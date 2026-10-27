import Foundation

/// What a font reader or writer throws; the converters map it to a `ConversionError`.
enum FontError: Error, Equatable {
    case damaged(String)
    case unsupported(String)
}

extension Array where Element == UInt8 {
    /// Big-endian reads at an absolute offset; a read past the end means the table is damaged.
    func be8(_ o: Int) throws -> Int {
        guard o >= 0, o < count else { throw FontError.damaged("read past end") }
        return Int(self[o])
    }
    func be16(_ o: Int) throws -> Int {
        guard o >= 0, o + 2 <= count else { throw FontError.damaged("read past end") }
        return Int(self[o]) << 8 | Int(self[o + 1])
    }
    func beS16(_ o: Int) throws -> Int { let v = try be16(o); return v >= 0x8000 ? v - 0x10000 : v }
    func be32(_ o: Int) throws -> Int {
        guard o >= 0, o + 4 <= count else { throw FontError.damaged("read past end") }
        return Int(self[o]) << 24 | Int(self[o + 1]) << 16 | Int(self[o + 2]) << 8 | Int(self[o + 3])
    }
    func beS32(_ o: Int) throws -> Int { let v = try be32(o); return v >= 0x8000_0000 ? v - 0x1_0000_0000 : v }
    func le16(_ o: Int) throws -> Int {
        guard o >= 0, o + 2 <= count else { throw FontError.damaged("read past end") }
        return Int(self[o]) | Int(self[o + 1]) << 8
    }
    func le32(_ o: Int) throws -> Int {
        guard o >= 0, o + 4 <= count else { throw FontError.damaged("read past end") }
        return Int(self[o]) | Int(self[o + 1]) << 8 | Int(self[o + 2]) << 16 | Int(self[o + 3]) << 24
    }
    func tag(_ o: Int) throws -> String {
        guard o >= 0, o + 4 <= count else { throw FontError.damaged("read past end") }
        return String(decoding: self[o..<(o + 4)], as: UTF8.self)
    }
    func slice(_ o: Int, _ n: Int) throws -> [UInt8] {
        guard o >= 0, n >= 0, o + n <= count else { throw FontError.damaged("read past end") }
        return Array(self[o..<(o + n)])
    }
}

/// A sequential big-endian writer.
struct ByteWriter {
    var bytes: [UInt8] = []
    var count: Int { bytes.count }

    mutating func u8(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v >> 8)); bytes.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u32(_ v: Int) { u16(v >> 16); u16(v & 0xFFFF) }
    mutating func i16(_ v: Int) { u16(v & 0xFFFF) }
    mutating func i64(_ v: Int) { u32(Int(truncatingIfNeeded: v >> 32) & 0xFFFF_FFFF); u32(v & 0xFFFF_FFFF) }
    mutating func tag(_ s: String) { bytes.append(contentsOf: Array(s.utf8.prefix(4))); for _ in s.utf8.count..<4 { bytes.append(0x20) } }
    mutating func append(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func le16(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v)); bytes.append(UInt8(truncatingIfNeeded: v >> 8)) }
    mutating func le32(_ v: Int) { le16(v & 0xFFFF); le16((v >> 16) & 0xFFFF) }
    mutating func align4() { while bytes.count % 4 != 0 { bytes.append(0) } }
    /// Overwrites two bytes at `o` (patching a length or offset after the fact).
    mutating func patch16(_ o: Int, _ v: Int) { bytes[o] = UInt8(truncatingIfNeeded: v >> 8); bytes[o + 1] = UInt8(truncatingIfNeeded: v) }
}

func padded4(_ n: Int) -> Int { (n + 3) & ~3 }
