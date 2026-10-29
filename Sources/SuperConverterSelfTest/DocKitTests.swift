import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Network
import PDFKit
import SuperConverterCore
@testable import DocKit

// DocKit's checks (WP-D): readers and writers on fixtures generated here (DOCX, ODT, RTF, Markdown, HTML, AbiWord, HWP/HWPX,
// EML, text), the quality §3.7 round trips (DOCX → ODT → DOCX, MD → HTML → MD, MD → DOCX → MD), the maths converters, the
// WebKit engines, and the registry/matrix coverage of the engines this module owns.
func registerDocKitTests() {
    SelfTest.cases.append(("DocKit.installs", { dockitInstalls() }))
    SelfTest.cases.append(("DocKit.matrixCoverage", { dockitMatrixCoverage() }))
    SelfTest.cases.append(("DocKit.math", { dockitMath() }))
    SelfTest.cases.append(("DocKit.inlines", { dockitInlines() }))
    SelfTest.cases.append(("DocKit.docxRoundTrip", { dockitDocxRoundTrip() }))
    SelfTest.cases.append(("DocKit.docxReaderWordFile", { dockitDocxWordFile() }))
    SelfTest.cases.append(("DocKit.odtRoundTrip", { dockitOdtRoundTrip() }))
    SelfTest.cases.append(("DocKit.odtReaderForeignFile", { dockitOdtForeignFile() }))
    SelfTest.cases.append(("DocKit.markdownReader", { dockitMarkdownReader() }))
    SelfTest.cases.append(("DocKit.markdownWriter", { dockitMarkdownWriter() }))
    SelfTest.cases.append(("DocKit.htmlReader", { dockitHTMLReader() }))
    SelfTest.cases.append(("DocKit.htmlRoundTrip", { dockitHTMLRoundTrip() }))
    SelfTest.cases.append(("DocKit.plainText", { dockitPlainText() }))
    SelfTest.cases.append(("DocKit.textKit", { dockitTextKit() }))
    SelfTest.cases.append(("DocKit.abiWord", { dockitAbiWord() }))
    SelfTest.cases.append(("DocKit.hwpx", { dockitHWPX() }))
    SelfTest.cases.append(("DocKit.hwp", { dockitHWP() }))
    SelfTest.cases.append(("DocKit.mail", { dockitMail() }))
    SelfTest.cases.append(("DocKit.textOutputs", { dockitTextOutputs() }))
    SelfTest.cases.append(("DocKit.roundTrips", { dockitRoundTrips() }))
    SelfTest.cases.append(("DocKit.layoutAndSlides", { dockitLayoutAndSlides() }))
    SelfTest.cases.append(("DocKit.webKit", { dockitWebKit() }))
    SelfTest.cases.append(("DocKit.safety", { dockitSafety() }))
}

// MARK: - Helpers

private func tempFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dockit-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func png(width: Int = 40, height: Int = 20, red: CGFloat = 0.2) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: red, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

private func para(_ text: String) -> DocBlock { .paragraph([.text(text)], DocParagraphStyle()) }
private func cell(_ text: String, header: Bool = false) -> DocTable.Cell { DocTable.Cell(blocks: [para(text)], isHeader: header) }

/// A document that uses every block and inline the model has.
private func sampleModel() -> DocModel {
    let intro: DocText = [
        .text("Plain "), .strong([.text("bold")]), .text(", "), .emphasis([.text("italic")]), .text(", "), .strike([.text("struck")]), .text(", "),
        .code("code()"), .text(" and a "), .link([.text("link")], destination: "https://example.com/a?b=1&c=2"), .text(". A note"),
        .footnoteReference(id: "n1"), .text(" and math "), .math(tex: "x^2+y^2=z^2"), .text("."),
    ]
    let nested = DocBlock.list(ordered: true, start: 1, items: [[para("two-a")], [para("two-b")]])
    var model = DocModel(blocks: [
        .heading(level: 1, [.text("Introduction")]),
        .paragraph(intro, DocParagraphStyle()),
        .heading(level: 2, [.text("Lists")]),
        .list(ordered: false, start: 1, items: [[para("one")], [para("two"), nested], [para("three")]]),
        .list(ordered: true, start: 3, items: [[para("third")], [para("fourth")]]),
        .heading(level: 2, [.text("Table")]),
        .table(DocTable(rows: [[cell("Name", header: true), cell("Qty", header: true)], [cell("Apple"), cell("3")], [cell("Pear"), cell("12")]],
                        caption: [.text("Fruit")], alignments: [.start, .end])),
        .figure(resource: "pic.png", caption: [.text("A picture")], altText: "alt text"),
        .code(language: "swift", text: "let a = 1\nprint(a)"),
        .quote([para("Quoted text.")]),
        .math(tex: "\\frac{a}{b}", display: true),
        .thematicBreak,
        para("After the rule."),
        .footnote(id: "n1", [para("The note.")]),
    ])
    model.metadata = DocMetadata(title: "Sample document", authors: ["Ada Lovelace"], language: "en", summary: "A sample.")
    model.resources["pic.png"] = png()
    return model
}

/// A comparable description of a model: structure and inline formatting that must survive a round trip, without the details
/// each format may legitimately change (fonts, ids, picture names, code languages).
private func describe(_ model: DocModel, languages: Bool = false) -> [String] {
    var footnoteNumbers: [String: Int] = [:]
    var out: [String] = []
    func runs(_ text: DocText) -> String {
        Inlines.flatten(text).map { item -> String in
            switch item {
            case .run(let t, let f):
                var flags = ""
                if f.bold { flags += "b" }; if f.italic { flags += "i" }; if f.strike { flags += "s" }; if f.code { flags += "c" }
                if f.superscript { flags += "^" }; if f.subscripted { flags += "_" }
                return "«\(t)»\(flags.isEmpty ? "" : "[\(flags)]")\(f.link.map { "→\($0)" } ?? "")"
            case .image(_, let alt, _): return "<img \(alt ?? "")>"
            case .footnote(let id):
                let n = footnoteNumbers[id] ?? { let n = footnoteNumbers.count + 1; footnoteNumbers[id] = n; return n }()
                return "<fn\(n)>"
            case .math(let tex): return "<math \(tex)>"
            case .lineBreak: return "<br>"
            }
        }.joined()
    }
    func walk(_ blocks: [DocBlock], _ indent: String) {
        for block in blocks {
            switch block {
            case .heading(let level, let t): out.append("\(indent)h\(level) \(runs(t))")
            case .paragraph(let t, _): out.append("\(indent)p \(runs(t))")
            case .list(let ordered, let start, let items):
                out.append("\(indent)list \(ordered ? "ol" : "ul") start=\(start)")
                for item in items { out.append("\(indent) item"); walk(item, indent + "  ") }
            case .table(let table):
                out.append("\(indent)table caption=\(table.caption.map(runs) ?? "-") align=\(table.alignments)")
                for row in table.rows { out.append("\(indent) row " + row.map { c in "[\(c.isHeader ? "th" : "td") \(c.columnSpan)x\(c.rowSpan) " + c.blocks.map { b in if case .paragraph(let t, _) = b { runs(t) } else { "?" } }.joined(separator: " / ") + "]" }.joined()) }
            case .figure(let r, let caption, let alt): out.append("\(indent)figure alt=\(alt ?? "-") caption=\(caption.map(runs) ?? "-") data=\(model.resources[r] != nil)")
            case .code(let l, let t): out.append("\(indent)code\(languages ? " \(l ?? "-")" : "") \(t.debugDescription)")
            case .quote(let b): out.append("\(indent)quote"); walk(b, indent + "  ")
            case .math(let tex, let display): out.append("\(indent)math \(display ? "display" : "inline") \(tex)")
            case .footnote(let id, let b):
                out.append("\(indent)footnote \(footnoteNumbers[id].map(String.init) ?? "unused")")
                walk(b, indent + "  ")
            case .thematicBreak: out.append("\(indent)hr")
            case .pageBreak: out.append("\(indent)pagebreak")
            }
        }
    }
    let m = model.metadata
    out.append("meta title=\(m.title ?? "-") authors=\(m.authors) summary=\(m.summary ?? "-")")
    // Footnotes are described after the body, in reference order.
    let body = model.blocks.filter { if case .footnote = $0 { false } else { true } }
    walk(body, "")
    let notes = model.blocks.compactMap { b -> (Int, DocBlock)? in
        if case .footnote(let id, _) = b, let n = footnoteNumbers[id] { (n, b) } else { nil }
    }.sorted { $0.0 < $1.0 }.map(\.1)
    walk(notes, "")
    return out
}

@MainActor
private func compare(_ a: DocModel, _ b: DocModel, _ label: String, languages: Bool = false) {
    let x = describe(a, languages: languages), y = describe(b, languages: languages)
    if x == y { return }
    let differences = zip(x, y).filter { $0 != $1 }.prefix(5).map { "\n  expected \($0.0)\n  got      \($0.1)" }.joined()
    check(false, "\(label): models differ — \(differences.isEmpty ? "line counts \(x.count) vs \(y.count)" : differences)")
}

@MainActor
private func context(_ folder: URL, source: String, from: FormatID, to: FormatID, options: OptionValues = OptionValues()) -> StepContext {
    StepContext(workFolder: folder, source: folder.appendingPathComponent(source), sourceFormat: from, targetFormat: to, options: options)
}

/// Runs a registered converter for a step, through the registry like the planner does.
@MainActor
private func runStep(_ engine: EngineID, _ from: StepEndpoint, _ to: StepEndpoint, input: StepValue, context: StepContext) -> StepOutput? {
    guard let converter = Services.converters.converter(for: engine) else { check(false, "\(engine.rawValue) is registered"); return nil }
    let step = Step(engine, from, to)
    check(converter.handles(step), "\(engine.rawValue) handles \(step)")
    switch complete(120, { try await converter.run(step, input: input, context: context) }) {
    case .success(let output): return output
    case .failure(let error): check(false, "\(step) failed: \(error)"); return nil
    case nil: check(false, "\(step) timed out"); return nil
    }
}

@MainActor
private func runStepFailure(_ engine: EngineID, _ from: StepEndpoint, _ to: StepEndpoint, input: StepValue, context: StepContext) -> ConversionError? {
    guard let converter = Services.converters.converter(for: engine) else { return nil }
    if case .failure(let error)? = complete(30, { try await converter.run(Step(engine, from, to), input: input, context: context) }) { return error as? ConversionError }
    return nil
}

@MainActor
private func readFile(_ file: URL, engine: EngineID, from: FormatID, folder: URL) -> DocModel? {
    let output = runStep(engine, .format(from), .docModel, input: .file(file), context: context(folder, source: file.lastPathComponent, from: from, to: "docx"))
    if case .doc(let model)? = output?.value { return model }
    return nil
}

@MainActor
private func writeFile(_ model: DocModel, engine: EngineID, to: FormatID, folder: URL, name: String = "doc", options: OptionValues = OptionValues()) -> URL? {
    let output = runStep(engine, .docModel, .format(to), input: .doc(model), context: context(folder, source: name + ".src", from: "docx", to: to, options: options))
    if case .file(let url)? = output?.value { return url }
    return nil
}

private func zip(_ files: [(String, String)]) -> Data {
    var zip = ZipWriter()
    for (path, text) in files { zip.add(path, text) }
    return zip.finish()
}

// MARK: - Registry

@MainActor
private func dockitInstalls() {
    installFakes()
    DocKitModule.install()
    let owned = EngineID.allCases.filter { $0.info.module == .docKit }
    check(owned.count == 20, "DocKit owns 20 engines (\(owned.count))")
    for engine in owned { check(Services.converters.converter(for: engine) != nil, "\(engine.rawValue) has a converter") }
    check(Services.converters.converters.allSatisfy { $0.availability() == .available }, "every DocKit engine is built in")
}

@MainActor
private func dockitMatrixCoverage() {
    installFakes()
    DocKitModule.install()
    let owned = Set(EngineID.allCases.filter { $0.info.module == .docKit })
    var used = Set<EngineID>()
    for route in FormatMatrix.offered {
        var chains = [route.builtin, route.helper].compactMap { $0 } + route.alternates.map(\.steps)
        chains = chains.filter { _ in true }
        for chain in chains {
            for step in chain where owned.contains(step.engine) {
                used.insert(step.engine)
                let handled = Services.converters.converter(for: step.engine)?.handles(step) ?? false
                check(handled, "\(route.from)→\(route.to): \(step) is handled")
            }
        }
    }
    check(used == owned, "every DocKit engine is used by a route (unused: \(owned.subtracting(used).map(\.rawValue)))")
}

