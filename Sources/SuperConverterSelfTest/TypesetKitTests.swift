import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SuperConverterCore
import TypesetKit

// TypesetKit's checks (WP-T): the bundled fonts and their licences, LaTeX's page geometry read back from the PDF,
// golden renders of sample documents (PDF and PNG) that pass the typographic lint (quality §3.7) with a consistent
// baseline grid, embedded fonts, faithful text extraction, bookmarks and tags, and the converter through its contract.
//
// Renders go to $SUPERCONVERTER_TYPESET_RENDERS when set (to look at them), else to the throwaway scratch folder.
func registerTypesetKitTests() {
    SelfTest.cases.append(("TypesetKit.fonts", { typesetFonts() }))
    SelfTest.cases.append(("TypesetKit.geometry", { typesetGeometry() }))
    SelfTest.cases.append(("TypesetKit.lineBreaking", { typesetLineBreaking() }))
    SelfTest.cases.append(("TypesetKit.hyphenation", { typesetHyphenation() }))
    SelfTest.cases.append(("TypesetKit.prose", { typesetGolden("prose", TypesetSamples.prose) }))
    SelfTest.cases.append(("TypesetKit.math", { typesetGolden("math", TypesetSamples.math) }))
    SelfTest.cases.append(("TypesetKit.tables", { typesetTables() }))
    SelfTest.cases.append(("TypesetKit.longDocument", { typesetLongDocument() }))
    SelfTest.cases.append(("TypesetKit.looks", { typesetLooks() }))
    SelfTest.cases.append(("TypesetKit.workbook", { typesetWorkbook() }))
    SelfTest.cases.append(("TypesetKit.publication", { typesetPublication() }))
    SelfTest.cases.append(("TypesetKit.converter", { typesetConverter() }))
    SelfTest.cases.append(("TypesetKit.routesCovered", { typesetRoutesCovered() }))
}

