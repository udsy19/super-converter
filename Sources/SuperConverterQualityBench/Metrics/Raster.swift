import CoreGraphics
import Foundation
import ImageIO

/// An 8-bit sRGB picture as the metrics see it: interleaved RGB, alpha composited on white (quality §9).
struct Raster {
    let width: Int
    let height: Int
    /// `width * height * 3` bytes, row-major, R G B.
    var rgb: [UInt8]

    init(width: Int, height: Int, rgb: [UInt8]) {
        precondition(rgb.count == width * height * 3)
        self.width = width; self.height = height; self.rgb = rgb
    }

    /// A solid-colour picture (reference values and tests).
    init(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) {
        self.init(width: width, height: height, rgb: (0..<width * height).flatMap { _ in [red, green, blue] })
    }

    /// Decodes any file ImageIO reads (first frame) into sRGB.
    init?(contentsOf url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(image)
    }

    /// Draws `image` into an sRGB bitmap on white.
    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<width * height { rgb[i * 3] = rgba[i * 4]; rgb[i * 3 + 1] = rgba[i * 4 + 1]; rgb[i * 3 + 2] = rgba[i * 4 + 2] }
        self.init(width: width, height: height, rgb: rgb)
    }

    var pixelCount: Int { width * height }

    /// Luma (Rec. 601, 0…255) — the plane SSIM runs on (quality §2.8: "SSIM (luma…)").
    var luma: [Double] {
        var out = [Double](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            out[i] = 0.299 * Double(rgb[i * 3]) + 0.587 * Double(rgb[i * 3 + 1]) + 0.114 * Double(rgb[i * 3 + 2])
        }
        return out
    }

    func cgImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(rgb) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Writes the picture as a PNG.
    @discardableResult
    func writePNG(to url: URL) -> Bool {
        guard let image = cgImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
