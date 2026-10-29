import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore

/// ImageAsset ↔ CGImage for the vector readers and writers (pictures inside drawings, raster pages for PDF and PostScript).
public enum ImageBridge {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The first (or given) frame as an un-premultiplied 8-bit RGBA `CGImage` in the frame's colour space (sRGB when untagged).
    public static func cgImage(_ asset: ImageAsset, frame index: Int = 0) -> CGImage? {
        guard asset.frames.indices.contains(index) else { return nil }
        let frame = asset.frames[index]
        let space = frame.iccProfile.flatMap { CGColorSpace(iccData: $0 as CFData) }.flatMap { $0.model == .rgb ? $0 : nil } ?? srgb
        switch frame.pixels {
        case .rgba8(let data, let bytesPerRow):
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil,
                           shouldInterpolate: true, intent: .defaultIntent)
        case .rgbaHalf(let data, let bytesPerRow):
            // 16-bit float per channel → 8-bit.
            var bytes = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for y in 0..<frame.height {
                    for x in 0..<frame.width * 4 {
                        let bits = raw.loadUnaligned(fromByteOffset: y * bytesPerRow + x * 2, as: UInt16.self)
                        let v = Float(Float16(bitPattern: bits))
                        bytes[y * frame.width * 4 + x] = UInt8(max(0, min(255, (v * 255).rounded())))
                    }
                }
            }
            let out = Data(bytes)
            guard let provider = CGDataProvider(data: out as CFData) else { return nil }
            return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil,
                           shouldInterpolate: true, intent: .defaultIntent)
        case .file(let url):
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    /// A single-frame `ImageAsset` (8-bit RGBA, un-premultiplied) from a `CGImage`.
    public static func asset(_ image: CGImage) -> ImageAsset? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var premultiplied = Data(count: w * h * 4)
        let ok = premultiplied.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var hasAlpha = false
        premultiplied.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let a = Int(p[i + 3])
                if a != 255 { hasAlpha = true }
                if a > 0 && a < 255 {
                    for c in 0..<3 { p[i + c] = UInt8(min(255, (Int(p[i + c]) * 255 + a / 2) / a)) }
                }
            }
        }
        return ImageAsset(frames: [ImageFrame(width: w, height: h, pixels: .rgba8(premultiplied, bytesPerRow: w * 4), hasAlpha: hasAlpha)])
    }

    /// Decodes image bytes (PNG, JPEG, GIF, TIFF, …) into an asset.
    public static func asset(decoding data: Data) -> ImageAsset? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return asset(image)
    }

    /// PNG bytes of an asset's first frame.
    public static func pngData(_ asset: ImageAsset) -> Data? {
        guard let image = cgImage(asset) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
