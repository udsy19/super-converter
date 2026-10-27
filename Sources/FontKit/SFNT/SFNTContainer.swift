import Foundation

/// The table directory of an OpenType/TrueType file: parsing and serialising (OpenType spec, "organization of an
/// OpenType font"). Tables are opaque byte arrays here; `SFNTReader` and `SFNTWriter` give them meaning.
struct SFNTTables {
    /// `0x00010000` (TrueType outlines), `OTTO` (CFF), `true`.
    var flavor: Int
    var tables: [String: [UInt8]]

    static let trueTypeFlavor = 0x0001_0000
    static let cffFlavor = 0x4F54_544F
}

enum SFNTContainer {
    static func parse(_ bytes: [UInt8]) throws -> SFNTTables {
        guard bytes.count >= 12 else { throw FontError.damaged("too short") }
        var base = 0
        if try bytes.tag(0) == "ttcf" { base = try bytes.be32(12) }     // a collection: the first font is converted
        let flavor = try bytes.be32(base)
        guard [0x0001_0000, SFNTTables.cffFlavor, 0x7472_7565].contains(flavor) else { throw FontError.damaged("not an SFNT font") }
        let count = try bytes.be16(base + 4)
        guard count > 0, count < 200 else { throw FontError.damaged("table count") }
        var tables: [String: [UInt8]] = [:]
        for i in 0..<count {
            let entry = base + 12 + 16 * i
            let tag = try bytes.tag(entry)
            let offset = try bytes.be32(entry + 8)
            var length = try bytes.be32(entry + 12)
            guard offset <= bytes.count else { throw FontError.damaged("table \(tag) outside the file") }
            length = min(length, bytes.count - offset)
            tables[tag] = try bytes.slice(offset, length)
        }
        return SFNTTables(flavor: flavor, tables: tables)
    }

    static func checksum(_ b: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var i = 0
        while i < b.count {
            var word: UInt32 = 0
            for k in 0..<4 { word = word << 8 | (i + k < b.count ? UInt32(b[i + k]) : 0) }
            sum = sum &+ word
            i += 4
        }
        return sum
    }

    /// The tables with the checksum adjustment written into `head`.
    static func adjusted(flavor: Int, tables: [(String, [UInt8])]) -> [(String, [UInt8])] {
        var out = tables
        guard let h = out.firstIndex(where: { $0.0 == "head" }), out[h].1.count >= 12 else { return out }
        for k in 8..<12 { out[h].1[k] = 0 }
        let adj = 0xB1B0_AFBA &- checksum(serialize(flavor: flavor, tables: out, adjusting: false))
        for k in 0..<4 { out[h].1[8 + k] = UInt8(truncatingIfNeeded: adj >> UInt32(24 - 8 * k)) }
        return out
    }

    /// Serialises sorted by tag, 4-byte aligned, with the directory checksums. With `adjusting` the `head` adjustment is set.
    static func serialize(flavor: Int, tables: [(String, [UInt8])], adjusting: Bool = true) -> [UInt8] {
        let list = (adjusting ? adjusted(flavor: flavor, tables: tables) : tables).sorted { $0.0 < $1.0 }
        let n = list.count
        var searchRange = 1, entrySelector = 0
        while searchRange * 2 <= n { searchRange *= 2; entrySelector += 1 }
        var w = ByteWriter()
        w.u32(flavor); w.u16(n); w.u16(searchRange * 16); w.u16(entrySelector); w.u16(n * 16 - searchRange * 16)
        var offset = 12 + 16 * n
        for (tag, data) in list {
            var summed = data
            if tag == "head", summed.count >= 12 { for k in 8..<12 { summed[k] = 0 } }
            w.tag(tag); w.u32(Int(checksum(summed))); w.u32(offset); w.u32(data.count)
            offset += padded4(data.count)
        }
        for (_, data) in list { w.append(data); w.align4() }
        return w.bytes
    }
}
