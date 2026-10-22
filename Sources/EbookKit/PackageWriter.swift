import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore
import UniformTypeIdentifiers

/// What the e-book options (formats §5, O-EBOOK) mean for the writers.
public struct PackageWriteOptions: Sendable {
    public var epubVersion = 3
    /// Make a typeset cover from the title and author when the book has none.
    public var generateCover = false
    /// Keep (or build from the chapters) a table of contents. Off hides it; EPUB still needs one.
    public var includeContents = true
    /// Fonts travel as the source had them; "none" leaves them out.
    public var embedFonts = true
    public var title: String?
    public var author: String?
    public var language: String?

    public init() {}

    public init(options: OptionValues) {
        if let v = options["epubVersion"]?.string, let n = Int(v), n == 2 || n == 3 { epubVersion = n }
        if let v = options["epubVersion"]?.int, v == 2 || v == 3 { epubVersion = v }
        generateCover = options["cover"]?.string == "generate"
        if let v = options["contents"]?.bool { includeContents = v }
        embedFonts = options["embedFonts"]?.string != "none"
        for (key, keyPath) in [("title", \PackageWriteOptions.title), ("author", \.author), ("language", \.language)] {
            if let v = options[key]?.string, !v.trimmingCharacters(in: .whitespaces).isEmpty { self[keyPath: keyPath] = v }
        }
    }
}

/// Publication → EPUB 2 or 3 (EPUBCheck-clean by construction: mimetype first and stored, `container.xml`, OPF with a
/// manifest entry for every part, NCX and, for EPUB 3, the navigation document and `dcterms:modified`).
public enum EPUBWriter {
    @discardableResult
    public static func write(_ publication: Publication, to url: URL, options: PackageWriteOptions = PackageWriteOptions(),
                             isCancelled: () -> Bool = { false }, report: (Double) -> Void = { _ in }) throws -> [LossNote] {
        try PackageWriter(flavour: options.epubVersion == 2 ? .epub2 : .epub3, options: options).write(publication, to: url, isCancelled: isCancelled, report: report)
    }
}

/// Publication → OEB 1.2 (a ZIP holding the OPF 1.2 package, OEB documents, stylesheets and a contents page).
public enum OEBWriter {
    @discardableResult
    public static func write(_ publication: Publication, to url: URL, options: PackageWriteOptions = PackageWriteOptions(),
                             isCancelled: () -> Bool = { false }, report: (Double) -> Void = { _ in }) throws -> [LossNote] {
        try PackageWriter(flavour: .oeb12, options: options).write(publication, to: url, isCancelled: isCancelled, report: report)
    }
}

struct PackageWriter {
    let flavour: Flavour
    let options: PackageWriteOptions

    private struct Asset { var id: String; var path: String; var mediaType: String; var data: Data }
    private struct Part { var id: String; var path: String; var mediaType: String; var properties: String = ""; var data: Data }

