#!/usr/bin/env swift
// Generates the small committed fixtures of the quality bench (quality §9) into Tests/Corpus/generated/. Deterministic (sample.pdf's dates and /ID are pinned): the same script gives the same bytes, so a diff after re-running means the script changed.
//
//     swift scripts/make-fixtures.swift [output-folder]
//
// Needs only the Command Line Tools: Foundation, CoreGraphics, CoreText, ImageIO and /usr/bin/zip. To add fixtures for a kit,
// add a function below and call it from the bottom; keep the whole folder under 40 MB.
import CoreGraphics
import CoreText
import Foundation
import ImageIO

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                                          : root.appendingPathComponent("Tests/Corpus/generated", isDirectory: true)
try? FileManager.default.removeItem(at: out)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func write(_ name: String, _ text: String) throws { try Data(text.utf8).write(to: out.appendingPathComponent(name)) }
func write(_ name: String, _ data: Data) throws { try data.write(to: out.appendingPathComponent(name)) }

// MARK: Zip packages (DOCX, XLSX, ODT, EPUB, CBZ)

/// Builds a ZIP from `files` (path → data) with /usr/bin/zip, `stored` entries first and uncompressed (EPUB's and ODF's
/// `mimetype`), fixed modification times so the bytes repeat.
func zip(_ name: String, stored: [(String, Data)] = [], files: [(String, Data)]) throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("make-fixtures-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let target = out.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: target)
    func stage(_ entries: [(String, Data)]) throws -> [String] {
        try entries.map { path, data in
            let url = scratch.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: url.path)
            return path
        }
    }
    func run(_ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = scratch
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "zip", code: Int(p.terminationStatus)) }
    }
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    if !stored.isEmpty { try run(["-X", "-q", "-0", target.path] + stage(stored)) }
    try run(["-X", "-q", "-9", target.path] + stage(files))
}

func xmlEscape(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }

// MARK: Images

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func bitmap(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> CGImage {
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    draw(c)
    return c.makeImage()!
}

func png(_ name: String, _ image: CGImage) throws {
    let data = NSMutableData()
    let d = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, image, nil)
    guard CGImageDestinationFinalize(d) else { throw NSError(domain: "png", code: 1) }
    try write(name, data as Data)
}

func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor { CGColor(colorSpace: sRGB, components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1])! }

func images() throws {
    // A smooth ramp in both axes: banding and colour shifts show.
    try png("gradient-256.png", bitmap(256, 256) { c in
        for y in 0..<256 { for x in 0..<256 { c.setFillColor(rgb(x, y, (x + y) / 2)); c.fill(CGRect(x: x, y: 255 - y, width: 1, height: 1)) } }
    })
    // The 24 ColorChecker patches (sRGB values as published by X-Rite / BabelColor, D50 adapted), 6 x 4.
    let patches: [(Int, Int, Int)] = [
        (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
        (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
        (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
        (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52)]
    try png("colorchecker-24.png", bitmap(240, 160) { c in
        for (i, p) in patches.enumerated() { c.setFillColor(rgb(p.0, p.1, p.2)); c.fill(CGRect(x: (i % 6) * 40, y: 120 - (i / 6) * 40, width: 40, height: 40)) }
    })
    // 1-pixel black/white checkerboard: gamma-correct scaling must give 187–188, never 127/128.
    try png("checker-512.png", bitmap(512, 512) { c in
        for y in 0..<512 { for x in 0..<512 { let v = (x + y) % 2 == 0 ? 255 : 0; c.setFillColor(rgb(v, v, v)); c.fill(CGRect(x: x, y: y, width: 1, height: 1)) } }
    })
    // An anti-aliased logo with alpha: a red disc with a soft edge on transparency.
    try png("logo-alpha-128.png", bitmap(128, 128) { c in
        c.setFillColor(rgb(200, 30, 40)); c.fillEllipse(in: CGRect(x: 14, y: 14, width: 100, height: 100))
        c.setFillColor(rgb(255, 255, 255)); c.fillEllipse(in: CGRect(x: 44, y: 44, width: 40, height: 40))
    })
    // SMPTE-style colour bars (75 % bars, then the reverse castellations and the PLUGE strip), 640 x 360.
    let top: [(Int, Int, Int)] = [(191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0), (191, 0, 191), (191, 0, 0), (0, 0, 191)]
    try png("smpte-bars-640x360.png", bitmap(640, 360) { c in
        let w = 640.0 / 7
        for (i, p) in top.enumerated() { c.setFillColor(rgb(p.0, p.1, p.2)); c.fill(CGRect(x: Double(i) * w, y: 120, width: w + 1, height: 240)) }
        let mid: [(Int, Int, Int)] = [(0, 0, 191), (19, 19, 19), (191, 0, 191), (19, 19, 19), (0, 191, 191), (19, 19, 19), (191, 191, 191)]
        for (i, p) in mid.enumerated() { c.setFillColor(rgb(p.0, p.1, p.2)); c.fill(CGRect(x: Double(i) * w, y: 90, width: w + 1, height: 30)) }
        let bottom: [(Int, Int, Int)] = [(0, 33, 76), (255, 255, 255), (50, 0, 106), (19, 19, 19), (9, 9, 9), (19, 19, 19), (29, 29, 29)]
        for (i, p) in bottom.enumerated() { c.setFillColor(rgb(p.0, p.1, p.2)); c.fill(CGRect(x: Double(i) * w, y: 0, width: w + 1, height: 90)) }
    })
}

// MARK: Audio

func wav(_ name: String, rate: Int, channels: Int, samples: [Double]) throws {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = samples.count * channels * 2
    d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes)); d.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(rate)); u32(UInt32(rate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
    for s in samples { let v = Int16(max(-32768, min(32767, (s * 32767).rounded()))); for _ in 0..<channels { u16(UInt16(bitPattern: v)) } }
    try write(name, d)
}

func audio() throws {
    // 997 Hz, -1 dBFS, 3 s: the AES17 tone for THD+N.
    try wav("tone-997-48k.wav", rate: 48000, channels: 1, samples: (0..<48000 * 3).map { pow(10, -1.0 / 20) * sin(2 * .pi * 997 * Double($0) / 48000) })
    // EBU Tech 3341 case 1: stereo 1 kHz at -23 dBFS reads -23.0 LUFS.
    try wav("tone-1k-minus23-stereo.wav", rate: 48000, channels: 2, samples: (0..<48000 * 10).map { pow(10, -23.0 / 20) * sin(2 * .pi * 1000 * Double($0) / 48000) })
    // A logarithmic sweep 20 Hz – 20 kHz, 4 s, -6 dBFS.
    let rate = 44100.0, seconds = 4.0, f0 = 20.0, f1 = 20000.0, k = log(f1 / f0)
    try wav("sweep-20-20k-44k.wav", rate: 44100, channels: 1, samples: (0..<Int(rate * seconds)).map {
        0.5 * sin(2 * .pi * f0 * seconds / k * (exp(k * Double($0) / (rate * seconds)) - 1))
    })
}

// MARK: Text documents

let markdown = """
# Super Converter sample

A short paragraph with *emphasis*, **strong text**, `inline code` and a [link](https://example.com/page).

## Lists

- First bullet
- Second bullet with **bold**
- Third bullet

1. One
2. Two
3. Three

## A table

| Format | Kit | Pages |
|--------|-----|------:|
| DOCX | DocKit | 12 |
| EPUB | EbookKit | 340 |

## Code and quotes

> Quality is measured, not eyeballed.

```
let answer = 42
```

Ünïcödé text: café, naïve, Zürich, 東京.

"""

func documents() throws {
    try write("sample.md", markdown)
    try write("sample.txt", "Super Converter sample\n\nA plain text file with two paragraphs.\n\nSecond paragraph: café, naïve, Zürich.\n")
    try write("sample.html", """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><title>Super Converter sample</title></head><body>
    <h1>Super Converter sample</h1>
    <p>A short paragraph with <em>emphasis</em>, <strong>strong text</strong> and a <a href="https://example.com/page">link</a>.</p>
    <h2>Lists</h2><ul><li>First bullet</li><li>Second bullet</li><li>Third bullet</li></ul>
    <h2>A table</h2><table><tr><th>Format</th><th>Kit</th></tr><tr><td>DOCX</td><td>DocKit</td></tr><tr><td>EPUB</td><td>EbookKit</td></tr></table>
    </body></html>
    """)
    try write("sample.csv", "Name,Quantity,Price,Note\nWidget,12,3.50,\"Quoted, with comma\"\nGadget,7,12.25,plain\nGizmo,150,0.99,\"multi\nline\"\n")
    try write("sample.rst", """
    Super Converter sample
    ======================

    A paragraph with *emphasis*, **strong text** and ``code``.

    Lists
    -----

    * First bullet
    * Second bullet

    """)
    try write("sample.tex", """
    \\documentclass{article}
    \\begin{document}
    \\section{Super Converter sample}
    A paragraph with \\emph{emphasis} and \\textbf{strong text}.
    \\begin{itemize}
    \\item First bullet
    \\item Second bullet
    \\end{itemize}
    \\end{document}

    """)
    try write("sample.rtf", "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica;}}\\f0\\fs24 {\\b Super Converter sample}\\par A paragraph with {\\i emphasis} and {\\b strong text}.\\par Second paragraph.\\par}")

    // DOCX: heading, paragraph with run formatting, a table.
    let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
    func p(_ text: String, style: String? = nil, bold: Bool = false, italic: Bool = false) -> String {
        "<w:p>\(style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? "")<w:r>\(bold || italic ? "<w:rPr>\(bold ? "<w:b/>" : "")\(italic ? "<w:i/>" : "")</w:rPr>" : "")<w:t xml:space=\"preserve\">\(xmlEscape(text))</w:t></w:r></w:p>"
    }
    func cell(_ t: String) -> String { "<w:tc><w:tcPr><w:tcW w:w=\"2400\" w:type=\"dxa\"/></w:tcPr>\(p(t))</w:tc>" }
    let body = p("Super Converter sample", style: "Heading1") + p("A short paragraph of ordinary text.") + p("Strong words.", bold: true) + p("Emphasised words.", italic: true)
        + p("A table", style: "Heading2")
        + "<w:tbl><w:tblPr><w:tblW w:w=\"4800\" w:type=\"dxa\"/><w:tblBorders><w:top w:val=\"single\" w:sz=\"4\"/><w:bottom w:val=\"single\" w:sz=\"4\"/><w:insideH w:val=\"single\" w:sz=\"4\"/></w:tblBorders></w:tblPr><w:tblGrid><w:gridCol w:w=\"2400\"/><w:gridCol w:w=\"2400\"/></w:tblGrid>"
        + "<w:tr>\(cell("Format"))\(cell("Kit"))</w:tr><w:tr>\(cell("DOCX"))\(cell("DocKit"))</w:tr><w:tr>\(cell("EPUB"))\(cell("EbookKit"))</w:tr></w:tbl>"
        + p("Closing paragraph after the table.")
    let styles = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:styles \(ns)><w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:outlineLvl w:val=\"0\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"32\"/></w:rPr></w:style><w:style w:type=\"paragraph\" w:styleId=\"Heading2\"><w:name w:val=\"heading 2\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:outlineLvl w:val=\"1\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"26\"/></w:rPr></w:style></w:styles>"
    try zip("sample.docx", files: [
        ("[Content_Types].xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/><Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>".utf8)),
        ("_rels/.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".utf8)),
        ("word/_rels/document.xml.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>".utf8)),
        ("word/document.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:document \(ns)><w:body>\(body)<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>".utf8)),
        ("word/styles.xml", Data(styles.utf8)),
    ])

    // ODT: the same content, flat styles.
    let odfNS = "xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" xmlns:table=\"urn:oasis:names:tc:opendocument:xmlns:table:1.0\" xmlns:style=\"urn:oasis:names:tc:opendocument:xmlns:style:1.0\" xmlns:fo=\"urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0\" office:version=\"1.3\""
    try zip("sample.odt", stored: [("mimetype", Data("application/vnd.oasis.opendocument.text".utf8))], files: [
        ("META-INF/manifest.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>".utf8)),
        ("content.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content \(odfNS)><office:body><office:text><text:h text:outline-level=\"1\">Super Converter sample</text:h><text:p>A short paragraph of ordinary text.</text:p><text:p>Second paragraph, with <text:span>spans</text:span>.</text:p><table:table table:name=\"T1\"><table:table-column table:number-columns-repeated=\"2\"/><table:table-row><table:table-cell><text:p>Format</text:p></table:table-cell><table:table-cell><text:p>Kit</text:p></table:table-cell></table:table-row><table:table-row><table:table-cell><text:p>ODT</text:p></table:table-cell><table:table-cell><text:p>DocKit</text:p></table:table-cell></table:table-row></table:table></office:text></office:body></office:document-content>".utf8)),
    ])
}

// MARK: Spreadsheet

