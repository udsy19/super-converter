import Foundation
import SuperConverterCore

// Shared by every reader and writer in ArchiveKit: the errors, the extraction limits (decompression bombs), the path
// rules (zip-slip) and `SafeExtractor`, the one place that writes archive contents into a work folder.

/// Why reading or writing an archive failed. `conversionError(for:)` maps each to the ux §7.2 case the card shows.
public enum ArchiveError: Error, Equatable, Sendable {
    /// The archive (or an entry) is encrypted and no password was given, or the password did not fit.
    case passwordRequired
    /// Encrypted in a way libarchive cannot read (ZIP AES, 7z AES, RAR, encrypted headers): 7zz must do it.
    case needsSevenZip
    case damaged(String)
    /// Over a hard limit in `ExtractionLimits` (too many files, too many bytes, too deeply nested).
    case tooLarge(String)
    /// Expands like a decompression bomb (over `maxRatio` times its size and past `ratioFloor`): the person is asked first
    /// (quality §8 "Safety"), and the read runs again with `ExtractionLimits.extractAnyway` set.
    case looksLikeBomb
    case notEnoughSpace(needed: Int64)
    case unsupported(String)
    case toolMissing(String)
    case cancelled
    case failed(String)

    public func conversionError(for format: FormatID) -> ConversionError {
        switch self {
        case .passwordRequired, .needsSevenZip: .passwordRequired(format)
        case .damaged: .damaged(format)
        case .tooLarge(let why): .failed(why)
        case .looksLikeBomb:
            .needsConfirmation(question: "This archive expands over 1,000 times, past 10 GB, as a decompression bomb does. Extract it anyway?",
                               proceed: .extractAnyway, option: ExtractionLimits.extractAnywayOption)
        case .notEnoughSpace(let needed): .notEnoughSpace(volume: "this Mac", needed: needed)
        case .unsupported(let why): .failed(why)
        case .toolMissing(let name): .failed("\(name) isn’t available in this build.")
        case .cancelled: .cancelled
        case .failed(let why): .failed(why)
        }
    }
}

/// Caps that stop a hostile or runaway archive. A zip bomb (more than 1000:1 and past 10 GB) asks first (quality §8
/// "Safety"); the other caps always stop.
public struct ExtractionLimits: Sendable, Equatable {
    /// The O-ARCHIVE option that answers the bomb question with yes (`ConversionError.needsConfirmation`).
    public static let extractAnywayOption = "extractAnyway"

    /// Bytes written for one archive.
    public var maxTotalBytes: Int64 = 64 << 30
    public var maxEntries = 1_000_000
    /// Expanded size over archive size. Counted only once `ratioFloor` bytes were written, so small archives and
    /// well-compressed text never trip it.
    public var maxRatio = 1000.0
    public var ratioFloor: Int64 = 10_000_000_000
    /// The person agreed to unpack an archive that expands like a bomb; `maxTotalBytes` still applies.
    public var extractAnyway = false
    /// Archives inside archives that are unwrapped on the way (tar.7z, DEB payload, …).
    public var maxNesting = 3
    /// Free space kept back when checking whether the volume can hold the contents.
    public var reserveBytes: Int64 = 256 << 20

    public init() {}

    /// True when `expanded` bytes out of an archive of `archiveSize` bytes is a bomb the person has not agreed to.
    func looksLikeBomb(expanded: Int64, archiveSize: Int64) -> Bool {
        !extractAnyway && expanded > ratioFloor && archiveSize > 0 && Double(expanded) > maxRatio * Double(archiveSize)
    }
}

/// The rules for a name inside an archive (zip-slip).
enum ArchivePath {
    enum Result: Equatable {
        case ok(String)
        /// Nothing left after cleaning ("", ".", "/").
        case empty
        /// Climbs out of the archive ("../x", "a/../../x") or is not a plain relative name.
        case unsafe
    }

    /// Cleans a stored name into the form `ArchiveTree.Entry.path` promises: "/"-separated, no leading slash, no ".".
    /// `windowsSeparators`: the format comes from DOS/Windows tools, where "\" separates folders.
    static func normalize(_ raw: String, windowsSeparators: Bool = false) -> Result {
        var name = raw
        if windowsSeparators { name = name.replacingOccurrences(of: "\\", with: "/") }
        if name.unicodeScalars.contains(where: { $0.value == 0 }) { return .unsafe }
        var parts = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // "C:foo" or "C:" as the first component: a drive letter, not a name.
        if let first = parts.first, first.count >= 2, first.first?.isLetter == true, first[first.index(after: first.startIndex)] == ":" {
            let rest = String(first.dropFirst(2))
            if rest.isEmpty { parts.removeFirst() } else { parts[0] = rest }
        }
        parts.removeAll { $0 == "." }
        if parts.contains("..") { return .unsafe }
        return parts.isEmpty ? .empty : .ok(parts.joined(separator: "/"))
    }

