import Foundation
@testable import ArchiveKit

// RZipKit: rzip files assembled in the test from the format description (stored and bzip2 blocks, several chunks).

private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
private func be32(_ v: UInt32) -> [UInt8] { le32(v).reversed() }

private enum Command {
    case literal([UInt8])
    case match(offset: Int, length: Int)
}

private enum BlockKind { case stored, bzip2 }

/// Appends what `commands` produce to `output` (the whole file's output so far) and returns the chunk's control and literal bytes.
private func chunkStreams(_ commands: [Command], output: inout [UInt8]) -> (control: [UInt8], literal: [UInt8], crc: UInt32) {
    var control = [UInt8](), literal = [UInt8]()
    let start = output.count
    for command in commands {
        switch command {
        case .literal(let bytes):
            control += [0, UInt8(bytes.count & 0xFF), UInt8(bytes.count >> 8)]
            literal += bytes
            output += bytes
        case .match(let offset, let length):
            control += [1, UInt8(length & 0xFF), UInt8(length >> 8)] + le32(UInt32(offset))
            // A deliberately invalid offset (damage cases) yields filler so the CRC is still well defined.
            for _ in 0..<length { output.append(offset >= 1 && offset <= output.count ? output[output.count - offset] : 0) }
        }
    }
    control += [0, 0, 0]
    return (control, literal, ArchiveChecksum.crc32(0, Array(output[start...])))
}

private func bzip2(_ bytes: [UInt8], in folder: URL) -> [UInt8] {
    let input = folder.appendingPathComponent("bz-\(UUID().uuidString)")
    guard (try? Data(bytes).write(to: input)) != nil, let handle = try? FileHandle(forReadingFrom: input) else { return [] }
    defer { try? handle.close(); try? FileManager.default.removeItem(at: input) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/bzip2")
    process.arguments = ["-c"]
    let pipe = Pipe()
    process.standardInput = handle
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return [UInt8](data)
}

/// Splits `bytes` into blocks at the given sizes (the last block takes the rest).
private func split(_ bytes: [UInt8], _ sizes: [Int]) -> [[UInt8]] {
    var blocks = [[UInt8]](), at = 0
    for size in sizes where at < bytes.count {
        let end = min(bytes.count, at + size)
        blocks.append(Array(bytes[at..<end])); at = end
    }
    if at < bytes.count || blocks.isEmpty { blocks.append(Array(bytes[at...])) }
    return blocks
}

/// One chunk: two stream headers, then the blocks of both streams interleaved and linked per stream.
private func chunk(control: [UInt8], literal: [UInt8], crc: UInt32, controlSplit: [Int] = [], literalSplit: [Int] = [],
                   kind: BlockKind = .stored, folder: URL) -> [UInt8] {
    let controlBlocks = split(control + le32(crc), controlSplit)
    let literalBlocks = literal.isEmpty ? [] : split(literal, literalSplit)
    var order: [(stream: Int, bytes: [UInt8])] = []
    for index in 0..<max(controlBlocks.count, literalBlocks.count) {
        if index < controlBlocks.count { order.append((0, controlBlocks[index])) }
        if index < literalBlocks.count { order.append((1, literalBlocks[index])) }
    }
    let payloads = order.map { kind == .bzip2 ? bzip2($0.bytes, in: folder) : $0.bytes }
    var offsets = [Int](), cursor = 26
    for payload in payloads { offsets.append(cursor); cursor += 13 + payload.count }
    var firsts = [0, 0], nexts = [Int](repeating: 0, count: order.count), lastOf = [-1, -1]
    for (index, item) in order.enumerated() {
        if lastOf[item.stream] < 0 { firsts[item.stream] = offsets[index] } else { nexts[lastOf[item.stream]] = offsets[index] }
        lastOf[item.stream] = index
    }
    var bytes: [UInt8] = []
    for stream in 0..<2 { bytes += [3] + le32(0) + le32(0) + le32(UInt32(firsts[stream])) }
    for (index, item) in order.enumerated() {
        bytes += [kind == .bzip2 ? 4 : 3] + le32(UInt32(payloads[index].count)) + le32(UInt32(item.bytes.count)) + le32(UInt32(nexts[index]))
        bytes += payloads[index]
    }
    return bytes
}

private func rzipHeader(size: UInt64) -> [UInt8] {
    [0x52, 0x5A, 0x49, 0x50, 2, 1] + be32(UInt32(size & 0xFFFF_FFFF)) + be32(UInt32(size >> 32)) + [UInt8](repeating: 0, count: 10)
}

private struct Decoded {
    var bytes = [UInt8]()
    var error: ArchiveError?
    var pieces = 0
}

private func decode(_ file: [UInt8], in folder: URL, cancelAfter pieces: Int? = nil) -> Decoded {
    let url = folder.appendingPathComponent("in-\(UUID().uuidString).rz")
    var result = Decoded()
    guard (try? Data(file).write(to: url)) != nil else { result.error = .failed("write"); return result }
    defer { try? FileManager.default.removeItem(at: url) }
    nonisolated(unsafe) var seen = 0
    do {
        try RZipKit.decompress(source: url, isCancelled: { pieces.map { seen >= $0 } ?? false }, sink: { buffer in
            seen += 1
            result.bytes += buffer
        })
    } catch {
        result.error = error as? ArchiveError ?? .failed("\(error)")
    }
    result.pieces = seen
    return result
}

private func isDamaged(_ error: ArchiveError?) -> Bool {
    if case .damaged = error { return true }
    return false
}

private struct Lcg {
    var state: UInt64
    mutating func next() -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(state >> 33)
    }
    mutating func bytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) } }
}