func spreadsheet() throws {
    let strings = ["Name", "Quantity", "Price", "Total", "Widget", "Gadget", "Gizmo", "Summary"]
    let rows = ["<row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"B1\" t=\"s\"><v>1</v></c><c r=\"C1\" t=\"s\"><v>2</v></c><c r=\"D1\" t=\"s\"><v>3</v></c></row>",
                "<row r=\"2\"><c r=\"A2\" t=\"s\"><v>4</v></c><c r=\"B2\"><v>12</v></c><c r=\"C2\"><v>3.5</v></c><c r=\"D2\"><f>B2*C2</f><v>42</v></c></row>",
                "<row r=\"3\"><c r=\"A3\" t=\"s\"><v>5</v></c><c r=\"B3\"><v>7</v></c><c r=\"C3\"><v>12.25</v></c><c r=\"D3\"><f>B3*C3</f><v>85.75</v></c></row>",
                "<row r=\"4\"><c r=\"A4\" t=\"s\"><v>6</v></c><c r=\"B4\"><v>150</v></c><c r=\"C4\"><v>0.99</v></c><c r=\"D4\"><f>B4*C4</f><v>148.5</v></c></row>"]
    let main = "xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""
    try zip("sample.xlsx", files: [
        ("[Content_Types].xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/><Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/></Types>".utf8)),
        ("_rels/.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>".utf8)),
        ("xl/workbook.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><workbook \(main) xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Sales\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>".utf8)),
        ("xl/_rels/workbook.xml.rels", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>".utf8)),
        ("xl/worksheets/sheet1.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet \(main)><sheetData>\(rows.joined())</sheetData></worksheet>".utf8)),
        ("xl/sharedStrings.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><sst \(main) count=\"\(strings.count)\" uniqueCount=\"\(strings.count)\">\(strings.map { "<si><t>\($0)</t></si>" }.joined())</sst>".utf8)),
        ("xl/styles.xml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><styleSheet \(main)><fonts count=\"1\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font></fonts><fills count=\"2\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill></fills><borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/></cellXfs></styleSheet>".utf8)),
    ])
}

// MARK: E-books

func ebooks() throws {
    let chapter: (Int, String) -> String = { n, text in
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Chapter \(n)</title></head><body><h1>Chapter \(n)</h1><p>\(text)</p><p>Second paragraph of chapter \(n), with <em>emphasis</em>.</p></body></html>"
    }
    try zip("sample.epub", stored: [("mimetype", Data("application/epub+zip".utf8))], files: [
        ("META-INF/container.xml", Data("<?xml version=\"1.0\"?><container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>".utf8)),
        ("OEBPS/content.opf", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"id\">urn:uuid:5b1e2a3c-0000-4000-8000-000000000001</dc:identifier><dc:title>Super Converter sample book</dc:title><dc:creator>Quality Bench</dc:creator><dc:language>en</dc:language><meta property=\"dcterms:modified\">2024-01-01T00:00:00Z</meta></metadata><manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"c1\" href=\"ch1.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"c2\" href=\"ch2.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"c1\"/><itemref idref=\"c2\"/></spine></package>".utf8)),
        ("OEBPS/nav.xhtml", Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Contents</title></head><body><nav epub:type=\"toc\"><ol><li><a href=\"ch1.xhtml\">Chapter 1</a></li><li><a href=\"ch2.xhtml\">Chapter 2</a></li></ol></nav></body></html>".utf8)),
        ("OEBPS/ch1.xhtml", Data(chapter(1, "It was a quiet morning, and the converter had nothing to lose.").utf8)),
        ("OEBPS/ch2.xhtml", Data(chapter(2, "By noon every page had been typeset, measured, and checked.").utf8)),
    ])
    // A three-page comic: PNG pages that must pass through untouched.
    var pages: [(String, Data)] = []
    for i in 1...3 {
        let image = bitmap(100, 150) { c in
            c.setFillColor(rgb(40 * i, 120, 255 - 60 * i)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 150))
            c.setFillColor(rgb(255, 255, 255)); c.fill(CGRect(x: 10, y: 10 + 20 * i, width: 80, height: 20))
        }
        let data = NSMutableData()
        let d = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, image, nil); CGImageDestinationFinalize(d)
        pages.append((String(format: "page%03d.png", i), data as Data))
    }
    try zip("sample.cbz", files: pages)
}

// MARK: Typesetting (TypesetKit: LaTeX parity and the typographic lint, quality §3.7)

/// Markdown for TypesetKit's bench: prose in eight languages (hyphenation and line breaking), then one fixture per
/// structure LaTeX has rules for. Text written for the bench.
func typesetting() throws {
    let prose: [(String, String, [String])] = [
        ("en", "Line breaking", [
            "A paragraph is broken into lines by considering every feasible break at once and choosing the sequence whose total demerits are smallest. The method looks ahead to the end of the paragraph, so an awkward break near the bottom can change the very first line, which is why justified text set this way has an unusually even colour across the page.",
            "## Hyphenation\n\nHyphenation helps the optimiser when a long word would otherwise leave a loose line. Typographers generally prefer no more than two consecutive hyphenated lines, never a hyphen on the last full line of a page, and never a word broken after a single letter; the parameters reproduce those conventions numerically rather than by inspection.",
            "## Spacing\n\nInterword spaces stretch and shrink within limits taken from the font. After a full stop, question mark or exclamation mark the space is a little wider, except after abbreviations such as e.g. or after a capital initial, where an ordinary space keeps the reading rhythm intact.",
        ]),
        ("de", "Silbentrennung", [
            "Ein Absatz wird in Zeilen zerlegt, indem alle möglichen Umbrüche gleichzeitig betrachtet werden und jene Folge gewählt wird, deren Gesamtkosten am geringsten sind. Gerade im Deutschen mit seinen langen Zusammensetzungen wie Donaudampfschifffahrtsgesellschaft oder Haftpflichtversicherungsbedingungen ist eine gute Silbentrennung unverzichtbar.",
            "Die Wortzwischenräume dehnen und stauchen sich innerhalb fester Grenzen. Werden diese überschritten, entsteht eine unschöne Zeile, die der Algorithmus nach Möglichkeit vermeidet, indem er frühere Umbrüche verschiebt.",
        ]),
        ("fr", "La composition", [
            "Un paragraphe est découpé en lignes en examinant simultanément toutes les coupures possibles, puis en retenant la suite dont le coût total est le plus faible. Les mots longs, comme anticonstitutionnellement ou institutionnalisation, profitent particulièrement d’une bonne césure.",
            "Les espaces entre les mots s’étirent et se compriment dans des limites fixées par la fonte. La typographie française demande en outre des espaces fines avant certains signes de ponctuation ; ici, le texte reste simple et la composition suit les règles de LaTeX.",
        ]),
        ("es", "La composición", [
            "Un párrafo se divide en líneas considerando a la vez todos los cortes posibles y eligiendo la secuencia cuyo coste total es menor. Palabras largas como electroencefalografista o desafortunadamente se benefician de una buena división silábica.",
            "Los espacios entre palabras se estiran y se encogen dentro de los límites que fija la fuente, de modo que el gris de la página resulte uniforme y agradable a la vista.",
        ]),
        ("it", "La composizione", [
            "Un paragrafo viene diviso in righe considerando contemporaneamente tutte le interruzioni possibili e scegliendo la sequenza il cui costo complessivo è minimo. Parole lunghe come precipitevolissimevolmente traggono vantaggio da una buona sillabazione.",
            "Gli spazi tra le parole si allungano e si accorciano entro limiti stabiliti dal carattere, così che il grigio della pagina rimanga uniforme.",
        ]),
        ("nl", "Het zetten", [
            "Een alinea wordt in regels verdeeld door alle mogelijke afbrekingen tegelijk te bekijken en de reeks te kiezen met de laagste totale kosten. Lange samenstellingen zoals arbeidsongeschiktheidsverzekering of kinderdagverblijfmedewerker hebben baat bij een goede woordafbreking.",
            "De spaties tussen woorden rekken en krimpen binnen grenzen die het lettertype bepaalt, zodat de bladzijde een gelijkmatige grijswaarde krijgt.",
        ]),
        ("pt", "A composição", [
            "Um parágrafo é dividido em linhas considerando ao mesmo tempo todas as quebras possíveis e escolhendo a sequência cujo custo total é menor. Palavras longas como inconstitucionalissimamente ou otorrinolaringologista beneficiam de uma boa translineação.",
            "Os espaços entre as palavras esticam e encolhem dentro de limites definidos pela fonte, para que a mancha de texto fique uniforme.",
        ]),
        ("pl", "Skład tekstu", [
            "Akapit dzieli się na wiersze, rozważając jednocześnie wszystkie możliwe podziały i wybierając ten ciąg, którego łączny koszt jest najmniejszy. Długie wyrazy, takie jak konstantynopolitańczykowianeczka czy niezaprzeczalnie, korzystają z dobrego dzielenia.",
            "Odstępy między wyrazami rozciągają się i kurczą w granicach wyznaczonych przez krój pisma, dzięki czemu szarość kolumny jest równomierna.",
        ]),
    ]
    for (language, title, paragraphs) in prose {
        try write("typeset-prose-\(language).md", "---\nlang: \(language)\n---\n\n# \(title)\n\n" + paragraphs.joined(separator: "\n\n") + "\n")
    }
    try write("typeset-lists.md", """
    # Lists

    Lists are indented by 25 pt and their items are separated by a little stretchable space:

    - The first item is short.
    - The second item is long enough to wrap onto a second line, so its continuation lines up with the text of the item and not with the bullet.
      - A nested item takes an en dash as its label.
      - Another nested item.
    - The last item.

    Numbered lists count in arabic numerals, then letters:

    1. Measure the paragraph.
    2. Break it into lines.
       1. Try every feasible break.
       2. Keep the cheapest.
    3. Build the pages.

    """)
    try write("typeset-footnotes.md", """
    # Footnotes

    Footnotes are set in footnote size at the foot of the page that refers to them, below a short rule.[^rule] A page may carry several notes, and they take their room from the text above.[^room]

    The text then continues as usual, with a paragraph long enough to fill a few lines and to show that the footnotes do not disturb the baseline grid of the body.

    [^rule]: The rule is 0.4 pt thick and two fifths of the text width long.
    [^room]: TeX's page builder subtracts the height of every inserted note from the goal for the page.

    """)
    try write("typeset-tables.md", """
    # Tables

    Tables use three horizontal rules and no vertical ones, with numbers aligned on their decimal points.

    | Font | Design size | Space | Stretch |
    |:-----|------------:|------:|--------:|
    | LM Roman 10 | 10 | 3.33 | 1.67 |
    | LM Roman 12 | 12 | 3.26 | 1.63 |
    | LM Roman 17 | 17.28 | 3.18 | 1.59 |
    | LM Mono 10 | 10 | 5.25 | 0 |

    A paragraph after the table closes the fixture.

    """)
    try write("typeset-math.md", """
    # Mathematics

    Inline formulas such as $a^2 + b^2 = c^2$ and $e^{i\\pi} + 1 = 0$ sit on the baseline of the text. Display formulas are centred:

    $$\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}$$

    and sums take their limits above and below:

    $$\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}.$$

    """)
    try write("typeset-code.md", """
    # Code

    Code is set in LM Mono, unjustified, with the list spacing above and below:

    ```
    func breakLines(_ paragraph: Paragraph) -> [Line] {
        var active = [Breakpoint.start]
        for item in paragraph.items { consider(item, &active) }
        return cheapest(active)
    }
    ```

    The text continues after the code.

    """)
    try write("typeset-quotes.md", """
    # Quotations and links

    A quotation is indented on both sides:

    > Typography exists to honour content. Every rule here serves the reader, who should never have to notice it.

    Straight "quotes" become curly ones, two hyphens make an en dash for ranges such as 10--20, three make an em dash---like this---and three dots make an ellipsis... A [link to the specification](https://example.com/spec) is clickable without a visible box.

    """)
    try typesettingParity()
}

