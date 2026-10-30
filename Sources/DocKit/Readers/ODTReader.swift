import Foundation
import SuperConverterCore

/// ODT (and OTT, FODT is not read) → `DocModel`: our own OpenDocument reader (formats §3.2 `ODTReader`). Named and automatic
/// styles are resolved through their parents; lists keep their nesting; formulas come from the embedded MathML; notes stay
/// inline in the source and become `DocBlock.footnote`.
enum ODTReader {
    static func read(_ url: URL, options: DocReadOptions = DocReadOptions()) throws -> DocReadResult {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try read(data, options: options)
    }

    static func read(_ data: Data, options: DocReadOptions = DocReadOptions()) throws -> DocReadResult {
        let archive: ZipArchive
        do { archive = try ZipArchive(data: data) } catch { throw ConversionError.damaged("odt") }
        if let manifest = try? archive.data("META-INF/manifest.xml"), String(decoding: manifest, as: UTF8.self).contains("encryption-data") {
            throw ConversionError.passwordRequired("odt")
        }
        guard let contentData = try archive.data("content.xml"), let content = try? XML.parse(contentData, keepWhitespace: true),
              let text = content.child("body")?.child("text") else { throw ConversionError.damaged("odt") }
        let reader = Reader(archive: archive)
        reader.loadStyles(try archive.data("styles.xml"))
        reader.loadStyles(contentData)
        reader.loadMeta(try archive.data("meta.xml"))
        reader.loadPageSize(try archive.data("styles.xml"))
        var blocks = reader.blocks(text.children)
        blocks += reader.notes
        return DocReadResult(model: DocModel(metadata: reader.metadata, blocks: blocks, resources: reader.resources), lossNotes: reader.lossNotes)
    }

    // MARK: -

    private struct Style {
        var parent: String?
        var displayName: String
        var text: XMLNode?
        var paragraph: XMLNode?
        var listStyle: String?
    }

    private enum Parsed {
        case block(DocBlock)
        case codeLine(String)
        case quote(DocBlock)
        case caption(DocText)
    }

    private final class Reader {
        let archive: ZipArchive
        var styles: [String: Style] = [:]
        var listStyles: [String: XMLNode] = [:]
        var metadata = DocMetadata()
        var resources: [String: Data] = [:]
        var pictureKeys: [String: String] = [:]
        var notes: [DocBlock] = []
        var noteCounter = 0
        var lossNotes: [LossNote] = []

        init(archive: ZipArchive) { self.archive = archive }

        func loadStyles(_ data: Data?) {
            guard let data, let root = try? XML.parse(data) else { return }
            for container in [root.child("styles"), root.child("automatic-styles")].compactMap({ $0 }) {
                for style in container.children("style") {
                    guard let name = style.attr("name") else { continue }
                    styles[name] = Style(parent: style.attr("parent-style-name"), displayName: style.attr("display-name") ?? name,
                                         text: style.child("text-properties"), paragraph: style.child("paragraph-properties"),
                                         listStyle: style.attr("list-style-name"))
                }
                for list in container.children("list-style") { if let name = list.attr("name") { listStyles[name] = list } }
            }
        }

        func loadMeta(_ data: Data?) {
            guard let data, let root = try? XML.parse(data), let meta = root.child("meta") else { return }
            func text(_ name: String) -> String? { meta.child(name)?.allText.trimmed }
            if let t = text("title"), !t.isEmpty { metadata.title = t }
            if let d = text("description"), !d.isEmpty { metadata.summary = d }
            if let c = text("initial-creator") ?? text("creator"), !c.isEmpty { metadata.authors = c.split(separator: ";").map { $0.trimmed }.filter { !$0.isEmpty } }
            if let l = text("language"), !l.isEmpty { metadata.language = l }
            if let d = text("creation-date"), let date = ISO8601DateFormatter().date(from: d) ?? Self.looseDate(d) { metadata.date = date }
        }

        static func looseDate(_ s: String) -> Date? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSS"
            return f.date(from: s) ?? { f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f.date(from: s) }()
        }

