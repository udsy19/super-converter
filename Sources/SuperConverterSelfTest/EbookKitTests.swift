import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore
import UniformTypeIdentifiers
import EbookKit

// EbookKit's checks (WP-E): fixtures are generated here (EPUBs, FB2, HTMLZ, TXTZ, comics and CHM trees are built from
// strings and generated pictures), the writers' output is checked structurally (container.xml, OPF, nav/NCX, every part
// well-formed and in the manifest) and the readers are checked against files this file wrote by hand, independently of the
// writers. Text and metadata must round-trip.

// MARK: - Fixture helpers

private func ebDirectory(_ name: String = "ebook") -> URL {
    let url = scratch.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func ebImage(_ width: Int, _ height: Int, gray: CGFloat, type: UTType = .png) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: gray, green: 1 - gray, blue: 0.5, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

/// Writes a ZIP from (name, bytes) pairs.
private func ebZip(_ entries: [(String, Data)], named name: String, in dir: URL? = nil) -> URL {
    let url = (dir ?? ebDirectory()).appendingPathComponent(name)
    do {
        let zip = try ZipWriter(url: url)
        for (n, d) in entries { try zip.add(n, d, compress: n == "mimetype" ? false : nil) }
        try zip.finish()
    } catch { check(false, "fixture zip \(name): \(error)") }
    return url
}

private func ebRead(_ z: ZipArchive, _ name: String) -> Data? { (try? z.data(named: name)) ?? nil }

private func ebData(_ s: String) -> Data { Data(s.utf8) }

private func ebWellFormed(_ data: Data) -> Bool {
    (try? XMLDocument(data: data, options: [])) != nil
}

private func ebPlain(_ text: DocText) -> String {
    text.map { piece -> String in
        switch piece {
        case .text(let s), .code(let s): s
        case .emphasis(let t), .strong(let t), .strike(let t), .link(let t, _), .styled(let t, _): ebPlain(t)
        case .image(_, let alt): alt ?? ""
        case .math(let tex): tex
        case .lineBreak: "\n"
        case .footnoteReference(let id): "[^\(id)]"
        }
    }.joined()
}

private func ebPlain(_ blocks: [DocBlock]) -> [String] {
    blocks.flatMap { block -> [String] in
        switch block {
        case .heading(let l, let t): ["h\(l):" + ebPlain(t)]
        case .paragraph(let t, _): [ebPlain(t)]
        case .list(let ordered, _, let items): items.flatMap { ["\(ordered ? "#" : "•") " + ebPlain($0).joined(separator: " ")] }
        case .table(let table): table.rows.map { $0.map { ebPlain($0.blocks).joined(separator: " ") }.joined(separator: "|") }
        case .figure(let r, let c, _): ["fig:\(r)" + (c.map { ":" + ebPlain($0) } ?? "")]
        case .code(_, let text): ["code:" + text]
        case .quote(let inner): ebPlain(inner).map { "> " + $0 }
        case .math(let tex, _): ["math:" + tex]
        case .footnote(let id, let inner): ["note \(id): " + ebPlain(inner).joined(separator: " ")]
        case .thematicBreak: ["---"]
        case .pageBreak: ["<page>"]
        }
    }
}

private func ebDocs(_ p: Publication) -> [(id: String, title: String?, doc: DocModel)] {
    p.spine.compactMap { item in if case .document(let d) = item.content { (item.id, item.title, d) } else { nil } }
}

private let ebPNG = ebImage(40, 60, gray: 0.2)
private let ebCover = ebImage(80, 120, gray: 0.7)

/// A book that exercises every block and inline the writers produce.
private func ebSamplePublication() -> Publication {
    var meta = DocMetadata(title: "The Test Book & More", authors: ["Ada Author", "Bo Writer"], language: "en",
                           date: Date.init(timeIntervalSince1970: 1_589_673_600), summary: "A book about <testing> & things.")
    meta.pageSize = nil
    let chapter1 = DocModel(
        metadata: DocMetadata(title: "Chapter One"),
        blocks: [
            .heading(level: 1, [.text("Chapter One")]),
            .paragraph([.text("Plain, "), .emphasis([.text("emphasis")]), .text(", "), .strong([.text("strong")]), .text(", "), .strike([.text("struck")]),
                        .text(", "), .code("code()"), .text(" and a "), .link([.text("link")], destination: "https://example.com/a?b=1&c=2"),
                        .text(" with a note"), .footnoteReference(id: "c001-n1"), .text(". Unicode: café, 日本語, Ελληνικά.")], DocParagraphStyle()),
            .paragraph([.text("Centred.")], DocParagraphStyle(alignment: .centre)),
            .figure(resource: "pic1", caption: [.text("A picture")], altText: "Alt text"),
            .list(ordered: false, start: 1, items: [[.paragraph([.text("one")], DocParagraphStyle())], [.paragraph([.text("two")], DocParagraphStyle())]]),
            .table(DocTable(rows: [[.init(blocks: [.paragraph([.text("H1")], DocParagraphStyle())], isHeader: true), .init(blocks: [.paragraph([.text("H2")], DocParagraphStyle())], isHeader: true)],
                               [.init(blocks: [.paragraph([.text("a")], DocParagraphStyle())]), .init(blocks: [.paragraph([.text("b")], DocParagraphStyle())])]],
                            caption: [.text("Table caption")])),
            .quote([.paragraph([.text("Quoted words.")], DocParagraphStyle())]),
            .code(language: "swift", text: "let x = 1 < 2 && true\nprint(x)"),
            .thematicBreak,
            .footnote(id: "c001-n1", [.paragraph([.text("The note text.")], DocParagraphStyle())]),
        ],
        resources: ["pic1": ebPNG])
    let chapter2 = DocModel(
        metadata: DocMetadata(title: "Chapter Two"),
        blocks: [
            .heading(level: 1, [.text("Chapter Two")]),
            .heading(level: 2, [.text("A section")]),
            .paragraph([.text("See "), .link([.text("chapter one")], destination: "item:c001"), .text(". Inline "), .image(resource: "pic1", altText: "inline"), .text(" picture.")], DocParagraphStyle()),
            .list(ordered: true, start: 3, items: [[.paragraph([.text("third")], DocParagraphStyle())], [.paragraph([.text("fourth")], DocParagraphStyle())]]),
            .math(tex: "E = mc^2", display: true),
        ],
        resources: ["pic1": ebPNG])
    return Publication(
        metadata: meta,
        spine: [PublicationItem(id: "c001", title: "Chapter One", content: .document(chapter1)),
                PublicationItem(id: "c002", title: "Chapter Two", content: .document(chapter2))],
        contents: [ContentsEntry(title: "Chapter One", itemID: "c001"),
                   ContentsEntry(title: "Chapter Two", itemID: "c002", children: [ContentsEntry(title: "Chapter Two again", itemID: "c002")])],
        cover: "cover",
        resources: ["cover": PublicationResource(mediaType: "image/png", data: ebCover),
                    "sheet": PublicationResource(mediaType: "text/css", data: ebData("p { color: #333; }\n")),
                    "face": PublicationResource(mediaType: "application/x-font-ttf", data: Data(repeating: 7, count: 2048))])
}

// MARK: - Structure validator (EPUBCheck's structural rules that matter, run on every EPUB the tests write)

private func ebXPath(_ doc: XMLDocument, _ path: String) -> [XMLNode] { (try? doc.nodes(forXPath: path)) ?? [] }
private func ebAttr(_ node: XMLNode, _ name: String) -> String? { (node as? XMLElement)?.attribute(forName: name)?.stringValue }
private func ebLocal(_ name: String) -> String { "//*[local-name()='\(name)']" }

private func ebInspect(_ url: URL, version: Int) -> [String] {
    var problems: [String] = []
    guard let zip = try? ZipArchive(url: url) else { return ["not a zip"] }
    let names = zip.entries.filter { !$0.isDirectory }.map(\.name)
    guard let first = zip.entries.first, first.name == "mimetype", first.method == 0,
          (try? zip.data(for: first)) == ebData("application/epub+zip") else { problems.append("mimetype must be first, stored, exact"); return problems }
    guard let container = (try? zip.data(named: "META-INF/container.xml")).flatMap({ $0 }), let cdoc = try? XMLDocument(data: container),
          let opfPath = ebXPath(cdoc, ebLocal("rootfile")).first.flatMap({ ebAttr($0, "full-path") }), zip.contains(opfPath) else {
        problems.append("container.xml / rootfile"); return problems
    }
    for name in names where ["xml", "opf", "ncx", "xhtml", "html"].contains((name as NSString).pathExtension) {
        if let d = try? zip.data(named: name), !ebWellFormed(d) { problems.append("not well-formed: \(name)") }
    }
    guard let opfData = (try? zip.data(named: opfPath)).flatMap({ $0 }), let opf = try? XMLDocument(data: opfData) else { problems.append("opf unreadable"); return problems }
    let base = (opfPath as NSString).deletingLastPathComponent
    func full(_ href: String) -> String { PackagePathTest.resolve(href.removingPercentEncoding ?? href, in: base) }

    let pkg = ebXPath(opf, ebLocal("package")).first
    if pkg.flatMap({ ebAttr($0, "version") }) != (version == 3 ? "3.0" : "2.0") { problems.append("package version") }
    let uidRef = pkg.flatMap { ebAttr($0, "unique-identifier") }
    let identifiers = ebXPath(opf, "//*[local-name()='identifier']")
    guard let identifier = identifiers.first(where: { ebAttr($0, "id") == uidRef })?.stringValue, !identifier.isEmpty else { problems.append("unique-identifier does not resolve"); return problems }
    if (ebXPath(opf, ebLocal("title")).first?.stringValue ?? "").isEmpty { problems.append("dc:title") }
    if (ebXPath(opf, ebLocal("language")).first?.stringValue ?? "").isEmpty { problems.append("dc:language") }
    if version == 3 {
        let modified = ebXPath(opf, "//*[local-name()='meta'][@property='dcterms:modified']").first?.stringValue ?? ""
        if modified.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$"#, options: .regularExpression) == nil { problems.append("dcterms:modified '\(modified)'") }
    }
    let items = ebXPath(opf, "//*[local-name()='manifest']/*[local-name()='item']")
    let ids = items.compactMap { ebAttr($0, "id") }
    if Set(ids).count != ids.count { problems.append("duplicate manifest ids") }
    if ids.contains(where: { $0.first?.isNumber ?? true }) { problems.append("manifest id not an NCName") }
    var manifestPaths: [String: XMLNode] = [:]
    for item in items {
        guard let href = ebAttr(item, "href") else { problems.append("item without href"); continue }
        let p = full(href)
        if !zip.contains(p) { problems.append("manifest file missing: \(p)") }
        if manifestPaths[p] != nil { problems.append("manifest duplicate href \(p)") }
        manifestPaths[p] = item
        if ebAttr(item, "media-type") == nil { problems.append("item without media-type: \(p)") }
        if version == 2, ebAttr(item, "properties") != nil { problems.append("properties in EPUB 2") }
    }
    let known = Set(manifestPaths.keys + [opfPath, "mimetype"])
    for n in names where !n.hasPrefix("META-INF/") && !known.contains(n) { problems.append("zip file not in manifest: \(n)") }
    for ref in ebXPath(opf, "//*[local-name()='spine']/*[local-name()='itemref']") {
        guard let idref = ebAttr(ref, "idref"), let item = items.first(where: { ebAttr($0, "id") == idref }) else { problems.append("spine idref"); continue }
        if ebAttr(item, "media-type") != "application/xhtml+xml" { problems.append("spine item not XHTML: \(idref)") }
    }
    // Images and media types match their bytes
    for (path, item) in manifestPaths where ebAttr(item, "media-type")?.hasPrefix("image/") == true {
        guard let d = try? zip.data(named: path) else { continue }
        let sniffed = d.starts(with: [0x89, 0x50]) ? "image/png" : d.starts(with: [0xFF, 0xD8]) ? "image/jpeg" : d.starts(with: [0x47, 0x49]) ? "image/gif" : "other"
        if sniffed != ebAttr(item, "media-type") && sniffed != "other" { problems.append("media-type mismatch \(path)") }
    }
    // Navigation
    let spineRef = ebXPath(opf, ebLocal("spine")).first.flatMap { ebAttr($0, "toc") }
    if let spineRef, let ncxItem = items.first(where: { ebAttr($0, "id") == spineRef }), let href = ebAttr(ncxItem, "href"),
       let data = (try? zip.data(named: full(href))).flatMap({ $0 }), let ncx = try? XMLDocument(data: data) {
        let ncxBase = (full(href) as NSString).deletingLastPathComponent
        let points = ebXPath(ncx, ebLocal("navPoint"))
        if points.isEmpty { problems.append("empty NCX") }
        var expected = 1
        for p in points {
            if ebAttr(p, "playOrder") != String(expected) { problems.append("playOrder \(ebAttr(p, "playOrder") ?? "-") != \(expected)") }
            expected += 1
            if let src = ebXPath(ncx, "//*[local-name()='navPoint'][@id='\(ebAttr(p, "id") ?? "")']/*[local-name()='content']").first.flatMap({ ebAttr($0, "src") }) {
                if !zip.contains(PackagePathTest.resolve(src.removingPercentEncoding ?? src, in: ncxBase)) { problems.append("NCX target missing \(src)") }
            }
        }
        let uid = ebXPath(ncx, "//*[local-name()='meta'][@name='dtb:uid']").first.flatMap { ebAttr($0, "content") }
        if uid != identifier { problems.append("NCX uid differs from dc:identifier") }
    } else { problems.append("no NCX") }
    if version == 3 {
        let navs = items.filter { (ebAttr($0, "properties") ?? "").split(separator: " ").contains("nav") }
        if navs.count != 1 { problems.append("need exactly one nav item, have \(navs.count)") }
        if let nav = navs.first, let href = ebAttr(nav, "href"), let data = (try? zip.data(named: full(href))).flatMap({ $0 }), let doc = try? XMLDocument(data: data) {
            let toc = ebXPath(doc, "//*[local-name()='nav'][@*[local-name()='type']='toc']")
            if toc.count != 1 { problems.append("nav toc count \(toc.count)") }
            let links = ebXPath(doc, "//*[local-name()='nav']//*[local-name()='a']")
            if links.isEmpty { problems.append("nav has no links") }
            let navBase = (full(href) as NSString).deletingLastPathComponent
            for a in links { if let h = ebAttr(a, "href"), !zip.contains(PackagePathTest.resolve(h.removingPercentEncoding ?? h, in: navBase)) { problems.append("nav target missing \(h)") } }
        }
    } else if !items.filter({ ebAttr($0, "properties") != nil }).isEmpty { problems.append("EPUB 2 must not use properties") }
    // Content documents
    for (path, item) in manifestPaths where ebAttr(item, "media-type") == "application/xhtml+xml" {
        guard let data = (try? zip.data(named: path)).flatMap({ $0 }), let doc = try? XMLDocument(data: data) else { continue }
        if doc.rootElement()?.name != "html" || doc.rootElement()?.uri != "http://www.w3.org/1999/xhtml" { problems.append("\(path): root is not XHTML html") }
        if (ebXPath(doc, "//*[local-name()='head']/*[local-name()='title']").first?.stringValue ?? "").isEmpty { problems.append("\(path): empty title") }
        let dir = (path as NSString).deletingLastPathComponent
        for img in ebXPath(doc, ebLocal("img")) {
            if ebAttr(img, "alt") == nil { problems.append("\(path): img without alt") }
            if let src = ebAttr(img, "src"), !zip.contains(PackagePathTest.resolve(src.removingPercentEncoding ?? src, in: dir)) { problems.append("\(path): img missing \(src)") }
        }
        let idValues = ebXPath(doc, "//*[@id]").compactMap { ebAttr($0, "id") }
        if Set(idValues).count != idValues.count { problems.append("\(path): duplicate ids") }
        for a in ebXPath(doc, "//*[local-name()='a'][@href]") {
            guard let h = ebAttr(a, "href"), !h.contains(":") else { continue }
            if h.hasPrefix("#") { if !idValues.contains(String(h.dropFirst())) { problems.append("\(path): fragment \(h) undefined") } }
            else if !zip.contains(PackagePathTest.resolve(String(h.split(separator: "#").first ?? ""), in: dir)) { problems.append("\(path): link target missing \(h)") }
        }
        if version == 2 {
            for bad in ["section", "nav", "aside", "figure", "figcaption", "header", "footer", "s", "main"] where !ebXPath(doc, ebLocal(bad)).isEmpty { problems.append("\(path): <\(bad)> in XHTML 1.1") }
            if ebXPath(doc, "//*[@*[local-name()='type']='noteref']").count > 0 { problems.append("\(path): epub:type in EPUB 2") }
        }
    }
    return problems
}

private enum PackagePathTest {
    static func resolve(_ href: String, in dir: String) -> String {
        var parts: [String] = []
        for p in ((dir.isEmpty ? "" : dir + "/") + href).split(separator: "/") {
            if p == ".." { _ = parts.popLast() } else if p != "." { parts.append(String(p)) }
        }
        return parts.joined(separator: "/")
    }
}

// MARK: - Hand-built source EPUBs (independent of our writer)

private func ebHandEPUB3(obfuscatedFont: Data? = nil, extraEncryption: String? = nil, rtl: Bool = false, fixed: Bool = false) -> URL {
    let identifier = "urn:uuid:12345678-1234-1234-1234-123456789abc"
    var entries: [(String, Data)] = [("mimetype", ebData("application/epub+zip"))]
    entries.append(("META-INF/container.xml", ebData("""
    <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """)))
    var manifestExtra = ""
    if let font = obfuscatedFont {
        let key = Array(Insecure_SHA1.hash(identifier))
        var bytes = font
        for i in 0..<min(1040, bytes.count) { bytes[i] ^= key[i % key.count] }
        entries.append(("OPS/fonts/book.otf", bytes))
        entries.append(("META-INF/encryption.xml", ebData("""
        <?xml version="1.0"?><encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><enc:CipherData><enc:CipherReference URI="OPS/fonts/book.otf"/></enc:CipherData></enc:EncryptedData></encryption>
        """)))
        manifestExtra += "<item id=\"font\" href=\"fonts/book.otf\" media-type=\"font/otf\"/>"
    }
    if let algorithm = extraEncryption {
        entries.append(("META-INF/encryption.xml", ebData("""
        <?xml version="1.0"?><encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData><enc:EncryptionMethod Algorithm="\(algorithm)"/><enc:CipherData><enc:CipherReference URI="OPS/text/ch1.xhtml"/></enc:CipherData></enc:EncryptedData></encryption>
        """)))
    }
    let layoutMeta = fixed ? "<meta property=\"rendition:layout\">pre-paginated</meta>" : ""
    entries.append(("OPS/package.opf", ebData("""
    <?xml version="1.0" encoding="UTF-8"?>
    <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="fr">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">\(identifier)</dc:identifier><dc:title>Le Livre</dc:title><dc:creator>Zoé Écrivain</dc:creator><dc:language>fr</dc:language>
    <dc:date>2019-03-04</dc:date><dc:description>Un résumé.</dc:description><meta property="dcterms:modified">2020-01-01T00:00:00Z</meta>\(layoutMeta)
    </metadata>
    <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="img" href="images/a%20b.png" media-type="image/png"/>
    <item id="cov" href="images/cover.png" media-type="image/png" properties="cover-image"/>
    <item id="css" href="style.css" media-type="text/css"/>
    \(manifestExtra)
    </manifest>
    <spine\(rtl ? " page-progression-direction=\"rtl\"" : "")><itemref idref="nav"/><itemref idref="ch1"/><itemref idref="ch2"/></spine>
    </package>
    """)))
    entries.append(("OPS/nav.xhtml", ebData("""
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Nav</title></head><body>
    <nav epub:type="landmarks"><ol><li><a href="text/ch1.xhtml">Start</a></li></ol></nav>
    <nav epub:type="toc"><h1>Contents</h1><ol><li><a href="text/ch1.xhtml">Premier chapitre</a><ol><li><a href="text/ch2.xhtml#s">Sous-partie</a></li></ol></li><li><a href="text/ch2.xhtml">Second</a></li></ol></nav>
    </body></html>
    """)))
    entries.append(("OPS/text/ch1.xhtml", ebData("""
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Un</title></head><body>
    <h1>Premier   chapitre</h1>
    <p style="text-align: center">Texte <b>gras</b> et <i>italique</i> avec note<a epub:type="noteref" href="#n1">1</a> et <a href="ch2.xhtml#s">lien interne</a>
       et <a href="http://example.org/">lien externe</a>.</p>
    <p><img src="../images/a%20b.png" alt="image"/></p>
    <ul><li>un</li><li>deux<ul><li>sous</li></ul></li></ul>
    <aside epub:type="footnote" id="n1"><p>La note.</p></aside>
    </body></html>
    """)))
    entries.append(("OPS/text/ch2.xhtml", ebData("""
    <?xml version="1.0" encoding="UTF-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Deux</title></head><body>
    <h2 id="s">Sous-partie</h2><pre><code class="language-python">x = 1
    y = 2</code></pre>
    <table><thead><tr><th>A</th><th>B</th></tr></thead><tbody><tr><td>1</td><td colspan="1">2</td></tr></tbody></table>
    </body></html>
    """)))
    entries.append(("OPS/images/a b.png", ebPNG))
    entries.append(("OPS/images/cover.png", ebCover))
    entries.append(("OPS/style.css", ebData("p { margin: 0; }")))
    return ebZip(entries, named: "hand.epub")
}

private enum Insecure_SHA1 {
    static func hash(_ s: String) -> [UInt8] {
        // SHA-1 of the identifier, via `shasum` semantics implemented locally so the fixture does not share code with the reader.
        var h: [UInt32] = [0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0]
        var message = Array(s.utf8)
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in (0..<8).reversed() { message.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xFF)) }
        for chunk in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 { w[i] = (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(message[chunk + i * 4 + $1]) } }
            for i in 16..<80 { let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]; w[i] = (x << 1) | (x >> 31) }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32) = i < 20 ? ((b & c) | (~b & d), 0x5A82_7999) : i < 40 ? (b ^ c ^ d, 0x6ED9_EBA1)
                    : i < 60 ? ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC) : (b ^ c ^ d, 0xCA62_C1D6)
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return h.flatMap { v in (0..<4).reversed().map { UInt8((v >> UInt32($0 * 8)) & 0xFF) } }
    }
}