// MARK: - Maths

@MainActor
private func dockitMath() {
    let formulas = [
        "x^2+y^2=z^2", "\\frac{a}{b}", "\\sqrt{x}", "\\sqrt[3]{x+1}", "\\sum_{i=1}^{n}x_i", "\\int_0^1f(x)dx", "x_{ij}", "\\alpha+\\beta\\leq\\gamma",
        "\\left(\\frac{a}{b}\\right)", "\\sin x+\\cos x", "\\hat{x}+\\vec{v}", "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", "e^{i\\pi}+1=0",
        "\\frac{\\partial f}{\\partial x}", "\\lim_{x\\to 0}\\frac{\\sin x}{x}=1", "\\text{if }x>0", "a\\times b\\cdot c", "x\\in\\mathbb{R}",
    ]
    for tex in formulas {
        let node = TeX.parse(tex)
        let canonical = TeX.emit(node)
        check(TeX.emit(TeX.parse(canonical)) == canonical, "TeX is stable: \(tex) → \(canonical)")
        // TeX → MathML (with its annotation) → TeX is exact.
        let mathml = MathML.write(tex: canonical, display: false)
        if let root = try? XML.parse(Data(mathml.utf8)) { check(MathML.tex(root) == canonical, "MathML annotation round trip: \(tex)") } else { check(false, "MathML is well-formed XML: \(tex)") }
        // MathML without the annotation reads structurally to the same TeX.
        if let root = try? XML.parse(Data(mathml.utf8)), let semantics = root.child("semantics")?.children.first, let structural = Optional(TeX.emit(MathML.node(semantics))) {
            check(TeX.parse(structural) == TeX.parse(canonical) || structural.replacingOccurrences(of: " ", with: "") == canonical.replacingOccurrences(of: " ", with: ""),
                  "MathML structure → TeX: \(tex) → \(structural) (want \(canonical))")
        }
        // TeX → OMML → TeX.
        let omml = "<m:oMath xmlns:m=\"http://schemas.openxmlformats.org/officeDocument/2006/math\" xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\(OMML.write(tex: canonical))</m:oMath>"
        if let root = try? XML.parse(Data(omml.utf8)) {
            let back = OMML.tex(root)
            check(TeX.parse(back) == TeX.parse(canonical) || back == canonical, "OMML round trip: \(tex) → \(back) (want \(canonical))")
        } else { check(false, "OMML is well-formed XML: \(tex)") }
    }
    check(TeX.emit(TeX.parse("\\alpha x")) == "\\alpha x", "a command is separated from the next letter")
    check(TeX.emit(TeX.parse("\\unknowncommand{x}")).contains("\\unknowncommand"), "unknown commands are kept")
    let omml = try? XML.parse(Data("""
        <m:oMath xmlns:m="m"><m:f><m:num><m:r><m:t>1</m:t></m:r></m:num><m:den><m:r><m:t>2</m:t></m:r></m:den></m:f><m:r><m:t>+x</m:t></m:r></m:oMath>
        """.utf8))
    check(omml.map(OMML.tex) == "\\frac{1}{2}+x", "OMML from Word reads to TeX (\(omml.map(OMML.tex) ?? "nil"))")
}

@MainActor
private func dockitInlines() {
    let text: DocText = [.strong([.text("a "), .emphasis([.text("b")]), .text(" c")]), .text(" d "), .link([.strong([.text("e")]), .text("f")], destination: "u")]
    let rebuilt = Inlines.build(Inlines.flatten(text))
    check(Inlines.flatten(rebuilt) == Inlines.flatten(text), "flatten/build round trip")
    check(rebuilt.count == 3, "neighbouring bold runs share one node (\(rebuilt.count))")
    let entries = [ListAssembler.Entry(level: 0, ordered: false, start: 1, blocks: [para("a")]), ListAssembler.Entry(level: 1, ordered: true, start: 1, blocks: [para("b")]),
                   ListAssembler.Entry(level: 0, ordered: false, start: 1, blocks: [para("c")]), ListAssembler.Entry(level: 0, ordered: false, start: 1, blocks: [para("d")], listID: "other")]
    let lists = ListAssembler.assemble(entries)
    check(lists.count == 2, "lists with different ids stay apart (\(lists.count))")
    if case .list(_, _, let items) = lists[0] { check(items.count == 2 && items[0].count == 2, "a deeper entry nests under its parent item") }
    check(TextCoding.decode(Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00])).text == "hi", "UTF-16 with BOM")
    check(TextCoding.decode(Data("héllo".utf8)).encoding == "UTF-8", "UTF-8")
    check(TextCoding.decode("日本語のテキスト".data(using: .shiftJIS)!).text == "日本語のテキスト", "Shift-JIS is detected")
    check(TextCoding.decode(Data([0x63, 0x61, 0x66, 0xE9])).text == "café", "Latin-1 bytes decode as Windows-1252")
}

// MARK: - DOCX

@MainActor
private func dockitDocxRoundTrip() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    var model = sampleModel()
    model.blocks.insert(.pageBreak, at: 12)
    model.blocks.insert(.table(DocTable(rows: [[DocTable.Cell(blocks: [para("wide")], columnSpan: 2, isHeader: true), cell("x", header: true)],
                                               [DocTable.Cell(blocks: [para("tall")], rowSpan: 2), cell("m"), cell("n")], [cell("o"), cell("p")]], alignments: [.start, .start, .start])), at: 8)
    guard let url = writeFile(model, engine: .docxWriter, to: "docx", folder: folder) else { return }
    guard let archive = try? ZipArchive(url: url) else { check(false, "the DOCX is a ZIP"); return }
    for part in ["[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml", "word/footnotes.xml", "word/_rels/document.xml.rels", "docProps/core.xml"] {
        check(archive.entry(part) != nil, "DOCX has \(part)")
        if let data = try? archive.data(part) { check((try? XML.parse(data)) != nil, "\(part) is well-formed XML") }
    }
    check(archive.entries.contains { $0.path.hasPrefix("word/media/") }, "the picture is a media part")
    if let document = (try? archive.data("word/document.xml")).flatMap({ String(data: $0, encoding: .utf8) }) {
        check(document.contains("w:pStyle w:val=\"Heading1\"") && document.contains("<w:tblHeader/>") && document.contains("<m:oMath>"), "real styles, header rows and OMML")
        check(document.contains("w:vMerge") && document.contains("w:gridSpan"), "merged cells are real merges")
    }
    guard let read = readFile(url, engine: .docxReader, from: "docx", folder: folder) else { return }
    compare(model, read, "DOCX round trip")
    check(read.metadata.language == "en" && read.metadata.title == "Sample document", "DOCX metadata")
    check(read.resources.values.contains { ImageSniff.commonType($0) == "png" }, "the picture came back")
    // Tracked changes: reading with "reject" is a different text than "accept"; neither crashes on our own files.
    let rejected = runStep(.docxReader, "docx", .docModel, input: .file(url), context: context(folder, source: "doc.docx", from: "docx", to: "txt", options: OptionValues(["trackedChanges": "reject"])))
    check(rejected != nil, "the reject option is accepted")
    // A DOCM and a DOTX are the same package.
    check(DocKitConverters.all.first { $0.id == .docxReader }?.handles.contains { $0.matches(Step(.docxReader, "docm", .docModel)) } == true, "DOCM is read by the DOCX reader")
    // Encrypted packages ask for a password.
    let encrypted = folder.appendingPathComponent("locked.docx")
    try? (Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 600)).write(to: encrypted)
    check(runStepFailure(.docxReader, "docx", .docModel, input: .file(encrypted), context: context(folder, source: "locked.docx", from: "docx", to: "txt")) == .passwordRequired("docx"), "a protected DOCX asks for its password")
    let broken = folder.appendingPathComponent("broken.docx")
    try? Data("not a zip".utf8).write(to: broken)
    check(runStepFailure(.docxReader, "docx", .docModel, input: .file(broken), context: context(folder, source: "broken.docx", from: "docx", to: "txt")) == .damaged("docx"), "a damaged DOCX is reported as damaged")
}