    /// True when a symlink at `path` pointing at `target` stays inside the archive: relative, and never above the root.
    static func linkStaysInside(path: String, target: String) -> Bool {
        guard !target.isEmpty, !target.hasPrefix("/"), !target.unicodeScalars.contains(where: { $0.value == 0 }) else { return false }
        var depth = path.split(separator: "/").count - 1   // folders above the link
        for part in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": depth -= 1; if depth < 0 { return false }
            default: depth += 1
            }
        }
        return true
    }

    /// Names that are file-system or Finder litter rather than content, dropped from every archive read.
    static func isVolumeLitter(_ path: String) -> Bool {
        guard let top = path.split(separator: "/").first else { return false }
        return [".fseventsd", ".Trashes", ".Spotlight-V100", ".TemporaryItems", ".DocumentRevisions-V100", ".VolumeIcon.icns"].contains(String(top))
    }

    /// `__MACOSX/…`, `._name` (AppleDouble) and `.DS_Store`: the "Mac extras" the person can keep or drop (formats §5).
    static func isMacExtra(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        guard let last = parts.last else { return false }
        return parts.first == "__MACOSX" || last.hasPrefix("._") || last == ".DS_Store"
    }
}

/// Receives the files of one archive and writes them under `root`, enforcing every rule on the way. Readers call
/// `directory`, `file`, `symlink` and `hardlink` for each entry and `finish()` at the end. Single-threaded.
final class SafeExtractor {
    let root: URL
    let limits: ExtractionLimits
    let archiveSize: Int64
    let isCancelled: @Sendable () -> Bool
    let windowsSeparators: Bool
    private let diagnostics: ReadDiagnostics?

    private(set) var entries: [ArchiveTree.Entry] = []
    private var index: [String: Int] = [:]
    private(set) var totalBytes: Int64 = 0
    /// Entries left out for climbing out of the archive.
    private(set) var unsafeNames = 0
    /// Links left out for pointing outside the archive.
    private(set) var outsideLinks = 0
    private var bytesSinceSpaceCheck: Int64 = 0
    private let fm = FileManager.default

    init(root: URL, limits: ExtractionLimits = ExtractionLimits(), archiveSize: Int64 = 0, windowsSeparators: Bool = false,
         diagnostics: ReadDiagnostics? = nil, isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        self.root = root.standardizedFileURL
        self.limits = limits; self.archiveSize = archiveSize; self.windowsSeparators = windowsSeparators; self.isCancelled = isCancelled
        self.diagnostics = diagnostics
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    // MARK: Entries

    func directory(_ rawPath: String, modified: Date? = nil, permissions: Int = 0o755) throws {
        guard let path = try accept(rawPath) else { return }
        let url = try destination(path)
        try makeDirectory(url)
        record(.init(path: path, kind: .directory, modified: modified, permissions: permissions & 0o777))
    }

    /// Opens a file for writing; the caller writes the data and calls `close()`.
    func file(_ rawPath: String, size: Int64? = nil, modified: Date? = nil, permissions: Int = 0o644) throws -> FileSink? {
        guard let path = try accept(rawPath) else { return nil }
        if let size { try checkSpace(for: size) }
        let url = try freshFile(for: path)
        guard fm.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) else {
            throw ArchiveError.failed("Couldn’t write \(path).")
        }
        return FileSink(owner: self, path: path, url: url, handle: handle, modified: modified, permissions: permissions)
    }

    /// A file whose bytes are already in memory.
    func file(_ rawPath: String, data: Data, modified: Date? = nil, permissions: Int = 0o644) throws {
        guard let sink = try file(rawPath, size: Int64(data.count), modified: modified, permissions: permissions) else { return }
        try data.withUnsafeBytes { try sink.write($0) }
        try sink.close()
    }

    /// Links are never created on disk: a link is recorded in the tree (writers re-create it) and only when it stays
    /// inside the archive. That also rules out writing a file "through" a link that points elsewhere.
    func symlink(_ rawPath: String, target: String, modified: Date? = nil) throws {
        guard let path = try accept(rawPath) else { return }
        guard ArchivePath.linkStaysInside(path: path, target: target) else { outsideLinks += 1; return }
        record(.init(path: path, kind: .symlink, modified: modified, permissions: 0o755, linkTarget: target))
    }

