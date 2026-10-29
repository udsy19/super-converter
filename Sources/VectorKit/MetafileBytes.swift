import Foundation

/// Bounds-checked little-endian access to a byte buffer: reads outside the buffer return 0, so a damaged file yields wrong
/// numbers (which the callers range-check) and never a trap.
struct ByteReader {
    let bytes: [UInt8]
    init(_ data: Data) { bytes = [UInt8](data) }
    init(bytes: [UInt8]) { self.bytes = bytes }

    var count: Int { bytes.count }

    func has(_ offset: Int, _ length: Int) -> Bool { offset >= 0 && length >= 0 && offset <= bytes.count && length <= bytes.count - offset }

    func u8(_ o: Int) -> Int { o >= 0 && o < bytes.count ? Int(bytes[o]) : 0 }
    func u16(_ o: Int) -> Int { has(o, 2) ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : 0 }
    func i16(_ o: Int) -> Int { let v = u16(o); return v > 32767 ? v - 65536 : v }
    func u32(_ o: Int) -> Int { has(o, 4) ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 : 0 }
    func i32(_ o: Int) -> Int { Int(Int32(truncatingIfNeeded: u32(o))) }
    func f32(_ o: Int) -> Double { has(o, 4) ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: u32(o)))) : 0 }

    func slice(_ o: Int, _ length: Int) -> [UInt8] {
        guard has(o, length), length > 0 else { return [] }
        return Array(bytes[o..<(o + length)])
    }

    /// `chars` UTF-16 code units at `o` (stops at a NUL when `terminated`).
    func utf16(_ o: Int, chars: Int, terminated: Bool = false) -> String {
        var units: [UInt16] = []
        var i = 0
        while i < chars, has(o + i * 2, 2) {
            let u = UInt16(u16(o + i * 2))
            if terminated && u == 0 { break }
            units.append(u); i += 1
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// 8-bit text (Windows-1252) of `chars` bytes at `o`.
    func ansi(_ o: Int, chars: Int, terminated: Bool = false) -> String {
        var out: [UInt8] = []
        var i = 0
        while i < chars, has(o + i, 1) {
            let b = bytes[o + i]
            if terminated && b == 0 { break }
            out.append(b); i += 1
        }
        return String(data: Data(out), encoding: .windowsCP1252) ?? String(decoding: out, as: UTF8.self)
    }
}

/// Little-endian byte assembly for the writers.
struct ByteWriter {
    var bytes: [UInt8] = []
    var count: Int { bytes.count }

    mutating func u8(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) { u8(v); u8(v >> 8) }
    mutating func u32(_ v: Int) { u16(v); u16(v >> 16) }
    mutating func i32(_ v: Int) { u32(v) }
    mutating func f32(_ v: Double) { u32(Int(Float(v).bitPattern)) }
    mutating func append(_ b: [UInt8]) { bytes.append(contentsOf: b) }
    mutating func pad4() { while bytes.count % 4 != 0 { bytes.append(0) } }
    mutating func set32(_ at: Int, _ v: Int) {
        for k in 0..<4 { bytes[at + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) }
    }
}
