import Foundation
import PDFKit
import SuperConverterCore
import TypesetKit

/// TypesetKit (quality §3.7): the typographic lint on every PDF it writes (layout log and PDF), text that extracts as
/// written, and LaTeX parity against Tectonic compiling DocKit's LaTeX of the same fixture — skipped where Tectonic is
/// not installed. Office files and e-books reach TypesetKit through OfficeKit's, DocKit's and EbookKit's readers.
enum TypesetKitCases {
    /// The parity and lint fixtures (`scripts/make-fixtures.swift`, `typesetting()`): their bookmark counts (the opening
    /// "# Title" becomes the title block, bookmarked when it is the only heading; each "##" a section) and the share of
    /// the source's words PDFKit reads back in order (its reading order wanders in nested lists, footnotes and formulas).
    static let fixtures: [(name: String, bookmarks: Int, words: Double)] = [
        ("prose-en", 2, 0.98), ("prose-de", 1, 0.98), ("prose-fr", 1, 0.98), ("prose-es", 1, 0.98), ("prose-it", 1, 0.98),
        ("prose-nl", 1, 0.98), ("prose-pt", 1, 0.98), ("prose-pl", 1, 0.98), ("lists", 1, 0.9), ("footnotes", 1, 0.9),
        ("tables", 1, 0.98), ("math", 1, 0.9), ("code", 1, 0.98), ("quotes", 1, 0.98),
    ]
    /// Markdown words a reader never sees in the PDF: front matter, link targets, TeX control words.
    static let markup: Set<String> = ["lang", "en", "de", "fr", "es", "it", "nl", "pt", "pl", "https", "example", "com", "spec",
                                      "int", "infty", "sqrt", "pi", "sum", "frac", "dx", "e", "i", "x", "k", "n", "a", "b", "c", "1", "2"]

    static let all: [BenchCase] =
        fixtures.map { f in
            BenchCase(id: "typesetkit.lint-\(f.name)", category: .document, fixture: "generated/typeset-\(f.name).md", target: "pdf",
                      checks: [.producesFormat("pdf"), .typographicLint(bookmarks: f.bookmarks), .textAsWritten(atLeast: f.words, ignoring: markup)])
        }
        + fixtures.map { f in
            // Tectonic compiles DocKit's LaTeX of the fixture (the golden); the check sets the same fixture with TypesetKit.
            BenchCase(id: "typesetkit.parity-\(f.name)", category: .document, tier: .full, fixture: "generated/typeset-\(f.name).md", target: "pdf",
                      route: [Step(.markdownReader, "md", .docModel), Step(.latexWriter, .docModel, "tex"), Step(.tectonic, "tex", "pdf")],
                      checks: [.latexParity()], timeout: 300)
        }
        + [
            // The other ways in: plain text, office files as written and in the LaTeX look, spreadsheets, e-books, mail.
            BenchCase(id: "typesetkit.txt-pdf", category: .document, fixture: "generated/sample.txt", target: "pdf", checks: [
                .producesFormat("pdf"), .typographicLint(bookmarks: nil), .textAsWritten(atLeast: 1.0),
            ]),
            BenchCase(id: "typesetkit.md-pdf", category: .document, fixture: "generated/sample.md", target: "pdf", checks: [
                .producesFormat("pdf"), .typographicLint(bookmarks: 3), .pdf(pages: 1, text: ["Super Converter sample", "Quality is measured", "EbookKit"]),
            ]),
            BenchCase(id: "typesetkit.docx-pdf", category: .document, fixture: "generated/sample.docx", target: "pdf", look: .asWritten, checks: [
                .producesFormat("pdf"), .typographicLint(bookmarks: nil), .pdf(pages: 1, text: ["Super Converter sample", "DocKit"]),
            ]),
            BenchCase(id: "typesetkit.docx-pdf-latex", category: .document, fixture: "generated/sample.docx", target: "pdf",
                      options: OptionValues(["look": "latex"]), checks: [
                .producesFormat("pdf"), .typographicLint(bookmarks: nil), .pdf(pages: 1, text: ["Super Converter sample", "DocKit"]),
            ]),
            BenchCase(id: "typesetkit.odt-pdf", category: .document, fixture: "generated/sample.odt", target: "pdf", look: .asWritten, checks: [
                .producesFormat("pdf"), .typographicLint(bookmarks: nil), .pdf(pages: 1, text: ["Super Converter sample", "ODT"]),
            ]),
            BenchCase(id: "typesetkit.rtf-pdf", category: .document, fixture: "generated/sample.rtf", target: "pdf", checks: [
                .producesFormat("pdf"), .typographicLint(bookmarks: nil), .pdf(pages: 1, text: ["Super Converter sample", "strong text"]),
            ]),
            BenchCase(id: "typesetkit.docx-png", category: .document, tier: .full, fixture: "generated/sample.docx", target: "png", look: .asWritten, checks: [
                .producesFormat("png"), .pictureHasInk(inkAtLeast: 0.003),
            ]),
            BenchCase(id: "typesetkit.xlsx-pdf", category: .spreadsheet, fixture: "generated/sample.xlsx", target: "pdf", checks: [
                .producesFormat("pdf"), .typographicLint(bookmarks: nil), .pdf(pages: 1, text: ["Widget", "148.5"]),
            ]),
            BenchCase(id: "typesetkit.csv-pdf", category: .spreadsheet, fixture: "generated/sample.csv", target: "pdf", checks: [
                .producesFormat("pdf"), .typographicLint(bookmarks: nil), .pdf(pages: 1, text: ["Widget", "Gizmo"]),
            ]),
            BenchCase(id: "typesetkit.epub-pdf", category: .ebook, fixture: "generated/sample.epub", target: "pdf", checks: [
                .producesFormat("pdf"), .typographicLint(bookmarks: nil), .pdf(pages: 2, text: ["Chapter 1", "quiet morning", "typeset, measured"]),
            ]),
        ]
}

