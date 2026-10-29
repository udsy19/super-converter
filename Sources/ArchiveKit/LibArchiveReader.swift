import Archive
import Foundation
import SuperConverterCore

/// libarchive's C API from Swift: the reader (every format libarchive knows) and the helpers both directions share.
enum LibArchive {
    /// libarchive converts names through the C locale: call `setlocale(LC_ALL, "en_US.UTF-8")` once before using names
    /// (scripts/build-vendor.sh).
    static let prepared: Void = { setlocale(LC_ALL, "en_US.UTF-8") }()

    static func message(_ a: OpaquePointer?) -> String {
        guard let a, let text = archive_error_string(a) else { return "" }
        return String(cString: text)
    }

    /// Maps a failed libarchive call to the error the dispatcher acts on.
    static func classify(_ a: OpaquePointer?, hasPassword: Bool) -> ArchiveError {
        let text = message(a)
        let lower = text.lowercased()
        if lower.contains("passphrase required") { return .passwordRequired }
        if lower.contains("incorrect passphrase") { return .passwordRequired }
        if lower.contains("encrypt") || lower.contains("crypto library") || lower.contains("decryption") { return .needsSevenZip }
        if lower.contains("unrecognized archive format") || lower.contains("unsupported") || lower.contains("not supported")
            || lower.contains("unknown compression") || lower.contains("invalid or unsupported") { return .unsupported(text) }
        return .damaged(text)
    }
}

enum LibArchiveReader {
    /// Reads `request.source` with libarchive into `request.root`.
    /// - Throws: `.passwordRequired`, `.needsSevenZip` (encryption libarchive cannot do), `.unsupported` (format or method
    ///   libarchive lacks), `.damaged`, and the limit errors.
    static func read(_ request: ArchiveReadRequest) throws -> ArchiveTree {
        _ = LibArchive.prepared
        var encoding = request.nameEncoding
        for attempt in 0..<2 {
            do {
                return try readOnce(request, encoding: encoding)
            } catch NeedsEncoding.scan where attempt == 0 {
                // A name that is not UTF-8 and no encoding chosen: look at every name first, pick one, read again.
                try? FileManager.default.removeItem(at: request.root)
                encoding = try detectEncoding(request)
            }
        }
        throw ArchiveError.failed("Couldn’t read the file names in this archive.")
    }

    private enum NeedsEncoding: Error { case scan }

    /// Formats that are one compressed file (gz, bz2, …): a tar inside is unpacked, anything else is the one entry.
    private static let singleStreamFormats: Set<String> = ["gz", "bz", "bz2", "xz", "lz", "lzma", "z"]

    private static func open(_ request: ArchiveReadRequest) throws -> OpaquePointer {
        guard let a = archive_read_new() else { throw ArchiveError.failed("Out of memory.") }
        archive_read_support_filter_all(a)
        let single = singleStreamFormats.contains(request.format.rawValue)
        if request.format.rawValue == "rpm", !request.unpackPayload {
            archive_read_support_format_raw(a)
        } else {
            archive_read_support_format_all(a)
            // Raw (one file, any bytes) only for compressors that hold one file; otherwise it would swallow whatever
            // libarchive does not recognise, including damaged archives.
            if single { archive_read_support_format_raw(a) }
        }
        // Keep `._name` AppleDouble files and `__MACOSX` as the entries they are: ArchiveKit's options decide what stays.
        archive_read_set_options(a, "!mac-ext")
        if let password = request.password { archive_read_add_passphrase(a, password) }
        if archive_read_open_filename(a, request.source.path, 1 << 20) != ARCHIVE_OK {
            let error = LibArchive.classify(a, hasPassword: request.password != nil)
            archive_read_free(a)
            throw error
        }
        return a
    }

    private static func readOnce(_ request: ArchiveReadRequest, encoding: NameEncoding) throws -> ArchiveTree {
        let a = try open(request)
        defer { archive_read_free(a) }
        let extractor = try request.extractor()
        let total = max(request.sourceSize, 1)
        var wasEncrypted = false
        var names = NameDecoder(encoding: encoding)
        var buffer = [UInt8]()

        while true {
            var entryPointer: OpaquePointer?
            let status = archive_read_next_header(a, &entryPointer)
            if status == ARCHIVE_EOF { break }
            if status < ARCHIVE_WARN { throw LibArchive.classify(a, hasPassword: request.password != nil) }
            guard let entry = entryPointer else { break }
            if request.isCancelled() { throw ArchiveError.cancelled }
            request.report(StepProgress(fraction: min(Double(archive_filter_bytes(a, -1)) / Double(total), 0.99), unit: nil))

            let isRaw = archive_format(a) & ARCHIVE_FORMAT_BASE_MASK == ARCHIVE_FORMAT_RAW
            if isRaw && archive_filter_code(a, 0) == ARCHIVE_FILTER_NONE { throw ArchiveError.damaged("This isn’t a \(request.format.pill) file.") }
            let rawName = isRaw ? request.innerName : try names.decode(entry)
            if archive_entry_is_encrypted(entry) != 0 { wasEncrypted = true }
            let modified: Date? = archive_entry_mtime_is_set(entry) != 0 ? Date(timeIntervalSince1970: TimeInterval(archive_entry_mtime(entry))) : nil
            let permissions = Int(archive_entry_perm(entry))

            if let hardlink = archive_entry_hardlink_utf8(entry).map({ String(cString: $0) }) ?? archive_entry_hardlink(entry).map({ String(cString: $0) }) {
                try extractor.hardlink(rawName, to: hardlink, modified: modified)
                continue
            }
            switch Int(archive_entry_filetype(entry)) & 0o170000 {
            case 0o040000:
                try extractor.directory(rawName, modified: modified, permissions: permissions)
            case 0o120000:
                let target = archive_entry_symlink_utf8(entry).map { String(cString: $0) } ?? archive_entry_symlink(entry).map { String(cString: $0) } ?? ""
                try extractor.symlink(rawName, target: target, modified: modified)
            case 0o100000, 0:
                let size: Int64? = archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil
                try copyData(a, to: extractor, name: rawName, size: size, modified: modified, permissions: permissions,
                             buffer: &buffer, hasPassword: request.password != nil)
            default:
                continue   // devices, sockets, fifos
            }
        }
        request.report(StepProgress(fraction: 1, unit: nil))
        return extractor.finish(wasEncrypted: wasEncrypted, nameEncoding: names.used)
    }

