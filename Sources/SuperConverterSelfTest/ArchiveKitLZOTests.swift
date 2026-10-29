import Foundation
@testable import ArchiveKit

// LZOKit: hand-assembled LZO1X streams (every opcode family) inside lzop containers, checksums, and hostile input.

private func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

/// Builds LZO1X instruction streams together with the bytes they must decode to.
private struct LZOAssembler {
    var code = [UInt8]()
    var expected = [UInt8]()

    /// 17 + n opcode that starts a stream with 5...238 literals.
    mutating func firstLiterals(_ bytes: [UInt8]) {
        code += [UInt8(17 + bytes.count)] + bytes
        expected += bytes
    }

    /// 18...21 opcode: 0...3 literals, leaving that many as the state.
    mutating func firstShortLiterals(_ bytes: [UInt8]) {
        code += [UInt8(17 + bytes.count)] + bytes
        expected += bytes
    }

    /// A literal run of 4 or more bytes; valid when the previous instruction left no trailing literals.
    mutating func literalRun(_ bytes: [UInt8]) {
        if bytes.count <= 18 {
            code.append(UInt8(bytes.count - 3))
        } else {
            let rest = bytes.count - 18
            let zeros = rest % 255 == 0 ? rest / 255 - 1 : rest / 255
            code += [0] + [UInt8](repeating: 0, count: zeros) + [UInt8(rest - zeros * 255)]
        }
        code += bytes
        expected += bytes
    }

    private mutating func copy(distance: Int, length: Int, trailing: [UInt8]) {
        for _ in 0..<length { expected.append(expected[expected.count - distance]) }
        expected += trailing
        code += trailing
    }

    /// M2: 3...8 bytes from up to 2048 back.
    mutating func m2(distance: Int, length: Int, trailing: [UInt8] = []) {
        let d = distance - 1
        code += [UInt8(((length - 1) << 5) | ((d & 7) << 2) | trailing.count), UInt8(d >> 3)]
        copy(distance: distance, length: length, trailing: trailing)
    }

    /// M3: up to 16384 back; lengths above 33 use the extended form.
    mutating func m3(distance: Int, length: Int, trailing: [UInt8] = []) {
        if length <= 33 {
            code.append(UInt8(0x20 | (length - 2)))
        } else {
            code += [0x20] + extended(length - 33)
        }
        let d = (distance - 1) << 2 | trailing.count
        code += [UInt8(d & 0xFF), UInt8(d >> 8)]
        copy(distance: distance, length: length, trailing: trailing)
    }

    /// M4: 16385...49151 back.
    mutating func m4(distance: Int, length: Int, trailing: [UInt8] = []) {
        let offset = distance - 16384
        let high = UInt8((offset >> 14) << 3)
        if length <= 9 {
            code.append(0x10 | high | UInt8(length - 2))
        } else {
            code += [0x10 | high] + extended(length - 9)
        }
        let d = (offset & 0x3FFF) << 2 | trailing.count
        code += [UInt8(d & 0xFF), UInt8(d >> 8)]
        copy(distance: distance, length: length, trailing: trailing)
    }

    /// M1 after literals: 2 bytes from up to 1024 back (state 1...3) or 3 bytes from 2049...3072 back (state 4).
    mutating func m1(distance: Int, length: Int, trailing: [UInt8] = []) {
        let d = distance - (length == 3 ? 2049 : 1)
        code += [UInt8((d & 3) << 2 | trailing.count), UInt8(d >> 2)]
        copy(distance: distance, length: length, trailing: trailing)
    }

    mutating func end() { code += [0x11, 0, 0] }

    /// Zero bytes each worth 255 and a final non-zero byte, together `value`.
    private func extended(_ value: Int) -> [UInt8] {
        let zeros = value % 255 == 0 ? value / 255 - 1 : value / 255
        return [UInt8](repeating: 0, count: zeros) + [UInt8(value - zeros * 255)]
    }
}

