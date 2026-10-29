import Foundation
import SuperConverterCore

/// ArchiveKit (quality §8: archive conversions must not lose a byte or a name). The corpus is
/// `Tests/Corpus/generated/archives/`, written by `python3 -I scripts/make-archive-fixtures.py --corpus …`: one fixture per
/// archive format, each with `expected/<fixture>.json`, the manifest an extraction must reproduce. Every built-in route from
/// a fixture's format runs once (to ZIP in the fast tier, the other targets in the full tier); the output is unpacked by an
/// independent reader (the system's bsdtar, or the bundled 7zz for passwords) and compared entry by entry.
enum ArchiveKitCases {
    /// Fixture → the format it is (the sniffer must agree, or the case fails).
    static let fixtures: [(String, FormatID)] = [
        ("tree.7z", "7z"), ("tree.ace", "ace"), ("tree.alz", "alz"), ("tree.arc", "arc"), ("stored.arj", "arj"), ("hello.txt.bz", "bz"),
        ("hello.txt.bz2", "bz2"), ("tree.cab", "cab"), ("tree.cpio", "cpio"), ("tool.deb", "deb"), ("tree.dmg", "dmg"), ("message.eml", "eml"),
        ("hello.txt.gz", "gz"), ("floppy.img", "img"), ("tree.iso", "iso"), ("tree.jar", "jar"), ("tree.lha", "lha"), ("hello.txt.lz", "lz"),
        ("hello.txt.lzma", "lzma"), ("hello.txt.lzo", "lzo"), ("stored.rar", "rar"), ("tool.rpm", "rpm"), ("hello.txt.rz", "rz"),
        ("tree.tar", "tar"), ("tree.tar.7z", "tar.7z"), ("tree.tar.bz", "tar.bz"), ("tree.tar.bz2", "tar.bz2"), ("tree.tar.gz", "tar.gz"),
        ("tree.tar.lzo", "tar.lzo"), ("tree.tar.xz", "tar.xz"), ("tree.tar.z", "tar.z"), ("tree.tbz", "tbz"), ("tree.tbz2", "tbz2"),
        ("tree.tgz", "tgz"), ("tree.tz", "tz"), ("tree.tzo", "tzo"), ("hello.txt.xz", "xz"), ("hello.txt.z", "z"), ("tree.zip", "zip"),
    ]

    static let archiveTargets: Set<FormatID> = ["zip", "7z", "tar", "tar.gz", "tar.bz2"]
    static let password = "sesame"

