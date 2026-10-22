import Foundation
import SuperConverterCore

/// Pandoc's JSON AST (`pandoc -t json`, pandoc-types 1.23) → `DocModel` (formats §4: "we read Pandoc's AST, never its
/// writers"). Anything the model has no place for is flattened to its text and counted in `flattened`.
final class PandocAST {
    enum ASTError: Error { case notPandocJSON }

    private(set) var flattened = Set<String>()
    private var footnotes: [DocBlock] = []
    private var resources: [String: Data] = [:]
    private let baseFolder: URL?

    private init(baseFolder: URL?) { self.baseFolder = baseFolder }

    /// `baseFolder` is where relative picture paths are looked for (the source file's folder).
    static func docModel(from json: Data, baseFolder: URL?) throws -> (model: DocModel, flattened: [String]) {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any], let blocks = root["blocks"] as? [[String: Any]] else {
            throw ASTError.notPandocJSON
        }
        let reader = PandocAST(baseFolder: baseFolder)
        var out = reader.blocks(blocks)
        out += reader.footnotes
        let meta = reader.metadata(root["meta"] as? [String: Any] ?? [:])
        return (DocModel(metadata: meta, blocks: out, resources: reader.resources), reader.flattened.sorted())
    }

    // MARK: Metadata

    private func metadata(_ meta: [String: Any]) -> DocMetadata {
        var result = DocMetadata()
        result.title = metaText(meta["title"])
        if let authors = meta["author"] as? [String: Any] {
            if authors["t"] as? String == "MetaList", let list = authors["c"] as? [Any] {
                result.authors = list.compactMap(metaText)
            } else if let one = metaText(authors) { result.authors = [one] }
        }
        result.language = metaText(meta["lang"])
        result.summary = metaText(meta["abstract"])
        if let date = metaText(meta["date"]) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            result.date = formatter.date(from: String(date.prefix(10)))
        }
        return result
    }

    private func metaText(_ value: Any?) -> String? {
        guard let node = value as? [String: Any], let tag = node["t"] as? String else { return nil }
        let text: String
        switch tag {
        case "MetaString": text = node["c"] as? String ?? ""
        case "MetaInlines": text = plain(inlines(node["c"] as? [[String: Any]] ?? []))
        case "MetaBlocks": text = (node["c"] as? [[String: Any]] ?? []).map { plain(inlines($0["c"] as? [[String: Any]] ?? [])) }.joined(separator: " ")
        default: return nil
        }
        return text.isEmpty ? nil : text
    }

    // MARK: Blocks

    private func blocks(_ list: [[String: Any]]) -> [DocBlock] { list.flatMap(block) }

    private func block(_ node: [String: Any]) -> [DocBlock] {
        let c = node["c"]
        switch node["t"] as? String ?? "" {
        case "Para", "Plain":
            let text = inlines(c as? [[String: Any]] ?? [])
            if text.count == 1, case .math(let tex) = text[0], isDisplay(c) { return [.math(tex: tex, display: true)] }
            return [.paragraph(text, DocParagraphStyle())]
        case "LineBlock":
            let lines = (c as? [[[String: Any]]] ?? []).map(inlines)
            var text: DocText = []
            for (i, line) in lines.enumerated() { if i > 0 { text.append(.lineBreak) }; text += line }
            return [.paragraph(text, DocParagraphStyle())]
        case "CodeBlock":
            guard let parts = c as? [Any], parts.count == 2, let attr = parts[0] as? [Any], let text = parts[1] as? String else { return [] }
            return [.code(language: (attr[safe: 1] as? [String])?.first, text: text)]
        case "RawBlock":
            flattened.insert("raw blocks")
            return []
        case "BlockQuote": return [.quote(blocks(c as? [[String: Any]] ?? []))]
        case "BulletList": return [.list(ordered: false, start: 1, items: (c as? [[[String: Any]]] ?? []).map(blocks))]
        case "OrderedList":
            guard let parts = c as? [Any], parts.count == 2 else { return [] }
            let start = ((parts[0] as? [Any])?.first as? Int) ?? 1
            return [.list(ordered: true, start: start, items: (parts[1] as? [[[String: Any]]] ?? []).map(blocks))]
        case "DefinitionList":
            // Term in bold, then its definitions, one list item per entry.
            let entries = c as? [[Any]] ?? []
            let items: [[DocBlock]] = entries.compactMap { entry in
                guard entry.count == 2 else { return nil }
                let term = inlines(entry[0] as? [[String: Any]] ?? [])
                let definitions = (entry[1] as? [[[String: Any]]] ?? []).flatMap(blocks)
                return [.paragraph([.strong(term)], DocParagraphStyle())] + definitions
            }
            return [.list(ordered: false, start: 1, items: items)]
        case "Header":
            guard let parts = c as? [Any], parts.count == 3, let level = parts[0] as? Int else { return [] }
            return [.heading(level: min(max(level, 1), 6), inlines(parts[2] as? [[String: Any]] ?? []))]
        case "HorizontalRule": return [.thematicBreak]
        case "Div":
            guard let parts = c as? [Any], parts.count == 2 else { return [] }
            return blocks(parts[1] as? [[String: Any]] ?? [])
        case "Figure":
            guard let parts = c as? [Any], parts.count == 3 else { return [] }
            return blocks(parts[2] as? [[String: Any]] ?? [])
        case "Table": return table(c as? [Any] ?? [])
        default:
            flattened.insert((node["t"] as? String ?? "unknown") + " blocks")
            return []
        }
    }

    private func isDisplay(_ list: Any?) -> Bool {
        guard let first = (list as? [[String: Any]])?.first, first["t"] as? String == "Math",
              let parts = first["c"] as? [Any], let kind = parts.first as? [String: Any] else { return false }
        return kind["t"] as? String == "DisplayMath"
    }

    private func table(_ parts: [Any]) -> [DocBlock] {
        guard parts.count == 6 else { return [] }
        let caption = ((parts[1] as? [Any])?[safe: 1] as? [[String: Any]]).map(blocks)?.compactMap { block -> DocText? in
            if case .paragraph(let text, _) = block { text } else { nil }
        }.first
        let alignments = (parts[2] as? [[Any]] ?? []).map { alignment(($0.first as? [String: Any])?["t"] as? String) }
        func rows(_ list: Any?, header: Bool) -> [[DocTable.Cell]] {
            (list as? [[Any]] ?? []).map { row in
                (row[safe: 1] as? [[Any]] ?? []).map { cell in
                    DocTable.Cell(blocks: blocks(cell[safe: 4] as? [[String: Any]] ?? []), columnSpan: cell[safe: 3] as? Int ?? 1,
                                  rowSpan: cell[safe: 2] as? Int ?? 1, isHeader: header)
                }
            }
        }
        var all = rows((parts[3] as? [Any])?[safe: 1], header: true)
        for body in parts[4] as? [[Any]] ?? [] { all += rows(body[safe: 2], header: true) + rows(body[safe: 3], header: false) }
        all += rows((parts[5] as? [Any])?[safe: 1], header: false)
        return [.table(DocTable(rows: all, caption: caption, alignments: alignments))]
    }

    private func alignment(_ tag: String?) -> DocParagraphStyle.Alignment {
        switch tag { case "AlignRight": .end; case "AlignCenter": .centre; default: .start }
    }

    // MARK: Inlines

    private func inlines(_ list: [[String: Any]]) -> DocText { list.flatMap(inline) }

    private func inline(_ node: [String: Any]) -> DocText {
        let c = node["c"]
        func nested() -> DocText { inlines(c as? [[String: Any]] ?? []) }
        switch node["t"] as? String ?? "" {
        case "Str": return [.text(c as? String ?? "")]
        case "Space", "SoftBreak": return [.text(" ")]
        case "LineBreak": return [.lineBreak]
        case "Emph": return [.emphasis(nested())]
        case "Strong": return [.strong(nested())]
        case "Strikeout": return [.strike(nested())]
        case "Underline": return [.styled(nested(), DocRunStyle(underline: true))]
        case "Superscript": return [.styled(nested(), DocRunStyle(superscript: true))]
        case "Subscript": return [.styled(nested(), DocRunStyle(subscripted: true))]
        case "SmallCaps": return nested()
        case "Quoted":
            guard let parts = c as? [Any], parts.count == 2 else { return [] }
            let single = (parts[0] as? [String: Any])?["t"] as? String == "SingleQuote"
            return [.text(single ? "‘" : "“")] + inlines(parts[1] as? [[String: Any]] ?? []) + [.text(single ? "’" : "”")]
        case "Cite":
            guard let parts = c as? [Any], parts.count == 2 else { return [] }
            return inlines(parts[1] as? [[String: Any]] ?? [])
        case "Code": return [.code(((c as? [Any])?[safe: 1] as? String) ?? "")]
        case "Math":
            guard let parts = c as? [Any], parts.count == 2 else { return [] }
            return [.math(tex: parts[1] as? String ?? "")]
        case "RawInline":
            flattened.insert("raw inlines")
            return []
        case "Link":
            guard let parts = c as? [Any], parts.count == 3 else { return [] }
            let target = (parts[2] as? [String])?.first ?? ""
            return [.link(inlines(parts[1] as? [[String: Any]] ?? []), destination: target)]
        case "Image":
            guard let parts = c as? [Any], parts.count == 3 else { return [] }
            let path = (parts[2] as? [String])?.first ?? ""
            let alt = plain(inlines(parts[1] as? [[String: Any]] ?? []))
            if resources[path] == nil, let base = baseFolder, !path.contains("://"),
               let data = try? Data(contentsOf: base.appendingPathComponent(path)) { resources[path] = data }
            return [.image(resource: path, altText: alt.isEmpty ? nil : alt)]
        case "Note":
            let id = String(footnotes.count + 1)
            footnotes.append(.footnote(id: id, blocks(c as? [[String: Any]] ?? [])))
            return [.footnoteReference(id: id)]
        case "Span": return inlines(((c as? [Any])?[safe: 1] as? [[String: Any]]) ?? [])
        default:
            flattened.insert((node["t"] as? String ?? "unknown") + " inlines")
            return []
        }
    }

    private func plain(_ text: DocText) -> String {
        text.map { part -> String in
            switch part {
            case .text(let s), .code(let s): s
            case .emphasis(let t), .strong(let t), .strike(let t), .styled(let t, _), .link(let t, _): plain(t)
            case .math(let tex): tex
            case .lineBreak: " "
            case .image(_, let alt): alt ?? ""
            case .footnoteReference: ""
            }
        }.joined()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