        func loadPageSize(_ data: Data?) {
            guard let data, let root = try? XML.parse(data), let props = root.all("page-layout-properties").first,
                  let w = props.attr("page-width").flatMap(Self.points), let h = props.attr("page-height").flatMap(Self.points) else { return }
            metadata.pageSize = VectorSize(width: w, height: h)
        }

        /// "21cm", "8.5in", "12pt", "210mm", "0.5in" → points.
        static func points(_ length: String) -> Double? {
            let units: [(String, Double)] = [("cm", 28.3465), ("mm", 2.83465), ("in", 72), ("pt", 1), ("pc", 12), ("px", 0.75)]
            for (unit, factor) in units where length.hasSuffix(unit) {
                return Double(length.dropLast(unit.count)).map { $0 * factor }
            }
            return Double(length)
        }

        // MARK: Style lookup

        func chain(_ name: String?) -> [Style] {
            var out: [Style] = []
            var seen = Set<String>()
            var current = name
            while let key = current, seen.insert(key).inserted, let style = styles[key] { out.append(style); current = style.parent }
            return out
        }

        func property(_ chain: [Style], _ keyPath: (Style) -> XMLNode?, _ attribute: String) -> String? {
            chain.compactMap { keyPath($0)?.attr(attribute) }.first
        }

        func format(forStyle name: String?, base: RunFormat) -> RunFormat {
            var f = base
            let c = chain(name)
            if let w = property(c, \.text, "font-weight") { f.bold = w == "bold" || (Int(w) ?? 0) >= 600 }
            if let i = property(c, \.text, "font-style") { f.italic = i == "italic" || i == "oblique" }
            if let s = property(c, \.text, "text-line-through-style") { f.strike = s != "none" }
            if let u = property(c, \.text, "text-underline-style"), !c.contains(where: { $0.displayName == "Internet link" }) { f.underline = u != "none" }
            if let p = property(c, \.text, "text-position") {
                let word = p.split(separator: " ").first.map(String.init) ?? p
                f.superscript = word == "super" || (word.hasSuffix("%") && (Double(word.dropLast()) ?? 0) > 0)
                f.subscripted = word == "sub" || (word.hasSuffix("%") && (Double(word.dropLast()) ?? 0) < 0)
            }
            if let font = property(c, \.text, "font-family") ?? property(c, \.text, "font-name") {
                let clean = font.replacingOccurrences(of: "'", with: "")
                if DOCXReader.monospaceFonts.contains(clean.lowercased()) { f.code = true } else { f.font = clean }
            }
            if let size = property(c, \.text, "font-size"), let value = Self.points(size) { f.size = value }
            if let colour = property(c, \.text, "color"), colour.hasPrefix("#"), colour.count == 7, !c.contains(where: { $0.displayName == "Internet link" }) { f.colour = colour.uppercased() }
            return f
        }

        func paragraphStyle(_ name: String?) -> DocParagraphStyle {
            let c = chain(name)
            var s = DocParagraphStyle()
            switch property(c, \.paragraph, "text-align") {
            case "center": s.alignment = .centre
            case "end", "right": s.alignment = .end
            case "justify": s.alignment = .justified
            default: break
            }
            s.spaceBefore = property(c, \.paragraph, "margin-top").flatMap(Self.points).flatMap { $0 > 0 ? $0 : nil }
            s.spaceAfter = property(c, \.paragraph, "margin-bottom").flatMap(Self.points).flatMap { $0 > 0 ? $0 : nil }
            if let font = property(c, \.text, "font-family") ?? property(c, \.text, "font-name") { s.fontName = font.replacingOccurrences(of: "'", with: "") }
            s.fontSize = property(c, \.text, "font-size").flatMap(Self.points)
            return s
        }

        func names(_ style: String?) -> [String] { chain(style).map { $0.displayName.lowercased() } + chain(style).map { ($0.parent ?? "").lowercased() } }

        // MARK: Blocks

