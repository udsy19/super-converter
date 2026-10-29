import CoreGraphics
import Foundation
import ImageIO

public extension ImageFrame {
    /// An 8-bit un-premultiplied RGBA frame holding `image`'s pixels, drawn in `space` (sRGB when nil). `iccProfile` is the
    /// space's profile, so downstream encoders tag the output (quality §2.2). Nil when the image is empty.
    init?(cgImage image: CGImage, space: CGColorSpace? = nil, hasAlpha: Bool = false) {
        let space = space ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let width = image.width, height = image.height, bytesPerRow = width * 4
        guard width > 0, height > 0, var buffer = Optional([UInt8](repeating: 0, count: bytesPerRow * height)) else { return nil }
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        if hasAlpha {
            for i in stride(from: 0, to: buffer.count, by: 4) {
                let a = Int(buffer[i + 3])
                guard a > 0, a < 255 else { continue }
                for c in 0..<3 { buffer[i + c] = UInt8(min(255, (Int(buffer[i + c]) * 255 + a / 2) / a)) }
            }
        }
        self.init(width: width, height: height, pixels: .rgba8(Data(buffer), bytesPerRow: bytesPerRow), hasAlpha: hasAlpha,
                  iccProfile: space.copyICCData() as Data?)
    }

    /// The frame as a CGImage (8-bit or half-float RGBA un-premultiplied, or a file ImageIO reads), in its own colour space
    /// (sRGB when untagged, or when the profile isn't an RGB one the pixels could be in): the inverse of `init(cgImage:)`.
    func cgImage() -> CGImage? {
        let space = iccProfile.flatMap { CGColorSpace(iccData: $0 as CFData) }.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        switch pixels {
        case .rgba8(let data, let bytesPerRow):
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        case .rgbaHalf(let data, let bytesPerRow):
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.floatComponents.rawValue | CGImageByteOrderInfo.order16Little.rawValue)
            return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: bytesPerRow, space: space,
                           bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        case .file(let url):
            return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }
    }
}
