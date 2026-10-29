import Foundation
import SuperConverterCore

/// Netpbm reading for the variants ImageIO lacks (formats §3.2, `ImageCodecs`): PBM/PGM/PPM in plain (P1–P3) and raw
/// (P4–P6) form, PAM (P7: GRAYSCALE, RGB, with _ALPHA, BLACKANDWHITE), any maxval up to 65535. Netpbm has no colour
/// profile: RGB is sRGB and gray is Gray Gamma 2.2 (quality §2.2, untagged).
enum PNMDecoder {
    /// The asset when the file is Netpbm; nil when it is not; throws when it is but is damaged.
    static func decodeIfNetpbm(_ url: URL, workFolder: URL) throws -> ImageAsset? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 2, data[0] == UInt8(ascii: "P"),
              (UInt8(ascii: "1")...UInt8(ascii: "7")).contains(data[1]) else { return nil }
        guard let raster = decode(data) else { throw ConversionError.damaged("ppm") }
        return ImageAsset(frames: [try FrameIO.frame(from: raster, depth: raster.sourceDepth, folder: workFolder)])
    }

    static func decode(_ data: Data) -> Raster? {
        let bytes = [UInt8](data)
        var i = 2
        let kind = Int(bytes[1] - UInt8(ascii: "0"))

        func skipSpaceAndComments() {
            while i < bytes.count {
                if bytes[i] == UInt8(ascii: "#") { while i < bytes.count, bytes[i] != 10, bytes[i] != 13 { i += 1 } }
                else if bytes[i] == 32 || (9...13).contains(bytes[i]) { i += 1 }
                else { break }
            }
        }
        func number() -> Int? {
            skipSpaceAndComments()
            var value = 0, digits = 0
            while i < bytes.count, (48...57).contains(bytes[i]) {
                guard value <= Int(Int32.max) else { return nil }   // no Netpbm field needs more
                value = value * 10 + Int(bytes[i] - 48); i += 1; digits += 1
            }
            return digits > 0 ? value : nil
        }

        var width = 0, height = 0, maxval = 1, channels = 1, alpha = false, bitmap = false
        if kind == 7 {
            var depth = 0, tupleType = ""
            let text = String(decoding: bytes[2..<min(bytes.count, 4096)], as: UTF8.self)
            guard let end = text.range(of: "ENDHDR") else { return nil }
            for line in text[..<end.lowerBound].split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2 else { continue }
                switch parts[0] {
                case "WIDTH": width = Int(parts[1]) ?? 0
                case "HEIGHT": height = Int(parts[1]) ?? 0
                case "DEPTH": depth = Int(parts[1]) ?? 0
                case "MAXVAL": maxval = Int(parts[1]) ?? 0
                case "TUPLTYPE": tupleType = parts[1...].joined(separator: " ")
                default: break
                }
            }
            i = 2 + text.utf8.distance(from: text.startIndex, to: end.upperBound)
            while i < bytes.count, bytes[i] != 10 { i += 1 }
            i += 1
            channels = depth
            alpha = tupleType.hasSuffix("_ALPHA") || depth == 2 || depth == 4
            bitmap = tupleType.hasPrefix("BLACKANDWHITE")
        } else {
            guard let w = number(), let h = number() else { return nil }
            width = w; height = h
            if kind == 1 || kind == 4 { maxval = 1; bitmap = true } else { guard let m = number() else { return nil }; maxval = m }
            channels = (kind == 3 || kind == 6) ? 3 : 1
            i += 1   // the single whitespace before raster data
        }
        guard width > 0, height > 0, maxval > 0, maxval <= 65535, (1...4).contains(channels),
              case let (pixels, overflow) = width.multipliedReportingOverflow(by: height), !overflow, pixels < 1 << 30 else { return nil }
        let colourChannels = alpha ? channels - 1 : channels
        let count = width * height
        // The samples the header claims must fit in what follows it (plain samples take at least a byte each).
        let wide = maxval > 255
        let rowBytes = (width + 7) / 8
        let needed = switch kind {
        case 1, 2, 3: count * channels
        case 4: rowBytes * height
        default: count * channels * (wide ? 2 : 1)
        }
        guard i <= bytes.count, needed <= bytes.count - i else { return nil }
        var values = [Float](repeating: 0, count: count * channels)
        let scale = 1 / Float(maxval)
        switch kind {
        case 1, 2, 3:
            for k in 0..<(count * channels) {
                if kind == 1 {
                    skipSpaceAndComments()
                    guard i < bytes.count else { return nil }
                    values[k] = bytes[i] == UInt8(ascii: "1") ? 0 : 1   // PBM: 1 is black
                    i += 1
                } else {
                    guard let v = number() else { return nil }
                    values[k] = Float(min(v, maxval)) * scale
                }
            }
        case 4:
            for y in 0..<height {
                for x in 0..<width { values[y * width + x] = (bytes[i + y * rowBytes + x / 8] >> (7 - UInt8(x % 8))) & 1 == 1 ? 0 : 1 }
            }
        default:
            for k in 0..<(count * channels) {
                let v = wide ? Int(bytes[i + 2 * k]) << 8 | Int(bytes[i + 2 * k + 1]) : Int(bytes[i + k])
                values[k] = bitmap && k % channels < colourChannels ? (v > 0 ? 1 : 0) : Float(min(v, maxval)) * scale
            }
        }
        let space: ColourSpace = colourChannels >= 3 ? .sRGB : .grayGamma22
        return Raster(width: width, height: height, space: space, hasAlpha: alpha, data: values, sourceDepth: maxval > 255 ? 16 : 8)
    }
}
