import Foundation
import SuperConverterCore
import UniformTypeIdentifiers

/// Recognises files by content first, extension second (ux §6.2): the magic-byte table in Core, then — for `PK\3\4`
/// containers — the entries inside, and when the content says nothing, the extension (or the file system's type).
/// A file named `.jpg` that is really a PNG is a PNG; `SniffResult.mismatch` tells the card to say so.
@MainActor
public final class FormatSniffer: FormatSniffing {
    public init() {}

    /// Formats that are ZIP files with no signature inside to tell them apart: the extension decides.
    private static let unsignedZipFormats: Set<FormatID> = ["cbz", "cbc"]
    /// One- and two-byte signatures match too many files by chance; they only confirm what the extension claims.
    private static let weak: Set<FormatID> = ["arc", "bmp", "ac3", "aac", "mp3"]

    public func sniff(_ url: URL) throws -> SniffResult {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        let claimed = Self.claimedFormat(of: url)
        if values.isDirectory == true { return SniffResult(format: nil, claimed: claimed, sizeBytes: size) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = [UInt8](try handle.read(upToCount: MagicTable.headerLength) ?? Data())

        return SniffResult(format: Self.detect(header: header, claimed: claimed, url: url) ?? claimed, claimed: claimed, sizeBytes: size)
    }

    /// The format the file name (else the file system's type for the extension) says.
    static func claimedFormat(of url: URL) -> FormatID? {
        if let format = FormatCatalog.format(forFileName: url.lastPathComponent) { return format.id }
        guard !url.pathExtension.isEmpty, let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        return FormatCatalog.inputs.first { format in format.utTypes.contains { type.conforms(to: $0) } }?.id
    }

    static func detect(header: [UInt8], claimed: FormatID?, url: URL) -> FormatID? {
        for rule in MagicTable.rules where rule.matches(header) {
            if weak.contains(rule.format), rule.bytes.count <= 2, rule.also.isEmpty {
                guard let claimed, claimed == rule.format || rule.family.contains(claimed) else { continue }
            }
            if rule.format == "svg", rule.bytes == Array("<?xml".utf8) {
                // Any XML: the root element says which.
                let text = String(decoding: header.prefix(4096), as: UTF8.self)
                if text.contains("<svg") { return "svg" }
                if text.contains("<FictionBook") { return "fb2" }
                if text.contains("<html") || text.contains("<!DOCTYPE html") { return claimed.map { rule.family.contains($0) ? $0 : "html" } ?? "html" }
                guard let claimed, rule.family.contains(claimed) else { continue }
                return claimed
            }
            if rule.format == "zip" { return zipFormat(url: url, claimed: claimed) }
            if let claimed, rule.family.contains(claimed) { return claimed }
            return rule.format
        }
        return nil
    }

    private static func zipFormat(url: URL, claimed: FormatID?) -> FormatID {
        guard let zip = ZipDirectory(url: url) else { return claimed.flatMap { unsignedZipFormats.contains($0) ? $0 : nil } ?? "zip" }
        let names = zip.names
        let mimetype = zip.text(of: "mimetype")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentTypes = names.contains("[Content_Types].xml") ? zip.text(of: "[Content_Types].xml") : nil
        for rule in MagicTable.zipRules where rule.requiredEntries.allSatisfy(names.contains) {
            if let wanted = rule.mimetype, wanted != mimetype { continue }
            if let wanted = rule.contentType, !(contentTypes?.contains(wanted) ?? false) { continue }
            return rule.format
        }
        return claimed.flatMap { unsignedZipFormats.contains($0) ? $0 : nil } ?? "zip"
    }
}
