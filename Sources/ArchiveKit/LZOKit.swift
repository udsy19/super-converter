// Adapted from lzokay lzokay.cpp (MIT, Copyright (c) 2018 Jack Andersen): the LZO1X decompressor only, re-expressed in
// Swift with every read and write bounds-checked, plus the lzop container (header, blocks, adler32/crc32) written for
// this project.

import Foundation

/// Table-driven checksums used by the container formats ArchiveKit decodes itself (lzop, rzip).
enum ArchiveChecksum {
    private static let crcTable: [UInt32] = (0..<256).map { n in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    /// zlib's CRC-32; pass the previous result as `crc` to continue over more bytes.
    static func crc32(_ crc: UInt32 = 0, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }

    static func crc32(_ crc: UInt32 = 0, _ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes { crc32(crc, $0) }
    }

    /// zlib's Adler-32 (initial value 1).
    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var index = 0
        while index < bytes.count {
            let end = min(index + 5552, bytes.count)   // the longest run before the sums can overflow 32 bits
            for byte in bytes[index..<end] { a &+= UInt32(byte); b &+= a }
            a %= 65521; b %= 65521
            index = end
        }
        return (b << 16) | a
    }
}

/// LZO1X decompression and the lzop (.lzo) container.
enum LZOKit {
    private static let magic: [UInt8] = [0x89, 0x4C, 0x5A, 0x4F, 0x00, 0x0D, 0x0A, 0x1A, 0x0A]
    /// A block larger than this is not something lzop writes (its blocks are 256 KiB).
    private static let maxBlock = 64 << 20

    private enum Flags {
        static let adler32Data: UInt32 = 0x1
        static let adler32Packed: UInt32 = 0x2
        static let extraField: UInt32 = 0x40
        static let crc32Data: UInt32 = 0x100
        static let crc32Packed: UInt32 = 0x200
        static let multipart: UInt32 = 0x400
        static let filter: UInt32 = 0x800
        static let headerCRC32: UInt32 = 0x1000
    }