private func ebHandEPUB2() -> URL {
    ebZip([
        ("mimetype", ebData("application/epub+zip")),
        ("META-INF/container.xml", ebData("""
        <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)),
        ("content.opf", ebData("""
        <?xml version="1.0"?>
        <package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="id">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
        <dc:title>Old Book</dc:title><dc:creator opf:role="aut">Old Author</dc:creator><dc:identifier id="id">isbn-0</dc:identifier><dc:language>en-GB</dc:language>
        <meta name="cover" content="coverimg"/></metadata>
        <manifest><item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="p1" href="a.html" media-type="application/xhtml+xml"/>
        <item id="p2" href="b.html" media-type="application/xhtml+xml"/><item id="coverimg" href="c.jpg" media-type="image/jpeg"/></manifest>
        <spine toc="ncx"><itemref idref="p1"/><itemref idref="p2"/></spine>
        <guide><reference type="cover" title="Cover" href="a.html"/></guide></package>
        """)),
        ("toc.ncx", ebData("""
        <?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head/><docTitle><text>Old Book</text></docTitle><navMap>
        <navPoint id="n1" playOrder="1"><navLabel><text>First</text></navLabel><content src="a.html"/></navPoint>
        <navPoint id="n2" playOrder="2"><navLabel><text>Second</text></navLabel><content src="b.html#x"/><navPoint id="n3" playOrder="3"><navLabel><text>Nested</text></navLabel><content src="b.html"/></navPoint></navPoint>
        </navMap></ncx>
        """)),
        ("a.html", ebData("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>A</title></head><body><h1>First</h1><p>Hello &amp; welcome&nbsp;friends &#233;&#x41;.</p></body></html>")),
        ("b.html", ebData("<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>B</title></head><body><h1 id=\"x\">Second</h1><p>World<br/>wide.</p></body></html>")),
        ("c.jpg", ebImage(30, 30, gray: 0.4, type: .jpeg)),
    ], named: "old.epub")
}

/// A FictionBook with every element the reader knows, declared in `encoding` (the caller encodes it).
private func ebFB2(encoding: String) -> String {
    let pngBase64 = ebCover.base64EncodedString(options: .lineLength76Characters)
    return """
    <?xml version="1.0" encoding="\(encoding)"?>
    <FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink">
    <description><title-info><genre>prose</genre>
    <author><first-name>Лев</first-name><middle-name>Николаевич</middle-name><last-name>Толстой</last-name></author><author><nickname>Anon</nickname></author>
    <book-title>Война и мир</book-title><annotation><p>Роман.</p></annotation><date value="1869-01-01">1869</date><coverpage><image l:href="#cover.png"/></coverpage><lang>ru</lang></title-info></description>
    <body><title><p>Том первый</p></title><epigraph><p>Эпиграф</p><text-author>Автор</text-author></epigraph>
    <section id="s1"><title><p>Глава</p><p>первая</p></title><p>Первый <emphasis>абзац</emphasis> и <strong>жирный</strong>, <strikethrough>зачёркнутый</strikethrough>, H<sub>2</sub>O<a l:href="#n1" type="note">[1]</a>.</p>
    <empty-line/><p>Второй <a l:href="http://example.com">ссылка</a>.</p><image l:href="#cover.png"/>
    <poem><stanza><v>Строка раз</v><v>Строка два</v></stanza><text-author>Поэт</text-author></poem>
    <section><title><p>Подраздел</p></title><cite><p>Цитата</p></cite><p>Вложенный.</p></section></section>
    <section id="s2"><title><p>Глава вторая</p></title><p>Конец.</p><table><tr><th>a</th><th>b</th></tr><tr><td>1</td><td>2</td></tr></table></section></body>
    <body name="notes"><section id="n1"><title><p>1</p></title><p>Примечание.</p></section></body>
    <binary id="cover.png" content-type="image/png">\(pngBase64)</binary></FictionBook>
    """
}

// MARK: - Cases

func registerEbookKitTests() {
    SelfTest.cases.append(("EbookKit.installs", {
        installFakes()
        EbookKitModule.install()
        let ids = Set(Services.converters.converters.map(\.id))
        check(ids == [.epubReader, .oebReader, .fb2Reader, .htmlzReader, .txtzReader, .comicReader, .chmReader, .ebookKit], "registered engines: \(ids)")
    }))
    SelfTest.cases.append(("EbookKit.zip", ebookZip))
    SelfTest.cases.append(("EbookKit.markup", ebookMarkup))
    SelfTest.cases.append(("EbookKit.epub3Structure", { ebookWriterStructure(version: 3) }))
    SelfTest.cases.append(("EbookKit.epub2Structure", { ebookWriterStructure(version: 2) }))
    SelfTest.cases.append(("EbookKit.epubRoundTrip", ebookEPUBRoundTrip))
    SelfTest.cases.append(("EbookKit.epubReadsHandBuilt", ebookReadsHandBuilt))
    SelfTest.cases.append(("EbookKit.epub2ReadsHandBuilt", ebookReadsEPUB2))
    SelfTest.cases.append(("EbookKit.epubFontsAndDRM", ebookFontsAndDRM))
    SelfTest.cases.append(("EbookKit.epubDamaged", ebookDamaged))
    SelfTest.cases.append(("EbookKit.oeb", ebookOEB))
    SelfTest.cases.append(("EbookKit.fb2", ebookFB2))
    SelfTest.cases.append(("EbookKit.htmlz", ebookHTMLZ))
    SelfTest.cases.append(("EbookKit.txtz", ebookTXTZ))
    SelfTest.cases.append(("EbookKit.comics", ebookComics))
    SelfTest.cases.append(("EbookKit.chm", ebookCHM))
    SelfTest.cases.append(("EbookKit.writerOptions", ebookWriterOptions))
    SelfTest.cases.append(("EbookKit.documentBridge", ebookDocumentBridge))
    SelfTest.cases.append(("EbookKit.converters", ebookConverters))
    SelfTest.cases.append(("EbookKit.routesCovered", ebookRoutesCovered))
    SelfTest.cases.append(("EbookKit.damagedInputNeverCrashes", ebookDamagedInputNeverCrashes))
}

@MainActor private func ebookZip() {
    let dir = ebDirectory()
    let url = dir.appendingPathComponent("t.zip")
    let big = Data((0..<20_000).map { UInt8(truncatingIfNeeded: $0 / 7) })
    do {
        let w = try ZipWriter(url: url)
        try w.add("mimetype", ebData("application/epub+zip"), compress: false)
        try w.add("dir/text.txt", Data(String(repeating: "hello ", count: 500).utf8))
        try w.add("dir/bin.dat", big)
        try w.add("empty", Data())
        try w.add("é ü.txt", ebData("unicode name"))
        try w.finish()
        let z = try ZipArchive(url: url)
        check(z.entries.map(\.name) == ["mimetype", "dir/text.txt", "dir/bin.dat", "empty", "é ü.txt"], "entry names \(z.entries.map(\.name))")
        check(z.entries[0].method == 0 && z.entries[1].method == 8, "stored and deflated methods")
        check(ebRead(z, "dir/bin.dat") == big, "deflated bytes round-trip")
        check(ebRead(z, "DIR/TEXT.TXT")?.count == 3000, "case-insensitive fallback")
        check(ebRead(z, "empty") == Data(), "empty entry")
        check(ebRead(z, "é ü.txt") == ebData("unicode name"), "unicode name")
        check(ebRead(z, "nope") == nil, "missing entry is nil")
        // Corruption is caught by the CRC
        var bytes = try Data(contentsOf: url)
        let at = bytes.range(of: ebData("unicode name"))!.lowerBound
        bytes[at] ^= 0xFF
        let z2 = try ZipArchive(data: bytes)
        var failed = false
        do { _ = try z2.data(named: "é ü.txt") } catch { failed = true }
        check(failed, "CRC mismatch is an error")
        check((try? ZipArchive(data: ebData("not a zip at all, just text of some length"))) == nil, "garbage is not a zip")
    } catch { check(false, "zip: \(error)") }
}

@MainActor private func ebookMarkup() {
    // The reader path is exercised through HTMLZ with sloppy HTML.
    let html = "<html><head><title>T</title><style>p{}</style></head><body><h1>Head</h1><p>One<p>Two &amp; &lt;b&gt; &copy; &#8212;<ul><li>a<li>b</ul><BR>after<script>var x = '<p>';</script></body></html>"
    let url = ebZip([("index.html", ebData(html))], named: "sloppy.htmlz")
    do {
        let r = try HTMLZReader.read(url: url)
        let text = ebDocs(r.publication).flatMap { ebPlain($0.doc.blocks) }
        check(text.contains("h1:Head"), "heading kept: \(text)")
        check(text.contains("One") && text.contains("Two & <b> © —"), "implied </p> and entities: \(text)")
        check(text.contains("• a") && text.contains("• b"), "implied </li>: \(text)")
        check(!text.joined().contains("var x"), "script dropped")
    } catch { check(false, "sloppy html: \(error)") }
}

@MainActor private func ebookWriterStructure(version: Int) {
    let dir = ebDirectory()
    let url = dir.appendingPathComponent("out.epub")
    var options = PackageWriteOptions()
    options.epubVersion = version
    do {
        _ = try EPUBWriter.write(ebSamplePublication(), to: url, options: options)
        let problems = ebInspect(url, version: version)
        check(problems.isEmpty, "EPUB \(version) structure: \(problems)")
        let zip = try ZipArchive(url: url)
        let names = zip.entries.map(\.name)
        check(names.first == "mimetype" && names.contains("META-INF/container.xml") && names.contains("OEBPS/content.opf") && names.contains("OEBPS/toc.ncx"),
              "core parts present: \(names)")
        check(version == 3 ? names.contains("OEBPS/nav.xhtml") : !names.contains("OEBPS/nav.xhtml"), "nav document only in EPUB 3")
        let opf = String(decoding: try zip.data(named: "OEBPS/content.opf")!, as: UTF8.self)
        check(opf.contains("The Test Book &amp; More") && opf.contains("Ada Author") && opf.contains("<dc:date>2020-05-17</dc:date>"), "metadata in OPF")
        check(opf.contains("A book about &lt;testing&gt; &amp; things."), "summary escaped")
        let chapter = String(decoding: try zip.data(named: "OEBPS/text/0001.xhtml")!, as: UTF8.self)
        check(chapter.contains("let x = 1 &lt; 2 &amp;&amp; true"), "code escaped")
        check(chapter.contains("https://example.com/a?b=1&amp;c=2"), "link escaped")
        check(version == 3 ? chapter.contains("epub:type=\"noteref\"") && chapter.contains("<!DOCTYPE html>") : chapter.contains("XHTML 1.1"), "flavour markup")
        check(chapter.contains("The note text."), "footnote text written")
        let second = String(decoding: try zip.data(named: "OEBPS/text/0002.xhtml")!, as: UTF8.self)
        check(second.contains("href=\"0001.xhtml\""), "item: link resolved to the chapter file")
        check(version == 3 ? second.contains("start=\"3\"") : !second.contains("start="), "ol start only in EPUB 3")
        check(opf.contains("cover-image") == (version == 3), "cover-image property only in EPUB 3")
    } catch { check(false, "write EPUB \(version): \(error)") }
}

@MainActor private func ebookEPUBRoundTrip() {
    let dir = ebDirectory()
    let url = dir.appendingPathComponent("rt.epub")
    let original = ebSamplePublication()
    do {
        try EPUBWriter.write(original, to: url)
        let back = try EPUBReader.read(url: url).publication
        check(back.metadata.title == original.metadata.title, "title \(back.metadata.title ?? "-")")
        check(back.metadata.authors == original.metadata.authors, "authors \(back.metadata.authors)")
        check(back.metadata.language == "en", "language")
        check(back.metadata.summary == original.metadata.summary, "summary")
        check(back.metadata.date == original.metadata.date, "date")
        check(back.spine.count == 2 && back.layout == .reflowable && back.direction == .leftToRight, "spine, layout, direction")
        check(back.contents.map(\.title) == ["Chapter One", "Chapter Two"] && back.contents[1].children.map(\.title) == ["Chapter Two again"], "contents tree \(back.contents)")
        check(back.cover != nil && back.resources[back.cover!]?.data == ebCover, "cover bytes")
        check(back.resources.values.contains { $0.mediaType == "text/css" && $0.data == ebData("p { color: #333; }\n") }, "carried stylesheet")
        check(back.resources.values.contains { $0.data == Data(repeating: 7, count: 2048) }, "carried font")
        let after = ebDocs(back)
        check(after.count == 2, "two documents")
        let c1 = ebPlain(after[0].doc.blocks)
        check(c1.contains("h1:Chapter One"), "heading round-trips: \(c1)")
        check(c1.contains { $0.hasPrefix("Plain, emphasis, strong, struck, code() and a link with a note") && $0.hasSuffix("Unicode: café, 日本語, Ελληνικά.") }, "paragraph text round-trips: \(c1)")
        check(c1.contains("• one") && c1.contains("• two") && c1.contains("H1|H2") && c1.contains("a|b") && c1.contains("> Quoted words."), "list, table, quote")
        check(c1.contains("code:let x = 1 < 2 && true\nprint(x)") && c1.contains("---"), "code and rule")
        check(c1.contains { $0.contains("The note text.") && $0.hasPrefix("note ") }, "footnote survives")
        check(c1.contains { $0.hasPrefix("fig:") && $0.hasSuffix(":A picture") }, "figure caption")
        check(after[0].doc.resources.values.contains(ebPNG), "picture bytes unchanged")
        if case .paragraph(let text, _) = after[0].doc.blocks[1] {
            check(text.contains { if case .link(_, let d) = $0 { d == "https://example.com/a?b=1&c=2" } else { false } }, "external link kept")
            check(text.contains { if case .strong = $0 { true } else { false } }, "strong kept")
        } else { check(false, "second block is a paragraph") }
        let c2 = ebPlain(after[1].doc.blocks)
        check(c2.contains("h2:A section") && c2.contains("# third") && c2.contains("# fourth"), "chapter two: \(c2)")
        if case .paragraph(let text, _) = after[1].doc.blocks[2] {
            check(text.contains { if case .link(_, let d) = $0 { d == "item:" + after[0].id } else { false } }, "chapter link resolves to the first item")
        }
        // Write the re-read book again: stable text, still valid
        let url2 = dir.appendingPathComponent("rt2.epub")
        try EPUBWriter.write(back, to: url2)
        check(ebInspect(url2, version: 3).isEmpty, "second generation is valid: \(ebInspect(url2, version: 3))")
        let again = try EPUBReader.read(url: url2).publication
        func stable(_ docs: [(id: String, title: String?, doc: DocModel)]) -> [[String]] {
            docs.map { ebPlain($0.doc.blocks).filter { !$0.hasPrefix("note ") && !$0.hasPrefix("fig:") && !$0.contains("[^") } }
        }
        check(stable(ebDocs(again)) == stable(after), "text stable across generations: \(stable(ebDocs(again))) vs \(stable(after))")
    } catch { check(false, "round trip: \(error)") }
}

@MainActor private func ebookReadsHandBuilt() {
    do {
        let r = try EPUBReader.read(url: ebHandEPUB3(rtl: true))
        let p = r.publication
        check(p.metadata.title == "Le Livre" && p.metadata.authors == ["Zoé Écrivain"] && p.metadata.language == "fr" && p.metadata.summary == "Un résumé.", "metadata \(p.metadata)")
        check(p.direction == .rightToLeft, "page progression direction")
        check(p.spine.map(\.id) == ["ch1", "ch2"], "nav document is not a chapter: \(p.spine.map(\.id))")
        check(p.contents.map(\.title) == ["Premier chapitre", "Second"] && p.contents[0].children.map(\.title) == ["Sous-partie"], "nav tree \(p.contents)")
        check(p.cover == "cov" && p.resources["cov"]?.data == ebCover, "cover-image property")
        check(p.resources["css"]?.mediaType == "text/css" && p.resources["img"]?.data == ebPNG, "resources by manifest id, percent-decoded href")
        let docs = ebDocs(p)
        let one = ebPlain(docs[0].doc.blocks)
        check(one.first == "h1:Premier chapitre", "whitespace collapsed in heading: \(one)")
        check(one.contains { $0.hasPrefix("Texte gras et italique avec note[^ch1-n1] et lien interne et lien externe.") }, "paragraph with note ref: \(one)")
        check(one.contains("fig:img"), "image resolved through percent-encoded path")
        check(one.contains { $0.hasPrefix("note ch1-n1: ") && $0.contains("La note.") }, "footnote lifted out of the flow")
        check(!one.contains { $0.hasPrefix("La note") }, "note not duplicated in the flow")
        check(one.contains("• un") && one.contains("• deux sous") == false, "nested list")
        if case .paragraph(let t, let s) = docs[0].doc.blocks[1] {
            check(s.alignment == .centre, "text-align from style")
            check(t.contains { if case .link(_, let d) = $0 { d == "item:ch2" } else { false } }, "internal link → item:ch2")
            check(t.contains { if case .link(_, let d) = $0 { d == "http://example.org/" } else { false } }, "external link")
        } else { check(false, "paragraph expected") }
        let two = ebPlain(docs[1].doc.blocks)
        check(two.contains("code:x = 1\ny = 2") && two.contains("A|B") && two.contains("1|2"), "pre and table: \(two)")
        if case .code(let lang, _) = docs[1].doc.blocks[1] { check(lang == "python", "code language") }
        check(docs[0].title == "Premier chapitre" && docs[1].title == "Second", "item titles come from the contents: \(docs.map(\.title))")
        // Fixed layout flag
        let f = try EPUBReader.read(url: ebHandEPUB3(fixed: true)).publication
        check(f.layout == .fixed, "rendition:layout")
    } catch { check(false, "hand-built EPUB 3: \(error)") }
}

@MainActor private func ebookReadsEPUB2() {
    do {
        let p = try EPUBReader.read(url: ebHandEPUB2()).publication
        check(p.metadata.title == "Old Book" && p.metadata.authors == ["Old Author"] && p.metadata.language == "en-GB", "EPUB 2 metadata")
        check(p.contents.map(\.title) == ["First", "Second"] && p.contents[1].children.map(\.title) == ["Nested"], "NCX tree \(p.contents)")
        check(p.cover == "coverimg", "meta cover")
        let text = ebDocs(p).flatMap { ebPlain($0.doc.blocks) }
        check(text.contains("Hello & welcome\u{A0}friends éA."), "entities decoded: \(text)")
        check(text.contains("World\nwide."), "br becomes a line break: \(text)")
        check(p.direction == .leftToRight && p.layout == .reflowable, "defaults")
    } catch { check(false, "hand-built EPUB 2: \(error)") }
}

@MainActor private func ebookFontsAndDRM() {
    let font = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 5) })
    do {
        let p = try EPUBReader.read(url: ebHandEPUB3(obfuscatedFont: font)).publication
        check(p.resources["font"]?.data == font, "IDPF-obfuscated font is restored")
        var thrown: ConversionError?
        do { _ = try EPUBReader.read(url: ebHandEPUB3(extraEncryption: "http://www.w3.org/2001/04/xmlenc#aes128-cbc")) } catch { thrown = error as? ConversionError }
        check(thrown == .drmProtected, "encrypted content is DRM: \(String(describing: thrown))")
    } catch { check(false, "fonts: \(error)") }
}

@MainActor private func ebookDamaged() {
    let dir = ebDirectory()
    let junk = dir.appendingPathComponent("junk.epub")
    try? ebData("this is not a zip file at all, but it is long enough to look like one").write(to: junk)
    var e1: ConversionError?
    do { _ = try EPUBReader.read(url: junk) } catch { e1 = error as? ConversionError }
    check(e1 == .damaged("epub"), "junk → damaged: \(String(describing: e1))")
    let noOPF = ebZip([("mimetype", ebData("application/epub+zip")), ("hello.txt", ebData("hi"))], named: "empty.epub")
    var e2: ConversionError?
    do { _ = try EPUBReader.read(url: noOPF) } catch { e2 = error as? ConversionError }
    check(e2 == .damaged("epub"), "no package → damaged: \(String(describing: e2))")
    // A truncated archive
    do {
        let good = dir.appendingPathComponent("good.epub")
        try EPUBWriter.write(ebSamplePublication(), to: good)
        let bytes = try Data(contentsOf: good)
        let cut = dir.appendingPathComponent("cut.epub")
        try bytes.prefix(bytes.count / 2).write(to: cut)
        var e3: ConversionError?
        do { _ = try EPUBReader.read(url: cut) } catch { e3 = error as? ConversionError }
        check(e3 == .damaged("epub"), "truncated → damaged: \(String(describing: e3))")
        // Missing container.xml falls back to the first .opf
        let zip = try ZipArchive(url: good)
        let entries = try zip.entries.filter { $0.name != "META-INF/container.xml" && !$0.isDirectory }.map { ($0.name, try zip.data(for: $0)) }
        let bare = ebZip(entries, named: "nocontainer.epub")
        check((try? EPUBReader.read(url: bare))?.publication.spine.count == 2, "missing container.xml → first OPF")
    } catch { check(false, "damaged: \(error)") }
}

@MainActor private func ebookOEB() {
    let dir = ebDirectory()
    let url = dir.appendingPathComponent("book.oeb")
    do {
        _ = try OEBWriter.write(ebSamplePublication(), to: url)
        let zip = try ZipArchive(url: url)
        let names = zip.entries.map(\.name)
        check(names.contains("content.opf") && names.contains("contents.html") && !names.contains("mimetype") && !names.contains("META-INF/container.xml"), "OEB layout \(names)")
        for n in names where ["opf", "html"].contains((n as NSString).pathExtension) {
            check(ebWellFormed(ebRead(zip, n) ?? Data()), "well-formed \(n)")
        }
        let opf = String(decoding: try zip.data(named: "content.opf")!, as: UTF8.self)
        check(opf.contains("OEB 1.2 Package") && opf.contains("<dc:Title>The Test Book &amp; More</dc:Title>") && opf.contains("text/x-oeb1-document") && opf.contains("text/x-oeb1-css"), "OEB 1.2 vocabulary")
        let back = try OEBReader.read(url: url).publication
        check(back.metadata.title == "The Test Book & More" && back.metadata.authors == ["Ada Author", "Bo Writer"] && back.metadata.language == "en", "OEB metadata round trip \(back.metadata)")
        check(back.spine.count == 2, "OEB spine")
        check(back.contents.map(\.title) == ["Chapter One", "Chapter Two"], "contents via guide page: \(back.contents)")
        check(back.cover != nil && back.resources[back.cover!]?.data == ebCover, "OEB cover via guide")
        let t = ebDocs(back).flatMap { ebPlain($0.doc.blocks) }
        check(t.contains("h1:Chapter One") && t.contains { $0.contains("Unicode: café, 日本語, Ελληνικά.") } && t.contains("H1|H2"), "OEB text round trip: \(t)")
        // Bare OPF next to its parts (an unpacked OEB folder)
        let folder = ebDirectory("unpacked")
        for e in zip.entries where !e.isDirectory {
            let dest = folder.appendingPathComponent(e.name)
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try zip.data(for: e).write(to: dest)
        }
        let bare = try OEBReader.read(url: folder.appendingPathComponent("content.opf")).publication
        check(bare.spine.count == 2 && bare.metadata.title == "The Test Book & More", "unpacked OEB folder")
    } catch { check(false, "oeb: \(error)") }
}

@MainActor private func ebookFB2() {
    let dir = ebDirectory()
    do {
        // windows-1251 declared and encoded
        let cp1251 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding("windows-1251" as CFString)))
        let url = dir.appendingPathComponent("book.fb2")
        try ebFB2(encoding: "windows-1251").data(using: cp1251)!.write(to: url)
        let r = try FB2Reader.read(url: url)
        let p = r.publication
        check(p.metadata.title == "Война и мир" && p.metadata.authors == ["Лев Николаевич Толстой", "Anon"] && p.metadata.language == "ru", "FB2 metadata (cp1251): \(p.metadata)")
        check(p.metadata.summary == "Роман.", "annotation")
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        check(p.metadata.date.map { utc.component(.year, from: $0) } == 1869, "date")
        check(p.cover == "cover.png" && p.resources["cover.png"]?.data == ebCover, "cover binary")
        check(p.spine.count == 3, "front matter + two top-level sections: \(p.spine.map(\.title))")
        check(p.contents.map(\.title) == ["Том первый", "Глава первая", "Глава вторая"], "contents \(p.contents.map(\.title))")
        let docs = ebDocs(p)
        let front = ebPlain(docs[0].doc.blocks)
        check(front.first == "h1:Том первый" && front.contains("> Эпиграф"), "body title and epigraph: \(front)")
        let ch1 = ebPlain(docs[1].doc.blocks)
        check(ch1.first == "h1:Глава первая", "multi-paragraph title joined: \(ch1)")
        check(ch1.contains { $0.hasPrefix("Первый абзац и жирный, зачёркнутый, H2O[^") }, "inline markup and note ref: \(ch1)")
        check(ch1.contains { $0.hasPrefix("note ") && $0.contains("Примечание.") }, "note body becomes a footnote")
        check(ch1.contains("> Строка раз\nСтрока два\n> Поэт".replacingOccurrences(of: "\n> Поэт", with: "")) || ch1.contains { $0.contains("Строка раз\nСтрока два") }, "poem stanza lines")
        check(ch1.contains("h2:Подраздел") && ch1.contains("> Цитата") && ch1.contains("Вложенный."), "nested section is a level-2 heading")
        check(ch1.contains { $0.hasPrefix("fig:cover.png") }, "block image")
        check(ebPlain(docs[2].doc.blocks).contains("a|b") && ebPlain(docs[2].doc.blocks).contains("1|2"), "table")
        // The same book as UTF-8 inside a zip (.fb2.zip) and via EPUB
        let utf = dir.appendingPathComponent("u.fb2")
        try ebData(ebFB2(encoding: "utf-8")).write(to: utf)
        let z = ebZip([("u.fb2", ebData(ebFB2(encoding: "utf-8")))], named: "u.fb2.zip", in: dir)
        check((try? FB2Reader.read(url: z))?.publication.metadata.title == "Война и мир", "zipped FB2")
        let epub = dir.appendingPathComponent("fb2.epub")
        try EPUBWriter.write(try FB2Reader.read(url: utf).publication, to: epub)
        check(ebInspect(epub, version: 3).isEmpty, "FB2 → EPUB is valid: \(ebInspect(epub, version: 3))")
        let again = try EPUBReader.read(url: epub).publication
        check(ebDocs(again).flatMap { ebPlain($0.doc.blocks) }.contains("h1:Глава вторая"), "FB2 → EPUB → read keeps the text")
        // Not FB2
        let bad = dir.appendingPathComponent("bad.fb2")
        try ebData("<html><body>nope</body></html>").write(to: bad)
        var thrown: ConversionError?
        do { _ = try FB2Reader.read(url: bad) } catch { thrown = error as? ConversionError }
        check(thrown == .damaged("fb2"), "non-FB2 → damaged")
    } catch { check(false, "fb2: \(error)") }
}

/// An HTMLZ: index.html with headings, styled text and a picture, metadata.opf with a cover.
private func ebHTMLZ() -> URL {
    let opf = """
    <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Zipped</dc:title><dc:creator>Zed</dc:creator><dc:language>de</dc:language><dc:identifier id="id">x</dc:identifier></metadata>
    <manifest><item id="c" href="cover.png" media-type="image/png"/></manifest><spine/><guide><reference type="cover" href="cover.png"/></guide></package>
    """
    let html = """
    <!DOCTYPE html><html><head><meta charset="utf-8"/><title>Zipped</title></head><body>
    <h1>Eins</h1><p>Erster Absatz mit <em>Betonung</em> und Bild <img src="images/x.png" alt="x"/>.</p>
    <h1>Zwei</h1><p style="text-align:right">Rechts.</p><p><img src="images/x.png" alt="solo"/></p></body></html>
    """
    return ebZip([("index.html", ebData(html)), ("metadata.opf", ebData(opf)), ("cover.png", ebCover), ("images/x.png", ebPNG)], named: "b.htmlz")
}

@MainActor private func ebookHTMLZ() {
    let url = ebHTMLZ()
    do {
        let p = try HTMLZReader.read(url: url).publication
        check(p.metadata.title == "Zipped" && p.metadata.authors == ["Zed"] && p.metadata.language == "de", "HTMLZ metadata")
        check(p.cover != nil && p.resources[p.cover!]?.data == ebCover, "HTMLZ cover")
        check(p.spine.count == 2 && p.contents.map(\.title) == ["Eins", "Zwei"], "split at h1: \(p.contents)")
        let docs = ebDocs(p)
        check(ebPlain(docs[0].doc.blocks).contains { $0.hasPrefix("Erster Absatz mit Betonung und Bild") }, "text")
        check(docs[0].doc.resources["images/x.png"] == ebPNG && docs[1].doc.resources["images/x.png"] == ebPNG, "each chapter keeps the pictures it uses")
        if case .paragraph(_, let s) = docs[1].doc.blocks[1] { check(s.alignment == .end, "alignment") } else { check(false, "paragraph") }
        let epub = scratch.appendingPathComponent("htmlz-\(UUID().uuidString).epub")
        try EPUBWriter.write(p, to: epub)
        check(ebInspect(epub, version: 3).isEmpty, "HTMLZ → EPUB valid: \(ebInspect(epub, version: 3))")
    } catch { check(false, "htmlz: \(error)") }
}

/// A TXTZ: light Markdown with every construct the reader knows, metadata.opf and a picture.
private func ebTXTZ() -> URL {
    let text = """
    # Capítulo uno

    Primer párrafo con *énfasis* y **negrita** y `código`,
    que continúa en la línea siguiente. Ver [enlace](http://example.com).

    - alfa
    - beta

    1. uno
    2. dos

    > Una cita.

    ![figura](pics/a.png)

    ---

    Título subrayado
    ================

    Fin con 2 * 3 * 4 sin énfasis.
    """
    let opf = "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>Texto</dc:title><dc:language>es</dc:language></metadata></package>"
    return ebZip([("index.txt", ebData(text)), ("metadata.opf", ebData(opf)), ("pics/a.png", ebPNG)], named: "t.txtz")
}

@MainActor private func ebookTXTZ() {
    let url = ebTXTZ()
    do {
        let p = try TXTZReader.read(url: url).publication
        check(p.metadata.title == "Texto" && p.metadata.language == "es", "TXTZ metadata")
        let t = ebDocs(p).flatMap { ebPlain($0.doc.blocks) }
        check(t.contains("h1:Capítulo uno"), "ATX heading: \(t)")
        check(t.contains("Primer párrafo con énfasis y negrita y código, que continúa en la línea siguiente. Ver enlace."), "wrapped lines joined, inline marks: \(t)")
        check(t.contains("• alfa") && t.contains("• beta") && t.contains("# uno") && t.contains("# dos"), "lists")
        check(t.contains("> Una cita.") && t.contains("---") && t.contains("h1:Título subrayado"), "quote, rule, setext")
        check(t.contains("fig:pics/a.png"), "picture")
        check(t.contains("Fin con 2 * 3 * 4 sin énfasis."), "stray asterisks stay text")
        check(ebDocs(p).contains { $0.doc.resources["pics/a.png"] == ebPNG }, "picture bytes")
    } catch { check(false, "txtz: \(error)") }
}

@MainActor private func ebookComics() {
    func page(_ n: Int) -> Data { ebImage(60 + n, 90, gray: CGFloat(n % 10) / 10, type: n % 2 == 0 ? .png : .jpeg) }
    let names = ["Comic/page2.png", "Comic/page10.jpg", "Comic/page1.jpg", "Comic/.hidden.png", "__MACOSX/Comic/page1.jpg", "Comic/notes.txt"]
    let pages: [String: Data] = ["Comic/page1.jpg": page(1), "Comic/page2.png": page(2), "Comic/page10.jpg": page(11)]
    let info = "<?xml version=\"1.0\"?><ComicInfo><Title>Issue One</Title><Series>Heroes</Series><Number>1</Number><Writer>Ann, Ben</Writer><LanguageISO>ja</LanguageISO><Year>2021</Year><Month>3</Month><Day>9</Day><Manga>YesAndRightToLeft</Manga></ComicInfo>"
    var entries: [(String, Data)] = names.map { ($0, pages[$0] ?? ebData("x")) }
    entries.append(("ComicInfo.xml", ebData(info)))
    let cbz = ebZip(entries, named: "issue.cbz")
    let work = ebDirectory()
    do {
        let r = complete(30) { try await ComicReader.read(url: cbz, format: "cbz", workFolder: work, extractor: nil) }
        guard case .success(let read)? = r else { check(false, "cbz read failed: \(String(describing: r))"); return }
        let p = read.publication
        check(p.layout == .fixed && p.direction == .rightToLeft, "fixed layout, manga direction")
        check(p.metadata.title == "Issue One" && p.metadata.authors == ["Ann", "Ben"] && p.metadata.language == "ja", "ComicInfo metadata \(p.metadata)")
        check(p.spine.count == 3, "three pages (hidden, MACOSX and txt skipped): \(p.spine.count)")
        let order = p.spine.compactMap { item -> Data? in if case .page(let r) = item.content { p.resources[r]?.data } else { nil } }
        check(order == [pages["Comic/page1.jpg"]!, pages["Comic/page2.png"]!, pages["Comic/page10.jpg"]!], "natural page order, bytes untouched")
        check(p.cover != nil && p.resources[p.cover!]?.data == pages["Comic/page1.jpg"], "first page is the cover")

        // Fixed-layout EPUB: pages stay byte-identical, viewport matches the picture
        let epub = work.appendingPathComponent("issue.epub")
        try EPUBWriter.write(p, to: epub)
        check(ebInspect(epub, version: 3).isEmpty, "comic EPUB valid: \(ebInspect(epub, version: 3))")
        let zip = try ZipArchive(url: epub)
        let images = zip.entries.filter { $0.name.hasPrefix("OEBPS/images/") }.sorted { $0.name.compare($1.name, options: .numeric) == .orderedAscending }
        let written = try images.map { try zip.data(for: $0) }
        check(Set(written) == Set(order), "page pictures are byte-identical in the EPUB")
        let opf = String(decoding: try zip.data(named: "OEBPS/content.opf")!, as: UTF8.self)
        check(opf.contains("rendition:layout\">pre-paginated") && opf.contains("page-progression-direction=\"rtl\""), "fixed layout and rtl in OPF")
        let first = String(decoding: try zip.data(named: "OEBPS/text/0001.xhtml")!, as: UTF8.self)
        check(first.contains("name=\"viewport\" content=\"width=61, height=90\""), "viewport from the picture size: \(first)")
        let reread = try EPUBReader.read(url: epub).publication
        check(reread.layout == .fixed && reread.direction == .rightToLeft && reread.spine.count == 3, "fixed EPUB reads back")
        let pageBytes = reread.spine.compactMap { item -> Data? in if case .page(let r) = item.content { reread.resources[r]?.data } else { nil } }
        check(pageBytes == order, "pages survive EPUB → Publication")
        let flat = PublicationBuilder.document(from: p).doc
        check(flat.blocks.count == 3 && flat.resources.count == 3, "comic as a document: one figure per page")
        let v2 = work.appendingPathComponent("issue2.epub")
        var o2 = PackageWriteOptions(); o2.epubVersion = 2
        try EPUBWriter.write(p, to: v2, options: o2)
        check(ebInspect(v2, version: 2).isEmpty, "comic EPUB 2 valid: \(ebInspect(v2, version: 2))")

        // CBR that is really a RAR: the archive engine unpacks it
        let rar = work.appendingPathComponent("fake.cbr")
        try ebData("Rar!\u{1A}\u{07}\u{01}\u{00} not a zip").write(to: rar)
        let fake: ArchiveExtractor = { _, dest in
            try FileManager.default.createDirectory(at: dest.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try pages["Comic/page1.jpg"]!.write(to: dest.appendingPathComponent("sub/1.jpg"))
            try pages["Comic/page2.png"]!.write(to: dest.appendingPathComponent("sub/2.png"))
        }
        if case .success(let viaEngine)? = complete(30, { try await ComicReader.read(url: rar, format: "cbr", workFolder: work, extractor: fake) }) {
            check(viaEngine.publication.spine.count == 2, "CBR via the archive engine")
        } else { check(false, "cbr via extractor") }
        if case .failure(let error)? = complete(30, { try await ComicReader.read(url: rar, format: "cbr", workFolder: work, extractor: nil) }) {
            check(error is ConversionError, "CBR without an engine fails with a message")
        } else { check(false, "cbr without extractor should fail") }
        check(((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).filter { $0.hasPrefix("comic-") }.isEmpty, "extraction folder removed")

        // CBC: a collection of CBZ files
        let inner1 = ebZip([("a1.png", page(2)), ("a2.png", page(4))], named: "one.cbz")
        let inner2 = ebZip([("b1.jpg", page(1))], named: "two.cbz")
        let cbc = ebZip([("two.cbz", try Data(contentsOf: inner2)), ("one.cbz", try Data(contentsOf: inner1)),
                         ("comics.txt", ebData("one.cbz:First Volume\ntwo.cbz:Second Volume\n"))], named: "set.cbc")
        if case .success(let c)? = complete(30, { try await ComicReader.read(url: cbc, format: "cbc", workFolder: work, extractor: nil) }) {
            check(c.publication.spine.count == 3, "CBC pages")
            check(c.publication.contents.map(\.title) == ["First Volume", "Second Volume"], "CBC contents in comics.txt order: \(c.publication.contents.map(\.title))")
        } else { check(false, "cbc read") }
    } catch { check(false, "comics: \(error)") }
}

@MainActor private func ebookCHM() {
    let extract: ArchiveExtractor = { _, dest in
        func put(_ path: String, _ data: Data) throws {
            let url = dest.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try put("Toc.hhc", ebData("""
        <!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML//EN"><HTML><BODY><OBJECT type="text/site properties"><param name="ImageType" value="Folder"></OBJECT>
        <UL>
        <LI><OBJECT type="text/sitemap"><param name="Name" value="Welcome"><param name="Local" value="Intro.HTM"></OBJECT>
        <LI><OBJECT type="text/sitemap"><param name="Name" value="Reference"><param name="Local" value="ref/index.htm"></OBJECT>
        <UL>
          <LI><OBJECT type="text/sitemap"><param name="Name" value="Details"><param name="Local" value="ref/details.htm#top"></OBJECT>
        </UL>
        <LI><OBJECT type="text/sitemap"><param name="Name" value="Folder only"></OBJECT>
        <UL><LI><OBJECT type="text/sitemap"><param name="Name" value="Leaf"><param name="Local" value="leaf.htm"></OBJECT></UL>
        </UL></BODY></HTML>
        """))
        try put("intro.htm", "<HTML><HEAD><TITLE>Intro</TITLE><meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1252\"></HEAD><BODY><H1>Welcome</H1><P>Caf\u{E9} text <A HREF=\"ref/details.htm\">details</A> <IMG SRC=\"img/Pic.PNG\"></BODY></HTML>".data(using: .windowsCP1252)!)
        try put("ref/index.htm", ebData("<html><body><h2>Reference</h2><p>Index page"))
        try put("ref/details.htm", ebData("<html><body><h2>Details</h2><p>All the details"))
        try put("leaf.htm", ebData("<html><body><p>A leaf"))
        try put("img/pic.png", ebPNG)
    }
    let work = ebDirectory()
    let source = work.appendingPathComponent("help.chm")
    try? ebData("ITSF fake").write(to: source)
    if case .success(let read)? = complete(30, { try await CHMReader.read(url: source, workFolder: work, extractor: extract) }) {
        let p = read.publication
        check(p.spine.count == 4, "four pages in contents order: \(p.spine.map(\.id))")
        check(p.contents.map(\.title) == ["Welcome", "Reference", "Folder only"], "top-level entries: \(p.contents.map(\.title))")
        check(p.contents[1].children.map(\.title) == ["Details"] && p.contents[2].children.map(\.title) == ["Leaf"], "nested entries")
        let docs = ebDocs(p)
        let first = ebPlain(docs[0].doc.blocks)
        check(first.contains("h1:Welcome") && first.contains { $0.hasPrefix("Café text") } , "windows-1252 text: \(first)")
        check(docs[0].doc.resources.values.contains(ebPNG), "case-insensitive picture lookup")
        if case .paragraph(let t, _) = docs[0].doc.blocks[1] {
            check(t.contains { if case .link(_, let d) = $0 { d.hasPrefix("item:") } else { false } }, "link between pages")
        }
        let epub = work.appendingPathComponent("help.epub")
        if (try? EPUBWriter.write(p, to: epub)) != nil { check(ebInspect(epub, version: 3).isEmpty, "CHM → EPUB valid: \(ebInspect(epub, version: 3))") } else { check(false, "write CHM EPUB") }
    } else { check(false, "chm read") }
    if case .failure? = complete(30, { try await CHMReader.read(url: source, workFolder: work, extractor: nil) }) {} else { check(false, "CHM without an engine must fail") }
    EbookKitModule.converters(extractor: nil).first { $0.id == .chmReader }.map { check($0.availability() == .unavailable("Needs the archive engine"), "CHM unavailable without an engine") }
    EbookKitModule.converters(extractor: extract).first { $0.id == .chmReader }.map { check($0.availability() == .available, "CHM available with an engine") }
}

@MainActor private func ebookWriterOptions() {
    let dir = ebDirectory()
    do {
        // Overrides, no fonts, contents off, generated cover
        var book = ebSamplePublication()
        book.cover = nil
        book.resources["cover"] = nil
        var o = PackageWriteOptions(options: OptionValues(["epubVersion": "3", "cover": "generate", "contents": false, "embedFonts": "none",
                                                           "title": "Override", "author": "New Author", "language": "fr"]))
        check(!o.includeContents && !o.embedFonts && o.generateCover && o.title == "Override" && o.epubVersion == 3, "options decoded")
        let url = dir.appendingPathComponent("o.epub")
        let losses = try EPUBWriter.write(book, to: url, options: o)
        check(ebInspect(url, version: 3).isEmpty, "options EPUB valid: \(ebInspect(url, version: 3))")
        check(losses.contains { $0.kind == .fontsReplaced }, "dropped fonts are reported")
        let zip = try ZipArchive(url: url)
        check(!zip.entries.contains { $0.name.contains("fonts/") }, "no fonts written")
        let opf = String(decoding: try zip.data(named: "OEBPS/content.opf")!, as: UTF8.self)
        check(opf.contains("<dc:title>Override</dc:title>") && opf.contains("New Author") && opf.contains("<dc:language>fr</dc:language>") && !opf.contains("Ada Author"), "metadata overrides")
        check(opf.contains("cover-image") && zip.contains("OEBPS/text/cover.xhtml"), "generated cover and cover page")
        let coverEntry = zip.entries.first { $0.name.contains("generated-cover") }
        check(coverEntry != nil && (try? zip.data(for: coverEntry!))?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true, "cover is a PNG")
        if let d = coverEntry.flatMap({ try? zip.data(for: $0) }) { let size = MediaTypesProbe.size(d); check(size?.0 == 1200 && size?.1 == 1800, "cover size") }
        let nav = String(decoding: try zip.data(named: "OEBPS/nav.xhtml")!, as: UTF8.self)
        check(nav.contains("hidden=\"hidden\""), "contents off hides the navigation")
        let back = try EPUBReader.read(url: url).publication
        check(back.metadata.title == "Override" && back.spine.count == 3, "reads back (cover page is a chapter)")
        // option defaults
        o = PackageWriteOptions(options: OptionValues())
        check(o.epubVersion == 3 && o.includeContents && o.embedFonts && !o.generateCover, "option defaults")
        o = PackageWriteOptions(options: OptionValues(["epubVersion": "2"]))
        check(o.epubVersion == 2, "EPUB 2 option")

        // Cancellation leaves nothing behind
        let cancelled = dir.appendingPathComponent("c.epub")
        var thrown: ConversionError?
        do { try EPUBWriter.write(ebSamplePublication(), to: cancelled, isCancelled: { true }) } catch { thrown = error as? ConversionError }
        check(thrown == .cancelled && !FileManager.default.fileExists(atPath: cancelled.path), "cancellation: \(String(describing: thrown))")
        // An empty book is refused
        var empty: ConversionError?
        do { try EPUBWriter.write(Publication(), to: dir.appendingPathComponent("e.epub")) } catch { empty = error as? ConversionError }
        check(empty != nil, "empty publication is refused")
        // No contents given: built from the chapters
        var plain = ebSamplePublication(); plain.contents = []
        let p2 = dir.appendingPathComponent("p2.epub")
        try EPUBWriter.write(plain, to: p2)
        check(ebInspect(p2, version: 3).isEmpty, "derived contents valid")
        let derived = try EPUBReader.read(url: p2).publication.contents.map(\.title); check(derived == ["Chapter One", "Chapter Two"], "contents derived from chapter titles")
    } catch { check(false, "writer options: \(error)") }
}

private enum MediaTypesProbe {
    static func size(_ data: Data) -> (Int, Int)? {
        guard let s = CGImageSourceCreateWithData(data as CFData, nil), let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}

@MainActor private func ebookDocumentBridge() {
    // DocModel → Publication (chapters at h1, notes and pictures travel with their chapter) and back to one document.
    let doc = DocModel(
        metadata: DocMetadata(title: "Doc", authors: ["A"], language: "en"),
        blocks: [.paragraph([.text("Preface")], DocParagraphStyle()),
                 .heading(level: 1, [.text("One")]),
                 .paragraph([.text("a"), .footnoteReference(id: "n1")], DocParagraphStyle()),
                 .figure(resource: "img", caption: nil, altText: nil),
                 .heading(level: 2, [.text("Sub")]),
                 .heading(level: 1, [.text("Two")]),
                 .paragraph([.text("b"), .footnoteReference(id: "n2")], DocParagraphStyle()),
                 .footnote(id: "n1", [.paragraph([.text("note one")], DocParagraphStyle())]),
                 .footnote(id: "n2", [.paragraph([.text("note two")], DocParagraphStyle())])],
        resources: ["img": ebPNG, "unused": ebCover])
    let p = PublicationBuilder.publication(from: doc)
    check(p.spine.count == 3 && p.contents.map(\.title) == ["Doc", "One", "Two"], "chapters: \(p.contents.map(\.title))")
    let docs = ebDocs(p)
    check(docs[1].doc.resources.keys.sorted() == ["img"] && docs[2].doc.resources.isEmpty, "pictures travel with their chapter")
    check(ebPlain(docs[1].doc.blocks).contains("note n1: note one") && !ebPlain(docs[1].doc.blocks).contains { $0.contains("note two") }, "footnotes travel with the citing chapter")
    check(ebPlain(docs[2].doc.blocks).contains("note n2: note two"), "second chapter's note")
    let (flat, losses) = PublicationBuilder.document(from: p)
    check(losses.isEmpty && flat.metadata.title == "Doc" && flat.metadata.authors == ["A"], "metadata kept")
    let text = ebPlain(flat.blocks)
    check(text.contains("Preface") && text.contains("h1:One") && text.contains("h2:Sub") && text.contains("h1:Two") && text.contains { $0.hasPrefix("note n2") }, "flattened text: \(text)")
    check(flat.resources["img"] == ebPNG, "flattened pictures")
    // Links between chapters cannot survive a flat document
    var linked = p
    if case .document(var d) = linked.spine[1].content {
        d.blocks.append(.paragraph([.link([.text("go")], destination: "item:c003")], DocParagraphStyle()))
        linked.spine[1].content = .document(d)
    }
    let (flat2, l2) = PublicationBuilder.document(from: linked)
    check(l2.map(\.kind) == [.hyperlinksDropped] && ebPlain(flat2.blocks).contains("go"), "chapter links dropped with a loss note")
    // Publication with one chapter and no headings still gets a valid book
    let bare = PublicationBuilder.publication(from: DocModel(blocks: [.paragraph([.text("only")], DocParagraphStyle())]))
    check(bare.spine.count == 1, "single chapter")
}

@MainActor private func ebookConverters() {
    installFakes()
    EbookKitModule.install()
    let registry = Services.converters
    guard let kit = registry.converter(for: .ebookKit), let epubReader = registry.converter(for: .epubReader), let fb2Reader = registry.converter(for: .fb2Reader) else {
        check(false, "converters registered"); return
    }
    let work = ebDirectory()
    let source = ebHandEPUB3()
    func context(_ from: FormatID, _ to: FormatID, source: URL, options: OptionValues = OptionValues(), final: Bool = false) -> StepContext {
        StepContext(workFolder: work, source: source, sourceFormat: from, targetFormat: to, options: options, isFinalStep: final)
    }
    func run(_ converter: any Converter, _ step: Step, _ input: StepValue, _ ctx: StepContext) -> StepOutput? {
        if case .success(let out)? = complete(30, { try await converter.run(step, input: input, context: ctx) }) { return out }
        return nil
    }
    // EPUB → Publication → EPUB (the calibre hand-off shape: files in the work folder)
    let readStep = Step(.epubReader, "epub", .publication)
    check(epubReader.handles(readStep) && !epubReader.handles(Step(.epubReader, "oeb", .publication)), "EPUBReader handles epub → Publication only")
    guard let read = run(epubReader, readStep, .file(source), context("epub", "epub", source: source)), case .publication(let publication) = read.value else { check(false, "read step"); return }
    check(publication.spine.count == 2, "publication from the read step")
    let writeStep = Step(.ebookKit, .publication, "epub")
    check(kit.handles(writeStep) && kit.handles(Step(.ebookKit, .publication, "oeb")) && kit.handles(Step(.ebookKit, .publication, .docModel)) && kit.handles(Step(.ebookKit, .docModel, "epub")), "EbookKit handles")
    check(!kit.handles(Step(.ebookKit, .publication, "pdf")) && !kit.handles(Step(.epubReader, .publication, "epub")), "and nothing else")
    var o = OptionValues(); o["epubVersion"] = "2"
    if let out = run(kit, writeStep, .publication(publication), context("epub", "epub", source: source, options: o)), case .file(let url) = out.value {
        check(url.deletingLastPathComponent() == work && url.pathExtension == "epub", "output goes to the work folder: \(url.path)")
        check(ebInspect(url, version: 2).isEmpty, "step output is a valid EPUB 2: \(ebInspect(url, version: 2))")
    } else { check(false, "write step") }
    // A second write for the same source does not overwrite the first
    if let a = run(kit, writeStep, .publication(publication), context("epub", "epub", source: source)), case .file(let u1) = a.value,
       let b = run(kit, writeStep, .publication(publication), context("epub", "epub", source: source)), case .file(let u2) = b.value { check(u1 != u2, "unique output names") }
    // Publication → DocModel
    if let out = run(kit, Step(.ebookKit, .publication, .docModel), .publication(publication), context("epub", "txt", source: source)), case .doc(let doc) = out.value {
        check(ebPlain(doc.blocks).contains("h1:Premier chapitre") && ebPlain(doc.blocks).contains { $0.contains("Texte gras et italique") }, "publication → document")
        check(out.lossNotes.contains { $0.kind == .hyperlinksDropped }, "link loss note")
    } else { check(false, "publication → doc step") }
    // DocModel → OEB and EPUB
    let doc = DocModel(metadata: DocMetadata(title: "From doc"), blocks: [.heading(level: 1, [.text("H")]), .paragraph([.text("t")], DocParagraphStyle())])
    for fmt in ["epub", "oeb"] as [FormatID] {
        if let out = run(kit, Step(.ebookKit, .docModel, .format(fmt)), .doc(doc), context("docx", fmt, source: work.appendingPathComponent("My Notes.docx"))), case .file(let url) = out.value {
            check(url.lastPathComponent == "My Notes.\(fmt.rawValue)", "output named after the source: \(url.lastPathComponent)")
            check(fmt == "epub" ? ebInspect(url, version: 3).isEmpty : ((try? OEBReader.read(url: url))?.publication.metadata.title == "From doc"), "docModel → \(fmt)")
        } else { check(false, "doc → \(fmt)") }
    }
    // Wrong input kind and cancellation
    if case .failure(let e)? = complete(10, { try await kit.run(writeStep, input: .doc(doc), context: context("epub", "epub", source: source)) }) { _ = e } else { /* docModel → epub is valid for this input; nothing to check */ }
    let cancelledContext = StepContext(workFolder: work, source: source, sourceFormat: "epub", targetFormat: "epub", isCancelled: { true })
    if case .failure(let e)? = complete(10, { try await epubReader.run(readStep, input: .file(source), context: cancelledContext) }) { check((e as? ConversionError) == .cancelled, "cancelled read") } else { check(false, "cancelled read should throw") }
    if case .failure(let e)? = complete(10, { try await epubReader.run(readStep, input: .doc(doc), context: context("epub", "epub", source: source)) }) { check(e is ConversionError, "reader refuses a model input") } else { check(false, "reader with model input should throw") }
    // FB2 reader step reports its engine
    let fb2URL = scratch.appendingPathComponent("conv-\(UUID().uuidString).fb2")
    try? ebData("<FictionBook><description><title-info><book-title>T</book-title></title-info></description><body><section><title><p>S</p></title><p>Body</p></section></body></FictionBook>").write(to: fb2URL)
    if let out = run(fb2Reader, Step(.fb2Reader, "fb2", .publication), .file(fb2URL), context("fb2", "epub", source: fb2URL)), case .publication(let p) = out.value { check(p.metadata.title == "T" && p.spine.count == 1, "FB2 step") } else { check(false, "fb2 step") }
}

/// Every step of every route that names one of this module's engines is handled by a registered converter, and every converter
/// is used by some route (ARCHITECTURE §4: no dead converters).
@MainActor private func ebookRoutesCovered() {
    installFakes()
    EbookKitModule.install()
    let mine: Set<EngineID> = [.epubReader, .oebReader, .fb2Reader, .htmlzReader, .txtzReader, .comicReader, .chmReader, .ebookKit]
    var used: Set<EngineID> = []
    var steps = 0
    for route in FormatMatrix.routes {
        let chains = [route.builtin, route.helper].compactMap { $0 } + route.alternates.map(\.steps)
        for chain in chains {
            for step in chain where mine.contains(step.engine) {
                steps += 1
                used.insert(step.engine)
                let handled = Services.converters.converters.contains { $0.handles(step) }
                check(handled, "no converter handles \(step) in \(route.from) → \(route.to)")
                if let converter = Services.converters.converter(for: step.engine) {
                    check(converter.id.info.module == .ebookKit, "\(step.engine) is registered by EbookKit")
                }
            }
        }
    }
    check(used == mine, "engines the matrix uses: \(used.map(\.rawValue).sorted())")
    check(steps > 200, "matrix steps checked: \(steps)")
    // Calibre-only formats are never read here; HelperKit owns that engine.
    check(Services.converters.converter(for: .calibre) == nil, "calibre is not registered by EbookKit")
    check(EngineID.calibre.helpers == [.calibre] && EngineID.calibre.info.module == .helperKit, "calibre runs through HelperKit")
    // Every calibre route meets EbookKit at EPUB
    for route in FormatMatrix.routes {
        for chain in [route.builtin, route.helper].compactMap({ $0 }) {
            for (a, b) in zip(chain, chain.dropFirst()) where a.engine == .calibre && mine.contains(b.engine) {
                check(a.to == "epub" && b.from == "epub", "calibre hand-off for \(route.from) → \(route.to) is EPUB: \(a) → \(b)")
            }
            for (a, b) in zip(chain, chain.dropFirst()) where b.engine == .calibre && mine.contains(a.engine) {
                check(a.to == "epub" && b.from == "epub", "EbookKit hand-off to calibre for \(route.from) → \(route.to) is EPUB: \(a) → \(b)")
            }
        }
    }
}

// MARK: - Damaged input

/// A fuzz seed for a ZIP package (EPUB, OEB, HTMLZ, TXTZ, CBZ…): three inputs in four damage one entry, unpacked with
/// EbookKit's ZipArchive and re-zipped with its ZipWriter, so the damage reaches the markup readers; the rest damage the
/// package's own bytes for the ZIP reader.
private func ebPackageSeed(_ name: String, _ ext: String, _ url: URL, nesting: [String] = ["<div>"]) -> FuzzSeed? {
    guard let data = try? Data(contentsOf: url), let zip = try? ZipArchive(data: data) else { check(false, "\(name) fixture"); return nil }
    let bytes = [UInt8](data)
    let entries = zip.entries.compactMap { entry in (try? zip.data(for: entry)).map { (path: entry.name, bytes: [UInt8]($0)) } }
    let rezipped = ebDirectory("fuzz-zip").appendingPathComponent("package.zip")
    return FuzzSeed(name: name, ext: ext, bytes: bytes, mutate: { rng in
        guard Int.random(in: 0..<4, using: &rng) != 0 else { return Fuzz.mutate(bytes, nesting: nesting, using: &rng) }
        let damaged = Fuzz.mutateEntries(entries, nesting: nesting, using: &rng)
        try? FileManager.default.removeItem(at: rezipped)
        guard let writer = try? ZipWriter(url: rezipped) else { return bytes }
        for entry in damaged { try? writer.add(entry.path, Data(entry.bytes), compress: entry.path == "mimetype" ? false : nil) }
        try? writer.finish()
        return (try? Data(contentsOf: rezipped)).map { [UInt8]($0) } ?? bytes
    }, nesting: nesting)
}

/// Books whose structure is hostile where the readers recurse, search or size things, each read once as it is by the
/// fuzz case: 50,000 nested elements, a chain of 5,000 notes each citing the next, 20,000 nested Markdown quotes, a line
/// of 20,000 unclosed "[" and "*", and a ZIP64 end record pointing near Int.max.
private func ebHostileBooks() -> [(name: String, ext: String, url: URL)] {
    let notes = (0..<5_000).map { ##"<aside epub:type="footnote" id="n\##($0)"><p>Note <a epub:type="noteref" href="#n\##($0 + 1)">\##($0 + 1)</a></p></aside>"## }.joined()
    let html = ##"<html><body><p>Start <a epub:type="noteref" href="#n0">0</a></p>"## + String(repeating: "<div>", count: 50_000) + "deep" + notes
        + #"<table><tr><td colspan="9223372036854775807" rowspan="-4">x</td></tr></table></body></html>"#
    let htmlz = ebZip([("index.html", ebData(html))], named: "hostile.htmlz")
    let text = String(repeating: "> ", count: 20_000) + "quoted\n\n" + String(repeating: "[*", count: 20_000) + "\n"
    let txtz = ebZip([("index.txt", ebData(text))], named: "hostile.txtz")
    // ZIP64: the end record's count says "see the ZIP64 record", and a locator before it points that record near Int.max.
    var zip64 = (try? Data(contentsOf: ebHandEPUB2())) ?? Data()
    if zip64.count > 22 {
        let eocd = zip64.count - 22
        zip64[eocd + 10] = 0xFF; zip64[eocd + 11] = 0xFF
        let locator: [UInt8] = [0x50, 0x4B, 0x06, 0x07, 0, 0, 0, 0, 0xF0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 1, 0, 0, 0]
        zip64.insert(contentsOf: locator, at: eocd)
    }
    let epub = ebDirectory("hostile").appendingPathComponent("zip64.epub")
    try? zip64.write(to: epub)
    return [("hostile-htmlz", "htmlz", htmlz), ("hostile-txtz", "txtz", txtz), ("hostile-zip64", "epub", epub)]
}

/// Every in-process reader on its format; a thrown error is a clean failure, only a trap or a hang is not. CHM's archive
/// engine is out of process: a stand-in unpacks the input as the book's sitemap next to one page.
private func ebReadAny(_ url: URL, _ ext: String, work: URL) async {
    switch ext {
    case "epub": _ = try? EPUBReader.read(url: url)
    case "oeb": _ = try? OEBReader.read(url: url)
    case "fb2", "zip": _ = try? FB2Reader.read(url: url)
    case "htmlz": _ = try? HTMLZReader.read(url: url)
    case "txtz": _ = try? TXTZReader.read(url: url)
    case "chm":
        let unpack: ArchiveExtractor = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent("toc.hhc"))
            try Data(#"<html><body><h1>Page</h1><p>Text <img src="pic.png"></body></html>"#.utf8).write(to: destination.appendingPathComponent("page.htm"))
        }
        _ = try? await CHMReader.read(url: url, workFolder: work, extractor: unpack)
    default: _ = try? await ComicReader.read(url: url, format: FormatID(ext), workFolder: work, extractor: nil)
    }
}

@MainActor private func ebookDamagedInputNeverCrashes() {
    let dir = ebDirectory("fuzz-seeds")
    let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Corpus/generated")
    let epub3 = dir.appendingPathComponent("written.epub"), oeb = dir.appendingPathComponent("written.oeb")
    _ = try? EPUBWriter.write(ebSamplePublication(), to: epub3)
    _ = try? OEBWriter.write(ebSamplePublication(), to: oeb)
    let fb2 = ebFB2(encoding: "utf-8")
    let cbz = corpus.appendingPathComponent("sample.cbz")
    let cbc = ebZip([("one.cbz", (try? Data(contentsOf: cbz)) ?? Data()), ("two.cbz", (try? Data(contentsOf: cbz)) ?? Data()),
                     ("comics.txt", ebData("two.cbz:Second\none.cbz:First\n"))], named: "set.cbc", in: dir)
    let hhc = #"<html><body><ul><li><object type="text/sitemap"><param name="Name" value="Page"><param name="Local" value="page.htm"></object>"#
        + #"<ul><li><object type="text/sitemap"><param name="Name" value="Again"><param name="Local" value="page.htm#a"></object></ul></ul></body></html>"#
    let packages: [FuzzSeed?] = [
        ebPackageSeed("epub-written", "epub", epub3), ebPackageSeed("epub3-hand", "epub", ebHandEPUB3()), ebPackageSeed("epub2-hand", "epub", ebHandEPUB2()),
        ebPackageSeed("epub-corpus", "epub", corpus.appendingPathComponent("sample.epub")), ebPackageSeed("oeb", "oeb", oeb),
        ebPackageSeed("fb2-zip", "zip", ebZip([("book.fb2", ebData(fb2))], named: "book.fb2.zip", in: dir), nesting: ["<section>"]),
        ebPackageSeed("htmlz", "htmlz", ebHTMLZ(), nesting: ["<div>", "<b>"]), ebPackageSeed("txtz", "txtz", ebTXTZ(), nesting: ["> ", "[", "**"]),
        ebPackageSeed("cbz", "cbz", cbz, nesting: ["<ComicInfo>"]), ebPackageSeed("cbc", "cbc", cbc),
    ]
    let seeds = packages.compactMap { $0 } + [
        FuzzSeed(name: "fb2", ext: "fb2", bytes: Array(fb2.utf8), nesting: ["<section>", "<emphasis>"]),
        FuzzSeed(name: "chm-sitemap", ext: "chm", bytes: Array(hhc.utf8), nesting: ["<ul><li>"]),
    ]
    let work = ebDirectory("fuzz-work")
    for book in ebHostileBooks() {
        check(complete(30, { await ebReadAny(book.url, book.ext, work: work) }) != nil, "\(book.name) is read in time")
    }
    let ran = fuzzNeverCrashes("EbookKit.damagedInputNeverCrashes", seeds: seeds, count: 90) { url, seed in await ebReadAny(url, seed.ext, work: work) }
    check(ran == 90 * 12 && seeds.count == 12, "every damaged input was handled without a crash (\(ran))")
}
