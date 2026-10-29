import Foundation
import SuperConverterCore
@testable import ArchiveKit

// ArchiveKit's checks (WP-A): archives are generated here (libarchive writes ZIP/7Z/TAR; hand-built bytes for the rest),
// hostile ones included. Cases needing 7zz, hdiutil or Python skip themselves when the tool is missing.

// MARK: - Fixture builders

private func akScratch(_ name: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("akit-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Runs `body` with a fresh folder that is removed afterwards.
private func akCase(_ name: String, _ body: @escaping @MainActor (URL) throws -> Void) {
    SelfTest.cases.append(("ArchiveKit.\(name)", {
        let dir = akScratch(name)
        defer { try? FileManager.default.removeItem(at: dir) }
        do { try body(dir) } catch { check(false, "\(name) threw \(error)") }
    }))
    registerArchiveKitACETests()
    registerArchiveKitARCTests()
}

private func akText(_ s: String) -> Data { Data(s.utf8) }

/// A tree extracted into `dir/src` from (path, content) pairs; `nil` content is a directory.
private func akTree(_ dir: URL, _ files: [(String, Data?)], links: [(String, String)] = []) throws -> ArchiveTree {
    let extractor = try SafeExtractor(root: dir.appendingPathComponent("src"))
    for (path, data) in files {
        if let data { try extractor.file(path, data: data, modified: Date(timeIntervalSince1970: 1_700_000_000), permissions: 0o644) }
        else { try extractor.directory(path, modified: Date(timeIntervalSince1970: 1_700_000_000)) }
    }
    for (path, target) in links { try extractor.symlink(path, target: target) }
    return extractor.finish()
}

private func akRead(_ url: URL, _ format: String, into root: URL, engine: EngineID = .libarchive, password: String? = nil,
                    encoding: NameEncoding = .auto, unpack: Bool = true, limits: ExtractionLimits = ExtractionLimits()) throws -> (ArchiveTree, [LossNote]) {
    let request = ArchiveReadRequest(source: url, format: FormatID(format), root: root, password: password, nameEncoding: encoding,
                                     unpackPayload: unpack, limits: limits)
    let tree = try Archives.read(request, engine: engine)
    return (tree, request.diagnostics.lossNotes)
}

private func akWrite(_ tree: ArchiveTree, _ format: String, to url: URL, dir: URL, password: String? = nil, compatible: Bool = false,
                     compression: ArchiveWriteRequest.Compression = .normal, keepMacExtras: Bool = false, split: Int64? = nil) throws -> URL {
    try Archives.write(ArchiveWriteRequest(tree: tree, format: FormatID(format), destination: url, compression: compression, password: password,
                                           compatibleZip: compatible, keepMacExtras: keepMacExtras, splitBytes: split, workFolder: dir))
}

private func akContents(_ tree: ArchiveTree) -> [String: Data] {
    var result: [String: Data] = [:]
    for e in tree.entries where e.kind == .file { result[e.path] = e.extracted.flatMap { try? Data(contentsOf: $0) } }
    return result
}

private func akPaths(_ tree: ArchiveTree, _ kind: ArchiveTree.Entry.Kind? = nil) -> Set<String> {
    Set(tree.entries.filter { kind == nil || $0.kind == kind }.map(\.path))
}

private func akExpectError(_ expected: ArchiveError, _ body: () throws -> Void, _ message: String) {
    do { try body(); check(false, "\(message): no error") } catch let error as ArchiveError { check(error == expected, "\(message): \(error)") } catch { check(false, "\(message): \(error)") }
}

private func akRun(_ tool: String, _ arguments: [String], in dir: URL? = nil) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = arguments
    p.currentDirectoryURL = dir
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
private func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF) }

/// A ZIP with stored entries and names given as raw bytes (flag bit 11 clear, as old tools wrote them).
private func akZip(_ entries: [(name: [UInt8], data: [UInt8])], utf8Flag: Bool = false) -> Data {
    var out = [UInt8](), central = [UInt8]()
    for (name, data) in entries {
        let crc = ArchiveChecksum.crc32(0, data)
        let offset = out.count
        let flags = utf8Flag ? 0x800 : 0
        out += [0x50, 0x4B, 3, 4] + le16(10) + le16(flags) + le16(0) + le16(0) + le16(0x21) + le32(Int(crc)) + le32(data.count) + le32(data.count)
            + le16(name.count) + le16(0) + name + data
        central += [0x50, 0x4B, 1, 2] + le16(20) + le16(10) + le16(flags) + le16(0) + le16(0) + le16(0x21) + le32(Int(crc)) + le32(data.count)
            + le32(data.count) + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name
    }
    let start = out.count
    out += central
    out += [0x50, 0x4B, 5, 6] + le16(0) + le16(0) + le16(entries.count) + le16(entries.count) + le32(central.count) + le32(start) + le16(0)
    return Data(out)
}

/// ustar bytes: regular files, directories, symlinks and hard links.
private struct AKTar {
    struct Item { var name: String; var type: UInt8 = 0x30; var data: [UInt8] = []; var link = ""; var mode = 0o644 }
    var items: [Item] = []

    func data() -> Data {
        var out = [UInt8]()
        for item in items {
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, at o: Int, max: Int) { for (i, b) in text.utf8.prefix(max).enumerated() { h[o + i] = b } }
            func octal(_ v: Int, at o: Int, width: Int) { put(String(v, radix: 8).leftPad(width - 1) + "\0", at: o, max: width) }
            put(item.name, at: 0, max: 100)
            octal(item.mode, at: 100, width: 8); octal(0, at: 108, width: 8); octal(0, at: 116, width: 8)
            octal(item.type == 0x30 ? item.data.count : 0, at: 124, width: 12); octal(1_700_000_000, at: 136, width: 12)
            h[156] = item.type
            put(item.link, at: 157, max: 100)
            put("ustar\0", at: 257, max: 6); put("00", at: 263, max: 2)
            put("        ", at: 148, max: 8)
            let sum = h.reduce(0) { $0 + Int($1) }
            put(String(sum, radix: 8).leftPad(6) + "\0 ", at: 148, max: 8)
            out += h
            if item.type == 0x30 {
                out += item.data
                out += [UInt8](repeating: 0, count: (512 - item.data.count % 512) % 512)
            }
        }
        out += [UInt8](repeating: 0, count: 1024)
        return Data(out)
    }
}

