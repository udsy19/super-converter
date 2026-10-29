// Written from the published description of the ARC format (System Enhancement Associates, 1985): entries led by a 0x1A
// marker and a method byte, 13-byte DOS name, sizes, DOS date and time, CRC-16. Methods 1 to 4 (stored, packed, squeezed),
// 8 (crunched, dynamic LZW plus RLE) and 9 (squashed, 13-bit LZW). The older crunch variants (5, 6, 7) and PAK's crushed
// and distilled (10, 11) are reported as unsupported. No ARC source code was used.

import Foundation
import SuperConverterCore

/// ARC archives, as made by SEA ARC, PKPAK and PAK.
enum ARCKit {
    private static let marker: UInt8 = 0x1A
    private static let blockSize = 1 << 16

    private struct Entry {
        var method: Int
        var name: [UInt8]
        var packedSize: Int
        var datetime: UInt32
        var crc: UInt16
        var size: Int
        var dataOffset: Int
    }

    /// CRC-16/ARC: polynomial 0xA001 (reflected), start 0, no final inversion.
    enum CRC16 {
        private static let table: [UInt16] = (0..<256).map { i -> UInt16 in
            var c = UInt16(i)
            for _ in 0..<8 { c = c & 1 != 0 ? 0xA001 ^ (c >> 1) : c >> 1 }
            return c
        }

        static func update(_ crc: UInt16, _ byte: UInt8) -> UInt16 { table[Int((crc ^ UInt16(byte)) & 0xFF)] ^ (crc >> 8) }

        static func checksum(_ bytes: [UInt8]) -> UInt16 { bytes.reduce(0, update) }
    }

    static func read(_ request: ArchiveReadRequest) throws -> ArchiveTree {
        try read(request, into: request.extractor(windowsSeparators: true))
    }

    /// Reads into a given extractor, so the caller can ask it what was left out.
    static func read(_ request: ArchiveReadRequest, into extractor: SafeExtractor) throws -> ArchiveTree {
        let data: Data
        do { data = try Data(contentsOf: request.source, options: .alwaysMapped) } catch {
            throw ArchiveError.failed("Couldn’t read \(request.source.lastPathComponent).")
        }
        let entries = try parseEntries(data)
        var usedLegacyNames = false

        for (index, entry) in entries.enumerated() {
            if request.isCancelled() { throw ArchiveError.cancelled }
            request.report(StepProgress(fraction: Double(index) / Double(entries.count), unit: "File \(index + 1) of \(entries.count)"))
            guard Int64(entry.size) <= request.limits.maxTotalBytes else {
                throw ArchiveError.tooLarge("A file in this archive is larger than Super Converter will unpack.")
            }
            let (name, legacy) = ArchiveDOSName.decode(entry.name, index: index, encoding: request.nameEncoding)
            usedLegacyNames = usedLegacyNames || legacy
            let modified = ArchiveDOSTime.date(entry.datetime)
            let sink = try extractor.file(name, size: Int64(entry.size), modified: modified)
            let output = Output(size: entry.size) { chunk in try chunk.withUnsafeBytes { try sink?.write($0) } }
            do {
                try decode(entry, data: data, into: output)
                try output.finish()
                guard output.produced == entry.size else { throw ArchiveError.damaged("A file ends before its full size.") }
                guard output.crc == entry.crc else { throw ArchiveError.damaged("A file’s checksum doesn’t match.") }
                try sink?.close()
            } catch {
                sink?.abort()
                throw error
            }
        }
        request.report(StepProgress(fraction: 1, unit: nil))
        return extractor.finish(nameEncoding: usedLegacyNames ? "CP437" : nil)
    }

    // MARK: Headers

