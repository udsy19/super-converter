import Compression
import Foundation
import SuperConverterCore

// DEFLATE in and out on Apple's Compression framework, for the formats that carry it: SVGZ (gzip), PostScript's
// FlateDecode (zlib) and XPS packages (ZIP, raw deflate).

/// gzip (RFC 1952) decoding for SVGZ, bounded against decompression bombs.
enum Gzip {
    static func isGzip(_ data: Data) -> Bool { data.count > 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b }

    static func decompress(_ data: Data, limit: Int = 256 << 20) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw ConversionError.damaged("svgz") }
        let flags = bytes[3]
        var pos = 10
        if flags & 4 != 0 { guard pos + 2 <= bytes.count else { throw ConversionError.damaged("svgz") }; pos += 2 + Int(bytes[pos]) + (Int(bytes[pos + 1]) << 8) }
        if flags & 8 != 0 { while pos < bytes.count, bytes[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 16 != 0 { while pos < bytes.count, bytes[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 2 != 0 { pos += 2 }
        guard pos < bytes.count - 8 else { throw ConversionError.damaged("svgz") }
        return try Inflate.raw(Array(bytes[pos..<(bytes.count - 8)]), limit: limit)
    }
}

/// Raw DEFLATE decoding on the Compression framework with an output cap.
enum Inflate {
    static func raw(_ input: [UInt8], limit: Int) throws -> Data {
        var out = Data()
        let bufferSize = 1 << 16
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ConversionError.damaged("svgz")
        }
        defer { compression_stream_destroy(streamPointer) }
        return try input.withUnsafeBufferPointer { src -> Data in
            streamPointer.pointee.src_ptr = src.baseAddress!
            streamPointer.pointee.src_size = src.count
            streamPointer.pointee.dst_ptr = dst
            streamPointer.pointee.dst_size = bufferSize
            while true {
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - streamPointer.pointee.dst_size
                out.append(dst, count: produced)
                if out.count > limit { throw ConversionError.damaged("svgz") }
                streamPointer.pointee.dst_ptr = dst
                streamPointer.pointee.dst_size = bufferSize
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK: continue
                default: throw ConversionError.damaged("svgz")
                }
            }
        }
    }
}

/// DEFLATE encoding: Compression's `COMPRESSION_ZLIB` writes the raw deflate body (RFC 1951).
public enum Deflate {
    /// The raw deflate body, or nil when it comes out no smaller than `data`.
    public static func raw(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBytes { src in
            compression_encode_buffer(&buffer, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return n > 0 && n < data.count ? Data(buffer[0..<n]) : nil
    }

    /// An RFC 1950 zlib stream (what PDF and PostScript FlateDecode read): the two-byte header, the deflate body (stored
    /// blocks when compressing doesn't pay) and the Adler-32 trailer.
    public static func zlib(_ data: Data) -> Data {
        var out = Data([0x78, 0x9C])
        if let body = raw(data) {
            out.append(body)
        } else {
            // Stored blocks of at most 65535 bytes (RFC 1951 §3.2.4).
            var start = 0
            repeat {
                let length = min(65535, data.count - start)
                out.append(start + length >= data.count ? 1 : 0)
                out.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8((~length >> 8) & 0xFF)])
                out.append(data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + length)))
                start += length
            } while start < data.count
        }
        var a: UInt32 = 1, b: UInt32 = 0
        for chunk in stride(from: 0, to: data.count, by: 5552) {
            for byte in data[data.startIndex + chunk..<data.startIndex + min(chunk + 5552, data.count)] { a += UInt32(byte); b += a }
            a %= 65521; b %= 65521
        }
        let adler = b << 16 | a
        out.append(contentsOf: [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)])
        return out
    }
}
