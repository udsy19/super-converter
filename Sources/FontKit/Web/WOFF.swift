import Foundation
import Compression

/// WOFF 1.0: SFNT tables, each zlib-compressed when that is smaller (W3C WOFF File Format 1.0).
enum WOFF {
    static func read(_ bytes: [UInt8]) throws -> SFNTTables {
        guard bytes.count >= 44, try bytes.tag(0) == "wOFF" else { throw FontError.damaged("not a WOFF file") }
        let flavor = try bytes.be32(4)
        let count = try bytes.be16(12)
        guard count > 0, count < 200 else { throw FontError.damaged("table count") }
        var tables: [String: [UInt8]] = [:]
        for i in 0..<count {
            let e = 44 + i * 20
            let tag = try bytes.tag(e)
            let offset = try bytes.be32(e + 4), compressed = try bytes.be32(e + 8), original = try bytes.be32(e + 12)
            guard original < 1 << 28 else { throw FontError.damaged("table size") }
            let stored = try bytes.slice(offset, compressed)
            if compressed == original { tables[tag] = stored }
            else if compressed < original { tables[tag] = try inflate(stored, size: original) }
            else { throw FontError.damaged("table \(tag) is larger than its original") }
        }
        return SFNTTables(flavor: flavor, tables: tables)
    }

    static func write(_ built: SFNTWriter.Built) -> [UInt8] {
        let tables = SFNTContainer.adjusted(flavor: built.flavor, tables: built.tables).sorted { $0.0 < $1.0 }
        struct Entry { var tag: String; var stored: [UInt8]; var original: Int; var checksum: UInt32 }
        let entries = tables.map { tag, data -> Entry in
            var summed = data
            if tag == "head", summed.count >= 12 { for k in 8..<12 { summed[k] = 0 } }
            let packed = deflate(data)
            return Entry(tag: tag, stored: packed.count < data.count ? packed : data, original: data.count, checksum: SFNTContainer.checksum(summed))
        }
        var offset = 44 + 20 * entries.count
        var w = ByteWriter()
        let total = entries.reduce(offset) { $0 + padded4($1.stored.count) }
        let sfntSize = 12 + 16 * entries.count + entries.reduce(0) { $0 + padded4($1.original) }
        w.tag("wOFF"); w.u32(built.flavor); w.u32(total); w.u16(entries.count); w.u16(0); w.u32(sfntSize)
        w.u16(1); w.u16(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0); w.u32(0)
        for e in entries {
            w.tag(e.tag); w.u32(offset); w.u32(e.stored.count); w.u32(e.original); w.u32(Int(e.checksum))
            offset += padded4(e.stored.count)
        }
        for e in entries { w.append(e.stored); w.align4() }
        return w.bytes
    }

    /// An RFC 1950 stream: Compression's `COMPRESSION_ZLIB` is the raw deflate body, so the header and Adler-32 are added here.
    static func deflate(_ data: [UInt8]) -> [UInt8] {
        guard !data.isEmpty else { return [] }
        var out = [UInt8](repeating: 0, count: data.count + 1024)
        let n = compression_encode_buffer(&out, out.count, data, data.count, nil, COMPRESSION_ZLIB)
        guard n > 0 else { return data }
        var stream: [UInt8] = [0x78, 0xDA]
        stream += out[0..<n]
        let a = adler32(data)
        stream += [UInt8(a >> 24), UInt8((a >> 16) & 0xFF), UInt8((a >> 8) & 0xFF), UInt8(a & 0xFF)]
        return stream
    }

    static func inflate(_ stream: [UInt8], size: Int) throws -> [UInt8] {
        guard stream.count > 2, stream[0] & 0x0F == 8 else { throw FontError.damaged("zlib header") }
        var out = [UInt8](repeating: 0, count: size)
        let body = Array(stream[2...])
        let n = compression_decode_buffer(&out, size, body, body.count, nil, COMPRESSION_ZLIB)
        guard n == size else { throw FontError.damaged("table did not inflate to its size") }
        return out
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return b << 16 | a
    }
}