    /// Walks the entry chain. An archive may end without its end marker, but not in the middle of an entry.
    private static func parseEntries(_ data: Data) throws -> [Entry] {
        guard data.count >= 2, data[0] == marker else {
            throw ArchiveError.damaged("This isn’t an ARC archive.")
        }
        var entries: [Entry] = []
        var offset = 0
        while offset < data.count {
            guard data[offset] == marker else { throw ArchiveError.damaged("An ARC entry doesn’t start where expected.") }
            guard data.count - offset >= 2 else { throw ArchiveError.damaged("An ARC archive is cut short.") }
            let method = Int(data[offset + 1])
            if method == 0 { break }
            let headerSize = method == 1 ? 25 : 29
            guard data.count - offset >= headerSize else { throw ArchiveError.damaged("An ARC header is cut short.") }
            func u16(_ i: Int) -> Int { Int(data[offset + i]) | Int(data[offset + i + 1]) << 8 }
            func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
            let packed = u32(15)
            let dataOffset = offset + headerSize
            guard packed <= data.count - dataOffset else { throw ArchiveError.damaged("An ARC archive is cut short.") }
            entries.append(Entry(method: method, name: Array(data[(offset + 2)..<(offset + 15)]), packedSize: packed,
                                 datetime: UInt32(u16(19)) << 16 | UInt32(u16(21)), crc: UInt16(u16(23)),
                                 size: method == 1 ? packed : u32(25), dataOffset: dataOffset))
            offset = dataOffset + packed
        }
        return entries
    }

    // MARK: Output

    /// Receives the unpacked bytes of one entry, in blocks, and stops taking bytes at the declared size.
    private final class Output {
        let size: Int
        private(set) var produced = 0
        private(set) var crc: UInt16 = 0
        private var buffer: [UInt8] = []
        private let write: ([UInt8]) throws -> Void

        init(size: Int, write: @escaping ([UInt8]) throws -> Void) { self.size = size; self.write = write }

        var isFull: Bool { produced >= size }

        func put(_ byte: UInt8) throws {
            guard produced < size else { return }
            buffer.append(byte)
            crc = CRC16.update(crc, byte)
            produced += 1
            if buffer.count >= ARCKit.blockSize { try drain() }
        }

        func put(_ byte: UInt8, times: Int) throws {
            var left = times
            while left > 0, !isFull { try put(byte); left -= 1 }
        }

        func finish() throws { try drain() }