        func blocks(_ nodes: [XMLNode]) -> [DocBlock] {
            var parsed: [Parsed] = []
            collect(nodes, into: &parsed)
            var out: [DocBlock] = []
            var i = 0
            while i < parsed.count {
                switch parsed[i] {
                case .block(let b): out.append(b)
                case .codeLine:
                    var lines: [String] = []
                    while i < parsed.count, case .codeLine(let l) = parsed[i] { lines.append(l); i += 1 }
                    out.append(.code(language: nil, text: lines.joined(separator: "\n")))
                    continue
                case .quote:
                    var inner: [DocBlock] = []
                    while i < parsed.count, case .quote(let b) = parsed[i] { inner.append(b); i += 1 }
                    out.append(.quote(inner))
                    continue
                case .caption(let text):
                    // A caption sits under a figure and above a table.
                    if case .figure(let r, let existing, let a)? = out.last, existing == nil {
                        out[out.count - 1] = .figure(resource: r, caption: text, altText: a)
                    } else if i + 1 < parsed.count, case .block(.table(var table)) = parsed[i + 1], table.caption == nil {
                        table.caption = text
                        out.append(.table(table))
                        i += 1
                    } else {
                        out.append(.paragraph(text, DocParagraphStyle()))
                    }
                }
                i += 1
            }
            return out
        }

        func collect(_ nodes: [XMLNode], into out: inout [Parsed]) {
            for node in nodes {
                switch node.name {
                case "h":
                    let text = inlines(node)
                    let level = min(max(Int(node.attr("outline-level") ?? "1") ?? 1, 1), 6)
                    out.append(.block(.heading(level: level, text)))
                case "p": paragraph(node, into: &out)
                case "list": out.append(.block(list(node)))
                case "table": out.append(.block(.table(table(node))))
                case "section", "index-body", "table-of-content", "alphabetical-index", "bibliography", "illustration-index":
                    collect(node.children, into: &out)
                case "table-of-content-source", "index-title-template": break
                case "index-title": collect(node.children, into: &out)
                default: break
                }
            }
        }

        func paragraph(_ p: XMLNode, into out: inout [Parsed]) {
            let styleName = p.attr("style-name")
            let n = names(styleName)
            let primary = chain(styleName).first?.displayName.lowercased() ?? (styleName ?? "").lowercased()
            let text = inlines(p)
            let plain = Inlines.plain(text).trimmed
            let breakBefore = chain(styleName).contains { $0.paragraph?.attr("break-before") == "page" }

            if primary == "title", !plain.isEmpty { metadata.title = plain; return }
            if primary == "author", !plain.isEmpty { metadata.authors = plain.split(separator: ";").map { $0.trimmed }; return }
            if primary == "date", !plain.isEmpty, let date = DOCXReader.plainDate(plain) ?? ISO8601DateFormatter().date(from: plain) { metadata.date = date; return }
            if primary == "abstract", !plain.isEmpty { metadata.summary = plain; return }
            if breakBefore { out.append(.block(.pageBreak)) }
            if text.isEmpty {
                if n.contains(where: { $0.contains("horizontal line") || $0.contains("horizontal_20_line") }) || chain(styleName).contains(where: { $0.paragraph?.attr("border-bottom") != nil }) { out.append(.block(.thematicBreak)) }
                else if n.contains(where: { $0.contains("preformatted") || $0.contains("source text") }) { out.append(.codeLine("")) }
                return
            }
            // A formula frame alone in its paragraph is display math.
            if text.count == 1, case .math(let tex) = text[0] { out.append(.block(.math(tex: tex, display: true))); return }
            if n.contains(where: { $0.contains("preformatted") || $0.contains("source text") }) {
                out.append(.codeLine(Self.rawText(p)))
                return
            }
            let allCode = Inlines.flatten(text).allSatisfy { if case .run(_, let f) = $0 { f.code } else if case .lineBreak = $0 { true } else { false } }
            if allCode { out.append(.codeLine(Inlines.plain(text))); return }
            if n.contains(where: { $0.contains("quotations") || $0 == "quote" || $0.contains("block quote") }) { out.append(.quote(.paragraph(text, paragraphStyle(styleName)))); return }
            if text.count == 1, case .image(let resource, let alt) = text[0] {
                out.append(.block(.figure(resource: resource, caption: nil, altText: alt)))
                return
            }
            if primary == "caption" || primary == "illustration" { out.append(.caption(text)); return }
            out.append(.block(.paragraph(text, paragraphStyle(styleName))))
        }

