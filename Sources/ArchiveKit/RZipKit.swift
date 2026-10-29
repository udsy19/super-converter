// Written from the published rzip 2.x file-format description (clean-room; no rzip source was consulted).

import Archive   // links libbz2 for the symbol below
import Foundation

@_silgen_name("BZ2_bzBuffToBuffDecompress")
private func bz2BuffToBuffDecompress(_ dest: UnsafeMutablePointer<CChar>?, _ destLength: UnsafeMutablePointer<UInt32>?,
                                     _ source: UnsafeMutablePointer<CChar>?, _ sourceLength: UInt32,
                                     _ small: Int32, _ verbosity: Int32) -> Int32

/// rzip decompression: long-range matches over the whole output, with the control and literal streams stored or bzip2-packed.
enum RZipKit {
    private static let headerSize: UInt64 = 24
    private static let streamHeaderSize: UInt64 = 13
    private static let maxSize: UInt64 = 1 << 40
    /// Output is handed to the sink, and appended to the history file, in pieces of about this size.
    private static let flushSize = 1 << 20
    private static let maxBlock = 256 << 20

    /// Streams the decompressed bytes to `sink`.
    static func decompress(source: URL, isCancelled: @Sendable () -> Bool, sink: (UnsafeRawBufferPointer) throws -> Void) throws {
        let input = try File(open: source.path, flags: O_RDONLY)
        defer { input.close() }
        let head = try input.read(at: 0, count: Int(headerSize))
        guard head[0..<4].elementsEqual("RZIP".utf8) else { throw ArchiveError.damaged("Not an rzip file.") }
        let declared = UInt64(be32(head, 10)) << 32 | UInt64(be32(head, 6))
        guard declared <= maxSize else { throw ArchiveError.tooLarge("This rzip file expands to more than 1 TB.") }

        let historyURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rzip-\(UUID().uuidString)")
        let history = try File(open: historyURL.path, flags: O_RDWR | O_CREAT | O_EXCL, mode: 0o600)
        defer { history.close(); unlink(historyURL.path) }

        var output = Output(history: history, limit: declared)
        var chunkStart = headerSize
        while output.total < declared {
            if isCancelled() { throw ArchiveError.cancelled }
            chunkStart += try decodeChunk(at: chunkStart, input: input, output: &output, isCancelled: isCancelled, sink: sink)
        }
        try output.flush(to: sink)
    }

    // MARK: Chunks

    /// Decodes the chunk that starts at `start` and returns how many bytes of the file it occupies.
    private static func decodeChunk(at start: UInt64, input: File, output: inout Output, isCancelled: @Sendable () -> Bool,
                                    sink: (UnsafeRawBufferPointer) throws -> Void) throws -> UInt64 {
        let headers = try input.read(at: start, count: Int(2 * streamHeaderSize))
        var control = try Stream(headers: headers, offset: 0, chunkStart: start, input: input)
        var literal = try Stream(headers: headers, offset: Int(streamHeaderSize), chunkStart: start, input: input)
        var blocks = 0
        output.beginChunk()

        func take(_ stream: inout Stream, _ count: Int) throws -> [UInt8] {
            var result = [UInt8]()
            result.reserveCapacity(count)
            while result.count < count {
                if stream.isDrained {
                    if isCancelled() { throw ArchiveError.cancelled }
                    blocks += 1
                    guard UInt64(blocks) <= input.size / streamHeaderSize + 1 else { throw ArchiveError.damaged("The rzip block list loops.") }
                    try stream.loadNext()
                }
                result += stream.consume(count - result.count)
            }
            return result
        }

        while true {
            let command = try take(&control, 3)
            let length = Int(command[1]) | Int(command[2]) << 8
            if command[0] == 0 {
                if length == 0 { break }
                try output.append(try take(&literal, length))
            } else {
                let offset = UInt64(le32(try take(&control, 4), 0))
                try output.copyMatch(offset: offset, length: length)
            }
            if output.pendingBytes >= flushSize { try output.flush(to: sink) }
        }
        let crc = output.finishChunk()
        guard le32(try take(&control, 4), 0) == crc else { throw ArchiveError.damaged("An rzip chunk doesn’t match its checksum.") }
        return 2 * streamHeaderSize + control.consumedBytes + literal.consumedBytes
    }

    // MARK: Streams

    /// One of a chunk's two streams: a linked list of blocks read in order.
    private struct Stream {
        let chunkStart: UInt64
        let input: File
        var next: UInt64
        var data = [UInt8]()
        var position = 0
        /// The size of every block loaded so far, headers included.
        var consumedBytes: UInt64 = 0

        init(headers: [UInt8], offset: Int, chunkStart: UInt64, input: File) throws {
            guard headers[offset] == 3, le32(headers, offset + 1) == 0, le32(headers, offset + 5) == 0 else {
                throw ArchiveError.damaged("An rzip stream header is invalid.")
            }
            self.chunkStart = chunkStart
            self.input = input
            next = UInt64(le32(headers, offset + 9))
        }

        var isDrained: Bool { position == data.count }

        mutating func consume(_ count: Int) -> [UInt8] {
            let end = min(data.count, position + count)
            defer { position = end }
            return Array(data[position..<end])
        }

