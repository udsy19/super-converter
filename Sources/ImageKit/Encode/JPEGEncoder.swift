import Foundation

/// An own JPEG encoder for quality ≥ 90 (quality §2.3): ImageIO subsamples chroma 4:2:0 up to quality 99, and red 12 px
/// text on white then smears to a glyph-edge ΔE00 p95 of about 20 (quality §2.8 "Edge chroma" allows 6). The spec's
/// remedy is libjpeg-turbo at 4:4:4; it is not among the vendored libraries, so ImageKit encodes JPEG itself in that range:
/// 4:4:4 YCbCr (JFIF), the IJG quality scaling of the Annex K luminance table for all three components (with Annex K's
/// coarser chroma table the same text still measures p95 7.7; with the luminance table 5.8, for about 5 % more bytes),
/// optimal Huffman tables per scan, progressive by spectral selection (or baseline), the ICC profile in APP2, EXIF and
/// XMP in APP1. Written from ITU-T T.81.
enum JPEGEncoder {
    private static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    ]
    private static let lumaBase: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
    ]
    /// The DCT basis C[u][x] = c(u)/2 · cos((2x + 1)uπ/16), so F = C f Cᵀ is T.81's forward DCT.
    private static let basis: [Float] = (0..<64).map { i in
        let u = i / 8, x = i % 8
        return Float((u == 0 ? 1 / 2.0.squareRoot() : 1) / 2 * cos(Double(2 * x + 1) * Double(u) * .pi / 16))
    }

    /// IJG scaling of a base table for `quality` 1…100 (natural order).
    static func table(_ base: [Int], quality: Int) -> [Int] {
        let q = min(max(quality, 1), 100)
        let scale = q < 50 ? 5000 / q : 200 - 2 * q
        return base.map { min(max(($0 * scale + 50) / 100, 1), 255) }
    }

    /// `rgb`: 8-bit RGB (3 per pixel), top row first. `dpi` goes into JFIF; `app1` holds ready EXIF/XMP payloads.
    static func encode(rgb: [UInt8], width: Int, height: Int, quality: Int, progressive: Bool, icc: Data?, dpi: Double,
                       exif: Data?, xmp: Data?) -> Data {
        let qY = table(lumaBase, quality: quality), qC = qY
        let bw = (width + 7) / 8, bh = (height + 7) / 8
        // Quantised coefficients in zigzag order: [component][block][64].
        var coefficients = [[Int32]](repeating: [Int32](repeating: 0, count: bw * bh * 64), count: 3)
        rgb.withUnsafeBufferPointer { pixels in
            for comp in 0..<3 {
                let q = comp == 0 ? qY : qC
                let reciprocal = q.map { 1 / Float($0) }
                coefficients[comp].withUnsafeMutableBufferPointer { out in
                    let outBase = out.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: bh) { by in
                        var block = [Float](repeating: 0, count: 64), temp = [Float](repeating: 0, count: 64)
                        for bx in 0..<bw {
                            for y in 0..<8 {
                                let sy = min(by * 8 + y, height - 1)
                                for x in 0..<8 {
                                    let sx = min(bx * 8 + x, width - 1)
                                    let p = (sy * width + sx) * 3
                                    let r = Float(pixels[p]), g = Float(pixels[p + 1]), b = Float(pixels[p + 2])
                                    switch comp {
                                    case 0: block[y * 8 + x] = 0.299 * r + 0.587 * g + 0.114 * b - 128
                                    case 1: block[y * 8 + x] = -0.168736 * r - 0.331264 * g + 0.5 * b
                                    default: block[y * 8 + x] = 0.5 * r - 0.418688 * g - 0.081312 * b
                                    }
                                }
                            }
                            // Rows then columns: temp = C · block, block = temp · Cᵀ.
                            for u in 0..<8 { for x in 0..<8 {
                                var s: Float = 0
                                for k in 0..<8 { s += basis[u * 8 + k] * block[k * 8 + x] }
                                temp[u * 8 + x] = s
                            } }
                            let dst = outBase + (by * bw + bx) * 64
                            for z in 0..<64 {
                                let n = zigzag[z], u = n / 8, v = n % 8
                                var s: Float = 0
                                for k in 0..<8 { s += temp[u * 8 + k] * basis[v * 8 + k] }
                                dst[z] = Int32((s * reciprocal[n]).rounded())
                            }
                        }
                    }
                }
            }
        }

        var out = Data([0xFF, 0xD8])
        func segment(_ marker: UInt8, _ body: [UInt8]) {
            out.append(contentsOf: [0xFF, marker, UInt8((body.count + 2) >> 8), UInt8((body.count + 2) & 0xFF)])
            out.append(contentsOf: body)
        }
        let density = Int(dpi.rounded())
        segment(0xE0, Array("JFIF\0".utf8) + [1, 1, 1, UInt8(density >> 8), UInt8(density & 0xFF), UInt8(density >> 8), UInt8(density & 0xFF), 0, 0])
        if let exif, exif.count + 6 <= 65533 { segment(0xE1, Array("Exif\0\0".utf8) + [UInt8](exif)) }
        if let xmp, xmp.count + 29 <= 65533 { segment(0xE1, Array("http://ns.adobe.com/xap/1.0/\0".utf8) + [UInt8](xmp)) }
        if let icc {
            let chunk = 65519, count = (icc.count + chunk - 1) / chunk
            for i in 0..<count {
                let part = icc[(icc.startIndex + i * chunk)..<(icc.startIndex + min((i + 1) * chunk, icc.count))]
                segment(0xE2, Array("ICC_PROFILE\0".utf8) + [UInt8(i + 1), UInt8(count)] + [UInt8](part))
            }
        }
        segment(0xDB, [0] + zigzag.map { UInt8(qY[$0]) } + [1] + zigzag.map { UInt8(qC[$0]) })
        segment(progressive ? 0xC2 : 0xC0, [8, UInt8(height >> 8), UInt8(height & 0xFF), UInt8(width >> 8), UInt8(width & 0xFF), 3,
                                            1, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1])

        let blocks = bw * bh
        let scans: [Scan] = progressive
            ? [Scan(components: [0, 1, 2], start: 0, end: 0), Scan(components: [0], start: 1, end: 5), Scan(components: [2], start: 1, end: 63),
               Scan(components: [1], start: 1, end: 63), Scan(components: [0], start: 6, end: 63)]
            : [Scan(components: [0, 1, 2], start: 0, end: 63)]
        for scan in scans {
            // Pass 1 counts symbols per table; pass 2 writes with the optimal codes (T.81 Annex K.2).
            var counter = Coder(mode: .count)
            scan.run(coefficients, blocks: blocks, coder: &counter)
            var tables: [Int: HuffmanTable] = [:]
            var dht: [UInt8] = []
            for (key, frequencies) in counter.frequencies.sorted(by: { $0.key < $1.key }) {
                let table = HuffmanTable(frequencies: frequencies)
                tables[key] = table
                dht += [UInt8((key >> 4) << 4 | (key & 0xF))] + table.bits + table.values
            }
            if !dht.isEmpty { segment(0xC4, dht) }
            var sos: [UInt8] = [UInt8(scan.components.count)]
            for c in scan.components { sos += [UInt8(c + 1), UInt8((c == 0 ? 0 : 1) << 4 | (c == 0 ? 0 : 1))] }
            sos += [UInt8(scan.start), UInt8(scan.end), 0]
            segment(0xDA, sos)
            var writer = Coder(mode: .write(tables))
            scan.run(coefficients, blocks: blocks, coder: &writer)
            writer.finish()
            out.append(contentsOf: writer.bytes)
        }
        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }

    private struct Scan {
        var components: [Int]
        var start: Int
        var end: Int

        /// Table keys: class (0 DC, 1 AC) << 4 | table id (0 luma, 1 chroma).
        func run(_ coefficients: [[Int32]], blocks: Int, coder: inout Coder) {
            var predictors = [Int32](repeating: 0, count: 3)
            var eobRun = 0
            func flushEOB(_ key: Int) {
                guard eobRun > 0 else { return }
                let bits = Int.bitWidth - 1 - eobRun.leadingZeroBitCount
                coder.symbol(key, bits << 4)
                if bits > 0 { coder.raw(eobRun & ((1 << bits) - 1), count: bits) }
                eobRun = 0
            }
            for b in 0..<blocks {
                for c in components {
                    let base = b * 64
                    let tableID = c == 0 ? 0 : 1
                    if start == 0 {
                        let dc = coefficients[c][base]
                        let diff = Int(dc - predictors[c])
                        predictors[c] = dc
                        let size = magnitude(diff)
                        coder.symbol(0 << 4 | tableID, size)
                        if size > 0 { coder.raw(diff < 0 ? diff - 1 : diff, count: size) }
                    }
                    guard end > 0 else { continue }
                    let key = 1 << 4 | tableID
                    var run = 0
                    for k in max(start, 1)...end {
                        let v = Int(coefficients[c][base + k])
                        if v == 0 { run += 1; continue }
                        if components.count == 1 { flushEOB(key) }
                        while run > 15 { coder.symbol(key, 0xF0); run -= 16 }
                        let size = magnitude(v)
                        coder.symbol(key, run << 4 | size)
                        coder.raw(v < 0 ? v - 1 : v, count: size)
                        run = 0
                    }
                    if run > 0 {
                        if components.count == 1 {
                            eobRun += 1
                            if eobRun == 0x7FFF { flushEOB(key) }
                        } else {
                            coder.symbol(key, 0x00)
                        }
                    }
                }
            }
            if let c = components.first, components.count == 1 { flushEOB(1 << 4 | (c == 0 ? 0 : 1)) }
        }

        private func magnitude(_ v: Int) -> Int { v == 0 ? 0 : Int.bitWidth - abs(v).leadingZeroBitCount }
    }

    private struct HuffmanTable {
        var bits: [UInt8] = []     // counts of codes of length 1…16
        var values: [UInt8] = []   // symbols by increasing code length
        var codes = [Int](repeating: 0, count: 256)
        var lengths = [Int](repeating: 0, count: 256)

        /// T.81 Annex K.2: code lengths from frequencies, limited to 16 bits, no all-ones code.
        init(frequencies input: [Int]) {
            var freq = input + [1]   // index 256 reserves one code point
            var codesize = [Int](repeating: 0, count: 257)
            var others = [Int](repeating: -1, count: 257)
            while true {
                var c1 = -1, c2 = -1, v1 = Int.max, v2 = Int.max
                for i in 0...256 where freq[i] > 0 && freq[i] <= v1 { v1 = freq[i]; c1 = i }
                for i in 0...256 where freq[i] > 0 && freq[i] <= v2 && i != c1 { v2 = freq[i]; c2 = i }
                if c2 < 0 { break }
                freq[c1] += freq[c2]; freq[c2] = 0
                codesize[c1] += 1
                while others[c1] >= 0 { c1 = others[c1]; codesize[c1] += 1 }
                others[c1] = c2
                codesize[c2] += 1
                while others[c2] >= 0 { c2 = others[c2]; codesize[c2] += 1 }
            }
            var counts = [Int](repeating: 0, count: 33)
            for i in 0...256 where codesize[i] > 0 { counts[min(codesize[i], 32)] += 1 }
            var i = 32
            while i > 16 {
                while counts[i] > 0 {
                    var j = i - 2
                    while counts[j] == 0 { j -= 1 }
                    counts[i] -= 2; counts[i - 1] += 1; counts[j + 1] += 2; counts[j] -= 1
                }
                i -= 1
            }
            i = 16
            while counts[i] == 0 { i -= 1 }
            counts[i] -= 1   // drop the reserved code point
            bits = (1...16).map { UInt8(counts[$0]) }
            let symbols = (0..<256).filter { codesize[$0] > 0 }.sorted { (codesize[$0], $0) < (codesize[$1], $1) }
            values = symbols.map { UInt8($0) }
            var code = 0, k = 0
            for length in 1...16 {
                for _ in 0..<counts[length] {
                    let s = symbols[k]
                    codes[s] = code; lengths[s] = length
                    code += 1; k += 1
                }
                code <<= 1
            }
        }
    }

    private struct Coder {
        enum Mode { case count, write([Int: HuffmanTable]) }
        let mode: Mode
        var frequencies: [Int: [Int]] = [:]
        var bytes: [UInt8] = []
        private var buffer = 0, filled = 0

        init(mode: Mode) { self.mode = mode }

        mutating func symbol(_ table: Int, _ value: Int) {
            switch mode {
            case .count: frequencies[table, default: [Int](repeating: 0, count: 256)][value] += 1
            case .write(let tables):
                let t = tables[table]!
                raw(t.codes[value], count: t.lengths[value])
            }
        }

        mutating func raw(_ value: Int, count: Int) {
            guard case .write = mode, count > 0 else { return }
            buffer = buffer << count | (value & ((1 << count) - 1))
            filled += count
            while filled >= 8 {
                let byte = UInt8((buffer >> (filled - 8)) & 0xFF)
                bytes.append(byte)
                if byte == 0xFF { bytes.append(0) }
                filled -= 8
            }
            buffer &= (1 << filled) - 1
        }

        /// Pads the last byte with one bits.
        mutating func finish() {
            if filled > 0 { raw((1 << (8 - filled)) - 1, count: 8 - filled) }
        }
    }
}
