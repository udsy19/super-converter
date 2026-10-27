import Foundation

/// The `cmap` table: Unicode subtables (formats 0, 4, 6, 10, 12) in, formats 4 and 12 out.
enum CmapTable {
    static func parse(_ d: [UInt8]) throws -> [UInt32: Int] {
        let count = try d.be16(2)
        var unicode: [(rank: Int, offset: Int)] = []
        for i in 0..<count {
            let r = 4 + i * 8
            let platform = try d.be16(r), encoding = try d.be16(r + 2), offset = try d.be32(r + 4)
            switch (platform, encoding) {
            case (3, 10), (0, 4), (0, 6): unicode.append((0, offset))
            case (3, 1), (0, 0), (0, 1), (0, 2), (0, 3): unicode.append((1, offset))
            default: break
            }
        }
        var map: [UInt32: Int] = [:]
        for sub in unicode.sorted(by: { $0.rank > $1.rank }) {
            for (code, glyph) in try subtable(d, at: sub.offset) where glyph != 0 { map[code] = glyph }
        }
        return map
    }

    private static func subtable(_ d: [UInt8], at o: Int) throws -> [(UInt32, Int)] {
        var out: [(UInt32, Int)] = []
        switch try d.be16(o) {
        case 0:
            for c in 0..<256 { let g = try d.be8(o + 6 + c); if g != 0 { out.append((UInt32(c), g)) } }
        case 4:
            let segX2 = try d.be16(o + 6)
            let seg = segX2 / 2
            let ends = o + 14, starts = ends + segX2 + 2, deltas = starts + segX2, ranges = deltas + segX2
            for s in 0..<seg {
                let end = try d.be16(ends + s * 2), start = try d.be16(starts + s * 2)
                let delta = try d.be16(deltas + s * 2), rangeOffset = try d.be16(ranges + s * 2)
                guard start <= end else { continue }
                guard out.count < 0x12_0000 else { throw FontError.damaged("cmap too large") }
                for c in start...end where c != 0xFFFF {
                    var g: Int
                    if rangeOffset == 0 { g = (c + delta) & 0xFFFF }
                    else {
                        let at = ranges + s * 2 + rangeOffset + (c - start) * 2
                        guard at + 2 <= d.count else { continue }
                        g = try d.be16(at)
                        if g != 0 { g = (g + delta) & 0xFFFF }
                    }
                    if g != 0 { out.append((UInt32(c), g)) }
                }
            }
        case 6:
            let first = try d.be16(o + 6), n = try d.be16(o + 8)
            for k in 0..<n { let g = try d.be16(o + 10 + k * 2); if g != 0 { out.append((UInt32(first + k), g)) } }
        case 10:
            let first = try d.be32(o + 12), n = try d.be32(o + 16)
            guard n < 0x11_0000 else { break }
            for k in 0..<n { let g = try d.be16(o + 20 + k * 2); if g != 0 { out.append((UInt32(first + k), g)) } }
        case 12:
            let groups = try d.be32(o + 12)
            guard groups < 0x20_0000 else { throw FontError.damaged("cmap groups") }
            for k in 0..<groups {
                let g = o + 16 + k * 12
                let start = try d.be32(g), end = try d.be32(g + 4), glyph = try d.be32(g + 8)
                guard start <= end, end <= 0x10FFFF, end - start < 0x11_0000 else { continue }
                guard out.count < 0x12_0000 else { throw FontError.damaged("cmap too large") }
                for c in start...end { out.append((UInt32(c), glyph + (c - start))) }
            }
        default: break
        }
        return out
    }

    /// Format 4 (and 12 for code points beyond the BMP) under the Windows and Unicode platforms.
    static func build(_ map: [UInt32: Int]) -> [UInt8] {
        let bmp = map.filter { $0.key < 0xFFFF }.sorted { $0.key < $1.key }
        let f4 = format4(bmp.map { (Int($0.key), $0.value) })
        var records: [(Int, Int, [UInt8])] = [(0, 3, f4), (3, 1, f4)]
        if map.keys.contains(where: { $0 > 0xFFFF }) {
            let f12 = format12(map.sorted { $0.key < $1.key }.map { (Int($0.key), $0.value) })
            records += [(0, 4, f12), (3, 10, f12)]
        }
        records.sort { ($0.0, $0.1) < ($1.0, $1.1) }
        var w = ByteWriter()
        w.u16(0); w.u16(records.count)
        var offset = 4 + records.count * 8
        var seen: [[UInt8]: Int] = [:]
        var bodies: [[UInt8]] = []
        for r in records {
            if let existing = seen[r.2] { w.u16(r.0); w.u16(r.1); w.u32(existing); continue }
            w.u16(r.0); w.u16(r.1); w.u32(offset)
            seen[r.2] = offset
            bodies.append(r.2)
            offset += r.2.count
        }
        for b in bodies { w.append(b) }
        return w.bytes
    }

    private static func format4(_ pairs: [(Int, Int)]) -> [UInt8] {
        struct Segment { var start: Int, end: Int, delta: Int?, glyphs: [Int] }
        var segments: [Segment] = []
        for (code, glyph) in pairs {
            if var last = segments.last, last.end + 1 == code {
                last.end = code
                last.glyphs.append(glyph)
                if let delta = last.delta, glyph - code != delta { last.delta = nil }
                segments[segments.count - 1] = last
            } else {
                segments.append(Segment(start: code, end: code, delta: glyph - code, glyphs: [glyph]))
            }
        }
        segments.append(Segment(start: 0xFFFF, end: 0xFFFF, delta: 1, glyphs: [0]))
        let n = segments.count
        var searchRange = 1, entrySelector = 0
        while searchRange * 2 <= n { searchRange *= 2; entrySelector += 1 }
        var glyphArray: [Int] = []
        var ends = ByteWriter(), starts = ByteWriter(), deltas = ByteWriter(), ranges = ByteWriter()
        for (i, s) in segments.enumerated() {
            ends.u16(s.end); starts.u16(s.start)
            if let delta = s.delta {
                deltas.i16(delta & 0xFFFF); ranges.u16(0)
            } else {
                deltas.u16(0)
                ranges.u16((n - i) * 2 + glyphArray.count * 2)
                glyphArray += s.glyphs
            }
        }
        var w = ByteWriter()
        let length = 16 + n * 8 + glyphArray.count * 2
        w.u16(4); w.u16(length); w.u16(0); w.u16(n * 2); w.u16(searchRange * 2); w.u16(entrySelector); w.u16(n * 2 - searchRange * 2)
        w.append(ends.bytes); w.u16(0); w.append(starts.bytes); w.append(deltas.bytes); w.append(ranges.bytes)
        for g in glyphArray { w.u16(g) }
        return w.bytes
    }

    private static func format12(_ pairs: [(Int, Int)]) -> [UInt8] {
        var groups: [(Int, Int, Int)] = []
        for (code, glyph) in pairs {
            if let last = groups.last, last.1 + 1 == code, last.2 + (code - last.0) == glyph {
                groups[groups.count - 1].1 = code
            } else {
                groups.append((code, code, glyph))
            }
        }
        var w = ByteWriter()
        w.u16(12); w.u16(0); w.u32(16 + groups.count * 12); w.u32(0); w.u32(groups.count)
        for g in groups { w.u32(g.0); w.u32(g.1); w.u32(g.2) }
        return w.bytes
    }
}