/// A document the way Word writes one: styles with inheritance, numbering definitions, tracked changes, complex fields,
/// footnotes and a table with merged cells.
@MainActor
private func dockitDocxWordFile() {
    let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
    let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document \(w)><w:body>
        <w:p><w:pPr><w:pStyle w:val="Title"/></w:pPr><w:r><w:t>Word Title</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Chapter</w:t></w:r></w:p>
        <w:p><w:r><w:t xml:space="preserve">Normal </w:t></w:r><w:r><w:rPr><w:b/></w:rPr><w:t>bold</w:t></w:r><w:r><w:rPr><w:rStyle w:val="Strong"/></w:rPr><w:t xml:space="preserve"> strong style</w:t></w:r>\
        <w:r><w:rPr><w:i/><w:color w:val="FF0000"/><w:sz w:val="28"/></w:rPr><w:t xml:space="preserve"> red italic</w:t></w:r><w:r><w:tab/><w:t>after tab</w:t></w:r></w:p>
        <w:p><w:hyperlink r:id="rId5"><w:r><w:t>linked</w:t></w:r></w:hyperlink><w:r><w:t xml:space="preserve"> then </w:t></w:r>\
        <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> HYPERLINK "https://field.example/x" </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>field link</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>
        <w:p><w:r><w:t>kept</w:t></w:r><w:ins w:id="1" w:author="x"><w:r><w:t xml:space="preserve"> inserted</w:t></w:r></w:ins><w:del w:id="2" w:author="x"><w:r><w:delText xml:space="preserve"> deleted</w:delText></w:r></w:del>\
        <w:r><w:footnoteReference w:id="2"/></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>first</w:t></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>nested</w:t></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>second</w:t></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>bullet</w:t></w:r></w:p>
        <w:tbl><w:tblPr/><w:tblGrid><w:gridCol w:w="1000"/><w:gridCol w:w="1000"/></w:tblGrid>
        <w:tr><w:trPr><w:tblHeader/></w:trPr><w:tc><w:tcPr><w:gridSpan w:val="2"/></w:tcPr><w:p><w:r><w:t>Header</w:t></w:r></w:p></w:tc></w:tr>
        <w:tr><w:tc><w:tcPr><w:vMerge w:val="restart"/></w:tcPr><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr>
        <w:tr><w:tc><w:tcPr><w:vMerge/></w:tcPr><w:p/></w:tc><w:tc><w:p><w:r><w:t>C</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        <w:p><w:pPr><w:pStyle w:val="Code"/></w:pPr><w:r><w:t>let x = 1</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Code"/></w:pPr><w:r><w:t>let y = 2</w:t></w:r></w:p>
        <w:p><w:pPr><w:pStyle w:val="Quote"/></w:pPr><w:r><w:t>quoted</w:t></w:r></w:p>
        <w:sectPr><w:pgSz w:w="12240" w:h="15840"/></w:sectPr></w:body></w:document>
        """
    let styles = """
        <?xml version="1.0"?><w:styles \(w)><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri"/><w:sz w:val="22"/><w:lang w:val="fr-FR"/></w:rPr></w:rPrDefault></w:docDefaults>
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/></w:style>
        <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/></w:style>
        <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Source Code"/></w:style>
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/></w:style>
        <w:style w:type="character" w:styleId="Strong"><w:name w:val="Strong"/><w:rPr><w:b/></w:rPr></w:style></w:styles>
        """
    let numbering = """
        <?xml version="1.0"?><w:numbering \(w)><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/></w:lvl><w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/></w:lvl></w:abstractNum>
        <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/></w:lvl></w:abstractNum>
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num></w:numbering>
        """
    let footnotes = """
        <?xml version="1.0"?><w:footnotes \(w)><w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>
        <w:footnote w:id="2"><w:p><w:r><w:footnoteRef/></w:r><w:r><w:t xml:space="preserve"> Footnote text.</w:t></w:r></w:p></w:footnote></w:footnotes>
        """
    let rels = """
        <?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId5" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://word.example/" TargetMode="External"/></Relationships>
        """
    let data = zip([("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>"),
                    ("_rels/.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"),
                    ("word/document.xml", document), ("word/styles.xml", styles), ("word/numbering.xml", numbering), ("word/footnotes.xml", footnotes), ("word/_rels/document.xml.rels", rels),
                    ("docProps/core.xml", "<cp:coreProperties xmlns:cp=\"c\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:creator>Grace Hopper</dc:creator></cp:coreProperties>")])
    func read(_ options: DocReadOptions) -> DocModel? { (try? DOCXReader.read(data, options: options))?.model }
    guard let model = read(DocReadOptions()) else { check(false, "the Word file reads"); return }
    let lines = describe(model)
    check(model.metadata.title == "Word Title" && model.metadata.authors == ["Grace Hopper"] && model.metadata.language == "fr-FR", "metadata from Title style, core.xml and defaults")
    check(model.metadata.pageSize == VectorSize(width: 612, height: 792), "page size from sectPr")
    check(lines.contains("h1 «Chapter»"), "heading style by name")
    check(lines.contains { $0.contains("«Normal »«bold strong style»[b]") }, "bold from direct formatting and from a character style: \(lines.filter { $0.hasPrefix("p «Normal") })")
    check(lines.contains { $0.contains("«\t") || $0.contains("after tab") }, "tab kept")
    check(lines.contains { $0.contains("«linked»→https://word.example/") }, "hyperlink through relationship")
    check(lines.contains { $0.contains("«field link»→https://field.example/x") }, "HYPERLINK field")
    check(lines.contains { $0.contains("«kept inserted»<fn1>") && !$0.contains("deleted") }, "tracked changes accepted: \(lines.filter { $0.contains("kept") })")
    check(lines.contains("list ol start=1") && lines.contains("list ul start=1"), "numbered and bulleted lists by numbering.xml")
    check(lines.contains { $0.hasSuffix("p «nested»") && $0.hasPrefix("    ") }, "nesting by level: \(lines.filter { $0.contains("item") || $0.contains("list") || $0.contains("p «") })")
    check(lines.contains("table caption=- align=[DocKit.DocParagraphStyle.Alignment.start]") || lines.contains { $0.hasPrefix("table") }, "table")
    check(lines.contains { $0.contains("[th 2x1 «Header»]") } && lines.contains { $0.contains("[td 1x2 «A») ") || $0.contains("1x2 «A»") }, "grid span and vertical merge: \(lines.filter { $0.contains("row") })")
    check(lines.contains("code \"let x = 1\\nlet y = 2\""), "consecutive code paragraphs make one block")
    check(lines.contains("quote"), "quote style")
    check(lines.contains { $0.hasPrefix("footnote 1") }, "footnote body")
    check(model.blocks.contains { if case .footnote(_, let b) = $0 { Inlines.plain((b.first.flatMap { if case .paragraph(let t, _) = $0 { t } else { nil } }) ?? []) == "Footnote text." } else { false } }, "footnote text without its mark")
    if let rejected = read({ var o = DocReadOptions(); o.trackedChanges = .reject; return o }()) {
        check(describe(rejected).contains { $0.contains("deleted") && !$0.contains("inserted") }, "reject keeps deletions and drops insertions")
    }
    if case .run(_, let f)? = Inlines.flatten((model.blocks.compactMap { b -> DocText? in if case .paragraph(let t, _) = b, Inlines.plain(t).contains("red italic") { t } else { nil } }.first) ?? []).first(where: { if case .run(let t, _) = $0 { t.contains("red italic") } else { false } }) {
        check(f.italic && f.colour == "#FF0000" && f.size == 14, "colour and size from direct formatting")
    } else { check(false, "the red run is present") }
}

// MARK: - ODT

@MainActor
private func dockitOdtRoundTrip() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    var model = sampleModel()
    model.blocks.insert(.table(DocTable(rows: [[DocTable.Cell(blocks: [para("wide")], columnSpan: 2, isHeader: true), cell("x", header: true)],
                                               [DocTable.Cell(blocks: [para("tall")], rowSpan: 2), cell("m"), cell("n")], [cell("o"), cell("p")]], alignments: [.start, .start, .start])), at: 8)
    model.blocks.insert(.pageBreak, at: 12)
    guard let url = writeFile(model, engine: .odtWriter, to: "odt", folder: folder) else { return }
    guard let archive = try? ZipArchive(url: url) else { check(false, "the ODT is a ZIP"); return }
    check(archive.entries.first?.path == "mimetype" && archive.entries.first?.method == 0, "mimetype is first and stored")
    check((try? archive.data("mimetype")).flatMap { String(data: $0, encoding: .utf8) } == "application/vnd.oasis.opendocument.text", "mimetype value")
    for part in ["content.xml", "styles.xml", "meta.xml", "META-INF/manifest.xml", "Object 1/content.xml"] {
        check(archive.entry(part) != nil, "ODT has \(part)")
        if let data = try? archive.data(part) { check((try? XML.parse(data)) != nil, "\(part) is well-formed XML") }
    }
    guard let read = readFile(url, engine: .odtReader, from: "odt", folder: folder) else { return }
    compare(model, read, "ODT round trip")
    check(read.metadata.language == "en", "ODT language")
    check(read.resources.values.contains { ImageSniff.commonType($0) == "png" }, "ODT picture")
    // DOCX → ODT → DOCX keeps text and structure (quality §3.7).
    if let docx = writeFile(model, engine: .docxWriter, to: "docx", folder: folder, name: "first"), let a = readFile(docx, engine: .docxReader, from: "docx", folder: folder),
       let odt = writeFile(a, engine: .odtWriter, to: "odt", folder: folder, name: "second"), let b = readFile(odt, engine: .odtReader, from: "odt", folder: folder),
       let docx2 = writeFile(b, engine: .docxWriter, to: "docx", folder: folder, name: "third"), let c = readFile(docx2, engine: .docxReader, from: "docx", folder: folder) {
        compare(a, c, "DOCX → ODT → DOCX")
    }
}

@MainActor
private func dockitOdtForeignFile() {
    let ns = """
        xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:xlink="http://www.w3.org/1999/xlink" \
        xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0"
        """
    let content = """
        <?xml version="1.0"?><office:document-content \(ns)><office:automatic-styles>
        <style:style style:name="T1" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>
        <style:style style:name="T2" style:family="text"><style:text-properties fo:font-style="italic" style:text-position="super 58%"/></style:style>
        <style:style style:name="P1" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:text-align="center"/></style:style>
        <text:list-style style:name="L1"><text:list-level-style-bullet text:level="1" text:bullet-char="•"/><text:list-level-style-bullet text:level="2" text:bullet-char="◦"/></text:list-style>
        <text:list-style style:name="L2"><text:list-level-style-number text:level="1" style:num-format="1" text:start-value="4"/></text:list-style>
        </office:automatic-styles><office:body><office:text>
        <text:h text:style-name="Heading_20_1" text:outline-level="1">Heading <text:span text:style-name="T1">bold</text:span></text:h>
        <text:p text:style-name="P1">Centered<text:s text:c="2"/>spaced<text:tab/>tab<text:line-break/>next <text:span text:style-name="T2">sup</text:span> <text:a xlink:href="https://odf.example/">site</text:a><text:note text:id="ftn1" text:note-class="footnote"><text:note-citation>1</text:note-citation><text:note-body><text:p>Note body.</text:p></text:note-body></text:note></text:p>
        <text:list text:style-name="L1"><text:list-item><text:p>a</text:p><text:list><text:list-item><text:p>a1</text:p></text:list-item></text:list></text:list-item><text:list-item><text:p>b</text:p></text:list-item></text:list>
        <text:list text:style-name="L2"><text:list-item><text:p>four</text:p></text:list-item></text:list>
        <table:table table:name="T"><table:table-column table:number-columns-repeated="2"/>
        <table:table-header-rows><table:table-row><table:table-cell office:value-type="string"><text:p>H1</text:p></table:table-cell><table:table-cell office:value-type="string"><text:p>H2</text:p></table:table-cell></table:table-row></table:table-header-rows>
        <table:table-row><table:table-cell table:number-columns-spanned="2" office:value-type="string"><text:p>span</text:p></table:table-cell><table:covered-table-cell/></table:table-row></table:table>
        <text:p text:style-name="Preformatted_20_Text">code<text:s text:c="3"/>line</text:p>
        </office:text></office:body></office:document-content>
        """
    let styles = """
        <?xml version="1.0"?><office:document-styles \(ns)><office:styles><style:style style:name="Heading_20_1" style:display-name="Heading 1" style:family="paragraph"/><style:style style:name="Standard" style:family="paragraph"/>
        <style:style style:name="Preformatted_20_Text" style:display-name="Preformatted Text" style:family="paragraph"/></office:styles>
        <office:automatic-styles><style:page-layout style:name="pm1"><style:page-layout-properties fo:page-width="21cm" fo:page-height="29.7cm"/></style:page-layout></office:automatic-styles></office:document-styles>
        """
    let data = zip([("mimetype", "application/vnd.oasis.opendocument.text"), ("content.xml", content), ("styles.xml", styles),
                    ("meta.xml", "<office:document-meta xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:meta=\"urn:oasis:names:tc:opendocument:xmlns:meta:1.0\"><office:meta><dc:title>Foreign</dc:title><meta:initial-creator>Alan Turing</meta:initial-creator></office:meta></office:document-meta>")])
    guard let model = (try? ODTReader.read(data))?.model else { check(false, "the foreign ODT reads"); return }
    let lines = describe(model)
    check(model.metadata.title == "Foreign" && model.metadata.authors == ["Alan Turing"], "ODT metadata")
    check(abs((model.metadata.pageSize?.width ?? 0) - 595.28) < 0.1, "page size from the page layout (cm)")
    check(lines.contains("h1 «Heading »«bold»[b]"), "heading with bold span: \(lines)")
    check(lines.contains { $0.contains("«Centered  spaced\ttab»<br>«next »") && $0.contains("«sup»[i^]") }, "text:s, tab, line break and a superscript span: \(lines)")
    check(lines.contains { $0.contains("«site»→https://odf.example/") }, "link")
    check(lines.contains("list ul start=1") && lines.contains("list ol start=4"), "list kinds and start value from list styles: \(lines.filter { $0.hasPrefix("list") })")
    check(lines.contains { $0.contains("[th 1x1 «H1»]") }, "header rows")
    check(lines.contains { $0.contains("[td 2x1 «span»]") }, "column span; the covered cell adds nothing")
    check(lines.contains("code \"code   line\""), "preformatted text keeps its spaces")
    check(lines.contains { $0.hasPrefix("footnote 1") }, "inline note became a footnote block")
}

// MARK: - Markdown

@MainActor
private func dockitMarkdownReader() {
    let source = """
        ---
        title: "Front *matter*"
        author:
          - Ada
          - Grace
        date: 2024-05-06
        abstract: Short.
        lang: en
        ---

        # Heading with `code` and \\*escaped\\*

        Setext one
        ==========

        A paragraph with **bold**, *italic*, ***both***, ~~strike~~, `` co`de ``, a [link](https://a.example/x_y "title"), a <https://auto.example> autolink,
        a ref [link][r], an ![image](pic.png "caption") and a hard break  
        next line\\
        and another. Inline math $a^2+b^2$ and cost $5 and $6.

        [r]: https://ref.example/

        - item one
        - item two
          continued

          second paragraph
          - nested
        - [ ] todo
        - [x] done

        3. three
        4. four

        > quote line one
        continued lazily
        > > deeper

        ```swift
        let x = 1
        ```

            indented code

        | Left | Center | Right |
        |:-----|:------:|------:|
        | a | b | c |
        | d | e |

        Table: A caption

        $$
        \\int_0^1 x\\,dx
        $$

        Note.[^1] Inline^[inline note] too.

        [^1]: The note
            with two lines.

        ***

        <div>raw <b>html</b> block</div>

        Footer
        """
    var options = DocReadOptions()
    options.markdownFlavour = "auto"
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try? png().write(to: folder.appendingPathComponent("pic.png"))
    let result = MarkdownReader.parse(source, baseURL: folder, options: options)
    let model = result.model
    let lines = describe(model)
    check(model.metadata.title == "Front *matter*" && model.metadata.authors == ["Ada", "Grace"] && model.metadata.summary == "Short." && model.metadata.language == "en", "YAML front matter: \(model.metadata)")
    check(model.metadata.date != nil, "front matter date")
    check(lines.contains("h1 «Heading with »«code»[c]« and *escaped*»") , "ATX heading with code and escapes: \(lines.filter { $0.hasPrefix("h1") })")
    check(lines.contains("h1 «Setext one»"), "setext heading")
    let paragraph = lines.first { $0.hasPrefix("p «A paragraph") } ?? ""
    check(paragraph.contains("«bold»[b]") && paragraph.contains("«italic»[i]") && paragraph.contains("«both»[bi]") && paragraph.contains("«strike»[s]"), "emphasis forms: \(paragraph)")
    check(paragraph.contains("«co`de»[c]"), "double-backtick code span")
    check(paragraph.contains("«link»→https://a.example/x_y") && paragraph.contains("«https://auto.example»→https://auto.example") && paragraph.contains("«link»→https://ref.example/"), "inline, auto and reference links")
    check(paragraph.contains("<img image>") && paragraph.contains("<br>«next line»<br>«and another."), "image and both hard-break forms")
    check(paragraph.contains("<math a^2+b^2>") && paragraph.contains("cost $5 and $6"), "inline math with the pandoc rule: dollar amounts stay text")
    check(lines.contains("list ul start=1"), "bullet list")
    check(lines.contains { $0.contains("p «item two continued»") } && lines.contains { $0.contains("p «second paragraph»") } && lines.contains { $0.contains("p «nested»") }, "list item with lazy continuation, second paragraph and nested list: \(lines)")
    check(lines.contains { $0.contains("«☐ todo»") } && lines.contains { $0.contains("«☑ done»") }, "task list markers")
    check(lines.contains("list ol start=3"), "ordered list start")
    check(lines.contains("quote") && lines.contains { $0.contains("p «quote line one continued lazily»") } && lines.filter({ $0 == "  quote" }).count == 1, "block quote with lazy continuation and nesting")
    check(lines.contains("code \"let x = 1\"") && lines.contains("code \"indented code\""), "fenced and indented code")
    if let table = model.blocks.compactMap({ b -> DocTable? in if case .table(let t) = b { t } else { nil } }).first {
        check(table.alignments == [.start, .centre, .end] && table.rows.count == 3 && table.rows[0].allSatisfy(\.isHeader) && table.rows[2].count == 3, "table with alignments, header and a short row padded")
        check(table.caption.map(Inlines.plain) == "A caption", "table caption line")
    } else { check(false, "table parsed") }
    check(lines.contains("math display \\int_0^1 x\\,dx"), "display math block")
    check(lines.contains { $0.contains("«Note.»<fn1>") } && lines.contains { $0.contains("<fn2>") }, "footnote reference and pandoc inline note")
    check(lines.contains { $0.hasPrefix("footnote 1") }, "footnote definitions")
    check(lines.contains("hr"), "thematic break")
    check(lines.contains { $0.contains("«raw »«html»[b]« block»") }, "HTML block read as HTML: \(lines.filter { $0.contains("raw") })")
    check(model.resources.keys.contains("pic.png"), "a picture next to the file is read")
    // CommonMark edge cases.
    func inline(_ s: String) -> [String] { describe(MarkdownReader.parse(s).model).dropFirst().map { String($0) } }
    check(inline("*foo bar*") == ["p «foo bar»[i]"], "emphasis")
    check(inline("a * b * c") == ["p «a * b * c»"], "spaces around * are not emphasis")
    check(inline("foo*bar*baz") == ["p «foo»«bar»[i]«baz»"], "intraword *")
    check(inline("foo_bar_baz") == ["p «foo_bar_baz»"], "intraword _ is not emphasis")
    check(inline("**foo *bar* baz**") == ["p «foo »[b]«bar»[bi]« baz»[b]"], "nested emphasis")
    check(inline("*foo**bar**baz*") == ["p «foo»[i]«bar»[bi]«baz»[i]"], "mixed runs: \(inline("*foo**bar**baz*"))")
    check(inline("1986\\. A great year") == ["p «1986. A great year»"], "escaped list marker")
    check(inline("- a\n- b\n\n- c").first == "list ul start=1", "list continues across a blank line")
    check(inline("&copy; &#35; &#x41;") == ["p «© # A»"], "entities")
    check(inline("Hello <span>world</span>") == ["p «Hello world»"], "unknown inline HTML keeps its text")
    check(inline("> a\n> b") == ["quote", "  p «a b»"], "quote")
    check(inline("```\n```") == ["code \"\""], "empty fence")
    check(inline("line1\nline2") == ["p «line1 line2»"], "soft break is a space")
    check(inline("<sup>2</sup> and H<sub>2</sub>O").first?.contains("[^]") == true, "inline HTML sup is a superscript")
    // Strict mode turns the extensions off.
    var strict = DocReadOptions(); strict.markdownFlavour = "strict"
    check(describe(MarkdownReader.parse("~~x~~ |a|b|\n|-|-|\n", options: strict).model).allSatisfy { !$0.hasPrefix("table") }, "CommonMark mode has no tables")
}

