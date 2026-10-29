import Foundation
import SuperConverterCore

/// ArchiveKit's front door: reads any archive into an `ArchiveTree` (the engine id from `format-matrix.json` picks the
/// reader) and writes a tree as ZIP, 7Z, TAR, TAR.GZ or TAR.BZ2.
public enum Archives {
    /// Extracts `request.source` into `request.root` with the reader the matrix names for `engine`.
    public static func read(_ request: ArchiveReadRequest, engine: EngineID) async throws -> ArchiveTree {
        switch engine {
        case .libarchive: return try await readPackageOrArchive(request)
        case .sevenZip: return try await SevenZip.read(request)
        case .hdiutil:
            do { return try await DiskImageReader.read(request) } catch ArchiveError.unsupported where SevenZip.isAvailable(request.tools) {
                try? FileManager.default.removeItem(at: request.root)
                return try await SevenZip.read(request)
            }
        case .unalz: return try UnALZReader.read(request)
        case .aceKit: return try ACEKit.read(request)
        case .arcKit: return try ARCKit.read(request)
        case .lzoKit:
            return try await readCompressedStream(request) { sink in
                try LZOKit.decompress(source: request.source, isCancelled: request.isCancelled, sink: sink)
            }
        case .rzipKit:
            return try await readCompressedStream(request) { sink in
                try RZipKit.decompress(source: request.source, isCancelled: request.isCancelled, sink: sink)
                return nil
            }
        default: throw ArchiveError.unsupported("\(engine.rawValue) doesn’t read archives.")
        }
    }

    /// Writes the tree to `request.destination`; with `splitBytes` set, a folder of numbered parts instead (its URL is returned).
    @discardableResult
    public static func write(_ request: ArchiveWriteRequest) async throws -> URL {
        try await ArchiveWriter.write(request)
        guard let size = request.splitBytes, size > 0 else { return request.destination }
        return try split(request.destination, partBytes: size, isCancelled: request.isCancelled)
    }

    // MARK: libarchive family

    /// libarchive first, then 7zz for what libarchive cannot do (encryption it has no crypto library for, UDF, Quantum CAB).
    static func readWithFallback(_ request: ArchiveReadRequest) async throws -> ArchiveTree {
        do {
            return try LibArchiveReader.read(request)
        } catch let error as ArchiveError {
            switch error {
            case .passwordRequired where request.password == nil:
                throw error
            case .needsSevenZip where request.password == nil:
                throw ArchiveError.passwordRequired
            case .passwordRequired, .needsSevenZip, .unsupported, .damaged:
                guard SevenZip.isAvailable(request.tools) else { throw error == .needsSevenZip ? ArchiveError.unsupported("This archive’s encryption isn’t supported here.") : error }
                try? FileManager.default.removeItem(at: request.root)
                do { return try await SevenZip.read(request) } catch ArchiveError.passwordRequired {
                    throw ArchiveError.passwordRequired
                } catch let second as ArchiveError {
                    switch second {
                    case .cancelled, .tooLarge, .notEnoughSpace: throw second
                    default: throw error == .needsSevenZip ? second : error   // keep libarchive's verdict, except "needs 7zz"
                    }
                }
            default:
                throw error
            }
        }
    }

    /// DEB and RPM payloads, tar-in-7z and plain archives.
    private static func readPackageOrArchive(_ request: ArchiveReadRequest) async throws -> ArchiveTree {
        switch request.format.rawValue {
        case "deb" where request.unpackPayload: return try await readDebPayload(request)
        case "tar.7z": return try await readWrapped(request, container: "7z")
        case "iso":
            // A UDF-only disc carries an empty ISO 9660 bridge that libarchive reads as nothing: 7zz reads the UDF.
            let tree = try await readWithFallback(request)
            guard tree.entries.isEmpty, SevenZip.isAvailable(request.tools) else { return tree }
            try? FileManager.default.removeItem(at: request.root)
            return try await SevenZip.read(request)
        default: return try await readWithFallback(request)
        }
    }

    /// A Debian package is an `ar` archive: `debian-binary`, `control.tar.*`, `data.tar.*`. The payload is `data.tar.*`.
    private static func readDebPayload(_ request: ArchiveReadRequest) async throws -> ArchiveTree {
        var members = request
        members.unpackPayload = false
        let (tree, cleanup) = try await readAside(members)
        defer { cleanup() }
        guard let data = tree.entries.first(where: { $0.kind == .file && $0.path.hasPrefix("data.tar") }), let file = data.extracted else {
            return try await readWithFallback(members)
        }
        var payload = try request.nested(source: file, format: "tar", root: request.root)
        payload.unpackPayload = false
        return try await readWithFallback(payload)
    }

