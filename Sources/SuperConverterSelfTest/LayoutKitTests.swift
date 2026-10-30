import CoreGraphics
import Foundation
import PDFKit
import SuperConverterCore
import LayoutKit
import RenderKit

// LayoutKit's checks (WP-L): documents are generated with Quartz (heading, paragraphs, list, ruled table, picture, running
// header, page number, a two-column page, a scan) and the extracted text, structure and tables are compared with what was drawn.

private let layoutPDF: URL = fixturePDF(pages: [{ fixtureDocumentPage($0, number: 1) }, { fixtureDocumentPage($0, number: 2) }])

@MainActor
private func layout(_ to: StepEndpoint, _ url: URL = layoutPDF, options: OptionValues = OptionValues()) -> StepValue? {
    fixtureRun(LayoutKitConverter(), from: "pdf", to: to, input: .file(url), options: options)?.value
}

private func flatText(_ text: DocText) -> String {
    text.map { piece -> String in
        switch piece {
        case .text(let s), .code(let s): s
        case .emphasis(let t), .strong(let t), .strike(let t), .link(let t, _), .styled(let t, _): flatText(t)
        case .lineBreak: "\n"
        default: ""
        }
    }.joined()
}

private func lineText(_ lines: [LayoutLine]) -> String { lines.map { $0.words.map(\.text).joined(separator: " ") }.joined(separator: " ") }

/// Two columns of three lines each, the left one first in the file's content stream order reversed (right drawn first).
private func twoColumnPage(_ ctx: CGContext) {
    for (i, line) in ["the right column begins with this line", "and the right column goes on with this", "before the right column finally ends it"].enumerated() { fixtureText(ctx, line, x: 330, y: 640 - CGFloat(i) * 14) }
    for (i, line) in ["the left column begins with this line", "and the left column goes on with this", "before the left column finally ends it"].enumerated() { fixtureText(ctx, line, x: 72, y: 640 - CGFloat(i) * 14) }
}

