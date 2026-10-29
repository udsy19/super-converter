import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore

/// Straight (un-premultiplied) 8-bit RGBA pixels of an image's first frame.
struct Raster {
    var width: Int
    var height: Int
    var rgba: [UInt8]
}

enum PixelSource {
    /// IEEE half precision to Float (`Float16` is missing on Intel).
    static func half(_ bits: UInt16) -> Float {
        let sign: Float = bits & 0x8000 != 0 ? -1 : 1
        let exponent = Int((bits >> 10) & 0x1f), mantissa = Float(bits & 0x3ff)
        if exponent == 0 { return sign * mantissa * powf(2, -24) }
        if exponent == 31 { return mantissa == 0 ? sign * .infinity : .nan }
        return sign * (1 + mantissa / 1024) * powf(2, Float(exponent - 15))
    }

    static func decode(_ asset: ImageAsset) throws -> Raster {
        guard let frame = asset.frames.first, frame.width > 0, frame.height > 0 else { throw ConversionError.failed("There’s no picture to trace.") }
        let w = frame.width, h = frame.height
        switch frame.pixels {
        case .rgba8(let data, let bytesPerRow):
            guard bytesPerRow >= w * 4, data.count >= bytesPerRow * (h - 1) + w * 4 else { throw ConversionError.damaged("png") }
            var out = [UInt8](repeating: 0, count: w * h * 4)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for y in 0..<h { for x in 0..<(w * 4) { out[y * w * 4 + x] = raw[y * bytesPerRow + x] } }
            }
            return Raster(width: w, height: h, rgba: out)
        case .rgbaHalf(let data, let bytesPerRow):
            guard bytesPerRow >= w * 8, data.count >= bytesPerRow * (h - 1) + w * 8 else { throw ConversionError.damaged("png") }
            var out = [UInt8](repeating: 0, count: w * h * 4)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for y in 0..<h {
                    for x in 0..<(w * 4) {
                        let bits = raw.loadUnaligned(fromByteOffset: y * bytesPerRow + x * 2, as: UInt16.self)
                        let v = half(bits)
                        out[y * w * 4 + x] = v.isNaN ? 0 : UInt8(max(0, min(255, (v * 255).rounded())))
                    }
                }
            }
            return Raster(width: w, height: h, rgba: out)
        case .file(let url):
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ConversionError.damaged(FormatID(url.pathExtension.lowercased()))
            }
            let iw = image.width, ih = image.height
            var out = [UInt8](repeating: 0, count: iw * ih * 4)
            let ok = out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: iw, height: ih, bitsPerComponent: 8, bytesPerRow: iw * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: iw, height: ih))
                return true
            }
            guard ok else { throw ConversionError.damaged(FormatID(url.pathExtension.lowercased())) }
            for i in stride(from: 0, to: out.count, by: 4) {
                let a = Int(out[i + 3])
                if a > 0 && a < 255 { for c in 0..<3 { out[i + c] = UInt8(min(255, (Int(out[i + c]) * 255 + a / 2) / a)) } }
            }
            return Raster(width: iw, height: ih, rgba: out)
        }
    }
}
