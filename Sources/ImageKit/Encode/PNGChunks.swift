import Foundation
import zlib

/// zlib (the system library) for PNG chunks and PSD/PSB data.
enum Zlib {
    static func compress(_ data: Data, level: Int32 = 9) -> Data? {
        var size = compressBound(uLong(data.count))
        var out = Data(count: Int(size))
        let status = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                compress2(dst.bindMemory(to: Bytef.self).baseAddress!, &size, src.bindMemory(to: Bytef.self).baseAddress, uLong(data.count), level)
            }
        }
        guard status == Z_OK else { return nil }
        return out.prefix(Int(size))
    }

    /// Inflates one zlib stream (trailing bytes after its end are ignored) into exactly `expectedSize` bytes.
    static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        var out = Data(count: expectedSize)
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        let status: Int32 = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = dst.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(expectedSize)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || (status == Z_OK || status == Z_BUF_ERROR) && stream.avail_out == 0 else { return nil }
        return out
    }

    static func crc(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in UInt32(crc32(0, p.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
    }
}

/// Small edits to PNG files written by ImageIO: the exact source ICC profile in `iCCP` (ImageIO rewrites profiles it
/// embeds in PNG; quality §2.2 wants them byte for byte) and a `tRNS` chunk for palette images with transparent pixels.
enum PNGChunks {
    struct Chunk { var type: String; var body: Data }

    static func parse(_ png: Data) -> [Chunk]? {
        guard png.count > 8, png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else { return nil }
        var chunks: [Chunk] = []
        var i = 8
        while i + 12 <= png.count {
            let length = Int(png[i]) << 24 | Int(png[i + 1]) << 16 | Int(png[i + 2]) << 8 | Int(png[i + 3])
            guard i + 12 + length <= png.count else { return nil }
            let type = String(decoding: png[(i + 4)..<(i + 8)], as: UTF8.self)
            chunks.append(Chunk(type: type, body: png.subdata(in: (i + 8)..<(i + 8 + length))))
            i += 12 + length
            if type == "IEND" { break }
        }
        return chunks
    }

    static func assemble(_ chunks: [Chunk]) -> Data {
        var out = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        for chunk in chunks {
            var length = UInt32(chunk.body.count).bigEndian
            out.append(Data(bytes: &length, count: 4))
            let typed = Data(chunk.type.utf8) + chunk.body
            out.append(typed)
            var crc = Zlib.crc(typed).bigEndian
            out.append(Data(bytes: &crc, count: 4))
        }
        return out
    }

    /// Replaces (or adds) the `iCCP` chunk with these exact profile bytes; removes `sRGB`, `gAMA` and `cHRM`, which some
    /// readers would let override it.
    static func settingICC(_ png: Data, icc: Data) -> Data? {
        guard var chunks = parse(png), let compressed = Zlib.compress(icc) else { return nil }
        if let existing = chunks.first(where: { $0.type == "iCCP" }), let zero = existing.body.firstIndex(of: 0),
           Zlib.decompress(existing.body.suffix(from: zero + 2), expectedSize: icc.count) == icc {
            return png
        }
        chunks.removeAll { ["iCCP", "sRGB", "gAMA", "cHRM"].contains($0.type) }
        var body = Data("ICC Profile".utf8)
        body.append(contentsOf: [0, 0])
        body.append(compressed)
        chunks.insert(Chunk(type: "iCCP", body: body), at: 1)
        return assemble(chunks)
    }

    /// Adds a `tRNS` chunk (alpha per palette index) after `PLTE`.
    static func addingTransparency(_ png: Data, alphas: [UInt8]) -> Data? {
        guard var chunks = parse(png), let plte = chunks.firstIndex(where: { $0.type == "PLTE" }) else { return nil }
        chunks.removeAll { $0.type == "tRNS" }
        chunks.insert(Chunk(type: "tRNS", body: Data(alphas)), at: plte + 1)
        return assemble(chunks)
    }
}