/// The other 26 LaTeX parity fixtures (quality §3.7: 40 in all): long words, headings and numbering, the title block and
/// abstract, several pages, deep and restarted lists, many footnotes, captioned and numeric tables, inline, display and
/// aligned math, code, nested quotes, links, TeX punctuation, a mixed article, a rule, and three more languages.
func typesettingParity() throws {
    let more: [(String, String, [String])] = [
        ("sv", "Radbrytning", [
            "Ett stycke delas upp i rader genom att alla tänkbara brytpunkter prövas samtidigt och den följd väljs vars sammanlagda kostnad är minst. Långa sammansättningar som järnvägsstationsbyggnad eller sjukförsäkringsavgifterna gör en god avstavning nödvändig.",
            "Mellanrummen mellan orden töjs och krymper inom gränser som typsnittet anger, så att sidans gråton blir jämn och behaglig att läsa.",
        ]),
        ("da", "Linjebrydning", [
            "Et afsnit deles i linjer ved at alle mulige brud overvejes på én gang, og den række vælges hvis samlede omkostning er mindst. Lange sammensætninger som arbejdsløshedsforsikringen eller speciallægepraksisplanlægning har stor gavn af en god orddeling.",
            "Mellemrummene mellem ordene strækkes og trykkes sammen inden for de grænser skriften fastsætter, så siden får en jævn gråtone.",
        ]),
        ("cs", "Sazba odstavců", [
            "Odstavec se dělí na řádky tak, že se současně zváží všechna možná zalomení a vybere se ta posloupnost, jejíž celková cena je nejmenší. Dlouhá slova jako nejneobhospodařovávatelnějšími nebo nejkrásnějšímu potřebují dobré dělení.",
            "Mezery mezi slovy se natahují a stlačují v mezích, které určuje písmo, takže šeď sazby zůstává rovnoměrná.",
        ]),
    ]
    for (language, title, paragraphs) in more {
        try write("typeset-prose-\(language).md", "---\nlang: \(language)\n---\n\n# \(title)\n\n" + paragraphs.joined(separator: "\n\n") + "\n")
    }
    try write("typeset-long-words.md", """
    # Long words

    Some words are long enough to need two or three hyphens on their own: internationalization, characteristically, incomprehensibilities, electroencephalographic, counterrevolutionaries and institutionalization all have to break somewhere when the measure is only 345 points wide.

    Technical prose adds compounds of its own, such as microprocessor-based instrumentation, telecommunications infrastructure, photolithographically patterned semiconductors and the electrophysiological characterization of cardiomyocytes, which TeX's patterns break at the places a dictionary would choose.

    """)
    try write("typeset-numbered.md", """
    # Numbered sections

    ## Introduction

    Three or more sections at the top level are numbered, as LaTeX numbers \\section and \\subsection.

    ## Method

    The method has parts of its own.

    ### Measuring

    Each paragraph is measured with the fonts it will be set in.

    ### Breaking

    Then it is broken into lines by minimising the total demerits.

    ## Results

    The results are compared line by line.

    ## Discussion

    Differences come from the fonts, the patterns and the page builder.

    """)
    try write("typeset-headings.md", """
    # Heading levels

    ## A section

    A section heading is set in large bold type with generous space above and somewhat less below.

    ### A subsection

    A subsection heading is a little smaller, and the text that follows it is not indented.

    #### A subsubsection

    A subsubsection heading has the size of the text, still in bold.

    ##### A paragraph heading

    A paragraph heading runs into its paragraph, separated from the text by an em of space, which saves vertical room in a long document.

    ## Another section

    The second section closes the fixture with a paragraph long enough to wrap onto a second line of text.

    """)
    try write("typeset-title-block.md", """
    ---
    title: A Study of Line Breaking
    author: Ada Lovelace, Charles Babbage
    date: 2024-03-14
    ---

    The title block sets the title in a large size, the authors side by side below it and the date under them, all centred, before the text begins.

    ## Background

    The first paragraph after a section heading is not indented; later ones are.

    A second paragraph shows the indent of fifteen points that LaTeX gives every paragraph but the first.

    """)
    try write("typeset-abstract.md", """
    ---
    title: On Justified Text
    author: Donald Knuth
    abstract: This short paper looks at how a paragraph is broken into lines of equal width with the least visible strain.
    ---

    ## Overview

    The abstract above is set smaller than the text, under a centred bold heading, with its own margins on both sides.

    ## Conclusion

    The rest of the document follows the abstract with ordinary spacing.

    """)
    let multipage = [
        "Long documents are set one page at a time. TeX's page builder collects lines, headings, displays and floats into a vertical list and breaks it where the cost is lowest, preferring not to leave a single line of a paragraph alone at the top or the bottom of a page.",
        "Each page has the same text height, but with a ragged bottom the last line need not sit exactly on the bottom margin; the white space that remains is left below the text instead of being spread between the paragraphs.",
        "Club and widow penalties discourage a page break after the first line or before the last line of a paragraph. They are not absolute, so a page may still end that way when every alternative is worse, but in ordinary prose the builder almost always finds a better place.",
        "Headings are kept with the lines that follow them. A heading at the foot of a page with no text under it is one of the faults a careful compositor never lets through, and the page builder treats it as a forbidden break.",
        "Footnotes, figures and tables complicate the picture, because they take room on a page that the builder must account for before it knows where the page will end. Here the text is plain, so only the lines and the headings matter.",
    ]
    var body = ""
    for section in ["Pages", "Penalties", "Headings", "Floats", "Summary"] {
        body += "## \(section)\n\n" + multipage.joined(separator: "\n\n") + "\n\n"
    }
    try write("typeset-multipage.md", "# Several pages\n\n" + body)
    try write("typeset-lists-deep.md", """
    # Nested lists

    Itemize changes its label at every level:

    - A bullet at the first level.
      - An en dash at the second level.
        - An asterisk at the third level.
          - A centred dot at the fourth level.
        - Back to the third level.
      - Back to the second level.
    - Back to the first level.

    Enumerate counts in four styles:

    1. Arabic numerals.
       1. Lower-case letters in parentheses.
          1. Lower-case roman numerals.
             1. Upper-case letters.
             2. A second upper-case letter.
          2. A second roman numeral.
       2. A second letter.
    2. A second numeral.

    """)
    try write("typeset-lists-start.md", """
    # Lists that continue

    A numbered list can start anywhere:

    4. The fourth step comes first here.
    5. The fifth step follows it.
    6. The sixth step ends the list.

    An item may hold more than one paragraph:

    - The first paragraph of the item is set next to the bullet.

      The second paragraph of the same item lines up with the first one and is separated from it by the list's paragraph space.

    - A short item follows.

    The text after the list starts a new paragraph.

    """)
    try write("typeset-footnotes-many.md", """
    # Many footnotes

    The first claim needs a source.[^a] So does the second one, which is longer and wraps onto another line of the page before its note is referenced.[^b]

    A second paragraph brings two more notes,[^c] one of them with *emphasis* inside.[^d] The notes are numbered in order through the whole document.

    A last paragraph has a final note at its end.[^e]

    [^a]: Knuth and Plass, Breaking Paragraphs into Lines, 1981.
    [^b]: A footnote can be long enough to need two lines of its own at the foot of the page, set in footnote size with its own leading.
    [^c]: Short.
    [^d]: A note with *emphasis* in italics.
    [^e]: The last note.

    """)
    try write("typeset-table-caption.md", """
    # Captioned tables

    A table with a caption floats as a LaTeX table does and is numbered.

    | Paper | Width | Height |
    |:------|------:|-------:|
    | Letter | 614.29 | 794.97 |
    | A4 | 597.51 | 845.05 |
    | A5 | 421.10 | 597.51 |

    Table: Paper sizes in TeX points.

    The text continues after the table with a paragraph that is long enough to show where the table was placed on the page.

    """)
    try write("typeset-table-numbers.md", """
    # Numbers in tables

    Columns can be aligned left, centred or right.

    | Item | Category | Count | Share |
    |:-----|:--------:|------:|------:|
    | Paragraphs | prose | 1204 | 61.3 |
    | Headings | structure | 188 | 9.6 |
    | Lists | structure | 97 | 4.9 |
    | Tables | data | 41 | 2.1 |
    | Formulas | math | 433 | 22.1 |

    A closing paragraph follows the table.

    """)
    try write("typeset-math-inline.md", """
    # Inline mathematics

    Inline formulas take their place in the line: the roots of $ax^2 + bx + c = 0$ are $x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$, the sum $\\sum_{i=1}^{n} i$ stays small, and Greek letters such as $\\alpha$, $\\beta$ and $\\gamma$ sit on the baseline.

    Subscripts and superscripts like $x_i$, $y^{2}$ and $z_{j}^{k}$ change the size of their characters but not the spacing between the lines, so a paragraph with formulas such as $f(x) = e^{-x}$ keeps an even grey.

    """)
    try write("typeset-math-aligned.md", """
    # Aligned equations

    Several equations can be aligned on their relation signs:

    $$\\begin{aligned} (a + b)^2 &= a^2 + 2ab + b^2 \\\\ (a - b)^2 &= a^2 - 2ab + b^2 \\end{aligned}$$

    and a definition by cases uses a brace on the left:

    $$|x| = \\begin{cases} x & \\text{if } x \\geq 0 \\\\ -x & \\text{otherwise} \\end{cases}$$

    A matrix closes the fixture:

    $$A = \\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}$$

    """)
    try write("typeset-math-display.md", """
    # Display mathematics

    The Gaussian integral is a classic display:

    $$\\int_0^1 x^2 \\, dx = \\frac{1}{3}$$

    Fractions and roots grow to fit their contents,

    $$\\sqrt{\\frac{a^2 + b^2}{c^2 + d^2}} \\leq \\frac{\\sqrt{a^2 + b^2}}{\\sqrt{c^2 + d^2}} + 1,$$

    and a product with limits ends the fixture:

    $$\\prod_{k=1}^{n} \\left(1 + \\frac{1}{k}\\right) = n + 1.$$

    The paragraph after the displays continues the text.

    """)
    try write("typeset-code-blocks.md", """
    # Code blocks

    Two code blocks in a row, the second with longer lines:

    ```
    let width = 345.0
    let height = 550.0
    ```

    ```
    for line in paragraph.lines { draw(line, at: origin); origin.y -= baselineskip }
    print("done")
    ```

    A code block inside a list item:

    - Run the bench:

      ```
      swift run SuperConverterQualityBench
      ```

    - Read the report.

    """)
    try write("typeset-inline-styles.md", """
    # Inline styles

    Text can be set in *italics* for emphasis, in **bold** for strong emphasis, or in ***both at once***. Code such as `breakLines()` and `CTTypesetter` is set in the typewriter face, and ~~struck text~~ is crossed out.

    Emphasis inside a long sentence shows how *the italic correction* and the spacing around **bold words** work when the line is justified to the full measure of the text block.

    """)
    try write("typeset-quotes-nested.md", """
    # Nested quotations

    A quotation can hold more than one paragraph:

    > The first paragraph of the quotation is indented on both sides by the same amount.
    >
    > The second paragraph follows with the list's paragraph space between them.
    >
    > > A quotation inside a quotation is indented again on both sides, as LaTeX nests its quote environments.

    The text resumes after the quotation.

    """)
    try write("typeset-links.md", """
    # Links

    Links are clickable without a visible box: the [TeX Users Group](https://tug.org), the [Comprehensive TeX Archive Network](https://ctan.org) and the [Unicode Consortium](https://unicode.org) are three of them.

    A long address such as <https://example.com/a/rather/long/path/to/a/document.html> can break after its slashes and dots, never in the middle of a word.

    """)
    try write("typeset-punctuation.md", """
    # TeX punctuation

    "Double quotes" and 'single quotes' turn curly; it's an apostrophe. Pages 10--20, the years 1990--1999 and a pause---like this---take their dashes, and a sentence can trail off...

    Ligatures join the letters in office, efficient, affluent, shuffle and fjord. After a sentence the space is wider. After an abbreviation such as Mr. Smith or Prof. Jones it stays normal, as it does after the initials in D. E. Knuth.

    """)
    try write("typeset-article.md", """
    ---
    title: A Small Article
    author: Grace Hopper
    ---

    ## Summary

    This fixture mixes the elements of a short article: sections, a list, a table, a formula, code and a quotation.

    ## Data

    The measurements were taken on three machines:

    - an older laptop,
    - a desktop computer,
    - and a small server.

    | Machine | Seconds |
    |:--------|--------:|
    | Laptop | 4.21 |
    | Desktop | 2.08 |
    | Server | 1.57 |

    ## Model

    The time grows with the number of lines $n$ as

    $$t(n) = a n + b \\log n,$$

    which fits all three machines.

    ## Code

    ```
    let t = a * Double(n) + b * log(Double(n))
    ```

    > Measure twice, typeset once.

    """)
    var long = "# A long table\n\nA table longer than a page continues on the next one with its header repeated.\n\n| Year | Station | Mean | Rain |\n|-----:|:--------|-----:|-----:|\n"
    for year in 1961...2020 { long += "| \(year) | Station \(year % 7 + 1) | \(String(format: "%.1f", 8 + Double(year % 13) / 4)) | \(600 + year % 17 * 11) |\n" }
    try write("typeset-table-long.md", long + "\nThe text after the table closes the fixture.\n")
    try write("typeset-table-wide.md", """
    # A wide table

    A table wider than the text block is set smaller until it fits.

    | Language | Patterns | Left | Right | Spacing | Indent | Quotes | Dashes | Sample word |
    |:---------|:---------|-----:|------:|:--------|:-------|:-------|:-------|:------------|
    | English | hyph-en-us | 2 | 3 | wide | no | double | en, em | hyphenation |
    | German | hyph-de-1996 | 2 | 2 | french | no | low-high | en | Silbentrennung |
    | French | hyph-fr | 2 | 3 | french | yes | guillemets | em | césure |
    | Spanish | hyph-es | 2 | 2 | french | yes | guillemets | em | silabeo |

    The paragraph after the table continues the text.

    """)
    try write("typeset-rule.md", """
    # A rule

    A horizontal rule separates two parts of a text:

    ---

    The second part begins after the rule, as a new paragraph that is indented.

    """)
}

