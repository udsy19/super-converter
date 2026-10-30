import AppKit
import Foundation
import ImageIO
@testable import OfficeKit
import PDFKit
import SuperConverterCore

// OfficeKit's checks (WP-O). Fixtures are generated here (no files in the repository besides WP0b's libxls smoke fixture):
// workbooks with every cell kind and style written and read back through XLSX and ODS, CSV in several encodings, decks
// written to PPTX and read and rendered back, an ODF picture, a macro-enabled workbook repackaged. Everything goes through
// the registered converters, the same path the planner takes.

private let officeDay = Date(timeIntervalSince1970: 1_710_460_800)          // 2024-03-15 00:00 UTC
private let officeMoment = Date(timeIntervalSince1970: 1_710_498_600)       // 2024-03-15 10:30 UTC

@MainActor private func officeConverter(_ engine: EngineID) -> (any Converter)? { Services.converters.converter(for: engine) }

private func officeWorkFolder(_ name: String) -> URL {
    let folder = scratch.appendingPathComponent("office-\(name)-\(UUID().uuidString.prefix(6))")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Runs one step of an OfficeKit converter and returns its output; a thrown error is a failure of the case.
@MainActor private func officeRun(_ engine: EngineID, _ from: StepEndpoint, _ to: StepEndpoint, _ input: StepValue, source: URL,
                                  options: [String: OptionValue] = [:], note: String = "") -> StepOutput? {
    guard let converter = officeConverter(engine) else { check(false, "\(engine.rawValue) is registered"); return nil }
    let folder = officeWorkFolder(engine.rawValue)
    let context = StepContext(workFolder: folder, source: source, sourceFormat: FormatID(source.pathExtension.lowercased()),
                              targetFormat: FormatID(to.description), options: OptionValues(options))
    switch complete(60, { try await converter.run(Step(engine, from, to), input: input, context: context) }) {
    case .success(let output)?: return output
    case .failure(let error)?: check(false, "\(engine.rawValue) \(note) threw \(error)"); return nil
    case nil: check(false, "\(engine.rawValue) \(note) timed out"); return nil
    }
}

/// The error a step throws, if it does.
@MainActor private func officeError(_ engine: EngineID, _ from: StepEndpoint, _ to: StepEndpoint, _ input: StepValue, source: URL) -> ConversionError? {
    guard let converter = officeConverter(engine) else { return nil }
    let context = StepContext(workFolder: officeWorkFolder("err"), source: source, sourceFormat: FormatID(source.pathExtension.lowercased()),
                              targetFormat: FormatID(to.description))
    if case .failure(let error)? = complete(60, { try await converter.run(Step(engine, from, to), input: input, context: context) }) { return error as? ConversionError }
    return nil
}

private func officeFile(_ data: Data, _ name: String) -> URL {
    let url = officeWorkFolder("in").appendingPathComponent(name)
    try? data.write(to: url)
    return url
}

private func officeURL(_ output: StepOutput?) -> URL? { if case .file(let url)? = output?.value { url } else { nil } }
private func officeWorkbook(_ output: StepOutput?) -> Workbook? { if case .workbook(let book)? = output?.value { book } else { nil } }

@MainActor private func officeReadWorkbook(_ engine: EngineID, _ from: StepEndpoint, _ url: URL, note: String = "") -> StepOutput? {
    officeRun(engine, from, .workbook, .file(url), source: url, note: note)
}

// MARK: - Fixtures

private func officeCell(_ value: CellValue, formula: String? = nil, format: String? = nil, display: String? = nil, style: CellStyle = CellStyle()) -> Cell {
    Cell(value: value, formula: formula, numberFormat: format, displayText: display, style: style)
}

/// A workbook with every kind of cell, styles, merges, widths, a hidden sheet and a print area.
private func officeSampleWorkbook() -> Workbook {
    var bold = CellStyle(); bold.bold = true
    var styled = CellStyle()
    styled.bold = true; styled.italic = true; styled.fontName = "Arial"; styled.fontSize = 14
    styled.textColour = "#FF0000"; styled.fillColour = "#FFFF00"; styled.alignment = .centre; styled.wrapsText = true
    var right = CellStyle(); right.alignment = .end
    let rows: [[Cell]] = [
        [officeCell(.text("Item"), style: bold), officeCell(.text("Price"), style: bold), officeCell(.text("Qty"), style: bold), officeCell(.text("Total"), style: bold)],
        [officeCell(.text("Tea & <Co>")), officeCell(.number(1234.5), format: "#,##0.00"), officeCell(.number(3)), officeCell(.number(3703.5), formula: "B2*C2", format: "#,##0.00")],
        [officeCell(.text("Coffee"), style: styled), officeCell(.number(0.25), format: "0%"), officeCell(.number(-2)), officeCell(.number(-0.5), formula: "B3*C3", format: "0.00")],
        [officeCell(.date(officeDay), format: "yyyy-mm-dd"), officeCell(.date(officeMoment), format: "yyyy-mm-dd hh:mm:ss"), officeCell(.bool(true)), officeCell(.bool(false), formula: "C4=FALSE")],
        [officeCell(.error("#DIV/0!"), formula: "1/0"), officeCell(.text("  padded  ")), officeCell(.text("two\nlines"), style: right), officeCell(.text("Σ ünïcode 日本"))],
        [officeCell(.text("Sum")), officeCell(.number(1234.75), formula: "SUM(B2:B3)", format: "$#,##0.00"), officeCell(.text("from other"), formula: "'My Sheet'!A1&\" x\""), officeCell(.number(1e-7))],
    ]
    var main = Sheet(name: "Sales", rows: rows)
    main.merges = [CellRange(firstRow: 6, firstColumn: 0, lastRow: 7, lastColumn: 1)]
    main.rows.append([officeCell(.text("merged"))])
    main.columnWidths = [0: 18, 2: 12.5]
    main.printArea = CellRange(firstRow: 0, firstColumn: 0, lastRow: 5, lastColumn: 3)
    var other = Sheet(name: "My Sheet", rows: [[officeCell(.text("hello"))]])
    other.isHidden = true
    return Workbook(sheets: [main, other], title: "Sample")
}

/// The parts of a cell that must survive a round trip (display text is checked apart).
private func officeEssence(_ cell: Cell) -> String {
    "\(cell.value)|\(cell.formula ?? "-")|\(cell.numberFormat ?? "-")|\(cell.style)"
}

private func officeCompare(_ a: Workbook, _ b: Workbook, _ label: String) {
    check(a.sheets.map(\.name) == b.sheets.map(\.name), "\(label): sheet names \(b.sheets.map(\.name))")
    for (x, y) in zip(a.sheets, b.sheets) {
        check(x.isHidden == y.isHidden, "\(label): \(x.name) hidden")
        check(x.merges == y.merges, "\(label): \(x.name) merges \(y.merges)")
        check(x.printArea == y.printArea, "\(label): \(x.name) print area \(String(describing: y.printArea))")
        check(x.columnWidths.keys.sorted() == y.columnWidths.keys.sorted()
              && x.columnWidths.allSatisfy { abs($0.value - (y.columnWidths[$0.key] ?? -1)) < 0.01 }, "\(label): \(x.name) widths \(y.columnWidths)")
        check(y.rows.count >= x.rows.count, "\(label): \(x.name) rows \(y.rows.count)")
        for (r, row) in x.rows.enumerated() where r < y.rows.count {
            for (c, cell) in row.enumerated() {
                let back = c < y.rows[r].count ? y.rows[r][c] : Cell()
                check(officeEssence(cell) == officeEssence(back), "\(label): \(x.name) r\(r + 1)c\(c + 1): wrote \(officeEssence(cell)) read \(officeEssence(back))")
            }
        }
    }
}

private func officeText(_ blocks: [DocBlock]) -> String {
    func inline(_ text: DocText) -> String {
        text.map { piece -> String in
            switch piece {
            case .text(let t), .code(let t): t
            case .emphasis(let c), .strong(let c), .strike(let c), .link(let c, _), .styled(let c, _): inline(c)
            case .lineBreak: "\n"
            default: ""
            }
        }.joined()
    }
    return blocks.map { block -> String in
        switch block {
        case .paragraph(let t, _), .heading(_, let t): inline(t)
        case .list(_, _, let items): items.map { officeText($0) }.joined(separator: "\n")
        case .table(let table): table.rows.map { $0.map { officeText($0.blocks) }.joined(separator: "|") }.joined(separator: "\n")
        case .quote(let inner): officeText(inner)
        default: ""
        }
    }.joined(separator: "\n")
}

private func officePixels(width: Int, height: Int) -> ImageAsset {
    var data = Data()
    for y in 0..<height { for x in 0..<width { data.append(contentsOf: [UInt8(x * 60), UInt8(y * 80), UInt8(200 - x * 20), 255]) } }
    return ImageAsset(frames: [ImageFrame(width: width, height: height, pixels: .rgba8(data, bytesPerRow: width * 4), hasAlpha: false)])
}

private func officeSampleDeck() -> Deck {
    func para(_ text: String) -> DocBlock { .paragraph([.text(text)], DocParagraphStyle()) }
    let bullets: [DocBlock] = [.list(ordered: false, start: 1, items: [[para("First point")], [para("Second point")], [para("Third point")]])]
    let styledRun: DocText = [.strong([.styled([.text("Bold red")], DocRunStyle(fontName: "Arial", fontSize: 24, colour: "#FF0000"))]), .text(" and "),
                              .link([.text("a link")], destination: "https://example.com/deck")]
    let table = DocTable(rows: [[DocTable.Cell(blocks: [para("Name")], isHeader: true), DocTable.Cell(blocks: [para("Value")], isHeader: true)],
                                [DocTable.Cell(blocks: [para("Alpha")]), DocTable.Cell(blocks: [para("42")])]])
    let triangle: [VectorNode] = [.path([.move(VectorPoint(0, 100)), .line(VectorPoint(50, 0)), .line(VectorPoint(100, 100)), .close],
                                        fill: .solid(VectorColour(red: 0, green: 0.5, blue: 1)), stroke: nil)]
    let one = Slide(title: "Quarterly review", shapes: [
        SlideShape(box: LayoutBox(x: 60, y: 140, width: 500, height: 150), content: .text(bullets)),
        SlideShape(box: LayoutBox(x: 60, y: 320, width: 500, height: 60), content: .text([.paragraph(styledRun, DocParagraphStyle(alignment: .centre))])),
        SlideShape(box: LayoutBox(x: 600, y: 140, width: 100, height: 100), content: .vector(triangle)),
    ], background: VectorColour(red: 0.95, green: 0.95, blue: 0.9), notes: "Remember the numbers.\nPause for questions.")
    let two = Slide(title: "Data", shapes: [
        SlideShape(box: LayoutBox(x: 60, y: 140, width: 400, height: 80), content: .text([.table(table)])),
        SlideShape(box: LayoutBox(x: 500, y: 140, width: 160, height: 120), content: .picture(officePixels(width: 4, height: 3))),
    ])
    let hidden = Slide(title: "Backup slide", shapes: [SlideShape(box: LayoutBox(x: 60, y: 140, width: 400, height: 40), content: .text([para("Hidden text")]))], isHidden: true)
    return Deck(size: VectorSize(width: 720, height: 405), slides: [one, two, hidden],
                theme: DeckTheme(headingFont: "Georgia", bodyFont: "Arial", accents: ["#112233", "#445566", "#778899", "#AABBCC", "#DDEEFF", "#FF00FF"]))
}

/// A hand-made xlsx with a shared formula, an inline string and a boolean, in the shape Excel writes them; `sheet` and
/// `styles` replace the worksheet and add a style sheet.
private func officeHandMadeXLSX(sheet: String? = nil, styles: String? = nil) -> Data {
    var zip = ZipWriter()
    zip.add("[Content_Types].xml", #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/></Types>"#)
    zip.add("_rels/.rels", #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)
    zip.add("xl/workbook.xml", #"<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>"#)
    zip.add("xl/_rels/workbook.xml.rels", #"<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#)
    zip.add("xl/worksheets/sheet1.xml", sheet ?? #"<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1"><v>1</v></c><c r="B1"><f t="shared" ref="B1:B3" si="0">A1*2+$A$1</f><v>3</v></c><c r="C1" t="inlineStr"><is><t>note</t></is></c><c r="D1" t="b"><v>1</v></c></row><row r="2"><c r="A2"><v>2</v></c><c r="B2"><f t="shared" si="0"/><v>6</v></c></row><row r="3"><c r="A3"><v>3</v></c><c r="B3"><f t="shared" si="0"/><v>9</v></c></row></sheetData></worksheet>"#)
    if let styles { zip.add("xl/styles.xml", styles) }
    return zip.finish()
}

/// Packages whose numbers are hostile where the readers turn them into counts, sizes and Ints, each read once as it is
/// by the fuzz case: rows and repeats near Int.max or below zero, a cell at the last column of 400 rows (a grid past the
/// cell limit), widths that each span the sheet, NaN and 1e300 through fraction, exponent and fraction-of-a-second
/// formats, digit counts of 10¹¹, table spans and list numbering near Int.max, and an arc of 1e308 degrees.
private func officeHostileXLSX() -> Data {
    let cols = String(repeating: #"<col min="1" max="16384" width="9"/>"#, count: 3_000)
    let far = (2...401).map { #"<row r="\#($0)"><c r="XFD\#($0)"><v>1</v></c></row>"# }.joined()
    let sheet = #"<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols>\#(cols)</cols><sheetData>"#
        + #"<row r="1"><c r="A1" s="1"><v>1e300</v></c><c r="B1" s="2"><v>1e307</v></c><c r="C1" s="3"><v>0.5</v></c><c r="D1" s="4"><v>0.5</v></c><c r="E1" s="1"><v>NaN</v></c></row>"#
        + far + #"<row r="9223372036854775807"/><row/><row/><row r="-9223372036854775808"><c><v>2</v></c></row></sheetData></worksheet>"#
    let styles = #"<?xml version="1.0"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="4">"#
        + ##"<numFmt numFmtId="164" formatCode="# ?/?"/><numFmt numFmtId="165" formatCode="0.00E+00%"/><numFmt numFmtId="166" formatCode="?/??????????????????????"/>"##
        + #"<numFmt numFmtId="167" formatCode="[h]:mm:ss.00000000000000000000"/></numFmts><cellXfs count="5"><xf numFmtId="0"/><xf numFmtId="164"/><xf numFmtId="165"/>"#
        + #"<xf numFmtId="166"/><xf numFmtId="167"/></cellXfs></styleSheet>"#
    return officeHandMadeXLSX(sheet: sheet, styles: styles)
}

private func officeHostileODS() -> Data {
    var zip = ZipWriter()
    zip.add("mimetype", "application/vnd.oasis.opendocument.spreadsheet", compress: false)
    zip.add("content.xml", #"<?xml version="1.0"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" "#
        + #"xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" "#
        + #"xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"><office:automatic-styles>"#
        + #"<number:number-style style:name="N1"><number:number number:min-integer-digits="99999999999" number:decimal-places="99999999999"/></number:number-style>"#
        + #"<style:style style:name="ce1" style:family="table-cell" style:data-style-name="N1"/></office:automatic-styles><office:body><office:spreadsheet><table:table table:name="S">"#
        + #"<table:table-column table:number-columns-repeated="-1"/><table:table-column table:number-columns-repeated="99999999"/><table:table-column table:number-columns-repeated="99999999"/>"#
        + #"<table:table-row table:number-rows-repeated="-5"><table:table-cell table:number-columns-repeated="-3" office:value-type="float" office:value="1" "#
        + #"table:number-columns-spanned="9223372036854775807" table:number-rows-spanned="9223372036854775807"><text:p>a<text:s text:c="-1"/></text:p></table:table-cell></table:table-row>"#
        + #"<table:table-row><table:table-cell office:value-type="date" office:date-value=""/><table:table-cell office:value-type="date" office:date-value="2024-01-01T99999999999999999999:00"/>"#
        + #"<table:table-cell table:style-name="ce1" office:value-type="float" office:value="2"><text:p>2</text:p></table:table-cell></table:table-row></table:table></office:spreadsheet></office:body></office:document-content>"#)
    return zip.finish()
}

private func officeHostilePPTX() -> Data {
    let written = PPTXWriter.write(officeSampleDeck(), title: "Hostile")
    guard let archive = try? ZipArchive(data: written) else { return written }
    var zip = ZipWriter()
    for entry in archive.entries {
        guard let data = try? archive.data(for: entry) else { continue }
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: "</a:path>", with: #"<a:arcTo wR="10" hR="10" stAng="0" swAng="1e308"/></a:path>"#)
            .replacingOccurrences(of: "<a:buChar[^>]*/>", with: #"<a:buAutoNum type="arabicPeriod" startAt="9223372036854775807"/>"#, options: .regularExpression)
            .replacingOccurrences(of: "<a:tc>", with: #"<a:tc gridSpan="9223372036854775807" rowSpan="9223372036854775807">"#)
        zip.add(entry.path, entry.path.hasSuffix(".xml") ? Data(text.utf8) : data)
    }
    return zip.finish()
}

/// The file names inside a ZIP, in the central directory's order.
private func officeNames(_ data: Data) -> [String] { (try? ZipArchive(data: data))?.entries.map(\.path) ?? [] }

/// A fuzz seed for a ZIP package (XLSX, ODS, PPTX, ODF): three inputs in four damage one member, unpacked with the module's
/// ZipArchive and re-zipped with its ZipWriter, so the damage reaches the XML readers; the rest damage the package's own
/// bytes for the ZIP reader.
private func officePackageSeed(_ name: String, _ ext: String, _ data: Data, nesting: [String] = ["<a>"]) -> FuzzSeed {
    let bytes = [UInt8](data)
    let archive = try? ZipArchive(data: data)
    let entries = (archive?.entries ?? []).compactMap { entry in (try? archive?.data(for: entry)).flatMap { $0 }.map { (path: entry.path, bytes: [UInt8]($0)) } }
    return FuzzSeed(name: name, ext: ext, bytes: bytes, mutate: { rng in
        guard Int.random(in: 0..<4, using: &rng) != 0 else { return Fuzz.mutate(bytes, nesting: nesting, using: &rng) }
        var zip = ZipWriter()
        for entry in Fuzz.mutateEntries(entries, nesting: nesting, using: &rng) { zip.add(entry.path, Data(entry.bytes), compress: entry.path != "mimetype") }
        return [UInt8](zip.finish())
    }, nesting: nesting)
}

@MainActor private func officeCSVWorkbook(_ data: Data, name: String = "t.csv") -> Workbook? {
    let url = officeFile(data, name)
    return officeWorkbook(officeReadWorkbook(.csvReader, "csv", url))
}

private func officeTexts(_ sheet: Sheet) -> [[String]] {
    sheet.rows.map { $0.map { cell in if case .text(let t) = cell.value { t } else { cell.displayText ?? "\(cell.value)" } } }
}

// MARK: - Cases

func registerOfficeKitTests() {
    SelfTest.cases.append(("OfficeKit.installs", {
        OfficeKitModule.install()
        let mine = EngineID.allCases.filter { $0.info.module == .officeKit }
        check(mine.count == 13, "OfficeKit owns 13 engine ids in the matrix, found \(mine.count)")
        for engine in mine { check(officeConverter(engine) != nil, "\(engine.rawValue) has a converter") }
        check(Services.converters.converters.allSatisfy { $0.availability() == .available }, "no OfficeKit converter needs a helper")
    }))

    // MARK: CSV
    SelfTest.cases.append(("OfficeKit.csvRFC4180", {
        OfficeKitModule.install()
        let csv = "name,note,n\r\n\"Smith, J\",\"said \"\"hi\"\"\",1\r\n\"multi\nline\",plain,2.50\r\n,\"\",\r\n"
        let sheet = officeCSVWorkbook(Data(csv.utf8))?.sheets.first
        check(sheet?.rows.count == 4, "four records (trailing newline makes no fifth): \(sheet?.rows.count ?? -1)")
        let texts = sheet.map(officeTexts) ?? []
        check(texts.dropFirst().first?.first == "Smith, J" && texts[1][1] == "said \"hi\"", "quoted comma and doubled quote: \(texts)")
        check(texts[2][0] == "multi\nline", "line break inside quotes")
        check(sheet?.rows[2][2].value == .number(2.5) && sheet?.rows[2][2].displayText == "2.50" && sheet?.rows[2][2].numberFormat == "0.00", "2.50 is a number shown as written")
        check(sheet?.rows[3].allSatisfy { $0.value == .empty || $0.value == .text("") } == true, "empty and quoted-empty fields")
        check(sheet?.name == "t", "sheet is named after the file")
    }))

    SelfTest.cases.append(("OfficeKit.csvTypedCells", {
        OfficeKitModule.install()
        let sheet = officeCSVWorkbook(Data("007,1.5,-3,2024-03-15,TRUE,1e3,12345678901234567890,2024-02-31,=SUM(A1)\n".utf8))?.sheets.first
        let row = sheet?.rows.first ?? []
        check(row.count == 9, "nine fields")
        check(row[0].value == .text("007"), "leading zeros stay text")
        check(row[1].value == .number(1.5) && row[2].value == .number(-3), "numbers")
        check(row[3].value == .date(officeDay) && row[3].displayText == "2024-03-15", "ISO date")
        check(row[4].value == .bool(true), "TRUE")
        check(row[5].value == .number(1000), "exponent")
        check(row[6].value == .text("12345678901234567890"), "more than 15 digits stays text")
        check(row[7].value == .text("2024-02-31"), "impossible date stays text")
        check(row[8].value == .text("=SUM(A1)") && row[8].formula == nil, "a CSV formula is text")
    }))

    SelfTest.cases.append(("OfficeKit.csvDelimiters", {
        OfficeKitModule.install()
        check(officeTexts(officeCSVWorkbook(Data("a;b;c\n1;2;3\n".utf8))!.sheets[0])[0] == ["a", "b", "c"], "semicolon detected")
        check(officeTexts(officeCSVWorkbook(Data("a\tb\tc\n1\t2\t3\n".utf8))!.sheets[0])[0] == ["a", "b", "c"], "tab detected")
        check(officeTexts(officeCSVWorkbook(Data("a|b|c\n1|2|3\n".utf8))!.sheets[0])[0] == ["a", "b", "c"], "pipe detected")
        check(officeTexts(officeCSVWorkbook(Data("a,b\n\"x;y\",2\n".utf8))!.sheets[0])[1][0] == "x;y", "a semicolon inside quotes does not split")
        check(officeCSVWorkbook(Data())?.sheets.first?.rows.isEmpty == true, "an empty file is an empty sheet")
    }))

    SelfTest.cases.append(("OfficeKit.csvEncodings", {
        OfficeKitModule.install()
        let text = "city,note\nCafé,naïve\n"
        @MainActor func first(_ data: Data) -> String? { officeCSVWorkbook(data).flatMap { officeTexts($0.sheets[0]).dropFirst().first?.first } }
        check(first(Data(text.utf8)) == "Café", "UTF-8")
        check(first(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)) == "Café", "UTF-8 with byte-order mark")
        check(first(Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!) == "Café", "UTF-16 LE with mark")
        check(first(Data([0xFE, 0xFF]) + text.data(using: .utf16BigEndian)!) == "Café", "UTF-16 BE with mark")
        check(first(text.data(using: .utf16LittleEndian)!) == "Café", "UTF-16 LE without mark")
        check(first(text.data(using: .windowsCP1252)!) == "Café", "Windows-1252")
        check(first(Data("a,b\n".utf8) + Data([0x81, 0x0A])) == "Å", "MacRoman when Windows-1252 has no such byte")
        let japanese = "名前,値\n日本語,漢字\n"
        check(first(japanese.data(using: .shiftJIS)!) == "日本語", "Shift-JIS")
    }))

    SelfTest.cases.append(("OfficeKit.csvWriter", {
        OfficeKitModule.install()
        var plain = CellStyle(); plain.bold = true
        let sheet = Sheet(name: "S", rows: [
            [officeCell(.text("a,b"), style: plain), officeCell(.text("say \"x\"")), officeCell(.text(" pad ")), officeCell(.text("l1\nl2"))],
            [officeCell(.number(1234.5), format: "#,##0.00", display: "1,234.50"), officeCell(.number(0.1 + 0.2)), officeCell(.date(officeDay), display: "15/03/2024"), officeCell(.bool(true))],
            [officeCell(.text("x"))],
        ])
        let book = Workbook(sheets: [sheet])
        let src = officeFile(Data(), "out.xlsx")
        @MainActor func write(_ options: [String: OptionValue]) -> (Data, StepOutput)? {
            guard let out = officeRun(.csvWriter, .workbook, "csv", .workbook(book), source: src, options: options), let url = officeURL(out),
                  let data = try? Data(contentsOf: url) else { return nil }
            return (data, out)
        }
        let displayed = write([:])
        check(displayed.map { String(decoding: $0.0, as: UTF8.self) } == "\"a,b\",\"say \"\"x\"\"\",\" pad \",\"l1\nl2\"\r\n\"1,234.50\",0.3,15/03/2024,TRUE\r\nx,,,\r\n",
              "RFC 4180 quoting, displayed values, equal-width records: \(displayed.map { String(decoding: $0.0, as: UTF8.self) } ?? "nil")")
        let raw = write(["values": "raw"]).map { String(decoding: $0.0, as: UTF8.self) }
        check(raw?.contains("1234.5,0.30000000000000004,2024-03-15,TRUE") == true, "raw values: \(raw ?? "nil")")
        check(write(["delimiter": "semicolon"]).map { String(decoding: $0.0, as: UTF8.self).hasPrefix("a,b;") } == true, "semicolon needs no quotes around a comma")
        check(write(["encoding": "utf8bom"])?.0.starts(with: [0xEF, 0xBB, 0xBF]) == true, "UTF-8 for Excel has a byte-order mark")
        let utf16 = write(["encoding": "utf16"])?.0
        check(utf16?.starts(with: [0xFF, 0xFE]) == true && String(data: utf16!.dropFirst(2), encoding: .utf16LittleEndian)?.hasPrefix("\"a,b\"") == true, "UTF-16 LE with mark")
        let decimal = write(["values": "raw", "decimalSeparator": ",", "delimiter": "semicolon"]).map { String(decoding: $0.0, as: UTF8.self) }
        check(decimal?.contains("1234,5;0,30000000000000004;2024-03-15") == true, "decimal comma: \(decimal ?? "nil")")
    }))

    SelfTest.cases.append(("OfficeKit.csvSheetsAndRoundTrip", {
        OfficeKitModule.install()
        let src = officeFile(Data(), "multi.xlsx")
        let one = Sheet(name: "One", rows: [[officeCell(.text("a")), officeCell(.number(1))]])
        let two = Sheet(name: "Two/2", rows: [[officeCell(.text("b")), officeCell(.number(2))]])
        let book = Workbook(sheets: [one, two])
        let zipped = officeURL(officeRun(.csvWriter, .workbook, "csv", .workbook(book), source: src))
        check(zipped?.pathExtension == "zip", "several sheets are zipped by default")
        check(zipped.flatMap { try? Data(contentsOf: $0) }.map(officeNames) == ["multi - One.csv", "multi - Two2.csv"], "one CSV per sheet: \(String(describing: zipped.flatMap { try? Data(contentsOf: $0) }.map(officeNames)))")
        let chosen = officeURL(officeRun(.csvWriter, .workbook, "csv", .workbook(book), source: src, options: ["sheet": "Two/2"]))
        check(chosen.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "b,2\r\n", "the Sheets option picks a sheet by name")
        let byNumber = officeURL(officeRun(.csvWriter, .workbook, "csv", .workbook(book), source: src, options: ["sheet": "1"]))
        check(byNumber.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "a,1\r\n", "or by number")
        let joined = officeURL(officeRun(.csvWriter, .workbook, "csv", .workbook(book), source: src, options: ["onePerSheet": false]))
        check(joined.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "a,1\r\n\r\nb,2\r\n", "or one file")
        // CSV → Workbook → CSV is the identity on well-formed files.
        let original = "id,price,when,note\r\n1,9.90,2024-03-15,\"a, b\"\r\n2,10.00,2024-03-16,\"x\"\"y\"\r\n"
        let url = officeFile(Data(original.utf8), "rt.csv")
        let book2 = officeWorkbook(officeReadWorkbook(.csvReader, "csv", url))
        let again = book2.flatMap { officeRun(.csvWriter, .workbook, "csv", .workbook($0), source: url) }.flatMap(officeURL).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        check(again == original, "CSV round trip: \(again ?? "nil")")
        let missing = ConversionError.failed("There’s no sheet “9” in this file.")
        let fake = StepContext(workFolder: officeWorkFolder("sel"), source: src, sourceFormat: "xlsx", targetFormat: "csv", options: OptionValues(["sheet": "9"]))
        if case .failure(let error)? = complete(10, { try await officeConverter(.csvWriter)!.run(Step(.csvWriter, .workbook, "csv"), input: .workbook(book), context: fake) }) {
            check((error as? ConversionError) == missing, "a missing sheet is reported: \(error)")
        } else { check(false, "a missing sheet throws") }
    }))

    // MARK: XLSX
    SelfTest.cases.append(("OfficeKit.xlsxRoundTrip", {
        OfficeKitModule.install()
        let book = officeSampleWorkbook()
        let src = officeFile(Data(), "sample.csv")
        guard let url = officeURL(officeRun(.xlsxWriter, .workbook, "xlsx", .workbook(book), source: src, options: ["formulas": "keep"])),
              let data = try? Data(contentsOf: url) else { return }
        let names = officeNames(data)
        check(names.first == "[Content_Types].xml" && names.contains("xl/workbook.xml") && names.contains("xl/styles.xml") && names.contains("xl/sharedStrings.xml"), "package parts \(names)")
        guard let out = officeReadWorkbook(.xlsxReader, "xlsx", url), let back = officeWorkbook(out) else { return }
        officeCompare(book, back, "xlsx")
        check(back.title == "Sample", "title")
        let main = back.sheets[0]
        check(main.rows[1][1].displayText == "1,234.50", "number format applied to the displayed text: \(main.rows[1][1].displayText ?? "nil")")
        check(main.rows[2][1].displayText == "25%", "percent shown")
        check(main.rows[3][0].displayText == "2024-03-15" && main.rows[3][1].displayText == "2024-03-15 10:30:00", "dates shown: \(main.rows[3][1].displayText ?? "nil")")
        check(main.rows[5][1].displayText == "$1,234.75", "currency shown")
        check(out.lossNotes.isEmpty, "nothing lost: \(out.lossNotes)")
    }))

    SelfTest.cases.append(("OfficeKit.xlsxValuesOnly", {
        OfficeKitModule.install()
        let src = officeFile(Data(), "v.csv")
        let out = officeRun(.xlsxWriter, .workbook, "xlsx", .workbook(officeSampleWorkbook()), source: src)
        check(out?.lossNotes.contains { $0.detail.contains("Formulas") } == true, "formulas dropped by default are reported")
        guard let url = officeURL(out), let back = officeWorkbook(officeReadWorkbook(.xlsxReader, "xlsx", url)) else { return }
        check(back.sheets[0].rows[1][3].formula == nil && back.sheets[0].rows[1][3].value == .number(3703.5), "the cached value stays")
    }))

    SelfTest.cases.append(("OfficeKit.xlsxSharedFormulasAndSheets", {
        OfficeKitModule.install()
        let url = officeFile(officeHandMadeXLSX(), "hand.xlsx")
        guard let book = officeWorkbook(officeReadWorkbook(.xlsxReader, "xlsx", url)) else { return }
        let rows = book.sheets[0].rows
        check(rows[0][1].formula == "A1*2+$A$1" && rows[1][1].formula == "A2*2+$A$1" && rows[2][1].formula == "A3*2+$A$1", "shared formula expanded: \(rows.map { $0[1].formula ?? "-" })")
        check(rows[1][1].value == .number(6), "cached result")
        check(rows[0][2].value == .text("note") && rows[0][3].value == .bool(true), "inline string and boolean")
        // Sheet names: invalid characters and duplicates.
        let tricky = Workbook(sheets: ["a/b", "A/B", "", String(repeating: "x", count: 40)].map { Sheet(name: $0, rows: [[officeCell(.number(1))]]) })
        guard let out = officeURL(officeRun(.xlsxWriter, .workbook, "xlsx", .workbook(tricky), source: url)),
              let back = officeWorkbook(officeReadWorkbook(.xlsxReader, "xlsx", out)) else { return }
        check(back.sheets.map(\.name) == ["ab", "AB 2", "Sheet", String(repeating: "x", count: 31)], "sheet names made valid and unique: \(back.sheets.map(\.name))")
    }))

    SelfTest.cases.append(("OfficeKit.xlsxErrors", {
        OfficeKitModule.install()
        let truncated = officeFile(Data(officeHandMadeXLSX().prefix(60)), "cut.xlsx")
        check(officeError(.xlsxReader, .format("xlsx"), .workbook, .file(truncated), source: truncated) == .damaged("xlsx"), "a cut file is damaged")
        let notZip = officeFile(Data("hello".utf8), "text.xlsx")
        check(officeError(.xlsxReader, .format("xlsx"), .workbook, .file(notZip), source: notZip) == .damaged("xlsx"), "text is damaged")
        let encrypted = officeFile(Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 600), "locked.xlsx")
        check(officeError(.xlsxReader, .format("xlsx"), .workbook, .file(encrypted), source: encrypted) == .passwordRequired("xlsx"), "an OLE2 container is a password-protected workbook")
    }))

    // MARK: ODS
    SelfTest.cases.append(("OfficeKit.odsRoundTrip", {
        OfficeKitModule.install()
        let book = officeSampleWorkbook()
        let src = officeFile(Data(), "sample.csv")
        guard let url = officeURL(officeRun(.odsWriter, .workbook, "ods", .workbook(book), source: src, options: ["formulas": "keep"])),
              let data = try? Data(contentsOf: url) else { return }
        let names = officeNames(data)
        check(names.first == "mimetype" && names.contains("content.xml") && names.contains("META-INF/manifest.xml"), "package parts \(names)")
        check(data.range(of: Data("application/vnd.oasis.opendocument.spreadsheet".utf8)).map { $0.lowerBound < 80 } == true, "the mimetype is first and stored")
        guard let out = officeReadWorkbook(.odsReader, "ods", url), let back = officeWorkbook(out) else { return }
        officeCompare(book, back, "ods")
        check(back.sheets[0].rows[1][1].displayText == "1,234.50", "number text kept: \(back.sheets[0].rows[1][1].displayText ?? "nil")")
        check(back.sheets[0].rows[4][2].value == .text("two\nlines"), "line break inside a cell")
        check(back.sheets[0].rows[4][1].value == .text("  padded  "), "edge spaces: \(back.sheets[0].rows[4][1].value)")
        check(out.lossNotes.isEmpty, "nothing lost: \(out.lossNotes)")
    }))

    SelfTest.cases.append(("OfficeKit.spreadsheetPipelines", {
        OfficeKitModule.install()
        // XLSX → ODS → XLSX → CSV, and CSV → XLSX → CSV: values identical as displayed.
        let src = officeFile(Data(), "chain.csv")
        let book = officeSampleWorkbook()
        @MainActor func csv(_ b: Workbook) -> String? {
            officeRun(.csvWriter, .workbook, "csv", .workbook(b), source: src, options: ["sheet": "1"]).flatMap(officeURL).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        guard let xlsx = officeURL(officeRun(.xlsxWriter, .workbook, "xlsx", .workbook(book), source: src, options: ["formulas": "keep"])),
              let a = officeWorkbook(officeReadWorkbook(.xlsxReader, "xlsx", xlsx)),
              let ods = officeURL(officeRun(.odsWriter, .workbook, "ods", .workbook(a), source: src, options: ["formulas": "keep"])),
              let b = officeWorkbook(officeReadWorkbook(.odsReader, "ods", ods)),
              let xlsx2 = officeURL(officeRun(.xlsxWriter, .workbook, "xlsx", .workbook(b), source: src, options: ["formulas": "keep"])),
              let c = officeWorkbook(officeReadWorkbook(.xlsxReader, "xlsx", xlsx2)) else { return }
        let first = csv(a), last = csv(c)
        check(first != nil && first == last, "XLSX → ODS → XLSX shows the same cells:\n\(first ?? "nil")\n\(last ?? "nil")")
        officeCompare(book, c, "chain")
        let table = "Date,Amount,Rate\r\n2024-01-05,\"1,200.50\",0.5\r\n2024-02-06,7,12\r\n"
        let tableURL = officeFile(Data(table.utf8), "table.csv")
        guard let t = officeWorkbook(officeReadWorkbook(.csvReader, "csv", tableURL)),
              let tx = officeURL(officeRun(.xlsxWriter, .workbook, "xlsx", .workbook(t), source: tableURL)),
              let t2 = officeWorkbook(officeReadWorkbook(.xlsxReader, "xlsx", tx)) else { return }
        check(csv(t2) == csv(t), "CSV → XLSX → CSV identical as displayed")
        check(t2.sheets[0].rows[1][0].displayText == "2024-01-05", "date survives")
    }))

    // MARK: XLS
    SelfTest.cases.append(("OfficeKit.xlsReader", {
        OfficeKitModule.install()
        // WP0b's libxls smoke fixture (written by xlwt): two sheets, text, numbers, UTF-8.
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/vendor/smoke/fixture.xls")
        guard FileManager.default.fileExists(atPath: fixture.path) else { print("  (no xls fixture; skipped)"); return }
        guard let out = officeReadWorkbook(.xlsReader, "xls", fixture), let book = officeWorkbook(out) else { return }
        check(book.sheets.map(\.name) == ["Data", book.sheets.last?.name ?? ""] && book.sheets.count == 2, "two sheets \(book.sheets.map(\.name))")
        let rows = book.sheets[0].rows
        check(rows.count == 2 && rows[0][0].value == .text("Hello") && rows[1][0].value == .text("World"), "text cells: \(rows)")
        check(rows[0][1].value == .number(42) && rows[1][1].value == .number(3.5), "number cells")
        check(book.sheets[1].rows.first?.first?.value == .text("Caf\u{e9} \u{fc}ber"), "UTF-16 strings: \(String(describing: book.sheets[1].rows.first?.first?.value))")
        let garbage = officeFile(Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 1024), "bad.xls")
        check(officeError(.xlsReader, .format("xls"), .workbook, .file(garbage), source: garbage) == .damaged("xls"), "an empty container is damaged")
    }))

    // MARK: Decks
    SelfTest.cases.append(("OfficeKit.pptxWriteReadRender", {
        OfficeKitModule.install()
        let deck = officeSampleDeck()
        let src = officeFile(Data(), "talk.pdf")
        guard let url = officeURL(officeRun(.pptxWriter, .deck, "pptx", .deck(deck), source: src)), let data = try? Data(contentsOf: url) else { return }
        let names = officeNames(data)
        for part in ["ppt/presentation.xml", "ppt/slides/slide1.xml", "ppt/slideMasters/slideMaster1.xml", "ppt/theme/theme1.xml", "ppt/notesSlides/notesSlide1.xml",
                     "ppt/notesMasters/notesMaster1.xml", "ppt/media/image1.png"] { check(names.contains(part), "\(part) is in the package") }

        guard let read = officeRun(.slideReader, "pptx", .docModel, .file(url), source: url), case .doc(let doc) = read.value else { return }
        let text = officeText(doc.blocks)
        check(text.contains("Quarterly review") && text.contains("First point\nSecond point\nThird point"), "slide 1 title and bullets: \(text)")
        check(text.contains("Bold red and a link"), "styled runs and link text")
        check(text.contains("Name|Value\nAlpha|42"), "table text")
        check(!text.contains("Hidden text") && !text.contains("Backup slide"), "hidden slides are left out")
        check(!text.contains("Remember the numbers"), "notes are off by default")
        check(doc.blocks.contains { if case .heading(1, let t) = $0 { officeText([.heading(level: 1, t)]) == "Data" } else { false } }, "each slide's title is a heading")
        check(doc.blocks.contains { if case .figure = $0 { true } else { false } } && doc.resources.values.contains { $0.starts(with: [0x89, 0x50, 0x4E, 0x47]) }, "the picture becomes a figure with PNG data")
        check(doc.blocks.contains { if case .list(false, _, let items) = $0 { items.count == 3 } else { false } }, "bullets are a list of three")

        let withNotes = officeRun(.slideReader, "pptx", .docModel, .file(url), source: url, options: ["notes": "notesPages", "hiddenSlides": true])
        if case .doc(let full)? = withNotes?.value {
            let fullText = officeText(full.blocks)
            check(fullText.contains("Remember the numbers.\nPause for questions.") && fullText.contains("Hidden text"), "notes and hidden slides on request")
        } else { check(false, "second read") }

        // PDF: one page per visible slide, at the slide's size, with real text.
        guard let pdfURL = officeURL(officeRun(.slideRenderer, "pptx", "pdf", .file(url), source: url)), let pdf = PDFDocument(url: pdfURL) else { check(false, "pdf"); return }
        check(pdf.pageCount == 2, "two visible slides \(pdf.pageCount)")
        check(abs((pdf.page(at: 0)?.bounds(for: .mediaBox).width ?? 0) - 720) < 0.5 && abs((pdf.page(at: 0)?.bounds(for: .mediaBox).height ?? 0) - 405) < 0.5, "page is the slide's size")
        let pdfText = pdf.string ?? ""
        check(pdfText.contains("Quarterly review") && pdfText.contains("First point") && pdfText.contains("Alpha"), "the PDF has the slides' text: \(pdfText.prefix(120))")
        let all = officeURL(officeRun(.slideRenderer, "pptx", "pdf", .file(url), source: url, options: ["hiddenSlides": true]))
        check(all.flatMap { PDFDocument(url: $0) }?.pageCount == 3, "hidden slides on request")
        let range = officeURL(officeRun(.slideRenderer, "pptx", "pdf", .file(url), source: url, options: ["pages": "2"]))
        check(range.flatMap { PDFDocument(url: $0) }?.pageCount == 1, "page range")
    }))

    SelfTest.cases.append(("OfficeKit.pptxVariantsAndErrors", {
        OfficeKitModule.install()
        let src = officeFile(Data(), "variants.pdf")
        let locked = officeFile(Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 600), "locked.pptx")
        check(officeError(.slideReader, .format("pptx"), .docModel, .file(locked), source: locked) == .passwordRequired("pptx"), "an OLE2 container is a password-protected deck")
        let junk = officeFile(Data("nope".utf8), "junk.pptx")
        check(officeError(.slideRenderer, .format("pptx"), .format("pdf"), .file(junk), source: junk) == .damaged("pptx"), "junk is damaged")
        let empty = Deck(size: VectorSize(width: 720, height: 540), slides: [])
        if let url = officeURL(officeRun(.pptxWriter, .deck, "pptx", .deck(empty), source: src)), let doc = officeRun(.slideReader, "pptx", .docModel, .file(url), source: url) {
            check(doc.lossNotes.isEmpty, "an empty deck still writes and reads")
        }
    }))

    // MARK: ODF pictures
    SelfTest.cases.append(("OfficeKit.odfPicture", {
        OfficeKitModule.install()
        let image = officePixels(width: 5, height: 4)
        let src = officeFile(Data(), "pic.png")
        guard let url = officeURL(officeRun(.odfWriter, .imageAsset, "odd", .image(image), source: src)), let data = try? Data(contentsOf: url) else { return }
        let names = officeNames(data)
        check(names.first == "mimetype" && names.contains("Pictures/image1.png") && names.contains("content.xml"), "package parts \(names)")
        guard let read = officeRun(.odfReader, "odd", .imageAsset, .file(url), source: url), case .image(let back) = read.value, let frame = back.frames.first else { return }
        check(frame.width == 5 && frame.height == 4, "size \(frame.width)×\(frame.height)")
        if case .rgba8(let pixels, _) = frame.pixels, case .rgba8(let original, _) = image.frames[0].pixels { check(pixels == original, "pixels identical (PNG is lossless)") }
        else { check(false, "pixel format") }
        let animated = ImageAsset(frames: [image.frames[0], image.frames[0]])
        check(officeRun(.odfWriter, .imageAsset, "odd", .image(animated), source: src)?.lossNotes.contains { $0.kind == .animationDropped } == true, "animation dropped is reported")
        let junk = officeFile(Data("x".utf8), "junk.odd")
        check(officeError(.odfReader, .format("odd"), .imageAsset, .file(junk), source: junk) == .damaged("odd"), "junk is damaged")
    }))

    // MARK: Repackaging
    SelfTest.cases.append(("OfficeKit.ooxmlRepackage", {
        OfficeKitModule.install()
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="bin" ContentType="application/vnd.ms-office.vbaProject"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.ms-excel.sheet.macroEnabled.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>"#)
        zip.add("_rels/.rels", #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#)
        zip.add("xl/_rels/workbook.xml.rels", #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.microsoft.com/office/2006/relationships/vbaProject" Target="vbaProject.bin"/></Relationships>"#)
        zip.add("xl/workbook.xml", "<workbook/>")
        zip.add("xl/worksheets/sheet1.xml", "<worksheet>keep me</worksheet>")
        zip.add("xl/vbaProject.bin", Data([1, 2, 3, 4]))
        let url = officeFile(zip.finish(), "macros.xlsm")
        guard let out = officeRun(.ooxmlRepackage, .format("xlsm"), .format("xlsx"), .file(url), source: url), let result = officeURL(out), let data = try? Data(contentsOf: result) else { return }
        check(out.lossNotes.contains { $0.kind == .macrosDropped }, "macros dropped is reported")
        let names = officeNames(data)
        check(!names.contains("xl/vbaProject.bin") && names.contains("xl/worksheets/sheet1.xml") && names.first == "[Content_Types].xml", "macro part gone, others kept \(names)")
        let text = String(decoding: data, as: UTF8.self)
        check(!text.contains("macroEnabled") && !text.contains("vbaProject"), "content types and relationships are clean")
        check(result.pathExtension == "xlsx", "named .xlsx")
    }))

    SelfTest.cases.append(("OfficeKit.cancellation", {
        OfficeKitModule.install()
        let src = officeFile(Data(), "c.csv")
        let context = StepContext(workFolder: officeWorkFolder("cancel"), source: src, sourceFormat: "csv", targetFormat: "xlsx", isCancelled: { true })
        if case .failure(let error)? = complete(10, { try await officeConverter(.xlsxWriter)!.run(Step(.xlsxWriter, .workbook, "xlsx"), input: .workbook(Workbook(sheets: [])), context: context) }) {
            check((error as? ConversionError) == .cancelled, "cancelled before any work: \(error)")
        } else { check(false, "a cancelled step throws") }
    }))
    SelfTest.cases.append(("OfficeKit.damagedInputNeverCrashes", {
        OfficeKitModule.install()
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let book = officeSampleWorkbook()
        var seeds = [officePackageSeed("xlsx", "xlsx", XLSXWriter.write(book)), officePackageSeed("xlsx-hand", "xlsx", officeHandMadeXLSX()),
                     officePackageSeed("ods", "ods", ODSWriter.write(book)), officePackageSeed("pptx", "pptx", PPTXWriter.write(officeSampleDeck(), title: "Fuzz"))]
        if let picture = try? ODFPicture.write(officePixels(width: 5, height: 4)) { seeds.append(officePackageSeed("odd", "odd", picture)) }
        for (name, ext) in [("Tests/Corpus/generated/sample.xlsx", "xlsx"), ("Tests/Corpus/generated/sample.csv", "csv"), ("scripts/vendor/smoke/fixture.xls", "xls")] {
            guard let data = try? Data(contentsOf: repository.appendingPathComponent(name)) else { check(false, "\(name) is in the repository"); continue }
            seeds.append(ext == "xlsx" ? officePackageSeed("corpus-xlsx", ext, data) : FuzzSeed(name: "corpus-\(ext)", ext: ext, bytes: [UInt8](data), nesting: ["\""]))
        }
        // The hostile ODS and PPTX are fuzzed too; the XLSX, whose grid fills the cell limit, is read once (it is slow).
        let hostile = [officePackageSeed("hostile-ods", "ods", officeHostileODS()), officePackageSeed("hostile-pptx", "pptx", officeHostilePPTX())]
        let folder = officeWorkFolder("fuzz")
        /// Every reader the app runs on the format: a thrown error is a clean failure, only a trap or a hang is not.
        @MainActor func read(_ url: URL, _ ext: String) async {
            let format = FormatID(ext)
            let steps: [(EngineID, StepEndpoint)] = switch ext {
            case "csv": [(.csvReader, .workbook)]
            case "xlsx": [(.xlsxReader, .workbook)]
            case "ods": [(.odsReader, .workbook)]
            case "xls": [(.xlsReader, .workbook)]
            case "odd": [(.odfReader, .imageAsset)]
            default: [(.slideReader, .docModel), (.slideRenderer, "pdf")]
            }
            for (engine, to) in steps {
                let context = StepContext(workFolder: folder, source: url, sourceFormat: format, targetFormat: FormatID(to.description))
                _ = try? await officeConverter(engine)!.run(Step(engine, .format(format), to), input: .file(url), context: context)
            }
        }
        for (name, ext, data) in hostile.map({ ($0.name, $0.ext, Data($0.bytes)) }) + [("hostile-xlsx", "xlsx", officeHostileXLSX())] {
            let url = officeFile(data, "hostile.\(ext)")
            check(complete(30, { await read(url, ext) }) != nil, "\(name) is read in time")
        }
        let ran = fuzzNeverCrashes("OfficeKit.damagedInputNeverCrashes", seeds: seeds + hostile, count: 70) { url, seed in await read(url, seed.ext) }
        check(ran == 70 * 10 && seeds.count == 8, "every damaged input was handled without a crash (\(ran))")
    }))
}
