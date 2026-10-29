import CoreGraphics
import Foundation
import SuperConverterCore

/// The `ImagePipeline` step (quality §2.1): every pixel operation between decode and encode, in this order —
/// orientation → linear light → Lanczos resampling → one ColorSync conversion to the target space → crop/pad →
/// alpha flattening (in the encoded space) → one bit-depth reduction with dither. A frame that needs none of it is passed
/// on untouched, so its encoder can copy the source bit for bit.
struct ImagePipeline {
    let settings: ImageSettings
    let traits: TargetTraits
    let sourceFormat: FormatID
    let workFolder: URL
    var isCancelled: () -> Bool = { false }

    private final class Notes {
        var list: [LossNote] = []
        func add(_ note: LossNote) { if !list.contains(note) { list.append(note) } }
    }

    func run(_ input: ImageAsset) throws -> (asset: ImageAsset, notes: [LossNote]) {
        let notes = Notes()
        var asset = input
        asset.metadata = Metadata.filtered(input.metadata, policy: settings.metadata)
        let hasPhotoDetails = input.metadata.exif != nil || input.metadata.iptc != nil || input.metadata.xmp != nil
        if settings.metadata != .none, hasPhotoDetails, [.bmp, .gif, .ico, .icns].contains(traits.kind) {
            notes.add(LossNote(.metadataDropped))
        }
        let sourceIsIconSet = ["ico", "icns", "cur"].contains(sourceFormat.rawValue)
        var frames = input.frames
        if sourceIsIconSet, traits.iconSizes.isEmpty, let largest = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            frames = [largest]
        }
        if !traits.iconSizes.isEmpty {
            asset.frames = try iconSet(from: frames, sourceIsIconSet: sourceIsIconSet, notes: notes)
            asset.loopCount = nil
        } else {
            asset.frames = try frames.map { frame in
                if isCancelled() { throw ConversionError.cancelled }
                return try process(frame, iconSize: nil, notes: notes)
            }
        }
        if input.isAnimated, !traits.holdsSeveral { notes.add(LossNote(.animationDropped)) }
        return (asset, notes.list)
    }

    // MARK: Decisions

    /// The space the target receives (quality §2.2): the person's choice or the source's own, adapted to what the
    /// target can hold — sRGB for targets without ICC, Display P3 for CMYK or Lab into RGB-only targets.
    func targetSpace(for source: ColourSpace) -> ColourSpace {
        var space: ColourSpace
        switch settings.profile {
        case .keep: space = source
        case .srgb: space = .sRGB
        case .displayP3: space = .displayP3
        case .adobeRGB: space = .adobeRGB
        case .proPhoto: space = .proPhoto
        case .gray: space = .grayGamma22
        case .cmyk: space = .genericCMYK
        case .custom(let url): space = (try? Data(contentsOf: url)).flatMap { ColourSpace(icc: $0) } ?? source
        }
        if !traits.holdsICC { return .sRGB }
        switch space.model {
        case .cmyk where !traits.holdsCMYK: return .displayP3
        case .gray where !traits.holdsGray: return .sRGB
        case .lab: return .displayP3
        default: return space
        }
    }

    func outputDepth(for frame: ImageFrame) -> Int {
        var depth: Int
        switch settings.bitDepth {
        case .keep: depth = frame.bitsPerComponent
        case .eight: depth = 8
        case .sixteen: depth = 16
        }
        depth = min(depth, traits.maxDepth)
        if depth > 16, traits.kind != .tiff { depth = 16 }
        return depth <= 8 ? 8 : depth <= 16 ? 16 : 32
    }

    private var backgroundIsTransparent: Bool { settings.background == .transparent }

    // MARK: One frame

    private func process(_ frame: ImageFrame, iconSize: Int?, notes: Notes) throws -> ImageFrame {
        let sourceSpace = FrameIO.space(of: frame)
        let orientation = settings.autoRotate ? frame.orientation : 1
        let orientedWidth = orientation >= 5 ? frame.height : frame.width
        let orientedHeight = orientation >= 5 ? frame.width : frame.height
        let plan: Geometry.Plan
        if let s = iconSize {
            let scale = min(Double(s) / Double(orientedWidth), Double(s) / Double(orientedHeight))
            plan = Geometry.Plan(scaledWidth: max(Int((Double(orientedWidth) * scale).rounded()), 1),
                                 scaledHeight: max(Int((Double(orientedHeight) * scale).rounded()), 1), canvasWidth: s, canvasHeight: s)
        } else {
            plan = Geometry.plan(width: orientedWidth, height: orientedHeight, size: settings.size, fit: settings.fit)
        }
        let resample = plan.scaledWidth != orientedWidth || plan.scaledHeight != orientedHeight
        let canvas = plan.canvasWidth != plan.scaledWidth || plan.canvasHeight != plan.scaledHeight
        let hdrSource: Bool = {
            if case .file(let url) = frame.pixels { return HDR.isHDR(url) }
            return false
        }()
        let keepHDR = hdrSource && traits.carriesHDR
        let destination = targetSpace(for: sourceSpace)
        let colourChange = destination.icc != sourceSpace.icc
        let flattenWanted = frame.hasAlpha && (!traits.holdsAlpha || destination.model == .cmyk
                                               || (traits.kind == .bmp && !backgroundIsTransparent))
        let depth = keepHDR ? 32 : outputDepth(for: frame)
        let untouched = orientation == 1 && !resample && !canvas && !colourChange && depth == frame.bitsPerComponent && iconSize == nil
            && (!hdrSource || keepHDR) && frame.bitsPerComponent != 32
        if untouched && !flattenWanted { return frame }

        // Decode (HDR sources through ImageIO's HDR rendition, which is then kept or tone-mapped).
        var raster: Raster
        if hdrSource, case .file(let url) = frame.pixels, let hdr = HDR.decodeHDR(url) {
            raster = hdr
        } else if let r = FrameIO.raster(frame) {
            raster = r
            if hdrSource, !keepHDR { notes.add(LossNote(.hdrToSDR)) }
        } else {
            throw ConversionError.failed("The picture couldn’t be read.")
        }
        if untouched && flattenWanted && !raster.hasTransparency { return frame }   // alpha fully opaque: nothing to fill

        raster = Geometry.orient(raster, orientation)
        if raster.extended, !keepHDR {
            if raster.maxComponent > 1.001 {
                raster = HDR.toneMapped(raster)
                notes.add(LossNote(.hdrToSDR))
            }
            raster.extended = false
            raster.clamp()
        }

        if resample {
            let pixelArt = plan.scaledWidth > raster.width && isPixelArt(raster)
            if !raster.extended, raster.space.model != .cmyk, let linear = raster.space.linear {
                raster = try convert(raster, to: linear, intent: .relative, bpc: false, notes: nil)
            }
            if pixelArt {
                raster = Resample.nearest(raster, factor: min(plan.scaledWidth / raster.width, plan.scaledHeight / raster.height))
            }
            raster = Resample.lanczos(raster, width: plan.scaledWidth, height: plan.scaledHeight)
        }

        if keepHDR {
            if raster.space != HDR.workingSpace { raster = try convert(raster, to: HDR.workingSpace, intent: .relative, bpc: false, notes: nil) }
        } else if raster.space != destination {
            // RGB → CMYK always goes perceptual (quality §2.2); everything else uses the chosen intent.
            let intent: ImageSettings.Intent = destination.model == .cmyk && raster.space.model != .cmyk ? .perceptual : settings.intent
            raster = try convert(raster, to: destination, intent: intent, bpc: true, notes: notes)
        }

        if canvas {
            let transparent = iconSize != nil || (backgroundIsTransparent && traits.holdsAlpha)
            if transparent { raster.addAlpha() }
            var fill = transparent ? [Float](repeating: 0, count: raster.space.components) : backgroundColour(in: raster.space)
            if raster.hasAlpha { fill.append(transparent ? 0 : 1) }
            raster = Geometry.canvas(raster, width: plan.canvasWidth, height: plan.canvasHeight, fill: fill)
        }

        if raster.hasAlpha && (flattenWanted || raster.space.model == .cmyk) {
            if raster.hasTransparency {
                flatten(&raster)
                notes.add(LossNote(.transparencyFilled))
            }
            raster.removeAlpha()
        }

        if let s = iconSize, s <= 64 { Resample.iconSharpen(&raster) }

        raster.clamp()
        // One reduction with dither when the pixels carry more precision than the target keeps; plain rounding otherwise
        // (an 8-bit source converted once stays within half a level of the exact transform). GIF dithers in its quantiser.
        if depth < 32, raster.sourceDepth > depth, traits.kind != .gif { Dither.quantise(&raster, bits: depth) }
        raster.sourceDepth = depth
        var out = try FrameIO.frame(from: raster, depth: depth, folder: workFolder, delay: frame.delay)
        out.orientation = settings.autoRotate ? 1 : frame.orientation
        return out
    }

    /// ICO/ICNS entries: every size from the largest picture, reusing a source icon's own entry when it has that size.
    private func iconSet(from frames: [ImageFrame], sourceIsIconSet: Bool, notes: Notes) throws -> [ImageFrame] {
        guard let master = frames.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return [] }
        let allowed = traits.iconSizes
        let chosen = settings.iconSizes?.filter { allowed.contains($0) } ?? []
        let sizes = chosen.isEmpty ? allowed : chosen
        return try sizes.sorted(by: >).map { size in
            if isCancelled() { throw ConversionError.cancelled }
            let own = sourceIsIconSet ? frames.first { $0.width == size && $0.height == size } : nil
            return try process(own ?? master, iconSize: size, notes: notes)
        }
    }

    // MARK: Helpers

    private func convert(_ raster: Raster, to space: ColourSpace, intent: ImageSettings.Intent, bpc: Bool, notes: Notes?) throws -> Raster {
        let (colour, alpha) = raster.splitAlpha()
        guard var converted = ColourTransform.convert(colour, pixelCount: raster.pixelCount, from: raster.space, to: space,
                                                      intent: intent, blackPointCompensation: bpc) else {
            throw ConversionError.failed("The colours couldn’t be converted.")
        }
        if !raster.extended {
            // Relative colorimetric clips what the new space cannot show (quality §2.2: a loss note says so).
            let tolerance: Float = 0.5 / 255
            if let notes, converted.contains(where: { $0 < -tolerance || $0 > 1 + tolerance }) { notes.add(LossNote(.gamutClipped)) }
            for i in 0..<converted.count { converted[i] = min(max(converted[i], 0), 1) }
        }
        var out = raster
        out.space = space
        out.data = Raster.join(colour: converted, components: space.components, alpha: alpha)
        return out
    }

    /// The background colour (sRGB in the options) in `space`.
    private func backgroundColour(in space: ColourSpace) -> [Float] {
        let rgb: [Float]
        switch settings.background {
        case .transparent: rgb = [1, 1, 1]
        case .colour(let r, let g, let b): rgb = [Float(r), Float(g), Float(b)]
        }
        let converted = ColourTransform.convert(colour: rgb, from: .sRGB, to: space) ?? [Float](repeating: 1, count: space.components)
        return converted.map { min(max($0, 0), 1) }
    }

    /// Composites onto the background in the encoded space (quality §2.2: what browsers and Finder showed).
    private func flatten(_ raster: inout Raster) {
        let bg = backgroundColour(in: raster.space)
        let s = raster.stride, comps = raster.space.components
        for i in 0..<raster.pixelCount {
            let a = raster.data[i * s + comps]
            for c in 0..<comps { raster.data[i * s + c] = raster.data[i * s + c] * a + bg[c] * (1 - a) }
            raster.data[i * s + comps] = 1
        }
    }

    /// Pixel art (quality §2.4): at most 256 px with at most 64 colours.
    private func isPixelArt(_ raster: Raster) -> Bool {
        guard max(raster.width, raster.height) <= 256 else { return false }
        var colours = Set<UInt64>()
        let s = raster.stride
        for i in 0..<raster.pixelCount {
            var key: UInt64 = 0
            for c in 0..<s { key = key << 8 | UInt64(min(max(raster.data[i * s + c], 0), 1) * 255 + 0.5) }
            colours.insert(key)
            if colours.count > 64 { return false }
        }
        return true
    }
}