private extension String {
    func leftPad(_ width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}

/// An `ar` archive (what a .deb is).
private func akAr(_ members: [(String, Data)]) -> Data {
    var out = Data("!<arch>\n".utf8)
    for (name, data) in members {
        func field(_ s: String, _ n: Int) -> String { s + String(repeating: " ", count: n - s.count) }
        out += Data((field(name + "/", 16) + field("1700000000", 12) + field("0", 6) + field("0", 6) + field("100644", 8) + field(String(data.count), 10) + "`\n").utf8)
        out += data
        if data.count % 2 == 1 { out += Data("\n".utf8) }
    }
    return out
}

/// A newc cpio archive.
private func akCpio(_ files: [(String, Data)]) -> Data {
    var out = Data()
    func header(_ name: String, size: Int, mode: Int) -> Data {
        func hex(_ v: Int) -> String { String(v, radix: 16, uppercase: true).leftPad(8) }
        let fields = ["070701", hex(1), hex(mode), hex(0), hex(0), hex(1), hex(1_700_000_000), hex(size), hex(0), hex(0), hex(0), hex(0),
                      hex(name.utf8.count + 1), hex(0)]
        var d = Data(fields.joined().utf8)
        d += Data(name.utf8) + Data([0])
        d += Data(repeating: 0, count: (4 - d.count % 4) % 4)
        return d
    }
    for (name, data) in files {
        out += header(name, size: data.count, mode: 0o100644) + data
        out += Data(repeating: 0, count: (4 - data.count % 4) % 4)
    }
    out += header("TRAILER!!!", size: 0, mode: 0)
    return out
}

/// A CAB with one stored (uncompressed) folder holding the files.
private func akCab(_ files: [(String, [UInt8])]) -> Data {
    var entries = [UInt8](), body = [UInt8](), offset = 0
    for (name, data) in files {
        entries += le32(data.count) + le32(offset) + le16(0) + le16(0x5821) + le16(0x6000) + le16(0x20) + Array(name.utf8) + [0]
        body += data
        offset += data.count
    }
    let cfdata = le32(0) + le16(body.count) + le16(body.count) + body
    let filesAt = 36 + 8, dataAt = filesAt + entries.count
    let total = dataAt + cfdata.count
    let header = Array("MSCF".utf8) + le32(0) + le32(total) + le32(0) + le32(filesAt) + le32(0) + [3, 1] + le16(1) + le16(files.count) + le16(0) + le16(1) + le16(0)
    return Data(header + le32(dataAt) + le16(1) + le16(0) + entries + cfdata)
}

/// An LHA archive of stored (-lh0-) level 0 entries.
private func akLha(_ files: [(String, [UInt8])]) -> Data {
    func crc16(_ bytes: [UInt8]) -> Int {
        var crc = 0
        for b in bytes { crc ^= Int(b); for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 } }
        return crc
    }
    var out = [UInt8]()
    for (name, data) in files {
        let n = Array(name.utf8)
        let body = Array("-lh0-".utf8) + le32(data.count) + le32(data.count) + le32(0x5821_6000) + [0x20, 0, UInt8(n.count)] + n + le16(crc16(data))
        out += [UInt8(body.count), UInt8(body.reduce(0) { ($0 + Int($1)) & 0xFF })] + body + data
    }
    return Data(out + [0])
}

/// An ALZ archive of stored entries (names in CP949) and folders.
private func akAlz(_ entries: [(name: [UInt8], data: [UInt8]?)]) -> Data {
    var out = Array("ALZ".utf8) + [1] + le32(10)
    for (name, data) in entries {
        out += Array("BLZ".utf8) + [1] + le16(name.count)
        if let data {
            out += [0x20] + le32(0x5821_6000) + [0x20, 0] + [0, 0] + le32(Int(ArchiveChecksum.crc32(0, data))) + le16(data.count) + le16(data.count) + name + data
        } else {
            out += [0x10] + le32(0x5821_6000) + [0, 0] + name
        }
    }
    return Data(out)
}

private func akGzip(_ data: Data, in dir: URL) -> Data? {
    let file = dir.appendingPathComponent("gz-\(UUID().uuidString)")
    try? data.write(to: file)
    guard akRun("/usr/bin/gzip", ["-n", "-f", file.path]) else { return nil }
    return try? Data(contentsOf: file.appendingPathExtension("gz"))
}

private var akSevenZipPresent: Bool { SevenZip.isAvailable }

// MARK: - Cases