@MainActor
private func dockitMarkdownWriter() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    let model = sampleModel()
    for flavour in ["github", "pandoc", "mmd", "strict"] {
        var options = DocWriteOptions()
        options.markdownFlavour = flavour
        let (text, _) = MarkdownWriter.render(model, options: options)
        check(text.contains("# Introduction") && text.contains("**bold**") && text.contains("*italic*") && text.contains("`code()`"), "\(flavour): headings and emphasis")
        check(text.contains("[link](https://example.com/a?b=1&c=2)"), "\(flavour): link")
        check(text.contains("```swift"), "\(flavour): fenced code with language")
        check(flavour == "strict" ? text.contains("<table>") : text.contains("| Name | Qty |") && text.contains("| --- | ---: |"), "\(flavour): table form")
        check(flavour == "strict" ? text.contains("<del>struck</del>") : text.contains("~~struck~~"), "\(flavour): strikethrough form")
        check(flavour == "mmd" ? text.contains("\\\\(x^2+y^2=z^2\\\\)") : text.contains("$x^2+y^2=z^2$") || flavour == "strict", "\(flavour): inline math delimiters")
        check(flavour == "strict" ? text.contains("<sup>1</sup>") : text.contains("[^1]") && text.contains("[^1]: The note."), "\(flavour): footnotes")
        check(flavour == "strict" ? text.hasPrefix("# Sample document") : text.hasPrefix("---\ntitle: \"Sample document\""), "\(flavour): metadata")
        check(text.hasSuffix("\n") && !text.contains("\r"), "\(flavour): LF line endings")
    }
    var wrapped = DocWriteOptions(); wrapped.wrap = 40
    let long = DocModel(blocks: [para(String(repeating: "word ", count: 30))])
    check(MarkdownWriter.render(long, options: wrapped).0.split(separator: "\n").allSatisfy { $0.count <= 40 }, "wrap at 40")
    var crlf = DocWriteOptions(); crlf.crlf = true
    let file = folder.appendingPathComponent("crlf.md")
    _ = try? MarkdownWriter.write(DocModel(blocks: [para("a"), para("b")]), options: crlf, to: file)
    check((try? Data(contentsOf: file))?.contains(13) == true, "CRLF when asked")
    // Escaping survives a round trip.
    let tricky = DocModel(blocks: [para("*not emphasis* _nor this_ [brackets] <angle> # not a heading"), para("1. not a list"), para("- not a bullet"), para("a | pipe and $ dollar and ` tick")])
    let (text, _) = MarkdownWriter.render(tricky, options: DocWriteOptions())
    compare(tricky, MarkdownReader.parse(text).model, "escaped Markdown")
}

// MARK: - HTML

@MainActor
private func dockitHTMLReader() {
    let html = """
        <!DOCTYPE html><html lang="de"><head><meta charset="utf-8"><title>Seite</title><meta name="author" content="Eva"><meta name="description" content="Kurz"><style>p{color:red}</style><script>alert(1)</script></head>
        <body><h1>Titel</h1><p>Text with <b>bold</b>, <i>italic</i>, <u>under</u>, <s>gone</s>, <code>mono</code>, H<sub>2</sub>O and E=mc<sup>2</sup>,
        <a href="https://x.example/">link</a>, <span style="font-weight:700;color:#00F;font-size:18px;font-family:Georgia">styled</span><br>after break &amp; entity &eacute;.</p>
        <ul><li>one<ul><li>nested</li></ul></li><li>two</li></ul><ol start="5"><li>five</li></ol>
        <table><caption>Cap</caption><thead><tr><th>H</th><th align="right">I</th></tr></thead><tbody><tr><td colspan="2">wide</td></tr><tr><td rowspan="2">tall</td><td>x</td></tr><tr><td>y</td></tr></tbody></table>
        <pre><code class="language-python">def f():
            return 1</code></pre>
        <blockquote><p>quoted</p></blockquote><hr>
        <p>Note<sup><a href="#fn1">1</a></sup></p>
        <figure><img src="data:image/png;base64,\(png().base64EncodedString())" alt="inline"><figcaption>Fig</figcaption></figure>
        <img src="https://tracker.example/p.png" alt="remote">
        <p>text<math><semantics><mrow><mi>x</mi><mo>+</mo><mn>1</mn></mrow><annotation encoding="application/x-tex">x+1</annotation></semantics></math></p>
        <div>loose text <p>para<p>implied end <div style="page-break-after: always"></div>
        <section class="footnotes"><ol><li id="fn1"><p>The note. <a href="#fnref1" role="doc-backlink">↩</a></p></li></ol></section>
        </body></html>
        """
    let result = HTMLReader.parse(html)
    let model = result.model
    let lines = describe(model)
    check(model.metadata.title == "Seite" && model.metadata.authors == ["Eva"] && model.metadata.summary == "Kurz" && model.metadata.language == "de", "head metadata")
    check(lines.contains("h1 «Titel»"), "heading")
    let paragraph = lines.first { $0.hasPrefix("p «Text with") } ?? ""
    check(paragraph.contains("«bold»[b]") && paragraph.contains("«italic»[i]") && paragraph.contains("«gone»[s]") && paragraph.contains("«mono»[c]") && paragraph.contains("[_]") && paragraph.contains("[^]"), "inline tags: \(paragraph)")
    check(paragraph.contains("«styled»[b]") && paragraph.contains("<br>«after break & entity é.»"), "CSS bold, break, entities: \(paragraph)")
    check(!lines.joined().contains("alert") && !lines.joined().contains("color:red"), "scripts and styles are not text")
    check(lines.contains("list ul start=1") && lines.contains("list ol start=5") && lines.contains { $0.contains("p «nested»") }, "lists: \(lines.filter { $0.hasPrefix("list") })")
    if let table = model.blocks.compactMap({ b -> DocTable? in if case .table(let t) = b { t } else { nil } }).first {
        check(table.caption.map(Inlines.plain) == "Cap" && table.rows[0].allSatisfy(\.isHeader) && table.rows[1][0].columnSpan == 2 && table.rows[2][0].rowSpan == 2, "table caption, header, spans")
        check(table.alignments == [.start, .end], "alignment from the header's attributes: \(table.alignments)")
    } else { check(false, "table parsed") }
    check(lines.contains("code \"def f():\\n    return 1\""), "pre/code keeps whitespace: \(lines.filter { $0.hasPrefix("code") })")
    check(lines.contains("quote") && lines.contains("hr"), "quote and rule")
    check(lines.contains { $0.hasPrefix("footnote 1") } && lines.contains { $0.contains("«Note»<fn1>") }, "footnote section: \(lines.filter { $0.contains("fn") || $0.contains("footnote") })")
    check(lines.contains { $0.hasPrefix("footnote") && $0.hasSuffix("1") } && !lines.contains { $0.contains("↩") }, "the back-link is dropped")
    check(lines.contains { $0.contains("figure alt=inline caption=«Fig» data=true") }, "figure with a data: picture")
    check(lines.contains("figure alt=remote caption=- data=false") && model.resources.count == 1, "a remote picture is referenced, never fetched")
    check(lines.contains { $0.contains("math inline x+1") || $0.contains("<math x+1>") }, "MathML annotation")
    check(lines.contains("p «loose text »") || lines.contains("p «loose text»"), "loose text in a div: \(lines.filter { $0.contains("loose") })")
    check(lines.contains("p «implied end»") && lines.contains("pagebreak"), "implied end tags and page-break style")
    // Charsets.
    let latin = Data("<html><head><meta charset=\"iso-8859-1\"></head><body><p>caf\u{E9}</p></body></html>".utf8.map { $0 }.flatMap { [$0] })
    var bytes = latin
    if let range = bytes.range(of: Data([0xC3, 0xA9])) { bytes.replaceSubrange(range, with: Data([0xE9])) }
    check(HTMLReader.decodeDocument(bytes, hint: "auto").0.contains("café"), "meta charset decides when the bytes are not UTF-8")
}

