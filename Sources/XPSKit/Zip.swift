import Compression
import Foundation
import SuperConverterCore
import VectorKit

/// A ZIP package (the OPC container of XPS): reading with the central directory and bomb limits, writing with CRC-32.
enum Zip {
    static let maxEntries = 100_000
    static let maxEntrySize = 256 << 20
    static let maxTotalSize = 768 << 20

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

struct ZipReader {
    struct Entry { let name: String; let method: Int; let crc: UInt32; let compressed: Int; let size: Int; let offset: Int }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]
    /// Names in directory order.
    private(set) var names: [String] = []
    private var inflatedTotal = 0

    private func u16(_ o: Int) -> Int { o >= 0 && o + 2 <= data.count ? Int(data[data.startIndex + o]) | Int(data[data.startIndex + o + 1]) << 8 : 0 }
    private func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

    init(_ data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw ConversionError.damaged("xps") }
        var eocd = -1
        var p = data.count - 22
        let stop = max(0, data.count - 22 - 65_535)
        while p >= stop {
            if u32(p) == 0x0605_4b50 { eocd = p; break }
            p -= 1
        }
        guard eocd >= 0 else { throw ConversionError.damaged("xps") }
        let count = u16(eocd + 10), dirOffset = u32(eocd + 16)
        guard count <= Zip.maxEntries, dirOffset < data.count else { throw ConversionError.damaged("xps") }
        var pos = dirOffset
        var declared = 0
        for _ in 0..<count {
            guard pos + 46 <= data.count, u32(pos) == 0x0201_4b50 else { throw ConversionError.damaged("xps") }
            let method = u16(pos + 10), crc = UInt32(truncatingIfNeeded: u32(pos + 16)), csize = u32(pos + 20), usize = u32(pos + 24)
            let nameLen = u16(pos + 28), extraLen = u16(pos + 30), commentLen = u16(pos + 32), local = u32(pos + 42)
            guard pos + 46 + nameLen <= data.count else { throw ConversionError.damaged("xps") }
            let raw = data.subdata(in: (data.startIndex + pos + 46)..<(data.startIndex + pos + 46 + nameLen))
            let name = String(decoding: raw, as: UTF8.self)
            declared += usize
            guard usize <= Zip.maxEntrySize, declared <= Zip.maxTotalSize else { throw ConversionError.damaged("xps") }
            if !name.hasSuffix("/") {
                let key = name.lowercased()
                if entries[key] == nil { names.append(name) }
                entries[key] = Entry(name: name, method: method, crc: crc, compressed: csize, size: usize, offset: local)
            }
            pos += 46 + nameLen + extraLen + commentLen
        }
    }

    func has(_ name: String) -> Bool { entries[Self.key(name)] != nil }

    static func key(_ name: String) -> String { (name.hasPrefix("/") ? String(name.dropFirst()) : name).lowercased() }

    func read(_ name: String) throws -> Data {
        guard let e = entries[Self.key(name)] else { throw ConversionError.damaged("xps") }
        guard u32(e.offset) == 0x0403_4b50 else { throw ConversionError.damaged("xps") }
        let start = e.offset + 30 + u16(e.offset + 26) + u16(e.offset + 28)
        guard start >= 0, start + e.compressed <= data.count else { throw ConversionError.damaged("xps") }
        let body = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressed))
        let out: Data
        switch e.method {
        case 0: out = body
        case 8:
            guard e.size > 0 else { return Data() }
            // DEFLATE expands at most 1032:1, so a declared size beyond that is damage: the buffer is not allocated for it.
            guard e.size / 1032 <= e.compressed else { throw ConversionError.damaged("xps") }
            var buffer = [UInt8](repeating: 0, count: e.size)
            let n = body.withUnsafeBytes { src -> Int in
                guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(&buffer, e.size, base, body.count, nil, COMPRESSION_ZLIB)
            }
            guard n == e.size else { throw ConversionError.damaged("xps") }
            out = Data(buffer)
        default: throw ConversionError.damaged("xps")
        }
        guard out.count == e.size, Zip.crc32(out) == e.crc else { throw ConversionError.damaged("xps") }
        return out
    }
}

struct ZipWriter {
    private var body = Data()
    private var directory = Data()
    private var count = 0

    private static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }
    private static func le32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }

    mutating func add(_ name: String, _ data: Data) {
        let crc = Int(Zip.crc32(data))
        var method = 0
        var payload = data
        if data.count > 64, let deflated = Deflate.raw(data) { method = 8; payload = deflated }
        let nameBytes = Array(name.utf8)
        let offset = body.count
        var local: [UInt8] = Self.le32(0x0403_4b50) + Self.le16(20) + Self.le16(0x0800) + Self.le16(method) + Self.le16(0) + Self.le16(0x21)
        local += Self.le32(crc) + Self.le32(payload.count) + Self.le32(data.count) + Self.le16(nameBytes.count) + Self.le16(0) + nameBytes
        body.append(contentsOf: local); body.append(payload)
        var central: [UInt8] = Self.le32(0x0201_4b50) + Self.le16(20) + Self.le16(20) + Self.le16(0x0800) + Self.le16(method) + Self.le16(0) + Self.le16(0x21)
        central += Self.le32(crc) + Self.le32(payload.count) + Self.le32(data.count) + Self.le16(nameBytes.count) + Self.le16(0) + Self.le16(0)
        central += Self.le16(0) + Self.le16(0) + Self.le32(0) + Self.le32(offset) + nameBytes
        directory.append(contentsOf: central)
        count += 1
    }

    func finish() -> Data {
        var out = body
        out.append(directory)
        out.append(contentsOf: Self.le32(0x0605_4b50) + Self.le16(0) + Self.le16(0) + Self.le16(count) + Self.le16(count) + Self.le32(directory.count) + Self.le32(body.count) + Self.le16(0))
        return out
    }
}