    static var all: [BenchCase] {
        var cases: [BenchCase] = []
        // Every reader, every built-in archive target (quality §8 "Every reader" and "Content manifest").
        for (fixture, format) in fixtures {
            let targets = FormatMatrix.routes(from: format).filter { $0.builtin != nil && archiveTargets.contains($0.to) }.map(\.to)
            let fast = targets.contains("zip") ? FormatID("zip") : targets.first
            for target in targets {
                // A JAR's ZIP still sniffs as a JAR (its manifest is content); a TAR in 7Z sniffs as the 7Z it also is, so
                // its own route runs straight through the converters.
                var checks: [Check] = format == "jar" ? [] : [.producesFormat(target)]
                var route: [Step]?
                if format == "tar.7z" { route = [Step(.libarchive, "tar.7z", .archiveTree), Step(.libarchive, .archiveTree, StepEndpoint.format(target))] }
                else { checks.insert(.sourceFormat(format), at: 0) }
                cases.append(BenchCase(id: "archivekit.\(fixture)-\(target.rawValue)", category: .archive, tier: target == fast ? .fast : .full,
                                       fixture: "generated/archives/\(fixture)", target: target, route: route,
                                       checks: checks + [.archiveMatches(fixture)]))
            }
        }
        // Encrypted sources open with the password (quality §8 "Encryption"); the new archive notes that it has none.
        for fixture in ["aes.zip", "zipcrypto.zip", "secret.7z"] {
            cases.append(BenchCase(id: "archivekit.\(fixture)-password", category: .archive, fixture: "generated/archives/\(fixture)", target: "tar",
                                   options: OptionValues(["password": .string(password)]),
                                   checks: [.archiveMatches(fixture), .lossNote(.encryptionRemoved), .asksForPassword()]))
        }
        // New archives with a password: AES-256 ZIP and 7Z (names encrypted) open in 7zz with it and not without; the
        // compatible ZIP (ZipCrypto) opens in the system's unzip, as Archive Utility's.
        cases.append(BenchCase(id: "archivekit.new-password-zip", category: .archive, fixture: "generated/archives/tree.tar", target: "zip",
                               options: OptionValues(["newPassword": .string(password)]),
                               checks: [.archiveMatches("tree.tar", reader: .sevenZip(password: password)), .sevenZipNeedsPassword()]))
        // libarchive (bsdtar) opens AES-256 ZIPs too, but not encrypted links: a tree without links.
        cases.append(BenchCase(id: "archivekit.new-password-zip-bsdtar", category: .archive, fixture: "generated/archives/tree.lha", target: "zip",
                               options: OptionValues(["newPassword": .string(password)]),
                               checks: [.archiveMatches("tree.lha", reader: .bsdtar(password: password))]))
        cases.append(BenchCase(id: "archivekit.new-password-7z", category: .archive, fixture: "generated/archives/tree.tar", target: "7z",
                               options: OptionValues(["newPassword": .string(password)]),
                               checks: [.archiveMatches("tree.tar", reader: .sevenZip(password: password)), .sevenZipNeedsPassword()]))
        cases.append(BenchCase(id: "archivekit.new-password-zipcrypto", category: .archive, fixture: "generated/archives/tree.tar", target: "zip",
                               options: OptionValues(["newPassword": .string(password), "compatibleZip": .bool(true)]),
                               checks: [.archiveMatches("tree.tar", reader: .unzip(password: password))]))
        // Legacy names (quality §8 "Names"): CP437 and Shift-JIS detected and written as UTF-8.
        for fixture in ["cp437.zip", "shift-jis.zip"] {
            cases.append(BenchCase(id: "archivekit.\(fixture)-names", category: .archive, fixture: "generated/archives/\(fixture)", target: "tar",
                                   checks: [.archiveMatches(fixture)]))
        }
        // UDF images go to 7zz (formats §6.8 ISO: "7zz for UDF").
        cases.append(BenchCase(id: "archivekit.udf.iso-zip", category: .archive, fixture: "generated/archives/udf.iso", target: "zip",
                               checks: [.archiveMatches("udf.iso")]))
        // Hostile archives (quality §8 "Safety"): only the safe entries come out, and the card says what was left out.
        cases.append(BenchCase(id: "archivekit.zip-slip", category: .archive, fixture: "generated/archives/zip-slip.zip", target: "tar",
                               checks: [.archiveMatches("zip-slip.zip"), .lossNote(.otherLoss)]))
        cases.append(BenchCase(id: "archivekit.link-escape", category: .archive, fixture: "generated/archives/link-escape.tar", target: "zip",
                               checks: [.archiveMatches("link-escape.tar"), .lossNote(.otherLoss)]))
        // A decompression bomb asks first: 7 KB of TAR.BZ2 that unpacks to 10.2 GB of zeros. With the person's yes it
        // converts whole; without it the same conversion stops on the question. Full tier: it writes 10 GB twice.
        cases.append(BenchCase(id: "archivekit.bomb-extract-anyway", category: .archive, tier: .full, fixture: "generated/archives/bomb.tar.bz2",
                               target: "zip", options: OptionValues(["extractAnyway": .bool(true)]),
                               checks: [.holds("zeros.bin", bytes: 10_200_000_000), .asksBeforeABomb()], timeout: 1800))

        // Archives this Mac cannot make, from other projects' test suites (`scripts/fetch-corpus.sh`; skipped when absent).
        // Encrypted names (RAR5 and RAR4, libarchive's tests): 7zz opens them with the password; without one the card asks.
        for fixture in ["test_read_format_rar5_encrypted_filenames.rar", "test_read_format_rar4_encrypted_filenames.rar"] {
            cases.append(BenchCase(id: "archivekit.\(fixture.split(separator: "_")[3])-encrypted-password", category: .archive, tier: .full,
                                   fixture: "external/archives/\(fixture)", target: "tar", options: OptionValues(["password": "password"]),
                                   checks: [.sourceFormat("rar"), .archiveMatches(fixture), .lossNote(.encryptionRemoved), .asksForPassword()]))
        }
        // A CAB with MSZIP, LZX and Quantum folders (libmspack's tests): libarchive has no Quantum decoder, so the planner's
        // route falls back to 7zz, and every file comes out.
        cases.append(BenchCase(id: "archivekit.quantum-cab", category: .archive, tier: .full, fixture: "external/archives/mszip_lzx_qtm.cab",
                               target: "zip", checks: [.sourceFormat("cab"), .archiveMatches("mszip_lzx_qtm.cab")]))
        return cases
    }
}