        /// The paragraph's characters exactly (preformatted text keeps its spaces and line breaks).
        static func rawText(_ node: XMLNode) -> String {
            var out = ""
            for c in node.content {
                switch c {
                case .text(let t): out += t
                case .element(let e):
                    switch e.name {
                    case "s": out += spaces(e)
                    case "tab": out += "\t"
                    case "line-break": out += "\n"
                    default: out += rawText(e)
                    }
                }
            }
            return out
        }

        // MARK: Inlines

        func inlines(_ node: XMLNode) -> DocText {
            var builder = InlineBuilder()
            // Headings, titles, captions and quotations look bold or italic by style; that is their role, not inline emphasis.
            let styleName = node.attr("style-name")
            let semantic = node.name == "h" || names(styleName).contains { name in
                ["title", "subtitle", "caption", "quotations", "quote", "author", "date", "abstract", "footnote", "illustration"].contains(name) || name.hasPrefix("heading")
            }
            walk(node, format: semantic ? RunFormat() : format(forStyle: styleName, base: RunFormat()), into: &builder)
            return builder.build()
        }

        func walk(_ node: XMLNode, format: RunFormat, into builder: inout InlineBuilder) {
            for c in node.content {
                switch c {
                case .text(let t):
                    // ODF collapses white-space runs; a leading space after another is dropped by the writer's text:s.
                    builder.add(t.replacingOccurrences(of: "\n", with: " "), format)
                case .element(let e):
                    switch e.name {
                    case "span": walk(e, format: self.format(forStyle: e.attr("style-name"), base: format), into: &builder)
                    case "a":
                        var f = format
                        f.link = e.attr("href")
                        walk(e, format: self.format(forStyle: e.attr("style-name"), base: f), into: &builder)
                    case "s": builder.add(spaces(e), format)
                    case "tab": builder.add("\t", format)
                    case "line-break": builder.add(.lineBreak)
                    case "frame": frame(e, link: format.link, into: &builder)
                    case "note": note(e, into: &builder)
                    case "soft-page-break", "bookmark", "bookmark-start", "bookmark-end", "change", "change-start", "change-end", "annotation", "annotation-end", "sequence-decls": break
                    case "tracked-changes": break
                    default: walk(e, format: format, into: &builder)
                    }
                }
            }
        }

        func frame(_ frame: XMLNode, link: String?, into builder: inout InlineBuilder) {
            let alt = frame.child("desc")?.allText.nilIfEmpty ?? frame.child("title")?.allText.nilIfEmpty
            if let image = frame.child("image") {
                var data: Data?
                var key: String?
                if let href = image.attr("href"), !href.hasPrefix("http") {
                    let path = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
                    if let known = pictureKeys[path] { builder.add(.image(resource: known, alt: alt, link: link)); return }
                    data = try? archive.data(path)
                    key = (path as NSString).lastPathComponent
                    if let data, let k = key {
                        var unique = k
                        while resources[unique] != nil { unique = "image\(resources.count + 1)." + (k as NSString).pathExtension }
                        resources[unique] = data
                        pictureKeys[path] = unique
                        builder.add(.image(resource: unique, alt: alt, link: link))
                    }
                } else if let binary = image.child("binary-data")?.allText, let decoded = Data(base64Encoded: binary, options: .ignoreUnknownCharacters) {
                    let unique = "image\(resources.count + 1)." + (ImageSniff.commonType(decoded).map { $0 == "jpeg" ? "jpg" : $0 } ?? "png")
                    resources[unique] = decoded
                    builder.add(.image(resource: unique, alt: alt, link: link))
                }
            } else if let object = frame.child("object") {
                guard let href = object.attr("href") else { return }
                let folder = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
                if let data = try? archive.data(folder + "/content.xml"), let root = try? XML.parse(data) {
                    let math = root.name == "math" ? root : (root.first("math") ?? root)
                    builder.add(.math(tex: MathML.tex(math)))
                }
            } else if let box = frame.child("text-box") {
                var inner: [Parsed] = []
                collect(box.children, into: &inner)
                for case .block(.paragraph(let text, _)) in inner { for item in Inlines.flatten(text) { builder.add(item) } }
            }
        }

