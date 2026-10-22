import Foundation
import SuperConverterCore

/// The markup flavours the writers produce.
enum Flavour {
    case epub2, epub3, oeb12

    var isXHTML5: Bool { self == .epub3 }
    var cssType: String { self == .oeb12 ? "text/x-oeb1-css" : "text/css" }
    var documentType: String { self == .oeb12 ? "text/x-oeb1-document" : "application/xhtml+xml" }
    var documentExtension: String { self == .oeb12 ? "html" : "xhtml" }
}

/// DocModel → one content document's body markup.
final class XHTMLEmitter {
    let flavour: Flavour
    /// Resource key → path relative to the document, nil when the picture is unavailable.
    let imagePath: (String) -> String?
    /// `item:<id>` → relative path of that chapter, nil when it does not exist.
    let itemPath: (String) -> String?

    private var noteIDs: [String: String] = [:]      // footnote id → anchor name
    private var noteNumbers: [String: Int] = [:]
    private(set) var usedFormulas = false

    init(flavour: Flavour, imagePath: @escaping (String) -> String?, itemPath: @escaping (String) -> String?) {
        self.flavour = flavour; self.imagePath = imagePath; self.itemPath = itemPath
    }

    /// The body content of a document.
    func body(_ blocks: [DocBlock]) -> String {
        var notes: [(String, [DocBlock])] = []
        var flow: [DocBlock] = []
        for b in blocks { if case .footnote(let id, let inner) = b { notes.append((id, inner)) } else { flow.append(b) } }
        for (n, note) in notes.enumerated() {
            noteIDs[note.0] = "fn-" + Self.nameToken(note.0, fallback: String(n + 1))
        }
        for id in DocWalk.footnoteReferences(in: flow) where noteIDs[id] != nil && noteNumbers[id] == nil { noteNumbers[id] = noteNumbers.count + 1 }
        var out = emit(flow)
        let cited = notes.filter { noteNumbers[$0.0] != nil }.sorted { noteNumbers[$0.0]! < noteNumbers[$1.0]! }
        if !cited.isEmpty {
            for (id, inner) in cited {
                let anchor = noteIDs[id]!
                let content = emit(inner)
                let label = "<span class=\"notenum\">\(noteNumbers[id]!). </span>"
                let tag = flavour.isXHTML5 ? "aside epub:type=\"footnote\"" : "div"
                let end = flavour.isXHTML5 ? "aside" : "div"
                let withLabel = content.hasPrefix("<p>") ? "<p>" + label + content.dropFirst(3) : "<p>" + label + "</p>\n" + content
                out += "<\(tag) id=\"\(anchor)\" class=\"footnote\">\n\(withLabel)</\(end)>\n"
            }
        }
        return out
    }

    // MARK: Blocks

    private func emit(_ blocks: [DocBlock]) -> String { blocks.map(emit).joined() }