    private static func copyData(_ a: OpaquePointer, to extractor: SafeExtractor, name: String, size: Int64?, modified: Date?, permissions: Int,
                                 buffer: inout [UInt8], hasPassword: Bool) throws {
        guard let sink = try extractor.file(name, size: size, modified: modified, permissions: permissions) else {
            archive_read_data_skip(a); return
        }
        do {
            var written: Int64 = 0
            while true {
                var block: UnsafeRawPointer?
                var length = 0
                var offset: Int64 = 0
                let status = archive_read_data_block(a, &block, &length, &offset)
                if status == ARCHIVE_EOF { break }
                if status < ARCHIVE_WARN { throw LibArchive.classify(a, hasPassword: hasPassword) }
                if offset > written {   // a sparse hole
                    // A hole past the entry's own size is a damaged sparse map, not gigabytes of zeros to write.
                    if let size, offset > size { throw ArchiveError.damaged("A sparse file in this archive points past its own end.") }
                    var gap = offset - written
                    if buffer.count < 1 << 16 { buffer = [UInt8](repeating: 0, count: 1 << 16) }
                    while gap > 0 {
                        let n = Int(min(gap, Int64(buffer.count)))
                        try buffer.withUnsafeBytes { try sink.write(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                        gap -= Int64(n)
                    }
                    written = offset
                }
                if let block, length > 0 { try sink.write(UnsafeRawBufferPointer(start: block, count: length)) }
                written += Int64(length)
            }
            try sink.close()
        } catch {
            sink.abort()
            throw error
        }
    }

    // MARK: File names

    /// Turns an entry's stored name into text. Names that are valid UTF-8 are used as they are; others are decoded with the
    /// chosen code page, or (automatic) the read stops with `NeedsEncoding.scan` so the encoding can be detected.
    private struct NameDecoder {
        let encoding: NameEncoding
        private(set) var used: String?

        init(encoding: NameEncoding) { self.encoding = encoding }

        mutating func decode(_ entry: OpaquePointer) throws -> String {
            if let utf8 = archive_entry_pathname_utf8(entry) { return String(cString: utf8) }
            guard let raw = archive_entry_pathname(entry) else { return "" }
            let bytes = Data(bytes: raw, count: strlen(raw))
            if let text = String(data: bytes, encoding: .utf8) { return text }
            guard let codePage = encoding.swiftEncoding else { throw NeedsEncoding.scan }
            used = encoding.charset
            return String(data: bytes, encoding: codePage) ?? String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Reads every header and chooses a code page for the names that are not UTF-8 (formats §5: CP437, Shift-JIS, GBK,
    /// EUC-KR detected for old ZIPs).
    private static func detectEncoding(_ request: ArchiveReadRequest) throws -> NameEncoding {
        let a = try open(request)
        defer { archive_read_free(a) }
        var samples = Data()
        var entryPointer: OpaquePointer?
        while archive_read_next_header(a, &entryPointer) == ARCHIVE_OK, let entry = entryPointer {
            if request.isCancelled() { throw ArchiveError.cancelled }
            if archive_entry_pathname_utf8(entry) == nil, let raw = archive_entry_pathname(entry) {
                let bytes = Data(bytes: raw, count: strlen(raw))
                if String(data: bytes, encoding: .utf8) == nil { samples.append(bytes); samples.append(0x2F) }
            }
            archive_read_data_skip(a)
        }
        return NameEncodingDetector.guess(samples)
    }
}

/// A guess at the code page of old file names (the person can override it in the options).
enum NameEncodingDetector {
    /// Decodes the sample with each CJK code page that accepts it and keeps the one whose text looks most like that language:
    /// kana for Japanese, mostly hangul for Korean, ideographs alone for Chinese. Nothing fits: CP437, the DOS default.
    static func guess(_ bytes: Data) -> NameEncoding {
        var best: (NameEncoding, Int)?
        for candidate in [NameEncoding.shiftJIS, .eucKR, .gbk] {
            guard let encoding = candidate.swiftEncoding, let text = String(data: bytes, encoding: encoding) else { continue }
            var kana = 0, hangul = 0, ideographs = 0, odd = 0
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x3040...0x30FF: kana += 1
                case 0xAC00...0xD7A3: hangul += 1
                case 0x4E00...0x9FFF: ideographs += 1
                case 0xFF61...0xFF9F, 0xE000...0xF8FF: odd += 1   // half-width kana, private use: signs of a wrong guess
                default: break
                }
            }
            let cjk = kana + hangul + ideographs
            guard cjk > 0, odd * 4 <= cjk else { continue }
            let score: Int
            switch candidate {
            case .shiftJIS: score = kana > 0 && (kana + ideographs) * 10 >= cjk * 9 ? 10 * kana + ideographs : 0
            case .eucKR: score = hangul * 5 >= cjk * 4 ? 10 * hangul : 0
            default: score = ideographs * 10 >= cjk * 9 ? ideographs : 0
            }
            if score > (best?.1 ?? 0) { best = (candidate, score) }
        }
        return best?.0 ?? .cp437
    }
}
