import Foundation

// DXF is a stream of (group code, value) pairs, as ASCII lines or as the binary form (formats §3.2). This file turns either
// into `[DXFGroup]`; everything above it (DXFReader) deals only in groups.

struct DXFGroup {
    var code: Int
    var text: String

    /// A real value; "nan", "inf" and anything unreadable are 0, since every DXF real is finite.
    var double: Double {
        let v = Double(text.trimmingCharacters(in: .whitespaces)) ?? 0
        return v.isFinite ? v : 0
    }
    /// An integer value. No group the reader uses holds more than 32 bits, so anything outside that range is damage and
    /// reads as 0, which also keeps counts multiplied together (mesh M × N, array rows × columns) from overflowing.
    var int: Int {
        let t = text.trimmingCharacters(in: .whitespaces)
        return Int(t).map(DXFGroup.integer) ?? DXFGroup.integer(Double(t) ?? 0)
    }

    static func integer(_ v: Int) -> Int { Int32(exactly: v).map(Int.init) ?? 0 }
    static func integer(_ v: Double) -> Int { Int32(exactly: v.rounded(.towardZero)).map(Int.init) ?? 0 }
}

enum DXFGroups {
    static let binarySentinel = Array("AutoCAD Binary DXF\r\n\u{1A}\0".utf8)

    /// The groups of a DXF file, ASCII or binary. Throws nothing: an unreadable stream yields the groups read so far.
    static func parse(_ data: Data) -> [DXFGroup] {
        let bytes = [UInt8](data)
        if bytes.count >= binarySentinel.count, Array(bytes[0..<binarySentinel.count]) == binarySentinel {
            return parseBinary(bytes)
        }
        return parseASCII(bytes)
    }

    static func isBinary(_ data: Data) -> Bool {
        data.count >= binarySentinel.count && Array(data.prefix(binarySentinel.count)) == binarySentinel
    }

    // MARK: ASCII

    private static func parseASCII(_ bytes: [UInt8]) -> [DXFGroup] {
        var groups: [DXFGroup] = []
        groups.reserveCapacity(bytes.count / 12)
        var lines = LineScanner(bytes)
        // Files before R2007 are in the drawing's code page; later ones are UTF-8. Decoding tries UTF-8 per string and falls
        // back to Windows-1252, which covers both without reading $DWGCODEPAGE.
        while let codeLine = lines.next(), let valueLine = lines.next() {
            let trimmed = codeLine.trimmingCharacters(in: .whitespaces)
            guard let code = Int(trimmed) else { continue }
            groups.append(DXFGroup(code: code, text: valueLine))
            if code == 0 && valueLine.trimmingCharacters(in: .whitespaces) == "EOF" { break }
        }
        return groups
    }

    private struct LineScanner {
        let bytes: [UInt8]
        var position = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func next() -> String? {
            guard position < bytes.count else { return nil }
            var end = position
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            var stop = end
            if stop > position, bytes[stop - 1] == 0x0D { stop -= 1 }
            let slice = bytes[position..<stop]
            position = end + 1
            return decode(slice)
        }
    }

    static func decode<S: Sequence>(_ slice: S) -> String where S.Element == UInt8 {
        let array = Array(slice)
        if let s = String(validatingUTF8: array.map { CChar(bitPattern: $0) } + [0]) { return s }
        return String(data: Data(array), encoding: .windowsCP1252) ?? String(decoding: array, as: UTF8.self)
    }

    // MARK: Binary