// MARK: CAD

func cad() throws {
    var d = ""
    func g(_ code: Int, _ value: Any) { d += "\(code)\n\(value)\n" }
    g(0, "SECTION"); g(2, "HEADER"); g(9, "$ACADVER"); g(1, "AC1015"); g(9, "$INSUNITS"); g(70, 4)
    g(9, "$EXTMIN"); g(10, 0.0); g(20, 0.0); g(30, 0.0); g(9, "$EXTMAX"); g(10, 100.0); g(20, 60.0); g(30, 0.0); g(0, "ENDSEC")
    g(0, "SECTION"); g(2, "TABLES"); g(0, "TABLE"); g(2, "LAYER"); g(70, 2)
    g(0, "LAYER"); g(2, "0"); g(70, 0); g(62, 7); g(6, "CONTINUOUS")
    g(0, "LAYER"); g(2, "WALLS"); g(70, 0); g(62, 1); g(6, "CONTINUOUS")
    g(0, "ENDTAB"); g(0, "ENDSEC")
    g(0, "SECTION"); g(2, "ENTITIES")
    for (x1, y1, x2, y2) in [(0.0, 0.0, 100.0, 0.0), (100.0, 0.0, 100.0, 60.0), (100.0, 60.0, 0.0, 60.0), (0.0, 60.0, 0.0, 0.0)] {
        g(0, "LINE"); g(8, "WALLS"); g(10, x1); g(20, y1); g(30, 0.0); g(11, x2); g(21, y2); g(31, 0.0)
    }
    g(0, "CIRCLE"); g(8, "0"); g(10, 30.0); g(20, 30.0); g(30, 0.0); g(40, 15.0)
    g(0, "ARC"); g(8, "0"); g(10, 70.0); g(20, 30.0); g(30, 0.0); g(40, 15.0); g(50, 0.0); g(51, 180.0)
    g(0, "LWPOLYLINE"); g(8, "WALLS"); g(90, 4); g(70, 1); g(10, 45.0); g(20, 10.0); g(10, 55.0); g(20, 10.0); g(10, 55.0); g(20, 20.0); g(10, 45.0); g(20, 20.0)
    g(0, "TEXT"); g(8, "0"); g(10, 10.0); g(20, 52.0); g(30, 0.0); g(40, 4.0); g(1, "SUPER CONVERTER")
    g(0, "ENDSEC"); g(0, "EOF")
    try write("sample.dxf", d)
}

// MARK: PDF

/// A two-page PDF with real text (CoreText, Helvetica): a heading, paragraphs, and a ruled table on page 1.
func pdf() throws {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, [kCGPDFContextTitle: "Super Converter sample", kCGPDFContextCreator: "make-fixtures"] as CFDictionary)!
    func text(_ s: String, size: CGFloat, bold: Bool = false, at point: CGPoint) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attributed = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        ctx.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
    }
    ctx.beginPDFPage(nil)
    ctx.setFillColor(rgb(0, 0, 0)); ctx.setStrokeColor(rgb(0, 0, 0))
    text("Super Converter sample", size: 24, bold: true, at: CGPoint(x: 72, y: 700))
    let lines = ["This sample page contains ordinary paragraphs of text so that", "extraction, layout analysis and rendering all have something to measure.",
                 "The second paragraph repeats the idea: quality is measured, not eyeballed."]
    for (i, l) in lines.enumerated() { text(l, size: 12, at: CGPoint(x: 72, y: 660 - CGFloat(i) * 16)) }
    // A table ruled on every side: 4 rows, 3 columns, rules at y = 584, 560, 536, 512, 488.
    let rows = [["Item", "Quantity", "Price"], ["Widget", "12", "3.50"], ["Gadget", "7", "12.25"], ["Gizmo", "150", "0.99"]]
    ctx.setLineWidth(0.5)
    for r in 0...rows.count { let y = 584 - CGFloat(r) * 24; ctx.move(to: CGPoint(x: 72, y: y)); ctx.addLine(to: CGPoint(x: 72 + 420, y: y)); ctx.strokePath() }
    for c in 0...3 { let x = 72 + CGFloat(c) * 140; ctx.move(to: CGPoint(x: x, y: 584)); ctx.addLine(to: CGPoint(x: x, y: 488)); ctx.strokePath() }
    for (r, row) in rows.enumerated() {
        for (c, cell) in row.enumerated() { text(cell, size: 12, bold: r == 0, at: CGPoint(x: 80 + CGFloat(c) * 140, y: 584 - CGFloat(r) * 24 - 17)) }
    }
    ctx.endPDFPage()
    ctx.beginPDFPage(nil)
    text("Second page", size: 18, bold: true, at: CGPoint(x: 72, y: 700))
    text("Text on the second page, so page counts and page order can be checked.", size: 12, at: CGPoint(x: 72, y: 670))
    ctx.endPDFPage()
    ctx.closePDF()
    try write("sample.pdf", pinned(data as Data))
}

/// CoreGraphics stamps the creation/modification date and derives the trailer /ID from it. Overwrite them in place with
/// same-length constants (xref offsets stay valid) so the bytes repeat.
func pinned(_ pdf: Data) -> Data {
    var text = String(data: pdf, encoding: .isoLatin1)!
    text = text.replacingOccurrences(of: "D:[0-9]{14}Z00'00'", with: "D:20240101000000Z00'00'", options: .regularExpression)
    text = text.replacingOccurrences(of: "<[0-9a-f]{32}>", with: "<00000000000000000000000000000000>", options: .regularExpression)
    return text.data(using: .isoLatin1)!
}

// MARK: Vector (VectorKit, XPSKit)