        private func drain() throws {
            guard !buffer.isEmpty else { return }
            try write(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    /// The 0x90 run-length layer of packed, squeezed and crunched data: `x 90 n` repeats x to n copies, `90 00` is a 0x90.
    private struct RunLength {
        private var last: UInt8 = 0
        private var escaped = false

        mutating func feed(_ byte: UInt8, into out: Output) throws {
            if escaped {
                escaped = false
                if byte == 0 {
                    try out.put(0x90)
                    last = 0x90
                } else {
                    try out.put(last, times: Int(byte) - 1)
                }
            } else if byte == 0x90 {
                escaped = true
            } else {
                try out.put(byte)
                last = byte
            }
        }
    }

    // MARK: Methods

    private static func decode(_ entry: Entry, data: Data, into out: Output) throws {
        let start = entry.dataOffset, end = entry.dataOffset + entry.packedSize
        switch entry.method {
        case 1, 2:
            guard entry.packedSize >= entry.size else { throw ArchiveError.damaged("A stored file is cut short.") }
            for i in start..<start + entry.size { try out.put(data[i]) }
        case 3:
            var rle = RunLength()
            for i in start..<end where !out.isFull { try rle.feed(data[i], into: out) }
        case 4:
            try unsqueeze(data, start..<end, into: out)
        case 8:
            guard end - start >= 1 else { throw ArchiveError.damaged("A crunched file has no data.") }
            let maxBits = Int(data[start])
            guard (9...16).contains(maxBits) else { throw ArchiveError.damaged("A crunched file names an impossible code size.") }
            try lzw(data, (start + 1)..<end, maxBits: maxBits, runLength: true, into: out)
        case 9:
            try lzw(data, start..<end, maxBits: 13, runLength: false, into: out)
        default:
            throw ArchiveError.unsupported("ARC method \(entry.method)")
        }
    }

    /// Method 4: a Huffman tree (node count, then two 16-bit children per node: negative is a leaf, `-(v + 1)` the byte,
    /// 256 the end), bits read least significant first, and the 0x90 layer on top.
    private static func unsqueeze(_ data: Data, _ range: Range<Int>, into out: Output) throws {
        let count = range.count
        guard count >= 2 else { throw ArchiveError.damaged("A squeezed file has no tree.") }
        func s16(_ i: Int) -> Int { Int(Int16(truncatingIfNeeded: Int(data[i]) | Int(data[i + 1]) << 8)) }
        let nodes = Int(data[range.lowerBound]) | Int(data[range.lowerBound + 1]) << 8
        guard (1...257).contains(nodes), count >= 2 + nodes * 4 else { throw ArchiveError.damaged("A squeezed file’s tree is cut short.") }
        let tree = (0..<nodes * 2).map { s16(range.lowerBound + 2 + $0 * 2) }

        var rle = RunLength()
        var node = 0
        var position = range.lowerBound + 2 + nodes * 4
        while position < range.upperBound, !out.isFull {
            let byte = data[position]
            position += 1
            for bit in 0..<8 {
                let child = tree[node * 2 + Int(byte >> UInt8(bit) & 1)]
                if child >= 0 {
                    guard child < nodes else { throw ArchiveError.damaged("A squeezed file’s tree points outside itself.") }
                    node = child
                    continue
                }
                node = 0
                let symbol = -(child + 1)
                if symbol == 256 { return }
                guard symbol < 256 else { throw ArchiveError.damaged("A squeezed file’s tree has an impossible leaf.") }
                try rle.feed(UInt8(symbol), into: out)
                if out.isFull { return }
            }
        }
    }

    /// Methods 8 and 9: LZW with codes of 9 bits growing to `maxBits`, packed least significant bit first; 256 clears the
    /// table, new entries start at 257 and stop once the table is full. As in UNIX compress, codes travel in groups of eight:
    /// after a clear code the rest of its group is padding (checked against a real crunched archive; the squashed samples
    /// have no clear code). Crunched data runs through the 0x90 layer.
    private static func lzw(_ data: Data, _ range: Range<Int>, maxBits: Int, runLength: Bool, into out: Output) throws {
        let limit = 1 << maxBits
        var prefix = [UInt16](repeating: 0, count: limit)
        var suffix = [UInt8](repeating: 0, count: limit)
        var rle = RunLength()
        var next = 257, bits = 9, old = -1
        var first: UInt8 = 0
        var accumulator: UInt32 = 0, have = 0
        var position = range.lowerBound
        var stack: [UInt8] = []
        var groupPosition = 0

        func emit(_ byte: UInt8) throws {
            if runLength { try rle.feed(byte, into: out) } else { try out.put(byte) }
        }

        func readCode() -> Int? {
            while have < bits {
                guard position < range.upperBound else { return nil }
                accumulator |= UInt32(data[position]) << UInt32(have)
                have += 8
                position += 1
            }
            let code = Int(accumulator & UInt32((1 << bits) - 1))
            accumulator >>= UInt32(bits)
            have -= bits
            groupPosition += 1
            return code
        }

        while !out.isFull {
            guard let code = readCode() else { return }
            if code == 256 {
                for _ in 0..<(8 - groupPosition % 8) % 8 { guard readCode() != nil else { return } }
                groupPosition = 0
                bits = 9; next = 257; old = -1
                continue
            }
            if old < 0 {
                guard code < 256 else { throw ArchiveError.damaged("An LZW stream doesn’t start with a literal.") }
                try emit(UInt8(code))
                old = code; first = UInt8(code)
                continue
            }

            stack.removeAll(keepingCapacity: true)
            var current = code
            if code >= next {
                guard code == next else { throw ArchiveError.damaged("An LZW code points at an entry that doesn’t exist.") }
                stack.append(first)
                current = old
            }
            while current >= 257 {
                stack.append(suffix[current])
                current = Int(prefix[current])
            }
            stack.append(UInt8(truncatingIfNeeded: current))
            first = stack[stack.count - 1]
            for byte in stack.reversed() {
                try emit(byte)
                if out.isFull { return }
            }
            if next < limit {
                prefix[next] = UInt16(old)
                suffix[next] = first
                next += 1
                if next == 1 << bits, bits < maxBits { bits += 1; groupPosition = 0 }
            }
            old = code
        }
    }
}