    func write(_ source: Publication, to url: URL, isCancelled: () -> Bool, report: (Double) -> Void) throws -> [LossNote] {
        var losses: [LossNote] = []
        var publication = source
        if let t = options.title { publication.metadata.title = t }
        if let a = options.author { publication.metadata.authors = [a] }
        if let l = options.language { publication.metadata.language = l }
        let title = publication.metadata.title?.nonEmpty ?? "Untitled"
        let language = publication.metadata.language?.nonEmpty ?? "und"
        let oeb = flavour == .oeb12

        // Pictures, styles and fonts, by resource key.
        var assets: [String: Asset] = [:]
        var counter = 0
        var usedPaths: Set<String> = []
        var stylesheets: [String] = []
        var droppedFonts = 0, droppedOther = 0
        func addAsset(_ key: String, data: Data, mediaType declared: String?) {
            guard assets[key] == nil else { return }
            var type = declared ?? MediaTypes.forImage(data, name: key)
            var data = data
            let folder: String
            if type.hasPrefix("image/") {
                // Only GIF, JPEG, PNG and SVG are core media types in every EPUB version; WebP and AVIF become PNG.
                if type == "image/webp" || type == "image/avif", let png = Self.transcodeToPNG(data) { data = png; type = "image/png" }
                folder = "images"
            } else if type == "text/css" || type == "text/x-oeb1-css" { type = flavour.cssType; folder = "styles" }
            else if Self.isFont(type) {
                guard options.embedFonts else { droppedFonts += 1; return }
                type = Self.fontType(type, for: flavour); folder = "fonts"
            } else if (type.hasPrefix("audio/") || type.hasPrefix("video/")) && flavour == .epub3 { folder = "media" }
            else { droppedOther += 1; return }
            counter += 1
            let stem = XHTMLEmitter.nameToken(((key as NSString).lastPathComponent as NSString).deletingPathExtension, fallback: "file")
            var name = "\(folder)/\(stem).\(MediaTypes.fileExtension(for: type) == "bin" ? (key as NSString).pathExtension : MediaTypes.fileExtension(for: type))"
            var n = 2
            while usedPaths.contains(name.lowercased()) { name = "\(folder)/\(stem)-\(n).\((name as NSString).pathExtension)"; n += 1 }
            usedPaths.insert(name.lowercased())
            assets[key] = Asset(id: "a\(counter)", path: name, mediaType: type, data: data)
            if folder == "styles" { stylesheets.append(name) }
        }
        for key in publication.resources.keys.sorted() {
            let r = publication.resources[key]!
            addAsset(key, data: r.data, mediaType: r.mediaType)
        }
        for item in publication.spine {
            if case .document(let doc) = item.content { for key in doc.resources.keys.sorted() { addAsset(key, data: doc.resources[key]!, mediaType: nil) } }
        }
        if droppedFonts > 0 { losses.append(LossNote(.fontsReplaced, detail: "\(droppedFonts) embedded font\(droppedFonts == 1 ? "" : "s") left out")) }
        if droppedOther > 0 { losses.append(LossNote(.otherLoss, detail: "\(droppedOther) part\(droppedOther == 1 ? "" : "s") this format can’t hold")) }

        // Cover
        var coverKey = publication.cover.flatMap { assets[$0] != nil ? $0 : nil }
        var generatedCover = false
        if coverKey == nil, options.generateCover, publication.layout == .reflowable, let png = CoverArt.png(title: title, authors: publication.metadata.authors) {
            addAsset("generated-cover", data: png, mediaType: "image/png")
            coverKey = "generated-cover"; generatedCover = true
        }

        // Paths
        let fixed = publication.layout == .fixed
        var docPaths: [String: String] = [:]
        var docIDs: [String: String] = [:]
        for (n, item) in publication.spine.enumerated() {
            docPaths[item.id] = "text/\(String(format: "%04d", n + 1)).\(flavour.documentExtension)"
            docIDs[item.id] = "d\(n + 1)"
        }
        let coverPagePath = "text/cover.\(flavour.documentExtension)"
        let cssBook = "styles/book.css", cssPage = "styles/page.css"
        var parts: [Part] = []
        parts.append(Part(id: "css-book", path: cssBook, mediaType: flavour.cssType, data: Data(XHTMLEmitter.stylesheet.utf8)))
        let pageCSS = "html, body { margin: 0; padding: 0; }\nimg { display: block; margin: 0 auto; width: 100%; height: 100%; max-width: none; }\n"
        if fixed { parts.append(Part(id: "css-page", path: cssPage, mediaType: flavour.cssType, data: Data(pageCSS.utf8))) }

        // Documents
        var spineIDs: [String] = []
        var formulas = false
        if generatedCover, let cover = coverKey, let asset = assets[cover] {
            let body = "<div class=\"figure\"><img src=\"\(PackagePath.relative(asset.path, from: coverPagePath))\" alt=\"Cover\"/></div>\n"
            let xml = XHTMLEmitter.document(flavour: flavour, title: title, language: language,
                                            stylesheets: [PackagePath.relative(cssBook, from: coverPagePath)], body: body, bodyAttributes: flavour == .epub3 ? " epub:type=\"cover\"" : "")
            parts.append(Part(id: "cover", path: coverPagePath, mediaType: flavour.documentType, data: Data(xml.utf8)))
            spineIDs.append("cover")
        }
        for (n, item) in publication.spine.enumerated() {
            if isCancelled() { throw ConversionError.cancelled }
            report(Double(n) / Double(max(1, publication.spine.count)) * 0.9)
            let path = docPaths[item.id]!
            let itemTitle = item.title?.nonEmpty ?? title
            let emitter = XHTMLEmitter(
                flavour: flavour,
                imagePath: { key in assets[key].map { PackagePath.relative($0.path, from: path) } },
                itemPath: { id in docPaths[id].map { PackagePath.relative($0, from: path) } })
            let xml: String
            switch item.content {
            case .document(let doc):
                let body = emitter.body(doc.blocks)
                formulas = formulas || emitter.usedFormulas
                let css = [cssBook] + stylesheets
                xml = XHTMLEmitter.document(flavour: flavour, title: itemTitle, language: language, stylesheets: css.map { PackagePath.relative($0, from: path) }, body: body)
            case .page(let key):
                guard let asset = assets[key] else { continue }
                let size = MediaTypes.pixelSize(of: asset.data) ?? (1000, 1500)
                let viewport = flavour == .epub3 && fixed ? "<meta name=\"viewport\" content=\"width=\(size.width), height=\(size.height)\"/>\n" : ""
                let img = "<img src=\"\(xmlEscape(PackagePath.encode(PackagePath.relative(asset.path, from: path)), attribute: true))\" alt=\"Page \(n + 1)\" width=\"\(size.width)\" height=\"\(size.height)\"/>\n"
                xml = XHTMLEmitter.document(flavour: flavour, title: itemTitle, language: language,
                                            stylesheets: [PackagePath.relative(fixed ? cssPage : cssBook, from: path)], body: img, extraHead: viewport)
            }
            parts.append(Part(id: docIDs[item.id]!, path: path, mediaType: flavour.documentType, data: Data(xml.utf8)))
            spineIDs.append(docIDs[item.id]!)
        }
        guard !spineIDs.isEmpty else { throw ConversionError.failed("This book has no pages to write.") }
        if formulas { losses.append(LossNote(.formattingSimplified, detail: "Formulas are kept as TeX text")) }

        // Contents
        let known = Set(publication.spine.map(\.id))
        func prune(_ entries: [ContentsEntry]) -> [ContentsEntry] {
            entries.flatMap { e -> [ContentsEntry] in
                let kids = prune(e.children)
                return known.contains(e.itemID) && !e.title.isEmpty ? [ContentsEntry(title: e.title, itemID: e.itemID, children: kids)] : kids
            }
        }
        var contents = prune(publication.contents)
        if contents.isEmpty {
            if fixed || publication.spine.count == 1 || !options.includeContents {
                if let first = publication.spine.first { contents = [ContentsEntry(title: first.title?.nonEmpty ?? title, itemID: first.id)] }
            } else {
                contents = publication.spine.enumerated().map { n, item in ContentsEntry(title: item.title?.nonEmpty ?? "Section \(n + 1)", itemID: item.id) }
            }
        }
        let identifier = "urn:uuid:" + UUID().uuidString.lowercased()
        let hidden = !options.includeContents

        switch flavour {
        case .epub3, .epub2:
            parts.append(Part(id: "ncx", path: "toc.ncx", mediaType: "application/x-dtbncx+xml",
                              data: Data(ncx(contents, title: title, identifier: identifier, docPaths: docPaths).utf8)))
            if flavour == .epub3 {
                let nav = navigation(contents, title: title, language: language, docPaths: docPaths, hidden: hidden)
                parts.append(Part(id: "nav", path: "nav.xhtml", mediaType: "application/xhtml+xml", properties: "nav", data: Data(nav.utf8)))
            }
        case .oeb12:
            let page = contentsPage(contents, title: title, language: language, docPaths: docPaths)
            parts.append(Part(id: "contents", path: "contents.html", mediaType: flavour.documentType, data: Data(page.utf8)))
        }
        report(0.95)

        let manifestAssets = assets.values.sorted { $0.id.count == $1.id.count ? $0.id < $1.id : $0.id.count < $1.id.count }
        let coverAssetID = coverKey.flatMap { assets[$0]?.id }
        let opf = oeb
            ? oebPackage(publication, title: title, language: language, identifier: identifier, parts: parts, assets: manifestAssets, spine: spineIDs, cover: coverKey.flatMap { assets[$0] })
            : epubPackage(publication, title: title, language: language, identifier: identifier, parts: parts, assets: manifestAssets, spine: spineIDs, coverID: coverAssetID, fixed: fixed)

        // Container
        do {
            let zip = try ZipWriter(url: url)
            do {
                let root = oeb ? "" : "OEBPS/"
                if !oeb {
                    try zip.add("mimetype", Data("application/epub+zip".utf8), compress: false)
                    try zip.add("META-INF/container.xml", Data("""
                    <?xml version="1.0" encoding="utf-8"?>
                    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                    <rootfiles>
                    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
                    </rootfiles>
                    </container>

                    """.utf8))
                }
                try zip.add(root + "content.opf", Data(opf.utf8))
                for part in parts { try zip.add(root + part.path, part.data) }
                for asset in manifestAssets { try zip.add(root + asset.path, asset.data) }
                try zip.finish()
            } catch { zip.abandon(); try? FileManager.default.removeItem(at: url); throw error }
        }
        report(1)
        return losses
    }