    private func emit(_ block: DocBlock) -> String {
        switch block {
        case .heading(let level, let text):
            let l = min(max(level, 1), 6)
            return "<h\(l)>\(inline(text))</h\(l)>\n"
        case .paragraph(let text, let style):
            let cls: String
            switch style.alignment {
            case .start: cls = ""
            case .centre: cls = " class=\"align-centre\""
            case .end: cls = " class=\"align-end\""
            case .justified: cls = " class=\"align-justify\""
            }
            let content = inline(text)
            return content.isEmpty ? "" : "<p\(cls)>\(content)</p>\n"
        case .list(let ordered, let start, let items):
            let tag = ordered ? "ol" : "ul"
            let startAttr = ordered && start != 1 && flavour.isXHTML5 ? " start=\"\(start)\"" : ""
            var out = "<\(tag)\(startAttr)>\n"
            for item in items {
                if item.count == 1, case .paragraph(let t, let s) = item[0], s.alignment == .start { out += "<li>\(inline(t))</li>\n" }
                else { out += "<li>\n\(item.isEmpty ? "" : emit(item))</li>\n" }
            }
            return out + "</\(tag)>\n"
        case .table(let table):
            return emitTable(table)
        case .figure(let resource, let caption, let alt):
            guard let path = imagePath(resource) else { return caption.map { "<p class=\"caption\">\(inline($0))</p>\n" } ?? "" }
            let img = "<img src=\"\(xmlEscape(PackagePath.encode(path), attribute: true))\" alt=\"\(xmlEscape(alt ?? "", attribute: true))\"/>"
            if let caption, flavour.isXHTML5 { return "<figure class=\"figure\">\n\(img)\n<figcaption>\(inline(caption))</figcaption>\n</figure>\n" }
            if let caption { return "<div class=\"figure\">\(img)<p class=\"caption\">\(inline(caption))</p></div>\n" }
            return "<div class=\"figure\">\(img)</div>\n"
        case .code(let language, let text):
            let cls = language.map { " class=\"language-\(xmlEscape(Self.nameToken($0, fallback: "text"), attribute: true))\"" } ?? ""
            return "<pre><code\(cls)>\(xmlEscape(text))</code></pre>\n"
        case .quote(let inner):
            let content = emit(inner)
            return content.isEmpty ? "" : "<blockquote>\n\(content)</blockquote>\n"
        case .math(let tex, let display):
            usedFormulas = true
            return display ? "<p class=\"math\"><code class=\"tex\">\(xmlEscape(tex))</code></p>\n" : "<p><code class=\"tex\">\(xmlEscape(tex))</code></p>\n"
        case .footnote:
            return ""
        case .thematicBreak:
            return "<hr/>\n"
        case .pageBreak:
            return "<div class=\"pagebreak\"></div>\n"
        }
    }

    private func emitTable(_ table: DocTable) -> String {
        guard !table.rows.isEmpty else { return "" }
        var out = "<table>\n"
        if let caption = table.caption { out += "<caption>\(inline(caption))</caption>\n" }
        let headerRows = table.rows.prefix { row in !row.isEmpty && row.allSatisfy(\.isHeader) }.count
        func row(_ cells: [DocTable.Cell]) -> String {
            var r = "<tr>"
            for (c, cell) in cells.enumerated() {
                let tag = cell.isHeader ? "th" : "td"
                var attrs = ""
                if cell.columnSpan > 1 { attrs += " colspan=\"\(cell.columnSpan)\"" }
                if cell.rowSpan > 1 { attrs += " rowspan=\"\(cell.rowSpan)\"" }
                if c < table.alignments.count {
                    switch table.alignments[c] {
                    case .centre: attrs += " style=\"text-align:center\""
                    case .end: attrs += " style=\"text-align:right\""
                    default: break
                    }
                }
                var content = ""
                if cell.blocks.count == 1, case .paragraph(let t, _) = cell.blocks[0] { content = inline(t) }
                else if !cell.blocks.isEmpty { content = "\n" + emit(cell.blocks) }
                r += "<\(tag)\(attrs)>\(content)</\(tag)>"
            }
            return r + "</tr>\n"
        }
        if headerRows > 0 { out += "<thead>\n" + table.rows.prefix(headerRows).map(row).joined() + "</thead>\n" }
        out += "<tbody>\n" + table.rows.dropFirst(headerRows).map(row).joined() + "</tbody>\n"
        if headerRows == table.rows.count { out = out.replacingOccurrences(of: "<tbody>\n</tbody>\n", with: "") }
        return out + "</table>\n"
    }

    // MARK: Inline

