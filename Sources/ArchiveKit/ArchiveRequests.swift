import Foundation
import SuperConverterCore

/// File-name encodings for old archives (O-ARCHIVE "File-name encoding", formats §5). Names in UTF-8 archives are never
/// re-interpreted; this only applies to names stored in a code page.
public enum NameEncoding: String, Sendable, CaseIterable {
    case auto, cp437, shiftJIS, gbk, eucKR

    public init(option: String?) { self = option.flatMap(NameEncoding.init(rawValue:)) ?? .auto }

    /// libiconv's name, which libarchive's `hdrcharset` takes.
    var charset: String? {
        switch self {
        case .auto: nil
        case .cp437: "CP437"
        case .shiftJIS: "CP932"
        case .gbk: "GBK"
        case .eucKR: "EUC-KR"
        }
    }

    var swiftEncoding: String.Encoding? {
        switch self {
        case .auto: nil
        case .cp437: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        case .shiftJIS: .shiftJIS
        case .gbk: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        case .eucKR: .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
        }
    }
}

/// What readers left out, collected across the nested reads of one request and shown on the card as loss notes.
public final class ReadDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [LossNote] = []

    public init() {}

    func add(_ notes: [LossNote]) {
        lock.lock(); defer { lock.unlock() }
        for note in notes where !collected.contains(note) { collected.append(note) }
    }

    public var lossNotes: [LossNote] { lock.lock(); defer { lock.unlock() }; return collected }
}

/// Everything a reader needs. A reader writes the archive's contents under `root` (through `SafeExtractor`) and returns
/// the tree; it never writes anywhere else.
public struct ArchiveReadRequest: Sendable {
    public var source: URL
    public var format: FormatID
    /// The folder the contents are extracted into (created if missing).
    public var root: URL
    public var password: String?
    public var nameEncoding: NameEncoding
    /// DEB `data.tar.*` and RPM cpio payloads are unpacked instead of the package container (formats §5).
    public var unpackPayload: Bool
    public var limits: ExtractionLimits
    /// How deep inside other archives this read is (compound formats unwrap one level at a time).
    public var depth: Int
    public var report: @Sendable (StepProgress) -> Void
    public var isCancelled: @Sendable () -> Bool
    /// Shared by this request and every request nested from it.
    public let diagnostics = ReadDiagnostics()

    public init(source: URL, format: FormatID, root: URL, password: String? = nil, nameEncoding: NameEncoding = .auto,
                unpackPayload: Bool = true, limits: ExtractionLimits = ExtractionLimits(), depth: Int = 0,
                report: @escaping @Sendable (StepProgress) -> Void = { _ in }, isCancelled: @escaping @Sendable () -> Bool = { false }) {
        self.source = source; self.format = format; self.root = root; self.password = password
        self.nameEncoding = nameEncoding; self.unpackPayload = unpackPayload; self.limits = limits; self.depth = depth
        self.report = report; self.isCancelled = isCancelled
    }

    /// The size of the file being read, for the bomb ratio.
    var sourceSize: Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: source.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// A new `SafeExtractor` for this request.
    func extractor(windowsSeparators: Bool = false) throws -> SafeExtractor {
        try SafeExtractor(root: root, limits: limits, archiveSize: sourceSize, windowsSeparators: windowsSeparators,
                          diagnostics: diagnostics, isCancelled: isCancelled)
    }

    /// The same request one level down, reading `source` into `root`.
    func nested(source: URL, format: FormatID, root: URL) throws -> ArchiveReadRequest {
        guard depth < limits.maxNesting else { throw ArchiveError.tooLarge("This archive is wrapped in too many other archives.") }
        var copy = self
        copy.source = source; copy.format = format; copy.root = root; copy.depth = depth + 1
        return copy
    }

    /// The source file name without the archive extension(s): what a single compressed file is called inside.
    var innerName: String {
        var name = source.lastPathComponent
        let lower = name.lowercased()
        for ext in [".\(format.rawValue)", ".gz", ".bz2", ".bz", ".xz", ".lz", ".lzma", ".z", ".lzo", ".rz"] where lower.hasSuffix(ext) && name.count > ext.count {
            name = String(name.dropLast(ext.count)); break
        }
        return name
    }
}

/// What the writers produce (formats §6.8 targets) and the options of O-ARCHIVE that shape it.
public struct ArchiveWriteRequest: Sendable {
    public enum Compression: String, Sendable { case fast, normal, smallest }

    public var tree: ArchiveTree
    /// "zip", "7z", "tar", "tar.gz", "tar.bz2".
    public var format: FormatID
    public var destination: URL
    public var compression: Compression
    /// The password for the new archive: ZIP AES-256 and 7Z AES-256 with encrypted names (7zz), or ZipCrypto.
    public var password: String?
    public var compatibleZip: Bool
    public var keepMacExtras: Bool
    /// Cut the output into parts of this many bytes (`name.zip.001`, …) when set.
    public var splitBytes: Int64?
    /// A scratch folder inside the job's work folder.
    public var workFolder: URL
    public var isCancelled: @Sendable () -> Bool
    public var report: @Sendable (StepProgress) -> Void

    public init(tree: ArchiveTree, format: FormatID, destination: URL, compression: Compression = .normal, password: String? = nil,
                compatibleZip: Bool = false, keepMacExtras: Bool = false, splitBytes: Int64? = nil, workFolder: URL,
                report: @escaping @Sendable (StepProgress) -> Void = { _ in }, isCancelled: @escaping @Sendable () -> Bool = { false }) {
        self.tree = tree; self.format = format; self.destination = destination; self.compression = compression; self.password = password
        self.compatibleZip = compatibleZip; self.keepMacExtras = keepMacExtras; self.splitBytes = splitBytes
        self.workFolder = workFolder; self.report = report; self.isCancelled = isCancelled
    }
}
