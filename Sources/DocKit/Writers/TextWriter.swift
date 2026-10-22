import Foundation
import SuperConverterCore

/// `DocModel` → plain text (formats §3.2 `TextWriter`): UTF-8 without BOM, LF, no wrapping unless asked (O-DOC). Headings
/// are underlined, lists keep their markers, tables are aligned in columns, notes follow the text.
enum TextWriter {
    static func write(_ model: DocModel, options: DocWriteOptions, to url: URL) throws -> [LossNote] {
        let (text, notes) = render(model, wrap: options.wrap)
        try TextCoding.encode(options.crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text, as: options.encoding).write(to: url, options: .atomic)
        return notes
    }

    static func render(_ model: DocModel, wrap: Int? = nil) -> (String, [LossNote]) {
        var r = Renderer(model: model, wrap: wrap)
        return r.run()
    }

    private struct Renderer {
        let model: DocModel
        let wrap: Int?
        var lossNotes: [LossNote] = []
        var footnoteNumbers: [String: Int] = [:]
        var footnoteBodies: [String: [DocBlock]] = [:]

        init(model: DocModel, wrap: Int?) {
            self.model = model; self.wrap = wrap
            for case .footnote(let id, let blocks) in model.blocks { footnoteBodies[id] = blocks }
        }

        mutating func run() -> (String, [LossNote]) {
            var parts: [String] = []
            let m = model.metadata
            if let t = m.title { parts.append(t + "\n" + String(repeating: "=", count: t.count)) }
            if !m.authors.isEmpty { parts.append(m.authors.joined(separator: "; ")) }
            if let d = m.date { parts.append(DocDates.string(d)) }
            if let s = m.summary { parts.append(wrapped(s)) }
            for block in model.blocks { if let s = self.block(block) { parts.append(s) } }
            var done = 0
            var notes: [String] = []
            while done < footnoteNumbers.count {
                guard let (id, number) = footnoteNumbers.first(where: { $0.value == done + 1 }) else { break }
                done += 1
                let body = (footnoteBodies[id] ?? []).compactMap { self.block($0) }.joined(separator: "\n\n")
                notes.append("[\(number)] " + body.replacingOccurrences(of: "\n", with: "\n    "))
            }
            if !notes.isEmpty { parts.append(notes.joined(separator: "\n")) }
            return (parts.joined(separator: "\n\n") + "\n", LossNote.merged(lossNotes))
        }

        func wrapped(_ s: String, indent: String = "") -> String { wrap.map { TextWrap.wrap(s, width: $0, indent: indent) } ?? s }

        mutating func block(_ block: DocBlock) -> String? {
            switch block {
            case .heading(let level, let text):
                let t = inline(text)
                return level <= 2 ? t + "\n" + String(repeating: level == 1 ? "=" : "-", count: t.count) : t
            case .paragraph(let text, _):
                let s = inline(text)
                return s.isEmpty ? nil : wrapped(s)
            case .list(let ordered, let start, let items):
                var out: [String] = []
                for (i, item) in items.enumerated() {
                    let marker = ordered ? "\(start + i). " : "- "
                    var body = ""
                    for child in item {
                        guard let part = self.block(child) else { continue }
                        if body.isEmpty { body = part } else if case .list = child { body += "\n" + part } else { body += "\n\n" + part }
                    }
                    let pad = String(repeating: " ", count: marker.count)
                    out.append(marker + body.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { $0 == 0 ? String($1) : ($1.isEmpty ? "" : pad + $1) }.joined(separator: "\n"))
                }
                return out.joined(separator: "\n")
            case .table(let table): return self.table(table)
            case .figure(_, let caption, let alt):
                let text = caption.map { inline($0) } ?? alt
                return text.map { "[Image: \($0)]" } ?? "[Image]"
            case .code(_, let text):
                return text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : "    " + $0 }.joined(separator: "\n")
            case .quote(let blocks):
                let inner = blocks.compactMap { self.block($0) }.joined(separator: "\n\n")
                return inner.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
            case .math(let tex, _): return "    " + tex
            case .footnote: return nil
            case .thematicBreak: return String(repeating: "-", count: 40)
            case .pageBreak: return nil
            }
        }

        mutating func table(_ table: DocTable) -> String? {
            let (columns, rows) = TableGrid.expand(table)
            guard !rows.isEmpty else { return nil }
            if TableGrid.hasSpans(table) { lossNotes.append(LossNote(.tableSimplified, detail: "merged cells")) }
            let cells: [[String]] = rows.map { row in
                row.map { slot in
                    slot.cell.map { cell in cell.blocks.compactMap { self.block($0) }.joined(separator: " ").replacingOccurrences(of: "\n", with: " ") } ?? ""
                }
            }
            var widths = [Int](repeating: 0, count: columns)
            for row in cells { for (i, c) in row.enumerated() { widths[i] = max(widths[i], c.count) } }
            func line(_ row: [String]) -> String {
                row.enumerated().map { i, c in
                    let alignment = i < table.alignments.count ? table.alignments[i] : .start
                    let pad = String(repeating: " ", count: widths[i] - c.count)
                    switch alignment { case .end: return pad + c; case .centre: return String(pad.prefix(pad.count / 2)) + c + String(pad.dropFirst(pad.count / 2)); default: return c + pad }
                }.joined(separator: "  ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
            var lines: [String] = []
            if let caption = table.caption { lines.append(inline(caption)) }
            let headers = table.rows.prefix { !$0.isEmpty && $0.allSatisfy(\.isHeader) }.count
            for (i, row) in cells.enumerated() {
                lines.append(line(row))
                if i == max(headers, 1) - 1 { lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")) }
            }
            return lines.joined(separator: "\n")
        }

        mutating func inline(_ text: DocText) -> String {
            var out = ""
            for item in text {
                switch item {
                case .text(let t), .code(let t): out += t
                case .emphasis(let c), .strong(let c), .strike(let c), .styled(let c, _): out += inline(c)
                case .link(let c, let destination):
                    let label = inline(c)
                    out += label == destination || label.isEmpty ? destination : "\(label) (\(destination))"
                case .image(_, let alt): out += alt.map { "[Image: \($0)]" } ?? "[Image]"
                case .footnoteReference(let id):
                    let n = footnoteNumbers[id] ?? { let n = footnoteNumbers.count + 1; footnoteNumbers[id] = n; return n }()
                    out += "[\(n)]"
                case .math(let tex): out += tex
                case .lineBreak: out += "\n"
                }
            }
            return out
        }
    }
}