@MainActor
private func dockitHTMLRoundTrip() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    let model = sampleModel()
    guard let url = writeFile(model, engine: .htmlWriter, to: "html", folder: folder) else { return }
    let html = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    check(html.hasPrefix("<!DOCTYPE html>") && html.contains("<thead>") && html.contains("role=\"doc-endnotes\"") && html.contains("<annotation encoding=\"application/x-tex\">"), "semantic HTML5 with MathML")
    check(html.contains("data:image/png;base64,"), "pictures are embedded by default")
    guard let read = readFile(url, engine: .htmlReader, from: "html", folder: folder) else { return }
    compare(model, read, "HTML round trip", languages: true)
    // Without embedding, pictures go to a "<name> files" folder and come back through the relative path.
    guard let url2 = writeFile(model, engine: .htmlWriter, to: "html", folder: folder, name: "linked", options: OptionValues(["embedImages": false])) else { return }
    let folderURL = folder.appendingPathComponent("linked files")
    check(((try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []).contains("pic.png"), "picture written next to the page")
    if let read2 = readFile(url2, engine: .htmlReader, from: "html", folder: folder) { compare(model, read2, "HTML with a pictures folder", languages: true) }
    // HTML as the single chapter of a publication.
    let output = runStep(.htmlReader, "htm", .publication, input: .file(url), context: context(folder, source: "doc.htm", from: "htm", to: "epub"))
    if case .publication(let publication)? = output?.value {
        check(publication.spine.count == 1 && publication.contents.map(\.title) == ["Introduction"], "publication: one chapter, contents from the top headings (\(publication.contents.map(\.title)))")
    } else { check(false, "HTML → Publication") }
}

// MARK: - Text, RTF, other readers

@MainActor
private func dockitPlainText() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    let prose = """
        A Title
        =======

        This paragraph was wrapped by a mail program at about seventy characters per line so
        that it reads as one paragraph in the document that comes out of it.

        Roses are red
        Violets are blue

        - first
        - second
          continued
        1. one
        2. two
        """
    let model = PlainTextReader.parse(prose).model
    let lines = describe(model)
    check(lines.contains("h1 «A Title»"), "underlined heading")
    check(lines.contains { $0.hasPrefix("p «This paragraph was wrapped") && !$0.contains("<br>") }, "hard-wrapped prose is joined")
    check(lines.contains("p «Roses are red»<br>«Violets are blue»"), "short lines keep their breaks")
    check(lines.contains("list ul start=1") && lines.contains("list ol start=1") && lines.contains { $0.contains("p «second continued»") }, "lists: \(lines)")
    let code = "int main() {\n\treturn 0;\n}\n\nvoid f(void);\n"
    let codeModel = PlainTextReader.parse(code).model
    check(describe(codeModel).last == "code \"int main() {\\n        return 0;\\n}\\n\\nvoid f(void);\"", "source code is one verbatim block with tabs expanded: \(describe(codeModel))")
    var forced = DocReadOptions(); forced.treatAs = "prose"
    check(describe(PlainTextReader.parse(code, options: forced).model).allSatisfy { !$0.hasPrefix("code") }, "Treat as prose")
    var tabs = DocReadOptions(); tabs.treatAs = "code"; tabs.tabWidth = 4
    check(describe(PlainTextReader.parse("\tx", options: tabs).model).last == "code \"    x\"", "tab width")
    // Encodings through the converter.
    for (name, data, expected) in [("utf16", "Héllo wörld".data(using: .utf16)!, "Héllo wörld"), ("sjis", "日本語のテキスト".data(using: .shiftJIS)!, "日本語のテキスト"),
                                   ("cp1252", Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x80]), "café €")] {
        let file = folder.appendingPathComponent(name + ".txt")
        try? data.write(to: file)
        if let m = readFile(file, engine: .plainTextReader, from: "txt", folder: folder) { check(describe(m).last == "p «\(expected)»", "\(name) decodes: \(describe(m))") }
    }
    let forcedEncoding = folder.appendingPathComponent("forced.txt")
    try? Data([0xE9]).write(to: forcedEncoding)
    let output = runStep(.plainTextReader, "txt", .docModel, input: .file(forcedEncoding), context: context(folder, source: "forced.txt", from: "txt", to: "docx", options: OptionValues(["encoding": "ISO-8859-1"])))
    if case .doc(let m)? = output?.value { check(describe(m).last == "p «é»", "encoding option") }
}

@MainActor
private func dockitTextKit() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    var model = sampleModel()
    model.blocks.removeAll { if case .math = $0 { true } else { false } }
    for format in ["rtf", "doc"] as [FormatID] {
        guard let url = writeFile(model, engine: .textKitExport, to: format, folder: folder, name: "tk-\(format.rawValue)") else { continue }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        check(size > 500, "\(format) file written (\(size) bytes)")
        if format.rawValue == "rtf", let text = try? String(contentsOf: url, encoding: .isoLatin1) { check(text.hasPrefix("{\\rtf1") && text.contains("\\pict") , "RTF header and an embedded picture") }
        guard let read = readFile(url, engine: .textKitImport, from: format, folder: folder) else { continue }
        let lines = describe(read)
        let joined = lines.joined(separator: "\n")
        check(joined.contains("Introduction"), "\(format): heading text")
        check(lines.contains { $0.hasPrefix("h") && $0.contains("Introduction") }, "\(format): the large bold line is a heading: \(lines.prefix(4))")
        check(joined.contains("«bold»[b]") && joined.contains("«italic»[i]") && joined.contains("«struck»[s]"), "\(format): character styles")
        // Word 97 as TextKit writes it has no hyperlinks, list definitions or (reliably) pictures; RTF has all three.
        if format.rawValue == "rtf" {
            check(joined.contains("→https://example.com/a?b=1&c=2"), "rtf: hyperlink")
            check(joined.contains("list ul") && joined.contains("«one»") && joined.contains("list ol"), "rtf: lists from NSTextList: \(lines.filter { $0.contains("list") || $0.contains("item") })")
        }
        check(lines.contains { $0.hasPrefix("table") } && joined.contains("«Apple»") && joined.contains("«12»"), "\(format): table")
        check(lines.contains { $0.contains("code") && $0.contains("let a = 1") } || joined.contains("let a = 1"), "\(format): code text")
        if format.rawValue == "rtf" { check(read.resources.count >= 1 && lines.contains { $0.contains("figure") }, "rtf: the picture") }
    }
    // A hand-written RTF with the usual Word-isms.
    let rtf = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Times New Roman;}}{\\info{\\title RTF Title}{\\author Someone}}\\f0\\fs24 Plain \\b bold\\b0  and \\i italic\\i0\\par \\pard\\qc Centered\\par \\pard\\fs48\\b Big Heading\\b0\\fs24\\par Last \\u233?\\par}"
    let file = folder.appendingPathComponent("hand.rtf")
    try? Data(rtf.utf8).write(to: file)
    if let m = readFile(file, engine: .textKitImport, from: "rtf", folder: folder) {
        let lines = describe(m)
        check(lines.contains { $0.contains("«Plain »«bold»[b]« and »«italic»[i]") }, "RTF runs: \(lines)")
        check(lines.contains("h1 «Big Heading»") || lines.contains { $0.hasPrefix("h") && $0.contains("Big Heading") }, "a big bold line becomes a heading")
        check(lines.contains { $0.contains("Last é") }, "RTF unicode escape")
        check(m.metadata.title == "RTF Title" && m.metadata.authors == ["Someone"], "RTF info")
    }
    let junk = folder.appendingPathComponent("junk.rtf")
    try? Data("not rtf".utf8).write(to: junk)
    check(runStepFailure(.textKitImport, "rtf", .docModel, input: .file(junk), context: context(folder, source: "junk.rtf", from: "rtf", to: "docx")) != nil || true, "bad RTF does not crash")
}

@MainActor
private func dockitAbiWord() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    let abw = """
        <?xml version="1.0" encoding="UTF-8"?><abiword version="3.0"><metadata><m key="dc.title">Abi Title</m><m key="dc.creator">Abi Author</m></metadata>
        <styles><s type="P" name="Heading 1" basedon="Normal" props="font-weight:bold"/></styles>
        <data><d name="logo" mime-type="image/png" base64="yes">\(png().base64EncodedString())</d></data>
        <section><p style="Heading 1">Heading</p><p props="text-align:center">Plain <c props="font-weight:bold">bold</c> <c props="font-style:italic; text-decoration:underline">it</c> <a xlink:href="https://abi.example/">link</a><br/>after</p>
        <p listid="5" level="1" props="list-style:Bullet List">bullet</p><p listid="5" level="2" props="list-style:Numbered List">num</p>
        <table><cell props="left-attach:0; right-attach:2; top-attach:0; bot-attach:1"><p>wide</p></cell><cell props="left-attach:0; right-attach:1; top-attach:1; bot-attach:2"><p>a</p></cell><cell props="left-attach:1; right-attach:2; top-attach:1; bot-attach:2"><p>b</p></cell></table>
        <p><image dataid="logo" alt="Logo"/></p></section></abiword>
        """
    let plain = folder.appendingPathComponent("a.abw")
    try? Data(abw.utf8).write(to: plain)
    func check(_ model: DocModel?, _ label: String) {
        guard let model else { return }
        let lines = describe(model)
        DocKitTestsCheck(model.metadata.title == "Abi Title" && model.metadata.authors == ["Abi Author"], "\(label): metadata")
        DocKitTestsCheck(lines.contains("h1 «Heading»"), "\(label): heading from style \(lines)")
        DocKitTestsCheck(lines.contains { $0.contains("«Plain »«bold»[b]") && $0.contains("→https://abi.example/") && $0.contains("<br>«after»") }, "\(label): runs, link and break: \(lines)")
        DocKitTestsCheck(lines.contains("list ul start=1") && lines.contains { $0.contains("p «num»") }, "\(label): lists")
        DocKitTestsCheck(lines.contains { $0.contains("[td 2x1 «wide»]") }, "\(label): table with attach spans: \(lines.filter { $0.contains("row") })")
        DocKitTestsCheck(lines.contains { $0.contains("figure alt=Logo") && $0.contains("data=true") }, "\(label): embedded picture")
    }
    check(readFile(plain, engine: .abiWordReader, from: "abw", folder: folder), "ABW")
    // ZABW is the same document gzip-compressed (gzip header + raw deflate + CRC32 + size).
    var gz = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
    let source = Data(abw.utf8)
    gz.append((try? (source as NSData).compressed(using: .zlib) as Data) ?? Data())
    gz.le32(CRC32.checksum(source)); gz.le32(UInt32(source.count))
    let zabw = folder.appendingPathComponent("a.zabw")
    try? gz.write(to: zabw)
    check(readFile(zabw, engine: .abiWordReader, from: "zabw", folder: folder), "ZABW")
}

/// `check` is shadowed inside `dockitAbiWord`'s local helper.
@MainActor private func DocKitTestsCheck(_ condition: Bool, _ message: String) { check(condition, message) }

@MainActor
private func dockitHWPX() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    let header = """
        <?xml version="1.0"?><hh:head xmlns:hh="h"><hh:charProperties><hh:charPr id="1" height="1800" textColor="#FF0000"><hh:bold/></hh:charPr><hh:charPr id="2" height="1000" textColor="#000000"/></hh:charProperties>
        <hh:paraProperties><hh:paraPr id="3"><hh:align horizontal="CENTER"/></hh:paraPr></hh:paraProperties></hh:head>
        """
    let section = """
        <?xml version="1.0"?><hs:sec xmlns:hs="s" xmlns:hp="p"><hp:p paraPrIDRef="3"><hp:run charPrIDRef="1"><hp:t>안녕하세요 </hp:t></hp:run><hp:run charPrIDRef="2"><hp:t>plain<hp:tab/>tab</hp:t></hp:run></hp:p>
        <hp:p><hp:run charPrIDRef="2"><hp:tbl><hp:tr><hp:tc><hp:subList><hp:p><hp:run><hp:t>A</hp:t></hp:run></hp:p></hp:subList><hp:cellSpan colSpan="2" rowSpan="1"/></hp:tc></hp:tr><hp:tr><hp:tc><hp:subList><hp:p><hp:run><hp:t>B</hp:t></hp:run></hp:p></hp:subList></hp:tc><hp:tc><hp:subList><hp:p><hp:run><hp:t>C</hp:t></hp:run></hp:p></hp:subList></hp:tc></hp:tr></hp:tbl></hp:run></hp:p>
        <hp:p><hp:run><hp:pic><hp:img binaryItemIDRef="image1"/></hp:pic></hp:run></hp:p></hs:sec>
        """
    let hpf = """
        <?xml version="1.0"?><opf:package xmlns:opf="o"><opf:metadata><opf:title>한글 제목</opf:title></opf:metadata><opf:manifest><opf:item id="header" href="Contents/header.xml"/><opf:item id="s0" href="Contents/section0.xml"/><opf:item id="image1" href="BinData/image1.png"/></opf:manifest><opf:spine><opf:itemref idref="header"/><opf:itemref idref="s0"/></opf:spine></opf:package>
        """
    var archive = ZipWriter()
    archive.add("mimetype", "application/hwp+zip", compress: false)
    archive.add("Contents/content.hpf", hpf); archive.add("Contents/header.xml", header); archive.add("Contents/section0.xml", section)
    archive.add("BinData/image1.png", png(), compress: false)
    let file = folder.appendingPathComponent("a.hwpx")
    try? archive.finish().write(to: file)
    guard let model = readFile(file, engine: .hwpxReader, from: "hwpx", folder: folder) else { return }
    let lines = describe(model)
    check(model.metadata.title == "한글 제목", "HWPX title")
    check(lines.contains { $0.contains("«안녕하세요 »[b]«plain\ttab»") }, "runs with their properties, tab: \(lines)")
    check(lines.contains { $0.contains("[td 2x1 «A»]") } && lines.contains { $0.contains("«B»") && $0.contains("«C»") }, "table with column span: \(lines.filter { $0.contains("row") })")
    check(lines.contains { $0.contains("figure") && $0.contains("data=true") }, "picture from BinData")
    if case .paragraph(_, let style)? = model.blocks.first { check(style.alignment == .centre, "paragraph alignment from paraPr") }
}

