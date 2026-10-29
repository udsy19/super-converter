// Adapted from acefile acefile.py, ACE (BSD-2-Clause, Copyright (C) 2017-2026 Daniel Roethlisberger; the licence text is in
// ACEKit.swift). Changes: Swift; output goes to a callback in blocks of at most 1 MiB instead of being collected; the EXE
// filter keeps a trailing CALL/JMP back only while more data follows; inputs that would loop or index out of range in the
// original are reported as damaged.

/// The three ways an entry is stored, sharing one window across the entries of a solid archive.
final class ACEDecoder {
    private static let blockSize = 1 << 20

    private let lz77 = ACELZ77()
    private let sound = ACESound()
    private let pic = ACEPic()
    private let isCancelled: () -> Bool

    init(isCancelled: @escaping () -> Bool) { self.isCancelled = isCancelled }

    private func checkCancelled() throws {
        if isCancelled() { throw ArchiveError.cancelled }
    }

    /// Method 0: the bytes as they are; they still enter the window so later entries of a solid archive can copy from them.
    func stored(_ source: ACEPackedSource, size: Int, dictionarySize: Int, emit: ([UInt8]) throws -> Void) throws {
        lz77.dictionary.setSize(dictionarySize)
        var produced = 0
        while produced < size {
            try checkCancelled()
            let chunk = try source.nextBytes(limit: min(size - produced, ACEDecoder.blockSize))
            guard !chunk.isEmpty else { throw ArchiveError.damaged("A stored file is cut short.") }
            lz77.dictionary.register(chunk)
            try emit(chunk)
            produced += chunk.count
        }
    }

    /// Method 1: ACE 1.0 LZ77.
    func lz77Only(_ source: ACEPackedSource, size: Int, dictionarySize: Int, emit: ([UInt8]) throws -> Void) throws {
        lz77.dictionary.setSize(dictionarySize)
        lz77.reinit()
        let bs = ACEBitStream(source)
        var produced = 0
        while produced < size {
            try checkCancelled()
            let remaining = size - produced
            let (chunk, mode) = try lz77.read(bs, target: min(remaining, ACEDecoder.blockSize), limit: remaining)
            guard mode == nil else { throw ArchiveError.damaged("An ACE 1.0 file switches modes.") }
            try emit(chunk)
            produced += chunk.count
        }
    }

    /// Method 2: ACE 2.0 blocks, each in one of the LZ77, DELTA, EXE, SOUND or PIC modes.
    func blocked(_ source: ACEPackedSource, size: Int, dictionarySize: Int, emit: ([UInt8]) throws -> Void) throws {
        let bs = ACEBitStream(source)
        lz77.dictionary.setSize(dictionarySize)
        lz77.reinit()

        var exeLeftover: [UInt8] = []
        var lastDelta = 0
        var nextMode: ACEMode?
        var mode = ACEMode(mode: ACEMode.lz77)
        var produced = 0

        while produced < size {
            try checkCancelled()
            if let next = nextMode {
                if mode.mode != next.mode {
                    if (ACEMode.sound8...ACEMode.sound32b).contains(next.mode) {
                        sound.reinit(mode: next.mode)
                    } else if next.mode == ACEMode.pic {
                        try pic.reinit(bs)
                    }
                }
                mode = next
                nextMode = nil
            }

            let remaining = size - produced
            var out: [UInt8] = []
            switch mode.mode {
            case ACEMode.lz77Delta:
                guard mode.deltaDist > 0, mode.deltaLen > 0, mode.deltaLen <= remaining else {
                    throw ArchiveError.damaged("A DELTA block has impossible parameters.")
                }
                var delta: [UInt8] = []
                while delta.count < mode.deltaLen {
                    let want = mode.deltaLen - delta.count
                    let (chunk, next) = try lz77.read(bs, target: want, limit: want)
                    delta.append(contentsOf: chunk)
                    if let next {
                        guard delta.isEmpty else { throw ArchiveError.damaged("A DELTA block ends with a mode change.") }
                        nextMode = next
                        break
                    }
                }
                if delta.isEmpty { continue }

                for i in delta.indices {
                    delta[i] = UInt8(truncatingIfNeeded: Int(delta[i]) + lastDelta)
                    lastDelta = Int(delta[i])
                }
                let planeSize = mode.deltaLen / mode.deltaDist
                out.reserveCapacity(delta.count)
                for pos in 0..<planeSize {
                    var plane = 0
                    while plane < mode.deltaLen {
                        guard plane + pos < delta.count else { throw ArchiveError.damaged("A DELTA block is not a whole number of planes.") }
                        out.append(delta[plane + pos])
                        plane += planeSize
                    }
                }

            case ACEMode.lz77, ACEMode.lz77Exe:
                out = exeLeftover
                exeLeftover = []
                let want = remaining - out.count
                if want > 0 {
                    let (chunk, next) = try lz77.read(bs, target: min(want, ACEDecoder.blockSize), limit: want)
                    out.append(contentsOf: chunk)
                    nextMode = next
                }
                if mode.mode == ACEMode.lz77Exe {
                    exeLeftover = ACEDecoder.unfilterExe(&out, exeMode: mode.exeMode, position: produced, more: produced + out.count < size)
                }

            case ACEMode.sound8...ACEMode.sound32b:
                let (chunk, next) = try sound.read(bs, count: min(remaining, ACEDecoder.blockSize) & ~3)
                out = chunk
                nextMode = next
                lz77.dictionary.register(out)

            case ACEMode.pic:
                let (chunk, next) = try pic.read(bs, count: min(remaining, ACEDecoder.blockSize))
                out = chunk
                nextMode = next
                lz77.dictionary.register(out)

            default:
                throw ArchiveError.damaged("An ACE block names an unknown mode.")
            }

            guard out.count <= remaining else { throw ArchiveError.damaged("An ACE block is longer than its file.") }
            guard !out.isEmpty || nextMode != nil else { throw ArchiveError.damaged("An ACE block makes no progress.") }
            try emit(out)
            produced += out.count
        }
    }

    /// Undoes the x86 filter: CALL and JMP targets were made absolute for better compression. `position` is the file
    /// offset of `bytes[0]`. A CALL or JMP too close to the end to be complete is cut off and returned for the next block
    /// when `more` data follows.
    private static func unfilterExe(_ bytes: inout [UInt8], exeMode: Int, position: Int, more: Bool) -> [UInt8] {
        let n = bytes.count
        var i = 0
        while i < n {
            if i + 4 >= n {
                guard more, let j = (i..<n).first(where: { bytes[$0] == 0xE8 || bytes[$0] == 0xE9 }) else { return [] }
                let tail = Array(bytes[j...])
                bytes.removeSubrange(j...)
                return tail
            }
            let pos = position + i
            if bytes[i] == 0xE8, exeMode != 0 {
                let rel = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) << 16 | Int(bytes[i + 4]) << 24
                let fixed = (rel - pos) & 0xFFFF_FFFF
                for k in 0..<4 { bytes[i + 1 + k] = UInt8(truncatingIfNeeded: fixed >> (8 * k)) }
                i += 5
            } else if bytes[i] == 0xE8 || bytes[i] == 0xE9 {
                let rel = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8
                let fixed = (rel - pos) & 0xFFFF
                bytes[i + 1] = UInt8(truncatingIfNeeded: fixed)
                bytes[i + 2] = UInt8(truncatingIfNeeded: fixed >> 8)
                i += 3
            } else {
                i += 1
            }
        }
        return []
    }
}