extension Check {
    /// The typographic lint (quality §3.7): none of the layout log's problems among the conversion's warnings, every font
    /// embedded, a tagged structure tree, and — when given — one bookmark per heading.
    static func typographicLint(bookmarks: Int?) -> Check {
        Check(name: "typographic lint") { ctx in
            guard let url = ctx.output else { throw CheckFailure("no output") }
            let problems = ctx.result.warnings.filter(TypographicLint.isProblem) + TypographicLint.check(pdf: url, bookmarks: bookmarks)
            if !problems.isEmpty { throw CheckFailure(problems.prefix(4).joined(separator: "; ")) }
            return [.exact("lint problems", 0, equals: 0)]
        }
    }

    /// The PDF's text, hyphens at line ends rejoined and ligatures decomposed, against the source's words in order.
    static func textAsWritten(atLeast minimum: Double, ignoring: Set<String> = []) -> Check {
        Check(name: "text extracts as written") { ctx in
            guard let url = ctx.output, let doc = PDFDocument(url: url) else { throw CheckFailure("not a readable PDF") }
            let text = (doc.string ?? "").precomposedStringWithCompatibilityMapping.replacingOccurrences(of: "-\n", with: "")
            let source = words(try textOf(ctx.source)).filter { !ignoring.contains($0) }
            let found = words(text).filter { !ignoring.contains($0) }
            guard !source.isEmpty else { throw CheckFailure("the source has no text") }
            return [Measurement(name: "words as written", value: Double(longestCommonSubsequence(source, found)) / Double(source.count), limit: .atLeast(minimum))]
        }
    }

    /// LaTeX parity (quality §3.7): `ctx.output` is Tectonic's PDF of the fixture; TypesetKit sets the same fixture and
    /// must give the same page count, ≥ 90 % agreement of line-ending words (TeX's and our hyphenation patterns are the
    /// same for the languages we bundle), page 1's first baseline within 0.5 pt, and page images SSIM ≥ 0.90 at 100 dpi.
    static func latexParity() -> Check {
        Check(name: "LaTeX parity") { ctx in
            guard let golden = ctx.output, let tex = PDFDocument(url: golden) else { throw CheckFailure("Tectonic's PDF does not open") }
            let ours = await Pipeline.convert(ctx.source, to: "pdf", into: ctx.work.appendingPathComponent("typesetkit", isDirectory: true))
            guard case .converted(let result) = ours.outcome, let file = result.outputs.first, let mine = PDFDocument(url: file) else {
                throw CheckFailure("TypesetKit did not set the fixture: \(ours.outcome)")
            }
            var out: [Measurement] = [.exact("pages", Double(mine.pageCount), equals: Double(tex.pageCount))]
            let texEnds = lineEnds(tex), ourEnds = lineEnds(mine)
            out.append(Measurement(name: "line-ending words agree", value: texEnds.isEmpty ? 1 : Double(longestCommonSubsequence(texEnds, ourEnds)) / Double(texEnds.count),
                                   limit: .atLeast(0.9)))
            if let a = firstBaseline(tex), let b = firstBaseline(mine) {
                out.append(Measurement(name: "first baseline offset", value: abs(a - b), unit: "pt", limit: .atMost(0.5)))
            }
            var worst = 1.0
            for i in 0..<min(tex.pageCount, mine.pageCount) {
                guard let p = tex.page(at: i), let q = mine.page(at: i), let a = PDFRender.raster(p, dpi: 100), let b = PDFRender.raster(q, dpi: 100),
                      a.width == b.width, a.height == b.height, let s = SSIM.ssim(a, b) else { continue }
                worst = min(worst, s.mean)
                if i == 0 { ctx.attach("Tectonic page 1", raster: a, name: "tectonic-1.png"); ctx.attach("TypesetKit page 1", raster: b, name: "typesetkit-1.png") }
            }
            out.append(.ssim("page ssim (worst)", worst, atLeast: 0.9))
            return out
        }
    }

    /// The last word of every text line, in reading order.
    private static func lineEnds(_ doc: PDFDocument) -> [String] {
        (0..<doc.pageCount).flatMap { i -> [String] in
            guard let page = doc.page(at: i), let all = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
            return all.selectionsByLine().compactMap { words($0.string ?? "").last }
        }
    }

    /// Page 1's first text line: the bottom of its bounds, from the top of the page.
    private static func firstBaseline(_ doc: PDFDocument) -> Double? {
        guard let page = doc.page(at: 0), let line = page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine().first else { return nil }
        return page.bounds(for: .mediaBox).height - line.bounds(for: page).minY
    }
}
