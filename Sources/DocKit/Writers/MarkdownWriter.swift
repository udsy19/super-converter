import Foundation
import SuperConverterCore

/// `DocModel` → Markdown (formats §3.2 `MarkdownWriter`) in four flavours (O-DOC `markdownFlavour`): GitHub (tables, task
/// lists, strikethrough, footnotes, `$` maths), CommonMark ("strict": raw HTML where CommonMark has no syntax), Pandoc and
/// MultiMarkdown. Metadata goes to YAML front matter.
enum MarkdownWriter {
    static func write(_ model: DocModel, options: DocWriteOptions, to url: URL) throws -> [LossNote] {
        let (text, notes) = render(model, options: options)
        try TextCoding.encode(options.crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text, as: options.encoding).write(to: url, options: .atomic)
        return notes
    }

    static func render(_ model: DocModel, options: DocWriteOptions) -> (String, [LossNote]) {
        var r = Renderer(model: model, options: options)
        return r.run()
    }

    private struct Renderer {
        let model: DocModel
        let options: DocWriteOptions
        var strict: Bool { options.markdownFlavour == "strict" }
        var pandoc: Bool { options.markdownFlavour == "pandoc" }
        var mmd: Bool { options.markdownFlavour == "mmd" }
        var lossNotes: [LossNote] = []
        var footnoteNumbers: [String: Int] = [:]
        var footnoteBodies: [String: [DocBlock]] = [:]
        var embedded: [String: String] = [:]

        init(model: DocModel, options: DocWriteOptions) {
            self.model = model; self.options = options
            for case .footnote(let id, let blocks) in model.blocks { footnoteBodies[id] = blocks }
        }

        mutating func run() -> (String, [LossNote]) {
            var out: [String] = []
            let front = frontMatter()
            if !front.isEmpty { out.append(front) }
            let body = render(model.blocks, tight: false).joined(separator: "\n\n")
            if !body.isEmpty { out.append(body) }
            // Notes (rendering the body numbered them; rendering a note can number more).
            var notes: [String] = []
            var done = 0
            while done < footnoteNumbers.count {
                guard let (id, number) = footnoteNumbers.first(where: { $0.value == done + 1 }) else { break }
                done += 1
                let body = render(footnoteBodies[id] ?? [], tight: false).joined(separator: "\n\n")
                let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
                if strict { notes.append("\(number). " + lines.enumerated().map { $0 == 0 ? String($1) : "   " + $1 }.joined(separator: "\n")) }
                else { notes.append("[^\(number)]: " + lines.enumerated().map { $0 == 0 ? String($1) : ($1.isEmpty ? "" : "    " + $1) }.joined(separator: "\n")) }
            }
            if !notes.isEmpty { out.append(strict ? "---\n\n" + notes.joined(separator: "\n") : notes.joined(separator: "\n\n")) }
            var text = out.joined(separator: "\n\n") + "\n"
            if let width = options.wrap { text = Self.wrapParagraphs(text, width: width) }
            return (text, LossNote.merged(lossNotes))
        }

        func frontMatter() -> String {
            let m = model.metadata
            if strict {
                return m.title.map { "# " + Self.escape($0) } ?? ""
            }
            var lines: [String] = []
            func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ") + "\"" }
            if let t = m.title { lines.append("title: " + quoted(t)) }
            if m.authors.count == 1 { lines.append("author: " + quoted(m.authors[0])) }
            else if m.authors.count > 1 { lines.append("author:"); lines += m.authors.map { "  - " + quoted($0) } }
            if let d = m.date { lines.append("date: " + quoted(DocDates.string(d))) }
            if let s = m.summary { lines.append("abstract: " + quoted(s)) }
            if let l = m.language { lines.append("lang: " + quoted(l)) }
            return lines.isEmpty ? "" : "---\n" + lines.joined(separator: "\n") + "\n---"
        }

        // MARK: Blocks

        mutating func render(_ blocks: [DocBlock], tight: Bool) -> [String] {
            var out: [String] = []
            for block in blocks { if let s = self.block(block) { out.append(s) } }
            return out
        }

        mutating func block(_ block: DocBlock) -> String? {
            switch block {
            case .heading(let level, let text):
                return String(repeating: "#", count: min(max(level, 1), 6)) + " " + inline(text, inCell: false)
            case .paragraph(let text, _):
                let s = inline(text, inCell: false)
                if s.isEmpty { return nil }
                return Self.escapeLineStart(s)
            case .list(let ordered, let start, let items): return list(ordered: ordered, start: start, items: items)
            case .table(let table): return self.table(table)
            case .figure(let resource, let caption, let alt):
                let title = caption.map { " \"" + Inlines.plain($0).replacingOccurrences(of: "\"", with: "\\\"") + "\"" } ?? ""
                return "![\(Self.escape(alt ?? ""))](\(destination(resource))\(title))"
            case .code(let language, let text):
                var fence = "```"
                while text.contains(fence) { fence += "`" }
                return fence + (language ?? "") + "\n" + text + "\n" + fence
            case .quote(let blocks):
                let inner = render(blocks, tight: false).joined(separator: "\n\n")
                return inner.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
            case .math(let tex, _):
                return mmd ? "\\\\[\n\(tex)\n\\\\]" : "$$\n\(tex)\n$$"
            case .footnote: return nil
            case .thematicBreak: return "---"
            case .pageBreak: return pandoc ? "\\newpage" : "<div style=\"page-break-after: always;\"></div>"
            }
        }