        mutating func loadNext() throws {
            guard next >= 2 * RZipKit.streamHeaderSize else { throw ArchiveError.damaged("The rzip file ends too early.") }
            let at = chunkStart + next
            let header = try input.read(at: at, count: Int(RZipKit.streamHeaderSize))
            let packedLength = Int(le32(header, 1)), length = Int(le32(header, 5))
            guard length <= RZipKit.maxBlock else { throw ArchiveError.damaged("An rzip block is impossibly large.") }
            var packed = try input.read(at: at + RZipKit.streamHeaderSize, count: packedLength)
            switch header[0] {
            case 3:
                guard packedLength == length else { throw ArchiveError.damaged("An rzip block has inconsistent sizes.") }
                data = packed
            case 4:
                var decoded = [UInt8](repeating: 0, count: length)
                var decodedLength = UInt32(length)
                let status = decoded.withUnsafeMutableBytes { out in
                    packed.withUnsafeMutableBytes { src in
                        bz2BuffToBuffDecompress(out.baseAddress?.assumingMemoryBound(to: CChar.self), &decodedLength,
                                                src.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32(packedLength), 0, 0)
                    }
                }
                guard status == 0, Int(decodedLength) == length else { throw ArchiveError.damaged("An rzip block can’t be decompressed.") }
                data = decoded
            default:
                throw ArchiveError.damaged("An rzip block has an unknown type.")
            }
            position = 0
            consumedBytes += RZipKit.streamHeaderSize + UInt64(packedLength)
            next = UInt64(le32(header, 9))
        }
    }

    // MARK: Output and history

    /// The decompressed bytes so far. Flushed bytes live in the history file, recent ones in `pending`; both serve matches.
    private struct Output {
        let history: File
        let limit: UInt64
        private(set) var flushed: UInt64 = 0
        private var pending = [UInt8]()
        /// Checksum of this chunk's output up to `checkedCount` pending bytes.
        private var chunkCRC: UInt32 = 0
        private var checkedCount = 0

        init(history: File, limit: UInt64) {
            self.history = history; self.limit = limit
        }

        var total: UInt64 { flushed + UInt64(pending.count) }
        var pendingBytes: Int { pending.count }

        mutating func beginChunk() {
            chunkCRC = 0
            checkedCount = pending.count
        }

        /// The checksum of everything this chunk produced.
        mutating func finishChunk() -> UInt32 {
            foldPending()
            return chunkCRC
        }

        private mutating func foldPending() {
            chunkCRC = pending[checkedCount...].withUnsafeBytes { ArchiveChecksum.crc32(chunkCRC, $0) }
            checkedCount = pending.count
        }

        mutating func append(_ bytes: [UInt8]) throws {
            guard UInt64(bytes.count) <= limit - total else { throw ArchiveError.damaged("An rzip file expands past its stated size.") }
            pending += bytes
        }

        mutating func copyMatch(offset: UInt64, length: Int) throws {
            guard offset >= 1, offset <= total, UInt64(length) <= limit - total else { throw ArchiveError.damaged("An rzip match points outside the data.") }
            var remaining = length
            while remaining > 0 {
                let from = total - offset
                if from >= flushed {
                    pending.append(pending[Int(from - flushed)])
                    remaining -= 1
                } else {
                    let count = Int(min(UInt64(remaining), flushed - from))
                    pending += try history.read(at: from, count: count)
                    remaining -= count
                }
            }
        }

        /// Writes the pending bytes to the history file and the sink.
        mutating func flush(to sink: (UnsafeRawBufferPointer) throws -> Void) throws {
            guard !pending.isEmpty else { return }
            foldPending()
            try history.write(pending, at: flushed)
            try pending.withUnsafeBytes { try sink($0) }
            flushed += UInt64(pending.count)
            pending.removeAll(keepingCapacity: true)
            checkedCount = 0
        }
    }

    // MARK: Files and numbers

    /// A file read with `pread`, so streams and history can be read at any offset; a short read means a cut-off file.
    private final class File {
        private let descriptor: Int32
        let size: UInt64

        init(open path: String, flags: Int32, mode: mode_t = 0) throws {
            descriptor = Darwin.open(path, flags, mode)
            guard descriptor >= 0 else { throw ArchiveError.failed("Couldn’t open a file.") }
            var info = stat()
            size = fstat(descriptor, &info) == 0 ? UInt64(info.st_size) : 0
        }

        func close() { Darwin.close(descriptor) }

        func read(at offset: UInt64, count: Int) throws -> [UInt8] {
            guard count > 0 else { return [] }
            guard offset <= UInt64(Int64.max) else { throw ArchiveError.damaged("The rzip file ends too early.") }
            var bytes = [UInt8](repeating: 0, count: count)
            var done = 0
            while done < count {
                let got = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress! + done, count - done, off_t(offset) + off_t(done)) }
                if got < 0 { throw ArchiveError.failed("Couldn’t read a file.") }
                if got == 0 { throw ArchiveError.damaged("The rzip file ends too early.") }
                done += got
            }
            return bytes
        }

        func write(_ bytes: [UInt8], at offset: UInt64) throws {
            var done = 0
            while done < bytes.count {
                let put = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress! + done, bytes.count - done, off_t(offset) + off_t(done)) }
                if put <= 0 { throw ArchiveError.failed("Couldn’t write the temporary history file.") }
                done += put
            }
        }
    }

    private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }
}
