import Foundation
import SuperConverterCore

/// `DocModel` → reStructuredText (formats §3.2 `RSTWriter`): section titles by adornment, field-list metadata, lists,
/// `code-block`, `list-table`, `figure`, `math` and numbered footnotes. Docutils reads the result.
enum RSTWriter {
    static func write(_ model: DocModel, options: DocWriteOptions, to url: URL) throws -> [LossNote] {
        let (text, notes) = render(model)
        try TextCoding.encode(options.crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text, as: options.encoding).write(to: url, options: .atomic)
        return notes
    }

    static func render(_ model: DocModel) -> (String, [LossNote]) {
        var r = Renderer(model: model)
        return r.run()
    }

    private struct Renderer {
        let model: DocModel
        var lossNotes: [LossNote] = []
        var footnoteNumbers: [String: Int] = [:]
        var footnoteBodies: [String: [DocBlock]] = [:]
        var substitutions: [(name: String, resource: String, alt: String)] = []

        static let adornments: [Character] = ["=", "-", "~", "^", "\"", "'"]

        init(model: DocModel) {
            self.model = model
            for case .footnote(let id, let blocks) in model.blocks { footnoteBodies[id] = blocks }
        }

        mutating func run() -> (String, [LossNote]) {
            var parts: [String] = []
            let m = model.metadata
            if let title = m.title {
                let bar = String(repeating: "=", count: max(title.count, 4))
                parts.append("\(bar)\n\(Self.escape(title))\n\(bar)")
            }
            var fields: [String] = []
            if !m.authors.isEmpty { fields.append(":Author: " + m.authors.joined(separator: "; ")) }
            if let d = m.date { fields.append(":Date: " + DocDates.string(d)) }
            if let l = m.language { fields.append(":Language: " + l) }
            if !fields.isEmpty { parts.append(fields.joined(separator: "\n")) }
            if let s = m.summary { parts.append(".. topic:: Abstract\n\n" + Self.indent(Self.escape(s), 3)) }
            for block in model.blocks { if let s = self.block(block) { parts.append(s) } }
            var done = 0
            var notes: [String] = []
            while done < footnoteNumbers.count {
                guard let (id, number) = footnoteNumbers.first(where: { $0.value == done + 1 }) else { break }
                done += 1
                let body = (footnoteBodies[id] ?? []).compactMap { self.block($0) }.joined(separator: "\n\n")
                notes.append(".. [#fn\(number)]\n" + Self.indent(body, 3))
            }
            if !notes.isEmpty { parts.append(notes.joined(separator: "\n\n")) }
            if !substitutions.isEmpty {
                parts.append(substitutions.map { ".. |\($0.name)| image:: \($0.resource)\n   :alt: \($0.alt)" }.joined(separator: "\n"))
            }
            return (parts.joined(separator: "\n\n") + "\n", LossNote.merged(lossNotes))
        }

        static func indent(_ text: String, _ n: Int) -> String {
            let pad = String(repeating: " ", count: n)
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : pad + $0 }.joined(separator: "\n")
        }

        // MARK: Blocks

        mutating func block(_ block: DocBlock) -> String? {
            switch block {
            case .heading(let level, let text):
                let t = inline(text)
                return t + "\n" + String(repeating: Self.adornments[min(max(level, 1), 6) - 1], count: max(Inlines.plain(text).count, t.count, 3))
            case .paragraph(let text, _):
                let s = inline(text)
                return s.isEmpty ? nil : s
            case .list(let ordered, let start, let items):
                var out: [String] = []
                for (i, item) in items.enumerated() {
                    let marker = ordered ? "\(start + i). " : "- "
                    var body = ""
                    for child in item {
                        guard let part = self.block(child) else { continue }
                        body += body.isEmpty ? part : "\n\n" + part
                    }
                    let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
                    out.append(marker + lines.enumerated().map { $0 == 0 ? String($1) : ($1.isEmpty ? "" : String(repeating: " ", count: marker.count) + $1) }.joined(separator: "\n"))
                }
                return out.joined(separator: "\n")
            case .table(let table): return self.table(table)
            case .figure(let resource, let caption, let alt):
                var out = ".. figure:: \(resource)"
                if let alt { out += "\n   :alt: \(alt)" }
                if let caption { out += "\n\n" + Self.indent(inline(caption), 3) }
                return out
            case .code(let language, let text):
                return ".. code-block:: \(language ?? "text")\n\n" + Self.indent(text, 3)
            case .quote(let blocks):
                return Self.indent(blocks.compactMap { self.block($0) }.joined(separator: "\n\n"), 4)
            case .math(let tex, _):
                return ".. math::\n\n" + Self.indent(tex, 3)
            case .footnote: return nil
            case .thematicBreak: return "----"
            case .pageBreak: return ".. raw:: latex\n\n   \\newpage"
            }
        }

