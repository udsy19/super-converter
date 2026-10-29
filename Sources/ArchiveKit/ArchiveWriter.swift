import Archive
import Foundation
import SuperConverterCore

/// Writes an `ArchiveTree` as ZIP, 7Z, TAR, TAR.GZ or TAR.BZ2 (formats §6.8). libarchive does the writing; a password for
/// the new archive goes through 7zz (ZIP AES-256, 7Z AES-256) or libarchive's ZipCrypto when "compatible ZIP" is on.
enum ArchiveWriter {
    static func write(_ request: ArchiveWriteRequest) async throws {
        _ = LibArchive.prepared
        let tree = filtered(request.tree, keepMacExtras: request.keepMacExtras)
        var request = request
        request.tree = tree
        let fm = FileManager.default
        try fm.createDirectory(at: request.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = request.destination.deletingLastPathComponent().appendingPathComponent(".\(request.destination.lastPathComponent).partial")
        try? fm.removeItem(at: partial)
        defer { try? fm.removeItem(at: partial) }

        let password = request.password.flatMap { $0.isEmpty ? nil : $0 }
        let isTar = request.format.rawValue.hasPrefix("tar")
        if password != nil, isTar { throw ArchiveError.unsupported("TAR archives can’t have a password.") }
        // ZipCrypto is libarchive's; every AES-256 archive is 7zz's.
        let needs7zz = password != nil && !(request.format.rawValue == "zip" && request.compatibleZip)
        if needs7zz {
            let staged = request.workFolder.appendingPathComponent("stage-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: staged) }
            try stage(tree, into: staged)
            var sevenZipRequest = request
            sevenZipRequest.destination = partial
            let scratch = request.workFolder.appendingPathComponent(".7zz-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: scratch) }
            try await SevenZip.write(sevenZipRequest, staged: staged, scratch: scratch)
        } else {
            try writeWithLibarchive(request, to: partial, password: password)
        }
        try? fm.removeItem(at: request.destination)
        try fm.moveItem(at: partial, to: request.destination)
    }

    /// Mac extras (`__MACOSX`, `._*`, `.DS_Store`) are dropped unless the person keeps them.
    static func filtered(_ tree: ArchiveTree, keepMacExtras: Bool) -> ArchiveTree {
        guard !keepMacExtras else { return tree }
        var copy = tree
        copy.entries.removeAll { ArchivePath.isMacExtra($0.path) }
        return copy
    }

    // MARK: libarchive

    private static func writeWithLibarchive(_ request: ArchiveWriteRequest, to url: URL, password: String?) throws {
        guard let a = archive_write_new() else { throw ArchiveError.failed("Out of memory.") }
        defer { archive_write_free(a) }
        let level = switch request.compression { case .fast: 1; case .normal: 6; case .smallest: 9 }
        func option(_ text: String) throws {
            if archive_write_set_options(a, text) != ARCHIVE_OK { throw ArchiveError.failed(LibArchive.message(a)) }
        }
        switch request.format.rawValue {
        case "zip":
            archive_write_set_format_zip(a)
            try option("zip:compression=deflate")
            try option("zip:compression-level=\(level)")
            if let password {
                try option("zip:encryption=zipcrypt")
                archive_write_set_passphrase(a, password)
            }
        case "7z":
            archive_write_set_format_7zip(a)
            try option("7zip:compression=lzma2")
            try option("7zip:compression-level=\(request.compression == .fast ? 1 : request.compression == .normal ? 5 : 9)")
        case "tar":
            archive_write_set_format_pax_restricted(a)
        case "tar.gz":
            archive_write_set_format_pax_restricted(a)
            archive_write_add_filter_gzip(a)
            try option("gzip:compression-level=\(level)")
        case "tar.bz2":
            archive_write_set_format_pax_restricted(a)
            archive_write_add_filter_bzip2(a)
            try option("bzip2:compression-level=\(level)")
        default:
            throw ArchiveError.unsupported("Can’t write \(request.format.rawValue.uppercased()) archives.")
        }
        if archive_write_open_filename(a, url.path) != ARCHIVE_OK { throw ArchiveError.failed(LibArchive.message(a)) }

        let total = max(request.tree.totalSize, 1)
        var done: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        guard let entry = archive_entry_new() else { throw ArchiveError.failed("Out of memory.") }
        defer { archive_entry_free(entry) }

        for item in request.tree.entries {
            if request.isCancelled() { throw ArchiveError.cancelled }
            archive_entry_clear(entry)
            // macOS file names are decomposed (NFD); archives carry composed (NFC) names, which every platform shows the same way.
            let name = item.path.precomposedStringWithCanonicalMapping
            archive_entry_set_pathname(entry, item.kind == .directory ? name + "/" : name)
            let modified = item.modified ?? Date()
            archive_entry_set_mtime(entry, Int(modified.timeIntervalSince1970), 0)
            archive_entry_set_uid(entry, 0); archive_entry_set_gid(entry, 0)
            switch item.kind {
            case .directory:
                archive_entry_set_filetype(entry, 0o040000)
                archive_entry_set_perm(entry, mode_t(item.permissions | 0o111))
                archive_entry_set_size(entry, 0)
                try header(a, entry)
            case .symlink:
                archive_entry_set_filetype(entry, 0o120000)
                archive_entry_set_perm(entry, 0o755)
                archive_entry_set_symlink(entry, (item.linkTarget ?? "").precomposedStringWithCanonicalMapping)
                archive_entry_set_size(entry, 0)
                try header(a, entry)
            case .file:
                guard let source = item.extracted, let input = try? FileHandle(forReadingFrom: source) else {
                    throw ArchiveError.failed("A file to archive is missing: \(item.path)")
                }
                defer { try? input.close() }
                let size = ((try? FileManager.default.attributesOfItem(atPath: source.path)[.size]) as? NSNumber)?.int64Value ?? item.size
                archive_entry_set_filetype(entry, 0o100000)
                archive_entry_set_perm(entry, mode_t(item.permissions))
                archive_entry_set_size(entry, size)
                try header(a, entry)
                var remaining = size
                while remaining > 0 {
                    if request.isCancelled() { throw ArchiveError.cancelled }
                    let count = min(Int64(buffer.count), remaining)
                    let n = buffer.withUnsafeMutableBytes { read(input.fileDescriptor, $0.baseAddress, Int(count)) }
                    guard n > 0 else { throw ArchiveError.failed("A file changed while it was being archived: \(item.path)") }
                    let written = buffer.withUnsafeBytes { archive_write_data(a, $0.baseAddress, n) }
                    if written < 0 { throw ArchiveError.failed(LibArchive.message(a)) }
                    remaining -= Int64(n)
                    done += Int64(n)
                    request.report(StepProgress(fraction: min(Double(done) / Double(total), 0.99), unit: nil))
                }
            }
        }
        if archive_write_close(a) != ARCHIVE_OK { throw ArchiveError.failed(LibArchive.message(a)) }
    }

    private static func header(_ a: OpaquePointer, _ entry: OpaquePointer) throws {
        if archive_write_header(a, entry) < ARCHIVE_WARN { throw ArchiveError.failed(LibArchive.message(a)) }
    }

    // MARK: Staging for 7zz

    /// Lays the tree out as real files under `folder` (links to the extracted files where possible): 7zz archives a folder.
    static func stage(_ tree: ArchiveTree, into folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for item in tree.entries {
            let url = folder.appendingPathComponent(item.path)
            switch item.kind {
            case .directory:
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            case .symlink:
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: item.linkTarget ?? "")
            case .file:
                guard let source = item.extracted else { continue }
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { try fm.linkItem(at: source, to: url) } catch { try fm.copyItem(at: source, to: url) }
            }
        }
    }
}
