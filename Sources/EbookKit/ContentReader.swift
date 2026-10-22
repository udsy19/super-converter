import Foundation
import SuperConverterCore

/// Turns the markup of one content document (XHTML, HTML, FB2 sections' HTML-like parts) into `DocModel` blocks. The caller
/// says how pictures and links are found; the converter collects the pictures it used, the footnotes it met and what it had
/// to drop.
final class ContentReader {
    /// Absolute container path → (resource key, bytes) for a picture, nil when it is missing or external.
    typealias ImageLookup = (String) -> (key: String, data: Data)?
    /// Absolute container path → destination text for a link to another document of the book, nil when it is not one.
    typealias LinkLookup = (String) -> String?

    let documentPath: String
    let footnotePrefix: String
    let images: ImageLookup
    let links: LinkLookup

    private(set) var resources: [String: Data] = [:]
    private(set) var footnotes: [DocBlock] = []
    private(set) var losses: Set<LossNote.Kind> = []
    private var footnoteSources: [String: MarkupNode] = [:]
    private var footnoteDone: Set<String> = []

    init(documentPath: String, footnotePrefix: String, images: @escaping ImageLookup, links: @escaping LinkLookup) {
        self.documentPath = documentPath; self.footnotePrefix = footnotePrefix; self.images = images; self.links = links
    }

    static let blockNames: Set<String> = [
        "p", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "hr", "table", "div", "section", "article",
        "aside", "header", "footer", "main", "figure", "figcaption", "dl", "dt", "dd", "body", "html", "form", "fieldset", "address",
        "center", "nav", "details", "summary", "tr", "td", "th", "thead", "tbody", "tfoot", "caption", "hgroup", "dir", "menu",
    ]
    private static let skipped: Set<String> = ["head", "script", "style", "title", "meta", "link", "noscript", "template", "object", "audio", "video", "iframe", "canvas", "map", "select", "option", "button", "input", "textarea"]

    // MARK: Entry points

    /// The blocks of a whole document (its `body`, or the root when there is none).
    func blocks(of root: MarkupNode) -> [DocBlock] {
        let body = root.descendant("body") ?? root
        collectFootnoteSources(in: body)
        var out: [DocBlock] = []
        convert(body.children, into: &out)
        return out + footnotes
    }

    /// First heading text, else the `<title>`.
    static func title(of root: MarkupNode) -> String? {
        for tag in ["h1", "h2", "h3"] {
            if let h = (root.descendant("body") ?? root).descendant(tag) {
                let t = h.plainText
                if !t.isEmpty { return t }
            }
        }
        if let t = root.descendant("title")?.plainText, !t.isEmpty { return t }
        return nil
    }

    // MARK: Footnotes

    private func isNote(_ node: MarkupNode) -> Bool {
        let type = (node.attribute("epub:type") ?? node.attribute("type") ?? "") + " " + (node.attribute("role") ?? "")
        return type.contains("footnote") || type.contains("endnote") || type.contains("rearnote") || type.contains("doc-endnote")
    }

    private func isNoteRef(_ node: MarkupNode) -> Bool {
        let type = (node.attribute("epub:type") ?? "") + " " + (node.attribute("role") ?? "")
        return type.contains("noteref") || node.attribute("type") == "note"
    }

    /// Notes are only lifted out of the flow when some note reference points at them.
    private func collectFootnoteSources(in body: MarkupNode) {
        var candidates: [String: MarkupNode] = [:]
        var referenced: Set<String> = []
        func walk(_ node: MarkupNode) {
            for c in node.children where !c.isText {
                if c.name == "a", isNoteRef(c), let frag = c.attribute("href").flatMap({ PackagePath.fragment(of: $0) }) { referenced.insert(frag) }
                else if let id = c.attribute("id"), !id.isEmpty, isNote(c), c.name != "a" { candidates[id] = c }
                walk(c)
            }
        }
        walk(body)
        footnoteSources = candidates.filter { referenced.contains($0.key) }
    }

    private func footnoteReference(for anchor: MarkupNode) -> DocInline? {
        guard isNoteRef(anchor), let href = anchor.attribute("href"), let frag = PackagePath.fragment(of: href),
              let source = footnoteSources[frag] else { return nil }
        let id = footnotePrefix + frag
        if !footnoteDone.contains(frag) {
            footnoteDone.insert(frag)
            var inner: [DocBlock] = []
            let content = source.children.filter { !isBacklink($0) }
            convert(content, into: &inner)
            if inner.isEmpty { return nil }
            footnotes.append(.footnote(id: id, inner))
        }
        return .footnoteReference(id: id)
    }

    private func isBacklink(_ node: MarkupNode) -> Bool {
        guard node.name == "a" else { return false }
        let type = (node.attribute("epub:type") ?? "") + " " + (node.attribute("role") ?? "")
        if type.contains("backlink") { return true }
        return ["↩", "↑", "^", "↩︎", "⏎", "[back]", "back"].contains(node.plainText.lowercased())
    }

