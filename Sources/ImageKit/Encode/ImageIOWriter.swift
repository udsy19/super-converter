import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore
import UniformTypeIdentifiers

/// JPEG, PNG, TIFF, HEIC and (where this Mac's ImageIO lists it) AVIF through ImageIO (quality §2.3), with the source
/// profile byte for byte, photo details, DPI and HDR gain maps.
struct ImageIOWriter {
    let kind: TargetKind
    let settings: ImageSettings
    let context: StepContext

    var typeIdentifier: String {
        switch kind {
        case .jpeg: UTType.jpeg.identifier
        case .tiff: UTType.tiff.identifier
        case .heic: UTType.heic.identifier
        case .avif: "public.avif"
        default: UTType.png.identifier
        }
    }

    func write(_ asset: ImageAsset, to url: URL) throws {
        if copyUntouchedSource(asset, to: url) { return }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, typeIdentifier as CFString, asset.frames.count, nil) else {
            throw ConversionError.folderNotWritable(name: url.deletingLastPathComponent().lastPathComponent)
        }
        var paletteAlphas: [UInt8]?
        for frame in asset.frames {
            if context.isCancelled() { throw ConversionError.cancelled }
            var (image, hdr) = try Self.image(for: frame, carriesHDR: TargetTraits(kind).carriesHDR, keepsFloat: kind == .tiff)
            let (properties, xmp) = Metadata.forWriting(asset.metadata, width: frame.width, height: frame.height, orientation: frame.orientation)
            var options = properties
            switch kind {
            case .jpeg:
                options[kCGImageDestinationLossyCompressionQuality] = Double(settings.quality(for: .jpeg)) / 100
                if settings.progressive { options[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true] }
            case .heic, .avif:
                options[kCGImageDestinationLossyCompressionQuality] = Double(settings.lossless == true ? 100 : settings.quality(for: kind)) / 100
            case .tiff:
                var tiff = options[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                tiff[kCGImagePropertyTIFFCompression] = switch settings.tiffCompression {
                case .lzw: 5   // ImageIO adds the horizontal predictor with LZW
                case .zip: 8
                case .none: 1
                case .jpeg: 7
                }
                options[kCGImagePropertyTIFFDictionary] = tiff
            case .png:
                if asset.frames.count == 1, !hdr, let palette = Palette.indexed(image) {
                    image = palette.image
                    paletteAlphas = palette.alphas
                }
            default: break
            }
            if hdr, #available(macOS 15, *) { options[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap }
            if let xmp { CGImageDestinationAddImageAndMetadata(destination, image, xmp, options as CFDictionary) }
            else { CGImageDestinationAddImage(destination, image, options as CFDictionary) }
        }
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("The picture couldn’t be saved.") }
        if kind == .png, let frame = asset.frames.first {
            var png = try Data(contentsOf: url)
            if let alphas = paletteAlphas, let withAlpha = PNGChunks.addingTransparency(png, alphas: alphas) { png = withAlpha }
            if let exact = PNGChunks.settingICC(png, icc: FrameIO.space(of: frame).icc) { png = exact }
            try png.write(to: url, options: .atomic)
        }
    }

    /// The frame's pixels as Core Graphics sees them, labelled with the frame's own profile; for HDR (a source with a gain
    /// map or PQ/HLG, or extended float pixels) the HDR rendition when the target keeps it.
    static func image(for frame: ImageFrame, carriesHDR: Bool, keepsFloat: Bool = false) throws -> (CGImage, hdr: Bool) {
        if carriesHDR, case .file(let url) = frame.pixels, frame.bitsPerComponent != 32, HDR.isHDR(url), #available(macOS 15, *),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let hdr = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary) {
            return (hdr, true)
        }
        if frame.bitsPerComponent == 32, !keepsFloat, let raster = FrameIO.raster(frame) {
            if raster.extended, raster.maxComponent > 1.001, carriesHDR, let image = raster.cgImage(depth: 32) { return (image, true) }
            var sdr = raster
            sdr.extended = false
            sdr.clamp()
            if let image = sdr.cgImage(depth: 16) { return (image, false) }
        }
        guard let image = FrameIO.cgImage(frame) else { throw ConversionError.failed("The picture couldn’t be read.") }
        return (relabel(image, space: FrameIO.space(of: frame)), false)
    }

    /// The same pixels with `space` attached (no conversion): ImageIO then embeds exactly that profile.
    static func relabel(_ image: CGImage, space: ColourSpace) -> CGImage {
        guard image.colorSpace?.model != .indexed, (image.colorSpace?.numberOfComponents ?? space.components) == space.components,
              (image.colorSpace?.copyICCData() as Data?) != space.icc, let provider = image.dataProvider,
              let relabelled = CGImage(width: image.width, height: image.height, bitsPerComponent: image.bitsPerComponent,
                                       bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow, space: space.cg,
                                       bitmapInfo: image.bitmapInfo, provider: provider, decode: image.decode,
                                       shouldInterpolate: true, intent: .defaultIntent) else { return image }
        return relabelled
    }

    /// Same container, nothing changed, default quality: ImageIO copies the compressed data and rewrites only the
    /// metadata (quality §2.6: JPEG → JPEG metadata edits are lossless; HEIC keeps its gain map).
    private func copyUntouchedSource(_ asset: ImageAsset, to url: URL) -> Bool {
        guard asset.frames.count == 1, let frame = asset.frames.first, case .file(let file) = frame.pixels,
              file.standardizedFileURL == context.source.standardizedFileURL,
              FormatCatalog.isSameFormat(context.sourceFormat, context.targetFormat),
              settings.quality == nil, settings.lossless == nil, [.jpeg, .heic, .tiff, .avif].contains(kind),
              let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) == 1,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, typeIdentifier as CFString, 1, nil) else { return false }
        let (_, xmp) = Metadata.forWriting(asset.metadata, width: frame.width, height: frame.height, orientation: frame.orientation)
        var error: Unmanaged<CFError>?
        let ok = CGImageDestinationCopyImageSource(destination, source, [kCGImageDestinationMetadata: xmp ?? CGImageMetadataCreateMutable(),
                                                                         kCGImageDestinationMergeMetadata: false] as CFDictionary, &error)
        error?.release()
        if !ok { try? FileManager.default.removeItem(at: url) }
        return ok
    }
}

