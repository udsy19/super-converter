import Foundation
import SuperConverterCore

/// HTML → `DocModel` (formats §3.2 `HTMLReader`): headings, paragraphs, inline styles (tags and the CSS properties people
/// use), lists, tables with spans and header rows, figures, code, quotes, footnote sections, MathML, `data:` and local
/// pictures. `<head>` metadata fills the document's. Scripts and styles are ignored; nothing is fetched.
enum HTMLReader {
    static func read(_ url: URL, options: DocReadOptions = DocReadOptions()) throws -> DocReadResult {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let (text, _) = decodeDocument(data, hint: options.encoding)
        var converter = Converter(baseURL: url.deletingLastPathComponent())
        return converter.document(HTMLParser.parse(text))
    }

    /// A document from a string (clipboard HTML, `.eml` bodies, HTMLZ members).
    static func parse(_ html: String, baseURL: URL? = nil) -> DocReadResult {
        var converter = Converter(baseURL: baseURL)
        return converter.document(HTMLParser.parse(html))
    }

    /// Blocks for an HTML fragment inside another document (Markdown's raw HTML blocks).
    static func fragment(_ html: String, baseURL: URL?, resources: inout [String: Data]) -> [DocBlock] {
        var converter = Converter(baseURL: baseURL)
        converter.resources = resources
        let blocks = converter.blocks(of: HTMLParser.parse(html).children)
        resources = converter.resources
        return blocks
    }

