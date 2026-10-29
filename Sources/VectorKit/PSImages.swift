import CoreGraphics
import Foundation
import ImageIO

/// Pictures for PostScript: the `image` operator with its data inline after `currentfile`, ASCII85-armoured so the file
/// stays 7-bit clean (formats §3.2, `PSWriter`). Level 3 compresses with Flate and tags colour as ICCBased; Level 2 has
/// neither, so lossless data is run-length encoded and colour is DeviceRGB. JPEG goes through DCTDecode at both levels.
enum PSImages {
    enum Encoding { case flate, jpeg }

    /// The PostScript that paints `image` into the unit square (top row first), composited over white.
    /// - Parameters:
    ///   - jpeg: JPEG bytes to pass through untouched when `encoding` is `.jpeg` (an RGB JPEG source file).
    ///   - tagged: tag the colours with the image's own ICC profile (Level 3 raster pages); otherwise the pixels are
    ///     converted to sRGB and written as DeviceRGB.
    static func paint(_ image: CGImage, level: Int, encoding: Encoding, jpeg: Data? = nil, tagged: Bool) -> String? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let space = tagged && level >= 3 && image.colorSpace?.model == .rgb ? image.colorSpace! : srgb
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var out = ""
        if tagged, level >= 3, let icc = space.copyICCData() as Data? {
            // An interpreter without ICC support falls back to DeviceRGB instead of stopping.
            out += "mark { [/ICCBased << /N 3 /DataSource <~\(ascii85(icc, wrap: false)) >>] setcolorspace } stopped\n"
            out += "{ cleartomark /DeviceRGB setcolorspace } { pop } ifelse\n"
        } else {
            out += "/DeviceRGB setcolorspace\n"
        }
        let filters: String, data: Data
        if encoding == .jpeg, let bytes = jpeg ?? jpegData(image, space: space) {
            filters = "/ASCII85Decode filter /DCTDecode filter"; data = bytes
        } else {
            guard let rgb = rgbBytes(image, space: space) else { return nil }
            if level >= 3 { filters = "/ASCII85Decode filter /FlateDecode filter"; data = Deflate.zlib(rgb) }
            else { filters = "/ASCII85Decode filter /RunLengthDecode filter"; data = runLength(rgb) }
        }
        out += "<< /ImageType 1 /Width \(w) /Height \(h) /BitsPerComponent 8 /Decode [0 1 0 1 0 1] /ImageMatrix [\(w) 0 0 -\(h) 0 \(h)]\n"
        out += "   /DataSource currentfile \(filters) >> image\n"
        out += ascii85(data, wrap: true) + "\n"
        return out
    }

    /// 8-bit RGB rows (top first) in `space`, alpha composited over white.
    static func rgbBytes(_ image: CGImage, space: CGColorSpace) -> Data? {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1]) ?? CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var rgb = Data(count: w * h * 3)
        rgb.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            for p in 0..<(w * h) { dst[p * 3] = rgba[p * 4]; dst[p * 3 + 1] = rgba[p * 4 + 1]; dst[p * 3 + 2] = rgba[p * 4 + 2] }
        }
        return rgb
    }

    /// The image as a baseline JPEG (quality 0.9) in `space`, over white.
    static func jpegData(_ image: CGImage, space: CGColorSpace) -> Data? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1]) ?? CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let opaque = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, opaque, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// TIFF bytes of a bitmap, for the DOS EPS preview section.
    static func tiff(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.tiff" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: Filters

    /// PackBits-style run-length encoding as RunLengthDecode reads it (PLRM 3.13.3), ending with the EOD byte 128.
    static func runLength(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8](), i = 0
        while i < bytes.count {
            var run = 1
            while i + run < bytes.count, run < 128, bytes[i + run] == bytes[i] { run += 1 }
            if run >= 2 {
                out.append(UInt8(257 - run)); out.append(bytes[i]); i += run
                continue
            }
            var j = i + 1
            while j < bytes.count, j - i < 128, !(j + 1 < bytes.count && bytes[j] == bytes[j + 1]) { j += 1 }
            out.append(UInt8(j - i - 1)); out.append(contentsOf: bytes[i..<j]); i = j
        }
        out.append(128)
        return Data(out)
    }

    /// ASCII85 with the `~>` end marker (PLRM 3.13.3). Wrapped at 76 columns; a line that would start with `%` gets a
    /// leading space (ignored by the filter) so DSC readers never mistake it for a comment.
    static func ascii85(_ data: Data, wrap: Bool) -> String {
        let bytes = [UInt8](data)
        var chars = [UInt8]()
        chars.reserveCapacity(bytes.count * 5 / 4 + 8)
        var i = 0
        while i < bytes.count {
            let n = min(4, bytes.count - i)
            var v: UInt32 = 0
            for k in 0..<4 { v = v << 8 | UInt32(k < n ? bytes[i + k] : 0) }
            if v == 0 && n == 4 { chars.append(UInt8(ascii: "z")) } else {
                var group = [UInt8](repeating: 0, count: 5)
                for k in stride(from: 4, through: 0, by: -1) { group[k] = UInt8(v % 85) + 33; v /= 85 }
                chars.append(contentsOf: group[0...n])
            }
            i += 4
        }
        chars.append(contentsOf: Array("~>".utf8))
        guard wrap else { return String(decoding: chars, as: UTF8.self) }
        var out = [UInt8](), column = 0
        for c in chars {
            if column == 76 { out.append(10); column = 0 }
            if column == 0 && c == UInt8(ascii: "%") { out.append(32); column = 1 }
            out.append(c); column += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}