        func note(_ note: XMLNode, into builder: inout InlineBuilder) {
            noteCounter += 1
            let id = note.attr("id") ?? "n\(noteCounter)"
            let body = blocks(note.child("note-body")?.children ?? [])
            notes.append(.footnote(id: id, body))
            builder.add(.footnote(id: id))
        }

        // MARK: Lists

        /// Style names of the lists being read, innermost last: a nested list without a style takes its parent's.
        var listStack: [String] = []

        func list(_ node: XMLNode) -> DocBlock {
            let styleName = node.attr("style-name") ?? listStack.last ?? ""
            listStack.append(styleName)
            defer { listStack.removeLast() }
            let levelStyle = listStyles[styleName]?.children.first { $0.attr("level") == String(listStack.count) }
            let ordered = levelStyle?.name == "list-level-style-number"
            let start = ListAssembler.start(Int(node.child("list-item")?.attr("start-value") ?? levelStyle?.attr("start-value") ?? "1"))
            let items = node.children.filter { $0.name == "list-item" || $0.name == "list-header" }.map { blocks($0.children) }
            return .list(ordered: ordered, start: start, items: items)
        }

        // MARK: Tables

        func table(_ node: XMLNode) -> DocTable {
            var rows: [[DocTable.Cell]] = []
            func addRows(_ container: XMLNode, header: Bool) {
                for child in container.children {
                    switch child.name {
                    case "table-row":
                        let row = tableRow(child, header: header)
                        let repeated = min(max(Int(child.attr("number-rows-repeated") ?? "1") ?? 1, 1), 100)
                        let isBlank = row.allSatisfy { $0.blocks == [.paragraph([], DocParagraphStyle())] }
                        for _ in 0..<(isBlank ? 1 : repeated) { rows.append(row) }
                    case "table-header-rows": addRows(child, header: true)
                    case "table-row-group", "table-rows": addRows(child, header: header)
                    default: break
                    }
                }
            }
            addRows(node, header: false)
            var alignments: [DocParagraphStyle.Alignment] = []
            if let first = rows.first {
                for cell in first {
                    var a = DocParagraphStyle.Alignment.start
                    if case .paragraph(_, let s)? = cell.blocks.first { a = s.alignment }
                    alignments += Array(repeating: a, count: cell.columnSpan)
                }
            }
            return DocTable(rows: rows, caption: nil, alignments: alignments)
        }

        /// One row's cells; covered cells (the rest of a span) add nothing.
        func tableRow(_ row: XMLNode, header: Bool) -> [DocTable.Cell] {
            var cells: [DocTable.Cell] = []
            for cell in row.children where cell.name == "table-cell" {
                let repeated = min(max(Int(cell.attr("number-columns-repeated") ?? "1") ?? 1, 1), 64)
                let span = TableGrid.span(Int(cell.attr("number-columns-spanned") ?? "1"))
                var blocks = self.blocks(cell.children)
                if blocks.isEmpty { blocks = [.paragraph([], DocParagraphStyle())] }
                let rowSpan = TableGrid.span(Int(cell.attr("number-rows-spanned") ?? "1"))
                for _ in 0..<repeated { cells.append(DocTable.Cell(blocks: blocks, columnSpan: span, rowSpan: rowSpan, isHeader: header)) }
            }
            return cells
        }
    }
}

private extension String {
    var nilIfEmpty: String? { let t = trimmed; return t.isEmpty ? nil : t }
}

/// The spaces a `text:s` stands for: its count is the file's word, so a negative one (a trap) or one in the billions (a
/// runaway allocation) is damage; no real document runs a thousand spaces together.
private func spaces(_ node: XMLNode) -> String {
    String(repeating: " ", count: min(max(Int(node.attr("c") ?? "1") ?? 1, 0), 1_000))
}
