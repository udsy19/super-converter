import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore

/// ImageIO reading (formats §3.1): one `ImageAsset` per file. A single-frame source stays a reference to the file itself
/// (`.file(source)`, decoded when needed), so an untouched picture reaches its encoder bit for bit (quality §2.1); the
/// frames of animations, multi-page TIFFs and icon sets are copied out losslessly into the work folder. Photoshop files
/// go through `PSDCodec` first: ImageIO returns the colours of semi-transparent PSD pixels premultiplied.
enum ImageIODecoder {
    static func decode(_ url: URL, format: FormatID, settings: ImageSettings, workFolder: URL,
                       isCancelled: () -> Bool = { false }) throws -> ImageAsset {
        if format == "psd", let data = try? Data(contentsOf: url, options: .mappedIfSafe), let psd = try? PSDCodec.decode(data) {
            let frame = try FrameIO.frame(from: psd.raster, depth: psd.raster.sourceDepth, folder: workFolder)
            let metadata = CGImageSourceCreateWithURL(url as CFURL, nil).map { Metadata.capture($0, index: 0) } ?? ImageMetadata(xmp: psd.xmp)
            return ImageAsset(frames: [frame], metadata: metadata)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            if let asset = try PNMDecoder.decodeIfNetpbm(url, workFolder: workFolder) { return asset }
            throw ConversionError.damaged(format)
        }
        let count = CGImageSourceGetCount(source)
        let animation = animationInfo(source, count: count)
        let isIconSet = ["ico", "icns", "cur"].contains(format.rawValue)
        let indexes = count > 1 && !isIconSet ? settings.pageIndices(count: count) : Array(0..<count)
        var frames: [ImageFrame] = []
        for index in indexes {
            if isCancelled() { throw ConversionError.cancelled }
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { throw ConversionError.damaged(format) }
            let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
            var space = colourSpace(of: image)
            let delay = animation?.delays[index]
            let orientation = (properties[kCGImagePropertyOrientation] as? Int) ?? 1
            let isFloat = (properties[kCGImagePropertyIsFloat] as? Bool) == true || image.bitmapInfo.contains(.floatComponents)
            let depth = isFloat ? 32 : max(image.bitsPerComponent, (properties[kCGImagePropertyDepth] as? Int) ?? 8) > 8 ? 16 : 8
            let alpha = hasAlpha(image)
            if count == 1, image.colorSpace?.model != .lab {
                frames.append(ImageFrame(width: image.width, height: image.height, pixels: .file(url), hasAlpha: alpha,
                                         iccProfile: space.icc, colourModel: space.model.rawValue, bitsPerComponent: depth,
                                         delay: delay, orientation: orientation))
                continue
            }
            var pixels = image
            if image.colorSpace?.model == .lab || image.colorSpace?.model == .indexed {
                // Lab (the one model ImageKit does not carry) becomes Display P3; palettes are expanded.
                let target = image.colorSpace?.model == .lab ? ColourSpace.displayP3 : space
                guard let drawn = draw(image, in: target, alpha: alpha, sixteen: depth > 8) else { throw ConversionError.damaged(format) }
                pixels = drawn; space = target
            }
            frames.append(ImageFrame(width: image.width, height: image.height, pixels: .file(try FrameIO.writeTIFF(pixels, folder: workFolder)),
                                     hasAlpha: alpha, iccProfile: space.icc, colourModel: space.model.rawValue, bitsPerComponent: depth,
                                     delay: delay, orientation: orientation))
        }
        let metadata = Metadata.capture(source, index: indexes.first ?? 0)
        return ImageAsset(frames: frames, metadata: metadata, loopCount: animation.map { $0.loopCount })
    }

    /// The colour space of a decoded image (indexed images: their base space; untagged ones: ImageIO already assumes
    /// sRGB / Gray Gamma 2.2 / Generic CMYK, which is quality §2.2's rule).
    static func colourSpace(of image: CGImage) -> ColourSpace {
        guard var cg = image.colorSpace else { return .sRGB }
        if cg.model == .indexed, let base = cg.baseColorSpace { cg = base }
        return ColourSpace(cg: cg) ?? .sRGB
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static func draw(_ image: CGImage, in space: ColourSpace, alpha: Bool, sixteen: Bool) -> CGImage? {
        let info = (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
            | (sixteen ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        guard space.model == .rgb, let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: sixteen ? 16 : 8,
                                                           bytesPerRow: 0, space: space.cg, bitmapInfo: info) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    struct Animation { var delays: [Int: TimeInterval]; var loopCount: Int }

    /// Frame delays and loop count of GIF, APNG, animated WebP and HEIF sequences; nil for stills and multi-page files.
    private static func animationInfo(_ source: CGImageSource, count: Int) -> Animation? {
        guard count > 1 else { return nil }
        let container = (CGImageSourceCopyProperties(source, nil) as? [CFString: Any]) ?? [:]
        let kinds: [(CFString, CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime, kCGImagePropertyWebPLoopCount),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime, kCGImagePropertyHEICSLoopCount),
        ]
        for (dict, unclamped, clamped, loop) in kinds {
            var delays: [Int: TimeInterval] = [:]
            for i in 0..<count {
                let p = (CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any])?[dict] as? [CFString: Any]
                if let d = (p?[unclamped] as? Double) ?? (p?[clamped] as? Double) { delays[i] = d }
            }
            if !delays.isEmpty {
                // No loop extension in a GIF means it plays once.
                let loopCount = ((container[dict] as? [CFString: Any])?[loop] as? Int) ?? 1
                return Animation(delays: delays, loopCount: loopCount)
            }
        }
        return nil
    }
}
