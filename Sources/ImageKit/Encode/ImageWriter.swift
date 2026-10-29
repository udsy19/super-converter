import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore

/// Writes an `ImageAsset` (already prepared by the pipeline) as the target format. A target that holds one picture gets
/// one file per frame or page, returned as a folder of numbered files ("1.png", "2.png", …) that ConvertKit names and
/// places (ux §6.3).
struct ImageWriter {
    let kind: TargetKind
    let format: FormatID
    let settings: ImageSettings
    let context: StepContext

    func write(_ asset: ImageAsset) throws -> URL {
        guard !asset.frames.isEmpty else { throw ConversionError.failed("There’s nothing to save.") }
        let together = TargetTraits(kind).holdsSeveral && !(kind == .tiff && !settings.multiPage)
        try FileManager.default.createDirectory(at: context.workFolder, withIntermediateDirectories: true)
        if asset.frames.count > 1 && !together {
            let folder = context.workFolder.appendingPathComponent("pictures-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (i, frame) in asset.frames.enumerated() {
                if context.isCancelled() { throw ConversionError.cancelled }
                var single = asset
                single.frames = [frame]
                single.loopCount = nil
                try writeFile(single, to: folder.appendingPathComponent("\(i + 1).\(format.rawValue)"))
                context.report(StepProgress(fraction: Double(i + 1) / Double(asset.frames.count)))
            }
            return folder
        }
        let url = context.workFolder.appendingPathComponent("picture-\(UUID().uuidString).\(format.rawValue)")
        try writeFile(asset, to: url)
        return url
    }

    private func writeFile(_ asset: ImageAsset, to url: URL) throws {
        switch kind {
        case .jpeg, .png, .tiff, .heic:
            try ImageIOWriter(kind: kind, settings: settings, context: context).write(asset, to: url)
        case .avif:
            // Neither ImageIO (it refuses quality 1.0) nor the bundled SVT-AV1 (4:2:0 only) writes lossless 4:4:4 AVIF.
            if settings.lossless == true { throw ConversionError.failed("Lossless AVIF can’t be made on this Mac. Turn off Lossless, or choose PNG or WebP.") }
            if ImageIOSupport.writesAVIF { try ImageIOWriter(kind: kind, settings: settings, context: context).write(asset, to: url) }
            else { try writeAVIF(asset, to: url) }
        case .webp: try writeWebP(asset, to: url)
        case .gif: try writeGIF(asset, to: url)
        case .bmp: try writeBMP(asset, to: url)
        case .psd: try writePSD(asset, to: url)
        case .ico: try writeICO(asset, to: url)
        case .icns: try writeICNS(asset, to: url)
        default: throw ConversionError.unsupportedPair(from: context.sourceFormat, to: format)
        }
    }

    // MARK: Pixels for the own writers

    /// 8-bit RGBA (straight alpha, top row first) in the frame's own space; gray is expanded to RGB.
    private func rgba8(_ frame: ImageFrame) throws -> [UInt8] {
        if case .rgba8(let data, let bytesPerRow) = frame.pixels, bytesPerRow == frame.width * 4 { return [UInt8](data) }
        guard let raster = FrameIO.raster(frame) else { throw ConversionError.failed("The picture couldn’t be read.") }
        var out = [UInt8](repeating: 255, count: raster.pixelCount * 4)
        let s = raster.stride, gray = raster.space.components == 1
        for i in 0..<raster.pixelCount {
            for c in 0..<3 { out[i * 4 + c] = UInt8(min(max(raster.data[i * s + (gray ? 0 : c)], 0), 1) * 255 + 0.5) }
            if raster.hasAlpha { out[i * 4 + 3] = UInt8(min(max(raster.data[i * s + s - 1], 0), 1) * 255 + 0.5) }
        }
        return out
    }

    private var dpi: (ImageAsset) -> Double { { Metadata.dpi($0.metadata) ?? 72 } }

    private func exifAndXMP(_ asset: ImageAsset, frame: ImageFrame) -> (exif: Data?, xmp: Data?) {
        let (properties, xmp) = Metadata.forWriting(asset.metadata, width: frame.width, height: frame.height, orientation: frame.orientation)
        return (Metadata.exifBlock(properties), xmp.flatMap { CGImageMetadataCreateXMPData($0, nil) as Data? })
    }