private func withFolder(_ body: (URL) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rzip-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    body(folder)
}

/// A whole file from several chunks, and the bytes it must decode to.
private func build(_ chunks: [[Command]], kind: BlockKind = .stored, controlSplit: [Int] = [], literalSplit: [Int] = [], folder: URL) -> (file: [UInt8], output: [UInt8]) {
    var output = [UInt8](), body = [UInt8]()
    for commands in chunks {
        let streams = chunkStreams(commands, output: &output)
        body += chunk(control: streams.control, literal: streams.literal, crc: streams.crc, controlSplit: controlSplit, literalSplit: literalSplit, kind: kind, folder: folder)
    }
    return (rzipHeader(size: UInt64(output.count)) + body, output)
}

func registerArchiveKitRZipTests() {
    SelfTest.cases.append(("ArchiveKit.rzip.stored", {
        withFolder { folder in
            let text = Array("The quick brown fox jumps over the lazy dog. ".utf8)
            let (file, output) = build([[.literal(text), .match(offset: text.count, length: 90), .literal([0x21]), .match(offset: 1, length: 40)]], folder: folder)
            let result = decode(file, in: folder)
            check(result.error == nil && result.bytes == output, "stored chunk with a repeated and an overlapping match: \(String(describing: result.error))")
            check(output.count == 45 + 90 + 1 + 40, "fixture size")
            let empty = decode(rzipHeader(size: 0), in: folder)
            check(empty.error == nil && empty.bytes.isEmpty, "an empty rzip file decodes to nothing")
        }
    }))

    SelfTest.cases.append(("ArchiveKit.rzip.bzip2", {
        withFolder { folder in
            var rng = Lcg(state: 5)
            let noise = rng.bytes(500)
            let chunks: [[Command]] = [[.literal(noise), .match(offset: 500, length: 700), .literal(Array("tail".utf8)), .match(offset: 3, length: 20)]]
            for (controlSplit, literalSplit) in [([Int](), [Int]()), ([5, 4, 9], [100, 150])] {
                let (file, output) = build(chunks, kind: .bzip2, controlSplit: controlSplit, literalSplit: literalSplit, folder: folder)
                let result = decode(file, in: folder)
                check(result.error == nil && result.bytes == output, "bzip2 blocks, control split \(controlSplit)")
            }
            let mixedSplit = build(chunks, controlSplit: [1, 1, 1, 2], literalSplit: [7], folder: folder)
            check(decode(mixedSplit.file, in: folder).bytes == mixedSplit.output, "stored blocks split inside commands")
        }
    }))

    SelfTest.cases.append(("ArchiveKit.rzip.chunks", {
        withFolder { folder in
            var rng = Lcg(state: 11)
            let head = rng.bytes(65_000)
            let big = (0..<20).map { _ in Command.literal(rng.bytes(65_535)) }
            let second: [Command] = [.literal(Array("second".utf8)), .match(offset: 1_300_000, length: 5_000), .match(offset: 3, length: 100)]
            let third: [Command] = [.match(offset: 60, length: 300), .literal([1, 2, 3])]
            let (file, output) = build([[.literal(head)] + big, second, third], folder: folder)
            check(output.count > 1_300_000, "history grows past one flush")
            let result = decode(file, in: folder)
            check(result.error == nil && result.bytes == output, "chunks whose matches reach back into earlier chunks and the history file")
            check(result.pieces >= 2, "output is streamed in pieces")
            check(decode(file, in: folder, cancelAfter: 1).error == .cancelled, "cancelled between chunks")
        }
    }))

    SelfTest.cases.append(("ArchiveKit.rzip.damage", {
        withFolder { folder in
            let text = Array("abcdefghijklmnopqrstuvwxyz".utf8)
            let (good, output) = build([[.literal(text), .match(offset: 26, length: 26)]], kind: .bzip2, folder: folder)
            check(decode(good, in: folder).bytes == output, "good file")

            var badMagic = good; badMagic[0] = 0x58
            check(isDamaged(decode(badMagic, in: folder).error), "bad magic")
            let stored = build([[.literal(text), .match(offset: 26, length: 26)]], folder: folder)
            var badCRC = stored.file; badCRC[badCRC.count - 1] ^= 1
            check(isDamaged(decode(badCRC, in: folder).error), "CRC mismatch")
            var badType = stored.file; badType[24] = 9
            check(isDamaged(decode(badType, in: folder).error), "bad stream type")
            check(isDamaged(decode(Array(stored.file[0..<20]), in: folder).error), "header cut short")

            var short = rzipHeader(size: 100)
            var scratch = [UInt8]()
            let streams = chunkStreams([.literal(text)], output: &scratch)
            short += chunk(control: streams.control, literal: streams.literal, crc: streams.crc, folder: folder)
            check(isDamaged(decode(short, in: folder).error), "stated size larger than the data (no second chunk)")
            var tooLong = rzipHeader(size: 10)
            tooLong += chunk(control: streams.control, literal: streams.literal, crc: streams.crc, folder: folder)
            check(isDamaged(decode(tooLong, in: folder).error), "data larger than the stated size")

            var farOutput = [UInt8]()
            let far = chunkStreams([.literal(text), .match(offset: 27, length: 4)], output: &farOutput)
            let farFile = rzipHeader(size: 30) + chunk(control: far.control, literal: far.literal, crc: far.crc, folder: folder)
            check(isDamaged(decode(farFile, in: folder).error), "match offset beyond the output")
            var zeroOutput = [UInt8]()
            let zero = chunkStreams([.literal(text), .match(offset: 0, length: 4)], output: &zeroOutput)
            let zeroFile = rzipHeader(size: 30) + chunk(control: zero.control, literal: zero.literal, crc: zero.crc, folder: folder)
            check(isDamaged(decode(zeroFile, in: folder).error), "match offset zero")

            let huge = decode(rzipHeader(size: 3 << 40), in: folder)
            if case .tooLarge = huge.error {} else { check(false, "declared size over 1 TiB is tooLarge") }
        }
    }))

    SelfTest.cases.append(("ArchiveKit.rzip.fuzz", {
        withFolder { folder in
            let (good, _) = build([[.literal(Array("fuzzing the rzip decoder ".utf8)), .match(offset: 25, length: 100)], [.match(offset: 7, length: 50)]], kind: .bzip2, controlSplit: [6], folder: folder)
            var truncated = 0
            for length in 0..<good.count - 1 where decode(Array(good[0..<length]), in: folder).error != nil { truncated += 1 }
            check(truncated == good.count - 1, "every truncation is rejected")
            var rng = Lcg(state: 3)
            for _ in 0..<300 {
                var mutated = good
                for _ in 0..<(1 + rng.next() % 3) { mutated[rng.next() % mutated.count] = UInt8(truncatingIfNeeded: rng.next()) }
                _ = decode(mutated, in: folder)
            }
            check(true, "mutated input never crashes")
        }
    }))
}
