import Foundation
import SuperConverterCore

// OOXML repackaging (formats §3.2: "OOXML repackage (macros dropped; content untouched)"): a macro-enabled workbook,
// document or presentation, a template or a slide show becomes the plain format by rewriting the package's content types
// and removing the macro parts. Every other part is copied byte for byte.

enum OOXMLRepackage {
    /// Main-part content types of the variants, replaced by the plain one (longest first, so a substring never wins).
    private static let mainTypes: [(String, String)] = [
        ("wordprocessingml.template.macroEnabled.main+xml", "wordprocessingml.document.main+xml"),
        ("wordprocessingml.document.macroEnabled.main+xml", "wordprocessingml.document.main+xml"),
        ("wordprocessingml.template.main+xml", "wordprocessingml.document.main+xml"),
        ("presentationml.template.macroEnabled.main+xml", "presentationml.presentation.main+xml"),
        ("presentationml.slideshow.macroEnabled.main+xml", "presentationml.presentation.main+xml"),
        ("presentationml.presentation.macroEnabled.main+xml", "presentationml.presentation.main+xml"),
        ("presentationml.template.main+xml", "presentationml.presentation.main+xml"),
        ("presentationml.slideshow.main+xml", "presentationml.presentation.main+xml"),
        ("spreadsheetml.template.macroEnabled.main+xml", "spreadsheetml.sheet.main+xml"),
        ("spreadsheetml.sheet.macroEnabled.main+xml", "spreadsheetml.sheet.main+xml"),
        ("spreadsheetml.template.main+xml", "spreadsheetml.sheet.main+xml"),
    ]

    private static let macroPart = try! NSRegularExpression(pattern: #"(^|/)(vbaProject\.bin|vbaProjectSignature\.bin|vbaData\.xml)$"#, options: .caseInsensitive)
    private static let macroTag = try! NSRegularExpression(pattern: #"<(Override|Default|Relationship)\b[^>]*(vbaProject|vbaData|vbaProjectSignature)[^>]*/>"#, options: .caseInsensitive)

    /// The plain package, and whether macros were removed.
    static func repackage(_ data: Data) throws -> (data: Data, removedMacros: Bool) {
        let archive: ZipArchive
        do { archive = try ZipArchive(data: data) } catch { throw ConversionError.damaged(FormatID("zip")) }
        var zip = ZipWriter()
        var removed = false
        var wroteTypes = false
        // [Content_Types].xml first, as the package convention has it.
        let ordered = archive.entries.filter { !$0.isDirectory }.sorted { ($0.path == "[Content_Types].xml" ? 0 : 1) < ($1.path == "[Content_Types].xml" ? 0 : 1) }
        for entry in ordered {
            let range = NSRange(entry.path.startIndex..., in: entry.path)
            if macroPart.firstMatch(in: entry.path, range: range) != nil { removed = true; continue }
            var bytes = try archive.data(for: entry)
            if entry.path == "[Content_Types].xml", var text = String(data: bytes, encoding: .utf8) {
                wroteTypes = true
                text = strip(text, removed: &removed)
                for (from, to) in mainTypes { text = text.replacingOccurrences(of: from, with: to) }
                bytes = Data(text.utf8)
            } else if entry.path.hasSuffix(".rels"), var text = String(data: bytes, encoding: .utf8) {
                text = strip(text, removed: &removed)
                bytes = Data(text.utf8)
            }
            zip.add(entry.path, bytes)
        }
        guard wroteTypes else { throw ConversionError.damaged(FormatID("zip")) }
        return (zip.finish(), removed)
    }

    private static func strip(_ text: String, removed: inout Bool) -> String {
        let range = NSRange(text.startIndex..., in: text)
        guard macroTag.firstMatch(in: text, range: range) != nil else { return text }
        removed = true
        return macroTag.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
