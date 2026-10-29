import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore
import UniformTypeIdentifiers

/// How ImageKit stores `ImageFrame` pixels (the convention other engines read):
/// - `.rgba8`: 8-bit RGB with alpha, un-premultiplied, in the frame's ICC space.
/// - `.rgbaHalf`: half-float RGBA in the frame's ICC space with extended-range semantics (values above 1 are HDR).
/// - `.file(url)`: the first image of a file ImageIO reads — the untouched source itself, or a lossless TIFF in the work
///   folder for gray, CMYK, 16-bit and float pixels. `iccProfile`, `colourModel` and `bitsPerComponent` describe it; a
///   reader trusts `iccProfile` over whatever the file carries.
enum FrameIO {
    /// The colour space a frame's pixels are in.
    static func space(of frame: ImageFrame) -> ColourSpace {
        if let icc = frame.iccProfile, let space = ColourSpace(icc: icc) { return space }
        switch frame.colourModel {
        case "Gray": return .grayGamma22
        case "CMYK": return .genericCMYK
        default: return .sRGB
        }
    }

    /// The frame's pixels as a `CGImage` exactly as stored (no colour conversion).
    static func cgImage(_ frame: ImageFrame) -> CGImage? {
        switch frame.pixels {
        case .file(let url):
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        case .rgba8, .rgbaHalf:
            return raster(frame)?.cgImage(depth: frame.bitsPerComponent > 8 ? 32 : 8)
        }
    }

    /// The frame as a float raster in its own space.
    static func raster(_ frame: ImageFrame) -> Raster? {
        let space = space(of: frame)
        switch frame.pixels {
        case .rgba8(let data, let bytesPerRow):
            guard space.model == .rgb, data.count >= bytesPerRow * frame.height, bytesPerRow >= frame.width * 4 else { return nil }
            let channels = frame.hasAlpha ? 4 : 3
            var out = [Float](repeating: 0, count: frame.width * frame.height * channels)
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                let p = src.bindMemory(to: UInt8.self)
                for y in 0..<frame.height {
                    for x in 0..<frame.width {
                        let s = y * bytesPerRow + x * 4, d = (y * frame.width + x) * channels
                        for c in 0..<channels { out[d + c] = Float(p[s + c]) / 255 }
                    }
                }
            }
            return Raster(width: frame.width, height: frame.height, space: space, hasAlpha: frame.hasAlpha, data: out, sourceDepth: 8)
        case .rgbaHalf(let data, let bytesPerRow):
            guard space.model == .rgb, data.count >= bytesPerRow * frame.height, bytesPerRow >= frame.width * 8 else { return nil }
            let all = HalfFloat.toFloat(data, count: bytesPerRow / 2 * frame.height)
            let channels = frame.hasAlpha ? 4 : 3
            var out = [Float](repeating: 0, count: frame.width * frame.height * channels)
            var maxValue: Float = 0
            for y in 0..<frame.height {
                for x in 0..<frame.width {
                    let s = y * bytesPerRow / 2 + x * 4, d = (y * frame.width + x) * channels
                    for c in 0..<channels { out[d + c] = all[s + c]; if c < 3 { maxValue = max(maxValue, all[s + c]) } }
                }
            }
            return Raster(width: frame.width, height: frame.height, space: space, hasAlpha: frame.hasAlpha, data: out,
                          sourceDepth: max(frame.bitsPerComponent, 16), extended: maxValue > 1)
        case .file(let url):
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            var r = Raster(cgImage: image, space: space, extended: frame.bitsPerComponent == 32)
            if frame.bitsPerComponent == 32 { r?.sourceDepth = 32 }
            return r
        }
    }

    /// Stores a processed raster as a frame: 8-bit RGB in memory, anything else as a lossless TIFF in `folder`.
    /// `depth` is 8, 16 or 32 (float); values must already be quantised (dithered) for 8 and 16.
    static func frame(from raster: Raster, depth: Int, folder: URL, delay: TimeInterval? = nil) throws -> ImageFrame {
        if depth == 8, raster.space.model == .rgb {
            let count = raster.pixelCount, s = raster.stride
            var bytes = Data(count: count * 4)
            raster.data.withUnsafeBufferPointer { src in
                bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                    let d = raw.bindMemory(to: UInt8.self)
                    for i in 0..<count {
                        for c in 0..<3 { d[i * 4 + c] = UInt8(min(max(src[i * s + c], 0), 1) * 255 + 0.5) }
                        d[i * 4 + 3] = raster.hasAlpha ? UInt8(min(max(src[i * s + 3], 0), 1) * 255 + 0.5) : 255
                    }
                }
            }
            return ImageFrame(width: raster.width, height: raster.height, pixels: .rgba8(bytes, bytesPerRow: raster.width * 4),
                              hasAlpha: raster.hasAlpha, iccProfile: raster.space.icc, colourModel: raster.space.model.rawValue,
                              bitsPerComponent: 8, delay: delay, orientation: 1)
        }
        guard let image = raster.cgImage(depth: depth) else { throw ConversionError.failed("The picture couldn’t be prepared.") }
        let url = try writeTIFF(image, folder: folder)
        return ImageFrame(width: raster.width, height: raster.height, pixels: .file(url), hasAlpha: raster.hasAlpha,
                          iccProfile: raster.space.icc, colourModel: raster.space.model.rawValue, bitsPerComponent: depth,
                          delay: delay, orientation: 1)
    }

    /// An uncompressed TIFF of `image` in `folder` (straight alpha, exact samples).
    static func writeTIFF(_ image: CGImage, folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("frame-\(UUID().uuidString).tiff")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil) else {
            throw ConversionError.folderNotWritable(name: folder.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("The picture couldn’t be prepared.") }
        return url
    }
}