func registerLayoutKitTests() {
    SelfTest.cases.append(("LayoutKit.layoutDocument", {
        guard case .layout(let document)? = layout(.layoutDocument) else { check(false, "no layout"); return }
        check(document.pages.count == 2, "two pages")
        guard let page = document.pages.first else { return }
        check(page.size.width == 612 && page.size.height == 792, "page size")
        var kinds: [String] = []
        for block in page.blocks {
            switch block {
            case .heading(let level, let lines): kinds.append("H\(level):" + lineText(lines))
            case .paragraph: kinds.append("P")
            case .listItem(let marker, let lines): kinds.append("LI\(marker):" + lineText(lines))
            case .table(let rows, _): kinds.append("T\(rows.count)x\(rows.first?.count ?? 0)")
            case .figure(_, let image): kinds.append("F" + (image == nil ? "-" : "+"))
            case .header(let lines): kinds.append("HDR:" + lineText(lines))
            case .footer(let lines): kinds.append("FTR:" + lineText(lines))
            }
        }
        check(kinds.contains("H1:Quarterly Report"), "heading found: \(kinds)")
        check(kinds.contains("LI\u{2022}:First point") && kinds.contains("LI\u{2022}:Third point"), "list items with markers: \(kinds)")
        check(kinds.contains("T3x3"), "3 x 3 table: \(kinds)")
        check(kinds.contains("F+"), "figure with its picture: \(kinds)")
        check(kinds.contains { $0.hasPrefix("HDR:Acme") } && kinds.contains("FTR:1"), "running header and page number kept as header/footer: \(kinds)")
        if case .table(let rows, _)? = page.blocks.first(where: { if case .table = $0 { true } else { false } }) {
            check(rows[1].map(lineText) == ["Widget", "4", "1,250.50"], "table cells \(rows[1].map(lineText))")
        }
        let words = page.blocks.flatMap { block -> [LayoutWord] in
            if case .paragraph(let lines, _) = block { lines.flatMap(\.words) } else { [] }
        }
        check(words.contains { $0.text == "Revenue" && $0.isBold }, "bold word flagged")
        check(words.allSatisfy { $0.box.width > 0 && $0.box.y > 0 && $0.box.y < 792 }, "word boxes sane")
    }))

    SelfTest.cases.append(("LayoutKit.docModel", {
        guard case .doc(let doc)? = layout(.docModel) else { check(false, "no DocModel"); return }
        check(doc.metadata.title == "Fixture" && doc.metadata.language == "en", "metadata \(doc.metadata.title ?? "-") \(doc.metadata.language ?? "-")")
        check(doc.metadata.pageSize == VectorSize(width: 612, height: 792), "page size")
        var headings: [String] = [], paragraphs: [String] = [], lists = 0, tables: [DocTable] = [], figures = 0
        for block in doc.blocks {
            switch block {
            case .heading(_, let t): headings.append(flatText(t))
            case .paragraph(let t, _): paragraphs.append(flatText(t))
            case .list(let ordered, _, let items): lists += 1; check(!ordered && items.count == 3, "bullet list of three")
            case .table(let t): tables.append(t)
            case .figure(let r, let caption, _): figures += 1; check(doc.resources[r]?.isEmpty == false, "figure data"); _ = caption
            default: break
            }
        }
        check(headings.first == "Quarterly Report", "heading \(headings)")
        check(paragraphs.first == "The company grew steadily during the quarter and the board is pleased with the results, which exceed the forecast in every region we operate in, including some new markets.",
              "paragraph reflowed: \(paragraphs.first ?? "-")")
        check(paragraphs.contains { $0.hasPrefix("Revenue rose by twelve percent over a comparable international period") }, "hyphenated line joined: \(paragraphs)")
        check(!paragraphs.contains { $0.contains("Acme Corp") } && !paragraphs.contains("1"), "running header and page number left out")
        check(lists == 2 && tables.count == 2 && figures == 2, "lists \(lists) tables \(tables.count) figures \(figures)")
        if let table = tables.first {
            check(table.rows.count == 3 && table.rows.allSatisfy { $0.count == 3 }, "table is 3 x 3")
            check(table.rows[0].allSatisfy(\.isHeader), "header row")
            check(flatText(table.rows[1][2].blocks.compactMap { if case .paragraph(let t, _) = $0 { t } else { nil } }.first ?? []) == "1,250.50", "cell text")
            check(table.alignments[1] == .end && table.alignments[0] == .start, "numbers right-aligned")
        }
        let bold = doc.blocks.contains { block in
            if case .paragraph(let t, _) = block, t.contains(where: { if case .strong = $0 { true } else { false } }) { return true } else { return false }
        }
        check(bold, "bold run kept as strong")
        // Visual appearance keeps line breaks and page breaks.
        if case .doc(let visual)? = layout(.docModel, options: OptionValues(["visualAppearance": true])) {
            check(visual.blocks.contains(.pageBreak), "page break between pages")
        }
    }))

    SelfTest.cases.append(("LayoutKit.workbook", {
        guard case .workbook(let book)? = layout(.workbook) else { check(false, "no Workbook"); return }
        check(book.sheets.count == 2, "a sheet per table: \(book.sheets.map(\.name))")
        guard let sheet = book.sheets.first else { return }
        check(sheet.rows.count == 3 && sheet.rows[0].count == 3, "3 x 3")
        check(sheet.rows[0][0].value == .text("Item") && sheet.rows[0][0].style.bold, "bold header")
        check(sheet.rows[1][1].value == .number(4), "4 is a number")
        check(sheet.rows[1][2].value == .number(1250.5) && sheet.rows[1][2].numberFormat == "#,##0.00" && sheet.rows[1][2].displayText == "1,250.50", "1,250.50 keeps its format")
        if case .workbook(let single)? = layout(.workbook, options: OptionValues(["singleSheet": true])) {
            check(single.sheets.count == 1 && single.sheets[0].rows.count == 7, "all tables on one sheet with a blank row between")
        }
        let plain = fixturePDF(pages: [twoColumnPage])
        if case .workbook(let text)? = layout(.workbook, plain) { check(text.sheets.first?.name == "Text" && !(text.sheets.first?.rows.isEmpty ?? true), "no tables: the text on one sheet") }
    }))

    SelfTest.cases.append(("LayoutKit.deck", {
        guard case .deck(let deck)? = layout(.deck) else { check(false, "no Deck"); return }
        check(deck.slides.count == 2 && deck.size == VectorSize(width: 612, height: 792), "a slide per page at the page size")
        guard let slide = deck.slides.first else { return }
        check(slide.title == "Quarterly Report", "title \(slide.title ?? "-")")
        let heading = slide.shapes.first { if case .text(let blocks) = $0.content, case .heading? = blocks.first { true } else { false } }
        // Heading baseline 700 pt (up) → near the top: y (down) around 792 - 700 - 24.
        check(heading.map { $0.box.y > 40 && $0.box.y < 100 } == true, "boxes flipped to y down: \(String(describing: heading?.box))")
        check(slide.shapes.contains { if case .picture = $0.content { true } else { false } }, "figure as a picture")
        check(slide.shapes.contains { if case .text(let b) = $0.content, case .table? = b.first { true } else { false } }, "table shape")
    }))

    SelfTest.cases.append(("LayoutKit.publicationAndText", {
        let chapters = fixturePDF(pages: [
            { fixtureText($0, "Chapter One", x: 72, y: 640, size: 22, bold: true); fixtureText($0, "First chapter body text goes here.", x: 72, y: 600) },
            { fixtureText($0, "Chapter Two", x: 72, y: 640, size: 22, bold: true); fixtureText($0, "Second chapter body text goes here.", x: 72, y: 600) },
        ])
        guard case .publication(let book)? = layout(.publication, chapters) else { check(false, "no Publication"); return }
        check(book.spine.map(\.title) == ["Chapter One", "Chapter Two"], "chapters from headings \(book.spine.map { $0.title ?? "-" })")
        check(book.contents.count == 2 && book.cover == "cover" && book.resources["cover"]?.mediaType == "image/jpeg", "contents and cover")

        let columns = fixturePDF(pages: [twoColumnPage])
        guard case .file(let url)? = layout("txt", columns), let text = try? String(contentsOf: url, encoding: .utf8) else { check(false, "no text"); return }
        check(text == "the left column begins with this line and the left column goes on with this before the left column finally ends it\n\nthe right column begins with this line and the right column goes on with this before the right column finally ends it\n", "columns read one after the other: \(text.debugDescription)")
        if case .file(let onPage)? = layout("txt", columns, options: OptionValues(["layout": "page"])), let t = try? String(contentsOf: onPage, encoding: .utf8) {
            check(t.hasPrefix("the left column begins with this line") && t.contains("the right column begins") && t.components(separatedBy: "\n")[0].contains("   "), "as on the page: \(t.debugDescription)")
        }
    }))

    SelfTest.cases.append(("LayoutKit.lockedAndSelectedPages", {
        let locked = fixturePDF(userPassword: "pw", pages: [{ fixtureText($0, "Secret text", x: 72, y: 600) }, { fixtureText($0, "Other page", x: 72, y: 600) }])
        let context = StepContext(workFolder: scratch, source: locked, sourceFormat: "pdf", targetFormat: "txt")
        let step = Step(.layoutKit, "pdf", .docModel)
        if case .failure(let e)? = complete(300, { try await LayoutKitConverter().run(step, input: .file(locked), context: context) }) {
            check((e as? ConversionError) == .passwordRequired("pdf"), "asks for the password: \(e)")
        } else { check(false, "must not open without the password") }
        if case .doc(let doc)? = layout(.docModel, locked, options: OptionValues(["password": "pw", "pages": "2"])) {
            check(doc.blocks.map(DocBlockText.of) == ["Other page"], "only page 2: \(doc.blocks.map(DocBlockText.of))")
        }
    }))

    SelfTest.cases.append(("LayoutKit.recognisesScans", {
        // A page that is one picture of text: no text layer, so Vision reads it.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmap = CGContext(data: nil, width: 1650, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(gray: 1, alpha: 1); bitmap.fill(CGRect(x: 0, y: 0, width: 1650, height: 400))
        fixtureText(bitmap, "Invoice total", x: 100, y: 200, size: 90)
        let scan = fixturePDF(pages: [{ ctx in ctx.draw(bitmap.makeImage()!, in: CGRect(x: 0, y: 500, width: 612, height: 148)) }])
        guard case .layout(let document)? = layout(.layoutDocument, scan) else { check(false, "no layout for the scan"); return }
        check(document.pages.first?.isRecognised == true, "page flagged as recognised")
        let text = document.pages.first?.blocks.compactMap { b -> String? in
            switch b { case .paragraph(let l, _), .heading(_, let l): lineText(l); default: nil }
        }.joined(separator: " ").lowercased() ?? ""
        check(text.contains("invoice") && text.contains("total"), "recognised text: \(text)")
        if case .layout(let off)? = layout(.layoutDocument, scan, options: OptionValues(["ocr": false])) {
            check(off.pages.first?.blocks.contains { if case .paragraph = $0 { true } else { false } } == false, "no recognition when switched off")
        }
    }))

    SelfTest.cases.append(("LayoutKit.damagedInputNeverCrashes", {
        // Quartz's fixture (compressed streams: damage mostly reaches the PDF reader) and an uncompressed page whose content
        // stream the page graphics scanner and the analysis meet directly: words, rulings of a table, an image, nested forms.
        let drawn = svtSinglePagePDF(content: """
            BT /F1 18 Tf 72 700 Td (Damaged input heading) Tj ET
            BT /F1 10 Tf 72 670 Td (A paragraph of words that the analysis groups into lines) Tj 0 -12 Td (and a second line below it.) Tj ET
            0.5 w 72 600 m 300 600 l S 72 580 m 300 580 l S 72 560 m 300 560 l S 72 560 m 72 600 l S 186 560 m 186 600 l S 300 560 m 300 600 l S
            BT /F1 9 Tf 76 586 Td (Cell one) Tj 114 0 Td (Cell two) Tj 0 -20 Td (12.50) Tj -114 0 Td (Total) Tj ET
            72 440 1 100 re f 1 0 0 rg 80 450 60 40 re f
            q 120 0 0 80 300 400 cm /Im1 Do Q q 1 0 0 1 20 20 cm /Fm1 Do Q
            """, resources: "/Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> /XObject << /Im1 5 0 R /Fm1 6 0 R >>",
            extra: ["/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8",
                    "/Type /XObject /Subtype /Form /BBox [0 0 200 200] /Resources << /XObject << /Fm1 6 0 R >> >>"],
            extraStreams: [5: "\u{0}\u{80}\u{80}\u{FF}", 6: "0 0 1 rg 10 10 50 50 re f 2 w 0 0 m 200 0 l S /Fm1 Do"])
        let fixture = (try? Data(contentsOf: layoutPDF)).map { [UInt8]($0) } ?? []
        let seeds = [FuzzSeed(name: "fixture", ext: "pdf", bytes: fixture),
                     FuzzSeed(name: "drawn", ext: "pdf", bytes: [UInt8](drawn), nesting: ["q ", "[", "<<", "0 0 1 1 re "])]
        let dir = scratch.appendingPathComponent("layoutkit-fuzz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The model readers, page-layout text (its columns come from word positions) and figure pictures in turn.
        let targets: [StepEndpoint] = [.layoutDocument, .docModel, .format("txt"), .workbook, .deck]
        var next = 0
        let ran = fuzzNeverCrashes("LayoutKit.damagedInputNeverCrashes", seeds: seeds, count: 75) { url, _ in
            let to = targets[next % targets.count]; next += 1
            let context = StepContext(workFolder: dir, source: url, sourceFormat: "pdf", targetFormat: "txt",
                                      options: OptionValues(["ocr": false, "layout": "page"]))
            _ = try await LayoutKitConverter().run(Step(.layoutKit, "pdf", to), input: .file(url), context: context)
        }
        check(ran == 150, "every damaged input was handled without a crash (\(ran))")
    }))

    registerPDFOpsTests()
}

enum DocBlockText {
    static func of(_ block: DocBlock) -> String {
        switch block {
        case .paragraph(let t, _), .heading(_, let t): flatText(t)
        default: ""
        }
    }
}