        mutating func list(ordered: Bool, start: Int, items: [[DocBlock]]) -> String {
            let loose = items.contains { item in item.filter { if case .list = $0 { false } else { true } }.count > 1 }
            var rendered: [String] = []
            for (index, item) in items.enumerated() {
                var blocks = item
                var task = ""
                if !strict, case .paragraph(var text, let style)? = blocks.first, case .text(let t)? = text.first {
                    if t.hasPrefix("☐ ") { task = "[ ] "; text[0] = .text(String(t.dropFirst(2))); blocks[0] = .paragraph(text, style) }
                    else if t.hasPrefix("☑ ") { task = "[x] "; text[0] = .text(String(t.dropFirst(2))); blocks[0] = .paragraph(text, style) }
                }
                let marker = ordered ? "\(start + index). " : "- "
                // Nested lists follow their parent item directly; other blocks are separated by a blank line.
                var body = ""
                for child in blocks {
                    guard let part = self.block(child) else { continue }
                    if body.isEmpty { body = part }
                    else if case .list = child { body += "\n" + part }
                    else { body += "\n\n" + part }
                }
                let lines = (task + body).split(separator: "\n", omittingEmptySubsequences: false)
                let pad = String(repeating: " ", count: marker.count)
                rendered.append(marker + lines.enumerated().map { $0 == 0 ? String($1) : ($1.isEmpty ? "" : pad + $1) }.joined(separator: "\n"))
            }
            return rendered.joined(separator: loose ? "\n\n" : "\n")
        }

        // MARK: Tables

        mutating func table(_ table: DocTable) -> String? {
            if strict { return htmlTable(table) }
            let (columns, rows) = TableGrid.expand(table)
            if TableGrid.hasSpans(table) { lossNotes.append(LossNote(.tableSimplified, detail: "merged cells")) }
            guard !rows.isEmpty else { return nil }
            func text(_ slot: TableGrid.Slot) -> String {
                guard let cell = slot.cell else { return "" }
                let parts = cell.blocks.map { b -> String in
                    if case .paragraph(let t, _) = b { return inline(t, inCell: true) }
                    return Self.escape(Self.plainText(b)).replacingOccurrences(of: "\n", with: " ")
                }.filter { !$0.isEmpty }
                return parts.joined(separator: "<br>").replacingOccurrences(of: "|", with: "\\|")
            }
            var lines: [String] = []
            func row(_ slots: [TableGrid.Slot]) -> String { "| " + slots.map(text).joined(separator: " | ") + " |" }
            lines.append(row(rows[0]))
            let alignments = (0..<columns).map { $0 < table.alignments.count ? table.alignments[$0] : .start }
            lines.append("| " + alignments.map { a -> String in switch a { case .centre: ":---:"; case .end: "---:"; default: "---" } }.joined(separator: " | ") + " |")
            for r in rows.dropFirst() { lines.append(row(r)) }
            var out = lines.joined(separator: "\n")
            // Pandoc's table caption line: GitHub shows it as a plain line, and the reader reads it back.
            if let caption = table.caption { out += "\n\nTable: " + inline(caption, inCell: false) }
            return out
        }

        mutating func htmlTable(_ table: DocTable) -> String {
            var html = HTMLWriter.render(DocModel(blocks: [.table(table)], resources: model.resources), embedImages: true, filesFolder: "").html
            if let start = html.range(of: "<table>"), let end = html.range(of: "</table>") { html = String(html[start.lowerBound..<end.upperBound]) }
            return html
        }

        static func plainText(_ block: DocBlock) -> String {
            switch block {
            case .paragraph(let t, _), .heading(_, let t): return Inlines.plain(t)
            case .code(_, let t): return t
            case .list(_, _, let items): return items.map { $0.map(plainText).joined(separator: " ") }.joined(separator: "; ")
            case .quote(let b): return b.map(plainText).joined(separator: " ")
            case .math(let tex, _): return tex
            default: return ""
            }
        }

        // MARK: Inlines

