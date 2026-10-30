import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore

/// CGImage and image bytes → ImageAsset for the vector readers (pictures inside drawings), and PNG bytes back; the other
/// direction is Core's `ImageFrame.cgImage()`.
public enum ImageBridge {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// The most pixels a picture inside a drawing may have (80 megapixels, 320 MB as RGBA).
    static let maxPixels = 80_000_000
    /// The most pixels one byte of encoded picture can describe: DEFLATE expands at most 1032:1 and a 1-bit PNG packs eight
    /// pixels in a byte, so a header claiming more is damage, not a picture.
    static let maxPixelsPerByte = 8192

    /// Whether `w` × `h` is a size worth decoding: positive and at most `maxPixels`, tested without overflowing.
    static func plausible(width w: Int, height h: Int) -> Bool { w > 0 && h > 0 && w <= maxPixels && h <= maxPixels / w }

    /// A single-frame `ImageAsset` (8-bit RGBA, un-premultiplied) from a `CGImage`.
    public static func asset(_ image: CGImage) -> ImageAsset? {
        let w = image.width, h = image.height
        guard plausible(width: w, height: h) else { return nil }
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

    /// Decodes image bytes (PNG, JPEG, GIF, TIFF, …) into an asset; nil when they don't decode or their header claims
    /// more pixels than the bytes can hold.
    public static func asset(decoding data: Data) -> ImageAsset? {
        guard let image = image(decoding: data) else { return nil }
        return asset(image)
    }

    /// The first picture in encoded bytes, refused when its size isn't plausible for them (see `maxPixelsPerByte`).
    static func image(decoding data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              plausible(width: image.width, height: image.height), image.width * image.height / maxPixelsPerByte <= data.count else { return nil }
        return image
    }

    /// PNG bytes of an asset's first frame.
    public static func pngData(_ asset: ImageAsset) -> Data? {
        guard let image = asset.frames.first?.cgImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