    private static func parseBinary(_ bytes: [UInt8]) -> [DXFGroup] {
        var groups: [DXFGroup] = []
        var p = binarySentinel.count
        // R13 and later write 2-byte codes; R12 writes one byte (255 introduces a 2-byte code). The first group is
        // "0 SECTION": a zero second byte can only be the high byte of a 2-byte code 0.
        let wideCodes = p + 1 < bytes.count && bytes[p] == 0 && bytes[p + 1] == 0
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        while p < bytes.count {
            var code: Int
            if wideCodes {
                guard p + 2 <= bytes.count else { break }
                code = u16(p); p += 2
            } else {
                code = Int(bytes[p]); p += 1
                if code == 255 { guard p + 2 <= bytes.count else { break }; code = u16(p); p += 2 }
            }
            switch kind(of: code, wide: wideCodes) {
            case .string:
                var end = p
                while end < bytes.count, bytes[end] != 0 { end += 1 }
                groups.append(DXFGroup(code: code, text: decode(bytes[p..<end])))
                p = min(end + 1, bytes.count)
            case .chunk:
                guard p < bytes.count else { return groups }
                let n = Int(bytes[p]); p += 1
                guard p + n <= bytes.count else { return groups }
                groups.append(DXFGroup(code: code, text: bytes[p..<p + n].map { String(format: "%02X", $0) }.joined()))
                p += n
            case .int16:
                guard p + 2 <= bytes.count else { return groups }
                groups.append(DXFGroup(code: code, text: String(Int16(truncatingIfNeeded: u16(p)))))
                p += 2
            case .int32:
                guard p + 4 <= bytes.count else { return groups }
                let v = UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24
                groups.append(DXFGroup(code: code, text: String(Int32(bitPattern: v))))
                p += 4
            case .int64:
                guard p + 8 <= bytes.count else { return groups }
                var v: UInt64 = 0
                for i in 0..<8 { v |= UInt64(bytes[p + i]) << UInt64(8 * i) }
                groups.append(DXFGroup(code: code, text: String(Int64(bitPattern: v))))
                p += 8
            case .byte:
                guard p < bytes.count else { return groups }
                groups.append(DXFGroup(code: code, text: String(bytes[p])))
                p += 1
            case .double:
                guard p + 8 <= bytes.count else { return groups }
                var v: UInt64 = 0
                for i in 0..<8 { v |= UInt64(bytes[p + i]) << UInt64(8 * i) }
                groups.append(DXFGroup(code: code, text: String(Double(bitPattern: v))))
                p += 8
            }
            if code == 0, groups.last?.text == "EOF" { break }
        }
        return groups
    }

    private enum ValueKind { case string, chunk, int16, int32, int64, byte, double }

    private static func kind(of code: Int, wide: Bool) -> ValueKind {
        switch code {
        case 0...9, 100...102, 105, 999, 1000...1009: return .string
        case 10...59, 110...149, 210...239, 460...469, 1010...1059: return .double
        case 60...79, 170...179, 270...289, 370...389, 400...409, 1060...1070: return .int16
        case 90...99, 420...429, 440...459, 1071: return .int32
        case 160...169: return .int64
        case 290...299: return wide ? .byte : .int16
        case 300...309, 320...369, 390...399, 410...419, 430...439, 470...481: return .string
        case 310...319: return .chunk
        default: return wide ? .string : .int16
        }
    }
}

/// A DXF entity or table record: its type and its groups, with the lookups the reader needs.
struct DXFRecord {
    var type: String
    var groups: [DXFGroup]

    func first(_ code: Int) -> DXFGroup? { groups.first { $0.code == code } }
    func string(_ code: Int) -> String? { first(code)?.text }
    func double(_ code: Int, _ fallback: Double = 0) -> Double { first(code)?.double ?? fallback }
    func int(_ code: Int, _ fallback: Int = 0) -> Int { first(code)?.int ?? fallback }
    func all(_ code: Int) -> [DXFGroup] { groups.filter { $0.code == code } }
    func has(_ code: Int) -> Bool { first(code) != nil }

    /// Group 10/20/30 (+ offset) as a point.
    func point(_ base: Int = 10) -> (x: Double, y: Double, z: Double) {
        (double(base), double(base + 10), double(base + 20))
    }

    /// Extrusion direction (210/220/230), default +Z.
    var extrusion: (x: Double, y: Double, z: Double) {
        has(230) ? (double(210), double(220), double(230)) : (0, 0, 1)
    }
}

/// Splits a group stream into records at each code 0.
func dxfRecords(_ groups: ArraySlice<DXFGroup>) -> [DXFRecord] {
    var records: [DXFRecord] = []
    for group in groups {
        if group.code == 0 {
            records.append(DXFRecord(type: group.text.trimmingCharacters(in: .whitespaces), groups: []))
        } else if !records.isEmpty {
            records[records.count - 1].groups.append(group)
        }
    }
    return records
}