/// Palette PNG when a picture has at most 256 colours and no partial transparency (quality §2.3: smaller, exactly
/// lossless). Fully transparent pixels share one palette entry made transparent through `tRNS`.
enum Palette {
    struct Indexed { let image: CGImage; let alphas: [UInt8]? }

    static func indexed(_ image: CGImage) -> Indexed? {
        guard image.bitsPerComponent == 8, let space = image.colorSpace, space.model == .rgb,
              let raster = Raster(cgImage: image, space: ColourSpace(cg: space) ?? .sRGB) else { return nil }
        let s = raster.stride, count = raster.pixelCount
        var colours: [UInt32: UInt8] = [:]
        var table: [UInt8] = []
        var transparent = false
        if raster.hasAlpha {
            for i in 0..<count where raster.data[i * s + 3] < 1 {
                guard raster.data[i * s + 3] == 0 else { return nil }   // partial alpha: keep RGBA
                transparent = true
            }
            if transparent { table = [0, 0, 0] }   // index 0
        }
        var indexes = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            if transparent, raster.data[i * s + 3] == 0 { continue }
            let r = UInt32(raster.data[i * s] * 255 + 0.5), g = UInt32(raster.data[i * s + 1] * 255 + 0.5), b = UInt32(raster.data[i * s + 2] * 255 + 0.5)
            let key = r << 16 | g << 8 | b
            if let index = colours[key] { indexes[i] = index; continue }
            guard table.count / 3 < 256 else { return nil }
            let index = UInt8(table.count / 3)
            colours[key] = index
            table += [UInt8(r), UInt8(g), UInt8(b)]
            indexes[i] = index
        }
        guard let indexedSpace = CGColorSpace(indexedBaseSpace: space, last: table.count / 3 - 1, colorTable: table),
              let provider = CGDataProvider(data: Data(indexes) as CFData),
              let out = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: raster.width,
                                space: indexedSpace, bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return Indexed(image: out, alphas: transparent ? [0] : nil)
    }
}