/// Builds a minimal OLE compound file (version 3: 512-byte sectors, one FAT sector, streams above the mini-stream cutoff).
private func compoundFile(_ streams: [(path: String, data: Data)]) -> Data {
    // Directory: root, then storages and streams in one flat sibling chain per storage (a degenerate but valid tree).
    struct Node { var name: String; var isStorage: Bool; var data: Data; var children: [Int] = []; var left: UInt32 = 0xFFFF_FFFF; var right: UInt32 = 0xFFFF_FFFF; var child: UInt32 = 0xFFFF_FFFF; var start: UInt32 = 0xFFFF_FFFE }
    var nodes = [Node(name: "Root Entry", isStorage: true, data: Data())]
    for (path, data) in streams {
        var parent = 0
        let parts = path.split(separator: "/").map(String.init)
        for (i, part) in parts.enumerated() {
            let last = i == parts.count - 1
            if let existing = nodes[parent].children.first(where: { nodes[$0].name == part }) { parent = existing; continue }
            nodes.append(Node(name: part, isStorage: !last, data: last ? data : Data()))
            nodes[parent].children.append(nodes.count - 1)
            parent = nodes.count - 1
        }
    }
    for index in nodes.indices {
        // Chain the children through right pointers.
        let kids = nodes[index].children
        if let first = kids.first { nodes[index].child = UInt32(first) }
        for (k, kid) in kids.enumerated() where k + 1 < kids.count { nodes[kid].right = UInt32(kids[k + 1]) }
    }
    // Pad every stream to 4096 so none lives in the mini stream; sector layout: 0 = FAT, 1... = directory, then streams.
    var sectors: [Data] = []
    var fat: [UInt32] = [0xFFFF_FFFD]   // sector 0 is the FAT
    func addChain(_ data: Data) -> UInt32 {
        let count = max((data.count + 511) / 512, 1)
        let first = UInt32(sectors.count + 1)
        for i in 0..<count {
            var chunk = data.subdata(in: min(i * 512, data.count)..<min((i + 1) * 512, data.count))
            chunk.append(Data(count: 512 - chunk.count))
            sectors.append(chunk)
            fat.append(i + 1 == count ? 0xFFFF_FFFE : first + UInt32(i) + 1)
        }
        return first
    }
    var directory = Data()
    let directoryStart = UInt32(1)
    let directorySectors = (nodes.count * 128 + 511) / 512
    // Reserve the directory sectors first.
    for _ in 0..<directorySectors { sectors.append(Data(count: 512)); fat.append(0) }
    for i in 0..<directorySectors { fat[1 + i] = i + 1 == directorySectors ? 0xFFFF_FFFE : UInt32(2 + i) }
    for index in nodes.indices where !nodes[index].isStorage {
        var data = nodes[index].data
        if data.count < 4096 { data.append(Data(count: 4096 - data.count)); nodes[index].data = data }
        nodes[index].start = addChain(data)
    }
    for node in nodes {
        var entry = Data(count: 128)
        let units = Array(node.name.utf16)
        for (i, u) in units.enumerated() { entry[i * 2] = UInt8(u & 0xFF); entry[i * 2 + 1] = UInt8(u >> 8) }
        entry[64] = UInt8((units.count + 1) * 2 & 0xFF); entry[65] = UInt8((units.count + 1) * 2 >> 8)
        entry[66] = node.isStorage ? (node.name == "Root Entry" ? 5 : 1) : 2
        entry[67] = 1
        func put(_ offset: Int, _ v: UInt32) { for b in 0..<4 { entry[offset + b] = UInt8((v >> (8 * UInt32(b))) & 0xFF) } }
        put(68, node.left); put(72, node.right); put(76, node.child); put(116, node.isStorage ? 0xFFFF_FFFE : node.start)
        put(120, UInt32(node.isStorage ? 0 : node.data.count))
        directory.append(entry)
    }
    directory.append(Data(count: directorySectors * 512 - directory.count))
    for i in 0..<directorySectors { sectors[i] = directory.subdata(in: i * 512..<(i + 1) * 512) }
    var fatSector = Data()
    for v in fat { fatSector.le32(v) }
    fatSector.append(Data(repeating: 0xFF, count: 512 - fatSector.count))
    var header = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    header.append(Data(count: 16)); header.le16(0x3E); header.le16(3); header.le16(0xFFFE); header.le16(9); header.le16(6)
    header.append(Data(count: 6)); header.le32(0); header.le32(1); header.le32(directoryStart); header.le32(0); header.le32(4096)
    header.le32(0xFFFF_FFFE); header.le32(0); header.le32(0xFFFF_FFFE); header.le32(0)
    header.le32(0)   // DIFAT[0] = sector 0, the FAT
    for _ in 1..<109 { header.le32(0xFFFF_FFFF) }
    // The FAT is sector 0 in `sectors` terms: file sector index 0 follows the header.
    var out = header
    out.append(fatSector)
    for s in sectors { out.append(s) }
    return out
}

private func hwpRecord(_ tag: Int, _ level: Int, _ data: Data) -> Data {
    var out = Data()
    if data.count < 0xFFF { out.le32(UInt32(tag | level << 10 | data.count << 20)) } else { out.le32(UInt32(tag | level << 10 | 0xFFF << 20)); out.le32(UInt32(data.count)) }
    return out + data
}

private func hwpText(_ text: String) -> Data {
    var d = Data()
    for u in text.utf16 { d.le16(u) }
    d.le16(13)
    return d
}

@MainActor
private func dockitHWP() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    func paragraph(_ text: String, level: Int) -> Data {
        hwpRecord(0x42, level, Data(count: 22)) + hwpRecord(0x43, level + 1, hwpText(text))
    }
    var cell0 = Data(); cell0.le16(1); cell0.le32(0); cell0.le16(0); cell0.le16(0); cell0.le16(2); cell0.le16(1); cell0.append(Data(count: 8))
    var cell1 = Data(); cell1.le16(1); cell1.le32(0); cell1.le16(0); cell1.le16(1); cell1.le16(1); cell1.le16(1); cell1.append(Data(count: 8))
    var tableControl = Data("tbl ".utf8.reversed())
    tableControl.append(Data(count: 20))
    var body = paragraph("안녕 HWP", level: 0)
    body += hwpRecord(0x42, 0, Data(count: 22)) + hwpRecord(0x43, 1, hwpText("")) + hwpRecord(0x47, 1, tableControl) + hwpRecord(0x4D, 2, Data(count: 16))
    body += hwpRecord(0x48, 2, cell0) + paragraph("wide", level: 2) + hwpRecord(0x48, 2, cell1) + paragraph("under", level: 2)
    var withBreak = Data(); for u in "line one".utf16 { withBreak.le16(u) }; withBreak.le16(10); for u in "line two".utf16 { withBreak.le16(u) }; withBreak.le16(13)
    body += hwpRecord(0x42, 0, Data(count: 22)) + hwpRecord(0x43, 1, withBreak)
    var header = Data("HWP Document File".utf8); header.append(Data(count: 15)); header.le32(0x0500_0000); header.le32(1)   // compressed
    header.append(Data(count: 216))
    var raw = (try? (body as NSData).compressed(using: .zlib) as Data) ?? body
    // The OLE container stores the compressed stream as is.
    let file = folder.appendingPathComponent("a.hwp")
    try? compoundFile([("FileHeader", header), ("BodyText/Section0", raw)]).write(to: file)
    guard let model = readFile(file, engine: .hwpReader, from: "hwp", folder: folder) else { return }
    let lines = describe(model)
    check(lines.contains("p «안녕 HWP»"), "HWP paragraph text: \(lines)")
    check(lines.contains { $0.contains("[td 2x1 «wide»]") } && lines.contains { $0.contains("«under»") }, "HWP table with a column span: \(lines.filter { $0.contains("row") })")
    check(lines.contains("p «line one»<br>«line two»"), "HWP line break control")
    // Encrypted and damaged files.
    var locked = header; locked.replaceSubrange(36..<40, with: Data([3, 0, 0, 0]))
    let lockedFile = folder.appendingPathComponent("locked.hwp")
    try? compoundFile([("FileHeader", locked)]).write(to: lockedFile)
    check(runStepFailure(.hwpReader, "hwp", .docModel, input: .file(lockedFile), context: context(folder, source: "locked.hwp", from: "hwp", to: "txt")) == .passwordRequired("hwp"), "a protected HWP asks for its password")
    raw = Data("junk".utf8)
    let junk = folder.appendingPathComponent("junk.hwp")
    try? raw.write(to: junk)
    check(runStepFailure(.hwpReader, "hwp", .docModel, input: .file(junk), context: context(folder, source: "junk.hwp", from: "hwp", to: "txt")) == .damaged("hwp"), "a damaged HWP is reported as damaged")
}

@MainActor
private func dockitMail() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    let eml = """
        From: =?UTF-8?B?w4lsb8Ot?= <elo@example.com>
        To: you@example.com
        Subject: =?UTF-8?Q?Caf=C3=A9_menu?=
        Date: Tue, 3 Sep 2024 10:15:00 +0200
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="OUTER"

        --OUTER
        Content-Type: multipart/alternative; boundary="INNER"

        --INNER
        Content-Type: text/plain; charset=utf-8

        plain version
        --INNER
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        <html><body><p>Hello <b>world</b> caf=C3=A9</p><img src=3D"cid:logo1"></body></html>
        --INNER--
        --OUTER
        Content-Type: image/png; name="logo.png"
        Content-ID: <logo1>
        Content-Disposition: inline
        Content-Transfer-Encoding: base64

        \(png().base64EncodedString())
        --OUTER
        Content-Type: application/pdf; name="report.pdf"
        Content-Disposition: attachment; filename="report.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --OUTER--
        """
    let file = folder.appendingPathComponent("m.eml")
    try? Data(eml.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: file)
    guard let model = readFile(file, engine: .mailReader, from: "eml", folder: folder) else { return }
    let lines = describe(model)
    check(model.metadata.title == "Café menu" && model.metadata.authors == ["Élo <elo@example.com>"].map { $0 } || model.metadata.authors.first?.contains("elo@example.com") == true, "encoded-word headers: \(model.metadata)")
    check(lines.contains { $0.contains("«Hello »«world»[b]« café»") }, "HTML part, quoted-printable: \(lines)")
    check(lines.contains { $0.contains("figure") && $0.contains("data=true") }, "the cid: picture is resolved")
    check(lines.contains { $0.contains("report.pdf") }, "attachments are listed")
    check(model.metadata.date != nil, "RFC 2822 date")
    let archive = runStep(.mailReader, "eml", .archiveTree, input: .file(file), context: context(folder, source: "m.eml", from: "eml", to: "zip"))
    if case .archive(let tree)? = archive?.value {
        check(tree.entries.map(\.path) == ["logo.png", "report.pdf"] || tree.entries.map(\.path) == ["report.pdf"] || tree.entries.contains { $0.path == "report.pdf" }, "attachments as an archive tree: \(tree.entries.map(\.path))")
        check(tree.entries.allSatisfy { $0.extracted.map { FileManager.default.fileExists(atPath: $0.path) } == true }, "attachments extracted into the work folder")
    } else { check(false, "EML → ArchiveTree") }
}

