// Adapted from acefile acefile.py, BitStream, Huffman, AceCRC32 (BSD-2-Clause, Copyright (C) 2017-2026 Daniel Roethlisberger;
// the licence text is in ACEKit.swift). Changes: Swift; the stream reads one entry's packed bytes (decrypting on the way)
// through `ACEPackedSource`; reads are capped at 31 bits; table lookups are bounds-checked.

import Foundation

/// ACE checksums: the standard CRC-32 without the final inversion; the 16-bit one is its low half.
enum ACECRC {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// Running state; start at 0 and read `sum` at the end.
    struct Sum {
        private var state: UInt32 = 0xFFFF_FFFF
        init() {}

        mutating func add(_ bytes: UnsafeRawBufferPointer) {
            var c = state
            for b in bytes { c = ACECRC.table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
            state = c
        }

        mutating func add(_ bytes: [UInt8]) { bytes.withUnsafeBytes { add($0) } }

        var sum: UInt32 { state }
    }

    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var s = Sum(); s.add(bytes); return s.sum
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 { UInt16(truncatingIfNeeded: crc32(bytes)) }
}

/// The packed bytes of one entry, handed out in blocks and decrypted when the entry is password protected.
final class ACEPackedSource {
    private static let blockSize = 1 << 16

    private let data: Data
    private var offset: Int
    private let end: Int
    private var cipher: ACEBlowfish?
    private var block: [UInt8] = []
    private var blockPos = 0

    init(data: Data, range: Range<Int>, cipher: ACEBlowfish?) {
        self.data = data; self.offset = range.lowerBound; self.end = range.upperBound; self.cipher = cipher
    }

    private func refill() throws {
        block.removeAll(keepingCapacity: true); blockPos = 0
        let n = min(ACEPackedSource.blockSize, end - offset)
        guard n > 0 else { return }
        block = Array(data[offset..<offset + n])
        offset += n
        if cipher != nil {
            guard n % ACEBlowfish.blockSize == 0 else { throw ArchiveError.damaged("An encrypted block is cut short.") }
            cipher!.decrypt(&block)
        }
    }

    /// The next little-endian 32-bit word, nil at the end.
    func nextWord() throws -> UInt32? {
        if block.count - blockPos < 4 {
            guard block.count == blockPos else { throw ArchiveError.damaged("The packed data ends inside a 32-bit word.") }
            try refill()
            if block.isEmpty { return nil }
            guard block.count >= 4 else { throw ArchiveError.damaged("The packed data ends inside a 32-bit word.") }
        }
        let i = blockPos
        blockPos += 4
        return UInt32(block[i]) | UInt32(block[i + 1]) << 8 | UInt32(block[i + 2]) << 16 | UInt32(block[i + 3]) << 24
    }

    /// Up to `limit` bytes; empty at the end.
    func nextBytes(limit: Int) throws -> [UInt8] {
        if blockPos == block.count { try refill() }
        let n = min(limit, block.count - blockPos)
        defer { blockPos += n }
        return Array(block[blockPos..<blockPos + n])
    }
}

/// Intel-endian 32-bit-word, MSB first bit reader. Peeking past the end yields zero bits; consuming past it fails.
final class ACEBitStream {
    private let source: ACEPackedSource
    /// The valid bits are the top `count` bits.
    private var acc: UInt64 = 0
    private var count = 0
    private var exhausted = false

    init(_ source: ACEPackedSource) { self.source = source }

    private func fill() throws {
        while count <= 32, !exhausted {
            if let word = try source.nextWord() {
                acc |= UInt64(word) << UInt64(32 - count)
                count += 32
            } else { exhausted = true }
        }
    }

    func peek(_ bits: Int) throws -> Int {
        precondition(bits >= 0 && bits <= 31)
        if count < bits { try fill() }
        return Int(acc >> UInt64(64 - bits))
    }

    func skip(_ bits: Int) throws {
        precondition(bits >= 0 && bits <= 31)
        if count < bits { try fill() }
        guard count >= bits else { throw ArchiveError.damaged("The packed data ends too early.") }
        acc <<= UInt64(bits)
        count -= bits
    }

    func read(_ bits: Int) throws -> Int {
        let v = try peek(bits)
        try skip(bits)
        return v
    }

    /// A Golomb-Rice code with `rBits` remainder bits; when `signed`, the lowest bit is the sign.
    func readGolombRice(_ rBits: Int, signed: Bool = false) throws -> Int {
        guard rBits <= 31 else { throw ArchiveError.damaged("A Golomb-Rice parameter is out of range.") }
        var value = rBits == 0 ? 0 : try read(rBits)
        while try read(1) == 1 {
            value += 1 << rBits
            guard value < 1 << 40 else { throw ArchiveError.damaged("A Golomb-Rice value is out of range.") }
        }
        guard signed else { return value }
        return value & 1 != 0 ? -(value >> 1) - 1 : value >> 1
    }