private let typesetRenders: URL = {
    let url = ProcessInfo.processInfo.environment["SUPERCONVERTER_TYPESET_RENDERS"].map { URL(fileURLWithPath: $0) }
        ?? scratch.appendingPathComponent("typeset")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

private func fontLibrary() -> FontLibrary? {
    let library = FontLibrary.bundled()
    check(library != nil, "the bundled fonts are found (Resources/Fonts)")
    return library
}

private func letter(_ o: TypesetOptions = TypesetOptions()) -> TypesetOptions {
    var o = o
    if o.paper == "auto" { o.paper = "letter" }
    return o
}

// MARK: - Tables

/// Booktabs tables, and a table too wide even at \footnotesize on landscape pages of its own (quality §3.2).
private func typesetTables() {
    guard typesetGolden("tables", TypesetSamples.tables, minPages: 3) != nil,
          let pdf = CGPDFDocument(typesetRenders.appendingPathComponent("tables.pdf") as CFURL) else { return }
    let boxes = (1...pdf.numberOfPages).compactMap { pdf.page(at: $0)?.getBoxRect(.mediaBox) }
    let landscape = boxes.indices.filter { boxes[$0].width > boxes[$0].height }
    check(landscape.count >= 2, "the wide table takes landscape pages (\(landscape.count) of \(boxes.count))")
    check(landscape.first.map { $0 > 0 } == true && landscape == Array(landscape[0]...landscape[landscape.count - 1]),
          "the sideways pages follow the portrait text page, together")
    if let i = landscape.first, let text = pdf.page(at: i + 1).flatMap({ PDFDocument(url: typesetRenders.appendingPathComponent("tables.pdf"))?.page(at: $0.pageNumber - 1)?.string }) {
        check(text.contains("Station 1") && text.contains("Year"), "the landscape page holds the table with its header")
    }
    if landscape.count >= 2, let doc = PDFDocument(url: typesetRenders.appendingPathComponent("tables.pdf")),
       let second = doc.page(at: landscape[1])?.string {
        check(second.contains("Year") && !second.contains("Monthly mean"), "later landscape pages repeat the header, not the caption")
    }
}

// MARK: - Hyphenation

/// TeX's Liang patterns give TeX's breaks (quality §3.3): the classic words from The TeXbook and hyph-utf8's tests.
private func typesetHyphenation() {
    func hyphenated(_ word: String, _ language: String) -> String {
        guard let h = Hyphenator(language: language) else { check(false, "\(language) hyphenates"); return word }
        var out = "", last = 0
        let units = Array(word.utf16)
        for p in h.points(in: word) { out += String(utf16CodeUnits: Array(units[last..<p]), count: p - last) + "-"; last = p }
        return out + String(utf16CodeUnits: Array(units[last...]), count: units.count - last)
    }
    for (word, expected) in [("hyphenation", "hy-phen-ation"), ("typesetting", "type-set-ting"), ("mathematics", "math-e-mat-ics"),
                             ("paragraph", "para-graph"), ("associate", "as-so-ciate"), ("Knuth", "Knuth"), ("table", "ta-ble"), ("cat", "cat"),
                             ("NASA", "NASA"), ("abc123def", "abc123def")] {
        check(hyphenated(word, "en_US") == expected, "en: \(word) → \(hyphenated(word, "en_US")) (TeX: \(expected))")
    }
    check(Hyphenator(language: "en_US")?.usesTeXPatterns == true && Hyphenator(language: "de-DE")?.usesTeXPatterns == true,
          "English and German use TeX's patterns")
    check(hyphenated("Silbentrennung", "de_DE") == "Sil-ben-tren-nung", "de: \(hyphenated("Silbentrennung", "de_DE"))")
    check(hyphenated("Silbentrennung", "de_DE") != "Silbentrennung" && hyphenated("anticonstitutionnellement", "fr_FR").contains("-"),
          "German and French words break")
    if let it = Hyphenator(language: "it_IT") { check(!it.usesTeXPatterns, "Italian (LPPL patterns) falls back to Apple's dictionary") }
}

// MARK: - Fonts and licences

private func typesetFonts() {
    guard let library = fontLibrary() else { return }
    let dir = library.directory
    for (folder, licence) in [("LatinModern", "GUST-FONT-LICENSE.txt"), ("LatinModernMath", "GUST-FONT-LICENSE.txt"),
                              ("CMU", "OFL.txt"), ("STIXTwo", "OFL.txt"), ("Carlito", "OFL.txt"), ("Caladea", "LICENSE-2.0.txt")] {
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(folder)/\(licence)").path), "\(folder) ships its licence")
    }
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
        .filter { ["otf", "ttf"].contains($0.pathExtension) }
    check(files.count >= 60, "Latin Modern optical sizes, Latin Modern Math, CMU, STIX Two Math, Carlito and Caladea are bundled (\(files.count) files)")
    for file in files {
        check(!(CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor] ?? []).isEmpty, "\(file.lastPathComponent) opens")
    }
    let manifest = (try? String(contentsOf: dir.appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
    check(manifest.contains("GUST Font License") && manifest.contains("SIL Open Font License"), "Resources/Fonts/README.md lists the licences")
    for file in files where !manifest.contains(file.lastPathComponent) {
        check(false, "\(file.lastPathComponent) is in the manifest")
    }
}

// MARK: - Geometry (quality §3.2)

/// The first line's left edge and baseline on Letter and A4 paper, read back from the PDF, are LaTeX's: article.cls
/// with `\@settopoint` gives a 134.27 pt (Letter) or 125.27 pt (A4) left margin and the text block's top at 125.27 pt
/// or 126.27 pt; the first baseline is `\topskip` (10 pt) below it.
private func typesetGeometry() {
    guard let library = fontLibrary() else { return }
    let doc = DocModel(blocks: [.paragraph([.text("Typesetting.")], DocParagraphStyle(alignment: .justified))])
    for (paper, left, top, size) in [("letter", 134.27, 125.27, CGSize(width: 612, height: 792)), ("a4", 125.27, 126.27, CGSize(width: 595.28, height: 841.89))] {
        var o = TypesetOptions()
        o.paper = paper
        let url = typesetRenders.appendingPathComponent("geometry-\(paper).pdf")
        guard (try? Typesetter(fonts: library).typeset(doc, options: o, to: url)) != nil, let page = PDFDocument(url: url)?.page(at: 0),
              let cg = CGPDFDocument(url as CFURL)?.page(at: 1) else { check(false, "geometry \(paper) renders"); continue }
        let bounds = page.bounds(for: .mediaBox)
        check(abs(bounds.width - size.width) < 0.1 && abs(bounds.height - size.height) < 0.1, "\(paper) paper is \(bounds.size)")
        guard let origin = firstTextOrigin(cg) else { check(false, "\(paper): text found"); continue }
        // The paragraph is indented by \parindent (15 pt).
        let x = Double(origin.x) * 72.27 / 72 - 15, baseline = (Double(bounds.height) - Double(origin.y)) * 72.27 / 72
        check(abs(x - left) < 0.05, "\(paper): text block starts \(String(format: "%.2f", x)) pt from the left (LaTeX \(left))")
        check(abs(baseline - (top + 10)) < 0.05, "\(paper): first baseline \(String(format: "%.2f", baseline)) pt from the top (LaTeX \(top + 10))")
    }
}

/// The text matrix of the first text drawn on a page (its origin in PDF units).
private func firstTextOrigin(_ page: CGPDFPage) -> CGPoint? {
    final class State { var origin: CGPoint?; var tm = CGAffineTransform.identity }
    let state = State()
    guard let table = CGPDFOperatorTableCreate() else { return nil }
    CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
        let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
        var v = [CGPDFReal](repeating: 0, count: 6)
        for i in (0..<6).reversed() { CGPDFScannerPopNumber(scanner, &v[i]) }
        s.tm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }
    for op in ["Tj", "TJ"] {
        CGPDFOperatorTableSetCallback(table, op) { _, info in
            let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            if s.origin == nil { s.origin = CGPoint(x: s.tm.tx, y: s.tm.ty) }
        }
    }
    let stream = CGPDFContentStreamCreateWithPage(page)
    let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
    CGPDFScannerScan(scanner)
    return state.origin
}

// MARK: - Line breaking

/// Knuth–Plass against TeX's own choices: the sample's third paragraph breaks where pdfLaTeX (lmodern, microtype)
/// breaks it, which a first-fit breaker does not.
private func typesetLineBreaking() {
    guard let library = fontLibrary() else { return }
    let doc = DocModel(blocks: [TypesetSamples.prose.blocks[3]])
    guard let r = try? Typesetter(fonts: library).typeset(doc, options: letter(), to: typesetRenders.appendingPathComponent("knuth-plass.pdf")) else {
        check(false, "the paragraph typesets"); return
    }
    let ends = r.log.lines.map { $0.text.split(separator: " ").last.map(String.init) ?? "" }
    check(ends == ["grows", "break", "The", "then", "in", "footnote", "the", "Silbentrennung."],
          "line ends match pdfLaTeX's: \(ends)")
    check(r.log.lines.allSatisfy { $0.badness <= 100 }, "the first pass (\\pretolerance 100) suffices")
}

// MARK: - Golden renders

@discardableResult
private func typesetGolden(_ name: String, _ doc: DocModel, options: TypesetOptions = TypesetOptions(), minPages: Int = 1) -> TypesetResult? {
    guard let library = fontLibrary() else { return nil }
    let url = typesetRenders.appendingPathComponent("\(name).pdf")
    let (typeset, seconds) = threadCPUSeconds { try? Typesetter(fonts: library).typeset(doc, options: letter(options), to: url) }
    guard let result = typeset else { check(false, "\(name) typesets"); return nil }
    check(seconds < 20 * budgetScale, "\(name) typesets in \(String(format: "%.1f", seconds)) s")
    check(result.pageCount >= minPages, "\(name): \(result.pageCount) page(s)")
    let lint = TypographicLint.check(result.log)
    check(lint.isEmpty, "\(name) passes the typographic lint: \(lint.prefix(4))")
    checkBaselineGrid(name, result.log, leading: options.baseSize == 11 ? 13.6 : options.baseSize == 12 ? 14.5 : 12)
    checkPDF(name, url, doc)
    renderPNG(url, name: name)
    return result
}

/// Consecutive lines of a paragraph sit exactly one \baselineskip apart.
private func checkBaselineGrid(_ name: String, _ log: TypesetLog, leading: Double) {
    var off = 0
    for (a, b) in zip(log.lines, log.lines.dropFirst())
    where a.paragraph >= 0 && a.paragraph == b.paragraph && a.page == b.page && a.column == b.column && !a.isHeading {
        let d = b.baseline - a.baseline
        if abs(d - leading) > 0.01 && d < leading + 0.5 { off += 1 }
    }
    check(off == 0, "\(name): lines of a paragraph are \(leading) pt apart (\(off) off the grid)")
}

/// All fonts embedded; the text extracts as written (ligatures and hyphens undone); bookmarks and tags present.
private func checkPDF(_ name: String, _ url: URL, _ doc: DocModel) {
    guard let pdf = PDFDocument(url: url) else { check(false, "\(name) PDF opens"); return }
    let problems = TypographicLint.check(pdf: url)
    check(problems.isEmpty, "\(name): fonts embedded and tagged (\(problems))")
    let extracted = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
        .precomposedStringWithCompatibilityMapping.replacingOccurrences(of: "-\n", with: "")
    let haystack = extracted.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    var missing: [String] = []
    for block in doc.blocks {
        guard case .paragraph(let text, _) = block else { continue }
        let words = plain(text).split(whereSeparator: \.isWhitespace).prefix(10).joined(separator: " ")
        let probe = words.replacingOccurrences(of: "---", with: "—").replacingOccurrences(of: "--", with: "–")
        if !probe.isEmpty && !probe.contains("$") && !probe.contains("\"") && !haystack.contains(probe) { missing.append(String(probe.prefix(50))) }
    }
    check(missing.isEmpty, "\(name): text extracts as written (missing \(missing.prefix(2)))")
    if doc.blocks.contains(where: { if case .heading = $0 { return true }; return false }) {
        check((pdf.outlineRoot?.numberOfChildren ?? 0) > 0, "\(name): bookmarks from headings")
    }
}

private func plain(_ t: DocText) -> String {
    var s = ""
    for n in t {
        switch n {
        case .text(let x): s += x
        case .emphasis(let i), .strong(let i), .strike(let i), .link(let i, _), .styled(let i, _): s += plain(i)
        case .code(let c): s += c
        case .math: s += "$"
        default: break
        }
    }
    return s
}

/// Page images at 110 dpi next to the PDF (the PNG golden renders).
private func renderPNG(_ pdf: URL, name: String, dpi: Double = 110) {
    guard let doc = CGPDFDocument(pdf as CFURL) else { return }
    for i in 1...doc.numberOfPages {
        guard let page = doc.page(at: i) else { continue }
        let box = page.getBoxRect(.mediaBox)
        let scale = dpi / 72
        guard let ctx = CGContext(data: nil, width: Int(box.width * scale), height: Int(box.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        let url = pdf.deletingLastPathComponent().appendingPathComponent("\(name)-\(i).png")
        guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { continue }
        CGImageDestinationAddImage(dest, image, nil)
        check(CGImageDestinationFinalize(dest), "\(name) page \(i) renders to PNG")
    }
}

// MARK: - Long documents, looks, other models

/// Many pages: page breaks with widow and club control, footnotes on the right pages, floats, contents and numbering.
private func typesetLongDocument() {
    let prose = TypesetSamples.prose.blocks.filter { if case .paragraph = $0 { return true }; return false }
    var blocks: [DocBlock] = []
    for s in 1...6 {
        blocks.append(head(1, "Section number \(s)"))
        for k in 0..<prose.count {
            blocks.append(prose[(k + s) % prose.count])
            if k == 2 { blocks.append(head(2, "A subsection of section \(s)")) }
        }
        blocks.append(TypesetSamples.tables.blocks[4])
    }
    blocks += TypesetSamples.prose.blocks.filter { if case .footnote = $0 { return true }; return false }
    var o = TypesetOptions()
    o.contents = true
    let doc = DocModel(metadata: DocMetadata(title: "A Longer Document", authors: ["A. N. Author"]), blocks: blocks)
    guard let r = typesetGolden("long", doc, options: o, minPages: 6) else { return }
    check(r.log.headings.contains("1 Section number 1") && r.log.headings.contains("6.1 A subsection of section 6"),
          "sections are numbered (\(r.log.headings.prefix(3)))")
}

private func typesetLooks() {
    var sans = TypesetOptions()
    sans.font = "latinModernSans"
    sans.baseSize = 11
    typesetGolden("prose-sans-11pt", TypesetSamples.prose, options: sans)
    var two = TypesetOptions()
    two.columns = 2
    typesetGolden("prose-twocolumn", TypesetSamples.prose, options: two)
    // "As written": the document's own fonts, Calibri set in its metric twin Carlito.
    var asWritten = TypesetOptions()
    asWritten.look = .asWritten
    var doc = TypesetSamples.prose
    doc.blocks = doc.blocks.map { b in
        if case .paragraph(let t, var s) = b { s.fontName = "Calibri"; s.fontSize = 11; s.alignment = .start; return .paragraph(t, s) }
        return b
    }
    guard let library = fontLibrary(),
          let r = try? Typesetter(fonts: library).typeset(doc, options: letter(asWritten), to: typesetRenders.appendingPathComponent("prose-as-written.pdf"))
    else { check(false, "the As written look typesets"); return }
    check(!r.lossNotes.contains { $0.kind == .fontsReplaced }, "Calibri is matched by Carlito, not replaced: \(r.lossNotes)")
    check(TypographicLint.check(r.log).isEmpty, "the As written look passes the lint")
    renderPNG(typesetRenders.appendingPathComponent("prose-as-written.pdf"), name: "prose-as-written")
}

private func typesetWorkbook() {
    guard let library = fontLibrary() else { return }
    let url = typesetRenders.appendingPathComponent("workbook.pdf")
    var o = TypesetOptions()
    o.paper = "a4"
    guard let r = try? Typesetter(fonts: library).typeset(TypesetSamples.workbook, options: o, to: url) else {
        check(false, "the workbook typesets"); return
    }
    check(r.pageCount == 1, "a small sheet fits on one page")
    let text = PDFDocument(url: url)?.page(at: 0)?.string ?? ""
    check(text.contains("1204.5") && text.contains("Region"), "sheet values appear as displayed")
    renderPNG(url, name: "workbook")
}

private func typesetPublication() {
    guard let library = fontLibrary() else { return }
    let prose = TypesetSamples.prose.blocks.filter { if case .paragraph = $0 { return true }; return false }
    let chapters = ["First", "Second", "Third"].enumerated().map { n, word in
        PublicationItem(id: "c\(n)", title: "Chapter \(n + 1)", content: .document(DocModel(blocks: [head(1, "The \(word) Chapter")] + prose)))
    }
    let pub = Publication(metadata: DocMetadata(title: "A Small Book", authors: ["Anonymous"]), spine: chapters)
    let url = typesetRenders.appendingPathComponent("book.pdf")
    guard let r = try? Typesetter(fonts: library).typeset(pub, options: TypesetOptions(), to: url) else {
        check(false, "the publication typesets"); return
    }
    check(r.pageCount >= 5, "a three-chapter book has a title page and chapters on new pages (\(r.pageCount) pages)")
    check(TypographicLint.check(r.log).isEmpty, "the book passes the lint: \(TypographicLint.check(r.log).prefix(3))")
    if let page = PDFDocument(url: url)?.page(at: 0) {
        check(abs(page.bounds(for: .mediaBox).width - 419.53) < 0.5, "e-books default to A5")
    }
    renderPNG(url, name: "book")
}

@MainActor
private func typesetConverter() {
    installFakes()
    TypesetKitModule.install()
    guard let converter = Services.converters.converter(for: .typesetKit) else { check(false, "TypesetKit registers its converter"); return }
    check(converter.availability() == .available, "the converter is available with the bundled fonts")
    let step = Step(.typesetKit, .docModel, "pdf")
    check(converter.handles(step), "the converter handles DocModel → PDF")
    let folder = scratch.appendingPathComponent("typeset-job")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let context = StepContext(workFolder: folder, source: URL(fileURLWithPath: "/tmp/Notes.md"), sourceFormat: "md", targetFormat: "pdf",
                              options: OptionValues(["paper": "a4"]), look: .latex, isFinalStep: true)
    let outcome = complete { try await converter.run(step, input: .doc(TypesetSamples.prose), context: context) }
    if case .success(let output)? = outcome, case .file(let url) = output.value {
        check(url.lastPathComponent == "Notes.pdf" && FileManager.default.fileExists(atPath: url.path), "the converter writes Notes.pdf in the work folder")
    } else {
        check(false, "the converter runs: \(String(describing: outcome))")
    }
}

/// Every TypesetKit step in the format matrix (DocModel, Workbook and Publication → PDF, from DocKit's, OfficeKit's
/// and EbookKit's readers) is handled by the converter TypesetKit registers.
@MainActor private func typesetRoutesCovered() {
    installFakes()
    TypesetKitModule.install()
    var steps = 0
    var inputs: Set<StepEndpoint> = []
    for route in FormatMatrix.routes {
        for chain in [route.builtin, route.helper].compactMap({ $0 }) + route.alternates.map(\.steps) {
            for step in chain where step.engine == .typesetKit {
                steps += 1
                inputs.insert(step.from)
                let handled = Services.converters.converter(for: .typesetKit)?.handles(step) == true
                check(handled, "TypesetKit handles \(step) in \(route.from) → \(route.to)")
            }
        }
    }
    check(inputs == [.model(.docModel), .model(.workbook), .model(.publication)], "TypesetKit's inputs: \(inputs)")
    check(steps >= 100, "matrix steps checked: \(steps)")
}

// MARK: - Sample documents

// Built as DocModels so the cases need no reader. `md` reads a small inline syntax: *emphasis*, **strong**, `code`,
// $math$, [^id] footnote references and [text](url) links.
private func md(_ s: String) -> DocText {
    var out: DocText = []
    var text = ""
    let chars = Array(s)
    var i = 0
    func flush() { if !text.isEmpty { out.append(.text(text)); text = "" } }
    func find(_ end: String, from start: Int) -> Int? {
        let e = Array(end)
        var j = start
        while j + e.count <= chars.count {
            if Array(chars[j..<j + e.count]) == e { return j }
            j += 1
        }
        return nil
    }
    while i < chars.count {
        let c = chars[i]
        if c == "*" && i + 1 < chars.count && chars[i + 1] == "*", let j = find("**", from: i + 2) {
            flush(); out.append(.strong(md(String(chars[(i + 2)..<j])))); i = j + 2; continue
        }
        if c == "*", let j = find("*", from: i + 1) {
            flush(); out.append(.emphasis(md(String(chars[(i + 1)..<j])))); i = j + 1; continue
        }
        if c == "`", let j = find("`", from: i + 1) {
            flush(); out.append(.code(String(chars[(i + 1)..<j]))); i = j + 1; continue
        }
        if c == "$", let j = find("$", from: i + 1) {
            flush(); out.append(.math(tex: String(chars[(i + 1)..<j]))); i = j + 1; continue
        }
        if c == "[" && i + 1 < chars.count && chars[i + 1] == "^", let j = find("]", from: i + 2) {
            flush(); out.append(.footnoteReference(id: String(chars[(i + 2)..<j]))); i = j + 1; continue
        }
        if c == "[", let j = find("](", from: i + 1), let k = find(")", from: j + 2) {
            flush(); out.append(.link(md(String(chars[(i + 1)..<j])), destination: String(chars[(j + 2)..<k]))); i = k + 1; continue
        }
        text.append(c)
        i += 1
    }
    flush()
    return out
}

private func para(_ s: String) -> DocBlock { .paragraph(md(s), DocParagraphStyle(alignment: .justified)) }
private func head(_ level: Int, _ s: String) -> DocBlock { .heading(level: level, md(s)) }
private func cell(_ s: String, header: Bool = false) -> DocTable.Cell { DocTable.Cell(blocks: [para(s)], isHeader: header) }

private enum TypesetSamples {
    static let prose = DocModel(
        metadata: DocMetadata(title: "On the Art of Breaking Paragraphs into Lines", authors: ["Ada Lovelace", "Charles Babbage"],
                              date: ISO8601DateFormatter().date(from: "2026-10-22T12:00:00Z")),
        blocks: [
            head(1, "Introduction"),
            para("The problem of dividing a paragraph into lines of approximately equal length is one of the oldest in typography. A compositor setting type by hand would look ahead a line or two, adjusting the spaces between words so that the right margin came out straight, and occasionally breaking a word with a hyphen when no better choice presented itself. Good compositors were prized precisely because they could do this without leaving rivers of white space running down the page or crowding the words of one line while the next stood loosely apart."),
            para("Mechanical composition did not change the essential difficulty, and early computer programs made it worse. They filled each line as full as possible before moving on to the next, a method that is fast and simple but frequently produces a poor line late in the paragraph that could have been avoided by a slightly different decision several lines earlier. The remedy, first described by Knuth and Plass in 1981, is to consider the paragraph as a whole: every feasible sequence of breakpoints is evaluated, and the one whose lines are, in total, the least unpleasant is chosen.[^history]"),
            para("To make “least unpleasant” precise, each line is assigned a *badness* that grows with the cube of the amount its spaces must stretch or shrink, and each break is assigned a *penalty* that discourages hyphens, especially two in a row. The sum of squared badness and penalty over all lines, called the *demerits*, is then minimised by a dynamic program whose running time is essentially linear in the length of the paragraph. The method is general enough to handle footnote marks, mathematics such as $e^{i\\pi} + 1 = 0$, and words in other languages, e.g. the German *Silbentrennung*."),
            head(2, "Spaces and their elasticity"),
            para("Interword spaces in a justified paragraph are not fixed. In the Computer Modern fonts a normal space is one third of an em, it may stretch by half of that and shrink by a third. After a sentence-ending period the space is a little wider, a convention TeX calls `\\nonfrenchspacing`; but no extra space follows an abbreviation like “Dr.” or the initials in “D. E. Knuth”. These rules are small, yet together they give a page its even colour."),
            para("Ligatures such as fi, fl, ff, ffi and ffl join letters that would otherwise collide, and kerning adjusts the space between pairs like “AV”, “To” and “Wa”. Punctuation at the end of a line is allowed to hang slightly into the margin, so that the edge looks straight to the eye rather than to the ruler---a refinement known as *protrusion*."),
            head(1, "Hyphenation"),
            para("When a paragraph cannot be set well without breaking a word, the line breaker considers the hyphenation points of each word. Long words such as *incomprehensibilities*, *characteristically* and *internationalization* offer many choices; short words and words containing digits are never broken. Consecutive hyphenated lines are discouraged, as is a hyphen on the penultimate line of a paragraph."),
            head(1, "Lists"),
            para("Lists in LaTeX are set with generous space around them and between their items:"),
            .list(ordered: false, start: 1, items: [
                [para("The first item states a fact plainly.")],
                [para("The second item is a little longer, so that it wraps onto a second line and shows how the text of an item hangs under its first word rather than under the label.")],
                [para("The third item closes the list.")],
            ]),
            para("Numbered lists work the same way, and nest:"),
            .list(ordered: true, start: 1, items: [
                [para("Choose the breakpoints.")],
                [para("Set the glue of each line."), .list(ordered: true, start: 1, items: [[para("Stretch or shrink every space by the same ratio.")], [para("Let punctuation protrude into the margin.")]])],
                [para("Build the pages.")],
            ]),
            head(1, "Quotations and code"),
            para("A quotation is indented on both sides:"),
            .quote([para("Typography exists to honour content. Like oratory, music, dance, calligraphy---like anything that lends its grace to language---typography is an art that can be deliberately misused.")]),
            para("Program text is set in a monospaced face with its spaces kept exactly:"),
            .code(language: "swift", text: "func badness(_ t: Double, _ s: Double) -> Int {\n    if t == 0 { return 0 }\n    guard s > 0 else { return 10000 }\n    let r = t / s\n    return min(10000, Int(100 * r * r * r))\n}"),
            para("And that concludes the demonstration of the paragraph builder, the page builder and the fonts.[^fonts]"),
            .footnote(id: "history", [para("D. E. Knuth and M. F. Plass, “Breaking paragraphs into lines”, *Software---Practice and Experience* 11 (1981), 1119--1184.")]),
            .footnote(id: "fonts", [para("The fonts are Latin Modern, the OpenType descendants of Knuth’s Computer Modern, distributed under the GUST Font License.")]),
        ])

    static let math = DocModel(
        metadata: DocMetadata(title: "A Few Formulas"),
        blocks: [
            head(1, "Inline and display mathematics"),
            para("The quadratic formula gives the roots of $ax^2 + bx + c = 0$ as"),
            .math(tex: "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}.", display: true),
            para("Euler’s identity $e^{i\\pi} + 1 = 0$ relates five constants, while the Gaussian integral"),
            .math(tex: "\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}", display: true),
            para("is the reason the normal distribution has the constant $1/\\sqrt{2\\pi}$ in front. Sums and products take limits above and below in display style:"),
            .math(tex: "\\sum_{k=1}^{n} k^2 = \\frac{n(n+1)(2n+1)}{6}, \\qquad \\prod_{p \\text{ prime}} \\frac{1}{1 - p^{-s}} = \\zeta(s).", display: true),
            para("Delimiters grow to fit what they enclose, and matrices are set in parentheses:"),
            .math(tex: "\\left( \\sum_{i=1}^{n} a_i b_i \\right)^2 \\le \\left( \\sum_{i=1}^{n} a_i^2 \\right) \\left( \\sum_{i=1}^{n} b_i^2 \\right), \\qquad A = \\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}.", display: true),
            para("Piecewise definitions use `cases`, and aligned equations line up on their relations:"),
            .math(tex: "|x| = \\begin{cases} x & \\text{if } x \\ge 0, \\\\ -x & \\text{otherwise,} \\end{cases}", display: true),
            .math(tex: "\\begin{aligned} (a+b)^2 &= a^2 + 2ab + b^2 \\\\ &\\ge 4ab. \\end{aligned}", display: true),
            para("Accents, primes and Greek letters: $\\hat{x}$, $\\bar{y}$, $\\vec{v}$, $f'(x)$, $\\alpha$, $\\beta$, $\\Gamma(n) = (n-1)!$ and $\\lim_{n \\to \\infty} (1 + 1/n)^n = e$. A continued fraction:"),
            .math(tex: "\\phi = 1 + \\cfrac{1}{1 + \\cfrac{1}{1 + \\cfrac{1}{1 + \\dotsb}}}", display: true),
            para("Binomial coefficients $\\binom{n}{k}$, roots $\\sqrt[3]{x}$, sets $\\{ x \\in \\mathbb{R} : x^2 < 2 \\}$ and calligraphic $\\mathcal{L}$ round out the test."),
        ])

    static let tables = DocModel(
        blocks: [
            head(1, "Tables"),
            para("Booktabs tables use three horizontal rules and no vertical ones. Numbers line up on their decimal points, as in Table 1, and the caption sits above the table."),
            .table(DocTable(rows: [
                [cell("Font", header: true), cell("Design size", header: true), cell("Space (pt)", header: true), cell("Stretch (pt)", header: true)],
                [cell("LM Roman 10"), cell("10"), cell("3.33"), cell("1.67")],
                [cell("LM Roman 12"), cell("12"), cell("3.26"), cell("1.63")],
                [cell("LM Roman 17"), cell("17.28"), cell("3.18"), cell("1.59")],
                [cell("LM Mono 10"), cell("10"), cell("5.25"), cell("0")],
            ], caption: md("Interword spacing of some Latin Modern fonts"), alignments: [.start, .end, .end, .end])),
            para("A table without a caption stays in the text, and a wider one wraps its text columns to the measure:"),
            .table(DocTable(rows: [
                [cell("Term", header: true), cell("Meaning", header: true)],
                [cell("Badness"), cell("A measure of how far the spaces of a line are stretched or shrunk from their natural width, roughly one hundred times the cube of the ratio.")],
                [cell("Penalty"), cell("The cost of breaking at a particular place, such as after a hyphen or before a display.")],
                [cell("Demerits"), cell("The quantity the line breaker minimises over the whole paragraph.")],
            ], alignments: [.start, .start])),
            para("Tables of many rows break across pages and repeat their header. Table 2 is too wide for the text block even in footnote size, so it turns sideways onto pages of its own while the text goes on."),
            .table(wideTable),
            para("The text continues after the sideways table."),
        ])

    /// Fourteen columns of figures over forty rows: wider than 345 pt at \footnotesize, narrower than 550 pt, taller
    /// than one landscape page.
    static let wideTable: DocTable = {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec", "Year"]
        var rows: [[DocTable.Cell]] = [[cell("Station", header: true)] + months.map { cell($0, header: true) }]
        for r in 1...40 {
            var row = [cell("Station \(r)")]
            for c in 1...13 {
                let value = Double((r * 37) % 97 + (c * 13) % 31) / 3
                row.append(cell(String(format: "%.1f", value)))
            }
            rows.append(row)
        }
        return DocTable(rows: rows, caption: md("Monthly mean temperatures (°C) at forty stations"),
                        alignments: [.start] + Array(repeating: .end, count: 13))
    }()

    static let workbook = Workbook(sheets: [
        Sheet(name: "Results", rows: [
            [Cell(value: .text("Region")), Cell(value: .text("Q1")), Cell(value: .text("Q2")), Cell(value: .text("Q3")), Cell(value: .text("Q4"))],
            [Cell(value: .text("North")), Cell(value: .number(1204.5)), Cell(value: .number(1310.25)), Cell(value: .number(998)), Cell(value: .number(1500.75))],
            [Cell(value: .text("South")), Cell(value: .number(845)), Cell(value: .number(902.4)), Cell(value: .number(1101.1)), Cell(value: .number(1012))],
            [Cell(value: .text("East")), Cell(value: .number(1500)), Cell(value: .number(1423.75)), Cell(value: .number(1388.2)), Cell(value: .number(1620.5))],
        ]),
    ], title: "Quarterly results")
}