    // MARK: Package documents

    private func epubPackage(_ p: Publication, title: String, language: String, identifier: String, parts: [Part], assets: [Asset],
                             spine: [String], coverID: String?, fixed: Bool) -> String {
        let v3 = flavour == .epub3
        var x = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        x += "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"\(v3 ? "3.0" : "2.0")\" unique-identifier=\"bookid\">\n"
        x += "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"\(v3 ? "" : " xmlns:opf=\"http://www.idpf.org/2007/opf\"")>\n"
        x += "<dc:identifier id=\"bookid\">\(identifier)</dc:identifier>\n"
        x += "<dc:title>\(xmlEscape(title))</dc:title>\n"
        x += "<dc:language>\(xmlEscape(language))</dc:language>\n"
        for (n, author) in p.metadata.authors.enumerated() {
            x += v3 ? "<dc:creator id=\"creator\(n + 1)\">\(xmlEscape(author))</dc:creator>\n"
                    : "<dc:creator opf:role=\"aut\">\(xmlEscape(author))</dc:creator>\n"
        }
        if let d = p.metadata.date { x += "<dc:date>\(d.bookDate)</dc:date>\n" }
        if let s = p.metadata.summary?.nonEmpty { x += "<dc:description>\(xmlEscape(s))</dc:description>\n" }
        if v3 {
            for (n, _) in p.metadata.authors.enumerated() {
                x += "<meta refines=\"#creator\(n + 1)\" property=\"role\" scheme=\"marc:relators\">aut</meta>\n"
            }
            x += "<meta property=\"dcterms:modified\">\(Date().isoSeconds)</meta>\n"
            if fixed {
                x += "<meta property=\"rendition:layout\">pre-paginated</meta>\n<meta property=\"rendition:orientation\">auto</meta>\n<meta property=\"rendition:spread\">auto</meta>\n"
            }
        }
        if let coverID { x += "<meta name=\"cover\" content=\"\(coverID)\"/>\n" }
        x += "</metadata>\n<manifest>\n"
        for part in parts {
            x += "<item id=\"\(part.id)\" href=\"\(xmlEscape(PackagePath.encode(part.path), attribute: true))\" media-type=\"\(part.mediaType)\"\(part.properties.isEmpty ? "" : " properties=\"\(part.properties)\"")/>\n"
        }
        for a in assets {
            let props = v3 && a.id == coverID ? " properties=\"cover-image\"" : ""
            x += "<item id=\"\(a.id)\" href=\"\(xmlEscape(PackagePath.encode(a.path), attribute: true))\" media-type=\"\(a.mediaType)\"\(props)/>\n"
        }
        x += "</manifest>\n"
        x += "<spine toc=\"ncx\"\(v3 && p.direction == .rightToLeft ? " page-progression-direction=\"rtl\"" : "")>\n"
        for id in spine { x += "<itemref idref=\"\(id)\"/>\n" }
        x += "</spine>\n</package>\n"
        return x
    }

    private func oebPackage(_ p: Publication, title: String, language: String, identifier: String, parts: [Part], assets: [Asset],
                            spine: [String], cover: Asset?) -> String {
        var x = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        x += "<!DOCTYPE package PUBLIC \"+//ISBN 0-9673008-1-9//DTD OEB 1.2 Package//EN\" \"http://openebook.org/dtds/oeb-1.2/oebpkg12.dtd\">\n"
        x += "<package unique-identifier=\"bookid\">\n<metadata>\n"
        x += "<dc-metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:oebpackage=\"http://openebook.org/namespaces/oeb-package/1.0/\">\n"
        x += "<dc:Title>\(xmlEscape(title))</dc:Title>\n"
        x += "<dc:Identifier id=\"bookid\">\(identifier)</dc:Identifier>\n"
        x += "<dc:Language>\(xmlEscape(language))</dc:Language>\n"
        for author in p.metadata.authors { x += "<dc:Creator role=\"aut\">\(xmlEscape(author))</dc:Creator>\n" }
        if let d = p.metadata.date { x += "<dc:Date>\(d.bookDate)</dc:Date>\n" }
        if let s = p.metadata.summary?.nonEmpty { x += "<dc:Description>\(xmlEscape(s))</dc:Description>\n" }
        x += "</dc-metadata>\n</metadata>\n<manifest>\n"
        for part in parts { x += "<item id=\"\(part.id)\" href=\"\(xmlEscape(PackagePath.encode(part.path), attribute: true))\" media-type=\"\(part.mediaType)\"/>\n" }
        for a in assets { x += "<item id=\"\(a.id)\" href=\"\(xmlEscape(PackagePath.encode(a.path), attribute: true))\" media-type=\"\(a.mediaType)\"/>\n" }
        x += "</manifest>\n<spine>\n"
        for id in spine { x += "<itemref idref=\"\(id)\"/>\n" }
        x += "</spine>\n<tours></tours>\n<guide>\n<reference type=\"toc\" title=\"Contents\" href=\"contents.html\"/>\n"
        if let cover { x += "<reference type=\"cover\" title=\"Cover\" href=\"\(xmlEscape(PackagePath.encode(cover.path), attribute: true))\"/>\n" }
        x += "</guide>\n</package>\n"
        return x
    }

    private func ncx(_ contents: [ContentsEntry], title: String, identifier: String, docPaths: [String: String]) -> String {
        var order = 0
        func depth(_ e: [ContentsEntry]) -> Int { (e.map { 1 + depth($0.children) }.max() ?? 0) }
        func points(_ entries: [ContentsEntry]) -> String {
            entries.map { e in
                order += 1
                let here = order
                let kids = points(e.children)
                return "<navPoint id=\"np\(here)\" playOrder=\"\(here)\"><navLabel><text>\(xmlEscape(e.title))</text></navLabel><content src=\"\(xmlEscape(PackagePath.encode(docPaths[e.itemID] ?? ""), attribute: true))\"/>\(kids)</navPoint>\n"
            }.joined()
        }
        let map = points(contents)
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head>
        <meta name="dtb:uid" content="\(identifier)"/>
        <meta name="dtb:depth" content="\(max(1, depth(contents)))"/>
        <meta name="dtb:totalPageCount" content="0"/>
        <meta name="dtb:maxPageNumber" content="0"/>
        </head>
        <docTitle><text>\(xmlEscape(title))</text></docTitle>
        <navMap>
        \(map)</navMap>
        </ncx>

        """
    }

    private func navigation(_ contents: [ContentsEntry], title: String, language: String, docPaths: [String: String], hidden: Bool) -> String {
        func list(_ entries: [ContentsEntry]) -> String {
            "<ol>\n" + entries.map { e in
                let kids = e.children.isEmpty ? "" : list(e.children)
                return "<li><a href=\"\(xmlEscape(PackagePath.encode(docPaths[e.itemID] ?? ""), attribute: true))\">\(xmlEscape(e.title))</a>\(kids)</li>\n"
            }.joined() + "</ol>\n"
        }
        let body = "<nav epub:type=\"toc\" id=\"toc\"\(hidden ? " hidden=\"hidden\"" : "")>\n<h1>Contents</h1>\n\(list(contents))</nav>\n"
        return XHTMLEmitter.document(flavour: .epub3, title: title, language: language, stylesheets: ["styles/book.css"], body: body)
    }

    private func contentsPage(_ contents: [ContentsEntry], title: String, language: String, docPaths: [String: String]) -> String {
        func list(_ entries: [ContentsEntry]) -> String {
            "<ul>\n" + entries.map { e in
                "<li><a href=\"\(xmlEscape(PackagePath.encode(docPaths[e.itemID] ?? ""), attribute: true))\">\(xmlEscape(e.title))</a>\(e.children.isEmpty ? "" : "\n" + list(e.children))</li>\n"
            }.joined() + "</ul>\n"
        }
        return XHTMLEmitter.document(flavour: .oeb12, title: title, language: language, stylesheets: ["styles/book.css"],
                                     body: "<h1>Contents</h1>\n" + list(contents))
    }

    // MARK: Helpers

    private static func isFont(_ type: String) -> Bool {
        type.hasPrefix("font/") || type.contains("font") || type == "application/vnd.ms-opentype"
    }

    private static func fontType(_ type: String, for flavour: Flavour) -> String {
        let ext: String
        switch type {
        case "font/ttf", "application/x-font-ttf", "application/x-truetype-font", "application/font-sfnt": ext = "ttf"
        case "font/otf", "application/vnd.ms-opentype", "application/x-font-opentype", "application/x-font-otf": ext = "otf"
        case "font/woff", "application/font-woff", "application/x-font-woff": ext = "woff"
        case "font/woff2", "application/font-woff2": ext = "woff2"
        default: return type
        }
        if flavour == .epub3 { return "font/" + ext }
        switch ext {
        case "ttf": return "application/x-font-ttf"
        case "otf": return "application/vnd.ms-opentype"
        default: return "application/font-woff"
        }
    }

    static func transcodeToPNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

extension String {
    var nonEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
