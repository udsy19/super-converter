import Foundation

// The `<Kit>.damagedInputNeverCrashes` cases: every in-process reader gets a few hundred damaged copies of its own valid
// fixtures and must fail cleanly (a thrown error or a best-effort result) — never trap, hang or allocate without bound,
// because engines run inside the app and a crash in one reader takes the whole app down.
//
// The mutations are seeded, so a failure reproduces: `SUPERCONVERTER_FUZZ_SEED=1234` reruns every fuzz case with another
// seed (the default is `Fuzz.defaultSeed`), and `SUPERCONVERTER_FUZZ_TRACE=1` prints each input's case, seed and index to
// stderr before it runs, so a crash names the input that caused it. The input being read is left in the case's folder
// under the self-test's scratch directory, which a crash does not remove.

/// SplitMix64: small, fast and the same on every machine, which is all a reproducible fuzzer needs.
struct FuzzRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fuzz {
    static let defaultSeed: UInt64 = 0x5EED_F022
    static let seed: UInt64 = ProcessInfo.processInfo.environment["SUPERCONVERTER_FUZZ_SEED"].flatMap { UInt64($0) } ?? defaultSeed
    static let trace = ProcessInfo.processInfo.environment["SUPERCONVERTER_FUZZ_TRACE"] != nil

    /// A generator for one fuzz case: the run's seed mixed with the case's name, so cases don't depend on each other's order.
    static func random(_ name: String) -> FuzzRandom {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325   // FNV-1a
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
        return FuzzRandom(seed: seed ^ hash)
    }

    /// Values that break naive readers when they land on a count, a length, an offset or a size.
    private static let hostileWords: [[UInt8]] = [
        [0xFF, 0xFF, 0xFF, 0xFF], [0x7F, 0xFF, 0xFF, 0xFF], [0xFF, 0xFF, 0xFF, 0x7F], [0x80, 0x00, 0x00, 0x00],
        [0x00, 0x00, 0x00, 0x80], [0x00, 0x00, 0x00, 0x00], [0xFF, 0xFF], [0x7F, 0xFF], [0xFF, 0x7F], [0x80, 0x00], [0x00, 0x00],
        [0x00, 0x10, 0x00, 0x00], [0x00, 0x00, 0x10, 0x00],
    ]
    private static let hostileNumbers = ["4294967295", "2147483648", "-1", "-2147483649", "99999999999999999999", "0",
                                         "1e308", "-1e308", "NaN", "65536", "1000000000"]