/// How the bench unpacks an output: by a reader that is not ArchiveKit's.
enum IndependentReader {
    case bsdtar(password: String?)
    case sevenZip(password: String?)
    case unzip(password: String)

    static let sevenZipTool = RepoRoot.url.appendingPathComponent("Vendor/Tools/7zz")

    func extract(_ archive: URL, into folder: URL) -> Bool {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        switch self {
        case .bsdtar(let password):
            return Subprocess.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xpf", archive.path, "-C", folder.path] + (password.map { ["--passphrase", $0] } ?? [])).status == 0
        case .sevenZip(let password):
            return Subprocess.run(Self.sevenZipTool, ["x", "-y", "-snl", "-p\(password ?? "")", "-o\(folder.path)", archive.path]).status == 0
        case .unzip(let password):
            return Subprocess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", "-P", password, archive.path, "-d", folder.path]).status == 0
        }
    }
}

extension Check {
    /// The sniffer reads the fixture as the format the case is about (otherwise another route would run).
    static func sourceFormat(_ format: FormatID) -> Check {
        Check(name: "sniffed as \(format.pill)") { ctx in
            guard ctx.sourceFormat == format else { throw CheckFailure("sniffed as \(ctx.sourceFormat.pill)") }
            return []
        }
    }

    /// Unpacks the output with an independent reader and compares it with `expected/<fixture>.json`: the same paths,
    /// kinds, sizes, SHA-256 and link targets, and where the fixture's format keeps them, permissions and modification
    /// times (2 s tolerance; quality §8 "Content manifest").
    static func archiveMatches(_ fixture: String, reader: IndependentReader = .bsdtar(password: nil)) -> Check {
        Check(name: "manifest matches \(fixture)") { ctx in
            guard let output = ctx.output else { throw CheckFailure("no output") }
            let expected = try ExpectedManifest.load(fixture)
            let folder = ctx.work.appendingPathComponent("unpacked-\(UUID().uuidString.prefix(6))", isDirectory: true)
            guard reader.extract(output, into: folder) else { throw CheckFailure("\(reader) could not unpack \(output.lastPathComponent)") }
            let actual = Dictionary(Manifest.entries(of: folder).map { ($0.path.precomposedStringWithCanonicalMapping, $0) }, uniquingKeysWith: { a, _ in a })
            var problems: [String] = []
            for want in expected.entries {
                guard let got = actual[want.path] else { problems.append("missing \(want.path)"); continue }
                if got.kind.rawValue != want.kind { problems.append("\(want.path) is a \(got.kind.rawValue)"); continue }
                if let size = want.size, got.size != size { problems.append("\(want.path) size \(got.size)") }
                if let sha = want.sha256, got.sha256 != sha { problems.append("\(want.path) content") }
                if let link = want.link, got.symlinkTarget != link { problems.append("\(want.path) → \(got.symlinkTarget ?? "nothing")") }
                if expected.modes, let mode = want.permissions, got.permissions != Int(String(mode, radix: 8)) {
                    problems.append("\(want.path) mode \(got.permissions)")
                }
                if expected.times, want.kind == "file", let time = want.modified, abs(got.modified - time) > 2 {
                    problems.append("\(want.path) modified \(Int(got.modified))")
                }
            }
            let extra = Set(actual.keys).subtracting(expected.entries.map(\.path))
            problems += extra.sorted().map { "extra \($0)" }
            if !problems.isEmpty { throw CheckFailure("manifest differs: \(problems.prefix(6))") }
            return [.count("entries", actual.count, atLeast: expected.entries.count), .exact("manifest differences", 0, equals: 0)]
        }
    }