    /// A second name for a file seen earlier: a copy of it.
    func hardlink(_ rawPath: String, to rawTarget: String, modified: Date? = nil) throws {
        guard case .ok(let target) = ArchivePath.normalize(rawTarget, windowsSeparators: windowsSeparators),
              let i = index[target], let source = entries[i].extracted, entries[i].kind == .file else { return }
        guard let path = try accept(rawPath) else { return }
        let url = try freshFile(for: path)
        try fm.copyItem(at: source, to: url)
        try account(entries[i].size)
        record(.init(path: path, kind: .file, size: entries[i].size, modified: modified ?? entries[i].modified,
                     permissions: entries[i].permissions, extracted: url))
    }

    /// Records everything a tool already extracted under `root` (7zz, hdiutil copies): names are checked, links are
    /// judged by the same rule and removed from disk, sizes count against the limits. Files stay where they are.
    func adoptExtractedTree() throws {
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey,
                                                                                .contentModificationDateKey, .isRegularFileKey],
                                         options: [], errorHandler: nil) else { return }
        var doomed: [URL] = []
        for case let url as URL in walker {
            if isCancelled() { throw ArchiveError.cancelled }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard case .ok(let path) = ArchivePath.normalize(relative), !ArchivePath.isVolumeLitter(path) else {
                doomed.append(url); walker.skipDescendants(); continue
            }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            let mode = ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? 0o644
            if values.isSymbolicLink == true {
                let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                if ArchivePath.linkStaysInside(path: path, target: target) {
                    record(.init(path: path, kind: .symlink, modified: values.contentModificationDate, permissions: 0o755, linkTarget: target))
                } else { outsideLinks += 1 }
                doomed.append(url)
            } else if values.isDirectory == true {
                record(.init(path: path, kind: .directory, modified: values.contentModificationDate, permissions: mode & 0o777))
            } else if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? 0)
                try account(size)
                record(.init(path: path, kind: .file, size: size, modified: values.contentModificationDate, permissions: mode & 0o777, extracted: url))
            } else { doomed.append(url) }   // devices, sockets, fifos
        }
        for url in doomed { try? fm.removeItem(at: url) }
    }

    // MARK: Finish

    func finish(wasEncrypted: Bool = false, nameEncoding: String? = nil) -> ArchiveTree {
        diagnostics?.add(lossNotes)
        return ArchiveTree(entries: entries, root: root, wasEncrypted: wasEncrypted, nameEncoding: nameEncoding)
    }

    /// What was left out, for the card (`StepOutput.lossNotes`).
    var lossNotes: [LossNote] {
        var notes: [LossNote] = []
        if outsideLinks > 0 {
            notes.append(LossNote(.otherLoss, detail: Formatting.count(outsideLinks, "link pointing outside the archive was left out",
                                                                       "links pointing outside the archive were left out")))
        }
        if unsafeNames > 0 {
            notes.append(LossNote(.otherLoss, detail: Formatting.count(unsafeNames, "file with an unsafe path was skipped",
                                                                       "files with unsafe paths were skipped")))
        }
        return notes
    }

    // MARK: Internals

    /// Cleans a name; nil means "skip this entry" (litter, empty, or unsafe and counted).
    private func accept(_ raw: String) throws -> String? {
        if isCancelled() { throw ArchiveError.cancelled }
        switch ArchivePath.normalize(raw, windowsSeparators: windowsSeparators) {
        case .empty: return nil
        case .unsafe: unsafeNames += 1; return nil
        case .ok(let path):
            if ArchivePath.isVolumeLitter(path) { return nil }
            if index[path] == nil, entries.count >= limits.maxEntries {
                throw ArchiveError.tooLarge("This archive holds more than \(limits.maxEntries) items, which is more than Super Converter will unpack.")
            }
            return path
        }
    }

    /// The place for `path` under the root; never outside it (a second line of defence after `normalize`).
    private func destination(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw ArchiveError.damaged("A file name points outside the archive.") }
        return url
    }

    private func makeDirectory(_ url: URL) throws {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { try fm.removeItem(at: url) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A path ready to receive a file: parents made (replacing a file that sits where a folder must be), an earlier
    /// entry with the same name replaced, and on a case-insensitive volume a clash with a different name avoided.
    private func freshFile(for path: String) throws -> URL {
        var url = try destination(path)
        try makeDirectory(url.deletingLastPathComponent())
        if let i = index[path] {
            if let old = entries[i].extracted { try? fm.removeItem(at: old) }
            totalBytes -= entries[i].size
            try? fm.removeItem(at: url)
        } else if fm.fileExists(atPath: url.path) {
            // Same name up to case (or a folder of that name): keep both under a distinct name on disk.
            var n = 2
            let base = url.deletingPathExtension(), ext = url.pathExtension
            repeat {
                url = (ext.isEmpty ? URL(fileURLWithPath: base.path + " (\(n))") : URL(fileURLWithPath: base.path + " (\(n))").appendingPathExtension(ext))
                n += 1
            } while fm.fileExists(atPath: url.path)
        }
        return url
    }

    private func record(_ entry: ArchiveTree.Entry) {
        if let i = index[entry.path] { entries[i] = entry } else { index[entry.path] = entries.count; entries.append(entry) }
    }

    fileprivate func account(_ bytes: Int64) throws {
        totalBytes += bytes
        if totalBytes > limits.maxTotalBytes {
            throw ArchiveError.tooLarge("This archive unpacks to more than \(Formatting.bytes(limits.maxTotalBytes)), which is more than Super Converter will unpack.")
        }
        if limits.looksLikeBomb(expanded: totalBytes, archiveSize: archiveSize) { throw ArchiveError.looksLikeBomb }
        bytesSinceSpaceCheck += bytes
        if bytesSinceSpaceCheck >= 256 << 20 { bytesSinceSpaceCheck = 0; try checkSpace(for: 0) }
    }

    private func checkSpace(for incoming: Int64) throws {
        guard let free = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else { return }
        if incoming + limits.reserveBytes > free { throw ArchiveError.notEnoughSpace(needed: incoming + limits.reserveBytes) }
    }

    /// One file being written.
    final class FileSink {
        private unowned let owner: SafeExtractor
        let path: String
        private let url: URL
        private let handle: FileHandle
        private let modified: Date?
        private let permissions: Int
        private var written: Int64 = 0
        private var closed = false

        fileprivate init(owner: SafeExtractor, path: String, url: URL, handle: FileHandle, modified: Date?, permissions: Int) {
            self.owner = owner; self.path = path; self.url = url; self.handle = handle; self.modified = modified; self.permissions = permissions
        }

        func write(_ bytes: UnsafeRawBufferPointer) throws {
            guard !bytes.isEmpty else { return }
            do {
                try owner.account(Int64(bytes.count))
                try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: bytes.baseAddress!), count: bytes.count, deallocator: .none))
            } catch {
                abort()
                if let archive = error as? ArchiveError { throw archive }
                throw ArchiveError.notEnoughSpace(needed: Int64(bytes.count))
            }
            written += Int64(bytes.count)
        }

        func close() throws {
            guard !closed else { return }
            closed = true
            try handle.close()
            // Owner can always read and write what it extracted; set-id and sticky bits never survive.
            var mode = permissions & 0o777 | 0o600
            if mode & 0o100 != 0 { mode |= 0o700 }
            var attributes: [FileAttributeKey: Any] = [.posixPermissions: mode]
            if let modified { attributes[.modificationDate] = modified }
            try? FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
            owner.record(.init(path: path, kind: .file, size: written, modified: modified, permissions: permissions & 0o777, extracted: url))
        }

        /// Gives up on a half-written file (error or cancellation).
        func abort() {
            guard !closed else { return }
            closed = true
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            owner.totalBytes -= written
        }
    }
}

