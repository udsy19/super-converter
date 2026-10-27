import Foundation

/// Embedded OpenType (W3C EOT submission): a little-endian header around the font, optionally XOR-obfuscated with 0x50.
/// Written uncompressed (version 0x00020001); MicroType Express compressed files are recognised but not decoded yet
/// (formats §7, rank P3).
enum EOT {
    static let xorFlag = 0x1000_0000
    static let compressedFlag = 0x4

    static func read(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count > 82, try bytes.le16(34) == 0x504C else { throw FontError.damaged("not an EOT file") }
        let total = min(try bytes.le32(0), bytes.count), dataSize = try bytes.le32(4), flags = try bytes.le32(12)
        guard dataSize > 0, dataSize <= total else { throw FontError.damaged("EOT font data size") }
        if flags & compressedFlag != 0 { throw FontError.unsupported("This EOT font uses MicroType Express compression, which can’t be read yet.") }
        var font = try bytes.slice(total - dataSize, dataSize)
        if flags & xorFlag != 0 { for i in font.indices { font[i] ^= 0x50 } }
        return font
    }

    static func write(sfnt: [UInt8], tables: [String: [UInt8]], names: [Int: String]) throws -> [UInt8] {
        let os2 = tables["OS/2"] ?? []
        func os2Value(_ o: Int, _ size: Int) -> Int { size == 2 ? ((try? os2.be16(o)) ?? 0) : ((try? os2.be32(o)) ?? 0) }
        var w = ByteWriter()
        w.le32(0)
        w.le32(sfnt.count); w.le32(0x0002_0001); w.le32(0)
        w.append(os2.count >= 42 ? Array(os2[32..<42]) : [UInt8](repeating: 0, count: 10))
        w.u8(1)
        w.u8(os2Value(62, 2) & 1)
        w.le32(os2Value(4, 2) == 0 ? 400 : os2Value(4, 2))
        w.le16(os2Value(8, 2)); w.le16(0x504C)
        for k in 0..<4 { w.le32(os2.count >= 58 ? os2Value(42 + 4 * k, 4) : 0) }
        for k in 0..<2 { w.le32(os2.count >= 86 ? os2Value(78 + 4 * k, 4) : 0) }
        w.le32((try? tables["head"]?.be32(8)) ?? 0)
        for _ in 0..<4 { w.le32(0) }
        w.le16(0)
        for id in [1, 2, 5, 4] {
            let utf16 = Array((names[id] ?? "").utf16)
            w.le16(utf16.count * 2)
            for u in utf16 { w.le16(Int(u)) }
            w.le16(0)
        }
        w.le16(0)
        w.append(sfnt)
        let size = w.count
        w.bytes.replaceSubrange(0..<4, with: [UInt8(size & 0xFF), UInt8((size >> 8) & 0xFF), UInt8((size >> 16) & 0xFF), UInt8((size >> 24) & 0xFF)])
        return w.bytes
    }
}
