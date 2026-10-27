import AppKit
import SuperConverterCore
import VectorKit

// VectorKit's checks (WP-V): SVG, PDF, PostScript, CGM, SK/SK1 and AI on generated fixtures, compared by rendered pixels.
// Renders of a few cases are saved under $SUPERCONVERTER_SELFTEST_RENDERS when set, so they can be looked at.

struct SVTPixel { var r: Int, g: Int, b: Int, a: Int }

/// A raster copy of a CGImage as straight RGBA bytes.
struct SVTBitmap {
    let width: Int, height: Int
    var bytes: [UInt8]

    init?(_ image: CGImage?) {
        guard let image else { return nil }
        width = image.width; height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !ok { return nil }
    }

    /// Pixel at (x, y) counted from the top-left.
    func at(_ x: Int, _ y: Int) -> SVTPixel {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return SVTPixel(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]), a: Int(bytes[i + 3]))
    }

    func near(_ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int, tolerance: Int = 12) -> Bool {
        let p = at(x, y)
        return abs(p.r - r) <= tolerance && abs(p.g - g) <= tolerance && abs(p.b - b) <= tolerance
    }

    /// Mean absolute difference per channel (0...255) against a bitmap of the same size.
    func meanDifference(_ other: SVTBitmap) -> Double {
        guard width == other.width, height == other.height else { return 255 }
        var total = 0
        for i in 0..<bytes.count { total += abs(Int(bytes[i]) - Int(other.bytes[i])) }
        return Double(total) / Double(bytes.count)
    }

    /// Fraction of pixels whose largest channel difference exceeds `threshold`.
    func mismatch(_ other: SVTBitmap, threshold: Int = 40) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        var bad = 0
        for p in 0..<(width * height) {
            var worst = 0
            for c in 0..<3 { worst = max(worst, abs(Int(bytes[p * 4 + c]) - Int(other.bytes[p * 4 + c]))) }
            if worst > threshold { bad += 1 }
        }
        return Double(bad) / Double(width * height)
    }
}

func svtSave(_ image: CGImage?, _ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["SUPERCONVERTER_SELFTEST_RENDERS"], let image else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
}

/// Renders page 0 of a document so that one SVG px is one image pixel (the model is in points).
func svtRender(_ doc: VectorDocument, pxPerPoint: Double = 4.0 / 3.0) -> SVTBitmap? {
    guard let page = doc.pages.first else { return nil }
    return SVTBitmap(VectorRenderer.render(page, scale: pxPerPoint))
}

func svtSVG(_ body: String, size: Int = 100) -> Data {
    Data("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"\(size)\" height=\"\(size)\" viewBox=\"0 0 \(size) \(size)\">\(body)</svg>".utf8)
}

func registerVectorKitTests() {
    registerVectorKitMetafileTests()
    registerVectorKitSVGTests()
}
