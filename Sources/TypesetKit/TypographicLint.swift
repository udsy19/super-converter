import CoreGraphics
import Foundation
import PDFKit

/// The typographic lint every TypesetKit PDF passes (quality §3.7). Over the layout log: no overfull line (more than
/// 0.1 pt past the margin), no line with badness above 200 outside the emergency pass, at most two hyphenated lines in a
/// row, no widow or orphan unless the paragraph has two lines or fewer, and no heading as the last line of a page. Over
/// the PDF: every font embedded, a tagged structure tree, and bookmarks for the headings.
public enum TypographicLint {
    public static func check(_ log: TypesetLog) -> [String] {
        var problems: [String] = []
        var run = 0
        var lastParagraph = -2
        for line in log.lines {
            let place = "page \(line.page): “\(line.text.prefix(40))”"
            if line.overfull > 0.1 { problems.append("Overfull by \(String(format: "%.2f", line.overfull)) pt on \(place)") }
            if line.badness > 200 && !line.emergency && !line.isHeading && line.lineInParagraph < line.linesInParagraph - 1 {
                problems.append("Badness \(line.badness) on \(place)")
            }
            if line.paragraph != lastParagraph { run = 0; lastParagraph = line.paragraph }
            run = line.hyphenated ? run + 1 : 0
            if run > 2 { problems.append("More than two hyphenated lines in a row on \(place)") }
            if line.paragraph >= 0 && line.linesInParagraph > 2 {
                if line.firstOnPage && line.lineInParagraph == line.linesInParagraph - 1 { problems.append("Widow on \(place)") }
                if line.lastOnPage && line.lineInParagraph == 0 && line.page < log.pages { problems.append("Orphan on \(place)") }
            }
            if line.isHeading && line.lastOnPage && line.page < log.pages { problems.append("Heading at the foot of \(place)") }
        }
        return problems
    }

    /// Whether a conversion warning is one of `check(_:)`'s problems (TypesetKit reports them as warnings).
    public static func isProblem(_ warning: String) -> Bool {
        ["Overfull by ", "Badness ", "More than two hyphenated", "Widow on ", "Orphan on ", "Heading at the foot"].contains { warning.hasPrefix($0) }
    }

    /// The PDF half: fonts embedded (a FontFile stream, or a Type 0 font's descendants), a StructTreeRoot, and — when
    /// `bookmarks` is given — that many top-level-or-nested outline entries.
    public static func check(pdf url: URL, bookmarks: Int? = nil) -> [String] {
        guard let cg = CGPDFDocument(url as CFURL), let doc = PDFDocument(url: url) else { return ["The PDF does not open"] }
        var problems: [String] = []
        var unembedded = Set<String>()
        for i in 1...max(1, cg.numberOfPages) {
            guard let dict = cg.page(at: i)?.dictionary else { continue }
            var resources: CGPDFDictionaryRef?, fonts: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts else { continue }
            CGPDFDictionaryApplyBlock(fonts, { key, object, _ in
                var font: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &font), let font else { return true }
                var descriptor: CGPDFDictionaryRef?, stream: CGPDFStreamRef?, array: CGPDFArrayRef?
                var embedded = CGPDFDictionaryGetArray(font, "DescendantFonts", &array)
                if CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor), let descriptor {
                    embedded = CGPDFDictionaryGetStream(descriptor, "FontFile", &stream) || CGPDFDictionaryGetStream(descriptor, "FontFile2", &stream)
                        || CGPDFDictionaryGetStream(descriptor, "FontFile3", &stream)
                }
                if !embedded { unembedded.insert(String(cString: key)) }
                return true
            }, nil)
        }
        if !unembedded.isEmpty { problems.append("Fonts not embedded: \(unembedded.sorted().joined(separator: ", "))") }
        var tree: CGPDFDictionaryRef?
        if !(cg.catalog.map { CGPDFDictionaryGetDictionary($0, "StructTreeRoot", &tree) } ?? false) { problems.append("No tagged structure") }
        if let bookmarks {
            func count(_ o: PDFOutline?) -> Int { guard let o else { return 0 }; return (0..<o.numberOfChildren).reduce(0) { $0 + 1 + count(o.child(at: $1)) } }
            let found = count(doc.outlineRoot)
            if found != bookmarks { problems.append("\(found) bookmark(s) for \(bookmarks) heading(s)") }
        }
        return problems
    }
}
