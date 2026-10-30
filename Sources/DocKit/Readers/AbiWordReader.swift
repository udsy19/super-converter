import Foundation
import SuperConverterCore

/// AbiWord (.abw, and gzip-compressed .zabw) → `DocModel` (formats §3.2 `AbiWordReader`): sections, paragraphs with their
/// styles and `props`, character runs, hyperlinks, lists, tables with cell attachments, embedded pictures, footnotes.
enum AbiWordReader {
    static func read(_ url: URL, options: DocReadOptions = DocReadOptions()) throws -> DocReadResult {
        var data = try Data(contentsOf: url, options: .mappedIfSafe)
        if Gzip.isGzip(data) {
            guard let inflated = Gzip.inflate(data) else { throw ConversionError.damaged("zabw") }
            data = inflated
        }
        guard let root = try? XML.parse(data, keepWhitespace: true), root.name == "abiword" else { throw ConversionError.damaged("abw") }
        var reader = Reader()
        return reader.run(root)
    }

    private struct Reader {
        var metadata = DocMetadata()
        var resources: [String: Data] = [:]
        var footnoteSections: [String: XMLNode] = [:]
        var noteBlocks: [DocBlock] = []
        /// Notes being read: a note section that refers to itself (or to a note that refers back) is read once, not forever.
        var readingNotes = Set<String>()
        var styles: [String: [String: String]] = [:]

        mutating func run(_ root: XMLNode) -> DocReadResult {
            for m in root.child("metadata")?.children("m") ?? [] {
                let value = m.allText.trimmed
                guard !value.isEmpty else { continue }
                switch m.attr("key") {
                case "dc.title": metadata.title = value
                case "dc.creator": metadata.authors = value.split(separator: ";").map { $0.trimmed }
                case "dc.description": metadata.summary = value
                case "dc.language": metadata.language = value
                case "abiword.date_last_changed", "dc.date": metadata.date = Self.date(value)
                default: break
                }
            }
            for s in root.child("styles")?.children("s") ?? [] {
                if let name = s.attr("name") { styles[name] = Self.props(s.attr("props") ?? "") }
            }
            for d in root.child("data")?.children("d") ?? [] {
                guard let name = d.attr("name") else { continue }
                let payload = d.allText.filter { !$0.isWhitespace }
                let bytes = d.attr("base64") == "yes" ? Data(base64Encoded: payload) : Data(d.allText.utf8)
                if let bytes {
                    let ext = (d.attr("mime-type") ?? "").split(separator: "/").last.map(String.init) ?? "png"
                    resources[name + (name.contains(".") ? "" : "." + (ext == "jpeg" ? "jpg" : ext))] = bytes
                }
            }
            for s in root.children("section") where s.attr("type") == "footnote" || s.attr("type") == "endnote" {
                if let id = s.attr("footnote-id") ?? s.attr("endnote-id") ?? s.attr("id") { footnoteSections[id] = s }
            }
            var blocks: [DocBlock] = []
            var listEntries: [ListAssembler.Entry] = []
            func flushList() { blocks += ListAssembler.assemble(listEntries); listEntries = [] }
            for section in root.children("section") where section.attr("type") == nil || section.attr("type") == "doc" {
                for node in section.children {
                    if node.name == "p", let entry = listEntry(node) { listEntries.append(entry); continue }
                    flushList()
                    blocks += block(node)
                }
            }
            flushList()
            blocks += noteBlocks
            return DocReadResult(model: DocModel(metadata: metadata, blocks: blocks, resources: resources))
        }

        static func date(_ s: String) -> Date? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            for format in ["EEE MMM dd HH:mm:ss yyyy", "yyyy-MM-dd'T'HH:mm:ss"] { f.dateFormat = format; if let d = f.date(from: s) { return d } }
            return nil
        }

        static func props(_ s: String) -> [String: String] {
            var out: [String: String] = [:]
            for pair in s.split(separator: ";") {
                guard let colon = pair.firstIndex(of: ":") else { continue }
                out[pair[..<colon].trimmed] = pair[pair.index(after: colon)...].trimmed
            }
            return out
        }

        func resolved(_ node: XMLNode) -> [String: String] {
            var out: [String: String] = [:]
            if let style = node.attr("style") {
                var chain: [[String: String]] = []
                var current: String? = style
                var seen = Set<String>()
                while let name = current, seen.insert(name).inserted, let props = styles[name] { chain.append(props); current = props["basedon"] }
                for props in chain.reversed() { out.merge(props) { $1 } }
            }
            out.merge(Self.props(node.attr("props") ?? "")) { $1 }
            return out
        }

        func isList(_ node: XMLNode) -> Bool { (node.attr("listid").map { $0 != "0" && !$0.isEmpty } ?? false) }

        mutating func listEntry(_ p: XMLNode) -> ListAssembler.Entry? {
            guard isList(p) else { return nil }
            let props = resolved(p)
            let style = (props["list-style"] ?? p.attr("style") ?? "").lowercased()
            let ordered = style.contains("numbered") || style.contains("lower") || style.contains("upper") || style.contains("roman") || style.contains("number")
            let level = max(Int(p.attr("level") ?? "1") ?? 1, 1) - 1
            return ListAssembler.Entry(level: level, ordered: ordered, start: ListAssembler.start(Int(props["start-value"] ?? "1")), blocks: [.paragraph(inlines(p), alignment(props))], listID: p.attr("listid") ?? "")
        }