    /// Streams the decompressed bytes of an lzop file to `sink` block by block. Returns the file name stored in the header.
    static func decompress(source: URL, isCancelled: @Sendable () -> Bool, sink: (UnsafeRawBufferPointer) throws -> Void) throws -> String? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: source) } catch { throw ArchiveError.failed("Couldn’t read the file.") }
        defer { try? handle.close() }
        let input = Input(handle: handle)

        guard try input.take(magic.count) == magic else { throw ArchiveError.damaged("Not an lzop file.") }
        var header = [UInt8]()
        func number(_ count: Int) throws -> UInt32 {
            let bytes = try input.take(count)
            header += bytes
            return bytes.reduce(0) { $0 << 8 | UInt32($1) }
        }

        let version = try number(2)
        _ = try number(2)   // the lzo library version that wrote the file
        if version >= 0x0940 { _ = try number(2) }   // version needed to extract
        let method = try number(1)
        guard (1...3).contains(method) else { throw ArchiveError.unsupported("This lzop compression method isn’t supported.") }
        if version >= 0x0940 { _ = try number(1) }   // level
        let flags = try number(4)
        if flags & Flags.multipart != 0 { throw ArchiveError.unsupported("Multi-part lzop files aren’t supported.") }
        if flags & Flags.filter != 0 { _ = try number(4) }
        _ = try number(4)   // mode
        _ = try number(4)   // modification time
        if version >= 0x0940 { _ = try number(4) }
        let nameLength = Int(try number(1))
        let nameBytes = try input.take(nameLength)
        header += nameBytes
        let storedHeaderSum = try input.number(4)
        let headerSum = flags & Flags.headerCRC32 != 0 ? ArchiveChecksum.crc32(0, header) : ArchiveChecksum.adler32(header)
        guard storedHeaderSum == headerSum else { throw ArchiveError.damaged("The lzop header checksum doesn’t match.") }
        if flags & Flags.extraField != 0 {
            let extra = Int(try input.number(4))
            guard extra <= maxBlock else { throw ArchiveError.damaged("The lzop header is damaged.") }
            _ = try input.take(extra + 4)
        }

        while true {
            if isCancelled() { throw ArchiveError.cancelled }
            let unpackedSize = Int(try input.number(4))
            if unpackedSize == 0 { break }
            let packedSize = Int(try input.number(4))
            guard unpackedSize <= maxBlock, packedSize > 0, packedSize <= unpackedSize else {
                throw ArchiveError.damaged("An lzop block has an impossible size.")
            }
            var dataAdler: UInt32?, dataCRC: UInt32?, packedAdler: UInt32?, packedCRC: UInt32?
            if flags & Flags.adler32Data != 0 { dataAdler = try input.number(4) }
            if flags & Flags.crc32Data != 0 { dataCRC = try input.number(4) }
            let stored = packedSize == unpackedSize
            if !stored {
                if flags & Flags.adler32Packed != 0 { packedAdler = try input.number(4) }
                if flags & Flags.crc32Packed != 0 { packedCRC = try input.number(4) }
            }
            let packed = try input.take(packedSize)
            if let packedAdler, ArchiveChecksum.adler32(packed) != packedAdler { throw ArchiveError.damaged("An lzop block is corrupt.") }
            if let packedCRC, ArchiveChecksum.crc32(0, packed) != packedCRC { throw ArchiveError.damaged("An lzop block is corrupt.") }
            let block = stored ? packed : try lzo1xDecompress(packed, expectedSize: unpackedSize)
            if let dataAdler, ArchiveChecksum.adler32(block) != dataAdler { throw ArchiveError.damaged("An lzop block is corrupt.") }
            if let dataCRC, ArchiveChecksum.crc32(0, block) != dataCRC { throw ArchiveError.damaged("An lzop block is corrupt.") }
            try block.withUnsafeBytes { try sink($0) }
        }

        guard !nameBytes.isEmpty else { return nil }
        return String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1)
    }

    /// Sequential big-endian reader over the file; a short read means the file is cut off.
    private final class Input {
        let handle: FileHandle
        init(handle: FileHandle) { self.handle = handle }

        func take(_ count: Int) throws -> [UInt8] {
            guard count > 0 else { return [] }
            let data: Data?
            do { data = try handle.read(upToCount: count) } catch { throw ArchiveError.failed("Couldn’t read the file.") }
            guard let data, data.count == count else { throw ArchiveError.damaged("The lzop file ends too early.") }
            return [UInt8](data)
        }

        func number(_ count: Int) throws -> UInt32 { try take(count).reduce(0) { $0 << 8 | UInt32($1) } }
    }

    // MARK: LZO1X

    /// Decodes one LZO1X block (instruction set per the Linux `Documentation/lzo.txt`) that must yield exactly `expectedSize` bytes.
    static func lzo1xDecompress(_ src: [UInt8], expectedSize: Int) throws -> [UInt8] {
        let damaged = ArchiveError.damaged("LZO data is damaged.")
        guard src.count >= 3 else { throw damaged }
        var out = [UInt8]()
        out.reserveCapacity(expectedSize)
        var pos = 0
        var state = 0

        func byte() throws -> Int {
            guard pos < src.count else { throw damaged }
            defer { pos += 1 }
            return Int(src[pos])
        }
        func literals(_ count: Int) throws {
            guard count <= src.count - pos, count <= expectedSize - out.count else { throw damaged }
            out.append(contentsOf: src[pos..<pos + count])
            pos += count
        }
        func copyMatch(distance: Int, length: Int) throws {
            guard distance >= 1, distance <= out.count, length <= expectedSize - out.count else { throw damaged }
            var from = out.count - distance
            for _ in 0..<length {
                out.append(out[from])
                from += 1
            }
        }
        /// The length of a run that did not fit in the opcode: zero bytes each add 255, then one byte.
        func extendedLength(base: Int) throws -> Int {
            var zeros = 0
            var last = try byte()
            while last == 0 {
                zeros += 1
                last = try byte()
            }
            return base + zeros * 255 + last
        }

        let first = Int(src[0])
        if first >= 22 {
            pos = 1
            try literals(first - 17)
            state = 4
        } else if first >= 18 {
            pos = 1
            state = first - 17
            try literals(state)
        }

        while true {
            let inst = try byte()
            let length: Int, distance: Int, next: Int
            if inst & 0xC0 != 0 {
                // M2: a 3..8 byte copy from within 2 KiB
                distance = (try byte() << 3) + ((inst >> 2) & 0x7) + 1
                length = (inst >> 5) + 1
                next = inst & 0x3
            } else if inst & 0x20 != 0 {
                // M3: a copy from within 16 KiB
                length = inst & 0x1F == 0 ? try extendedLength(base: 31) + 2 : (inst & 0x1F) + 2
                let tail = try byte() | (try byte() << 8)
                distance = (tail >> 2) + 1
                next = tail & 0x3
            } else if inst & 0x10 != 0 {
                // M4: a copy from 16..48 KiB away; a distance of exactly 16384 ends the block
                length = inst & 0x7 == 0 ? try extendedLength(base: 7) + 2 : (inst & 0x7) + 2
                let tail = try byte() | (try byte() << 8)
                let offset = ((inst & 0x8) << 11) + (tail >> 2)
                if offset == 0 {
                    guard length == 3, pos == src.count, out.count == expectedSize else { throw damaged }
                    return out
                }
                distance = 16384 + offset
                next = tail & 0x3
            } else if state == 0 {
                // M1 after no literals: a long literal run
                try literals(inst == 0 ? try extendedLength(base: 15) + 3 : inst + 3)
                state = 4
                continue
            } else {
                // M1 after literals: a 2 byte copy from within 1 KiB, or a 3 byte copy from 2..3 KiB after a long run
                let high = try byte() << 2
                next = inst & 0x3
                distance = (inst >> 2) + high + (state == 4 ? 2049 : 1)
                length = state == 4 ? 3 : 2
            }
            try copyMatch(distance: distance, length: length)
            try literals(next)
            state = next
        }
    }
}
