import Foundation
import SuperConverterCore

/// Photoshop files (Adobe's published "Photoshop File Formats Specification"), PSD and PSB ("big", version 2: 8-byte
/// lengths, 4-byte RLE counts). Reading: a file whose one layer covers the canvas is read from that layer (straight
/// colour, exact); otherwise from the composite, whose colours Photoshop mattes against white when the document is
/// transparent, so they are un-matted. Writing (quality §2.3): one layer plus the composite, 8 or 16-bit, ICC.
/// ImageIO's own PSD writer stores semi-transparent colours premultiplied and reads them back as straight, so ImageKit
/// reads and writes PSD itself.
enum PSDCodec {
    // MARK: Reading

    struct Decoded { var raster: Raster; var dpi: Double; var layerCount: Int; var xmp: Data? }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0
        mutating func u8() throws -> Int { guard i >= 0, i < bytes.count else { throw ConversionError.damaged("psd") }; i += 1; return Int(bytes[i - 1]) }
        mutating func u16() throws -> Int { try u8() << 8 | u8() }
        mutating func u32() throws -> Int { try u16() << 16 | u16() }
        mutating func u64() throws -> Int { try u32() << 32 | u32() }
        mutating func skip(_ n: Int) throws { guard i >= 0, n >= 0, n <= bytes.count - i else { throw ConversionError.damaged("psd") }; i += n }
        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard i >= 0, n >= 0, n <= bytes.count - i else { throw ConversionError.damaged("psd") }
            defer { i += n }
            return bytes[i..<(i + n)]
        }
    }

    private struct Header {
        var version: Int, channels: Int, height: Int, width: Int, depth: Int, mode: Int
        var palette: [UInt8], icc: Data?, dpi: Double, xmp: Data?, layerCount: Int, imageDataOffset: Int
        /// Channel id → the byte range of its data, when the file is one visible Normal layer covering the canvas.
        var singleLayer: [Int: Range<Int>]?
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
        // A PSB length is 64-bit: a damaged one can be negative here or past the end of the file.
        guard r.i >= 0, layerSectionLength >= 0, layerSectionLength <= bytes.count - r.i else { throw ConversionError.damaged("psd") }
        let layerSectionEnd = r.i + layerSectionLength
        var layerCount = 0
        var singleLayer: [Int: Range<Int>]?
        if layerSectionLength > 0, (version == 2 ? try r.u64() : try r.u32()) > 0 {
            layerCount = Int(Int16(truncatingIfNeeded: try r.u16()))
            if abs(layerCount) == 1 {
                // A malformed record only costs the shortcut: the composite is read instead.
                singleLayer = try? { () throws -> [Int: Range<Int>]? in
                    let top = try r.u32(), left = try r.u32(), bottom = try r.u32(), right = try r.u32()
                    var lengths: [(Int, Int)] = []
                    for _ in 0..<(try r.u16()) {
                        let id = Int(Int16(truncatingIfNeeded: try r.u16()))
                        let length = version == 2 ? try r.u64() : try r.u32()
                        guard length >= 0, length <= bytes.count else { return nil }
                        lengths.append((id, length))
                    }
                    try r.skip(4)
                    let blend = String(decoding: try r.take(4), as: UTF8.self)
                    let opacity = try r.u8(); _ = try r.u8()
                    let flags = try r.u8(); _ = try r.u8()
                    try r.skip(try r.u32())
                    var offset = r.i, ranges: [Int: Range<Int>] = [:]
                    for (id, length) in lengths { ranges[id] = offset..<(offset + length); offset += length }
                    guard top == 0, left == 0, bottom == height, right == width, opacity == 255, blend == "norm", flags & 2 == 0,
                          offset <= min(bytes.count, layerSectionEnd) else { return nil }
                    return ranges
                }()
            }
        }
        return Header(version: version, channels: channels, height: height, width: width, depth: depth, mode: mode, palette: palette,
                      icc: icc, dpi: dpi, xmp: xmp, layerCount: layerCount, imageDataOffset: layerSectionEnd, singleLayer: singleLayer)
    }

    static func decode(_ data: Data) throws -> Decoded {
        let bytes = [UInt8](data)
        let h = try header(bytes)
        // 300,000 pixels a side is the PSB maximum (30,000 for PSD).
        guard (1...300_000).contains(h.width), (1...300_000).contains(h.height), h.width * h.height < 1 << 31, [1, 8, 16, 32].contains(h.depth) else {
            throw ConversionError.damaged("psd")
        }
        let bytesPerSample = h.depth == 1 ? 0 : h.depth / 8
        let rowBytes = h.depth == 1 ? (h.width + 7) / 8 : h.width * bytesPerSample
        let planeBytes = rowBytes * h.height
        let colourPlanes = h.mode == 2 ? 1 : h.mode == 4 ? 4 : h.mode == 3 ? 3 : 1
        var planes: [[UInt8]] = []
        var fromLayer = false
        if let layer = h.singleLayer, h.mode != 2, (0..<colourPlanes).allSatisfy({ layer[$0] != nil }) {
            // Colour channels 0…n−1, then the transparency channel (−1) where there is one.
            let ids = Array(0..<colourPlanes) + (layer[-1] != nil ? [-1] : [])
            if let read = try? ids.map({ id -> [UInt8] in
                var c = Reader(bytes: bytes, i: layer[id]!.lowerBound)
                return try readPlanes(&c, count: 1, compression: try c.u16(), version: h.version, rowBytes: rowBytes, height: h.height,
                                      bytesPerSample: bytesPerSample)[0]
            }) {
                planes = read
                fromLayer = true
            }
        }
        if !fromLayer {
            var r = Reader(bytes: bytes, i: h.imageDataOffset)
            planes = try readPlanes(&r, count: h.channels, compression: try r.u16(), version: h.version, rowBytes: rowBytes, height: h.height,
                                    bytesPerSample: bytesPerSample)
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
        // A layer's transparency channel, or (composite) a negative layer count: the first extra channel is the merged
        // transparency; other extra channels are masks.
        let alpha = planes.count > sourcePlanes && (fromLayer || h.layerCount < 0)
        let matted = alpha && !fromLayer
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
            if alpha {
                let a = sample(planes[sourcePlanes], i)
                values[i * stride + comps] = a
                if matted {   // white is no ink in CMYK and full value elsewhere
                    for c in 0..<comps {
                        let m = values[i * stride + c]
                        values[i * stride + c] = a > 0 ? min(max(h.mode == 4 ? m / a : (m - (1 - a)) / a, 0), 1) : 0
                    }
                }
            }
        }
        let depth = h.depth == 32 ? 32 : h.depth == 16 ? 16 : 8
        return Decoded(raster: Raster(width: h.width, height: h.height, space: space, hasAlpha: alpha, data: values, sourceDepth: depth,
                                      extended: depth == 32),
                       dpi: h.dpi, layerCount: abs(h.layerCount), xmp: h.xmp)
    }

    /// `count` planes of channel data with the given compression (0 raw, 1 RLE, 2 zip, 3 zip with prediction).
    private static func readPlanes(_ r: inout Reader, count: Int, compression: Int, version: Int, rowBytes: Int, height: Int,
                                   bytesPerSample: Int) throws -> [[UInt8]] {
        let planeBytes = rowBytes * height
        switch compression {
        case 0:
            return try (0..<count).map { _ in Array(try r.take(planeBytes)) }
        case 1:
            var counts: [Int] = []
            for _ in 0..<(count * height) { counts.append(version == 2 ? try r.u32() : try r.u16()) }
            // PackBits makes at most 64 bytes of every byte it reads (128 from a two-byte run), so rows that cannot fill the
            // canvas they claim are damage, not a reason to allocate it.
            guard planeBytes * count <= 64 * counts.reduce(0, +) else { throw ConversionError.damaged("psd") }
            return try (0..<count).map { c in
                var plane = [UInt8](); plane.reserveCapacity(planeBytes)
                for y in 0..<height { plane += unpackBits(try r.take(counts[c * height + y]), expected: rowBytes) }
                return plane
            }
        case 2, 3:
            // Deflate expands at most 1032 : 1.
            guard planeBytes * count <= (r.bytes.count - r.i) * 1032,
                  let all = Zlib.decompress(Data(r.bytes[r.i...]), expectedSize: planeBytes * count) else { throw ConversionError.damaged("psd") }
            return (0..<count).map { c in
                var plane = [UInt8](all[(c * planeBytes)..<((c + 1) * planeBytes)])
                if compression == 3 { undoPrediction(&plane, rowBytes: rowBytes, height: height, bytesPerSample: bytesPerSample) }
                return plane
            }
        default:
            throw ConversionError.damaged("psd")
        }
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

    /// A PSD of `raster` (values already quantised for `depth`, 8 or 16): with alpha, one layer holding the straight
    /// colours and transparency (what Photoshop edits) plus the composite matted against white (Photoshop's convention).
    static func encode(_ raster: Raster, depth: Int, dpi: Double, exif: Data?, xmp: Data?, layerName: String) -> Data {
        let comps = raster.space.components
        let mode = raster.space.model == .gray ? 1 : raster.space.model == .cmyk ? 4 : 3
        let channels = raster.stride
        let w = raster.width, h = raster.height, s = raster.stride
        func plane(_ c: Int, matted: Bool) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: w * h * depth / 8)
            for i in 0..<(w * h) {
                var v = min(max(raster.data[i * s + c], 0), 1)
                if matted && c < comps {
                    let a = min(max(raster.data[i * s + comps], 0), 1)
                    v = v * a + (1 - a)
                }
                if mode == 4 && c < comps { v = 1 - v }
                if depth == 8 { out[i] = UInt8(v * 255 + 0.5) } else {
                    let q = UInt16(v * 65535 + 0.5)
                    out[2 * i] = UInt8(q >> 8); out[2 * i + 1] = UInt8(q & 0xFF)
                }
            }
            return out
        }
        let planes = (0..<channels).map { plane($0, matted: raster.hasAlpha) }
        let layerPlanes = raster.hasAlpha ? (0..<channels).map { plane($0, matted: false) } : planes
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
            let channelData = ids.map { id in channelBlock(layerPlanes[id < 0 ? comps : id], width: w, height: h, depth: depth) }
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