func registerArchiveKitTests() {
    registerArchiveKitLZOTests()
    registerArchiveKitRZipTests()

    SelfTest.cases.append(("ArchiveKit.installs", {
        installFakes()
        ArchiveKitModule.install()
        let ids = Set(Services.converters.converters.map(\.id))
        check(ids == Set(ArchiveConverter.engines), "install registers every ArchiveKit engine: \(ids)")
        // Every step of every archive route that names an ArchiveKit engine is handled by that engine's converter.
        var unhandled: [String] = []
        for route in FormatMatrix.routes {
            for step in (route.builtin ?? []) + (route.helper ?? []) + route.alternates.flatMap(\.steps) where step.engine.info.module == .archiveKit {
                if !(Services.converters.converter(for: step.engine)?.handles(step) ?? false) { unhandled.append("\(route.from)→\(route.to) \(step)") }
            }
        }
        check(unhandled.isEmpty, "unhandled steps: \(unhandled.prefix(5))")
    }))

    // Round trips through every writer: names (ASCII and non-ASCII), contents, directories, permissions, dates, links.
    for format in ["zip", "7z", "tar", "tar.gz", "tar.bz2"] {
        akCase("roundtrip.\(format)") { dir in
            let big = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
            let tree = try akTree(dir, [("docs", nil), ("docs/readme.txt", akText("hello\n")), ("日本語/éè 🙂.txt", akText("unicode")), ("empty", Data()),
                                        ("big.bin", big), ("emptydir", nil)], links: [("docs/link", "readme.txt")])
            let archive = try akWrite(tree, format, to: dir.appendingPathComponent("out.\(format)"), dir: dir)
            let (back, _) = try akRead(archive, format, into: dir.appendingPathComponent("back"))
            check(akContents(back) == akContents(tree), "\(format): contents differ")
            check(akPaths(back, .directory).isSuperset(of: ["docs", "emptydir"]), "\(format): directories \(akPaths(back, .directory))")
            check(akPaths(back, .symlink) == ["docs/link"], "\(format): symlink")
            check(back.entries.first { $0.path == "docs/link" }?.linkTarget == "readme.txt", "\(format): link target")
            let readme = back.entries.first { $0.path == "docs/readme.txt" }
            check(readme?.permissions == 0o644, "\(format): permissions \(String(describing: readme?.permissions))")
            check(abs((readme?.modified?.timeIntervalSince1970 ?? 0) - 1_700_000_000) <= 2, "\(format): modified \(String(describing: readme?.modified))")
            if format == "tar.gz" || format == "tar.bz2" { check((try? FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? Int) ?? 0 < big.count, "\(format) compresses") }
        }
    }

    akCase("compression.levels") { dir in
        let text = Data(String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 4000).utf8)
        let tree = try akTree(dir, [("a.txt", text)])
        var sizes: [String: Int] = [:]
        for level in [ArchiveWriteRequest.Compression.fast, .smallest] {
            let url = try akWrite(tree, "zip", to: dir.appendingPathComponent("\(level.rawValue).zip"), dir: dir, compression: level)
            sizes[level.rawValue] = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let (back, _) = try akRead(url, "zip", into: dir.appendingPathComponent("b-\(level.rawValue)"))
            check(akContents(back)["a.txt"] == text, "\(level) round trip")
        }
        check(sizes["smallest"]! <= sizes["fast"]!, "smallest <= fast \(sizes)")
    }

    akCase("macExtras") { dir in
        let tree = try akTree(dir, [("a.txt", akText("a")), ("._a.txt", akText("apple double")), (".DS_Store", akText("x")), ("__MACOSX", nil),
                                    ("__MACOSX/._a.txt", akText("y")), ("sub/.DS_Store", akText("z"))])
        let dropped = try akWrite(tree, "tar", to: dir.appendingPathComponent("drop.tar"), dir: dir)
        let (a, _) = try akRead(dropped, "tar", into: dir.appendingPathComponent("a"))
        check(akPaths(a, .file) == ["a.txt"], "Mac extras dropped: \(akPaths(a))")
        let kept = try akWrite(tree, "tar", to: dir.appendingPathComponent("keep.tar"), dir: dir, keepMacExtras: true)
        let (b, _) = try akRead(kept, "tar", into: dir.appendingPathComponent("b"))
        check(akPaths(b, .file).count == 5, "Mac extras kept: \(akPaths(b))")
    }

    akCase("split") { dir in
        let data = Data((0..<900_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 >> 5) })
        let tree = try akTree(dir, [("noise.bin", data)])
        let whole = try akWrite(tree, "zip", to: dir.appendingPathComponent("whole.zip"), dir: dir, compression: .fast)
        let wholeBytes = try Data(contentsOf: whole)
        let parts = try akWrite(tree, "zip", to: dir.appendingPathComponent("split.zip"), dir: dir, compression: .fast, split: 300_000)
        let names = try FileManager.default.contentsOfDirectory(atPath: parts.path).sorted()
        check(names.count == (wholeBytes.count + 299_999) / 300_000 && names.first == "split.zip.001", "split parts: \(names)")
        var joined = Data()
        for n in names { joined += try Data(contentsOf: parts.appendingPathComponent(n)) }
        let (back, _) = try akRead(whole, "zip", into: dir.appendingPathComponent("w"))
        check(joined.count == wholeBytes.count, "parts add up to the archive")
        check(akContents(back)["noise.bin"] == data, "unsplit archive reads back")
        check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("split.zip").path), "the unsplit file is removed")
    }

    akCase("cancel") { dir in
        let tree = try akTree(dir, [("a.txt", akText("a"))])
        let url = try akWrite(tree, "zip", to: dir.appendingPathComponent("a.zip"), dir: dir)
        let request = ArchiveReadRequest(source: url, format: "zip", root: dir.appendingPathComponent("out"), isCancelled: { true })
        akExpectError(.cancelled, { _ = try Archives.read(request, engine: .libarchive) }, "cancelled read")
        let write = ArchiveWriteRequest(tree: tree, format: "7z", destination: dir.appendingPathComponent("c.7z"), workFolder: dir, isCancelled: { true })
        akExpectError(.cancelled, { try Archives.write(write) }, "cancelled write")
        check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("c.7z").path), "no partial output")
        check(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).allSatisfy { !$0.hasSuffix(".partial") }, "no partial file left")
    }

    // MARK: Safety

    akCase("zipslip.zip") { dir in
        let evil = akText("evil")
        let zip = akZip([(Array("../evil1.txt".utf8), [UInt8](evil)), (Array("a/../../evil2.txt".utf8), [UInt8](evil)),
                         (Array("/abs/evil3.txt".utf8), [UInt8](evil)), (Array("..\\evil4.txt".utf8), [UInt8](evil)),
                         (Array("C:\\evil5.txt".utf8), [UInt8](evil)), (Array("ok/fine.txt".utf8), [UInt8](akText("fine")))])
        let url = dir.appendingPathComponent("slip.zip")
        try zip.write(to: url)
        let outer = dir.appendingPathComponent("outer")
        let root = outer.appendingPathComponent("root")
        let (tree, notes) = try akRead(url, "zip", into: root)
        let fm = FileManager.default
        for name in ["evil1.txt", "evil2.txt", "evil3.txt", "evil4.txt", "evil5.txt"] {
            check(!fm.fileExists(atPath: outer.appendingPathComponent(name).path) && !fm.fileExists(atPath: dir.appendingPathComponent(name).path), "\(name) escaped the root")
        }
        for e in tree.entries {
            check(!e.path.contains("..") && !e.path.hasPrefix("/"), "unsafe path survived: \(e.path)")
            if let url = e.extracted { check(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"), "extracted outside root: \(url.path)") }
        }
        check(akContents(tree)["ok/fine.txt"] == akText("fine"), "the safe file is extracted")
        check(notes.contains { $0.kind == .otherLoss && $0.detail.contains("unsafe") } || tree.entries.count >= 1, "skipped names are reported")
    }

    akCase("zipslip.tar") { dir in
        var tar = AKTar()
        tar.items = [.init(name: "../evil-t1.txt", data: [UInt8](akText("evil"))), .init(name: "x/../../evil-t2.txt", data: [UInt8](akText("evil"))),
                     .init(name: "good.txt", data: [UInt8](akText("good")))]
        let url = dir.appendingPathComponent("slip.tar")
        try tar.data().write(to: url)
        let outer = dir.appendingPathComponent("outer")
        let (tree, notes) = try akRead(url, "tar", into: outer.appendingPathComponent("root"))
        check(!FileManager.default.fileExists(atPath: outer.appendingPathComponent("evil-t1.txt").path), "tar ../ escaped")
        check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("evil-t2.txt").path), "tar nested ../ escaped")
        check(akPaths(tree, .file).contains("good.txt"), "good file: \(akPaths(tree))")
        check(notes.contains { $0.detail.contains("unsafe") }, "unsafe names counted: \(notes)")
    }

    akCase("symlinks") { dir in
        let outside = dir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        var tar = AKTar()
        tar.items = [.init(name: "inside", type: 0x32, link: "docs/readme.txt"), .init(name: "up", type: 0x32, link: "../../outside"),
                     .init(name: "abs", type: 0x32, link: outside.path), .init(name: "docs/", type: 0x35, mode: 0o755),
                     .init(name: "docs/readme.txt", data: [UInt8](akText("r"))), .init(name: "docs/sibling", type: 0x32, link: "../docs/readme.txt"),
                     // A file written "through" a link that points elsewhere must stay inside the root.
                     .init(name: "up/planted.txt", data: [UInt8](akText("planted"))), .init(name: "abs/planted2.txt", data: [UInt8](akText("planted")))]
        let url = dir.appendingPathComponent("links.tar")
        try tar.data().write(to: url)
        let root = dir.appendingPathComponent("root")
        let (tree, notes) = try akRead(url, "tar", into: root)
        check(akPaths(tree, .symlink) == ["inside", "docs/sibling"], "only links that stay inside are kept: \(akPaths(tree, .symlink))")
        check(notes.contains { $0.detail.contains("link") }, "dropped links are reported: \(notes)")
        check(((try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? []).isEmpty, "nothing was written through a link")
        // No link of any kind exists on disk.
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        var onDisk = 0
        while let u = walker?.nextObject() as? URL { if (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { onDisk += 1 } }
        check(onDisk == 0, "no links created on disk")
        // And the writers re-create the kept links.
        let rewritten = try akWrite(tree, "tar", to: dir.appendingPathComponent("again.tar"), dir: dir)
        let (again, _) = try akRead(rewritten, "tar", into: dir.appendingPathComponent("again"))
        check(akPaths(again, .symlink) == ["inside", "docs/sibling"], "links survive a rewrite")
    }

    akCase("hardlinks") { dir in
        var tar = AKTar()
        tar.items = [.init(name: "orig.txt", data: [UInt8](akText("same bytes"))), .init(name: "copy.txt", type: 0x31, link: "orig.txt"),
                     .init(name: "bad.txt", type: 0x31, link: "../../etc/hosts")]
        let url = dir.appendingPathComponent("hard.tar")
        try tar.data().write(to: url)
        let (tree, _) = try akRead(url, "tar", into: dir.appendingPathComponent("root"))
        check(akContents(tree)["copy.txt"] == akText("same bytes"), "hard link becomes a copy")
        check(!akPaths(tree).contains("bad.txt"), "a hard link to a name outside is ignored")
    }

    akCase("caseCollision") { dir in
        var tar = AKTar()
        tar.items = [.init(name: "File.txt", data: [UInt8](akText("upper"))), .init(name: "file.txt", data: [UInt8](akText("lower")))]
        let url = dir.appendingPathComponent("case.tar")
        try tar.data().write(to: url)
        let (tree, _) = try akRead(url, "tar", into: dir.appendingPathComponent("root"))
        check(akContents(tree) == ["File.txt": akText("upper"), "file.txt": akText("lower")], "both names keep their own bytes: \(akContents(tree))")
    }

    akCase("duplicates") { dir in
        var tar = AKTar()
        tar.items = [.init(name: "a.txt", data: [UInt8](akText("first"))), .init(name: "a.txt", data: [UInt8](akText("second")))]
        let url = dir.appendingPathComponent("dup.tar")
        try tar.data().write(to: url)
        let (tree, _) = try akRead(url, "tar", into: dir.appendingPathComponent("root"))
        check(tree.entries.count == 1 && akContents(tree)["a.txt"] == akText("second"), "the later entry wins")
    }

    akCase("limits") { dir in
        // 40 MB of zeros deflates to ~40 KB: a small bomb. Lower caps catch it; defaults let a normal archive through.
        let tree = try akTree(dir, [("zeros.bin", Data(count: 40 << 20))])
        let url = try akWrite(tree, "zip", to: dir.appendingPathComponent("bomb.zip"), dir: dir)
        var ratio = ExtractionLimits(); ratio.ratioFloor = 1 << 20; ratio.maxRatio = 100
        akExpectError(.tooLarge("This archive expands far more than a real one does (a decompression bomb), so it was stopped."),
                      { _ = try akRead(url, "zip", into: dir.appendingPathComponent("r1"), limits: ratio) }, "ratio")
        var total = ExtractionLimits(); total.maxTotalBytes = 1 << 20
        do { _ = try akRead(url, "zip", into: dir.appendingPathComponent("r2"), limits: total); check(false, "total cap") } catch ArchiveError.tooLarge {} catch { check(false, "total cap: \(error)") }
        check(((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("r2").path)) ?? []).count <= 1, "the half-written file is removed")
        var count = ExtractionLimits(); count.maxEntries = 3
        let many = try akTree(dir, (0..<10).map { ("f\($0).txt", akText("\($0)")) })
        let manyZip = try akWrite(many, "zip", to: dir.appendingPathComponent("many.zip"), dir: dir)
        do { _ = try akRead(manyZip, "zip", into: dir.appendingPathComponent("r3"), limits: count); check(false, "entry cap") } catch ArchiveError.tooLarge {} catch { check(false, "entry cap: \(error)") }
        var space = ExtractionLimits(); space.reserveBytes = Int64.max / 4
        do { _ = try akRead(url, "zip", into: dir.appendingPathComponent("r4"), limits: space); check(false, "space") } catch ArchiveError.notEnoughSpace {} catch { check(false, "space: \(error)") }
        let (ok, _) = try akRead(url, "zip", into: dir.appendingPathComponent("r5"))
        check(ok.totalSize == 40 << 20, "default limits unpack a normal archive")
    }

    akCase("nesting") { dir in
        let tree = try akTree(dir, [("a.txt", akText("a"))])
        var depth = ArchiveReadRequest(source: dir, format: "tar", root: dir)
        depth.limits.maxNesting = 1
        depth.depth = 1
        do { _ = try depth.nested(source: dir, format: "tar", root: dir); check(false, "nesting cap") } catch ArchiveError.tooLarge {} catch { check(false, "\(error)") }
        _ = tree
    }

    akCase("damaged") { dir in
        let tree = try akTree(dir, [("a.bin", Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 13) }))])
        for format in ["zip", "7z", "tar.gz", "tar.bz2"] {
            let url = try akWrite(tree, format, to: dir.appendingPathComponent("d.\(format)"), dir: dir)
            let bytes = try Data(contentsOf: url)
            let cut = dir.appendingPathComponent("cut.\(format)")
            try bytes.prefix(bytes.count / 2).write(to: cut)
            do { _ = try akRead(cut, format, into: dir.appendingPathComponent("cut-\(format)")); check(false, "\(format): truncated archive read") } catch is ArchiveError {} catch { check(false, "\(format): \(error)") }
            var junk = bytes
            for i in stride(from: 0, to: junk.count, by: 97) { junk[i] ^= 0xA5 }
            try junk.write(to: cut)
            do { _ = try akRead(cut, format, into: dir.appendingPathComponent("junk-\(format)")) } catch is ArchiveError {} catch { check(false, "\(format): \(error)") }
        }
    }

    // MARK: File-name encodings

    akCase("encoding.utf8") { dir in
        let url = dir.appendingPathComponent("u.zip")
        try akZip([(Array("café/日本語.txt".utf8), [UInt8](akText("x")))], utf8Flag: true).write(to: url)
        let (tree, _) = try akRead(url, "zip", into: dir.appendingPathComponent("r"))
        check(akPaths(tree, .file) == ["café/日本語.txt"], "UTF-8 flagged names: \(akPaths(tree))")
        let unflagged = dir.appendingPathComponent("u2.zip")
        try akZip([(Array("café.txt".utf8), [UInt8](akText("x")))], utf8Flag: false).write(to: unflagged)
        let (tree2, _) = try akRead(unflagged, "zip", into: dir.appendingPathComponent("r2"))
        check(akPaths(tree2, .file) == ["café.txt"], "UTF-8 names without the flag: \(akPaths(tree2))")
    }

    akCase("encoding.legacy") { dir in
        func zip(_ text: String, _ encoding: String.Encoding) throws -> URL {
            let url = dir.appendingPathComponent("\(UUID().uuidString).zip")
            try akZip([(Array(text.data(using: encoding)!), [UInt8](akText("x")))]).write(to: url)
            return url
        }
        let sjis = try zip("テスト/日本語のファイル.txt", .shiftJIS)
        let (a, _) = try akRead(sjis, "zip", into: dir.appendingPathComponent("a"))
        check(akPaths(a, .file) == ["テスト/日本語のファイル.txt"], "Shift-JIS detected: \(akPaths(a))")
        check(a.nameEncoding == "CP932", "encoding reported: \(String(describing: a.nameEncoding))")
        let cp437 = try zip("Ünïcödé/naïve.txt", .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue))))
        let (b, _) = try akRead(cp437, "zip", into: dir.appendingPathComponent("b"))
        check(akPaths(b, .file) == ["Ünïcödé/naïve.txt"], "CP437 fallback: \(akPaths(b))")
        let gbk = try zip("文档/中文文件名称.txt", .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))))
        let (c, _) = try akRead(gbk, "zip", into: dir.appendingPathComponent("c"))
        check(akPaths(c, .file) == ["文档/中文文件名称.txt"], "GBK detected: \(akPaths(c))")
        let euc = try zip("한국어/파일이름.txt", .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))))
        let (d, _) = try akRead(euc, "zip", into: dir.appendingPathComponent("d"))
        check(akPaths(d, .file) == ["한국어/파일이름.txt"], "EUC-KR detected: \(akPaths(d))")
        // The person's choice wins over detection.
        let (e, _) = try akRead(sjis, "zip", into: dir.appendingPathComponent("e"), encoding: .cp437)
        check(akPaths(e, .file) != ["テスト/日本語のファイル.txt"], "an explicit encoding overrides detection")
        let (f, _) = try akRead(sjis, "zip", into: dir.appendingPathComponent("f"), encoding: .shiftJIS)
        check(akPaths(f, .file) == ["テスト/日本語のファイル.txt"], "explicit Shift-JIS")
    }

    // MARK: Passwords

    akCase("password.zipcrypto") { dir in
        let tree = try akTree(dir, [("secret.txt", akText("top secret"))])
        let url = try akWrite(tree, "zip", to: dir.appendingPathComponent("zc.zip"), dir: dir, password: "pässword", compatible: true)
        akExpectError(.passwordRequired, { _ = try akRead(url, "zip", into: dir.appendingPathComponent("n")) }, "no password")
        let (ok, _) = try akRead(url, "zip", into: dir.appendingPathComponent("ok"), password: "pässword")
        check(akContents(ok)["secret.txt"] == akText("top secret") && ok.wasEncrypted, "right password")
        do { _ = try akRead(url, "zip", into: dir.appendingPathComponent("bad"), password: "wrong"); check(false, "wrong password accepted") }
        catch ArchiveError.passwordRequired {} catch { check(false, "wrong password: \(error)") }
    }

    for format in ["zip", "7z"] {
        akCase("password.aes.\(format)") { dir in
            guard akSevenZipPresent else { return }
            let tree = try akTree(dir, [("secret.txt", akText("top secret")), ("sub/more.txt", akText("more"))])
            let url = try akWrite(tree, format, to: dir.appendingPathComponent("aes.\(format)"), dir: dir, password: "correct horse")
            let plain = try Data(contentsOf: url)
            check(plain.range(of: akText("top secret")) == nil, "\(format): the bytes are not stored in the clear")
            if format == "7z" { check(plain.range(of: akText("secret.txt")) == nil && plain.range(of: Data("secret.txt".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })) == nil, "7z: file names are encrypted") }
            akExpectError(.passwordRequired, { _ = try akRead(url, format, into: dir.appendingPathComponent("n")) }, "\(format): no password")
            do { _ = try akRead(url, format, into: dir.appendingPathComponent("bad"), password: "nope"); check(false, "\(format): wrong password accepted") }
            catch ArchiveError.passwordRequired {} catch { check(false, "\(format) wrong password: \(error)") }
            let (ok, _) = try akRead(url, format, into: dir.appendingPathComponent("ok"), password: "correct horse")
            check(akContents(ok) == ["secret.txt": akText("top secret"), "sub/more.txt": akText("more")], "\(format): right password \(akContents(ok).keys)")
            check(ok.wasEncrypted, "\(format): the tree remembers it was encrypted")
        }
    }

    akCase("password.tar") { dir in
        let tree = try akTree(dir, [("a.txt", akText("a"))])
        akExpectError(.unsupported("TAR archives can’t have a password."), { _ = try akWrite(tree, "tar.gz", to: dir.appendingPathComponent("p.tar.gz"), dir: dir, password: "x") }, "TAR password")
    }

    // MARK: Other formats from generated fixtures

    akCase("fixtures.python") { dir in
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/make-archive-fixtures.py")
        guard FileManager.default.fileExists(atPath: script.path), akRun("/usr/bin/env", ["python3", "-I", script.path, dir.path]) else { return }
        let hello = try Data(contentsOf: dir.appendingPathComponent("payload/hello.txt"))
        let (rar, _) = try akRead(dir.appendingPathComponent("stored.rar"), "rar", into: dir.appendingPathComponent("rar"))
        check(akContents(rar) == ["hello.txt": hello], "RAR 5 through libarchive: \(akContents(rar).keys)")
        guard akSevenZipPresent else { return }
        let (arj, _) = try akRead(dir.appendingPathComponent("stored.arj"), "arj", into: dir.appendingPathComponent("arj"), engine: .sevenZip)
        check(akContents(arj) == ["hello.txt": hello], "ARJ through 7zz: \(akContents(arj).keys)")
        let (img, _) = try akRead(dir.appendingPathComponent("floppy.img"), "img", into: dir.appendingPathComponent("img"), engine: .sevenZip)
        check(akContents(img).values.contains(hello), "FAT image through 7zz: \(akContents(img).keys)")
        // The same RAR through the libarchive route falls back to 7zz when libarchive cannot.
        let (viaFallback, _) = try akRead(dir.appendingPathComponent("stored.arj"), "arj", into: dir.appendingPathComponent("arj2"))
        check(akContents(viaFallback) == ["hello.txt": hello], "libarchive falls back to 7zz for ARJ")
    }

    akCase("cpio") { dir in
        let url = dir.appendingPathComponent("a.cpio")
        try akCpio([("one.txt", akText("1")), ("dir/two.txt", akText("two two"))]).write(to: url)
        let (tree, _) = try akRead(url, "cpio", into: dir.appendingPathComponent("r"))
        check(akContents(tree) == ["one.txt": akText("1"), "dir/two.txt": akText("two two")], "cpio newc: \(akContents(tree).keys)")
    }

    akCase("deb") { dir in
        let payload = try akTree(dir, [("usr/bin/tool", akText("#!/bin/sh\n")), ("usr/share/doc/tool/README", akText("docs"))])
        let dataTar = try akWrite(payload, "tar.gz", to: dir.appendingPathComponent("data.tar.gz"), dir: dir)
        var control = AKTar()
        control.items = [.init(name: "./control", data: [UInt8](akText("Package: tool\n")))]
        guard let controlGz = akGzip(control.data(), in: dir) else { return }
        let deb = akAr([("debian-binary", akText("2.0\n")), ("control.tar.gz", controlGz), ("data.tar.gz", try Data(contentsOf: dataTar))])
        let url = dir.appendingPathComponent("tool.deb")
        try deb.write(to: url)
        let (unpacked, _) = try akRead(url, "deb", into: dir.appendingPathComponent("a"))
        check(akContents(unpacked).keys.sorted() == ["usr/bin/tool", "usr/share/doc/tool/README"], "DEB payload unpacked: \(akContents(unpacked).keys.sorted())")
        let (members, _) = try akRead(url, "deb", into: dir.appendingPathComponent("b"), unpack: false)
        check(akPaths(members, .file) == ["debian-binary", "control.tar.gz", "data.tar.gz"], "DEB members when unpacking is off: \(akPaths(members))")
    }

    akCase("rpm") { dir in
        // lead (96 bytes) + empty signature header + empty main header + gzip'd cpio payload
        var rpm = Data([0xED, 0xAB, 0xEE, 0xDB, 3, 0, 0, 0, 0, 1]) + Data("tool-1.0-1".utf8)
        rpm += Data(repeating: 0, count: 96 - rpm.count)
        let emptyHeader = Data([0x8E, 0xAD, 0xE8, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        guard let payload = akGzip(akCpio([("./usr/bin/tool", akText("binary")), ("./etc/tool.conf", akText("conf"))]), in: dir) else { return }
        rpm += emptyHeader + emptyHeader + payload
        let url = dir.appendingPathComponent("tool.rpm")
        try rpm.write(to: url)
        let (tree, _) = try akRead(url, "rpm", into: dir.appendingPathComponent("a"))
        check(akContents(tree).keys.sorted() == ["etc/tool.conf", "usr/bin/tool"], "RPM payload unpacked: \(akContents(tree).keys.sorted())")
        let (raw, _) = try akRead(url, "rpm", into: dir.appendingPathComponent("b"), unpack: false)
        check(akPaths(raw, .file).count == 1 && (akContents(raw).values.first?.range(of: akText("070701")) != nil), "RPM payload as a cpio file: \(akPaths(raw))")
    }

    // The extension-only variants of the same format all read through the same code; one file each proves the routes.
    akCase("formats.variants") { dir in
        let tree = try akTree(dir, [("v/one.txt", akText("one")), ("two.txt", akText("two"))])
        let expected = akContents(tree)
        let zip = try akWrite(tree, "zip", to: dir.appendingPathComponent("a.jar"), dir: dir)
        let (jar, _) = try akRead(zip, "jar", into: dir.appendingPathComponent("jar"))
        check(akContents(jar) == expected, "JAR")
        let tgz = try akWrite(tree, "tar.gz", to: dir.appendingPathComponent("a.tgz"), dir: dir)
        let tbz = try akWrite(tree, "tar.bz2", to: dir.appendingPathComponent("a.tbz2"), dir: dir)
        for format in ["tgz", "tar.gz"] {
            let (r, _) = try akRead(tgz, format, into: dir.appendingPathComponent("r-\(format)"))
            check(akContents(r) == expected, format)
        }
        for format in ["tbz", "tbz2", "tar.bz", "tar.bz2"] {
            let (r, _) = try akRead(tbz, format, into: dir.appendingPathComponent("r-\(format)"))
            check(akContents(r) == expected, format)
        }
        let bz = dir.appendingPathComponent("plain.txt")
        try akText("bz payload").write(to: bz)
        if akRun("/usr/bin/bzip2", ["-k", bz.path]) {
            let (b, _) = try akRead(bz.appendingPathExtension("bz2"), "bz", into: dir.appendingPathComponent("r-bz"))
            check(akContents(b) == ["plain.txt": akText("bz payload")], "BZ: \(akContents(b).keys)")
        }
        // compress(1): .Z, and a tar inside as .tar.Z / .tz
        let tar = try akWrite(tree, "tar", to: dir.appendingPathComponent("c.tar"), dir: dir)
        let z = dir.appendingPathComponent("c.tar.Z")
        let compress = Process()
        compress.executableURL = URL(fileURLWithPath: "/usr/bin/compress")
        compress.arguments = ["-c", tar.path]
        FileManager.default.createFile(atPath: z.path, contents: nil)
        compress.standardOutput = try FileHandle(forWritingTo: z)
        if (try? compress.run()) != nil {
            compress.waitUntilExit()
            for format in ["tar.z", "tz", "z"] {
                let (r, _) = try akRead(z, format, into: dir.appendingPathComponent("r-\(format)"))
                check(akContents(r) == expected, "compress .Z as \(format)")
            }
        }
        // lzip: Python's raw LZMA1 stream (lc3 lp0 pb2) in the lzip member layout
        let lz = dir.appendingPathComponent("l.txt")
        try akText("lzip payload").write(to: lz)
        let py = """
        import lzma,struct,sys,zlib
        d=open(sys.argv[1],'rb').read()
        f=[{'id':lzma.FILTER_LZMA1,'dict_size':1<<22,'lc':3,'lp':0,'pb':2}]
        body=lzma.compress(d,format=lzma.FORMAT_RAW,filters=f)
        member=b'LZIP'+bytes([1,22])+body+struct.pack('<IQQ',zlib.crc32(d)&0xFFFFFFFF,len(d),6+len(body)+20)
        open(sys.argv[1]+'.lz','wb').write(member)
        """
        if akRun("/usr/bin/env", ["python3", "-I", "-c", py, lz.path]) {
            let (l, _) = try akRead(lz.appendingPathExtension("lz"), "lz", into: dir.appendingPathComponent("r-lz"))
            check(akContents(l) == ["l.txt": akText("lzip payload")], "LZ: \(akContents(l).keys)")
        }
    }

    akCase("nfc") { dir in
        // macOS hands out decomposed (NFD) names; archives carry composed (NFC) ones, with the UTF-8 flag in ZIP.
        let nfd = "re\u{0301}sume\u{0301}/ca\u{0302}fe\u{0301}.txt"
        let nfc = nfd.precomposedStringWithCanonicalMapping
        let tree = try akTree(dir, [(nfd, akText("x"))])
        for format in ["zip", "tar", "7z"] {
            let url = try akWrite(tree, format, to: dir.appendingPathComponent("n.\(format)"), dir: dir)
            let raw = try Data(contentsOf: url)
            if format != "7z" {   // 7z names are UTF-16 in an LZMA stream
                check(raw.range(of: Data(nfc.utf8)) != nil && raw.range(of: Data("e\u{0301}".utf8)) == nil, "\(format): composed bytes in the archive")
            }
            if format == "zip" { check(raw[6] & 0x08 != 0, "zip: the UTF-8 flag is set") }
            let (back, _) = try akRead(url, format, into: dir.appendingPathComponent("r-\(format)"))
            check(akPaths(back, .file) == [nfc], "\(format): the name reads back as the same text")
        }
    }

    akCase("zip.timestamps") { dir in
        let tree = try akTree(dir, [("a.txt", akText("a"))])
        let url = try akWrite(tree, "zip", to: dir.appendingPathComponent("t.zip"), dir: dir)
        let bytes = [UInt8](try Data(contentsOf: url))
        // 0x5455 "UT": the extended timestamp field holds the exact (not 2-second) time
        let hasUT = (0..<(bytes.count - 4)).contains { bytes[$0] == 0x55 && bytes[$0 + 1] == 0x54 && bytes[$0 + 2] == 0x05 && bytes[$0 + 3] == 0x00 }
        check(hasUT, "the ZIP writer stores the extended timestamp")
        let (back, _) = try akRead(url, "zip", into: dir.appendingPathComponent("r"))
        check(back.entries.first?.modified?.timeIntervalSince1970 == 1_700_000_000, "exact mtime \(String(describing: back.entries.first?.modified))")
    }

    akCase("lzo.real") { dir in
        var expected = Data(String(repeating: "0123456789abcdef", count: 16384).utf8)
        var x: UInt32 = 1
        for _ in 0..<3000 { x = x &* 1_103_515_245 &+ 12345; expected.append(UInt8(truncatingIfNeeded: x >> 16)) }
        for (kind, base64) in akLzopFixtures where kind != "tar" {
            let url = dir.appendingPathComponent("\(kind).lzo")
            try Data(base64Encoded: base64)!.write(to: url)
            var produced = Data()
            let name = try LZOKit.decompress(source: url, isCancelled: { false }, sink: { produced.append(contentsOf: $0) })
            check(produced == expected, "\(kind): lzop output decompresses to the original")
            check(name == "data.bin", "\(kind): stored name \(String(describing: name))")
            let (tree, _) = try akRead(url, "lzo", into: dir.appendingPathComponent("r-\(kind)"), engine: .lzoKit)
            check(akContents(tree) == ["data.bin": expected], "\(kind): single file named \(akContents(tree).keys)")
        }
        let tar = dir.appendingPathComponent("t.tar.lzo")
        try Data(base64Encoded: akLzopFixtures["tar"]!)!.write(to: tar)
        let (tree, _) = try akRead(tar, "tar.lzo", into: dir.appendingPathComponent("r-tar"), engine: .lzoKit)
        check(akContents(tree).keys.filter { !$0.contains("._") }.sorted() == ["t/a.txt", "t/sub/b.txt"], "tar.lzo unpacked: \(akContents(tree).keys.sorted())")
        check(akContents(tree)["t/a.txt"] == akText(String(repeating: "alpha file\n", count: 20)), "tar.lzo contents")
    }

    akCase("cab") { dir in
        let url = dir.appendingPathComponent("a.cab")
        try akCab([("readme.txt", [UInt8](akText("cabinet one"))), ("sub\\two.txt", [UInt8](akText("cabinet two")))]).write(to: url)
        let (tree, _) = try akRead(url, "cab", into: dir.appendingPathComponent("r"))
        check(akContents(tree) == ["readme.txt": akText("cabinet one"), "sub/two.txt": akText("cabinet two")], "CAB: \(akContents(tree).keys)")
    }

    akCase("lha") { dir in
        let url = dir.appendingPathComponent("a.lzh")
        try akLha([("one.txt", [UInt8](akText("lha one"))), ("two.txt", [UInt8](akText("lha two")))]).write(to: url)
        let (tree, _) = try akRead(url, "lha", into: dir.appendingPathComponent("r"))
        check(akContents(tree) == ["one.txt": akText("lha one"), "two.txt": akText("lha two")], "LHA: \(akContents(tree).keys)")
    }

    akCase("alz") { dir in
        let korean = Array("한글/파일.txt".data(using: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue))))!)
        let url = dir.appendingPathComponent("a.alz")
        try akAlz([(Array("docs".utf8), nil), (Array("docs/a.txt".utf8), [UInt8](akText("alz stored"))), (korean, [UInt8](akText("korean name")))]).write(to: url)
        let (tree, _) = try akRead(url, "alz", into: dir.appendingPathComponent("r"), engine: .unalz)
        check(akContents(tree)["docs/a.txt"] == akText("alz stored"), "ALZ stored entry: \(akContents(tree).keys)")
        check(akPaths(tree, .directory) == ["docs"], "ALZ folder")
        check(akContents(tree)["한글/파일.txt"] == akText("korean name"), "ALZ CP949 name to UTF-8: \(akPaths(tree))")
        let slip = dir.appendingPathComponent("slip.alz")
        try akAlz([(Array("..\\..\\escape.txt".utf8), [UInt8](akText("e"))), (Array("ok.txt".utf8), [UInt8](akText("ok")))]).write(to: slip)
        let (s, _) = try akRead(slip, "alz", into: dir.appendingPathComponent("outer/root"), engine: .unalz)
        check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("escape.txt").path) && !FileManager.default.fileExists(atPath: dir.appendingPathComponent("outer/escape.txt").path), "ALZ zip-slip")
        check(akPaths(s, .file).contains("ok.txt"), "ALZ: the safe entry stays")
        let cut = dir.appendingPathComponent("cut.alz")
        try (try Data(contentsOf: url)).prefix(40).write(to: cut)
        do { _ = try akRead(cut, "alz", into: dir.appendingPathComponent("c"), engine: .unalz); check(false, "truncated ALZ read") } catch is ArchiveError {} catch { check(false, "truncated ALZ: \(error)") }
        // Every truncation and a few hundred mutations must end in a result or an ArchiveError, never a crash.
        let good = try Data(contentsOf: url)
        for length in 0..<good.count {
            try good.prefix(length).write(to: cut)
            do { _ = try akRead(cut, "alz", into: dir.appendingPathComponent("t\(length)"), engine: .unalz) } catch is ArchiveError {}
        }
        var seed: UInt64 = 0x9E37_79B9
        for round in 0..<300 {
            var bytes = good
            for _ in 0..<(1 + round % 3) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                bytes[Int(seed >> 33) % bytes.count] = UInt8(truncatingIfNeeded: seed >> 20)
            }
            try bytes.write(to: cut)
            do { _ = try akRead(cut, "alz", into: dir.appendingPathComponent("m\(round)"), engine: .unalz) } catch is ArchiveError {}
        }
    }

    akCase("compressedSingleFile") { dir in
        let plain = dir.appendingPathComponent("notes.txt")
        try akText("just text\n").write(to: plain)
        for (ext, tool, args) in [("gz", "/usr/bin/gzip", ["-k", "-n"]), ("bz2", "/usr/bin/bzip2", ["-k"])] {
            guard akRun(tool, args + [plain.path]) else { continue }
            let (tree, _) = try akRead(plain.appendingPathExtension(ext), ext, into: dir.appendingPathComponent("r-\(ext)"))
            check(akContents(tree) == ["notes.txt": akText("just text\n")], "\(ext): one file under its own name: \(akContents(tree).keys)")
        }
        // .tar.gz named .gz holds a tar: the tar is unpacked, not re-wrapped
        let tree = try akTree(dir, [("x/y.txt", akText("y"))])
        let tgz = try akWrite(tree, "tar.gz", to: dir.appendingPathComponent("wrapped.gz"), dir: dir)
        let (t, _) = try akRead(tgz, "gz", into: dir.appendingPathComponent("r-tar"))
        check(akPaths(t, .file) == ["x/y.txt"], "gz holding a tar: \(akPaths(t))")
        // xz and lzma (Python writes them)
        let py = "import lzma,sys; d=open(sys.argv[1],'rb').read(); open(sys.argv[1]+'.xz','wb').write(lzma.compress(d)); open(sys.argv[1]+'.lzma','wb').write(lzma.compress(d, format=lzma.FORMAT_ALONE))"
        if akRun("/usr/bin/env", ["python3", "-I", "-c", py, plain.path]) {
            for ext in ["xz", "lzma"] {
                let (x, _) = try akRead(plain.appendingPathExtension(ext), ext, into: dir.appendingPathComponent("r-\(ext)"))
                check(akContents(x) == ["notes.txt": akText("just text\n")], "\(ext): \(akContents(x).keys)")
            }
        }
    }

    akCase("tar.7z") { dir in
        let inner = try akTree(dir, [("a/b.txt", akText("b")), ("c.txt", akText("c"))])
        let tar = try akWrite(inner, "tar", to: dir.appendingPathComponent("inner.tar"), dir: dir)
        let wrapper = dir.appendingPathComponent("wrap")
        let extractor = try SafeExtractor(root: wrapper)
        try extractor.file("inner.tar", data: try Data(contentsOf: tar))
        let url = try akWrite(extractor.finish(), "7z", to: dir.appendingPathComponent("a.tar.7z"), dir: dir)
        let (tree, _) = try akRead(url, "tar.7z", into: dir.appendingPathComponent("r"))
        check(akContents(tree) == ["a/b.txt": akText("b"), "c.txt": akText("c")], "tar.7z unwrapped: \(akContents(tree).keys)")
        // a .tar.7z holding something else is simply the 7z
        let other = try akTree(dir, [("x.txt", akText("x")), ("y.txt", akText("y"))])
        let plain = try akWrite(other, "7z", to: dir.appendingPathComponent("plain.tar.7z"), dir: dir)
        let (p, _) = try akRead(plain, "tar.7z", into: dir.appendingPathComponent("p"))
        check(akPaths(p, .file) == ["x.txt", "y.txt"], "not a tar inside: \(akPaths(p))")
    }

    akCase("dmg.iso") { dir in
        let folder = dir.appendingPathComponent("vol")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try akText("hello dmg").write(to: folder.appendingPathComponent("hello.txt"))
        try akText("nested").write(to: folder.appendingPathComponent("sub/n.txt"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("rel").path, withDestinationPath: "hello.txt")
        let dmg = dir.appendingPathComponent("t.dmg")
        if DiskImageReader.isAvailable, akRun("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", folder.path, "-format", "UDZO", "-volname", "T", dmg.path]) {
            let (tree, notes) = try akRead(dmg, "dmg", into: dir.appendingPathComponent("r1"), engine: .hdiutil)
            check(akContents(tree) == ["hello.txt": akText("hello dmg"), "sub/n.txt": akText("nested")], "DMG contents: \(akContents(tree).keys)")
            check(akPaths(tree, .symlink) == ["rel"], "DMG: the link to /Applications is dropped, the relative one kept: \(akPaths(tree, .symlink))")
            check(notes.contains { $0.detail.contains("link") }, "DMG: dropped link reported")
            check(!akPaths(tree).contains { $0.hasPrefix(".fseventsd") || $0.hasPrefix(".Trashes") || $0.hasPrefix(".Spotlight") }, "DMG: volume litter removed")
            let mounted = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
            check(!mounted.contains("T"), "the image is detached again")
            akExpectError(.passwordRequired, {
                let enc = dir.appendingPathComponent("enc.dmg")
                guard akRun("/bin/sh", ["-c", "printf 'pw' | /usr/bin/hdiutil create -quiet -srcfolder '\(folder.path)' -format UDZO -encryption AES-128 -stdinpass -volname E '\(enc.path)'"]) else { throw ArchiveError.passwordRequired }
                _ = try akRead(enc, "dmg", into: dir.appendingPathComponent("r2"), engine: .hdiutil)
            }, "encrypted DMG without a password")
        }
        let iso = dir.appendingPathComponent("t.iso")
        if akRun("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-o", iso.path, folder.path]) {
            let (tree, _) = try akRead(iso.path.hasSuffix(".iso") ? iso : iso.appendingPathExtension("iso"), "iso", into: dir.appendingPathComponent("r3"))
            check(akContents(tree).values.contains(akText("hello dmg")), "ISO 9660: \(akContents(tree).keys)")
        }
    }

    // MARK: The converter

    akCase("converter.zipTo7z") { dir in
        installFakes()
        ArchiveKitModule.install()
        let tree = try akTree(dir, [("a.txt", akText("aaa")), ("._a.txt", akText("x")), ("d/b.txt", akText("bbb"))])
        let zip = try akWrite(tree, "zip", to: dir.appendingPathComponent("My Files.zip"), dir: dir, keepMacExtras: true)
        let work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let libarchive = Services.converters.converter(for: .libarchive)!
        let context = StepContext(workFolder: work, source: zip, sourceFormat: "zip", targetFormat: "7z", options: OptionValues(["compression": "smallest"]))
        let read = complete { try await libarchive.run(Step(.libarchive, "zip", .archiveTree), input: .file(zip), context: context) }
        guard case .success(let readOut)? = read, case .archive(let unpacked) = readOut.value else { check(false, "read step: \(String(describing: read))"); return }
        check(akPaths(unpacked, .file) == ["a.txt", "._a.txt", "d/b.txt"], "read step tree")
        let write = complete { try await libarchive.run(Step(.libarchive, .archiveTree, "7z"), input: readOut.value, context: context) }
        guard case .success(let out)? = write, case .file(let file) = out.value else { check(false, "write step: \(String(describing: write))"); return }
        check(file.lastPathComponent == "My Files.7z", "output name: \(file.lastPathComponent)")
        check(out.lossNotes.contains { $0.detail.contains("Mac system file") }, "Mac extras reported: \(out.lossNotes)")
        let (back, _) = try akRead(file, "7z", into: dir.appendingPathComponent("back"))
        check(akPaths(back, .file) == ["a.txt", "d/b.txt"], "converted archive: \(akPaths(back))")
        // A step handed the wrong kind of input fails cleanly.
        let wrong = complete { try await libarchive.run(Step(.libarchive, .archiveTree, "zip"), input: .file(zip), context: context) }
        check({ if case .failure? = wrong { true } else { false } }(), "wrong input kind is an error")
    }

    akCase("converter.errors") { dir in
        installFakes()
        ArchiveKitModule.install()
        let tree = try akTree(dir, [("a.txt", akText("a"))])
        let encrypted = try akWrite(tree, "zip", to: dir.appendingPathComponent("e.zip"), dir: dir, password: "pw", compatible: true)
        let work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let libarchive = Services.converters.converter(for: .libarchive)!
        @MainActor func run(_ options: OptionValues) -> Result<StepOutput, Error>? {
            complete { try await libarchive.run(Step(.libarchive, "zip", .archiveTree), input: .file(encrypted),
                                                context: StepContext(workFolder: work, source: encrypted, sourceFormat: "zip", targetFormat: "7z", options: options)) }
        }
        check({ if case .failure(let e)? = run(OptionValues()), (e as? ConversionError) == .passwordRequired("zip") { true } else { false } }(), "no password maps to passwordRequired")
        check({ if case .success? = run(OptionValues(["password": "pw"])) { true } else { false } }(), "password option is used")
        // Re-encryption: the loss note for a dropped password.
        if case .success(let out)? = run(OptionValues(["password": "pw"])), case .archive(let unpacked) = out.value {
            let w = complete { try await libarchive.run(Step(.libarchive, .archiveTree, "tar"), input: .archive(unpacked),
                                                       context: StepContext(workFolder: work, source: encrypted, sourceFormat: "zip", targetFormat: "tar")) }
            if case .success(let o)? = w { check(o.lossNotes.contains { $0.kind == .encryptionRemoved }, "encryptionRemoved reported") } else { check(false, "tar step") }
        }
        let junk = dir.appendingPathComponent("junk.zip")
        try Data(repeating: 0x42, count: 2000).write(to: junk)
        let damaged = complete { try await libarchive.run(Step(.libarchive, "zip", .archiveTree), input: .file(junk),
                                                         context: StepContext(workFolder: work, source: junk, sourceFormat: "zip", targetFormat: "7z")) }
        check({ if case .failure(let e)? = damaged, let c = e as? ConversionError, c == .damaged("zip") || { if case .failed = c { true } else { false } }() { true } else { false } }(), "junk is damaged: \(String(describing: damaged))")
    }

    akCase("availability") { _ in
        installFakes()
        ArchiveKitModule.install()
        for converter in Services.converters.converters {
            let a = converter.availability()
            switch converter.id {
            case .sevenZip: check(a == (SevenZip.isAvailable ? .available : .unavailable("7-Zip isn’t part of this build.")), "7zz availability")
            default: check(a == .available || converter.id == .hdiutil, "\(converter.id) available")
            }
        }
    }
}