/// Runs a bundled tool (`7zz`, `hdiutil`) for a reader or writer through HelperKit's runner (`Services.tools`, ARCHITECTURE
/// §7). The job's cancellation is a flag; it stops the tool by cancelling the task the runner works in.
enum ToolCall {
    /// `scratch` is the tool's working folder and a place it may write; `writable` are the others.
    static func run(_ tools: (any ToolRunning)?, _ tool: BundledTool, _ arguments: [String], scratch: URL, writable: [URL] = [],
                    input: Data? = nil, timeLimit: TimeInterval? = nil, outputLimit: Int = 256_000,
                    isCancelled: @escaping @Sendable () -> Bool) async throws -> HelperRunResult {
        guard let tools, tools.location(of: tool) != nil else { throw ArchiveError.toolMissing(tool == .sevenZip ? "7-Zip" : tool.rawValue) }
        if isCancelled() { throw ArchiveError.cancelled }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let invocation = ToolInvocation(tool: tool, arguments: arguments, workFolder: scratch, writable: writable, standardInput: input,
                                        timeLimit: timeLimit, outputLimit: outputLimit)
        let task = Task { try await tools.run(invocation) }
        let watcher = Task {
            while !Task.isCancelled {
                if isCancelled() { task.cancel(); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { watcher.cancel() }
        do { return try await task.value }
        catch ConversionError.cancelled { throw ArchiveError.cancelled }
        catch ConversionError.failed(let why) { throw ArchiveError.failed(why) }
    }
}
