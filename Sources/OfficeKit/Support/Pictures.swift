import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore
import UniformTypeIdentifiers

/// Pictures between Core's `ImageAsset` and the bytes inside Office files: decoding embedded media into an asset (8-bit
/// RGBA, un-premultiplied, sRGB) and encoding an asset's first frame as PNG for the writers. OfficeKit cannot import
/// ImageKit, so this is the small subset it needs.
enum Pictures {
    /// Decodes picture bytes (PNG, JPEG, GIF, TIFF, HEIC…); nil when ImageIO can't read them (EMF, WMF).
    static func asset(from data: Data, maxPixels: Int = 8_192) -> ImageAsset? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return asset(from: image)
    }

    static func asset(from image: CGImage) -> ImageAsset? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Un-premultiply: the model keeps colour independent of alpha.
            let bytes = buffer.bindMemory(to: UInt8.self)
            var i = 0
            while i < bytes.count {
                let a = Int(bytes[i + 3])
                if a > 0, a < 255 {
                    bytes[i] = UInt8(min(Int(bytes[i]) * 255 / a, 255))
                    bytes[i + 1] = UInt8(min(Int(bytes[i + 1]) * 255 / a, 255))
                    bytes[i + 2] = UInt8(min(Int(bytes[i + 2]) * 255 / a, 255))
                }
                i += 4
            }
            return true
        }
        guard drawn else { return nil }
        let alpha: Bool = {
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: false
            default: true
            }
        }()
        return ImageAsset(frames: [ImageFrame(width: width, height: height, pixels: .rgba8(pixels, bytesPerRow: bytesPerRow), hasAlpha: alpha)])
    }

    /// The first frame as a `CGImage` (sRGB, premultiplied); nil when the pixels can't be read.
    static func cgImage(_ asset: ImageAsset) -> CGImage? {
        guard let frame = asset.frames.first, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        switch frame.pixels {
        case .file(let url):
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        case .rgba8(let data, let bytesPerRow):
            return premultiplied(data, bytesPerRow: bytesPerRow, width: frame.width, height: frame.height, space: space) { Double($0) / 255 }
        case .rgbaHalf(let data, let bytesPerRow):
            return premultiplied(data, bytesPerRow: bytesPerRow, width: frame.width, height: frame.height, space: space, bytesPerComponent: 2) {
                halfToDouble(UInt16($0))
            }
        }
    }

    /// PNG bytes of the first frame.
    static func png(_ asset: ImageAsset) -> Data? {
        guard let image = cgImage(asset) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    private static func premultiplied(_ data: Data, bytesPerRow: Int, width: Int, height: Int, space: CGColorSpace, bytesPerComponent: Int = 1,
                                      value: (Int) -> Double) -> CGImage? {
        guard width > 0, height > 0, bytesPerRow >= width * 4 * bytesPerComponent, data.count >= bytesPerRow * height else { return nil }
        var out = Data(count: width * height * 4)
        data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                for y in 0..<height {
                    for x in 0..<width {
                        let s = y * bytesPerRow + x * 4 * bytesPerComponent
                        func component(_ k: Int) -> Double {
                            bytesPerComponent == 1 ? value(Int(source[s + k]))
                                : value(Int(source[s + k * 2]) | Int(source[s + k * 2 + 1]) << 8)
                        }
                        let a = min(max(component(3), 0), 1)
                        let t = (y * width + x) * 4
                        for k in 0..<3 { target[t + k] = UInt8((min(max(component(k), 0), 1) * a * 255).rounded()) }
                        target[t + 3] = UInt8((a * 255).rounded())
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: out as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// IEEE half precision, little endian bits, to Double.
    private static func halfToDouble(_ bits: UInt16) -> Double {
        let sign = bits & 0x8000 != 0 ? -1.0 : 1.0
        let exponent = Int(bits >> 10) & 0x1F, fraction = Double(bits & 0x3FF)
        if exponent == 0 { return sign * fraction / 1024 * pow(2, -14) }
        if exponent == 31 { return fraction == 0 ? sign * .infinity : .nan }
        return sign * (1 + fraction / 1024) * pow(2, Double(exponent - 15))
    }
}