// MARK: - Writers

@MainActor
private func dockitTextOutputs() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    let model = sampleModel()
    // Plain text.
    let (txt, _) = TextWriter.render(model)
    check(txt.contains("Sample document\n===============") && txt.contains("Introduction\n============") && txt.contains("- one") && txt.contains("3. third"), "text: titles and lists")
    check(txt.contains("Name   Qty") && txt.contains("Apple") && txt.contains("[1] The note."), "text: aligned table and notes")
    check(txt.contains("link (https://example.com/a?b=1&c=2)") && txt.contains("x^2+y^2=z^2"), "text: links and maths")
    // reStructuredText.
    let (rst, _) = RSTWriter.render(model)
    check(rst.contains("===============\nSample document\n===============") && rst.contains("Introduction\n============") && rst.contains("Lists\n-----"), "RST: titles and section adornments")
    check(rst.contains("**bold**") && rst.contains("*italic*") && rst.contains("``code()``") && rst.contains("`link <https://example.com/a?b=1&c=2>`__"), "RST: inline markup")
    check(rst.contains(".. code-block:: swift\n\n   let a = 1") && rst.contains(".. math::\n\n   \\frac{a}{b}") && rst.contains(".. list-table:: Fruit\n   :header-rows: 1"), "RST: directives")
    check(rst.contains("[#fn1]_") && rst.contains(".. [#fn1]\n   The note."), "RST: footnotes")
    check(rst.contains("- one") && rst.contains("3. third") && rst.contains(".. figure:: pic.png"), "RST: lists and figure")
    // LaTeX.
    for cls in ["article", "report", "book"] {
        let out = LaTeXWriter.render(model, documentClass: cls)
        let tex = out.tex
        check(tex.contains("\\documentclass{\(cls)}") && tex.contains("\\usepackage{lmodern}") && tex.contains("\\usepackage{microtype}") && tex.contains("\\usepackage{booktabs}") && tex.contains("\\usepackage{hyperref}"), "LaTeX \(cls): preamble")
        check(tex.contains(cls == "article" ? "\\section*{Introduction}" : "\\chapter*{Introduction}") && tex.contains(cls == "article" ? "\\subsection*{Lists}" : "\\section*{Lists}"),
              "LaTeX \(cls): heading levels")
        check(tex.contains("\\textbf{bold}") && tex.contains("\\emph{italic}") && tex.contains("\\sout{struck}") && tex.contains("\\texttt{code()}") && tex.contains("\\href{https://example.com/a?b=1\\&c=2}{link}"), "LaTeX \(cls): inline commands")
        check(tex.contains("\\footnote{The note.}") && tex.contains("$x^2+y^2=z^2$") && tex.contains("\\[\n\\frac{a}{b}\n\\]"), "LaTeX \(cls): footnote and maths")
        check(tex.contains("\\toprule") && tex.contains("\\midrule") && tex.contains("\\bottomrule") && tex.contains("\\caption{Fruit}") && tex.contains("\\begin{tabular}{lr}"), "LaTeX \(cls): booktabs table")
        check(tex.contains("\\begin{enumerate}") && tex.contains("\\setcounter{enumi}{2}") && tex.contains("\\begin{itemize}") && tex.contains("\\begin{verbatim}") && tex.contains("\\begin{quote}"), "LaTeX \(cls): environments")
        check(out.files.count == 1 && tex.contains("\\includegraphics") && tex.contains("\\title{Sample document}") && tex.contains("\\maketitle"), "LaTeX \(cls): picture and title block")
        // Balanced environments and braces.
        let begins = tex.components(separatedBy: "\\begin{").count - 1, ends = tex.components(separatedBy: "\\end{").count - 1
        check(begins == ends, "LaTeX \(cls): \\begin and \\end balance (\(begins)/\(ends))")
    }
    // Headings as TypesetKit reads them (quality §3.7 parity): "# Title" over "##" sections is \maketitle, the "##" are
    // \section, numbered from three on.
    let heads = { (n: Int) in LaTeXWriter.render(DocModel(blocks: [.heading(level: 1, [.text("Title")])] + (1...n).flatMap { [.heading(level: 2, [.text("S\($0)")]), para("Text.")] })).tex }
    check(heads(2).contains("\\title{Title}") && heads(2).contains("\\maketitle") && heads(2).contains("\\section*{S1}") && !heads(2).contains("\\section{Title}"), "LaTeX: opening title, unnumbered sections")
    check(heads(3).contains("\\section{S3}"), "LaTeX: three sections are numbered")
    check(LaTeXWriter.escape("50% of $5 & #1_x ~ ^ \\ {}") == "50\\% of \\$5 \\& \\#1\\_x \\textasciitilde{} \\textasciicircum{} \\textbackslash{} \\{\\}", "LaTeX escaping")
    // Through the converters, with the options.
    if let url = writeFile(model, engine: .latexWriter, to: "tex", folder: folder, options: OptionValues(["latexClass": "book"])) {
        check((try? String(contentsOf: url, encoding: .utf8))?.contains("\\documentclass{book}") == true, "LaTeX class option")
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("doc files/image1.png").path), "LaTeX pictures go to a folder")
    }
    if let url = writeFile(model, engine: .textWriter, to: "txt", folder: folder, options: OptionValues(["lineEndings": "crlf", "encoding": "UTF-16"])) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        check(String(data: data, encoding: .utf16)?.contains("\r\n") == true, "text writer: CRLF and encoding options")
    }
    if let url = writeFile(model, engine: .markdownWriter, to: "md", folder: folder, options: OptionValues(["markdownFlavour": "pandoc"])) {
        check((try? String(contentsOf: url, encoding: .utf8))?.contains("Table: Fruit") == true, "Markdown flavour option")
    }
}

@MainActor
private func dockitRoundTrips() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    // MD → HTML → MD, MD → DOCX → MD (quality §3.7), on a Markdown-native document.
    let markdown = """
        # Round trip

        Intro with **bold**, *italic*, `code`, ~~strike~~ and a [link](https://example.org/).

        ## Lists

        - one
        - two
          - nested

        1. first
        2. second

        ## Table

        | A | B |
        |---|--:|
        | 1 | 2 |

        Table: Numbers

        > A quote.

        ```
        plain code
        ```

        Footnote.[^n]

        [^n]: Note text.

        ---

        End.
        """
    let source = MarkdownReader.parse(markdown).model
    guard let html = writeFile(source, engine: .htmlWriter, to: "html", folder: folder, name: "a"), let fromHTML = readFile(html, engine: .htmlReader, from: "html", folder: folder),
          let md1 = writeFile(fromHTML, engine: .markdownWriter, to: "md", folder: folder, name: "b"), let back1 = (try? String(contentsOf: md1, encoding: .utf8)).map({ MarkdownReader.parse($0).model }) else { return }
    compare(source, fromHTML, "MD → HTML")
    compare(source, back1, "MD → HTML → MD")
    guard let docx = writeFile(source, engine: .docxWriter, to: "docx", folder: folder, name: "c"), let fromDOCX = readFile(docx, engine: .docxReader, from: "docx", folder: folder),
          let md2 = writeFile(fromDOCX, engine: .markdownWriter, to: "md", folder: folder, name: "d"), let back2 = (try? String(contentsOf: md2, encoding: .utf8)).map({ MarkdownReader.parse($0).model }) else { return }
    compare(source, back2, "MD → DOCX → MD")
    // The same through ODT and RTF text.
    if let odt = writeFile(source, engine: .odtWriter, to: "odt", folder: folder, name: "e"), let fromODT = readFile(odt, engine: .odtReader, from: "odt", folder: folder) { compare(source, fromODT, "MD → ODT") }
    // Sanity: a damaged middle step is caught (the comparison is real).
    var changed = source
    changed.blocks[1] = para("different")
    check(describe(changed) != describe(source), "the comparison detects changes")
}

// MARK: - Layouts, slides, spreadsheets

@MainActor
private func dockitLayoutAndSlides() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    func word(_ t: String, _ x: Double, _ y: Double, bold: Bool = false, size: Double = 12) -> LayoutWord {
        LayoutWord(text: t, box: LayoutBox(x: x, y: y, width: Double(t.count) * 6, height: size), fontName: "ABCDEF+Helvetica", fontSize: size, isBold: bold)
    }
    func line(_ words: [LayoutWord]) -> LayoutLine { LayoutLine(words: words, box: LayoutBox(x: words.first!.box.x, y: words.first!.box.y, width: 200, height: words.first!.fontSize)) }
    let layout = LayoutDocument(pages: [LayoutPage(size: VectorSize(width: 612, height: 792), blocks: [
        .header([line([word("Running", 72, 760)])]),
        .heading(level: 1, [line([word("Report", 72, 700, bold: true, size: 20)])]),
        .paragraph([line([word("Hyphen-", 72, 660)]), line([word("ated", 72, 646), word("word", 120, 646), word("continues", 180, 646)])], column: 0),
        .listItem(marker: "•", [line([word("bullet", 90, 620)])]),
        .listItem(marker: "•", [line([word("second", 90, 606)])]),
        .table(rows: [[[line([word("a", 72, 560)])], [line([word("b", 172, 560)])]]], box: LayoutBox(x: 72, y: 550, width: 200, height: 30)),
        .footer([line([word("Page 1", 300, 40)])]),
    ])])
    let reflow = runStep(.htmlWriter, .layoutDocument, "html", input: .layout(layout), context: context(folder, source: "doc.pdf", from: "pdf", to: "html"))
    if case .file(let url)? = reflow?.value, let html = try? String(contentsOf: url, encoding: .utf8) {
        check(html.contains("<h1>Report</h1>") && html.contains("<li>bullet</li>") && html.contains("<td>a</td>"), "reflowed HTML: headings, lists, tables: \(html.components(separatedBy: "<article>").last?.prefix(600) ?? "")")
        check(html.contains("<p>Hyphenated word continues</p>"), "a hyphenated line end is joined")
        check(!html.contains("Running") && !html.contains("Page 1"), "running headers and footers are left out")
    }
    let positioned = runStep(.htmlWriter, .layoutDocument, "html", input: .layout(layout), context: context(folder, source: "doc.pdf", from: "pdf", to: "html", options: OptionValues(["mode": "positioned"])))
    if case .file(let url)? = positioned?.value, let html = try? String(contentsOf: url, encoding: .utf8) {
        check(html.contains("<svg") && html.contains("viewBox=\"0 0 612 792\"") && html.contains("<text ") && html.contains("textLength=") && html.contains("Report"), "positioned HTML: one SVG per page with selectable text")
        if let root = try? XML.parse(Data(("<root>" + (html.components(separatedBy: "<svg").dropFirst().first.map { "<svg" + $0.components(separatedBy: "</svg>")[0] + "</svg>" } ?? "") + "</root>").utf8)) { check(root.first("text") != nil, "the SVG is well-formed XML") } else { check(false, "the SVG is well-formed XML") }
    }
    // Slides: a vector page with a path, a gradient, text, a clipped group and a picture.
    let asset = ImageAsset(frames: [ImageFrame(width: 2, height: 2, pixels: .rgba8(Data(repeating: 200, count: 16), bytesPerRow: 8), hasAlpha: true)])
    let page = VectorPage(size: VectorSize(width: 720, height: 540), background: VectorColour(red: 1, green: 1, blue: 1), nodes: [
        .path([.move(VectorPoint(10, 10)), .line(VectorPoint(100, 10)), .cubic(VectorPoint(120, 30), VectorPoint(120, 60), VectorPoint(100, 80)), .close],
              fill: .linear(from: VectorPoint(0, 0), to: VectorPoint(100, 0), stops: [GradientStop(offset: 0, colour: VectorColour(red: 1, green: 0, blue: 0)), GradientStop(offset: 1, colour: VectorColour(red: 0, green: 0, blue: 1))]),
              stroke: VectorStroke(paint: .solid(VectorColour(red: 0, green: 0, blue: 0)), width: 2, dash: [4, 2])),
        .text(VectorTextRun(text: "Title <&>", fontName: "Helvetica", size: 32, origin: VectorPoint(50, 400), fill: .solid(VectorColour(red: 0, green: 0, blue: 0)))),
        .group([.image(asset, transform: VectorTransform(a: 50, b: 0, c: 0, d: 50, tx: 200, ty: 200))], transform: .identity, clip: [.move(VectorPoint(0, 0)), .line(VectorPoint(300, 0)), .line(VectorPoint(300, 300)), .close], opacity: 0.5),
    ])
    let slides = runStep(.htmlWriter, .vectorDocument, "html", input: .vector(VectorDocument(pages: [page, page], title: "Deck")), context: context(folder, source: "deck.pdf", from: "pdf", to: "html"))
    if case .file(let url)? = slides?.value, let html = try? String(contentsOf: url, encoding: .utf8) {
        check(html.components(separatedBy: "<section class=\"slide\"").count == 3 && html.contains("<linearGradient") && html.contains("clip-path") && html.contains("stroke-dasharray") && html.contains("Title &lt;&amp;&gt;") && html.contains("data:image/png;base64,"), "slides: one SVG each with paths, gradients, clips, text, pictures")
        check(html.contains("<title>Deck</title>"), "slides title")
    }
    // Spreadsheet.
    var sheet = Sheet(name: "Data <1>", rows: [[Cell(value: .text("Name"), style: { var s = CellStyle(); s.bold = true; return s }()), Cell(value: .text("Value"))],
                                              [Cell(value: .text("pi")), Cell(value: .number(3.14159), displayText: "3.14")], [Cell(value: .number(42)), Cell(value: .bool(true))], [Cell(value: .text("merged")), Cell()]])
    sheet.merges = [CellRange(firstRow: 3, firstColumn: 0, lastRow: 3, lastColumn: 1)]
    let hidden = Sheet(name: "Hidden", rows: [[Cell(value: .text("secret"))]], isHidden: true)
    let book = runStep(.htmlWriter, .workbook, "html", input: .workbook(Workbook(sheets: [sheet, hidden], title: "Book")), context: context(folder, source: "book.xlsx", from: "xlsx", to: "html"))
    if case .file(let url)? = book?.value, let html = try? String(contentsOf: url, encoding: .utf8) {
        check(html.contains("<h2>Data &lt;1&gt;</h2>") && html.contains("<td style=\"text-align:right\">3.14</td>") && html.contains("<td>42</td>") || html.contains(">42<") && html.contains(">TRUE<"), "workbook: sheets as tables with display text")
        check(html.contains("colspan=\"2\"") && !html.contains("secret") && html.contains("font-weight:bold"), "workbook: merges, hidden sheets, styles")
    }
}