        mutating func inline(_ text: DocText, inCell: Bool) -> String {
            var out = ""
            for item in text {
                switch item {
                case .text(let t): out += Self.escape(t, math: !strict)
                case .emphasis(let c): out += wrap("*", inline(c, inCell: inCell))
                case .strong(let c): out += wrap("**", inline(c, inCell: inCell))
                case .strike(let c):
                    if strict { out += "<del>" + inline(c, inCell: inCell) + "</del>" } else { out += wrap("~~", inline(c, inCell: inCell)) }
                case .code(let t):
                    var fence = "`"
                    while t.contains(fence) { fence += "`" }
                    let pad = t.hasPrefix("`") || t.hasSuffix("`") || (t.hasPrefix(" ") && t.hasSuffix(" ") && !t.trimmed.isEmpty) ? " " : ""
                    out += fence + pad + t + pad + fence
                case .link(let c, let destinationText):
                    out += "[" + inline(c, inCell: inCell) + "](" + Self.linkDestination(destinationText) + ")"
                case .image(let resource, let alt): out += "![\(Self.escape(alt ?? ""))](\(destination(resource)))"
                case .footnoteReference(let id):
                    let number = footnoteNumber(id)
                    out += strict ? "<sup>\(number)</sup>" : "[^\(number)]"
                case .math(let tex): out += mmd ? "\\\\(\(tex)\\\\)" : "$\(tex)$"
                case .styled(let c, let style):
                    var inner = inline(c, inCell: inCell)
                    if style.underline { inner = "<u>" + inner + "</u>" }
                    if style.superscript { inner = "<sup>" + inner + "</sup>" } else if style.subscripted { inner = "<sub>" + inner + "</sub>" }
                    if style.fontName != nil || style.fontSize != nil || style.colour != nil { lossNotes.append(LossNote(.formattingSimplified)) }
                    out += inner
                case .lineBreak: out += inCell ? "<br>" : "\\\n"
                }
            }
            return out
        }

        mutating func footnoteNumber(_ id: String) -> Int {
            if let n = footnoteNumbers[id] { return n }
            let n = footnoteNumbers.count + 1
            footnoteNumbers[id] = n
            return n
        }

        func wrap(_ marker: String, _ inner: String) -> String {
            guard !inner.trimmed.isEmpty else { return inner }
            let leading = inner.prefix { $0 == " " }
            let trailing = inner.reversed().prefix { $0 == " " }
            return String(leading) + marker + inner.trimmed + marker + String(trailing)
        }

        mutating func destination(_ resource: String) -> String {
            guard let data = model.resources[resource] else { return Self.linkDestination(resource) }
            if let known = embedded[resource] { return known }
            let mime = ImageSniff.commonType(data).map(ImageSniff.mime) ?? ImageSniff.mimeForFileName(resource)
            let uri = "data:\(mime);base64,\(data.base64EncodedString())"
            embedded[resource] = uri
            return uri
        }

        static func linkDestination(_ d: String) -> String {
            if d.contains(" ") || d.contains("(") || d.contains(")") || d.isEmpty { return "<" + d.replacingOccurrences(of: ">", with: "%3E") + ">" }
            return d
        }

        // MARK: Escaping

        static func escape(_ s: String, math: Bool = false) -> String {
            var out = ""
            let chars = Array(s)
            for (i, c) in chars.enumerated() {
                switch c {
                case "\\", "`", "*", "_", "[", "]", "<": out += "\\" + String(c)
                case "~": out += "\\~"
                case "$": out += math ? "\\$" : "$"
                case "&": if i + 1 < chars.count, chars[i + 1].isLetter || chars[i + 1] == "#" { out += "\\&" } else { out.append(c) }
                case "|": out += "\\|"
                default: out.append(c)
                }
            }
            return out
        }

        /// A paragraph that begins like another block gets that character escaped.
        static func escapeLineStart(_ s: String) -> String {
            var out = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for i in out.indices {
                let line = out[i]
                if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("+") || line.hasPrefix("=") { out[i] = "\\" + line }
                else if (line.hasPrefix("-") || line.hasPrefix("*")) && (line.dropFirst().first == " " || line.dropFirst().first == nil || line.allSatisfy { $0 == "-" }) { out[i] = "\\" + line }
                else if let dot = line.firstIndex(where: { !$0.isNumber }), dot != line.startIndex, line[dot] == "." || line[dot] == ")", line[line.index(after: dot)...].first == " " || line[line.index(after: dot)...].isEmpty {
                    out[i] = String(line[..<dot]) + "\\" + String(line[dot...])
                }
            }
            return out.joined(separator: "\n")
        }

        static func wrapParagraphs(_ text: String, width: Int) -> String {
            var out: [String] = []
            var inFence = false
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("```") { inFence.toggle() }
                let special = line.hasPrefix("|") || line.hasPrefix("#") || line.hasPrefix("    ") || line.hasPrefix("[^") || line.hasPrefix("- ") || line.hasPrefix(">") || line.hasPrefix("$") || line.hasPrefix("---") || line.hasPrefix("<") || line.first?.isNumber == true
                out.append(inFence || special || line.count <= width || line.hasSuffix("\\") ? String(line) : TextWrap.wrap(String(line), width: width))
            }
            return out.joined(separator: "\n")
        }
    }
}