    private func writeWebP(_ asset: ImageAsset, to url: URL) throws {
        let frames = try asset.frames.map { WebPWriter.Frame(width: $0.width, height: $0.height, rgba: try rgba8($0), delay: $0.delay) }
        // Graphics (quality §2.3: PNG/GIF/BMP/ICO/TGA/PPM sources) are lossless unless the person chose otherwise.
        let graphicSource = ["png", "gif", "bmp", "ico", "tga", "ppm"].contains(context.sourceFormat.rawValue)
        let first = asset.frames[0]
        let (exif, xmp) = exifAndXMP(asset, frame: first)
        let data = try WebPWriter.encode(frames, lossless: settings.lossless ?? graphicSource, quality: settings.quality(for: .webp),
                                         loopCount: settings.loopCount ?? asset.loopCount ?? 0, icc: FrameIO.space(of: first).icc,
                                         exif: exif, xmp: xmp)
        try data.write(to: url, options: .atomic)
    }

    private func writeAVIF(_ asset: ImageAsset, to url: URL) throws {
        let frame = asset.frames[0]
        guard let raster = FrameIO.raster(frame) else { throw ConversionError.failed("The picture couldn’t be read.") }
        let depth = frame.bitsPerComponent > 8 ? 16 : 8
        let scale: Float = depth == 16 ? 65535 : 255
        var samples = [UInt16](repeating: UInt16(scale), count: raster.pixelCount * 4)
        let s = raster.stride, gray = raster.space.components == 1
        for i in 0..<raster.pixelCount {
            for c in 0..<3 { samples[i * 4 + c] = UInt16(min(max(raster.data[i * s + (gray ? 0 : c)], 0), 1) * scale + 0.5) }
            if raster.hasAlpha { samples[i * 4 + 3] = UInt16(min(max(raster.data[i * s + s - 1], 0), 1) * scale + 0.5) }
        }
        let (exif, xmp) = exifAndXMP(asset, frame: frame)
        let data = try AVIFWriter.encode(width: raster.width, height: raster.height, rgba: samples, depth: depth, alpha: raster.hasAlpha,
                                         quality: settings.lossless == true ? 100 : settings.quality(for: .avif),
                                         space: gray ? .sRGB : raster.space, exif: exif, xmp: xmp)
        try data.write(to: url, options: .atomic)
    }

    private func writeGIF(_ asset: ImageAsset, to url: URL) throws {
        let frames = try asset.frames.map { GIFEncoder.Frame(width: $0.width, height: $0.height, rgba: try rgba8($0), delay: $0.delay) }
        let data = GIFEncoder.encode(frames, colours: settings.gifColours, dither: settings.dither, loopCount: settings.loopCount ?? asset.loopCount ?? 0)
        try data.write(to: url, options: .atomic)
    }

    private func writeBMP(_ asset: ImageAsset, to url: URL) throws {
        let frame = asset.frames[0]
        try BitmapWriters.bmp(rgba: try rgba8(frame), width: frame.width, height: frame.height, alpha: frame.hasAlpha,
                              dpi: dpi(asset)).write(to: url, options: .atomic)
    }

    private func writePSD(_ asset: ImageAsset, to url: URL) throws {
        let frame = asset.frames[0]
        guard let raster = FrameIO.raster(frame) else { throw ConversionError.failed("The picture couldn’t be read.") }
        let (exif, xmp) = exifAndXMP(asset, frame: frame)
        try PSDCodec.encode(raster, depth: frame.bitsPerComponent > 8 ? 16 : 8, dpi: dpi(asset), exif: exif, xmp: xmp,
                            layerName: context.source.deletingPathExtension().lastPathComponent).write(to: url, options: .atomic)
    }

    private func writeICO(_ asset: ImageAsset, to url: URL) throws {
        let entries = try asset.frames.sorted { $0.width < $1.width }.map { frame -> (size: Int, rgba: [UInt8], png: Data?) in
            let png = frame.width >= 256 ? FrameIO.cgImage(frame).flatMap { BitmapWriters.png($0, icc: nil) } : nil
            return (frame.width, try rgba8(frame), png)
        }
        try BitmapWriters.ico(entries).write(to: url, options: .atomic)
    }

    private func writeICNS(_ asset: ImageAsset, to url: URL) throws {
        var pngs: [Int: Data] = [:]
        for frame in asset.frames {
            guard let image = FrameIO.cgImage(frame) else { throw ConversionError.failed("The picture couldn’t be read.") }
            let space = FrameIO.space(of: frame)
            pngs[frame.width] = BitmapWriters.png(ImageIOWriter.relabel(image, space: space), icc: space.icc)
        }
        try BitmapWriters.icns(pngs).write(to: url, options: .atomic)
    }
}