    /// `<meta charset>` wins over guesses when the bytes are not UTF-8/BOM-marked.
    static func decodeDocument(_ data: Data, hint: String) -> (String, String) {
        if hint.lowercased() == "auto" {
            let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
            if !data.starts(with: [0xEF, 0xBB, 0xBF]), String(data: data, encoding: .utf8) == nil,
               let range = head.range(of: "charset="), case let name = head[range.upperBound...].prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), !name.isEmpty {
                return TextCoding.decode(data, hint: String(name))
            }
        }
        return TextCoding.decode(data, hint: hint)
    }

    // MARK: -

    private struct Converter {
        let baseURL: URL?
        var resources: [String: Data] = [:]
        var metadata = DocMetadata()
        var lossNotes: [LossNote] = []
        var footnoteBodies: [String: HTMLNode] = [:]
        var usedFootnotes: [String] = []
        var noteBlocks: [DocBlock] = []

        init(baseURL: URL?) { self.baseURL = baseURL }

        static let skipped: Set<String> = ["script", "style", "head", "noscript", "template", "svg", "iframe", "object", "canvas", "audio", "video", "select", "button", "nav"]

        mutating func document(_ root: HTMLNode) -> DocReadResult {
            if let html = root.firstTag("html"), let lang = html.attr("lang") ?? html.attr("xml:lang") { metadata.language = lang }
            if let title = root.firstTag("title") { let t = title.allText.trimmed; if !t.isEmpty { metadata.title = t } }
            for meta in root.all(where: { $0.tag == "meta" }) {
                guard let name = meta.attr("name")?.lowercased(), let content = meta.attr("content")?.trimmed, !content.isEmpty else { continue }
                switch name {
                case "author": metadata.authors = content.split(separator: ";").map { $0.trimmed }
                case "description": metadata.summary = content
                case "date", "dcterms.date", "dc.date": metadata.date = ISO8601DateFormatter().date(from: content) ?? DOCXReader.plainDate(content)
                default: break
                }
            }
            // Footnote sections: the list items by id.
            for section in root.all(where: { isFootnoteSection($0) }) {
                for item in section.all(where: { $0.tag == "li" }) { if let id = item.attr("id") { footnoteBodies[id] = item } }
            }
            let body = root.firstTag("body") ?? root
            var blocks = self.blocks(of: body.children)
            blocks += noteBlocks
            return DocReadResult(model: DocModel(metadata: metadata, blocks: blocks, resources: resources), lossNotes: lossNotes)
        }

        func isFootnoteSection(_ node: HTMLNode) -> Bool {
            guard node.tag == "section" || node.tag == "div" || node.tag == "aside" || node.tag == "ol" else { return false }
            return node.classes.contains("footnotes") || node.attr("role") == "doc-endnotes" || node.attr("epub:type") == "footnotes"
        }

        // MARK: Blocks

        mutating func blocks(of nodes: [HTMLNode]) -> [DocBlock] {
            var out: [DocBlock] = []
            var inline = InlineBuilder()
            var pendingStyle = DocParagraphStyle()
            func flush(_ out: inout [DocBlock], _ inline: inout InlineBuilder) {
                inline.trim(leading: true)
                if !inline.isEmpty {
                    let text = inline.build()
                    out.append(Self.paragraphOrFigure(text, style: pendingStyle))
                }
                inline = InlineBuilder()
                pendingStyle = DocParagraphStyle()
            }
            for node in nodes {
                if node.isText {
                    inline.add(collapse(node.text, after: inline), RunFormat())
                    continue
                }
                if Self.skipped.contains(node.tag) && !(node.tag == "nav" && false) { continue }
                if isFootnoteSection(node) { continue }
                if Self.isInline(node) {
                    walkInline(node, RunFormat(), into: &inline)
                    continue
                }
                flush(&out, &inline)
                block(node, into: &out)
                if node.style["page-break-after"] == "always" || node.style["break-after"] == "page" { out.append(.pageBreak) }
            }
            flush(&out, &inline)
            return out
        }

        static let inlineTags: Set<String> = ["a", "abbr", "b", "bdi", "bdo", "big", "br", "cite", "code", "data", "del", "dfn", "em", "font", "i", "img", "input", "ins", "kbd", "label", "mark", "math", "q", "s", "samp", "small", "span", "strike", "strong", "sub", "sup", "time", "tt", "u", "var", "wbr"]

        static func isInline(_ node: HTMLNode) -> Bool { inlineTags.contains(node.tag) }

        static func paragraphOrFigure(_ text: DocText, style: DocParagraphStyle) -> DocBlock {
            if text.count == 1, case .image(let resource, let alt) = text[0] { return .figure(resource: resource, caption: nil, altText: alt) }
            if text.count == 1, case .math(let tex) = text[0] { return .math(tex: tex, display: true) }
            return .paragraph(text, style)
        }

        func collapse(_ text: String, after builder: InlineBuilder) -> String {
            var out = ""
            var lastSpace = false
            if case .run(let t, _)? = builder.items.last, t.last == " " { lastSpace = true }
            if builder.items.isEmpty { lastSpace = true }
            for ch in text {
                if ch == " " || ch == "\n" || ch == "\t" || ch == "\r" {
                    if !lastSpace { out.append(" "); lastSpace = true }
                } else { out.append(ch); lastSpace = false }
            }
            return out
        }

        func alignment(_ node: HTMLNode) -> DocParagraphStyle.Alignment {
            switch (node.style["text-align"] ?? node.attr("align") ?? "").lowercased() {
            case "center": .centre
            case "right", "end": .end
            case "justify": .justified
            default: .start
            }
        }

        /// The title block `HTMLWriter` writes (`h1.title`, `p.author`, `p.date`, `p.abstract`) goes back into the metadata.
        mutating func titleBlock(_ node: HTMLNode) -> Bool {
            let text = node.allText.trimmed
            // The head's own metadata may already say the same thing.
            if node.tag == "h1", node.classes.contains("title"), metadata.title == nil || metadata.title == text { metadata.title = text; return true }
            guard node.tag == "p" else { return false }
            if node.classes.contains("author"), metadata.authors.isEmpty || metadata.authors.joined(separator: "; ") == text {
                metadata.authors = text.split(separator: ";").map { $0.trimmed }
                return true
            }
            if node.classes.contains("date"), let date = ISO8601DateFormatter().date(from: text) ?? DOCXReader.plainDate(text) { metadata.date = metadata.date ?? date; return true }
            if node.classes.contains("abstract"), metadata.summary == nil || metadata.summary == text { metadata.summary = text; return true }
            return false
        }

        mutating func block(_ node: HTMLNode, into out: inout [DocBlock]) {
            if titleBlock(node) { return }
            switch node.tag {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                var builder = InlineBuilder()
                for child in node.children { walkChild(child, RunFormat(), into: &builder) }
                builder.trim(leading: true)
                out.append(.heading(level: Int(node.tag.dropFirst()) ?? 1, builder.build()))
            case "p", "address", "summary", "figcaption", "legend", "caption":
                var builder = InlineBuilder()
                for child in node.children { walkChild(child, RunFormat(), into: &builder) }
                builder.trim(leading: true)
                if builder.isEmpty { return }
                out.append(Self.paragraphOrFigure(builder.build(), style: DocParagraphStyle(alignment: alignment(node))))
            case "ul", "ol":
                out.append(list(node))
            case "dl":
                var builder = InlineBuilder()
                for child in node.children {
                    if child.tag == "dt" {
                        for c in child.children { walkChild(c, { var f = RunFormat(); f.bold = true; return f }(), into: &builder) }
                        builder.trim(leading: true)
                        if !builder.isEmpty { out.append(.paragraph(builder.build(), DocParagraphStyle())) }
                        builder = InlineBuilder()
                    } else if child.tag == "dd" {
                        out += blocks(of: child.children).map { block in
                            if case .paragraph(let t, let s) = block { return .quote([.paragraph(t, s)]) }
                            return block
                        }
                    }
                }
            case "blockquote":
                out.append(.quote(blocks(of: node.children)))
            case "pre":
                let codeNode = node.children.count == 1 && node.children[0].tag == "code" ? node.children[0] : node
                var text = codeNode.allText
                if text.hasPrefix("\n") { text.removeFirst() }
                if text.hasSuffix("\n") { text.removeLast() }
                let language = (codeNode.classes.first { $0.hasPrefix("language-") }).map { String($0.dropFirst(9)) }
                    ?? (node.classes.first { $0.hasPrefix("language-") }).map { String($0.dropFirst(9)) }
                out.append(.code(language: language, text: text.normalisedNewlines))
            case "hr":
                out.append(.thematicBreak)
            case "table":
                out.append(.table(table(node)))
            case "figure":
                let caption = node.firstTag("figcaption")
                if let img = node.firstTag("img"), let (resource, alt) = image(img) {
                    var captionText: DocText?
                    if let caption {
                        var builder = InlineBuilder()
                        for child in caption.children { walkChild(child, RunFormat(), into: &builder) }
                        builder.trim(leading: true)
                        if !builder.isEmpty { captionText = builder.build() }
                    }
                    out.append(.figure(resource: resource, caption: captionText, altText: alt))
                } else {
                    out += blocks(of: node.children)
                }
            case "math":
                out.append(.math(tex: MathMLBridge.tex(node), display: true))
            case "li":
                out += blocks(of: node.children)
            default:
                // div, section, article, main, body, form, fieldset, details, center, ...
                var children = blocks(of: node.children)
                if node.tag == "center" || alignment(node) != .start, !children.isEmpty {
                    let a: DocParagraphStyle.Alignment = node.tag == "center" ? .centre : alignment(node)
                    children = children.map { if case .paragraph(let t, var s) = $0, s.alignment == .start { s.alignment = a; return .paragraph(t, s) }; return $0 }
                }
                out += children
            }
        }

        // MARK: Lists

        mutating func list(_ node: HTMLNode) -> DocBlock {
            let ordered = node.tag == "ol"
            let start = Int(node.attr("start") ?? "1") ?? 1
            var items: [[DocBlock]] = []
            for child in node.children {
                if child.tag == "li" { items.append(blocks(of: child.children)) }
                else if child.tag == "ul" || child.tag == "ol" {
                    if items.isEmpty { items.append([]) }
                    items[items.count - 1].append(list(child))
                }
            }
            return .list(ordered: ordered, start: start, items: items)
        }

        // MARK: Tables

        mutating func table(_ node: HTMLNode) -> DocTable {
            var rows: [[DocTable.Cell]] = []
            var caption: DocText?
            func rowNodes(_ container: HTMLNode) -> [(HTMLNode, Bool)] {
                var out: [(HTMLNode, Bool)] = []
                for child in container.children {
                    switch child.tag {
                    case "tr": out.append((child, container.tag == "thead"))
                    case "thead", "tbody", "tfoot": out += rowNodes(child).map { ($0.0, $0.1 || child.tag == "thead") }
                    default: break
                    }
                }
                return out
            }
            if let cap = node.children.first(where: { $0.tag == "caption" }) {
                var builder = InlineBuilder()
                for child in cap.children { walkChild(child, RunFormat(), into: &builder) }
                builder.trim(leading: true)
                if !builder.isEmpty { caption = builder.build() }
            }
            for (tr, inHead) in rowNodes(node) {
                var cells: [DocTable.Cell] = []
                for cell in tr.children where cell.tag == "td" || cell.tag == "th" {
                    var content = blocks(of: cell.children)
                    if content.isEmpty { content = [.paragraph([], DocParagraphStyle(alignment: alignment(cell)))] }
                    else {
                        let a = alignment(cell)
                        if a != .start { content = content.map { if case .paragraph(let t, var s) = $0, s.alignment == .start { s.alignment = a; return .paragraph(t, s) }; return $0 } }
                    }
                    cells.append(DocTable.Cell(blocks: content, columnSpan: max(Int(cell.attr("colspan") ?? "1") ?? 1, 1),
                                               rowSpan: max(Int(cell.attr("rowspan") ?? "1") ?? 1, 1), isHeader: cell.tag == "th" || inHead))
                }
                if !cells.isEmpty { rows.append(cells) }
            }
            var alignments: [DocParagraphStyle.Alignment] = []
            if let first = rows.first {
                for cell in first {
                    var a = DocParagraphStyle.Alignment.start
                    if case .paragraph(_, let s)? = cell.blocks.first { a = s.alignment }
                    alignments += Array(repeating: a, count: cell.columnSpan)
                }
            }
            return DocTable(rows: rows, caption: caption, alignments: alignments)
        }

        // MARK: Inlines

        mutating func walkChild(_ node: HTMLNode, _ format: RunFormat, into builder: inout InlineBuilder) {
            if node.isText { builder.add(collapse(node.text, after: builder), format); return }
            walkInline(node, format, into: &builder)
        }

        mutating func walkInline(_ node: HTMLNode, _ base: RunFormat, into builder: inout InlineBuilder) {
            var f = base
            let css = node.style
            switch node.tag {
            case "b", "strong": f.bold = true
            case "i", "em", "cite", "dfn", "var": f.italic = true
            case "u", "ins": f.underline = true
            case "s", "strike", "del": f.strike = true
            case "code", "kbd", "samp", "tt": f.code = true
            case "sup": f.superscript = true
            case "sub": f.subscripted = true
            case "a":
                if let href = node.attr("href") {
                    // A footnote mark: <sup><a href="#fn1">.
                    if href.hasPrefix("#"), footnoteBodies[String(href.dropFirst())] != nil {
                        footnote(String(href.dropFirst()), into: &builder)
                        return
                    }
                    f.link = href
                }
            case "br": builder.add(.lineBreak); return
            case "wbr": return
            case "img":
                if let (resource, alt) = image(node) { builder.add(.image(resource: resource, alt: alt, link: f.link)) }
                else if let alt = node.attr("alt"), !alt.isEmpty { builder.add(alt, f) }
                return
            case "math":
                builder.add(.math(tex: MathMLBridge.tex(node)))
                return
            case "font":
                if let face = node.attr("face") { f.font = face.split(separator: ",").first.map { $0.trimmed } }
                if let colour = node.attr("color"), let hex = Self.colour(colour) { f.colour = hex }
            case "input", "label", "wbr": return
            default: break
            }
            if let weight = css["font-weight"] { f.bold = weight == "bold" || weight == "bolder" || (Int(weight) ?? 0) >= 600 }
            if let style = css["font-style"] { f.italic = style == "italic" || style == "oblique" }
            if let decoration = css["text-decoration"] ?? css["text-decoration-line"] {
                if decoration.contains("underline") { f.underline = true }
                if decoration.contains("line-through") { f.strike = true }
            }
            if let colour = css["color"], let hex = Self.colour(colour) { f.colour = hex }
            if let family = css["font-family"] {
                let first = family.split(separator: ",").first.map { $0.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) } ?? ""
                if DOCXReader.monospaceFonts.contains(first.lowercased()) || first.lowercased() == "monospace" { f.code = true }
                else if !["serif", "sans-serif", "system-ui", "inherit"].contains(first.lowercased()), !first.isEmpty { f.font = first }
            }
            if let size = css["font-size"] {
                if size.hasSuffix("pt"), let v = Double(size.dropLast(2)) { f.size = v }
                else if size.hasSuffix("px"), let v = Double(size.dropLast(2)) { f.size = (v * 0.75 * 10).rounded() / 10 }
            }
            if let va = css["vertical-align"] { if va == "super" { f.superscript = true } else if va == "sub" { f.subscripted = true } }
            for child in node.children { walkChild(child, f, into: &builder) }
        }

        mutating func footnote(_ id: String, into builder: inout InlineBuilder) {
            if !usedFootnotes.contains(id), let item = footnoteBodies[id] {
                usedFootnotes.append(id)
                // Drop the back-link.
                let copy = HTMLNode(tag: "li", attributes: [:])
                copy.children = item.children.filter { !($0.tag == "a" && ($0.attr("role") == "doc-backlink" || $0.classes.contains("footnote-back") || $0.attr("href")?.hasPrefix("#fnref") == true)) }
                for child in copy.children { prune(child) }
                noteBlocks.append(.footnote(id: id, blocks(of: copy.children)))
            }
            builder.add(.footnote(id: id))
        }

        func prune(_ node: HTMLNode) {
            node.children.removeAll { $0.tag == "a" && ($0.attr("role") == "doc-backlink" || $0.classes.contains("footnote-back") || $0.attr("href")?.hasPrefix("#fnref") == true) }
            for child in node.children { prune(child) }
        }

        // MARK: Pictures

        mutating func image(_ node: HTMLNode) -> (String, String?)? {
            guard let src = node.attr("src"), !src.isEmpty else { return nil }
            let alt = node.attr("alt").flatMap { $0.isEmpty ? nil : $0 }
            if src.hasPrefix("data:"), let comma = src.firstIndex(of: ",") {
                let header = src[..<comma]
                let payload = String(src[src.index(after: comma)...])
                guard let data = header.contains("base64") ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters) : payload.removingPercentEncoding.map({ Data($0.utf8) }) else { return nil }
                let ext = header.contains("png") ? "png" : header.contains("jpeg") || header.contains("jpg") ? "jpg" : header.contains("gif") ? "gif" : header.contains("svg") ? "svg" : header.contains("webp") ? "webp" : "img"
                let key = "image\(resources.count + 1).\(ext)"
                resources[key] = data
                return (key, alt)
            }
            if let base = baseURL, !src.contains("://"), !src.hasPrefix("//") {
                let path = (src.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? src).removingPercentEncoding ?? src
                let file = base.appendingPathComponent(path).standardizedFileURL
                if file.path.hasPrefix(base.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: file) {
                    resources[src] = data
                    return (src, alt)
                }
            }
            return (src, alt)
        }

        static func colour(_ css: String) -> String? {
            let c = css.trimmed.lowercased()
            if c.hasPrefix("#") {
                let hex = String(c.dropFirst())
                if hex.count == 6, hex.allSatisfy(\.isHexDigit) { return "#" + hex.uppercased() }
                if hex.count == 3, hex.allSatisfy(\.isHexDigit) { return "#" + hex.map { "\($0)\($0)" }.joined().uppercased() }
                return nil
            }
            if c.hasPrefix("rgb"), let open = c.firstIndex(of: "("), let close = c.firstIndex(of: ")") {
                let parts = c[c.index(after: open)..<close].split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).compactMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: "%"))) }
                if parts.count >= 3 { return String(format: "#%02X%02X%02X", Int(parts[0]), Int(parts[1]), Int(parts[2])) }
            }
            let named: [String: String] = ["red": "#FF0000", "blue": "#0000FF", "green": "#008000", "black": "#000000", "white": "#FFFFFF", "gray": "#808080", "grey": "#808080", "orange": "#FFA500", "purple": "#800080", "yellow": "#FFFF00"]
            return named[c]
        }
    }
}

/// MathML inside HTML ↔ TeX: reads the element tree the HTML parser built (it keeps the annotation text).
enum MathMLBridge {
    static func tex(_ math: HTMLNode) -> String {
        if let annotation = math.first(where: { $0.tag == "annotation" && ($0.attr("encoding")?.lowercased().contains("tex") ?? false) }) {
            return annotation.allText.trimmed
        }
        // Rebuild an XML tree and read it structurally.
        return MathML.tex(xml(math))
    }

    private static func xml(_ node: HTMLNode) -> XMLNode {
        let out = XMLNode(node.tag, attributes: node.attributes)
        for child in node.children where !child.isText { out.adopt(xml(child)) }
        if node.children.contains(where: \.isText), node.children.allSatisfy(\.isText) { out.adopt(text: node.allText) }
        return out
    }
}
