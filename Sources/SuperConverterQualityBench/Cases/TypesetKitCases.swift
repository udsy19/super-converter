import Foundation
import PDFKit
import SuperConverterCore
import TypesetKit
import VectorKit

/// TypesetKit (quality §3.7): the typographic lint on every PDF it writes (layout log and PDF), text that extracts as
/// written, and LaTeX parity against Tectonic compiling DocKit's LaTeX of the same fixture (the committed golden PDF,
/// remade by `--bless` where Tectonic is installed). Office files and e-books reach TypesetKit through OfficeKit's,
/// DocKit's and EbookKit's readers.
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
            // TypesetKit sets the fixture on LaTeX's default Letter paper; the check compares it with Tectonic's PDF of
            // DocKit's LaTeX of the same fixture.
            BenchCase(id: "typesetkit.parity-\(f.name)", category: .document, tier: .full, fixture: "generated/typeset-\(f.name).md", target: "pdf",
                      options: OptionValues(["paper": "letter"]), checks: [.latexParity()], timeout: 300)
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

    /// LaTeX parity (quality §3.7): `ctx.output` is TypesetKit's PDF of the fixture; `Tests/Golden/<case>/tectonic.pdf` is
    /// Tectonic's (`--bless` remakes it and records the version in `tectonic.txt`). Same page count, ≥ 90 % agreement of
    /// line-ending words (TeX's and our hyphenation patterns are the same for the languages we bundle), page 1's first
    /// baseline within 0.5 pt, and page images SSIM ≥ 0.90 at 100 dpi.
    static func latexParity() -> Check {
        Check(name: "LaTeX parity") { ctx in
            let golden = ctx.golden.appendingPathComponent("tectonic.pdf")
            if ctx.blessing { try await Tectonic.compile(ctx.source, to: golden, work: ctx.work.appendingPathComponent("tectonic", isDirectory: true)) }
            guard let tex = PDFDocument(url: golden) else { throw CheckFailure("no Tectonic golden: run --bless \(ctx.bench.id) where Tectonic is installed") }
            guard let file = ctx.output, let mine = PDFDocument(url: file) else { throw CheckFailure("TypesetKit's PDF does not open") }
            var out: [Measurement] = [.exact("pages", Double(mine.pageCount), equals: Double(tex.pageCount))]
            let texEnds = lineEnds(tex), ourEnds = lineEnds(mine)
            out.append(Measurement(name: "line-ending words agree", value: texEnds.isEmpty ? 1 : Double(longestCommonSubsequence(texEnds, ourEnds)) / Double(texEnds.count),
                                   limit: .atLeast(0.9)))
            if let a = firstBaseline(golden), let b = firstBaseline(file) {
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

    /// The last word of every line of text, in reading order: a line with a word of three letters or more (TeX's display
    /// formulas extract as glyph fragments — "∫∞", "k=1" — where TypesetKit draws them as paths with their TeX as
    /// `/ActualText`).
    private static func lineEnds(_ doc: PDFDocument) -> [String] {
        (0..<doc.pageCount).flatMap { i -> [String] in
            guard let page = doc.page(at: i), let all = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
            return all.selectionsByLine().compactMap { line -> String? in
                let w = words(line.string ?? "")
                return w.contains { $0.filter(\.isLetter).count >= 3 } ? w.last : nil
            }
        }
    }

    /// Page 1's first baseline, in TeX points from the top of the page: the highest text origin VectorKit's PDF reader
    /// finds (PDFKit's line bounds hang from each font's own bounding box, which differs between Tectonic's Type 1 and our
    /// OpenType Latin Modern).
    private static func firstBaseline(_ url: URL) -> Double? {
        guard let page = (try? PDFReader.read(url))?.document.pages.first else { return nil }
        func origins(_ nodes: [VectorNode], _ t: VectorTransform) -> [Double] {
            nodes.flatMap { node -> [Double] in
                switch node {
                case .text(let run): [t.b * run.origin.x + t.d * run.origin.y + t.ty]
                case .group(let children, let g, _, _):
                    origins(children, VectorTransform(a: g.a * t.a + g.b * t.c, b: g.a * t.b + g.b * t.d, c: g.c * t.a + g.d * t.c, d: g.c * t.b + g.d * t.d,
                                                      tx: g.tx * t.a + g.ty * t.c + t.tx, ty: g.tx * t.b + g.ty * t.d + t.ty))
                default: []
                }
            }
        }
        return origins(page.nodes, .identity).max().map { (page.size.height - $0) * 72.27 / 72 }
    }
}

/// The golden side of LaTeX parity: DocKit writes the fixture's LaTeX and the developer machine's Tectonic compiles it
/// (quality §9: a test tool, run here and never shipped), with network so its package cache fills on first use.
@MainActor
private enum Tectonic {
    static func compile(_ fixture: URL, to golden: URL, work: URL) async throws {
        guard let tool = HelperCatalog.info(.tectonic).detection.map(URL.init(fileURLWithPath:))
            .first(where: { $0.lastPathComponent == "tectonic" && FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CheckFailure("Tectonic is not installed (brew install tectonic)")
        }
        let run = await Pipeline.convertSteps(fixture, steps: [Step(.markdownReader, "md", .docModel), Step(.latexWriter, .docModel, "tex")], target: "tex", into: work)
        guard case .converted(let result) = run.outcome, let tex = result.outputs.first else { throw CheckFailure("DocKit did not write the LaTeX: \(run.outcome)") }
        let compiled = Subprocess.run(tool, ["-X", "compile", "--untrusted", "--outdir", work.path, tex.path], currentDirectory: work, timeout: 600)
        let pdf = tex.deletingPathExtension().appendingPathExtension("pdf")
        guard compiled.status == 0, FileManager.default.fileExists(atPath: pdf.path) else {
            throw CheckFailure("Tectonic failed: \(compiled.standardError?.suffix(400) ?? "")")
        }
        let version = Subprocess.run(tool, ["--version"]).standardOutput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let folder = golden.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: golden)
        try FileManager.default.copyItem(at: pdf, to: golden)
        try (version + "\n").write(to: folder.appendingPathComponent("tectonic.txt"), atomically: true, encoding: .utf8)
    }
}
