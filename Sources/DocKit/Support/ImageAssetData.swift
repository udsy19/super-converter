import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore

/// `ImageAsset` → PNG bytes for the writers that embed pictures (HTML from layouts and slides). Core's model is plain data, so
/// DocKit makes its own encoding with ImageIO; the pixel pipeline (colour management, resampling) belongs to ImageKit.
enum ImageAssetData {
    static func png(_ asset: ImageAsset) -> Data? {
        guard let frame = asset.frames.first else { return nil }
        var rgba: Data
        let bytesPerRow: Int
        switch frame.pixels {
        case .file(let url):
            return try? Data(contentsOf: url)
        case .rgba8(let data, let rowBytes):
            rgba = data; bytesPerRow = rowBytes
        case .rgbaHalf(let data, let rowBytes):
            // 16-bit float channels down to 8 bits.
            let width = frame.width, height = frame.height
            var out = Data(count: width * height * 4)
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                    for y in 0..<height {
                        for x in 0..<width * 4 {
                            let offset = y * rowBytes + x * 2
                            guard offset + 2 <= src.count else { continue }
                            let half = Float16(bitPattern: src.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                            dst[y * width * 4 + x] = UInt8(max(0, min(255, (Float(half) * 255).rounded())))
                        }
                    }
                }
            }
            rgba = out; bytesPerRow = width * 4
        }
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: frame.hasAlpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