    /// The conversion reported this kind of loss (the card's notes).
    static func lossNote(_ kind: LossNote.Kind) -> Check {
        Check(name: "notes \(kind.rawValue)") { ctx in
            guard ctx.result.lossNotes.contains(where: { $0.kind == kind }) else { throw CheckFailure("no \(kind.rawValue) note: \(ctx.result.lossNotes)") }
            return []
        }
    }

    /// 7zz cannot unpack the output with a wrong password.
    static func sevenZipNeedsPassword() -> Check {
        Check(name: "7zz needs the password") { ctx in
            guard let output = ctx.output else { throw CheckFailure("no output") }
            let folder = ctx.work.appendingPathComponent("no-password", isDirectory: true)
            if IndependentReader.sevenZip(password: "wrong").extract(output, into: folder) { throw CheckFailure("7zz unpacked it with a wrong password") }
            return []
        }
    }

    /// The output lists `path` at `bytes` (for a file too big to compare by manifest), read by the system's bsdtar.
    static func holds(_ path: String, bytes: Int64) -> Check {
        Check(name: "holds \(path)") { ctx in
            guard let output = ctx.output else { throw CheckFailure("no output") }
            let listing = Subprocess.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tvf", output.path])
            let lines = (listing.standardOutput ?? "").split(separator: "\n").map { $0.split(separator: " ", omittingEmptySubsequences: true) }
            guard listing.status == 0, lines.count == 1, let line = lines.first, line.last.map(String.init) == path else {
                throw CheckFailure("bsdtar lists \(listing.standardOutput ?? "nothing")")
            }
            guard line.contains(Substring(String(bytes))) else { throw CheckFailure("\(path) is not \(bytes) bytes: \(line.joined(separator: " "))") }
            return [.exact("bytes", Double(bytes), equals: Double(bytes))]
        }
    }

    /// Without the person's yes the same conversion stops on the bomb question (quality §8 "Safety", ux §7.2 "Extract Anyway").
    static func asksBeforeABomb() -> Check {
        Check(name: "asks first without extractAnyway") { ctx in
            let run = await Pipeline.convert(ctx.source, to: ctx.bench.target, into: ctx.work.appendingPathComponent("no-yes"), timeout: ctx.bench.timeout)
            guard case .failed(let why) = run.outcome, why.contains("needsConfirmation"), why.contains("extract it anyway?") else {
                throw CheckFailure("without extractAnyway: \(run.outcome)")
            }
            return []
        }
    }

    /// Without the password the same conversion stops and asks for it (ux §7.2 "Enter Password…").
    static func asksForPassword() -> Check {
        Check(name: "asks for the password without one") { ctx in
            let run = await Pipeline.convert(ctx.source, to: ctx.bench.target, into: ctx.work.appendingPathComponent("no-password"))
            guard case .failed(let why) = run.outcome, why.contains("passwordRequired") else { throw CheckFailure("without a password: \(run.outcome)") }
            return []
        }
    }
}

/// `Tests/Corpus/generated/archives/expected/<fixture>.json`.
struct ExpectedManifest: Decodable {
    struct Entry: Decodable {
        var path: String
        var kind: String
        var size: Int64?
        var sha256: String?
        var link: String?
        var permissions: Int?
        var modified: Double?
    }

    var modes: Bool
    var times: Bool
    var entries: [Entry]

    static func load(_ fixture: String) throws -> ExpectedManifest {
        let url = RepoRoot.corpus.appendingPathComponent("generated/archives/expected/\(fixture).json")
        guard let data = try? Data(contentsOf: url) else { throw CheckFailure("no expected manifest for \(fixture)") }
        var manifest = try JSONDecoder().decode(ExpectedManifest.self, from: data)
        for i in manifest.entries.indices { manifest.entries[i].path = manifest.entries[i].path.precomposedStringWithCanonicalMapping }
        return manifest
    }
}