    // MARK: Blocks

    private func convert(_ nodes: [MarkupNode], into blocks: inout [DocBlock]) {
        var run: DocText = []
        func flush() {
            let normalised = Self.normalise(run)
            run = []
            guard !normalised.isEmpty else { return }
            if normalised.count == 1, case .image(let resource, let alt) = normalised[0] {
                blocks.append(.figure(resource: resource, caption: nil, altText: alt)); return
            }
            blocks.append(.paragraph(normalised, DocParagraphStyle()))
        }
        for node in nodes {
            if let t = node.text { run.append(.text(Self.collapse(t))); continue }
            if Self.skipped.contains(node.name) { continue }
            if node.name == "math" {
                let tex = mathTeX(node)
                if node.attribute("display") == "block" { flush(); blocks.append(.math(tex: tex, display: true)) } else { run.append(.math(tex: tex)) }
                continue
            }
            if node.name == "svg" {
                if let image = node.descendant("image"), let src = image.attribute("href"), let (key, _) = lookup(src) { run.append(.image(resource: key, altText: nil)) }
                continue
            }
            if !Self.blockNames.contains(node.name) { run += inline(node); continue }
            if isNote(node), node.attribute("id").map({ footnoteSources[$0] != nil }) == true { continue }
            flush()
            block(node, into: &blocks)
        }
        flush()
    }