    /// `tar.7z`: a 7z holding one tar. When the 7z holds anything else it is read as the 7z it is.
    private static func readWrapped(_ request: ArchiveReadRequest, container: FormatID) async throws -> ArchiveTree {
        let (tree, cleanup) = try await readAside(try request.nested(source: request.source, format: container, root: request.root))
        defer { cleanup() }
        let files = tree.entries.filter { $0.kind == .file }
        guard files.count == 1, let file = files[0].extracted, looksLikeTar(file) else {
            var plain = request
            plain.format = container
            return try await readWithFallback(plain)
        }
        return try await readWithFallback(try request.nested(source: file, format: "tar", root: request.root))
    }

    /// Reads into a throw-away folder next to the real root; the caller deletes it with the returned closure.
    private static func readAside(_ request: ArchiveReadRequest) async throws -> (ArchiveTree, () -> Void) {
        let aside = request.root.deletingLastPathComponent().appendingPathComponent(".aside-\(UUID().uuidString)")
        var copy = request
        copy.root = aside
        let cleanup = { try? FileManager.default.removeItem(at: aside); return }
        do { return (try await readWithFallback(copy), cleanup) } catch { cleanup(); throw error }
    }

    // MARK: Single compressed files (lzop, rzip)

    /// A stream decompressor (LZO, rzip) holds one file. A tar inside is unpacked as the archive it is (TAR.LZO, TZO, a
    /// tarred rzip); anything else becomes the one file, named from the container header or the source name.
    private static func readCompressedStream(_ request: ArchiveReadRequest,
                                             decompress: ((UnsafeRawBufferPointer) throws -> Void) throws -> String?) async throws -> ArchiveTree {
        let aside = request.root.deletingLastPathComponent().appendingPathComponent(".stream-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: aside) }
        let holder = try SafeExtractor(root: aside, limits: request.limits, archiveSize: request.sourceSize, isCancelled: request.isCancelled)
        guard let sink = try holder.file("payload") else { throw ArchiveError.failed("Couldn’t unpack the file.") }
        var storedName: String?
        do {
            storedName = try decompress { try sink.write($0) }
            try sink.close()
        } catch { sink.abort(); throw error }
        let payload = aside.appendingPathComponent("payload")

        if looksLikeTar(payload) {
            return try await readWithFallback(try request.nested(source: payload, format: "tar", root: request.root))
        }
        let name = storedName.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? request.innerName
        let extractor = try request.extractor()
        try FileManager.default.createDirectory(at: request.root, withIntermediateDirectories: true)
        let target = request.root.appendingPathComponent(name.isEmpty ? "data" : name)
        try FileManager.default.moveItem(at: payload, to: target)
        try extractor.adoptExtractedTree()
        return extractor.finish()
    }

    static func looksLikeTar(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file), let head = try? handle.read(upToCount: 512) else { return false }
        try? handle.close()
        return head.count == 512 && head[257..<262].elementsEqual(Array("ustar".utf8))
    }

    // MARK: Splitting

    /// Cuts `file` into `<name>.001`, `.002`, … inside a folder `<name> parts` next to it, and removes the original.
    private static func split(_ file: URL, partBytes: Int64, isCancelled: @Sendable () -> Bool) throws -> URL {
        let fm = FileManager.default
        let folder = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + " parts")
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var number = 1
        while true {
            if isCancelled() { throw ArchiveError.cancelled }
            var left = partBytes
            var part: FileHandle?
            while left > 0, let chunk = try input.read(upToCount: Int(min(left, 4 << 20))), !chunk.isEmpty {
                if part == nil {
                    let url = folder.appendingPathComponent(file.lastPathComponent + String(format: ".%03d", number))
                    fm.createFile(atPath: url.path, contents: nil)
                    part = try FileHandle(forWritingTo: url)
                }
                try part?.write(contentsOf: chunk)
                left -= Int64(chunk.count)
            }
            try part?.close()
            if part == nil { break }
            number += 1
        }
        try fm.removeItem(at: file)
        return folder
    }
}
