import Foundation
import SuperConverterCore

/// Cubic outlines → a CFF 1 table with Type 2 charstrings (no subroutines, no hints: every contour is `rmoveto`, then
/// `rlineto` and `rrcurveto` groups). Coordinates are written as 16.16 fixed numbers where they are not whole, so a
/// quadratic outline raised to cubic keeps its exact curve.
enum CFFBuilder {
    static func build(_ model: FontModel, postScriptName: String) throws -> [UInt8] {
        guard !model.glyphs.isEmpty else { throw FontError.unsupported("no glyphs") }
        var counts: [Int: Int] = [:]
        for g in model.glyphs { counts[g.advance, default: 0] += 1 }
        let defaultWidth = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 0

        var strings: [[UInt8]] = []
        var stringIndex: [String: Int] = [:]
        var charset = ByteWriter()
        charset.u8(0)
        for g in model.glyphs.dropFirst() {
            if let sid = GlyphNameTables.cffStandardIndex[g.name], sid <= 228 { charset.u16(sid); continue }
            if let known = stringIndex[g.name] { charset.u16(391 + known); continue }
            stringIndex[g.name] = strings.count
            charset.u16(391 + strings.count)
            strings.append(Array(g.name.utf8.prefix(127)))
        }

        let charStrings = model.glyphs.map { charString($0, defaultWidth: defaultWidth) }
        var box = (minX: Double.infinity, minY: Double.infinity, maxX: -Double.infinity, maxY: -Double.infinity)
        for g in model.glyphs { if let b = model.bounds(of: g) { box.minX = min(box.minX, b.minX); box.minY = min(box.minY, b.minY); box.maxX = max(box.maxX, b.maxX); box.maxY = max(box.maxY, b.maxY) } }
        if box.minX > box.maxX { box = (0, 0, 0, 0) }

        func fixedInt(_ v: Int) -> [UInt8] { [29, UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        func topDict(charsetOffset: Int, charStringsOffset: Int, privateOffset: Int, privateSize: Int) -> [UInt8] {
            var d: [UInt8] = []
            for v in [box.minX.rounded(.down), box.minY.rounded(.down), box.maxX.rounded(.up), box.maxY.rounded(.up)] { d += fixedInt(Int(v)) }
            d.append(5)
            d += fixedInt(charsetOffset); d.append(15)
            d += fixedInt(charStringsOffset); d.append(17)
            d += fixedInt(privateSize); d += fixedInt(privateOffset); d.append(18)
            return d
        }
        var priv: [UInt8] = []
        priv += fixedInt(defaultWidth); priv.append(20)
        priv += fixedInt(0); priv.append(21)

        let header: [UInt8] = [1, 0, 4, 4]
        let nameIndex = makeIndex([Array(postScriptName.utf8)])
        let stringIndexData = makeIndex(strings)
        let globalSubrs = makeIndex([])
        let topSize = makeIndex([topDict(charsetOffset: 0, charStringsOffset: 0, privateOffset: 0, privateSize: 0)]).count
        let charsetOffset = header.count + nameIndex.count + topSize + stringIndexData.count + globalSubrs.count
        let charStringsData = makeIndex(charStrings)
        let charStringsOffset = charsetOffset + charset.count
        let privateOffset = charStringsOffset + charStringsData.count
        let top = makeIndex([topDict(charsetOffset: charsetOffset, charStringsOffset: charStringsOffset, privateOffset: privateOffset, privateSize: priv.count)])

        return header + nameIndex + top + stringIndexData + globalSubrs + charset.bytes + charStringsData + priv
    }

    static func makeIndex(_ items: [[UInt8]]) -> [UInt8] {
        var w = ByteWriter()
        w.u16(items.count)
        guard !items.isEmpty else { return w.bytes }
        let total = items.reduce(1) { $0 + $1.count }
        let offSize = total < 0x100 ? 1 : total < 0x10000 ? 2 : total < 0x100_0000 ? 3 : 4
        w.u8(offSize)
        func offset(_ v: Int) { for k in stride(from: offSize - 1, through: 0, by: -1) { w.u8(v >> (8 * k)) } }
        var running = 1
        offset(running)
        for item in items { running += item.count; offset(running) }
        for item in items { w.append(item) }
        return w.bytes
    }

    private struct Encoder {
        var bytes: [UInt8] = []
        var x = 0, y = 0                 // current point, 16.16 fixed

        mutating func number(fixed n: Int) {
            if n % 65536 == 0 {
                let v = n / 65536
                switch v {
                case -107...107: bytes.append(UInt8(v + 139))
                case 108...1131: let t = v - 108; bytes += [UInt8(247 + t / 256), UInt8(t % 256)]
                case -1131...(-108): let t = -v - 108; bytes += [UInt8(251 + t / 256), UInt8(t % 256)]
                default:
                    let c = max(-32768, min(32767, v))
                    bytes += [28, UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
                }
            } else {
                let c = max(-0x7FFF_FFFF, min(0x7FFF_FFFF, n))
                bytes += [255, UInt8((c >> 24) & 0xFF), UInt8((c >> 16) & 0xFF), UInt8((c >> 8) & 0xFF), UInt8(c & 0xFF)]
            }
        }
        /// A delta to an absolute point, advancing the current point by exactly the encoded amount.
        mutating func delta(toX tx: Double, toY ty: Double) {
            let fx = Int((tx * 65536).rounded()), fy = Int((ty * 65536).rounded())
            number(fixed: fx - x); number(fixed: fy - y)
            x = fx; y = fy
        }
    }

    private static func charString(_ glyph: FontModel.Glyph, defaultWidth: Int) -> [UInt8] {
        var e = Encoder()
        var pendingWidth = glyph.advance != defaultWidth ? glyph.advance : nil
        for contour in glyph.contours {
            guard let path = Outlines.cubicPath(contour), !path.segs.isEmpty else { continue }
            if let w = pendingWidth { e.number(fixed: w * 65536); pendingWidth = nil }
            e.delta(toX: path.start.x, toY: path.start.y); e.bytes.append(21)
            var i = 0
            var current = path.start
            while i < path.segs.count {
                var count = 0
                if case .line = path.segs[i] {
                    while i + count < path.segs.count, count < 20, case .line(let p) = path.segs[i + count] {
                        e.delta(toX: p.x, toY: p.y); current = p; count += 1
                    }
                    e.bytes.append(5)
                } else {
                    curves: while i + count < path.segs.count, count < 7 {
                        let c1: Pt, c2: Pt, p: Pt
                        switch path.segs[i + count] {
                        case .line: break curves
                        case .quad(let q, let end): c1 = current + (q - current) * (2.0 / 3.0); c2 = end + (q - end) * (2.0 / 3.0); p = end
                        case .cubic(let a, let b, let end): c1 = a; c2 = b; p = end
                        }
                        e.delta(toX: c1.x, toY: c1.y); e.delta(toX: c2.x, toY: c2.y); e.delta(toX: p.x, toY: p.y)
                        current = p
                        count += 1
                    }
                    e.bytes.append(8)
                }
                i += count
            }
        }
        if let w = pendingWidth { e.number(fixed: w * 65536) }
        e.bytes.append(14)
        return e.bytes
    }
}
