import Foundation

/// The `post` table: glyph names in, formats 2 and 3 out.
enum PostTable {
    static func glyphNames(_ d: [UInt8], glyphCount: Int) -> [String?] {
        var names = [String?](repeating: nil, count: glyphCount)
        guard let version = try? d.be32(0) else { return names }
        if version == 0x0001_0000 {
            for g in 0..<min(glyphCount, 258) { names[g] = GlyphNameTables.macStandard[g] }
        } else if version == 0x0002_0000, let n = try? d.be16(32) {
            var custom: [String] = []
            var o = 34 + n * 2
            while o < d.count {
                let len = Int(d[o])
                guard o + 1 + len <= d.count else { break }
                custom.append(String(decoding: d[(o + 1)..<(o + 1 + len)], as: UTF8.self))
                o += 1 + len
            }
            for g in 0..<min(n, glyphCount) {
                guard let index = try? d.be16(34 + g * 2) else { break }
                if index < 258 { names[g] = GlyphNameTables.macStandard[index] }
                else if index - 258 < custom.count { names[g] = custom[index - 258] }
            }
        }
        return names
    }

    /// `header` is the first 32 bytes of a source `post` (italic angle, underline, fixed pitch), or nil for defaults.
    static func build(names: [String], header: [UInt8]?, withNames: Bool, isFixedPitch: Bool) -> [UInt8] {
        var w = ByteWriter()
        if let header, header.count >= 32 { w.append(Array(header.prefix(32))) }
        else { w.u32(0); w.u32(0); w.i16(-100); w.i16(50); w.u32(isFixedPitch ? 1 : 0); w.u32(0); w.u32(0); w.u32(0); w.u32(0) }
        w.bytes.replaceSubrange(0..<4, with: withNames ? [0, 2, 0, 0] : [0, 3, 0, 0])
        guard withNames else { return w.bytes }
        w.u16(names.count)
        var custom: [[UInt8]] = []
        var indexes: [Int] = []
        var customIndex: [String: Int] = [:]
        for (g, name) in names.enumerated() {
            if g == 0 { indexes.append(0); continue }
            if let m = GlyphNameTables.macIndex[name] { indexes.append(m); continue }
            if let c = customIndex[name] { indexes.append(258 + c); continue }
            customIndex[name] = custom.count
            indexes.append(258 + custom.count)
            custom.append(Array(name.utf8.prefix(255)))
        }
        for i in indexes { w.u16(i) }
        for c in custom { w.u8(c.count); w.append(c) }
        return w.bytes
    }
}
