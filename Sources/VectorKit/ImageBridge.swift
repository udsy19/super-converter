import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore

/// CGImage and image bytes → ImageAsset for the vector readers (pictures inside drawings), the other direction is
/// Core's `ImageFrame.cgImage()` and `pngData()`.
public enum ImageBridge {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

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
}
