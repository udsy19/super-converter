import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Own writers where ImageIO falls short (checked on macOS 26.5): BMP (ImageIO cannot write a v5 header's alpha masks
/// and colour space; it also cannot read a BMP with an embedded profile, so ImageKit converts BMP pixels to sRGB and
/// declares LCS_sRGB), ICO (ImageIO writes one image per file) and ICNS (ImageIO's writer drops 64 and 1024 px and the
/// @2x entries).
enum BitmapWriters {
    /// PNG bytes for one image, with `icc` embedded byte for byte.
    static func png(_ image: CGImage, icc: Data?) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        guard let icc else { return out as Data }
        return PNGChunks.settingICC(out as Data, icc: icc) ?? out as Data
    }

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    private static func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
    private static func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    /// BMP with a BITMAPV5HEADER declaring sRGB: 24-bit, or 32-bit BGRA with bit-field masks when there is alpha.
    static func bmp(rgba: [UInt8], width: Int, height: Int, alpha: Bool, dpi: Double) -> Data {
        let bpp = alpha ? 32 : 24
        let rowBytes = ((width * bpp / 8) + 3) & ~3
        let pixelBytes = rowBytes * height
        let headerSize = 124
        var out: [UInt8] = Array("BM".utf8) + le32(14 + headerSize + pixelBytes) + le32(0) + le32(14 + headerSize)
        let ppm = Int((dpi / 0.0254).rounded())
        out += le32(headerSize) + le32(width) + le32(height) + le16(1) + le16(bpp)
        out += le32(alpha ? 3 : 0) + le32(pixelBytes) + le32(ppm) + le32(ppm) + le32(0) + le32(0)
        out += alpha ? le32(0x00FF_0000) + le32(0x0000_FF00) + le32(0x0000_00FF) + le32(Int(0xFF00_0000)) : le32(0) + le32(0) + le32(0) + le32(0)
        out += Array("BGRs".utf8)                      // LCS_sRGB as a little-endian DWORD
        out += [UInt8](repeating: 0, count: 36 + 12)   // endpoints and gamma (unused for sRGB)
        out += le32(2) + le32(0) + le32(0) + le32(0)   // LCS_GM_GRAPHICS (relative colorimetric), no profile
        var pixels = [UInt8](repeating: 0, count: pixelBytes)
        for y in 0..<height {
            let row = (height - 1 - y) * rowBytes
            for x in 0..<width {
                let s = (y * width + x) * 4, d = row + x * bpp / 8
                pixels[d] = rgba[s + 2]; pixels[d + 1] = rgba[s + 1]; pixels[d + 2] = rgba[s]
                if alpha { pixels[d + 3] = rgba[s + 3] }
            }
        }
        return Data(out + pixels)
    }

    /// ICO: 32-bit BGRA entries with an AND mask, the 256 px entry PNG-compressed (quality §2.3).
    static func ico(_ entries: [(size: Int, rgba: [UInt8], png: Data?)]) -> Data {
        var images: [[UInt8]] = []
        for e in entries {
            if e.size >= 256, let png = e.png { images.append([UInt8](png)); continue }
            let s = e.size
            var dib = le32(40) + le32(s) + le32(s * 2) + le16(1) + le16(32) + le32(0) + le32(s * s * 4) + le32(0) + le32(0) + le32(0) + le32(0)
            for y in (0..<s).reversed() {
                for x in 0..<s {
                    let i = (y * s + x) * 4
                    dib += [e.rgba[i + 2], e.rgba[i + 1], e.rgba[i], e.rgba[i + 3]]
                }
            }
            let maskRow = ((s + 31) / 32) * 4
            for y in (0..<s).reversed() {
                var row = [UInt8](repeating: 0, count: maskRow)
                for x in 0..<s where e.rgba[(y * s + x) * 4 + 3] == 0 { row[x / 8] |= 0x80 >> UInt8(x % 8) }
                dib += row
            }
            images.append(dib)
        }
        var out = le16(0) + le16(1) + le16(entries.count)
        var offset = 6 + 16 * entries.count
        for (e, image) in zip(entries, images) {
            let side = UInt8(e.size >= 256 ? 0 : e.size)
            out += [side, side, 0, 0] + le16(1) + le16(32) + le32(image.count) + le32(offset)
            offset += image.count
        }
        for image in images { out += image }
        return Data(out)
    }

    /// ICNS with PNG entries: the ten images of an `.iconset` (16–512 at @1x and @2x) plus 64 px.
    static func icns(_ pngs: [Int: Data]) -> Data {
        let types: [(String, Int)] = [("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("icp6", 64), ("ic07", 128),
                                      ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]
        var body: [UInt8] = []
        for (type, size) in types {
            guard let png = pngs[size] else { continue }
            body += Array(type.utf8) + be32(8 + png.count) + [UInt8](png)
        }
        return Data(Array("icns".utf8) + be32(8 + body.count) + body)
    }
}