    func inline(_ text: DocText) -> String {
        var out = ""
        for piece in text {
            switch piece {
            case .text(let s): out += xmlEscape(s)
            case .emphasis(let t): out += "<em>\(inline(t))</em>"
            case .strong(let t): out += "<strong>\(inline(t))</strong>"
            case .strike(let t): out += flavour.isXHTML5 ? "<s>\(inline(t))</s>" : "<span class=\"strike\">\(inline(t))</span>"
            case .code(let s): out += "<code>\(xmlEscape(s))</code>"
            case .link(let t, let destination):
                let inner = inline(t)
                if destination.hasPrefix("item:") {
                    if let path = itemPath(String(destination.dropFirst(5))) { out += "<a href=\"\(xmlEscape(PackagePath.encode(path), attribute: true))\">\(inner)</a>" } else { out += inner }
                } else if PackagePath.isExternal(destination) {
                    out += "<a href=\"\(xmlEscape(destination, attribute: true))\">\(inner)</a>"
                } else { out += inner }
            case .image(let resource, let alt):
                if let path = imagePath(resource) {
                    out += "<img src=\"\(xmlEscape(PackagePath.encode(path), attribute: true))\" alt=\"\(xmlEscape(alt ?? "", attribute: true))\"/>"
                } else if let alt { out += xmlEscape(alt) }
            case .footnoteReference(let id):
                if let anchor = noteIDs[id], let number = noteNumbers[id] {
                    let type = flavour.isXHTML5 ? " epub:type=\"noteref\"" : ""
                    out += "<sup><a\(type) id=\"ref-\(anchor)\" href=\"#\(anchor)\">\(number)</a></sup>"
                }
            case .math(let tex):
                usedFormulas = true
                out += "<code class=\"tex\">\(xmlEscape(tex))</code>"
            case .styled(let t, let style):
                var content = inline(t)
                if style.underline { content = "<span class=\"u\">\(content)</span>" }
                if style.superscript { content = "<sup>\(content)</sup>" }
                if style.subscripted { content = "<sub>\(content)</sub>" }
                out += content
            case .lineBreak: out += "<br/>"
            }
        }
        return out
    }

    static func nameToken(_ s: String, fallback: String) -> String {
        let mapped = s.unicodeScalars.map { c in (c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "-" || c == "_" || c == ".")) ? String(c) : "_" }.joined()
        return mapped.isEmpty ? fallback : mapped
    }

    // MARK: Documents

    static func document(flavour: Flavour, title: String, language: String, stylesheets: [String], body: String, bodyAttributes: String = "",
                         extraHead: String = "") -> String {
        let links = stylesheets.map { "<link rel=\"stylesheet\" type=\"\(flavour.cssType)\" href=\"\(xmlEscape(PackagePath.encode($0), attribute: true))\"/>\n" }.joined()
        let lang = xmlEscape(language, attribute: true)
        switch flavour {
        case .epub3:
            return """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(lang)" xml:lang="\(lang)">
            <head>
            <title>\(xmlEscape(title))</title>
            \(extraHead)\(links)</head>
            <body\(bodyAttributes)>
            \(body)</body>
            </html>

            """
        case .epub2:
            return """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
            <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="\(lang)">
            <head>
            <title>\(xmlEscape(title))</title>
            \(extraHead)\(links)</head>
            <body\(bodyAttributes)>
            \(body)</body>
            </html>

            """
        case .oeb12:
            return """
            <?xml version="1.0" encoding="utf-8"?>
            <!DOCTYPE html PUBLIC "+//ISBN 0-9673008-1-9//DTD OEB 1.2 Document//EN" "http://openebook.org/dtds/oeb-1.2/oebdoc12.dtd">
            <html>
            <head>
            <title>\(xmlEscape(title))</title>
            \(extraHead)\(links)</head>
            <body\(bodyAttributes)>
            \(body)</body>
            </html>

            """
        }
    }

    static let stylesheet = """
    body { font-family: serif; line-height: 1.4; margin: 0 4%; }
    h1, h2, h3, h4, h5, h6 { font-family: sans-serif; line-height: 1.2; margin: 1.2em 0 0.6em 0; page-break-after: avoid; }
    p { margin: 0 0 0.8em 0; }
    .align-centre { text-align: center; }
    .align-end { text-align: right; }
    .align-justify { text-align: justify; }
    blockquote { margin: 1em 2em; }
    pre { white-space: pre-wrap; font-family: monospace; font-size: 0.9em; margin: 1em 0; }
    code { font-family: monospace; }
    table { border-collapse: collapse; margin: 1em 0; }
    th, td { border: 1px solid #888888; padding: 0.25em 0.5em; vertical-align: top; }
    th { font-weight: bold; }
    img { max-width: 100%; }
    .figure { text-align: center; margin: 1em 0; }
    .caption, figcaption { font-size: 0.9em; text-align: center; }
    .strike { text-decoration: line-through; }
    .u { text-decoration: underline; }
    .footnote { font-size: 0.9em; margin: 0.5em 0; }
    .pagebreak { page-break-after: always; }

    """
}