private func lzopFile(blocks: [(unpacked: [UInt8], packed: [UInt8]?)], flags: UInt32 = 0, name: String = "", extra: Bool = false) -> [UInt8] {
    var header = [UInt8]()
    header += [0x10, 0x30, 0x20, 0x80, 0x09, 0x40, 1, 5]
    header += be32(flags | (extra ? 0x40 : 0))
    header += be32(0o644) + be32(1_700_000_000) + be32(0)
    header += [UInt8(name.utf8.count)] + Array(name.utf8)
    var file: [UInt8] = [0x89, 0x4C, 0x5A, 0x4F, 0x00, 0x0D, 0x0A, 0x1A, 0x0A] + header
    file += be32(flags & 0x1000 != 0 ? ArchiveChecksum.crc32(0, header) : ArchiveChecksum.adler32(header))
    if extra { file += be32(3) + [1, 2, 3] + be32(0) }
    for block in blocks {
        let packed = block.packed ?? block.unpacked
        file += be32(UInt32(block.unpacked.count)) + be32(UInt32(packed.count))
        if flags & 0x1 != 0 { file += be32(ArchiveChecksum.adler32(block.unpacked)) }
        if flags & 0x100 != 0 { file += be32(ArchiveChecksum.crc32(0, block.unpacked)) }
        if packed.count < block.unpacked.count {
            if flags & 0x2 != 0 { file += be32(ArchiveChecksum.adler32(packed)) }
            if flags & 0x200 != 0 { file += be32(ArchiveChecksum.crc32(0, packed)) }
        }
        file += packed
    }
    return file + be32(0)
}

private struct Decoded {
    var bytes = [UInt8]()
    var name: String?
    var error: ArchiveError?
}

private func decode(_ file: [UInt8], in folder: URL, cancelAfter blocks: Int? = nil) -> Decoded {
    let url = folder.appendingPathComponent("in-\(UUID().uuidString).lzo")
    var result = Decoded()
    guard (try? Data(file).write(to: url)) != nil else { result.error = .failed("write"); return result }
    defer { try? FileManager.default.removeItem(at: url) }
    nonisolated(unsafe) var seen = 0
    do {
        result.name = try LZOKit.decompress(source: url, isCancelled: { blocks.map { seen >= $0 } ?? false }, sink: { buffer in
            seen += 1
            result.bytes += buffer
        })
    } catch {
        result.error = error as? ArchiveError ?? .failed("\(error)")
    }
    return result
}

private func isDamaged(_ error: ArchiveError?) -> Bool {
    if case .damaged = error { return true }
    return false
}

/// A repeatable pseudo-random byte source for fixtures and mutations.
private struct Lcg {
    var state: UInt64
    mutating func next() -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(state >> 33)
    }
    mutating func bytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) } }
}

private func everyOpcodeStream() -> LZOAssembler {
    var rng = Lcg(state: 7)
    var a = LZOAssembler()
    a.firstShortLiterals(Array("abc".utf8))
    a.m2(distance: 3, length: 6, trailing: [0x58])
    a.m1(distance: 4, length: 2, trailing: [0x59, 0x5A])
    a.m2(distance: 1, length: 8)
    a.literalRun(rng.bytes(3000))
    a.m1(distance: 2500, length: 3)
    a.m3(distance: 12, length: 10, trailing: [0x51])
    a.m2(distance: 5, length: 3)
    a.literalRun(rng.bytes(40_000))
    a.m4(distance: 17_000, length: 9, trailing: [0x6D, 0x6E])
    a.m2(distance: 7, length: 4)
    a.literalRun(Array("wxyz".utf8))
    a.m4(distance: 20_000, length: 40)
    a.m3(distance: 300, length: 600)
    a.m4(distance: 33_000, length: 5)
    a.end()
    return a
}

private func withFolder(_ body: (URL) -> Void) {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lzo-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    body(folder)
}