    /// One damaged copy of `bytes`: a truncation, random bytes, bit flips, a hostile word on a header field, a repeated or
    /// deleted slice, and for text a hostile number or `nesting` (the format's opening tokens) repeated thousands of times.
    static func mutate(_ bytes: [UInt8], nesting: [String] = [], using rng: inout FuzzRandom) -> [UInt8] {
        guard !bytes.isEmpty else { return [UInt8].random(count: 64, using: &rng) }
        var copy = bytes
        /// Half the time a position in the first 512 bytes, where headers, counts and offsets live.
        func position() -> Int {
            Bool.random(using: &rng) ? Int.random(in: 0..<min(copy.count, 512), using: &rng) : Int.random(in: 0..<copy.count, using: &rng)
        }
        switch Int.random(in: 0..<9, using: &rng) {
        case 0:
            copy = Array(copy.prefix(Int.random(in: 0..<copy.count, using: &rng)))
        case 1:
            for _ in 0..<Int.random(in: 1...16, using: &rng) { copy[position()] = UInt8.random(in: 0...255, using: &rng) }
        case 2:
            for _ in 0..<Int.random(in: 1...8, using: &rng) { copy[position()] ^= 1 << UInt8.random(in: 0..<8, using: &rng) }
        case 3, 4:
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                let word = hostileWords.randomElement(using: &rng)!, at = position()
                for (i, b) in word.enumerated() where at + i < copy.count { copy[at + i] = b }
            }
        case 5:
            let start = Int.random(in: 0..<copy.count, using: &rng)
            let slice = copy[start..<min(copy.count, start + Int.random(in: 1...64, using: &rng))]
            let at = Int.random(in: 0...copy.count, using: &rng)
            copy.insert(contentsOf: Array(repeating: Array(slice), count: Int.random(in: 1...64, using: &rng)).joined(), at: at)
        case 6:
            let start = Int.random(in: 0..<copy.count, using: &rng)
            copy.removeSubrange(start..<min(copy.count, start + Int.random(in: 1...256, using: &rng)))
        case 7:
            // A number in text (a length, a count, a coordinate) becomes a hostile one.
            let digits = copy.indices.filter { (0x30...0x39).contains(copy[$0]) }
            guard let at = digits.randomElement(using: &rng) else { return mutate(bytes, nesting: nesting, using: &rng) }
            var end = at
            while end < copy.count, (0x30...0x39).contains(copy[end]) || copy[end] == 0x2E { end += 1 }
            var start = at
            while start > 0, (0x30...0x39).contains(copy[start - 1]) || copy[start - 1] == 0x2D { start -= 1 }
            copy.replaceSubrange(start..<end, with: Array(hostileNumbers.randomElement(using: &rng)!.utf8))
        default:
            guard let token = nesting.randomElement(using: &rng) else { return mutate(bytes, nesting: nesting, using: &rng) }
            let at = Int.random(in: 0...copy.count, using: &rng)
            copy.insert(contentsOf: Array(String(repeating: token, count: Int.random(in: 2_000...20_000, using: &rng)).utf8), at: at)
        }
        return copy
    }

    /// A damaged package: one member of `entries` (a ZIP's, say) is damaged with `mutate`, or dropped, so the reader gets
    /// past the container and meets the damage in the documents it parses. The caller writes the entries back out.
    static func mutateEntries(_ entries: [(path: String, bytes: [UInt8])], nesting: [String] = [],
                              using rng: inout FuzzRandom) -> [(path: String, bytes: [UInt8])] {
        guard !entries.isEmpty else { return entries }
        var copy = entries
        let i = Int.random(in: 0..<copy.count, using: &rng)
        if Int.random(in: 0..<10, using: &rng) == 0 { copy.remove(at: i) }
        else { copy[i].bytes = mutate(copy[i].bytes, nesting: nesting, using: &rng) }
        return copy
    }
}

private extension Array where Element == UInt8 {
    static func random(count: Int, using rng: inout FuzzRandom) -> [UInt8] { (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) } }
}

/// One fuzz input: a fixture's damaged bytes, named for traces and written with the fixture's extension.
struct FuzzSeed {
    var name: String
    var ext: String
    var bytes: [UInt8]
    /// Replaces the generic byte mutations, for formats (packages) whose damage has to go inside.
    var mutate: ((inout FuzzRandom) -> [UInt8])? = nil
    var nesting: [String] = []
}

/// Runs `count` damaged copies of every seed through `read`, each under a 30 s limit, and fails on a hang. A trap or a
/// runaway allocation ends the process, which is the failure this exists to find. Returns how many inputs ran.
@MainActor
@discardableResult
func fuzzNeverCrashes(_ caseName: String, seeds: [FuzzSeed], count: Int = 200,
                      read: @escaping @MainActor (URL, FuzzSeed) async throws -> Void) -> Int {
    let dir = scratch.appendingPathComponent("fuzz/\(caseName)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var rng = Fuzz.random(caseName)
    var ran = 0
    for seed in seeds {
        for i in 0..<count {
            let bytes = seed.mutate?(&rng) ?? Fuzz.mutate(seed.bytes, nesting: seed.nesting, using: &rng)
            let url = dir.appendingPathComponent("input.\(seed.ext)")
            try? FileManager.default.removeItem(at: url)
            guard (try? Data(bytes).write(to: url)) != nil else { check(false, "\(caseName): can't write the input"); return ran }
            if Fuzz.trace { FileHandle.standardError.write(Data("fuzz \(caseName) \(seed.name) seed=\(Fuzz.seed) #\(i)\n".utf8)) }
            if complete(30, { try await read(url, seed) }) == nil {
                check(false, "\(caseName): \(seed.name) #\(i) (seed \(Fuzz.seed)) did not finish in 30 s")
            }
            ran += 1
        }
    }
    return ran
}