        func alignment(_ props: [String: String]) -> DocParagraphStyle {
            var s = DocParagraphStyle()
            switch props["text-align"] {
            case "center": s.alignment = .centre
            case "right": s.alignment = .end
            case "justify": s.alignment = .justified
            default: break
            }
            return s
        }

        mutating func block(_ node: XMLNode) -> [DocBlock] {
            switch node.name {
            case "p", "h":
                let props = resolved(node)
                let name = (node.attr("style") ?? "").lowercased()
                let text = inlines(node)
                if name.hasPrefix("heading "), let level = Int(name.dropFirst(8)) { return [.heading(level: min(max(level, 1), 6), text)] }
                if text.isEmpty { return [.paragraph([], alignment(props))] }
                if name == "title" { metadata.title = Inlines.plain(text); return [] }
                if name.contains("block text") || name.contains("quote") { return [.quote([.paragraph(text, alignment(props))])] }
                if name.contains("plain text") || (props["font-family"].map { DOCXReader.monospaceFonts.contains($0.lowercased()) } ?? false) { return [.code(language: nil, text: Inlines.plain(text))] }
                if text.count == 1, case .image(let r, let a) = text[0] { return [.figure(resource: r, caption: nil, altText: a)] }
                return [.paragraph(text, alignment(props))]
            case "table":
                return [.table(table(node))]
            default:
                return []
            }
        }

        mutating func table(_ node: XMLNode) -> DocTable {
            struct Placed { var top: Int; var left: Int; var cell: DocTable.Cell }
            var placed: [Placed] = []
            for cell in node.children("cell") {
                let props = Self.props(cell.attr("props") ?? "")
                // Attach points are the file's word: kept in a table's range, so the spans between them cannot overflow.
                func attach(_ key: String, _ fallback: Int) -> Int { min(max(props[key].flatMap { Int($0) } ?? fallback, 0), 1 << 20) }
                let left = attach("left-attach", 0), right = attach("right-attach", left + 1)
                let top = attach("top-attach", 0), bottom = attach("bot-attach", top + 1)
                var blocks: [DocBlock] = []
                for child in cell.children { blocks += block(child) }
                if blocks.isEmpty { blocks = [.paragraph([], DocParagraphStyle())] }
                placed.append(Placed(top: top, left: left, cell: DocTable.Cell(blocks: blocks, columnSpan: TableGrid.span(right - left), rowSpan: TableGrid.span(bottom - top), isHeader: false)))
            }
            let rows = Dictionary(grouping: placed, by: \.top).sorted { $0.key < $1.key }.map { $0.value.sorted { $0.left < $1.left }.map(\.cell) }
            return DocTable(rows: rows)
        }

        mutating func inlines(_ p: XMLNode) -> DocText {
            var builder = InlineBuilder()
            walk(p, RunFormat(), &builder)
            builder.trim()
            return builder.build()
        }

        mutating func walk(_ node: XMLNode, _ base: RunFormat, _ builder: inout InlineBuilder) {
            for c in node.content {
                switch c {
                case .text(let t): builder.add(t.replacingOccurrences(of: "\n", with: " "), base)
                case .element(let e):
                    switch e.name {
                    case "c":
                        var f = base
                        let props = Self.props(e.attr("props") ?? "")
                        if props["font-weight"] == "bold" { f.bold = true }
                        if props["font-style"] == "italic" { f.italic = true }
                        if let d = props["text-decoration"] { if d.contains("underline") { f.underline = true }; if d.contains("line-through") { f.strike = true } }
                        if let p = props["text-position"] { f.superscript = p == "superscript"; f.subscripted = p == "subscript" }
                        if let family = props["font-family"] { if DOCXReader.monospaceFonts.contains(family.lowercased()) { f.code = true } else { f.font = family } }
                        if let size = props["font-size"], let v = Double(size.replacingOccurrences(of: "pt", with: "")) { f.size = v }
                        if let colour = props["color"], colour.count == 6, colour != "000000" { f.colour = "#" + colour.uppercased() }
                        walk(e, f, &builder)
                    case "a":
                        var f = base
                        f.link = e.attr("href")
                        walk(e, f, &builder)
                    case "br": builder.add(.lineBreak)
                    case "cbr", "pbr": builder.add(.lineBreak)
                    case "image":
                        if let id = e.attr("dataid") {
                            let key = resources.keys.first { $0 == id || $0.hasPrefix(id + ".") } ?? id
                            builder.add(.image(resource: key, alt: e.attr("alt") ?? e.attr("title"), link: base.link))
                        }
                    case "field":
                        switch e.attr("type") {
                        case "footnote_ref", "endnote_ref":
                            if let id = e.attr("param") ?? e.attr("footnote-id") {
                                if let section = footnoteSections[id], readingNotes.insert(id).inserted,
                                   !noteBlocks.contains(where: { if case .footnote(let n, _) = $0 { n == id } else { false } }) {
                                    var inner: [DocBlock] = []
                                    for child in section.children { inner += block(child) }
                                    noteBlocks.append(.footnote(id: id, inner))
                                }
                                builder.add(.footnote(id: id))
                            }
                        case "list_label": break
                        default: walk(e, base, &builder)
                        }
                    default: walk(e, base, &builder)
                    }
                }
            }
        }
    }
}