func registerArchiveKitLZOTests() {
    SelfTest.cases.append(("ArchiveKit.lzo.literals", {
        withFolder { folder in
            var a = LZOAssembler()
            a.firstLiterals(Array("hello, lzo world".utf8))
            a.end()
            check(a.code == [17 + 16] + Array("hello, lzo world".utf8) + [0x11, 0, 0], "literal-only stream layout")
            check((try? LZOKit.lzo1xDecompress(a.code, expectedSize: 16)) == a.expected, "literal-only stream decodes")
            a.code.removeLast(3)
            a.m2(distance: 16, length: 8)
            a.end()
            let result = decode(lzopFile(blocks: [(a.expected, a.code)], name: "hello.txt"), in: folder)
            check(result.error == nil && result.bytes == a.expected, "literals plus a match in a container: \(String(describing: result.error))")
            check(result.name == "hello.txt", "stored name is returned")
            let unnamed = decode(lzopFile(blocks: [(a.expected, a.code)]), in: folder)
            check(unnamed.name == nil && unnamed.bytes == a.expected, "empty name gives nil")
        }
    }))

    SelfTest.cases.append(("ArchiveKit.lzo.matches", {
        withFolder { folder in
            let a = everyOpcodeStream()
            check(a.expected.count > 40_000, "fixture is large enough to reach every opcode")
            let direct = try? LZOKit.lzo1xDecompress(a.code, expectedSize: a.expected.count)
            check(direct == a.expected, "M1, M2, M3, M4 (long and overlapping) decode to the model output")
            let result = decode(lzopFile(blocks: [(a.expected, a.code)]), in: folder)
            check(result.error == nil && result.bytes == a.expected, "matches inside a container")
            check(!isDamaged(result.error), "no error")
            check((try? LZOKit.lzo1xDecompress(a.code, expectedSize: a.expected.count + 1)) == nil, "short output is rejected")
            check((try? LZOKit.lzo1xDecompress(a.code, expectedSize: a.expected.count - 1)) == nil, "long output is rejected")
        }
    }))

    SelfTest.cases.append(("ArchiveKit.lzo.blocks", {
        withFolder { folder in
            var first = LZOAssembler()
            first.firstLiterals(Array("first block ".utf8))
            first.m2(distance: 12, length: 8)
            first.end()
            let stored = Array("stored block, copied verbatim".utf8)
            let second = everyOpcodeStream()
            let expected = first.expected + stored + second.expected
            for flags: UInt32 in [0, 0x1, 0x2, 0x3, 0x100, 0x200, 0x303, 0x1000, 0x1303] {
                let file = lzopFile(blocks: [(first.expected, first.code), (stored, nil), (second.expected, second.code)], flags: flags, name: "multi.bin")
                let result = decode(file, in: folder)
                check(result.error == nil && result.bytes == expected && result.name == "multi.bin", "three blocks with flags \(String(flags, radix: 16))")
            }
            let withExtra = decode(lzopFile(blocks: [(stored, nil)], extra: true), in: folder)
            check(withExtra.bytes == stored, "header extra field is skipped")
        }
    }))

    SelfTest.cases.append(("ArchiveKit.lzo.damage", {
        withFolder { folder in
            let a = everyOpcodeStream()
            let flags: UInt32 = 0x303
            let good = lzopFile(blocks: [(a.expected, a.code)], flags: flags, name: "x")
            check(decode(good, in: folder).bytes == a.expected, "checksummed file decodes")

            var badMagic = good; badMagic[0] = 0
            check(isDamaged(decode(badMagic, in: folder).error), "bad magic")
            var badHeader = good; badHeader[20] ^= 1
            check(isDamaged(decode(badHeader, in: folder).error), "header checksum mismatch")
            let dataSumAt = 9 + 8 + 2 + 4 + 4 + 4 + 4 + 4 + 1 + 1 + 4 + 8
            var badData = good; badData[dataSumAt] ^= 0xFF
            check(isDamaged(decode(badData, in: folder).error), "decompressed-data checksum mismatch")
            var badPacked = good; badPacked[dataSumAt + 8 + 20] ^= 0x40
            check(isDamaged(decode(badPacked, in: folder).error), "compressed-data checksum mismatch")
            var oversized = lzopFile(blocks: [([1, 2, 3], [1, 2, 3])])
            let sizeAt = oversized.count - 4 - 3 - 8
            oversized.replaceSubrange(sizeAt..<sizeAt + 4, with: be32(0x7000_0000))
            check(isDamaged(decode(oversized, in: folder).error), "absurd block size")
            check(decode(good, in: folder, cancelAfter: 0).error == .cancelled, "cancelled between blocks")
        }
    }))

    SelfTest.cases.append(("ArchiveKit.lzo.fuzz", {
        withFolder { folder in
            let a = everyOpcodeStream()
            let good = lzopFile(blocks: [(a.expected, a.code)], flags: 0x3, name: "fuzz")
            var truncated = 0
            for length in stride(from: 0, to: good.count - 1, by: 997) + Array(0..<80) {
                if decode(Array(good[0..<length]), in: folder).error != nil { truncated += 1 }
            }
            check(truncated > 80, "truncated files are rejected")
            var rng = Lcg(state: 99)
            var rejected = 0
            for _ in 0..<300 {
                var mutated = good
                for _ in 0..<(1 + rng.next() % 4) { mutated[rng.next() % mutated.count] = UInt8(truncatingIfNeeded: rng.next()) }
                if decode(mutated, in: folder).error != nil { rejected += 1 }
            }
            check(rejected > 250, "mutated container files are rejected or decode, never crash")
            for _ in 0..<2000 {
                var code = a.code
                for _ in 0..<(1 + rng.next() % 6) { code[rng.next() % 600] = UInt8(truncatingIfNeeded: rng.next()) }
                _ = try? LZOKit.lzo1xDecompress(code, expectedSize: a.expected.count)
                _ = try? LZOKit.lzo1xDecompress(Array(code[0..<(rng.next() % code.count)]), expectedSize: a.expected.count)
            }
            for _ in 0..<2000 {
                _ = try? LZOKit.lzo1xDecompress(rng.bytes(3 + rng.next() % 64), expectedSize: rng.next() % 4096)
            }
            check(true, "random LZO1X input never crashes")
        }
    }))
}