/// One drawing in every vector format VectorKit and XPSKit read, 400 × 300 px (300 × 225 pt): a stroked red rectangle,
/// a teal circle, a yellow-to-red gradient band, a dashed curve and the words "SUPER CONVERTER". SVG/SVGZ, a CoreGraphics
/// PDF (also as an Illustrator 9+ `.ai`, which is a PDF), EMF and WMF built record by record (MS-EMF, MS-WMF), Skencil
/// and sK1 text files, and an XPS package (no text: XPS glyphs need an embedded font).
func vector() throws {
    let svg = """
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" width="400" height="300" viewBox="0 0 400 300">
      <defs><linearGradient id="band" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#ffcc00"/><stop offset="1" stop-color="#cc3300"/></linearGradient></defs>
      <rect x="20" y="20" width="160" height="100" fill="#d62828" stroke="#003049" stroke-width="6" stroke-linejoin="round"/>
      <circle cx="290" cy="80" r="55" fill="#2a9d8f"/>
      <rect x="20" y="150" width="360" height="40" fill="url(#band)"/>
      <path d="M30 270 C 100 210, 160 290, 230 240 S 340 220, 370 270" fill="none" stroke="#264653" stroke-width="5" stroke-dasharray="14 6" stroke-linecap="round"/>
      <text x="40" y="228" font-family="Helvetica" font-size="24" fill="#000000">SUPER CONVERTER</text>
    </svg>

    """
    try write("sample.svg", svg)
    let gzip = Process()
    gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    gzip.arguments = ["-n", "-9", "-c", out.appendingPathComponent("sample.svg").path]
    let pipe = Pipe()
    gzip.standardOutput = pipe
    try gzip.run()
    let compressed = pipe.fileHandleForReading.readDataToEndOfFile()
    gzip.waitUntilExit()
    try write("sample.svgz", compressed)

    // The same drawing through CoreGraphics (y up: SVG y → 225 − y × 0.75).
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 300, height: 225)
    let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, [kCGPDFContextTitle: "Super Converter drawing", kCGPDFContextCreator: "make-fixtures"] as CFDictionary)!
    ctx.beginPDFPage(nil)
    ctx.scaleBy(x: 0.75, y: -0.75); ctx.translateBy(x: 0, y: -300)
    ctx.setFillColor(rgb(0xd6, 0x28, 0x28)); ctx.fill(CGRect(x: 20, y: 20, width: 160, height: 100))
    ctx.setStrokeColor(rgb(0x00, 0x30, 0x49)); ctx.setLineWidth(6); ctx.setLineJoin(.round); ctx.stroke(CGRect(x: 20, y: 20, width: 160, height: 100))
    ctx.setFillColor(rgb(0x2a, 0x9d, 0x8f)); ctx.fillEllipse(in: CGRect(x: 235, y: 25, width: 110, height: 110))
    ctx.saveGState(); ctx.clip(to: CGRect(x: 20, y: 150, width: 360, height: 40))
    let band = CGGradient(colorsSpace: sRGB, colors: [rgb(0xff, 0xcc, 0x00), rgb(0xcc, 0x33, 0x00)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(band, start: CGPoint(x: 20, y: 0), end: CGPoint(x: 380, y: 0), options: [])
    ctx.restoreGState()
    ctx.move(to: CGPoint(x: 30, y: 270)); ctx.addCurve(to: CGPoint(x: 230, y: 240), control1: CGPoint(x: 100, y: 210), control2: CGPoint(x: 160, y: 290))
    ctx.addCurve(to: CGPoint(x: 370, y: 270), control1: CGPoint(x: 300, y: 190), control2: CGPoint(x: 340, y: 220))
    ctx.setStrokeColor(rgb(0x26, 0x46, 0x53)); ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.setLineDash(phase: 0, lengths: [14, 6]); ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.saveGState(); ctx.translateBy(x: 40, y: 228); ctx.scaleBy(x: 1, y: -1)
    let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
    let words = NSAttributedString(string: "SUPER CONVERTER", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
    ctx.setFillColor(rgb(0, 0, 0)); ctx.textPosition = .zero; CTLineDraw(CTLineCreateWithAttributedString(words), ctx)
    ctx.restoreGState()
    ctx.endPDFPage(); ctx.closePDF()
    try write("sample-drawing.pdf", pinned(data as Data))
    try write("sample.ai", pinned(data as Data))

    try write("sample.emf", emf())
    try write("sample.wmf", wmf())

    // Skencil: unit-square rectangles and unit-circle ellipses under transforms, points in pt with y up.
    let sk = """
    ##Sketch 1 2
    document()
    layout((300,225),0)
    layer('Layer 1',1,1,0,0,(0,0,0))
    fp((0.839,0.157,0.157))
    lp((0,0.188,0.286))
    lw(4.5)
    lj(1)
    r(120,0,0,75,15,135)
    fp((0.165,0.616,0.561))
    le()
    e(41.25,0,0,41.25,217.5,165)
    gl([(0,(1,0.8,0)),(1,(0.8,0.2,0))])
    pgl(-1,0,0)
    le()
    r(270,0,0,30,15,82.5)
    fe()
    lp((0.149,0.275,0.325))
    lw(3.75)
    lc(2)
    ld((2.8,1.2))
    b()
    bs(22.5,22.5,0)
    bc(75,67.5,120,7.5,172.5,45,0)
    bc(225,82.5,255,60,277.5,22.5,0)
    Fn('Helvetica')
    Fs(18)
    fp((0,0,0))
    txt('SUPER CONVERTER',(1,0,0,1,30,54))

    """
    try write("sample.sk", sk)
    let sk1 = sk.replacingOccurrences(of: "##Sketch 1 2", with: "##sK1 1 2")
        .replacingOccurrences(of: "fp((0.839,0.157,0.157))", with: "fp([\"CMYK\",[0.0,0.81,0.81,0.16],1.0,\"\"])")
        .replacingOccurrences(of: "lp((0,0.188,0.286))", with: "lp([\"RGB\",[0.0,0.188,0.286],1.0,\"\"])")
    try write("sample.sk1", sk1)

    // XPS: one FixedPage with the drawing's shapes (Path Data mini-language, sRGB #RRGGBB brushes).
    let page = """
    <FixedPage xmlns="http://schemas.microsoft.com/xps/2005/06" Width="400" Height="300" xml:lang="en-US">
      <Path Data="M 20,20 L 180,20 180,120 20,120 Z" Fill="#FFD62828" Stroke="#FF003049" StrokeThickness="6" StrokeLineJoin="Round"/>
      <Path Data="M 345,80 A 55,55 0 1 1 235,80 A 55,55 0 1 1 345,80 Z" Fill="#FF2A9D8F"/>
      <Path Data="M 20,150 L 380,150 380,190 20,190 Z">
        <Path.Fill><LinearGradientBrush MappingMode="Absolute" StartPoint="20,0" EndPoint="380,0"><LinearGradientBrush.GradientStops>
          <GradientStop Color="#FFFFCC00" Offset="0"/><GradientStop Color="#FFCC3300" Offset="1"/>
        </LinearGradientBrush.GradientStops></LinearGradientBrush></Path.Fill>
      </Path>
      <Path Data="M 30,270 C 100,210 160,290 230,240 C 300,190 340,220 370,270" Stroke="#FF264653" StrokeThickness="5" StrokeDashArray="2.8 1.2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
    </FixedPage>
    """
    try zip("sample.xps", files: [
        ("[Content_Types].xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="fdseq" ContentType="application/vnd.ms-package.xps-fixeddocumentsequence+xml"/><Default Extension="fdoc" ContentType="application/vnd.ms-package.xps-fixeddocument+xml"/><Default Extension="fpage" ContentType="application/vnd.ms-package.xps-fixedpage+xml"/></Types>
        """.utf8)),
        ("_rels/.rels", Data("""
        <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="R0" Type="http://schemas.microsoft.com/xps/2005/06/fixedrepresentation" Target="/FixedDocumentSequence.fdseq"/></Relationships>
        """.utf8)),
        ("FixedDocumentSequence.fdseq", Data("<FixedDocumentSequence xmlns=\"http://schemas.microsoft.com/xps/2005/06\"><DocumentReference Source=\"/Documents/1/FixedDocument.fdoc\"/></FixedDocumentSequence>".utf8)),
        ("Documents/1/FixedDocument.fdoc", Data("<FixedDocument xmlns=\"http://schemas.microsoft.com/xps/2005/06\"><PageContent Source=\"/Documents/1/Pages/1.fpage\"/></FixedDocument>".utf8)),
        ("Documents/1/Pages/1.fpage", Data(page.utf8)),
    ])
}

/// Little-endian record bytes for the metafiles.
struct LE {
    var bytes: [UInt8] = []
    mutating func u16(_ v: Int) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    mutating func u32(_ v: Int) { for s in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(v >> s & 0xFF)) } }
    mutating func i32(_ v: Int) { u32(Int(UInt32(bitPattern: Int32(v)))) }
    mutating func i16(_ v: Int) { u16(Int(UInt16(bitPattern: Int16(v)))) }
    mutating func f32(_ v: Float) { u32(Int(v.bitPattern)) }
}

func colorref(_ r: Int, _ g: Int, _ b: Int) -> Int { r | g << 8 | b << 16 }

/// EMF (MS-EMF 2.3): logical units are pixels at 96 dpi; the frame is 400 × 300 px in 0.01 mm.
func emf() -> Data {
    var records: [[UInt8]] = []
    func record(_ type: Int, _ body: (inout LE) -> Void) {
        var r = LE(); body(&r)
        var head = LE(); head.u32(type); head.u32(r.bytes.count + 8)
        records.append(head.bytes + r.bytes)
    }
    func rect(_ r: inout LE, _ l: Int, _ t: Int, _ rt: Int, _ b: Int) { r.i32(l); r.i32(t); r.i32(rt); r.i32(b) }
    record(18) { $0.u32(1) }                                                        // SETBKMODE transparent
    record(39) { $0.u32(1); $0.u32(0); $0.u32(colorref(0xd6, 0x28, 0x28)); $0.u32(0) }  // CREATEBRUSHINDIRECT
    record(37) { $0.u32(1) }                                                        // SELECTOBJECT
    record(38) { $0.u32(2); $0.u32(0); $0.i32(6); $0.i32(0); $0.u32(colorref(0x00, 0x30, 0x49)) }   // CREATEPEN
    record(37) { $0.u32(2) }
    record(43) { rect(&$0, 20, 20, 180, 120) }                                      // RECTANGLE
    record(39) { $0.u32(3); $0.u32(0); $0.u32(colorref(0x2a, 0x9d, 0x8f)); $0.u32(0) }
    record(37) { $0.u32(3) }
    record(37) { $0.u32(0x80000008) }                                               // NULL_PEN stock object
    record(42) { rect(&$0, 235, 25, 345, 135) }                                     // ELLIPSE
    record(39) { $0.u32(4); $0.u32(0); $0.u32(colorref(0xe6, 0x80, 0x00)); $0.u32(0) }
    record(37) { $0.u32(4) }
    record(86) { r in rect(&r, 20, 150, 380, 190); r.u32(4); for (x, y) in [(20, 150), (380, 150), (380, 190), (20, 190)] { r.i16(x); r.i16(y) } }   // POLYGON16
    record(38) { $0.u32(5); $0.u32(0); $0.i32(5); $0.i32(0); $0.u32(colorref(0x26, 0x46, 0x53)) }
    record(37) { $0.u32(5) }
    record(27) { $0.i32(30); $0.i32(270) }                                          // MOVETOEX
    record(88) { r in rect(&r, 30, 190, 370, 290); r.u32(6)                         // POLYBEZIERTO16
        for (x, y) in [(100, 210), (160, 290), (230, 240), (300, 190), (340, 220), (370, 270)] { r.i16(x); r.i16(y) } }
    record(82) { r in r.u32(6); r.i32(-24); r.i32(0); r.i32(0); r.i32(0); r.i32(400); r.bytes += [0, 0, 0, 0, 0, 0, 0, 0]   // EXTCREATEFONTINDIRECTW
        let face = Array("Helvetica".utf16); for i in 0..<32 { r.u16(i < face.count ? Int(face[i]) : 0) } }
    record(37) { $0.u32(6) }
    record(24) { $0.u32(colorref(0, 0, 0)) }                                        // SETTEXTCOLOR
    record(22) { $0.u32(24) }                                                       // SETTEXTALIGN TA_BASELINE
    let text = Array("SUPER CONVERTER".utf16)
    record(84) { r in rect(&r, 40, 200, 260, 235); r.u32(1); r.f32(0); r.f32(0)    // EXTTEXTOUTW
        r.i32(40); r.i32(228); r.u32(text.count); r.u32(76); r.u32(0); rect(&r, 0, 0, -1, -1); r.u32(76 + (text.count * 2 + 3) / 4 * 4)
        for c in text { r.u16(Int(c)) }; while r.bytes.count % 4 != 0 { r.bytes.append(0) }
        for c in text { r.u32(c == 32 ? 7 : 16) } }
    record(14) { $0.u32(0); $0.u32(16); $0.u32(20) }                                // EOF
    let total = 108 + records.reduce(0) { $0 + $1.count }
    var h = LE()
    h.u32(1); h.u32(108); rect(&h, 0, 0, 399, 299); rect(&h, 0, 0, 10583, 7938)
    h.u32(0x464D4520); h.u32(0x10000); h.u32(total); h.u32(records.count + 1); h.u16(7); h.u16(0)
    h.u32(0); h.u32(0); h.u32(0); h.i32(400); h.i32(300); h.i32(106); h.i32(79); h.u32(0); h.u32(0); h.u32(0); h.i32(105833); h.i32(79375)
    return Data(h.bytes + records.joined())
}

/// WMF (MS-WMF 2.3) with a placeable header: 400 × 300 logical units at 96 units per inch.
func wmf() -> Data {
    var records: [[UInt8]] = []
    var largest = 0
    func record(_ function: Int, _ body: (inout LE) -> Void) {
        var r = LE(); body(&r)
        var head = LE(); head.u32(3 + r.bytes.count / 2); head.u16(function)
        largest = max(largest, 3 + r.bytes.count / 2)
        records.append(head.bytes + r.bytes)
    }
    record(0x020B) { $0.i16(0); $0.i16(0) }                                         // SETWINDOWORG
    record(0x020C) { $0.i16(300); $0.i16(400) }                                     // SETWINDOWEXT
    record(0x0102) { $0.u16(1) }                                                    // SETBKMODE transparent
    record(0x02FC) { $0.u16(0); $0.u32(colorref(0xd6, 0x28, 0x28)); $0.u16(0) }    // CREATEBRUSHINDIRECT → 0
    record(0x012D) { $0.u16(0) }
    record(0x02FA) { $0.u16(0); $0.i16(6); $0.i16(0); $0.u32(colorref(0x00, 0x30, 0x49)) }   // CREATEPENINDIRECT → 1
    record(0x012D) { $0.u16(1) }
    record(0x041B) { $0.i16(120); $0.i16(180); $0.i16(20); $0.i16(20) }             // RECTANGLE (bottom, right, top, left)
    record(0x02FC) { $0.u16(0); $0.u32(colorref(0x2a, 0x9d, 0x8f)); $0.u16(0) }    // → 2
    record(0x012D) { $0.u16(2) }
    record(0x02FA) { $0.u16(5); $0.i16(0); $0.i16(0); $0.u32(0) }                   // PS_NULL pen → 3
    record(0x012D) { $0.u16(3) }
    record(0x0418) { $0.i16(135); $0.i16(345); $0.i16(25); $0.i16(235) }            // ELLIPSE
    record(0x02FC) { $0.u16(0); $0.u32(colorref(0xe6, 0x80, 0x00)); $0.u16(0) }    // → 4
    record(0x012D) { $0.u16(4) }
    record(0x0324) { r in r.u16(4); for (x, y) in [(20, 150), (380, 150), (380, 190), (20, 190)] { r.i16(x); r.i16(y) } }   // POLYGON
    record(0x02FA) { $0.u16(0); $0.i16(5); $0.i16(0); $0.u32(colorref(0x26, 0x46, 0x53)) }   // → 5
    record(0x012D) { $0.u16(5) }
    record(0x0325) { r in                                                          // POLYLINE: the curve, flattened
        let p0 = (30.0, 270.0), c = [((100.0, 210.0), (160.0, 290.0), (230.0, 240.0)), ((300.0, 190.0), (340.0, 220.0), (370.0, 270.0))]
        var pts: [(Int, Int)] = [(30, 270)]
        var start = p0
        for (a, b, e) in c {
            for i in 1...16 {
                let t = Double(i) / 16, u = 1 - t
                pts.append((Int((u * u * u * start.0 + 3 * u * u * t * a.0 + 3 * u * t * t * b.0 + t * t * t * e.0).rounded()),
                            Int((u * u * u * start.1 + 3 * u * u * t * a.1 + 3 * u * t * t * b.1 + t * t * t * e.1).rounded())))
            }
            start = e
        }
        r.u16(pts.count); for (x, y) in pts { r.i16(x); r.i16(y) } }
    record(0x02FB) { r in r.i16(-24); r.i16(0); r.i16(0); r.i16(0); r.i16(400); r.bytes += [0, 0, 0, 0, 0, 0, 0, 0]   // CREATEFONTINDIRECT → 6
        let face = Array("Helvetica".utf8); for i in 0..<32 { r.bytes.append(i < face.count ? face[i] : 0) } }
    record(0x012D) { $0.u16(6) }
    record(0x0209) { $0.u32(colorref(0, 0, 0)) }                                    // SETTEXTCOLOR
    record(0x012E) { $0.u16(24) }                                                   // SETTEXTALIGN TA_BASELINE
    record(0x0521) { r in let s = Array("SUPER CONVERTER".utf8); r.u16(s.count); r.bytes += s; if s.count % 2 == 1 { r.bytes.append(0) }; r.i16(228); r.i16(40) }   // TEXTOUT
    record(0x0000) { _ in }                                                         // EOF
    let words = 9 + records.reduce(0) { $0 + $1.count / 2 }
    var p = LE()
    p.u32(0x9AC6CDD7); p.u16(0); p.i16(0); p.i16(0); p.i16(400); p.i16(300); p.u16(96); p.u32(0)
    var sum = 0
    for i in stride(from: 0, to: 20, by: 2) { sum ^= Int(p.bytes[i]) | Int(p.bytes[i + 1]) << 8 }
    p.u16(sum)
    var h = LE()
    h.u16(1); h.u16(9); h.u16(0x0300); h.u32(words); h.u16(7); h.u32(largest); h.u16(0)
    return Data(p.bytes + h.bytes + records.joined())
}

// MARK: Archives

/// The archive corpus (quality §8): one fixture per archive format with its expected manifest, written by
/// scripts/make-archive-fixtures.py (Python's standard library, macOS's hdiutil and compress, and the bundled 7zz).
func archives() throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-I", root.appendingPathComponent("scripts/make-archive-fixtures.py").path, "--corpus", out.appendingPathComponent("archives").path]
    try p.run(); p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw NSError(domain: "make-archive-fixtures", code: Int(p.terminationStatus)) }
}

// MARK: ImageKit (quality §2.8)

/// A CGImage over packed samples: `components` colour channels (+ alpha, un-premultiplied), 8 or 16 bits, in `space`.
func samples(_ width: Int, _ height: Int, space: CGColorSpace, alpha: Bool = false, bits: Int = 8, _ value: (Int, Int, Int) -> Double) -> CGImage {
    let components = space.numberOfComponents + (alpha ? 1 : 0)
    var bytes: [UInt8] = []
    for y in 0..<height { for x in 0..<width { for c in 0..<components {
        let v = min(max(value(x, y, c), 0), 1)
        if bits == 16 { let s = Int((v * 65535).rounded()); bytes += [UInt8(s & 255), UInt8(s >> 8)] } else { bytes.append(UInt8((v * 255).rounded())) }
    } } }
    let info = (alpha ? CGImageAlphaInfo.last : CGImageAlphaInfo.none).rawValue | (bits == 16 ? CGImageByteOrderInfo.order16Little.rawValue : 0)
    return CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * components, bytesPerRow: width * components * bits / 8,
                   space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)!
}

func encode(_ name: String, _ type: String, _ images: [CGImage], properties: [CFString: Any] = [:], frame: [CFString: Any] = [:]) throws {
    let data = NSMutableData()
    let d = CGImageDestinationCreateWithData(data, type as CFString, images.count, nil)!
    CGImageDestinationSetProperties(d, properties as CFDictionary)
    for image in images { CGImageDestinationAddImage(d, image, frame as CFDictionary) }
    guard CGImageDestinationFinalize(d) else { throw NSError(domain: name, code: 1) }
    try write(name, data as Data)
}

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
func be64(_ v: Int) -> [UInt8] { be32(v >> 32) + be32(v & 0xFFFF_FFFF) }

/// One TIFF IFD laid out at `base`: (tag, type, count, payload); a nil payload reserves a 4-byte slot patched later.
func ifd(_ entries: [(Int, Int, Int, [UInt8]?)], base: Int) -> (bytes: [UInt8], slots: [Int: Int]) {
    let sorted = entries.sorted { $0.0 < $1.0 }
    let extraStart = base + 2 + 12 * sorted.count + 4
    var table = le16(sorted.count), extra: [UInt8] = [], slots: [Int: Int] = [:]
    for (tag, type, count, payload) in sorted {
        table += le16(tag) + le16(type) + le32(count)
        guard let payload else { slots[tag] = base + table.count; table += [0, 0, 0, 0]; continue }
        if payload.count <= 4 { table += payload + [UInt8](repeating: 0, count: 4 - payload.count) } else {
            table += le32(extraStart + extra.count)
            extra += payload + (payload.count % 2 == 1 ? [0] : [])
        }
    }
    return (table + le32(0) + extra, slots)
}

/// A synthetic Linear DNG (DNG 1.4: a thumbnail in IFD0, 16-bit linear RGB in a SubIFD, identity colour matrix) of a
/// smooth colour scene — the layout CIRAWFilter develops.
func dng(width: Int, height: Int) -> Data {
    var raw: [UInt8] = []
    for y in 0..<height { for x in 0..<width {
        let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
        for v in [0.15 + 0.6 * fx, 0.2 + 0.5 * fy, 0.6 - 0.4 * fx * fy] { raw += le16(Int(v * 60000)) }
    } }
    let thumb = [UInt8](repeating: 128, count: 16 * 12 * 3)
    func rational(_ pairs: [(Int, Int)]) -> [UInt8] { pairs.flatMap { le32($0.0) + le32($0.1) } }
    let ifd0: [(Int, Int, Int, [UInt8]?)] = [
        (254, 4, 1, le32(1)), (256, 4, 1, le32(16)), (257, 4, 1, le32(12)), (258, 3, 3, le16(8) + le16(8) + le16(8)),
        (259, 3, 1, le16(1)), (262, 3, 1, le16(2)), (271, 2, 5, Array("Test\0".utf8)), (272, 2, 10, Array("Synthetic\0".utf8)),
        (273, 4, 1, nil), (274, 3, 1, le16(1)), (277, 3, 1, le16(3)), (278, 4, 1, le32(12)), (279, 4, 1, le32(thumb.count)),
        (284, 3, 1, le16(1)), (330, 4, 1, nil), (50706, 1, 4, [1, 4, 0, 0]), (50707, 1, 4, [1, 1, 0, 0]),
        (50708, 2, 15, Array("Test Synthetic\0".utf8)), (50721, 10, 9, rational([10000, 0, 0, 0, 10000, 0, 0, 0, 10000].map { ($0, 10000) })),
        (50728, 5, 3, rational([(1, 1), (1, 1), (1, 1)])), (50778, 3, 1, le16(21)),
    ]
    let sub: [(Int, Int, Int, [UInt8]?)] = [
        (254, 4, 1, le32(0)), (256, 4, 1, le32(width)), (257, 4, 1, le32(height)), (258, 3, 3, le16(16) + le16(16) + le16(16)),
        (259, 3, 1, le16(1)), (262, 3, 1, le16(34892)), (273, 4, 1, nil), (277, 3, 1, le16(3)), (278, 4, 1, le32(height)),
        (279, 4, 1, le32(raw.count)), (284, 3, 1, le16(1)), (50714, 4, 1, le32(0)), (50717, 4, 1, le32(65535)),
        (50719, 4, 2, le32(0) + le32(0)), (50720, 4, 2, le32(width) + le32(height)),
    ]
    let first = ifd(ifd0, base: 8)
    let subBase = (8 + first.bytes.count + 1) & ~1
    let second = ifd(sub, base: subBase)
    var file: [UInt8] = [0x49, 0x49, 0x2A, 0x00] + le32(8) + first.bytes
    file += [UInt8](repeating: 0, count: subBase - file.count) + second.bytes
    let thumbOffset = file.count
    file += thumb
    let rawOffset = file.count
    file += raw
    file.replaceSubrange(first.slots[273]!..<(first.slots[273]! + 4), with: le32(thumbOffset))
    file.replaceSubrange(first.slots[330]!..<(first.slots[330]! + 4), with: le32(subBase))
    file.replaceSubrange(second.slots[273]!..<(second.slots[273]! + 4), with: le32(rawOffset))
    return Data(file)
}

/// A PSB (version 2), 8-bit RGB + merged transparency, PackBits rows with 4-byte counts, the sRGB profile in resource 1039.
func psb(width: Int, height: Int, sample: (Int, Int, Int) -> Int) -> Data {
    let icc = [UInt8](sRGB.copyICCData()! as Data)
    var out: [UInt8] = Array("8BPS".utf8) + be16(2) + [UInt8](repeating: 0, count: 6) + be16(4) + be32(height) + be32(width) + be16(8) + be16(3)
    out += be32(0)
    var resource: [UInt8] = Array("8BIM".utf8) + be16(1039) + [0, 0] + be32(icc.count) + icc
    if icc.count % 2 == 1 { resource.append(0) }
    out += be32(resource.count) + resource
    let layerInfo = be16(0xFFFF) + [0, 0]
    let section = be64(layerInfo.count) + layerInfo + be32(0)
    out += be64(section.count) + section
    var counts: [UInt8] = [], packed: [UInt8] = []
    for c in 0..<4 { for y in 0..<height {
        let row = (0..<width).map { UInt8(sample($0, y, c)) }
        var encoded: [UInt8] = [], i = 0
        while i < row.count { let n = min(128, row.count - i); encoded.append(UInt8(n - 1)); encoded += row[i..<(i + n)]; i += n }
        counts += be32(encoded.count); packed += encoded
    } }
    out += be16(1) + counts + packed
    return Data(out)
}

/// A GIMP XCF (version 0, 8-bit RGBA layers, RLE tiles): `layers` top first as (x, y, w, h, opacity 0…255, mode, RGBA).
func xcf(width: Int, height: Int, layers: [(Int, Int, Int, Int, Int, Int, [UInt8])]) -> Data {
    var out: [UInt8] = Array("gimp xcf file\0".utf8) + be32(width) + be32(height) + be32(0)
    out += be32(17) + be32(1) + [1] + be32(0) + be32(0)   // PROP_COMPRESSION: RLE, then PROP_END
    let pointers = out.count
    out += [UInt8](repeating: 0, count: 4 * (layers.count + 1)) + be32(0)
    func patch(_ at: Int, _ v: Int) { out.replaceSubrange(at..<(at + 4), with: be32(v)) }
    func rle(_ plane: [UInt8]) -> [UInt8] {
        var o: [UInt8] = [], i = 0
        while i < plane.count {
            var run = 1
            while i + run < plane.count, run < 127, plane[i + run] == plane[i] { run += 1 }
            if run >= 3 { o += [UInt8(run - 1), plane[i]]; i += run; continue }
            let n = min(127, plane.count - i)
            o.append(UInt8(256 - n)); o += plane[i..<(i + n)]; i += n
        }
        return o
    }
    for (k, (x, y, w, h, opacity, mode, pixels)) in layers.enumerated() {
        patch(pointers + 4 * k, out.count)
        let name = Array("Layer \(k)\0".utf8)
        out += be32(w) + be32(h) + be32(1) + be32(name.count) + name
        out += be32(6) + be32(4) + be32(opacity) + be32(8) + be32(4) + be32(1)
        out += be32(15) + be32(8) + be32(x) + be32(y) + be32(7) + be32(4) + be32(mode) + be32(0) + be32(0)
        let hierarchy = out.count
        out += be32(0) + be32(0)
        patch(hierarchy, out.count)
        out += be32(w) + be32(h) + be32(4)
        let level = out.count
        out += be32(0) + be32(0)
        patch(level, out.count)
        out += be32(w) + be32(h)
        let across = (w + 63) / 64, down = (h + 63) / 64
        let tiles = out.count
        out += [UInt8](repeating: 0, count: 4 * across * down) + be32(0)
        for t in 0..<(across * down) {
            patch(tiles + 4 * t, out.count)
            let tx = (t % across) * 64, ty = (t / across) * 64
            var tile: [UInt8] = []
            for yy in ty..<min(ty + 64, h) { for xx in tx..<min(tx + 64, w) { tile += pixels[((yy * w + xx) * 4)..<((yy * w + xx) * 4 + 4)] } }
            for c in 0..<4 { out += rle(Swift.stride(from: c, to: tile.count, by: 4).map { tile[$0] }) }
        }
    }
    return Data(out)
}

/// The CMYK patches of `cmyk-chart.tiff`, 8 × 4 of 16 px, row by row (the bench recomputes the reference from these).
let cmykPatches: [[Double]] = (0..<32).map { (i: Int) -> [Double] in
    let c = Double(i % 4) / 3, m = Double(i / 4 % 4) / 3, y = Double((i * 5) % 7) / 6
    let k: Double = i < 16 ? 0 : Double(i % 3) / 4
    return [c, m, y, k]
}

func imageKit() throws {
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    // A synthetic photo in Display P3: smooth sky, a skin-tone blob, fine texture (lossy defaults, profile kept). A TIFF,
    // not a PNG: PNG counts as a graphics source, which WebP and AVIF write losslessly (formats §5).
    try encode("photo-p3-320.tiff", "public.tiff", [samples(320, 240, space: p3) { x, y, c in
        let fx = Double(x) / 320, fy = Double(y) / 240
        let blob = exp(-(pow(fx - 0.6, 2) + pow(fy - 0.55, 2)) * 18)
        let base = [0.35 + 0.5 * fy, 0.55 + 0.3 * (1 - fy), 0.85 - 0.6 * fy][c], skin = [0.9, 0.7, 0.55][c]
        return base * (1 - blob) + skin * blob + 0.02 * sin(Double(x) * 0.5) * cos(Double(y) * 0.4) + 0.1 * fx
    }], frame: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]])
    // The ColorChecker patches tagged Display P3 (≤ 256 colours, for no-ICC targets).
    let patches: [(Int, Int, Int)] = [
        (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67), (133, 128, 177), (103, 189, 170),
        (214, 126, 44), (80, 91, 166), (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
        (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31), (187, 86, 149), (8, 133, 161),
        (243, 243, 242), (200, 200, 200), (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52)]
    try encode("colorchecker-p3.png", "public.png", [samples(240, 160, space: p3) { x, y, c in
        let p = patches[(y / 40) * 6 + x / 40]
        return Double([p.0, p.1, p.2][c]) / 255
    }])
    // 16-bit RGB (Display P3) and 16-bit gray ramps for the lossless round trips.
    try encode("ramp-p3-16.png", "public.png", [samples(64, 48, space: p3, bits: 16) { x, y, c in
        Double(x * 48 + y + c * 977) .truncatingRemainder(dividingBy: 3072) / 3071
    }])
    try encode("ramp-gray-16.png", "public.png", [samples(64, 48, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bits: 16) { x, y, _ in
        Double(x * 48 + y) / 3071
    }])
    // CMYK patches in Generic CMYK (kept by CMYK targets, converted for RGB ones).
    try encode("cmyk-chart.tiff", "public.tiff", [samples(128, 64, space: CGColorSpace(name: CGColorSpace.genericCMYK)!) { x, y, c in
        cmykPatches[(y / 16) * 8 + x / 16][c]
    }], frame: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]])
    // Red 12 px text on white (edge chroma) and a hard step edge (ringing).
    try png("red-text-240.png", bitmap(240, 40) { c in
        c.setFillColor(rgb(255, 255, 255)); c.fill(CGRect(x: 0, y: 0, width: 240, height: 40))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let line = NSAttributedString(string: "Red text on white 0123456789", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                                             NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(255, 0, 0)])
        c.textPosition = CGPoint(x: 4, y: 14)
        CTLineDraw(CTLineCreateWithAttributedString(line), c)
    })
    try png("step-edge-200.png", bitmap(200, 40) { c in
        c.setFillColor(rgb(0, 0, 0)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 40))
        c.setFillColor(rgb(255, 255, 255)); c.fill(CGRect(x: 100, y: 0, width: 100, height: 40))
    })
    // An EXIF-rich JPEG stored sideways (orientation 6): a red block in the stored top-left corner.
    try encode("exif-orient6.jpg", "public.jpeg", [bitmap(96, 64) { c in
        c.setFillColor(rgb(40, 90, 200)); c.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        c.setFillColor(rgb(220, 20, 20)); c.fill(CGRect(x: 0, y: 40, width: 32, height: 24))
    }], frame: [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.95,
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09", kCGImagePropertyExifLensModel: "Test 35mm f/2",
                                                 kCGImagePropertyExifFNumber: 2.0, kCGImagePropertyExifExposureTime: 0.004],
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Super Converter", kCGImagePropertyTIFFModel: "Fixture 1"],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8566, kCGImagePropertyGPSLatitudeRef: "N",
                                                kCGImagePropertyGPSLongitude: 2.3522, kCGImagePropertyGPSLongitudeRef: "E"]])
    // An animated GIF: three frames, three delays.
    let colours = [(200, 40, 40), (40, 160, 60), (40, 60, 200)]
    try encode("animated-3.gif", "com.compuserve.gif", colours.map { col in bitmap(32, 32) { c in
        c.setFillColor(rgb(255, 255, 255)); c.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        c.setFillColor(rgb(col.0, col.1, col.2)); c.fill(CGRect(x: 8, y: 8, width: 16, height: 16))
    } }, properties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
       frame: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]])
    // Camera RAW, PSB and XCF.
    try write("synthetic.dng", dng(width: 256, height: 192))
    try write("sample.psb", psb(width: 64, height: 48) { x, y, c in c == 3 ? 255 : [x * 4, y * 5, 128][c] })
    let bottom = [UInt8](repeating: 0, count: 64 * 48 * 4).enumerated().map { $0.offset % 4 == 3 ? UInt8(255) : UInt8(200) }
    let top = [UInt8](repeating: 0, count: 32 * 24 * 4).enumerated().map { $0.offset % 4 == 0 || $0.offset % 4 == 3 ? UInt8(255) : UInt8(0) }
    try write("sample.xcf", xcf(width: 64, height: 48, layers: [(16, 12, 32, 24, 255, 3, top), (0, 0, 64, 48, 255, 0, bottom)]))
    // A gain-map HEIC (HDR highlights up to 4× SDR white): ImageIO writes ISO 21496-1 gain maps on macOS 15+.
    if #available(macOS 15, *) {
        let w = 96, h = 32
        var px = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let v = Float(x) / Float(w - 1) * 4, i = (y * w + x) * 4
            px[i] = v; px[i + 1] = v * 0.85; px[i + 2] = v * 0.6 + (y < h / 2 ? 0.05 : 0)
        } }
        let image = CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16,
                            space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                            provider: CGDataProvider(data: px.withUnsafeBytes { Data($0) } as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        try encode("hdr-gainmap.heic", "public.heic", [image], frame: [kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap])
    }
}

// MARK: Media (MediaKit, quality §5.3)

/// One small clip per audio/video input format of the matrix, made by the bundled LGPL FFmpeg in Vendor/Tools (never a system
/// FFmpeg: Homebrew's is GPL) from its own test sources, with bit-exact software encoders so the bytes repeat. Skipped with a
/// note when the tool is not there (`scripts/fetch-vendor.sh`).
func media() throws {
    let ffmpeg = root.appendingPathComponent("Vendor/Tools/ffmpeg")
    guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { print("Vendor/Tools/ffmpeg missing: media fixtures skipped"); return }
    let folder = out.appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func run(_ arguments: [String]) throws {
        let p = Process()
        p.executableURL = ffmpeg
        p.currentDirectoryURL = folder
        p.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-threads", "1"] + arguments
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw NSError(domain: "ffmpeg \(arguments.last ?? "")", code: Int(p.terminationStatus)) }
    }
    let exact = ["-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact", "-map_metadata", "-1"]
    func picture(_ size: String = "160x120", rate: String = "25", seconds: String = "1") -> [String] {
        ["-f", "lavfi", "-i", "testsrc2=s=\(size):r=\(rate):d=\(seconds)"]
    }
    func sound(rate: Int = 48000, seconds: String = "1", channels: Int = 2) -> [String] {
        ["-f", "lavfi", "-i", "sine=f=440:sample_rate=\(rate):d=\(seconds)", "-ac", String(channels)]
    }
    // Video: (name, picture, sound, codecs and muxer).
    let videos: [(String, [String], [String], [String])] = [
        ("mp4", picture(), sound(), ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "aac", "-b:a", "96k", "-f", "mp4"]),
        ("mov", picture(), sound(), ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "aac", "-b:a", "96k", "-f", "mov"]),
        ("m4v", picture(), sound(), ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "aac", "-b:a", "96k", "-f", "ipod"]),
        ("3gp", picture("176x144"), sound(), ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "aac", "-b:a", "64k", "-f", "3gp"]),
        ("3gpp", picture("176x144"), sound(), ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "aac", "-b:a", "64k", "-f", "3gp"]),
        ("3g2", picture("176x144"), sound(), ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "aac", "-b:a", "64k", "-f", "3g2"]),
        ("mkv", picture(), sound(), ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libvorbis", "-q:a", "3", "-f", "matroska"]),
        ("webm", picture(), sound(), ["-c:v", "libvpx", "-b:v", "200k", "-c:a", "libvorbis", "-q:a", "3", "-f", "webm"]),
        ("avi", picture(), sound(rate: 44100), ["-c:v", "mpeg4", "-q:v", "4", "-tag:v", "XVID", "-c:a", "libmp3lame", "-b:a", "128k", "-f", "avi"]),
        ("flv", picture(), sound(rate: 44100), ["-c:v", "flv", "-q:v", "4", "-c:a", "libmp3lame", "-b:a", "128k", "-f", "flv"]),
        ("wmv", picture(), sound(rate: 44100), ["-c:v", "msmpeg4", "-q:v", "4", "-c:a", "wmav2", "-b:a", "128k", "-f", "asf"]),
        ("mpeg", picture(), sound(), ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "mp2", "-b:a", "192k", "-f", "mpeg"]),
        ("mpg", picture(), sound(), ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "mp2", "-b:a", "192k", "-f", "mpeg"]),
        ("vob", picture("352x288"), sound(), ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "ac3", "-b:a", "192k", "-f", "vob"]),
        ("mod", picture("352x288"), sound(), ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "ac3", "-b:a", "192k", "-f", "vob"]),
        ("dvr", picture(), sound(), ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "mp2", "-b:a", "192k", "-f", "asf"]),
        ("wtv", picture(), sound(), ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "mp2", "-b:a", "192k", "-f", "wtv"]),
        ("ts", picture(), sound(), ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "mp2", "-b:a", "192k", "-f", "mpegts"]),
        ("m2ts", picture(), sound(), ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "ac3", "-b:a", "192k", "-mpegts_m2ts_mode", "1", "-f", "mpegts"]),
        ("mts", picture(), sound(), ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "ac3", "-b:a", "192k", "-mpegts_m2ts_mode", "1", "-f", "mpegts"]),
        ("mxf", picture("352x288"), sound(), ["-c:v", "mpeg2video", "-q:v", "4", "-c:a", "pcm_s16le", "-f", "mxf"]),
        ("dv", picture("720x576", seconds: "0.4"), sound(seconds: "0.4"), ["-c:v", "dvvideo", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", "-f", "dv"]),
        ("ogv", picture(), sound(), ["-c:v", "libtheora", "-q:v", "5", "-c:a", "libvorbis", "-q:a", "3", "-f", "ogg"]),
        ("rm", picture(), sound(), ["-c:v", "rv20", "-q:v", "4", "-c:a", "ac3", "-b:a", "192k", "-f", "rm"]),
        ("rmvb", picture(), sound(), ["-c:v", "rv20", "-q:v", "4", "-c:a", "ac3", "-b:a", "192k", "-f", "rm"]),
        ("swf", picture(), sound(rate: 44100), ["-c:v", "flv", "-q:v", "4", "-c:a", "libmp3lame", "-b:a", "128k", "-f", "swf"]),
    ]
    for (name, video, audio, codecs) in videos { try run(video + audio + exact + codecs + ["sample.\(name)"]) }
    // Audio.
    let audios: [(String, [String], [String])] = [
        ("wav", sound(), ["-c:a", "pcm_s16le", "-f", "wav"]),
        ("aiff", sound(), ["-c:a", "pcm_s16be", "-f", "aiff"]),
        ("aif", sound(), ["-c:a", "pcm_s16be", "-f", "aiff"]),
        ("aifc", sound(), ["-c:a", "pcm_f32be", "-f", "aiff"]),
        ("au", sound(), ["-c:a", "pcm_s16be", "-f", "au"]),
        ("voc", sound(rate: 22050, channels: 1), ["-c:a", "pcm_u8", "-f", "voc"]),
        ("flac", sound(), ["-c:a", "flac", "-f", "flac"]),
        ("caf", sound(), ["-c:a", "alac", "-f", "caf"]),
        ("aac", sound(), ["-c:a", "aac", "-b:a", "128k", "-f", "adts"]),
        ("m4a", sound(), ["-c:a", "aac", "-b:a", "128k", "-f", "ipod"]),
        ("m4b", sound(), ["-c:a", "aac", "-b:a", "128k", "-f", "ipod"]),
        ("mp3", sound(rate: 44100), ["-c:a", "libmp3lame", "-b:a", "128k", "-f", "mp3"]),
        ("ac3", sound(), ["-c:a", "ac3", "-b:a", "192k", "-f", "ac3"]),
        ("ogg", sound(), ["-c:a", "libvorbis", "-q:a", "3", "-f", "ogg"]),
        ("oga", sound(), ["-c:a", "libvorbis", "-q:a", "3", "-f", "ogg"]),
        ("opus", sound(), ["-c:a", "libopus", "-b:a", "96k", "-f", "opus"]),
        ("weba", sound(), ["-c:a", "libopus", "-b:a", "96k", "-f", "webm"]),
        ("wma", sound(rate: 44100), ["-c:a", "wmav2", "-b:a", "128k", "-f", "asf"]),
    ]
    for (name, audio, codecs) in audios { try run(audio + exact + codecs + ["sample.\(name)"]) }
    // AMR-NB (440 Hz, 8 kHz mono, 12.2 kbit/s): no AMR encoder is bundled any more (formats §2.7), so these are the bytes
    // the earlier opencore-amr build made, kept as they were; FFmpeg's native amrnb decoder reads them.
    let amr = [
        "IyFBTVIKPCQCB0gQS8fozAH69lBFFcAAYRwNbbxgAAAa4SAKB7A8LXrmkAAfh2GGA1rqxaN98bI5v39RHetHOMXUq3R7cDwkBuLoAB+f4JwDevLa",
        "Y0ralylwIx2E5k+kK5XiUGrgPC2A5ZgAZZ+BkAYq+ayaB+T3bnBGx2AEDwwyFLFHrnA8JAepSAAx2yEeAerdixwH5Y0G0A1TmYgyxuafl/eg8Dwt",
        "gOKIAGf5gQgGWt8sZzTmCA0cYvLOvaGDQtBPhQHQPCQG5UAAH59BGgH614ykyf4eHutrdjtMs8bo/QXyanA8LA/D8ABzn8CIAZo5Jj/P2bbB27mG",
        "5lQa3ffgHX3YMDwkBuWQAEuf4ZAB2srieSXn+IkmWPzdwk2Ax/7cpyiwPC2BqUgAd5/wkAY69JFsBvCApC8g7vDUrWSeYgCBkmA8JAbikAA1n2CU",
        "A1p9XGhY7obZ6qGvEZZ+6+MMpBCIIDwtgOVIAGWfgZIGOv0cfw3gs02GYa6NiCchoi3mjvtQPCQHw/AANZ/hAAGa78Z7V8QSRn9jxMY0Z0X05heO",
        "WPA8LYDlkABxn9CQBlrQgsg62pgdtht0/tBfAMAJ/vsDIDwkB6lIADXboZABugMwoXrG+n2MgATK5+zq4PB/33hwPC2A4pAAcduwCAZa3i0W9v6Y",
        "cvNUOjsZHgDjBFFNSjA8JAblSAAfn8EeAbod4A3k/b7F4M/QK1ZiWIBCzUPb8DwsD8PwAGefYIwBmmfekfztdDZXhTiWIZjGweEbtUawPCQG5ZAA",
        "H5/AsAHa/PPNLc24CCYAvC8a/4PLT+4iAnA8LYGpSAB127CIBjrYgywd8nWFOBAv3UhhOiA+qW67oDwkBuKQADe9UCgB2mCSbmDto3ZvTvJt99pk",
        "G1u3CMbwPC2A5UgAZZ/BkgY61XmGX+KzKbFbSvHoVSDgJfwxIzA8JAfD8AA1n+GSAZqCTiH6+o2uFWIZ9qBr5we0ELXY8DwtgOWQAGef0IIE2tc3",
        "QrDS02GmUuUb0knGgIlAk5TwPCQHqUgAH9uglAM6FhPkbMD+794SjAOKZf9TFAMeQKA8LYDikABP27AOBtrVHY845sMNoeiVL7oRNA7FguuW4Dwk",
        "BuVIAB+fwYIBuh0uLZTv/o9YpiPcPZEhXij/77LQPCwPw/AAN5/hgASanjixNdG/NfFdPV26JsAoJLrWx7A8JAblkAAfn+GIAdrFF5nnwI/lFrj0",
        "hQtX+HtH7BMgcDwtgalIASPbsIIDOvyOxxP2VKk2UjLNJAscxU1rawywPCQG4pAAN9uhkANaFkkE6ccwfjwA/3nIhjiXCmTCsuA8LYDlSABnn9CK",
        "BjraJkUP5PMdhg7XLpgFIoBJimP/QDwkB8PwAB+f4YIBmsJj+2j8JWIYGtfu4Fjfd56nygowPC2A5ZAAZZ/QiAZa0YqRN9xY/LARYP7JCCAEXIyB",
        "yaA8JAepSAA126GKAbpSdZwiyLlUN4Vx2dZoto1hPl/QMDwtgOKQAE/boVgGWtHJlvXSWBSkfJ4Zokw83w3Cjs3wPCQG5UgAH59gkgG6zkznyMM/",
        "yX+A9D6+2gjLzu3w0/A8LA/D8ABln2gCBhqCmRGn91aVoJJtvhx5Sox7FIc6UDwkBuWQAB+f4YIB2sC3SBTmGmcm7IIyXNiAwEv0KSqwPC2BqUgA",
        "dduwkgY61LVPkPDSqT6TjsRwINqAA8JFqaA8JAbikAA1n2EMA1r6aXIvxMUN/cIwaWD1DFw4IgOXcDwtgOVIAB+fkIAGOvou5fTqiH2NxGYp3DEi",
        "kAr9cTmgPCQHw/AANZ/BCAGa/waUnv69wY9jROcgASX94FE51LA8LYDlkABnn9CABNrd4Ps24psNMEbSTdBJhMNZwEUUMDwkB6lIADXboIgBuh2x",
        "vFLu0X6PgRDF56R3HgGZn8xwPC2A4pAAcduhHAZa2ecO9NfYaTRKDqlSGBAPAykLmvA8JAblSAAfn0GEAbr3hL2e1f05aGJ/wX4wRuolxWxkMDws",
        "D8PwAE+e4FAGGo2vo1jn7rHOXsfPYJ6ykvXMT1wwPCQG5ZAAHZ/hiAHawzVLTfYV4R9lwjX4ejByTvkidDA8LYGpSAEh27CQBjrXoaWF9VgrNIOs",
        "RIwYzIdNgFfIwDweGClCCGmRGIF0Soyq4682G1aFCygEwFYAAOFj4A4A"
    ].joined()
    try Data(base64Encoded: amr)!.write(to: folder.appendingPathComponent("sample.amr"))
    // Quality §5.3 sources: interlaced SD fields, PQ HDR with mastering metadata, a flash-and-beep clip, BT.601 bars, a
    // 24-bit tone for the resampling test.
    try run(picture("720x576", rate: "50", seconds: "1") + exact + ["-vf", "scale=720:288,weave=first_field=top,setfield=tff", "-c:v", "mpeg2video",
            "-flags:v", "+ilme+ildct+bitexact", "-q:v", "3", "-top", "1", "-an", "-f", "mpegts", "interlaced-576i.ts"])
    try run(picture("640x360", seconds: "1") + exact + ["-vf", "format=gbrp,zscale=tin=bt709:pin=bt709:min=gbr:rin=full:t=smpte2084:m=bt2020nc:p=bt2020:r=limited:npl=100,format=yuv420p10le",
            "-c:v", "libsvtav1", "-preset", "10", "-crf", "35",
            "-svtav1-params", "mastering-display=G(0.265,0.690)B(0.150,0.060)R(0.680,0.320)WP(0.3127,0.3290)L(1000,0.0050):content-light=1000,400",
            "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc", "-an", "-f", "matroska", "hdr-pq.mkv"])
    try run(["-f", "lavfi", "-i", "color=c=black:s=160x120:r=25:d=3,drawbox=w=iw:h=ih:c=white:t=fill:enable='between(t,1,1.08)'",
             "-f", "lavfi", "-i", "aevalsrc='0.5*sin(2*PI*1000*t)*between(t,1,1.08)':s=48000:d=3"] + exact
            + ["-c:v", "mpeg4", "-q:v", "2", "-c:a", "pcm_s16le", "-f", "mov", "flash-beep.mov"])
    try run(["-loop", "1", "-i", out.appendingPathComponent("smpte-bars-640x360.png").path, "-t", "1", "-r", "25"] + exact
            + ["-vf", "scale=out_color_matrix=bt601:out_range=tv,format=yuv420p", "-c:v", "mpeg4", "-q:v", "1",
               "-color_primaries", "smpte170m", "-color_trc", "smpte170m", "-colorspace", "smpte170m", "-color_range", "tv", "-f", "mov", "bars-601.mov"])
    // Computed here, not by FFmpeg's `sine` source (a table oscillator, about −80 dB THD+N): 1 kHz at −3 dBFS, 24-bit.
    var tone = Data()
    func le(_ v: UInt32, _ bytes: Int) { for i in 0..<bytes { tone.append(UInt8(v >> (8 * UInt32(i)) & 255)) } }
    let frames = 44100 * 3
    tone.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + frames * 3), 4); tone.append(contentsOf: Array("WAVEfmt ".utf8))
    le(16, 4); le(1, 2); le(1, 2); le(44100, 4); le(44100 * 3, 4); le(3, 2); le(24, 2)
    tone.append(contentsOf: Array("data".utf8)); le(UInt32(frames * 3), 4)
    for i in 0..<frames {
        let v = Int32((pow(10, -3.0 / 20) * sin(2 * .pi * 1000 * Double(i) / 44100) * 8_388_607).rounded())
        le(UInt32(bitPattern: v), 3)
    }
    try tone.write(to: folder.appendingPathComponent("tone-1k-24bit-44k.wav"))
    // A near-lossless 640×360 clip with detail and motion for the video-defaults metrics, a tagged MP3 with cover art and an
    // audiobook with chapters for the metadata test.
    try run(picture("640x360", rate: "30", seconds: "2") + exact + ["-c:v", "mpeg4", "-q:v", "1", "-an", "-f", "mov", "detail-640x360.mov"])
    try run(sound(rate: 44100, seconds: "2") + ["-i", out.appendingPathComponent("logo-alpha-128.png").path] + exact
            + ["-map", "0:a", "-map", "1:v", "-c:a", "libmp3lame", "-b:a", "128k", "-c:v", "png", "-disposition:v", "attached_pic",
               "-metadata", "title=Test tone", "-metadata", "artist=Super Converter", "-metadata", "album=Fixtures", "-metadata", "date=2026",
               "-id3v2_version", "4", "-f", "mp3", "tagged.mp3"])
    let chapters = folder.appendingPathComponent("chapters.txt")
    try ";FFMETADATA1\ntitle=Test book\nartist=Super Converter\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=1000\ntitle=One\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=1000\nEND=2000\ntitle=Two\n"
        .write(to: chapters, atomically: true, encoding: .utf8)
    try run(sound(seconds: "2") + ["-i", chapters.path] + ["-fflags", "+bitexact", "-flags:a", "+bitexact", "-map", "0:a", "-map_metadata", "1",
            "-map_chapters", "1", "-c:a", "aac", "-b:a", "96k", "-f", "ipod", "chapters.m4b"])
    try FileManager.default.removeItem(at: chapters)
    try soundFont(folder.appendingPathComponent("sample.sf2"))
}

/// A two-sample SoundFont (RIFF sfbk, SoundFont 2.04): a 440 Hz sine looped, a 660 Hz one, one preset whose instrument
/// splits the keyboard at middle C.
func soundFont(_ url: URL) throws {
    func le16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 255)); d.append(UInt8(v >> 8 & 255)) }
    func le32(_ v: Int, _ d: inout Data) { le16(v & 0xFFFF, &d); le16(v >> 16 & 0xFFFF, &d) }
    func name(_ s: String, _ d: inout Data) { var b = Array(s.utf8.prefix(20)); b += Array(repeating: 0, count: 20 - b.count); d.append(contentsOf: b) }
    func chunk(_ id: String, _ body: Data) -> Data { var d = Data(id.utf8); le32(body.count, &d); d.append(body); if body.count % 2 == 1 { d.append(0) }; return d }
    func list(_ kind: String, _ chunks: [Data]) -> Data { chunk("LIST", Data(kind.utf8) + chunks.reduce(Data(), +)) }
    let rate = 22050, length = 2205
    var smpl = Data()
    for f in [440.0, 660.0] {
        for i in 0..<length { le16(Int(Int16((sin(2 * .pi * f * Double(i) / Double(rate)) * 16000).rounded())), &smpl) }
        for _ in 0..<46 { le16(0, &smpl) }   // 46 zero samples after each sample (SoundFont 2.04 §6.1)
    }
    var info = Data()
    info += chunk("ifil", { var d = Data(); le16(2, &d); le16(4, &d); return d }())
    info += chunk("isng", Data("EMU8000\0".utf8))
    info += chunk("INAM", Data("Super Converter test\0\0".utf8))
    var phdr = Data(); name("Test Sine", &phdr); le16(0, &phdr); le16(0, &phdr); le16(0, &phdr); le32(0, &phdr); le32(0, &phdr); le32(0, &phdr)
    name("EOP", &phdr); le16(0, &phdr); le16(0, &phdr); le16(1, &phdr); le32(0, &phdr); le32(0, &phdr); le32(0, &phdr)
    var pbag = Data(); le16(0, &pbag); le16(0, &pbag); le16(1, &pbag); le16(0, &pbag)
    var pmod = Data(); for _ in 0..<5 { le16(0, &pmod) }
    var pgen = Data(); le16(41, &pgen); le16(0, &pgen); le16(0, &pgen); le16(0, &pgen)
    var inst = Data(); name("Sine", &inst); le16(0, &inst); name("EOI", &inst); le16(2, &inst)
    var ibag = Data(); le16(0, &ibag); le16(0, &ibag); le16(3, &ibag); le16(0, &ibag); le16(6, &ibag); le16(0, &ibag)
    var imod = Data(); for _ in 0..<5 { le16(0, &imod) }
    var igen = Data()
    le16(43, &igen); le16(0 | 59 << 8, &igen); le16(54, &igen); le16(1, &igen); le16(53, &igen); le16(0, &igen)
    le16(43, &igen); le16(60 | 127 << 8, &igen); le16(58, &igen); le16(76, &igen); le16(53, &igen); le16(1, &igen)
    le16(0, &igen); le16(0, &igen)
    var shdr = Data()
    for (i, n) in ["Sine 440", "Sine 660"].enumerated() {
        let start = i * (length + 46)
        name(n, &shdr); le32(start, &shdr); le32(start + length, &shdr); le32(start + 100, &shdr); le32(start + 2105, &shdr)
        le32(rate, &shdr); shdr.append(UInt8(i == 0 ? 69 : 76)); shdr.append(0); le16(0, &shdr); le16(1, &shdr)
    }
    name("EOS", &shdr); for _ in 0..<5 { le32(0, &shdr) }; le16(0, &shdr); le16(0, &shdr); le16(0, &shdr)
    let body = Data("sfbk".utf8) + list("INFO", [info]) + list("sdta", [chunk("smpl", smpl)])
        + list("pdta", [chunk("phdr", phdr), chunk("pbag", pbag), chunk("pmod", pmod), chunk("pgen", pgen), chunk("inst", inst),
                        chunk("ibag", ibag), chunk("imod", imod), chunk("igen", igen), chunk("shdr", shdr)])
    try chunk("RIFF", body).write(to: url)
}

try images()
try audio()
try documents()
try spreadsheet()
try ebooks()
try typesetting()
try cad()
try pdf()
try archives()
try imageKit()
try vector()
try media()
print("Fixtures written to \(out.path)")