    /// An unsigned integer of known bit width whose top bit (always 1) is not stored.
    func readKnownWidth(_ bits: Int) throws -> Int {
        if bits < 2 { return bits }
        return try read(bits - 1) + (1 << (bits - 1))
    }
}

/// Canonical-ish Huffman codes as ACE stores them: widths only, rebuilt with the original's own (unstable) ordering.
enum ACEHuffman {
    struct Tree {
        let codes: [UInt16]
        let widths: [Int]
        let maxWidth: Int

        func readSymbol(_ bs: ACEBitStream) throws -> Int {
            let index = try bs.peek(maxWidth)
            guard index < codes.count else { throw ArchiveError.damaged("A Huffman code is not in the table.") }
            let symbol = Int(codes[index])
            try bs.skip(widths[symbol])
            return symbol
        }
    }

    private static let widthBits = 3
    private static let maxWidthWidth = (1 << widthBits) - 1

    /// In-place quicksort of `keys` and `values`, descending by key. The tree rebuild depends on this exact unstable order.
    private static func quicksort(_ keys: inout [Int], _ values: inout [Int]) {
        func swap(_ a: Int, _ b: Int) { keys.swapAt(a, b); values.swapAt(a, b) }
        func sort(_ left: Int, _ right: Int) {
            var newLeft = left, newRight = right
            let m = keys[right]
            while true {
                while newLeft < keys.count, keys[newLeft] > m { newLeft += 1 }
                while newRight >= 0, keys[newRight] < m { newRight -= 1 }
                if newLeft <= newRight {
                    swap(newLeft, newRight)
                    newLeft += 1; newRight -= 1
                }
                if newLeft >= newRight { break }
            }
            if left < newRight {
                if left < newRight - 1 { sort(left, newRight) } else if keys[left] < keys[newRight] { swap(left, newRight) }
            }
            if right > newLeft {
                if newLeft < right - 1 { sort(newLeft, right) } else if keys[newLeft] < keys[right] { swap(newLeft, right) }
            }
        }
        if !keys.isEmpty { sort(0, keys.count - 1) }
    }

    private static func makeTree(_ widths: inout [Int], _ maxWidth: Int) throws -> Tree {
        var symbols = Array(0..<widths.count)
        var sortedWidths = widths
        quicksort(&sortedWidths, &symbols)

        var used = 0
        while used < sortedWidths.count, sortedWidths[used] != 0 { used += 1 }
        if used < 2 {
            widths[symbols[0]] = 1
            if used == 0 { used = 1 }
        }
        symbols.removeSubrange(used...)
        sortedWidths.removeSubrange(used...)

        var codes: [UInt16] = []
        let maxCodes = 1 << maxWidth
        for (symbol, width) in zip(symbols.reversed(), sortedWidths.reversed()) {
            guard width <= maxWidth else { throw ArchiveError.damaged("A Huffman code is too long.") }
            codes.append(contentsOf: repeatElement(UInt16(symbol), count: 1 << (maxWidth - width)))
            guard codes.count <= maxCodes else { throw ArchiveError.damaged("A Huffman table is over-subscribed.") }
        }
        return Tree(codes: codes, widths: widths, maxWidth: maxWidth)
    }

    /// Reads a tree of at most `numCodes` + 1 symbols with codes up to `maxWidth` bits from the stream.
    static func readTree(_ bs: ACEBitStream, maxWidth: Int, numCodes: Int) throws -> Tree {
        let numWidths = min(try bs.read(9) + 1, numCodes + 1)
        let lowerWidth = try bs.read(4)
        let upperWidth = try bs.read(4)

        var widthWidths: [Int] = []
        for _ in 0...upperWidth { widthWidths.append(try bs.read(widthBits)) }
        let widthTree = try makeTree(&widthWidths, maxWidthWidth)

        var widths: [Int] = []
        while widths.count < numWidths {
            let symbol = try widthTree.readSymbol(bs)
            if symbol < upperWidth {
                widths.append(symbol)
            } else {
                let length = min(try bs.read(4) + 4, numWidths - widths.count)
                widths.append(contentsOf: repeatElement(0, count: length))
            }
        }

        if upperWidth > 0 {
            for i in 1..<widths.count { widths[i] = (widths[i] + widths[i - 1]) % upperWidth }
        }
        for i in 0..<widths.count where widths[i] > 0 { widths[i] += lowerWidth }
        return try makeTree(&widths, maxWidth)
    }
}
