import Foundation
import SuperConverterCore

/// Photoshop files (Adobe's published "Photoshop File Formats Specification"): reading the composite of PSD and PSB
/// ("big", version 2: 8-byte section lengths, 4-byte RLE counts) for `ImageCodecs`, and writing PSD (quality §2.3: one
/// flattened layer, 8 or 16-bit, ICC). ImageIO's own PSD writer stores semi-transparent colours premultiplied and reads
/// them back as straight, so ImageKit writes PSD itself.
enum PSDCodec {
    // MARK: Reading

    struct Decoded { var raster: Raster; var dpi: Double; var layerCount: Int; var xmp: Data? }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0
        mutating func u8() throws -> Int { guard i < bytes.count else { throw ConversionError.damaged("psd") }; i += 1; return Int(bytes[i - 1]) }
        mutating func u16() throws -> Int { try u8() << 8 | u8() }
        mutating func u32() throws -> Int { try u16() << 16 | u16() }
        mutating func u64() throws -> Int { try u32() << 32 | u32() }
        mutating func skip(_ n: Int) throws { guard n >= 0, i + n <= bytes.count else { throw ConversionError.damaged("psd") }; i += n }
        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, i + n <= bytes.count else { throw ConversionError.damaged("psd") }
            defer { i += n }
            return bytes[i..<(i + n)]
        }
    }

    private struct Header {
        var version: Int, channels: Int, height: Int, width: Int, depth: Int, mode: Int
        var palette: [UInt8], icc: Data?, dpi: Double, xmp: Data?, layerCount: Int, imageDataOffset: Int
    }

    /// The number of layers (0 for a flat file); nil when the file is not a Photoshop file.
    static func layerCount(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return (try? header([UInt8](data))).map { abs($0.layerCount) }
    }

    private static func header(_ bytes: [UInt8]) throws -> Header {
        var r = Reader(bytes: bytes)
        guard try r.take(4).elementsEqual("8BPS".utf8) else { throw ConversionError.damaged("psd") }
        let version = try r.u16()
        guard version == 1 || version == 2 else { throw ConversionError.damaged("psd") }
        try r.skip(6)
        let channels = try r.u16(), height = try r.u32(), width = try r.u32(), depth = try r.u16(), mode = try r.u16()
        let palette = Array(try r.take(try r.u32()))
        let resourcesEnd = try r.u32() + r.i
        var icc: Data?, dpi = 72.0, xmp: Data?
        while r.i + 12 <= resourcesEnd {
            guard try r.take(4).elementsEqual("8BIM".utf8) else { break }
            let id = try r.u16()
            let nameLength = try r.u8()
            try r.skip(nameLength + ((nameLength + 1) % 2))
            let size = try r.u32()
            let body = try r.take(size)
            if size % 2 == 1 { try r.skip(1) }
            switch id {
            case 1039: icc = Data(body)
            case 1060: xmp = Data(body)
            case 1005 where size >= 4:
                let b = Array(body)
                dpi = Double(Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])) / 65536
            default: break
            }
        }
        r.i = resourcesEnd
        let layerSectionLength = version == 2 ? try r.u64() : try r.u32()
        let layerSectionEnd = r.i + layerSectionLength
        var layerCount = 0
        if layerSectionLength > 0, (version == 2 ? try r.u64() : try r.u32()) > 0 {
            layerCount = Int(Int16(truncatingIfNeeded: try r.u16()))
        }
        return Header(version: version, channels: channels, height: height, width: width, depth: depth, mode: mode, palette: palette,
                      icc: icc, dpi: dpi, xmp: xmp, layerCount: layerCount, imageDataOffset: layerSectionEnd)
    }

    static func decode(_ data: Data) throws -> Decoded {
        let bytes = [UInt8](data)
        let h = try header(bytes)
        guard h.width > 0, h.height > 0, h.width * h.height < 1 << 31, [1, 8, 16, 32].contains(h.depth) else { throw ConversionError.damaged("psd") }
        var r = Reader(bytes: bytes, i: h.imageDataOffset)
        let compression = try r.u16()
        let bytesPerSample = h.depth == 1 ? 0 : h.depth / 8
        let rowBytes = h.depth == 1 ? (h.width + 7) / 8 : h.width * bytesPerSample
        let planeBytes = rowBytes * h.height
        var planes: [[UInt8]] = []
        switch compression {
        case 0:
            for _ in 0..<h.channels { planes.append(Array(try r.take(planeBytes))) }
        case 1:
            var counts: [Int] = []
            for _ in 0..<(h.channels * h.height) { counts.append(h.version == 2 ? try r.u32() : try r.u16()) }
            for c in 0..<h.channels {
                var plane = [UInt8](); plane.reserveCapacity(planeBytes)
                for y in 0..<h.height { plane += unpackBits(try r.take(counts[c * h.height + y]), expected: rowBytes) }
                planes.append(plane)
            }
        case 2, 3:
            guard let all = Zlib.decompress(Data(bytes[r.i...]), expectedSize: planeBytes * h.channels) else { throw ConversionError.damaged("psd") }
            for c in 0..<h.channels {
                var plane = [UInt8](all[(c * planeBytes)..<((c + 1) * planeBytes)])
                if compression == 3 { undoPrediction(&plane, rowBytes: rowBytes, height: h.height, bytesPerSample: bytesPerSample) }
                planes.append(plane)
            }
        default:
            throw ConversionError.damaged("psd")
        }

        let profile = h.icc.flatMap { ColourSpace(icc: $0) }
        let comps: Int, space: ColourSpace
        switch h.mode {
        case 0, 1, 8: comps = 1; space = profile?.model == .gray ? profile! : .grayGamma22   // bitmap, gray, duotone
        case 2, 3: comps = 3; space = profile?.model == .rgb ? profile! : .sRGB              // indexed, RGB
        case 4: comps = 4; space = profile?.model == .cmyk ? profile! : .genericCMYK
        default: throw ConversionError.failed("This Photoshop colour mode isn’t supported.")
        }
        let sourcePlanes = h.mode == 2 ? 1 : comps
        guard planes.count >= sourcePlanes, planes.allSatisfy({ $0.count >= planeBytes }) else { throw ConversionError.damaged("psd") }
        // A negative layer count says the first extra channel is the merged transparency (other extra channels are masks).
        let alpha = h.layerCount < 0 && planes.count > sourcePlanes
        let stride = comps + (alpha ? 1 : 0)
        let count = h.width * h.height
        var values = [Float](repeating: 0, count: count * stride)
        func sample(_ plane: [UInt8], _ i: Int) -> Float {
            switch h.depth {
            case 1: return (plane[(i / h.width) * rowBytes + (i % h.width) / 8] >> (7 - UInt8(i % h.width % 8))) & 1 == 1 ? 0 : 1
            case 8: return Float(plane[i]) / 255
            case 16: return Float(Int(plane[2 * i]) << 8 | Int(plane[2 * i + 1])) / 65535
            default:
                return Float(bitPattern: UInt32(plane[4 * i]) << 24 | UInt32(plane[4 * i + 1]) << 16 | UInt32(plane[4 * i + 2]) << 8 | UInt32(plane[4 * i + 3]))
            }
        }
        for i in 0..<count {
            if h.mode == 2 {
                let index = Int(planes[0][i])
                for c in 0..<3 where h.palette.count >= 768 { values[i * stride + c] = Float(h.palette[c * 256 + index]) / 255 }
            } else {
                for c in 0..<comps {
                    let v = sample(planes[c], i)
                    values[i * stride + c] = h.mode == 4 ? 1 - v : v   // Photoshop stores CMYK as 1 − ink
                }
            }
            if alpha { values[i * stride + comps] = sample(planes[sourcePlanes], i) }
        }
        let depth = h.depth == 32 ? 32 : h.depth == 16 ? 16 : 8
        return Decoded(raster: Raster(width: h.width, height: h.height, space: space, hasAlpha: alpha, data: values, sourceDepth: depth,
                                      extended: depth == 32),
                       dpi: h.dpi, layerCount: abs(h.layerCount), xmp: h.xmp)
    }

    static func unpackBits(_ packed: ArraySlice<UInt8>, expected: Int) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(expected)
        var i = packed.startIndex
        while i < packed.endIndex, out.count < expected {
            let n = Int(Int8(bitPattern: packed[i])); i += 1
            if n >= 0 {
                let end = min(i + n + 1, packed.endIndex)
                out += packed[i..<end]; i = end
            } else if n != -128, i < packed.endIndex {
                out += [UInt8](repeating: packed[i], count: 1 - n); i += 1
            }
        }
        if out.count < expected { out += [UInt8](repeating: 0, count: expected - out.count) }
        return Array(out.prefix(expected))
    }

    private static func undoPrediction(_ plane: inout [UInt8], rowBytes: Int, height: Int, bytesPerSample: Int) {
        for y in 0..<height {
            let row = y * rowBytes
            switch bytesPerSample {
            case 2:
                var prev = 0
                for x in Swift.stride(from: 0, to: rowBytes, by: 2) {
                    let v = ((Int(plane[row + x]) << 8 | Int(plane[row + x + 1])) + prev) & 0xFFFF
                    plane[row + x] = UInt8(v >> 8); plane[row + x + 1] = UInt8(v & 0xFF); prev = v
                }
            case 4:
                // 32-bit: per row, the bytes are split into planes (all byte 0s, then 1s, …) and delta-coded.
                for x in 1..<rowBytes { plane[row + x] = plane[row + x] &+ plane[row + x - 1] }
                let w = rowBytes / 4
                let copy = Array(plane[row..<(row + rowBytes)])
                for x in 0..<w { for b in 0..<4 { plane[row + x * 4 + b] = copy[b * w + x] } }
            default:
                for x in 1..<rowBytes { plane[row + x] = plane[row + x] &+ plane[row + x - 1] }
            }
        }
    }

    // MARK: Writing

    /// A PSD of `raster` (values already quantised for `depth`, 8 or 16): one layer when there is alpha (so Photoshop
    /// shows transparency) plus the composite with straight colours (what ImageIO, Preview and Quick Look read).
    static func encode(_ raster: Raster, depth: Int, dpi: Double, exif: Data?, xmp: Data?, layerName: String) -> Data {
        let comps = raster.space.components
        let mode = raster.space.model == .gray ? 1 : raster.space.model == .cmyk ? 4 : 3
        let channels = raster.stride
        let w = raster.width, h = raster.height, s = raster.stride
        func plane(_ c: Int) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: w * h * depth / 8)
            for i in 0..<(w * h) {
                var v = min(max(raster.data[i * s + c], 0), 1)
                if mode == 4 && c < comps { v = 1 - v }
                if depth == 8 { out[i] = UInt8(v * 255 + 0.5) } else {
                    let q = UInt16(v * 65535 + 0.5)
                    out[2 * i] = UInt8(q >> 8); out[2 * i + 1] = UInt8(q & 0xFF)
                }
            }
            return out
        }
        let planes = (0..<channels).map(plane)
        var out: [UInt8] = Array("8BPS".utf8) + be16(1) + [UInt8](repeating: 0, count: 6)
        out += be16(channels) + be32(h) + be32(w) + be16(depth) + be16(mode)
        out += be32(0)   // colour mode data

        var resources: [UInt8] = []
        func resource(_ id: Int, _ body: [UInt8]) {
            resources += Array("8BIM".utf8) + be16(id) + [0, 0] + be32(body.count) + body
            if body.count % 2 == 1 { resources.append(0) }
        }
        let fixed = Int((dpi * 65536).rounded())
        resource(1005, be32(fixed) + be16(1) + be16(1) + be32(fixed) + be16(1) + be16(1))
        resource(1039, [UInt8](raster.space.icc))
        if let exif { resource(1058, [UInt8](exif)) }
        if let xmp { resource(1060, [UInt8](xmp)) }
        out += be32(resources.count) + resources

        if raster.hasAlpha {
            let ids = [-1] + Array(0..<comps)
            let channelData = ids.map { id in channelBlock(planes[id < 0 ? comps : id], width: w, height: h, depth: depth) }
            var record: [UInt8] = be32(0) + be32(0) + be32(h) + be32(w) + be16(ids.count)
            for (id, data) in zip(ids, channelData) { record += be16(id & 0xFFFF) + be32(data.count) }
            record += Array("8BIMnorm".utf8) + [255, 0, 0, 0]   // opacity, clipping, flags (visible), filler
            var name = [UInt8(min(layerName.utf8.count, 255))] + Array(layerName.utf8.prefix(255))
            while name.count % 4 != 0 { name.append(0) }
            let extra = be32(0) + be32(0) + name
            record += be32(extra.count) + extra
            var layerInfo = be16(0xFFFF) + record   // −1: the first alpha channel is the merged transparency
            for data in channelData { layerInfo += data }
            if layerInfo.count % 2 == 1 { layerInfo.append(0) }
            let section = be32(layerInfo.count) + layerInfo + be32(0)
            out += be32(section.count) + section
        } else {
            out += be32(0)
        }

        if depth == 8 {
            var counts: [UInt8] = [], packed: [UInt8] = []
            for p in planes {
                for y in 0..<h {
                    let row = packBits(p[(y * w)..<((y + 1) * w)])
                    counts += be16(row.count); packed += row
                }
            }
            out += be16(1) + counts + packed
        } else {
            out += be16(0)
            for p in planes { out += p }
        }
        return Data(out)
    }

    private static func channelBlock(_ plane: [UInt8], width: Int, height: Int, depth: Int) -> [UInt8] {
        guard depth == 8 else { return be16(0) + plane }
        var counts: [UInt8] = [], packed: [UInt8] = []
        for y in 0..<height {
            let row = packBits(plane[(y * width)..<((y + 1) * width)])
            counts += be16(row.count); packed += row
        }
        return be16(1) + counts + packed
    }

    static func packBits(_ row: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        var i = row.startIndex
        while i < row.endIndex {
            var run = 1
            while i + run < row.endIndex, run < 128, row[i + run] == row[i] { run += 1 }
            if run >= 2 {
                out.append(UInt8(bitPattern: Int8(1 - run))); out.append(row[i]); i += run; continue
            }
            var literal = 1
            while i + literal < row.endIndex, literal < 128 {
                if i + literal + 1 < row.endIndex, row[i + literal] == row[i + literal + 1] { break }
                literal += 1
            }
            out.append(UInt8(literal - 1)); out += row[i..<(i + literal)]; i += literal
        }
        return out
    }

    private static func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private static func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
}
