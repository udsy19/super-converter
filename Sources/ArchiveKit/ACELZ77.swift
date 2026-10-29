// Adapted from acefile acefile.py, LZ77 and AceMode (BSD-2-Clause, Copyright (C) 2017-2026 Daniel Roethlisberger; the licence
// text is in ACEKit.swift). Changes: Swift; a read may stop early at `target` bytes while `limit` still bounds the
// entry, so large entries are decoded in blocks; every distance is checked against the bytes held.

/// A compression sub-mode announced inside an ACE 2.0 block stream.
struct ACEMode {
    static let lz77 = 0, lz77Delta = 1, lz77Exe = 2, sound8 = 3, sound16 = 4, sound32a = 5, sound32b = 6, pic = 7

    var mode: Int
    var deltaDist = 0
    var deltaLen = 0
    var exeMode = 0

    static func read(_ bs: ACEBitStream) throws -> ACEMode {
        var m = ACEMode(mode: try bs.read(8))
        if m.mode == lz77Delta {
            m.deltaDist = try bs.read(8)
            m.deltaLen = try bs.read(17)
        } else if m.mode == lz77Exe {
            m.exeMode = try bs.read(8)
        }
        return m
    }
}

/// The LZ77 window. It also holds bytes produced by the other modes, so later copies can reach back into them.
final class ACEDictionary {
    static let minSize = 1 << 10, maxSize = 1 << 22

    private var bytes: [UInt8] = []
    private var size = ACEDictionary.minSize

    func setSize(_ wanted: Int) { size = min(max(wanted, size), ACEDictionary.maxSize) }

    func append(_ b: UInt8) { bytes.append(b) }

    func copy(distance: Int, length: Int) throws {
        let start = bytes.count - distance
        guard start >= 0 else { throw ArchiveError.damaged("An LZ77 copy reaches before the start of the data.") }
        bytes.reserveCapacity(bytes.count + length)
        for i in start..<start + length { bytes.append(bytes[i]) }
    }

    /// Registers bytes produced by the other modes.
    func register(_ chunk: [UInt8]) {
        bytes.append(contentsOf: chunk)
        truncate()
    }

    /// The last `n` bytes appended.
    func takeLast(_ n: Int) -> [UInt8] {
        let chunk = Array(bytes[(bytes.count - n)...])
        truncate()
        return chunk
    }

    // Trimmed only when it holds many times its size, to avoid copying on every block (as in the original).
    private func truncate() {
        if bytes.count > 8 * size { bytes.removeFirst(bytes.count - size) }
    }
}

/// ACE 1.0 and 2.0 LZ77: Huffman-coded literals and copies, in blocks that each carry their own two trees.
final class ACELZ77 {
    static let maxCodeWidth = 11
    private static let maxDistAtLen2 = 255, maxDistAtLen3 = 8191
    private static let typeCode = 260 + 22 + 1
    private static let numMainCodes = 260 + 22 + 2
    private static let numLenCodes = 256 - 1

    let dictionary = ACEDictionary()
    private var mainTree: ACEHuffman.Tree?
    private var lenTree: ACEHuffman.Tree?
    private var symbolsLeft = 0
    private var history = [Int](repeating: 0, count: 4)

    /// Forgets everything that depends on the data: trees and distance history (not the window).
    func reinit() {
        mainTree = nil; lenTree = nil; symbolsLeft = 0
        history = [Int](repeating: 0, count: 4)
    }

    private func readMainSymbol(_ bs: ACEBitStream) throws -> Int {
        if symbolsLeft == 0 {
            mainTree = try ACEHuffman.readTree(bs, maxWidth: ACELZ77.maxCodeWidth, numCodes: ACELZ77.numMainCodes)
            lenTree = try ACEHuffman.readTree(bs, maxWidth: ACELZ77.maxCodeWidth, numCodes: ACELZ77.numLenCodes)
            symbolsLeft = try bs.read(15)
        }
        symbolsLeft -= 1
        guard let tree = mainTree else { throw ArchiveError.damaged("An LZ77 block has no tree.") }
        return try tree.readSymbol(bs)
    }

    private func readLenSymbol(_ bs: ACEBitStream) throws -> Int {
        guard let tree = lenTree else { throw ArchiveError.damaged("An LZ77 block has no tree.") }
        return try tree.readSymbol(bs)
    }

    private func retrieve(_ offset: Int) -> Int {
        let d = history.remove(at: history.count - offset - 1)
        history.append(d)
        return d
    }

    /// Decodes until at least `target` bytes were produced or a mode instruction was read. A single copy may not take the
    /// output past `limit`. Returns the bytes and the mode instruction that ended the block, if any.
    func read(_ bs: ACEBitStream, target: Int, limit: Int) throws -> (chunk: [UInt8], mode: ACEMode?) {
        var have = 0
        var next: ACEMode?
        while have < target {
            let symbol = try readMainSymbol(bs)
            if symbol <= 255 {
                dictionary.append(UInt8(symbol))
                have += 1
            } else if symbol < ACELZ77.typeCode {
                var length: Int, distance: Int
                if symbol <= 259 {
                    length = try readLenSymbol(bs)
                    let offset = symbol & 3
                    distance = retrieve(offset)
                    length += offset > 1 ? 3 : 2
                } else {
                    distance = try bs.readKnownWidth(symbol - 260)
                    length = try readLenSymbol(bs)
                    history.removeFirst(); history.append(distance)
                    if distance <= ACELZ77.maxDistAtLen2 { length += 2 } else if distance <= ACELZ77.maxDistAtLen3 { length += 3 } else { length += 4 }
                }
                distance += 1
                guard have + length <= limit else { throw ArchiveError.damaged("An LZ77 copy runs past the end of the file.") }
                try dictionary.copy(distance: distance, length: length)
                have += length
            } else if symbol == ACELZ77.typeCode {
                next = try ACEMode.read(bs)
                break
            } else {
                throw ArchiveError.damaged("An LZ77 symbol is out of range.")
            }
        }
        return (dictionary.takeLast(have), next)
    }
}