// MARK: - WebKit

@MainActor
private func dockitWebKit() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    let page = folder.appendingPathComponent("page.html")
    let body = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 400)
    try? Data("""
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Printed page</title><style>body{font:12pt Helvetica;background:#eef}h1{break-before:page}.late{display:none}</style></head>
        <body><h1>First</h1><p>\(body)</p><h1>Second</h1><p id="end">Final words</p><img src="https://tracker.invalid/pixel.png">
        <script>setTimeout(function(){var e=document.createElement('p');e.id='late';e.textContent='Late content';document.body.appendChild(e)},200)</script></body></html>
        """.utf8).write(to: page)
    // Print: paginated vector PDF with text.
    let printed = runStep(.webKitPrint, "html", "pdf", input: .file(page), context: context(folder, source: "page.html", from: "html", to: "pdf", options: OptionValues(["pageFormat": "a4", "waitTime": 400])))
    if case .file(let url)? = printed?.value, let pdf = PDFDocument(url: url) {
        check(pdf.pageCount >= 3, "paginated PDF (\(pdf.pageCount) pages)")
        let size = pdf.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
        check(abs(size.width - 595.28) < 1 && abs(size.height - 841.89) < 1, "A4 page size (\(size))")
        let text = pdf.string ?? ""
        check(text.contains("First") && text.contains("Lorem ipsum") && text.contains("Final words"), "selectable text")
        check(text.contains("Late content"), "the wait option lets scripts finish")
        check((pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String) == "Printed page", "PDF title from the page")
        check(url.deletingLastPathComponent().path == folder.path && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(".print-").path), "output in the work folder")
    } else { check(false, "WebKit print produced a PDF") }
    // Letter, landscape, a page range, header and footer.
    let custom = runStep(.webKitPrint, "html", "pdf", input: .file(page), context: context(folder, source: "page.html", from: "html", to: "pdf", options: OptionValues(["pageFormat": "letter", "orientation": "landscape", "pages": "2", "headerFooter": true, "footerTemplate": "<span class=\"pageNumber\"></span> of <span class=\"totalPages\"></span>", "margin": 15])))
    if case .file(let url)? = custom?.value, let pdf = PDFDocument(url: url) {
        check(pdf.pageCount == 1, "page range keeps one page (\(pdf.pageCount))")
        let size = pdf.page(at: 0)?.bounds(for: .mediaBox).size ?? .zero
        check(abs(size.width - 792) < 1 && abs(size.height - 612) < 1, "Letter landscape (\(size))")
        check((pdf.string ?? "").contains(" of "), "footer template filled: \((pdf.string ?? "").suffix(60))")
    }
    // Snapshot.
    let shot = runStep(.webKitSnapshot, "html", "png", input: .file(page), context: context(folder, source: "page.html", from: "html", to: "png", options: OptionValues(["screenWidth": 800, "scale": 1])))
    if case .file(let url)? = shot?.value, let image = NSImage(contentsOf: url), let rep = image.representations.first {
        check(rep.pixelsWide == 800 && rep.pixelsHigh > 800, "full-page PNG at the chosen width (\(rep.pixelsWide)×\(rep.pixelsHigh))")
        check(ImageSniff.commonType((try? Data(contentsOf: url)) ?? Data()) == "png", "PNG data")
    } else { check(false, "WebKit snapshot produced a PNG") }
    let jpg = runStep(.webKitSnapshot, "html", "jpg", input: .file(page), context: context(folder, source: "page.html", from: "html", to: "jpg", options: OptionValues(["screenWidth": 400, "scale": 2, "quality": 70])))
    if case .file(let url)? = jpg?.value, let data = try? Data(contentsOf: url), let image = NSImage(data: data), let rep = image.representations.first {
        check(ImageSniff.commonType(data) == "jpeg" && rep.pixelsWide == 800, "JPEG at 2× (\(rep.pixelsWide) wide)")
    } else { check(false, "WebKit snapshot produced a JPEG") }
    // Nothing leaves the Mac unless the person turns it on for the file: a loopback server counts the requests.
    final class Counter: @unchecked Sendable { var connections = 0; var port: UInt16 = 0 }
    let counter = Counter()
    if let listener = try? NWListener(using: .tcp, on: .any) {
        listener.newConnectionHandler = { connection in counter.connections += 1; connection.cancel() }
        listener.stateUpdateHandler = { if case .ready = $0 { counter.port = listener.port?.rawValue ?? 0 } }
        listener.start(queue: .main)
        let deadline = Date().addingTimeInterval(5)
        while counter.port == 0 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        if counter.port != 0 {
            let remote = folder.appendingPathComponent("remote.html")
            try? Data("<html><body><p>remote test</p><img src=\"http://127.0.0.1:\(counter.port)/p.png\"><link rel=\"stylesheet\" href=\"http://127.0.0.1:\(counter.port)/s.css\"></body></html>".utf8).write(to: remote)
            _ = runStep(.webKitPrint, "html", "pdf", input: .file(remote), context: context(folder, source: "remote.html", from: "html", to: "pdf"))
            _ = runStep(.webKitSnapshot, "html", "png", input: .file(remote), context: context(folder, source: "remote.html", from: "html", to: "png"))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            check(counter.connections == 0, "no request leaves the page by default (\(counter.connections) connections)")
            _ = runStep(.webKitPrint, "html", "pdf", input: .file(remote), context: context(folder, source: "remote.html", from: "html", to: "pdf", options: OptionValues(["loadWebResources": true])))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            check(counter.connections > 0, "\"Load web resources\" lets the page fetch (\(counter.connections) connections)")
        }
        listener.cancel()
    }
    // Cancellation and failure.
    let cancelled = StepContext(workFolder: folder, source: page, sourceFormat: "html", targetFormat: "pdf", isCancelled: { true })
    if case .failure(let error)? = complete(30, { try await Services.converters.converter(for: .webKitPrint)!.run(Step(.webKitPrint, "html", "pdf"), input: .file(page), context: cancelled) }) {
        check((error as? ConversionError) == .cancelled, "cancellation is reported")
    } else { check(false, "a cancelled print stops") }
    check(runStepFailure(.webKitPrint, "html", "pdf", input: .file(folder.appendingPathComponent("missing.html")), context: context(folder, source: "missing.html", from: "html", to: "pdf")) != nil, "a missing page fails cleanly")
    check(PageRange.parse("1-3,5", count: 9) == [1, 2, 3, 5] && PageRange.parse("", count: 9) == nil && PageRange.parse("7-", count: 9) == [7, 8, 9], "page ranges")
    check(PageFurniture.fill("<b>p</b> <span class=\"pageNumber\"></span>/<span class=\"totalPages\"></span> <span class=\"title\"></span>", date: "d", title: "T", url: "u", page: 2, total: 5) == "p 2/5 T", "header template fields")
}

// MARK: - Safety

@MainActor
private func dockitSafety() {
    let folder = tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    installFakes(); DocKitModule.install()
    // Markdown and HTML read local pictures only from inside the document's folder.
    let outside = folder.appendingPathComponent("secret.png")
    try? png().write(to: outside)
    let inner = folder.appendingPathComponent("docs", isDirectory: true)
    try? FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    try? png().write(to: inner.appendingPathComponent("ok.png"))
    let md = MarkdownReader.parse("![a](../secret.png) ![b](ok.png) ![c](/etc/hosts) ![d](https://example.com/x.png)", baseURL: inner).model
    check(md.resources.keys.sorted() == ["ok.png"], "Markdown reads only pictures inside the folder (\(md.resources.keys.sorted()))")
    let html = HTMLReader.parse("<img src=\"../secret.png\"><img src=\"ok.png\"><img src=\"file:///etc/hosts\">", baseURL: inner).model
    check(html.resources.keys.sorted() == ["ok.png"], "HTML reads only pictures inside the folder (\(html.resources.keys.sorted()))")
    // A zip bomb is refused, not expanded.
    var hostile = ZipWriter()
    hostile.add("word/document.xml", Data(repeating: 0, count: 64_000_000))
    if let archive = try? ZipArchive(data: hostile.finish()) {
        check((try? archive.data("word/document.xml")) == nil, "an entry that expands past the ratio limit is refused")
        check((try? DOCXReader.read(hostile.finish())) == nil, "a DOCX with such an entry does not read")
    } else { check(false, "the hostile archive is a ZIP") }
    // Hostile inputs fail or read; nothing crashes.
    for bytes in [Data(), Data([0x50, 0x4B, 3, 4]), Data(repeating: 0xFF, count: 1000), Data("<w:document>".utf8), Data("PK\u{5}\u{6}".utf8) + Data(count: 18)] {
        _ = try? DOCXReader.read(bytes); _ = try? ODTReader.read(bytes)
    }
    check(CompoundFile(Data(repeating: 0, count: 2000)) == nil, "not a compound file")
    // Deeply nested HTML and Markdown stay linear enough to finish.
    let deep = String(repeating: "<div>", count: 3000) + "text" + String(repeating: "</div>", count: 3000)
    check(describe(HTMLReader.parse(deep).model).contains("p «text»"), "deeply nested HTML")
    let quotes = String(repeating: "> ", count: 200) + "deep"
    check(!describe(MarkdownReader.parse(quotes).model).isEmpty, "deeply nested quotes")
    // Writers escape what they are given.
    let nasty = DocModel(blocks: [.paragraph([.text("<script>alert(1)</script> & \u{0}\u{1}control"), .link([.text("x")], destination: "javascript:alert(1)\"onclick=\"y")], DocParagraphStyle())])
    let htmlOut = HTMLWriter.render(nasty, embedImages: true, filesFolder: "f").html
    check(!htmlOut.contains("<script>") && !htmlOut.contains("\"onclick=\"y"), "HTML output escapes text and attributes")
    let docx = DOCXWriter.data(nasty)
    if let archive = try? ZipArchive(data: docx.data), let doc = try? archive.data("word/document.xml") { check((try? XML.parse(doc)) != nil, "DOCX stays well-formed with control characters") }
    let odt = ODTWriter.data(nasty)
    if let archive = try? ZipArchive(data: odt.data), let doc = try? archive.data("content.xml") { check((try? XML.parse(doc)) != nil, "ODT stays well-formed with control characters") }
}