        mutating func table(_ table: DocTable) -> String? {
            let (_, rows) = TableGrid.expand(table)
            guard !rows.isEmpty else { return nil }
            if TableGrid.hasSpans(table) { lossNotes.append(LossNote(.tableSimplified, detail: "merged cells")) }
            let headerRows = table.rows.prefix { !$0.isEmpty && $0.allSatisfy(\.isHeader) }.count
            var out = ".. list-table::"
            if let caption = table.caption { out += " " + inline(caption) }
            out += "\n   :header-rows: \(headerRows)\n\n"
            for row in rows {
                for (i, slot) in row.enumerated() {
                    let text = slot.cell.map { cell in cell.blocks.compactMap { self.block($0) }.joined(separator: "\n\n") } ?? ""
                    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    let head = i == 0 ? "   * - " : "     - "
                    out += head + (lines.first.map(String.init) ?? "") + "\n"
                    for line in lines.dropFirst() { out += line.isEmpty ? "\n" : "       " + line + "\n" }
                }
            }
            return String(out.dropLast())
        }

        // MARK: Inlines

        mutating func inline(_ text: DocText) -> String {
            var out = ""
            // Inline markup must start after a space or opening punctuation and end before a space or closing punctuation;
            // an escaped space (`\ `) separates it from a word otherwise.
            var afterMarkup = false
            func put(_ piece: String, markup: Bool) {
                guard let first = piece.first else { return }
                if let last = out.last, markup, !(last.isWhitespace || "([{'\"-/:".contains(last)) { out += "\\ " }
                else if afterMarkup, !(first.isWhitespace || ".,;:!?)]}'\"-/".contains(first)) { out += "\\ " }
                out += piece
                afterMarkup = markup
            }
            for item in text {
                switch item {
                case .text(let t): put(Self.escape(t), markup: false)
                case .emphasis(let c): put(Self.mark("*", inline(c)), markup: true)
                case .strong(let c): put(Self.mark("**", inline(c)), markup: true)
                case .strike(let c): put(inline(c), markup: false); lossNotes.append(LossNote(.formattingSimplified, detail: "strikethrough"))
                case .code(let t): put("``" + t.replacingOccurrences(of: "\n", with: " ") + "``", markup: true)
                case .link(let c, let destination):
                    let label = Inlines.plain(c)
                    put(label == destination ? destination : "`\(Self.escape(label).replacingOccurrences(of: "`", with: "\\`")) <\(destination)>`__", markup: label != destination)
                case .image(let resource, let alt):
                    let name = "img\(substitutions.count + 1)"
                    substitutions.append((name, resource, alt ?? ""))
                    put("|\(name)|", markup: true)
                case .footnoteReference(let id):
                    let n = footnoteNumbers[id] ?? { let n = footnoteNumbers.count + 1; footnoteNumbers[id] = n; return n }()
                    put("[#fn\(n)]_", markup: true)
                case .math(let tex): put(":math:`\(tex.replacingOccurrences(of: "`", with: "\\`"))`", markup: true)
                case .styled(let c, let style):
                    let inner = inline(c)
                    if style.superscript { put(":sup:`\(inner)`", markup: true) } else if style.subscripted { put(":sub:`\(inner)`", markup: true) } else { put(inner, markup: false) }
                case .lineBreak: out += "\n"; afterMarkup = false
                }
            }
            return out
        }

        static func mark(_ marker: String, _ inner: String) -> String {
            let core = inner.trimmed
            return core.isEmpty ? "" : marker + core + marker
        }

        static func escape(_ s: String) -> String {
            var out = ""
            for c in s {
                switch c {
                case "\\", "*", "`", "|": out += "\\" + String(c)
                default: out.append(c)
                }
            }
            // A trailing underscore would read as a hyperlink reference.
            if out.hasSuffix("_") { out.removeLast(); out += "\\_" }
            return out
        }
    }
}