    private func block(_ node: MarkupNode, into blocks: inout [DocBlock]) {
        switch node.name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let text = Self.normalise(inlines(node.children))
            if !text.isEmpty { blocks.append(.heading(level: Int(String(node.name.last!))!, text)) }
        case "p", "dt", "dd", "summary", "figcaption", "address", "caption":
            var inner: [DocBlock] = []
            if node.name == "dt" {
                let text = Self.normalise(inlines(node.children))
                if !text.isEmpty { blocks.append(.paragraph([.strong(text)], DocParagraphStyle())) }
                return
            }
            convert(node.children, into: &inner)
            blocks += Self.aligned(inner, Self.alignment(of: node))
        case "ul", "ol":
            var items: [[DocBlock]] = []
            for li in node.children where !li.isText {
                if li.name == "li" { var inner: [DocBlock] = []; convert(li.children, into: &inner); items.append(inner) }
                else if !Self.skipped.contains(li.name) { var inner: [DocBlock] = []; convert([li], into: &inner); if !inner.isEmpty { items.append(inner) } }
            }
            if !items.isEmpty { blocks.append(.list(ordered: node.name == "ol", start: Int(node.attribute("start") ?? "") ?? 1, items: items)) }
        case "dl", "dir", "menu":
            if node.name == "dl" { convert(node.children, into: &blocks) }
            else {
                var items: [[DocBlock]] = []
                for li in node.elements where li.name == "li" { var inner: [DocBlock] = []; convert(li.children, into: &inner); items.append(inner) }
                if !items.isEmpty { blocks.append(.list(ordered: false, start: 1, items: items)) }
            }
        case "blockquote":
            var inner: [DocBlock] = []
            convert(node.children, into: &inner)
            if !inner.isEmpty { blocks.append(.quote(inner)) }
        case "pre":
            let codeChild = node.elements.count == 1 ? node.elements.first(where: { $0.name == "code" }) : nil
            var text = (codeChild ?? node).rawText
            if text.hasPrefix("\n") { text.removeFirst() }
            while text.hasSuffix("\n") { text.removeLast() }
            let classes = (codeChild?.attribute("class") ?? node.attribute("class") ?? "").split(separator: " ")
            let language = classes.compactMap { c -> String? in
                for p in ["language-", "lang-"] where c.hasPrefix(p) { return String(c.dropFirst(p.count)) }
                return nil
            }.first
            blocks.append(.code(language: language, text: text))
        case "hr":
            blocks.append(.thematicBreak)
        case "table":
            blocks.append(table(node))
        case "figure":
            var caption: DocText?
            var rest: [MarkupNode] = []
            for child in node.children {
                if child.name == "figcaption" { let t = Self.normalise(inlines(child.children)); if !t.isEmpty { caption = t } } else { rest.append(child) }
            }
            var inner: [DocBlock] = []
            convert(rest, into: &inner)
            if let caption, inner.count == 1, case .figure(let r, nil, let alt) = inner[0] { blocks.append(.figure(resource: r, caption: caption, altText: alt)) }
            else { blocks += inner; if let caption { blocks.append(.paragraph(caption, DocParagraphStyle(alignment: .centre))) } }
        case "nav":
            let type = (node.attribute("epub:type") ?? "") + (node.attribute("role") ?? "")
            if type.contains("landmarks") || type.contains("page-list") { return }
            convert(node.children, into: &blocks)
        case "center":
            var inner: [DocBlock] = []
            convert(node.children, into: &inner)
            blocks += Self.aligned(inner, .centre)
        default:   // div, section, article, aside, header, footer, main, body, html, form, li stray, tr stray …
            var inner: [DocBlock] = []
            convert(node.children, into: &inner)
            blocks += Self.aligned(inner, Self.alignment(of: node))
        }
    }

    private func table(_ node: MarkupNode) -> DocBlock {
        var rows: [[DocTable.Cell]] = []
        var caption: DocText?
        var alignments: [DocParagraphStyle.Alignment] = []
        func collect(_ parent: MarkupNode) {
            for child in parent.children where !child.isText {
                switch child.name {
                case "caption": let t = Self.normalise(inlines(child.children)); if !t.isEmpty { caption = t }
                case "thead", "tbody", "tfoot": collect(child)
                case "tr":
                    var cells: [DocTable.Cell] = []
                    for cell in child.elements where cell.name == "td" || cell.name == "th" {
                        var inner: [DocBlock] = []
                        convert(cell.children, into: &inner)
                        cells.append(DocTable.Cell(blocks: inner, columnSpan: max(1, Int(cell.attribute("colspan") ?? "") ?? 1),
                                                   rowSpan: max(1, Int(cell.attribute("rowspan") ?? "") ?? 1), isHeader: cell.name == "th"))
                        if rows.isEmpty { alignments.append(Self.alignment(of: cell)) }
                    }
                    if !cells.isEmpty { rows.append(cells) }
                default: break
                }
            }
        }
        collect(node)
        return .table(DocTable(rows: rows, caption: caption, alignments: alignments))
    }

    // MARK: Inline

    private func inlines(_ nodes: [MarkupNode]) -> DocText {
        var out: DocText = []
        for node in nodes {
            if let t = node.text { out.append(.text(Self.collapse(t))) }
            else if node.name == "math" { out.append(.math(tex: mathTeX(node))) }
            else if !Self.skipped.contains(node.name) { out += inline(node) }
        }
        return out
    }

    private func inline(_ node: MarkupNode) -> DocText {
        let name = node.name
        func wrap(_ make: (DocText) -> DocInline) -> DocText {
            let inner = inlines(node.children)
            return inner.isEmpty ? [] : [make(inner)]
        }
        let styled = Self.styleTraits(of: node)
        var result: DocText
        switch name {
        case "br": return [.lineBreak]
        case "wbr": return []
        case "em", "i", "cite", "var", "dfn": result = wrap { .emphasis($0) }
        case "strong", "b": result = wrap { .strong($0) }
        case "s", "strike", "del": result = wrap { .strike($0) }
        case "code", "tt", "kbd", "samp": let code = node.rawText; result = code.isEmpty ? [] : [.code(code)]
        case "u", "ins": result = wrap { .styled($0, DocRunStyle(underline: true)) }
        case "sup": result = wrap { .styled($0, DocRunStyle(superscript: true)) }
        case "sub": result = wrap { .styled($0, DocRunStyle(subscripted: true)) }
        case "img":
            guard let src = node.attribute("src") else { return [] }
            let alt = node.attribute("alt").flatMap { $0.isEmpty ? nil : $0 }
            if let (key, _) = lookup(src) { return [.image(resource: key, altText: alt)] }
            return alt.map { [.text($0)] } ?? []
        case "a":
            if let note = footnoteReference(for: node) { return [note] }
            if isBacklink(node) { return [] }
            let inner = inlines(node.children)
            guard let href = node.attribute("href"), !href.isEmpty, !inner.isEmpty else { return inner }
            if PackagePath.isExternal(href) { result = [.link(inner, destination: href)] }
            else {
                let path = PackagePath.resolve(href, against: documentPath)
                if !href.hasPrefix("#"), !path.isEmpty, let destination = links(path) { result = [.link(inner, destination: destination)] }
                else { result = inner; if href.hasPrefix("#") || !path.isEmpty { losses.insert(.hyperlinksDropped) } }
            }
        default: result = inlines(node.children)   // span, font, small, big, abbr, label, bdi, bdo, q …
        }
        if styled.bold, name != "strong", name != "b", !result.isEmpty { result = [.strong(result)] }
        if styled.italic, name != "em", name != "i", !result.isEmpty { result = [.emphasis(result)] }
        if styled.underline, name != "u", !result.isEmpty { result = [.styled(result, DocRunStyle(underline: true))] }
        return result
    }

    private func lookup(_ src: String) -> (key: String, data: Data)? {
        guard !src.isEmpty, !PackagePath.isExternal(src) else { return nil }
        let path = PackagePath.resolve(src, against: documentPath)
        guard let found = images(path) else { return nil }
        resources[found.key] = found.data
        return found
    }

    private func mathTeX(_ node: MarkupNode) -> String {
        if let ann = node.descendants("annotation").first(where: { $0.attribute("encoding")?.contains("tex") == true }) { return ann.rawText.trimmingCharacters(in: .whitespacesAndNewlines) }
        return node.plainText
    }

    // MARK: Text helpers

    static func collapse(_ s: String) -> String {
        var out = ""
        var space = false
        for ch in s.unicodeScalars {
            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" || ch == "\u{C}" { space = true }
            else { if space { out.append(" "); space = false }; out.unicodeScalars.append(ch) }
        }
        if space { out.append(" ") }
        return out
    }

    /// Drops spaces that follow a space or a line break and trims the ends; removes empty pieces.
    static func normalise(_ text: DocText) -> DocText {
        var afterSpace = true
        var out = normalise(text, afterSpace: &afterSpace)
        trimTrailing(&out)
        return out
    }

    private static func normalise(_ text: DocText, afterSpace: inout Bool) -> DocText {
        var out: DocText = []
        for piece in text {
            switch piece {
            case .text(var s):
                if afterSpace, s.hasPrefix(" ") { s.removeFirst() }
                if s.isEmpty { continue }
                afterSpace = s.hasSuffix(" ")
                out.append(.text(s))
            case .lineBreak:
                trimTrailing(&out)
                out.append(.lineBreak); afterSpace = true
            case .emphasis(let t): let n = normalise(t, afterSpace: &afterSpace); if !n.isEmpty { out.append(.emphasis(n)) }
            case .strong(let t): let n = normalise(t, afterSpace: &afterSpace); if !n.isEmpty { out.append(.strong(n)) }
            case .strike(let t): let n = normalise(t, afterSpace: &afterSpace); if !n.isEmpty { out.append(.strike(n)) }
            case .link(let t, let d): let n = normalise(t, afterSpace: &afterSpace); if !n.isEmpty { out.append(.link(n, destination: d)) }
            case .styled(let t, let st): let n = normalise(t, afterSpace: &afterSpace); if !n.isEmpty { out.append(.styled(n, st)) }
            default: afterSpace = false; out.append(piece)
            }
        }
        return out
    }

    private static func trimTrailing(_ text: inout DocText) {
        while let last = text.last {
            switch last {
            case .text(let s):
                var t = s
                while t.hasSuffix(" ") { t.removeLast() }
                if t.isEmpty { text.removeLast(); continue }
                text[text.count - 1] = .text(t); return
            case .emphasis(var t): trimTrailing(&t); if t.isEmpty { text.removeLast(); continue }; text[text.count - 1] = .emphasis(t); return
            case .strong(var t): trimTrailing(&t); if t.isEmpty { text.removeLast(); continue }; text[text.count - 1] = .strong(t); return
            case .strike(var t): trimTrailing(&t); if t.isEmpty { text.removeLast(); continue }; text[text.count - 1] = .strike(t); return
            case .link(var t, let d): trimTrailing(&t); if t.isEmpty { text.removeLast(); continue }; text[text.count - 1] = .link(t, destination: d); return
            case .styled(var t, let s): trimTrailing(&t); if t.isEmpty { text.removeLast(); continue }; text[text.count - 1] = .styled(t, s); return
            case .lineBreak: text.removeLast(); continue
            default: return
            }
        }
    }

    private static func aligned(_ blocks: [DocBlock], _ alignment: DocParagraphStyle.Alignment) -> [DocBlock] {
        guard alignment != .start else { return blocks }
        return blocks.map { b in
            if case .paragraph(let t, var s) = b, s.alignment == .start { s.alignment = alignment; return .paragraph(t, s) }
            return b
        }
    }

    static func alignment(of node: MarkupNode) -> DocParagraphStyle.Alignment {
        var value = node.attribute("align")?.lowercased() ?? ""
        for decl in (node.attribute("style") ?? "").split(separator: ";") {
            let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if kv.count == 2, kv[0] == "text-align" { value = kv[1] }
        }
        switch value {
        case "center", "centre": return .centre
        case "right", "end": return .end
        case "justify": return .justified
        default: return .start
        }
    }

    private static func styleTraits(of node: MarkupNode) -> (bold: Bool, italic: Bool, underline: Bool) {
        guard let style = node.attribute("style"), !style.isEmpty else { return (false, false, false) }
        var bold = false, italic = false, underline = false
        for decl in style.split(separator: ";") {
            let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "font-weight": bold = kv[1] == "bold" || kv[1] == "bolder" || (Int(kv[1]) ?? 0) >= 600
            case "font-style": italic = kv[1] == "italic" || kv[1] == "oblique"
            case "text-decoration", "text-decoration-line": underline = kv[1].contains("underline")
            default: break
            }
        }
        return (bold, italic, underline)
    }
}
