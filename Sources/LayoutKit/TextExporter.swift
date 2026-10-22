import CoreGraphics
import Foundation

/// PDF analysis → plain text (formats §5 O-PDF-TXT): in reading order, columns one after the other, running headers and
/// footers left out, hyphenated line ends joined; or as on the page, with columns kept by spaces.
/// Adapted from Super PDF's `TextExport.text`.
enum TextExporter {
    static func text(_ analysis: PDFAnalysis, asOnPage: Bool) -> String {
        let pages = analysis.pages.map { asOnPage ? pageText($0) : readingText($0) }.filter { !$0.isEmpty }
        return pages.joined(separator: "\n\n") + "\n"
    }

    static func readingText(_ page: AnalysedPage) -> String {
        page.readingOrder.compactMap { element -> String? in
            switch element {
            case .block(let id): page.blocks.first { $0.id == id }.map { reflow($0.lines.map(\.text)) }
            case .table(let id):
                page.tables.first { $0.id == id }.map { table in
                    (0..<table.rowCount).map { row in
                        table.cells.filter { $0.row == row }.sorted { $0.column < $1.column }.map(\.text).joined(separator: "\t")
                    }.joined(separator: "\n")
                }
            case .figure: nil
            }
        }.joined(separator: "\n\n")
    }

    /// A block's lines as one paragraph: words hyphenated at a line end are joined again.
    static func reflow(_ lines: [String]) -> String {
        var out = ""
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if out.isEmpty { out = text; continue }
            if out.hasSuffix("-"), let last = out.dropLast().last, last.isLetter, let first = text.first, first.isLowercase {
                out.removeLast(); out += text
            } else {
                out += " " + text
            }
        }
        return out
    }

    /// Rows of the page's words placed at character columns by their x position; a blank line where the gap is wide.
    static func pageText(_ page: AnalysedPage) -> String {
        let words = page.blocks.filter { block in
            if case .header = block.kind { return false }; if case .footer = block.kind { return false }; if case .pageNumber = block.kind { return false }
            return true
        }.flatMap(\.lines).flatMap(\.words) + page.tables.flatMap { $0.cells.flatMap(\.words) }
        let rows = LineBuilder.baselineRows(words)
        guard !rows.isEmpty else { return "" }
        let widths = words.filter { $0.text.count > 1 }.map { $0.bounds.width / CGFloat($0.text.count) }
        let character = max(median(widths), 1)
        let left = words.map(\.bounds.minX).min() ?? 0
        var out: [String] = []
        var previous: TextLine?
        for row in rows.sorted(by: { $0.bounds.maxY > $1.bounds.maxY }) {
            if let previous, previous.bounds.minY - row.bounds.maxY > 1.2 * max(row.fontSize, 1) { out.append("") }
            var line = ""
            for word in row.words {
                let column = Int(((word.bounds.minX - left) / character).rounded())
                if line.count < column { line += String(repeating: " ", count: column - line.count) } else if !line.isEmpty { line += " " }
                line += word.text
            }
            out.append(line)
            previous = row
        }
        return out.joined(separator: "\n")
    }
}
