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

try images()
try audio()
try documents()
try spreadsheet()
try ebooks()
try cad()
try pdf()
try vector()
print("Fixtures written to \(out.path)")
