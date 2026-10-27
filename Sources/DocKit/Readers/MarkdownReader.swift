import Foundation
import SuperConverterCore

// Markdown → `DocModel` (formats §3.2 `MarkdownReader`): an own CommonMark + GFM parser rather than swift-markdown, because the
// package build then stays offline (a new dependency needs a network fetch and an exact pin in Package.swift), swift-markdown
// has no footnotes or math, and the reader needs `$…$` maths, pandoc inline notes, GFM task lists and front matter anyway.
// Super PDF's MarkdownImporter (commit 058469b) writes attributed text for PDF output, so nothing was copied from it.

enum MarkdownReader {
    static func read(_ url: URL, options: DocReadOptions = DocReadOptions()) throws -> DocReadResult {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let (text, _) = TextCoding.decode(data, hint: options.encoding)
        return parse(text, baseURL: url.deletingLastPathComponent(), options: options)
    }

    static func parse(_ text: String, baseURL: URL? = nil, options: DocReadOptions = DocReadOptions()) -> DocReadResult {
        var parser = BlockParser(text.normalisedNewlines, baseURL: baseURL, strict: options.markdownFlavour == "strict")
        return parser.run()
    }

    // MARK: - Blocks

    private struct BlockParser {
        var lines: [Substring]
        let baseURL: URL?
        let strict: Bool
        var metadata = DocMetadata()
        var references: [String: (destination: String, title: String?)] = [:]
        var inline: InlineParser
        var lossNotes: [LossNote] = []

        init(_ text: String, baseURL: URL?, strict: Bool) {
            lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            self.baseURL = baseURL
            self.strict = strict
            inline = InlineParser(strict: strict, baseURL: baseURL)
        }

        mutating func run() -> DocReadResult {
            let strippedLines = frontMatter(lines)
            let body = collectReferences(strippedLines)
            inline.references = references
            var blocks = parseBlocks(body[...])
            blocks += inline.footnoteBlocks
            return DocReadResult(model: DocModel(metadata: metadata, blocks: blocks, resources: inline.resources), lossNotes: lossNotes)
        }

        // MARK: Front matter and references

        mutating func frontMatter(_ lines: [Substring]) -> [Substring] {
            guard !strict, lines.first?.trimmed == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmed == "---" || $0.trimmed == "..." }) else { return lines }
            let yaml = lines[1..<end]
            // Only treat it as metadata if it looks like key: value pairs.
            guard yaml.contains(where: { $0.contains(":") }) else { return lines }
            var key: String?
            var list: [String] = []
            func store(_ key: String, _ value: String) {
                let v = value.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                switch key.lowercased() {
                case "title": metadata.title = v
                case "author", "authors": metadata.authors = (list.isEmpty ? v.split(separator: ",").map { $0.trimmed } : list).filter { !$0.isEmpty }
                case "date": metadata.date = ISO8601DateFormatter().date(from: v) ?? DOCXReader.plainDate(v)
                case "abstract", "description", "summary": metadata.summary = v
                case "lang", "language": metadata.language = v
                default: break
                }
            }
            for line in yaml {
                if line.hasPrefix("  - ") || line.hasPrefix("- ") { list.append(line.drop(while: { $0 == " " }).dropFirst(2).trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))); continue }
                if let k = key, !list.isEmpty { store(k, ""); list = [] }
                key = nil
                guard let colon = line.firstIndex(of: ":") else { continue }
                let k = String(line[..<colon]).trimmed
                let v = String(line[line.index(after: colon)...])
                if v.trimmed.isEmpty { key = k } else { store(k, v) }
            }
            if let k = key, !list.isEmpty { store(k, "") }
            return Array(lines[(end + 1)...])
        }

        mutating func collectReferences(_ lines: [Substring]) -> [Substring] {
            var out: [Substring] = []
            var fence: String?
            for line in lines {
                let t = line.drop(while: { $0 == " " })
                if let f = fence { out.append(line); if t.hasPrefix(f) && t.allSatisfy({ $0 == f.first! || $0 == " " }) { fence = nil }; continue }
                if t.hasPrefix("```") || t.hasPrefix("~~~") { fence = String(t.prefix(while: { $0 == t.first! })); out.append(line); continue }
                if line.count - t.count <= 3, t.hasPrefix("["), !t.hasPrefix("[^"), let close = t.range(of: "]:") {
                    let label = String(t[t.index(after: t.startIndex)..<close.lowerBound])
                    var rest = t[close.upperBound...].trimmed
                    if !label.isEmpty, !rest.isEmpty {
                        var destination = rest
                        var title: String?
                        if rest.hasPrefix("<"), let end = rest.firstIndex(of: ">") {
                            destination = String(rest[rest.index(after: rest.startIndex)..<end])
                            rest = String(rest[rest.index(after: end)...]).trimmed
                        } else if let space = rest.firstIndex(of: " ") {
                            destination = String(rest[..<space])
                            rest = String(rest[space...]).trimmed
                        } else { rest = "" }
                        if let q = rest.first, "\"'(".contains(q), rest.count >= 2 { title = String(rest.dropFirst().dropLast()) }
                        references[label.lowercased()] = (destination, title)
                        continue
                    }
                }
                out.append(line)
            }
            return out
        }

        // MARK: Block structure

        static func indent(_ line: Substring) -> Int {
            var n = 0
            for ch in line { if ch == " " { n += 1 } else if ch == "\t" { n += 4 - n % 4 } else { break } }
            return n
        }

        static func strip(_ line: Substring, _ columns: Int) -> Substring {
            var n = 0
            var index = line.startIndex
            while index < line.endIndex, n < columns {
                if line[index] == " " { n += 1 } else if line[index] == "\t" { n += 4 - n % 4 } else { break }
                index = line.index(after: index)
            }
            return line[index...]
        }

        static func isBlank(_ line: Substring) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

        static func isThematicBreak(_ line: Substring) -> Bool {
            guard indent(line) < 4 else { return false }
            let t = line.filter { $0 != " " && $0 != "\t" }
            guard let c = t.first, "-*_".contains(c), t.count >= 3 else { return false }
            return t.allSatisfy { $0 == c }
        }

        static func atxHeading(_ line: Substring) -> (Int, Substring)? {
            guard indent(line) < 4 else { return nil }
            let t = line.drop(while: { $0 == " " })
            let level = t.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(level) else { return nil }
            let rest = t.dropFirst(level)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            var content = rest.trimmed
            // Closing sequence.
            if let lastSpace = content.lastIndex(of: " "), content[content.index(after: lastSpace)...].allSatisfy({ $0 == "#" }) { content = String(content[..<lastSpace]).trimmed }
            else if content.allSatisfy({ $0 == "#" }) { content = "" }
            return (level, Substring(content))
        }

        static func fence(_ line: Substring) -> (marker: Character, count: Int, info: String, indent: Int)? {
            let ind = indent(line)
            guard ind < 4 else { return nil }
            let t = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let c = t.first, c == "`" || c == "~" else { return nil }
            let count = t.prefix(while: { $0 == c }).count
            guard count >= 3 else { return nil }
            let info = t.dropFirst(count).trimmed
            if c == "`", info.contains("`") { return nil }
            return (c, count, info, ind)
        }

        struct ListMarker {
            var ordered: Bool
            var start: Int
            var delimiter: Character
            var contentIndent: Int
            var markerIndent: Int
            var blankAfter: Bool
        }

        static func listMarker(_ line: Substring) -> ListMarker? {
            let ind = indent(line)
            guard ind < 4 else { return nil }
            let t = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let c = t.first else { return nil }
            var width = 0
            var ordered = false
            var start = 1
            var delimiter = c
            if "-+*".contains(c) {
                width = 1
            } else if c.isNumber {
                let digits = t.prefix(while: { $0.isNumber && $0.isASCII })
                guard digits.count <= 9, digits.count < t.count, let d = t.dropFirst(digits.count).first, d == "." || d == ")" else { return nil }
                width = digits.count + 1
                ordered = true
                start = Int(digits) ?? 1
                delimiter = d
            } else { return nil }
            let after = t.dropFirst(width)
            guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
            if isThematicBreak(line), !ordered { return nil }
            let spaces = after.prefix(while: { $0 == " " }).count
            let blank = after.allSatisfy { $0 == " " || $0 == "\t" }
            let content = (blank || spaces > 4) ? 1 : max(spaces, 1)
            return ListMarker(ordered: ordered, start: start, delimiter: delimiter, contentIndent: ind + width + content, markerIndent: ind, blankAfter: blank)
        }

        static let htmlBlockStart = try! NSRegularExpression(pattern: "^ {0,3}<(/?)(address|article|aside|blockquote|body|center|details|dialog|div|dl|dt|dd|fieldset|figcaption|figure|footer|form|h[1-6]|header|hr|html|iframe|li|main|nav|ol|p|pre|section|summary|table|tbody|td|th|thead|tr|ul)(\\s|/?>|$)|^ {0,3}<!--", options: [.caseInsensitive])

        static func isHTMLBlockStart(_ line: Substring) -> Bool {
            htmlBlockStart.firstMatch(in: String(line), range: NSRange(location: 0, length: line.utf16.count)) != nil
        }

        static func tableCells(_ line: Substring) -> [String]? {
            let t = line.trimmed
            guard t.contains("|") else { return nil }
            var cells: [String] = []
            var current = ""
            var escaped = false
            var inCode = false
            for ch in t {
                if escaped { current.append(ch); escaped = false; continue }
                if ch == "\\" { current.append(ch); escaped = true; continue }
                if ch == "`" { inCode.toggle() }
                if ch == "|", !inCode { cells.append(current); current = ""; continue }
                current.append(ch)
            }
            cells.append(current)
            if t.hasPrefix("|") { cells.removeFirst() }
            if t.hasSuffix("|"), !t.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
            return cells.map { $0.trimmed.replacingOccurrences(of: "\\|", with: "|") }
        }

        static func tableAlignments(_ line: Substring) -> [DocParagraphStyle.Alignment]? {
            guard let cells = tableCells(line), !cells.isEmpty else { return nil }
            var out: [DocParagraphStyle.Alignment] = []
            for cell in cells {
                guard !cell.isEmpty, cell.allSatisfy({ $0 == "-" || $0 == ":" }), cell.contains("-") else { return nil }
                let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
                out.append(left && right ? .centre : right ? .end : .start)
            }
            return out
        }

        /// Quotes and lists nest by recursion; past this depth the rest is text, so hostile input cannot exhaust the stack.
        var depth = 0
        static let maxDepth = 60

        mutating func parseBlocks(_ input: ArraySlice<Substring>) -> [DocBlock] {
            depth += 1
            defer { depth -= 1 }
            if depth > Self.maxDepth { return [.paragraph([.text(input.map { String($0) }.joined(separator: " ").trimmed)], DocParagraphStyle())] }
            var blocks: [DocBlock] = []
            let lines = Array(input)
            var i = 0
            while i < lines.count {
                let line = lines[i]
                if Self.isBlank(line) { i += 1; continue }

                // Fenced code.
                if let f = Self.fence(line) {
                    var body: [String] = []
                    i += 1
                    while i < lines.count {
                        if let close = Self.fence(lines[i]), close.marker == f.marker, close.count >= f.count, close.info.isEmpty { i += 1; break }
                        body.append(String(Self.strip(lines[i], f.indent)))
                        i += 1
                    }
                    let language = f.info.split(separator: " ").first.map(String.init).map { $0.hasPrefix("{") ? $0.trimmingCharacters(in: CharacterSet(charactersIn: "{}.")) : $0 }
                    blocks.append(.code(language: language?.isEmpty == true ? nil : language, text: body.joined(separator: "\n")))
                    continue
                }
                // Display math.
                let trimmedLine = line.trimmed
                if !strict, trimmedLine.hasPrefix("$$") {
                    var tex = String(trimmedLine.dropFirst(2))
                    if tex.hasSuffix("$$"), tex.count >= 2 {
                        tex = String(tex.dropLast(2))
                        i += 1
                    } else {
                        var parts = [tex]
                        i += 1
                        while i < lines.count {
                            let l = lines[i].trimmed
                            i += 1
                            if l.hasSuffix("$$") { parts.append(String(l.dropLast(2))); break }
                            parts.append(String(l))
                        }
                        tex = parts.joined(separator: "\n")
                    }
                    blocks.append(.math(tex: tex.trimmed, display: true))
                    continue
                }
                if let (level, text) = Self.atxHeading(line) {
                    blocks.append(.heading(level: level, inline.parse(String(text))))
                    i += 1
                    continue
                }
                if Self.isThematicBreak(line) { blocks.append(.thematicBreak); i += 1; continue }
                // Block quote.
                if Self.indent(line) < 4, line.drop(while: { $0 == " " }).hasPrefix(">") {
                    var inner: [Substring] = []
                    var lastWasParagraph = false
                    while i < lines.count {
                        let l = lines[i]
                        let t = l.drop(while: { $0 == " " })
                        if Self.indent(l) < 4, t.hasPrefix(">") {
                            var rest = t.dropFirst()
                            if rest.first == " " { rest = rest.dropFirst() }
                            inner.append(rest)
                            lastWasParagraph = !Self.isBlank(rest)
                        } else if lastWasParagraph, !Self.isBlank(l), Self.atxHeading(l) == nil, Self.fence(l) == nil, !Self.isThematicBreak(l), Self.listMarker(l) == nil {
                            inner.append(l)   // lazy continuation
                        } else { break }
                        i += 1
                    }
                    blocks.append(.quote(parseBlocks(inner[...])))
                    continue
                }
                // Lists.
                if let marker = Self.listMarker(line) {
                    let (list, next) = parseList(lines, from: i, marker: marker)
                    blocks.append(list)
                    i = next
                    continue
                }
                // Footnote definition.
                if !strict, line.hasPrefix("[^"), let close = line.range(of: "]:") {
                    let id = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
                    var body: [Substring] = [line[close.upperBound...].drop(while: { $0 == " " })]
                    i += 1
                    while i < lines.count {
                        if Self.isBlank(lines[i]) {
                            // Blank lines belong to the note while the next non-blank line is indented.
                            var j = i
                            while j < lines.count, Self.isBlank(lines[j]) { j += 1 }
                            if j < lines.count, Self.indent(lines[j]) >= 4 { body += lines[i..<j].map { _ in Substring("") }; i = j; continue }
                            break
                        }
                        if Self.indent(lines[i]) >= 4 { body.append(Self.strip(lines[i], 4)) }
                        else if Self.listMarker(lines[i]) == nil, lines[i].hasPrefix("[^") == false, Self.atxHeading(lines[i]) == nil { body.append(lines[i]) }
                        else { break }
                        i += 1
                    }
                    let content = parseBlocks(body[...])
                    inline.setFootnote(id, content)
                    continue
                }
                // Indented code.
                if Self.indent(line) >= 4 {
                    var body: [String] = []
                    while i < lines.count, Self.indent(lines[i]) >= 4 || Self.isBlank(lines[i]) {
                        body.append(String(Self.strip(lines[i], 4)))
                        i += 1
                    }
                    while body.last?.isEmpty == true { body.removeLast() }
                    blocks.append(.code(language: nil, text: body.joined(separator: "\n")))
                    continue
                }
                // HTML block.
                if Self.isHTMLBlockStart(line) {
                    var html: [Substring] = []
                    let isComment = line.trimmed.hasPrefix("<!--")
                    while i < lines.count, !Self.isBlank(lines[i]) || (isComment && !(html.last?.contains("-->") ?? false)) {
                        html.append(lines[i]); i += 1
                        if isComment, html.last?.contains("-->") == true { break }
                    }
                    let source = html.joined(separator: "\n")
                    if source.trimmed.hasPrefix("<!--") { continue }
                    if source.contains("page-break-after") || source.contains("page-break-before") { blocks.append(.pageBreak); continue }
                    blocks += HTMLReader.fragment(source, baseURL: baseURL, resources: &inline.resources)
                    continue
                }
                if line.trimmed == "\\newpage" || line.trimmed == "\\pagebreak" { blocks.append(.pageBreak); i += 1; continue }
                // Table.
                if !strict, i + 1 < lines.count, let header = Self.tableCells(line), let alignments = Self.tableAlignments(lines[i + 1]), header.count == alignments.count {
                    var rows: [[DocTable.Cell]] = [header.map { cell(String($0), header: true) }]
                    i += 2
                    while i < lines.count, !Self.isBlank(lines[i]), let cells = Self.tableCells(lines[i]), Self.fence(lines[i]) == nil {
                        var padded = cells
                        while padded.count < header.count { padded.append("") }
                        rows.append(padded.prefix(header.count).map { cell($0, header: false) })
                        i += 1
                    }
                    var caption: DocText?
                    var j = i
                    while j < lines.count, Self.isBlank(lines[j]) { j += 1 }
                    if j < lines.count, lines[j].hasPrefix("Table:") {
                        caption = inline.parse(String(lines[j].dropFirst(6)).trimmed)
                        i = j + 1
                    }
                    blocks.append(.table(DocTable(rows: rows, caption: caption, alignments: alignments)))
                    continue
                }
                // Paragraph (and setext headings).
                var paragraph: [Substring] = []
                var heading: Int?
                while i < lines.count, !Self.isBlank(lines[i]) {
                    let l = lines[i]
                    if !paragraph.isEmpty {
                        if Self.indent(l) < 4, l.trimmed.allSatisfy({ $0 == "=" }) { heading = 1; i += 1; break }
                        if Self.indent(l) < 4, l.trimmed.allSatisfy({ $0 == "-" }), !l.trimmed.isEmpty { heading = 2; i += 1; break }
                        if Self.atxHeading(l) != nil || Self.fence(l) != nil || Self.isThematicBreak(l) || (l.drop(while: { $0 == " " }).hasPrefix(">") && Self.indent(l) < 4) { break }
                        if let m = Self.listMarker(l), !m.blankAfter, !m.ordered || m.start == 1 { break }
                        if Self.isHTMLBlockStart(l) { break }
                        if !strict, i + 1 < lines.count, Self.tableCells(l) != nil, Self.tableAlignments(lines[i + 1]) != nil { break }
                    }
                    paragraph.append(l)
                    i += 1
                }
                // A line ending in two spaces or a backslash is a hard break (marked with NUL for the inline parser).
                let joined = paragraph.enumerated().map { index, line -> String in
                    let content = line.drop(while: { $0 == " " || $0 == "\t" })
                    guard index < paragraph.count - 1 else { return content.trimmed }
                    if content.hasSuffix("\\") { return String(content.dropLast()).trimmed + "\u{0}" }
                    if content.hasSuffix("  ") { return content.trimmed + "\u{0}" }
                    return content.trimmed
                }.joined(separator: "\n")
                if let level = heading { blocks.append(.heading(level: level, inline.parse(joined.trimmed))) }
                else { blocks.append(paragraphBlock(joined)) }
            }
            return blocks
        }

        mutating func paragraphBlock(_ source: String) -> DocBlock {
            let text = inline.parse(source)
            // A picture alone in its paragraph is a figure; its title is the caption.
            if text.count == 1, case .image(let resource, let alt) = text[0] {
                return .figure(resource: resource, caption: inline.lastImageTitle.map { [.text($0)] }, altText: alt)
            }
            if text.count == 1, case .link(let inner, _) = text[0], inner.count == 1, case .image(let resource, let alt) = inner[0] {
                return .figure(resource: resource, caption: nil, altText: alt)
            }
            // Pandoc/GitHub inline `$$…$$` on its own line handled above; `\[ … \]` here.
            if !strict, let only = text.first, text.count == 1, case .math(let tex) = only, source.hasPrefix("\\[") { return .math(tex: tex, display: true) }
            return .paragraph(text, DocParagraphStyle())
        }

        mutating func cell(_ text: String, header: Bool) -> DocTable.Cell {
            DocTable.Cell(blocks: [.paragraph(inline.parse(text.replacingOccurrences(of: "<br>", with: "\u{0}").replacingOccurrences(of: "<br/>", with: "\u{0}")), DocParagraphStyle())], isHeader: header)
        }

        // MARK: Lists

        mutating func parseList(_ lines: [Substring], from start: Int, marker first: ListMarker) -> (DocBlock, Int) {
            var items: [[DocBlock]] = []
            var i = start
            while i < lines.count, let m = Self.listMarker(lines[i]), m.ordered == first.ordered, m.delimiter == first.delimiter, m.markerIndent < first.contentIndent {
                var body: [Substring] = []
                // The marker and the spaces after it (tabs count as one column here; they are rare after a marker).
                let firstLine = lines[i].dropFirst(min(m.contentIndent, lines[i].count))
                body.append(m.blankAfter ? Substring("") : firstLine)
                i += 1
                var sawBlank = false
                while i < lines.count {
                    let l = lines[i]
                    if Self.isBlank(l) { body.append(""); sawBlank = true; i += 1; continue }
                    if Self.indent(l) >= m.contentIndent { body.append(Self.strip(l, m.contentIndent)); sawBlank = false; i += 1; continue }
                    if !sawBlank, Self.listMarker(l) == nil, Self.atxHeading(l) == nil, Self.fence(l) == nil, !Self.isThematicBreak(l), !l.drop(while: { $0 == " " }).hasPrefix(">"), !(body.last.map(Self.isBlank) ?? true) {
                        body.append(l); i += 1; continue   // lazy continuation
                    }
                    break
                }
                while body.last.map(Self.isBlank) == true { body.removeLast(); }
                var blocks = parseBlocks(body[...])
                // Task list marker.
                if !strict, case .paragraph(var text, let style)? = blocks.first, case .text(let t)? = text.first {
                    if t.hasPrefix("[ ] ") { text[0] = .text("☐ " + t.dropFirst(4)); blocks[0] = .paragraph(text, style) }
                    else if t.hasPrefix("[x] ") || t.hasPrefix("[X] ") { text[0] = .text("☑ " + t.dropFirst(4)); blocks[0] = .paragraph(text, style) }
                }
                items.append(blocks)
                // Blank lines between items.
                while i < lines.count, Self.isBlank(lines[i]), i + 1 < lines.count, Self.listMarker(lines[i + 1]) != nil { i += 1 }
                if i < lines.count, Self.isBlank(lines[i]) { break }
            }
            return (.list(ordered: first.ordered, start: first.ordered ? first.start : 1, items: items), i)
        }
    }

    // MARK: - Inlines

    struct InlineParser {
        let strict: Bool
        let baseURL: URL?
        var references: [String: (destination: String, title: String?)] = [:]
        var resources: [String: Data] = [:]
        var footnoteBlocks: [DocBlock] = []
        var footnoteBodies: [String: [DocBlock]] = [:]
        var lastImageTitle: String?
        var inlineNoteCount = 0

        init(strict: Bool, baseURL: URL?) { self.strict = strict; self.baseURL = baseURL }

        mutating func setFootnote(_ id: String, _ blocks: [DocBlock]) {
            footnoteBodies[id] = blocks
            footnoteBlocks.append(.footnote(id: id, blocks))
        }

        private enum Token {
            case node(FlatItem)
            case delim(Character, Int, canOpen: Bool, canClose: Bool)
        }

        /// Parses inline Markdown into a `DocText`. "\u{0}" in the source marks a hard line break.
        mutating func parse(_ source: String) -> DocText {
            Inlines.build(flat(source))
        }

        mutating func flat(_ source: String) -> [FlatItem] {
            let chars = Array(source)
            var tokens: [Token] = []
            var text = ""
            func flushText() { if !text.isEmpty { tokens.append(.node(.run(text, RunFormat()))); text = "" } }
            var i = 0
            func isPunct(_ c: Character?) -> Bool { c.map { $0.isPunctuation || $0.isSymbol } ?? false }
            func isSpace(_ c: Character?) -> Bool { c.map { $0.isWhitespace } ?? true }

            while i < chars.count {
                let c = chars[i]
                switch c {
                case "\u{0}": flushText(); tokens.append(.node(.lineBreak)); i += (i + 1 < chars.count && chars[i + 1] == "\n") ? 2 : 1
                case "\n":
                    // Soft break: a space (trailing spaces were already turned into hard breaks).
                    text.append(" "); i += 1
                case "\\":
                    if i + 1 < chars.count, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                        if !strict, chars[i + 1] == "(" , let end = findClosing(chars, from: i + 2, "\\)") {
                            flushText(); tokens.append(.node(.math(tex: String(chars[(i + 2)..<end]).trimmed))); i = end + 2; continue
                        }
                        text.append(chars[i + 1]); i += 2
                    } else { text.append(c); i += 1 }
                case "`":
                    let run = chars[i...].prefix(while: { $0 == "`" }).count
                    var j = i + run
                    var found: Int?
                    while j < chars.count {
                        if chars[j] == "`" {
                            let r = chars[j...].prefix(while: { $0 == "`" }).count
                            if r == run { found = j; break }
                            j += r
                        } else { j += 1 }
                    }
                    if let end = found {
                        flushText()
                        var code = String(chars[(i + run)..<end]).replacingOccurrences(of: "\n", with: " ")
                        if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), !code.allSatisfy({ $0 == " " }) { code = String(code.dropFirst().dropLast()) }
                        var f = RunFormat(); f.code = true
                        tokens.append(.node(.run(code, f)))
                        i = end + run
                    } else { text += String(repeating: "`", count: run); i += run }
                case "*", "_", "~":
                    var run = chars[i...].prefix(while: { $0 == c }).count
                    if c == "~" {
                        guard run == 2, !strict else { text += String(repeating: "~", count: run); i += run; continue }
                    }
                    let before: Character? = i > 0 ? chars[i - 1] : nil
                    let after: Character? = i + run < chars.count ? chars[i + run] : nil
                    let leftFlanking = !isSpace(after) && (!isPunct(after) || isSpace(before) || isPunct(before))
                    let rightFlanking = !isSpace(before) && (!isPunct(before) || isSpace(after) || isPunct(after))
                    let canOpen: Bool, canClose: Bool
                    if c == "_" {
                        canOpen = leftFlanking && (!rightFlanking || isPunct(before))
                        canClose = rightFlanking && (!leftFlanking || isPunct(after))
                    } else { canOpen = leftFlanking; canClose = rightFlanking }
                    flushText()
                    tokens.append(.delim(c, run, canOpen: canOpen, canClose: canClose))
                    i += run
                    run = 0
                case "[", "!":
                    if c == "!" { guard i + 1 < chars.count, chars[i + 1] == "[" else { text.append(c); i += 1; continue } }
                    let isImage = c == "!"
                    let open = isImage ? i + 1 : i
                    // Footnote reference.
                    if !isImage, !strict, open + 1 < chars.count, chars[open + 1] == "^", let close = chars[open...].firstIndex(of: "]") {
                        let id = String(chars[(open + 2)..<close])
                        if !id.isEmpty, !id.contains(" ") { flushText(); tokens.append(.node(.footnote(id: id))); i = close + 1; continue }
                    }
                    if let close = matchingBracket(chars, open), let (destination, title, end) = linkTail(chars, after: close, label: String(chars[(open + 1)..<close])) {
                        flushText()
                        let inner = String(chars[(open + 1)..<close])
                        if isImage {
                            let alt = Inlines.plain(Inlines.build(flat(inner)))
                            lastImageTitle = title
                            tokens.append(.node(.image(resource: resource(destination), alt: alt.isEmpty ? nil : alt, link: nil)))
                        } else {
                            var innerItems = flat(inner)
                            for k in innerItems.indices {
                                if case .run(let t, var f) = innerItems[k] { f.link = destination; innerItems[k] = .run(t, f) }
                                if case .image(let r, let a, _) = innerItems[k] { innerItems[k] = .image(resource: r, alt: a, link: destination) }
                            }
                            for item in innerItems { tokens.append(.node(item)) }
                        }
                        i = end
                    } else { text.append(c); i += 1 }
                case "<":
                    if let end = chars[i...].firstIndex(of: ">") {
                        let inside = String(chars[(i + 1)..<end])
                        if inside.range(of: "^[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\\s<>]*$", options: .regularExpression) != nil || inside.range(of: "^[^\\s@<>]+@[^\\s@<>]+\\.[^\\s@<>]+$", options: .regularExpression) != nil {
                            flushText()
                            var f = RunFormat(); f.link = inside.contains("@") && !inside.contains(":") ? "mailto:" + inside : inside
                            tokens.append(.node(.run(inside, f)))
                            i = end + 1
                            continue
                        }
                        if let (items, next) = htmlInline(chars, at: i, tagEnd: end) {
                            flushText()
                            for item in items { tokens.append(.node(item)) }
                            i = next
                            continue
                        }
                        // Other tags (and comments) vanish; their text stays.
                        if inside.hasPrefix("/") || inside.first?.isLetter == true {
                            i = end + 1
                            continue
                        }
                        if inside.hasPrefix("!--"), let close = findClosing(chars, from: i + 1, "-->") { i = close + 3; continue }
                    }
                    text.append(c); i += 1
                case "&":
                    if let semicolon = chars[i...].prefix(12).firstIndex(of: ";"), let decoded = Self.entity(String(chars[(i + 1)..<semicolon])) {
                        text += decoded; i = semicolon + 1
                    } else { text.append(c); i += 1 }
                case "$":
                    guard !strict else { text.append(c); i += 1; continue }
                    if i + 1 < chars.count, chars[i + 1] == "$", let end = findClosing(chars, from: i + 2, "$$") {
                        flushText(); tokens.append(.node(.math(tex: String(chars[(i + 2)..<end]).trimmed))); i = end + 2; continue
                    }
                    // Pandoc rule: the opening $ has a non-space after it, the closing one a non-space before it and no digit after.
                    if i + 1 < chars.count, !chars[i + 1].isWhitespace, let end = chars[(i + 1)...].firstIndex(of: "$"), end > i + 1,
                       !chars[end - 1].isWhitespace, !(end + 1 < chars.count && chars[end + 1].isNumber), chars[(i + 1)..<end].contains("\n") == false {
                        flushText(); tokens.append(.node(.math(tex: String(chars[(i + 1)..<end])))); i = end + 1; continue
                    }
                    text.append(c); i += 1
                case "^":
                    // Pandoc inline note: ^[text].
                    if !strict, i + 1 < chars.count, chars[i + 1] == "[", let close = matchingBracket(chars, i + 1) {
                        inlineNoteCount += 1
                        let id = "inline\(inlineNoteCount)"
                        let body = parse(String(chars[(i + 2)..<close]))
                        setFootnote(id, [.paragraph(body, DocParagraphStyle())])
                        flushText(); tokens.append(.node(.footnote(id: id))); i = close + 1
                    } else { text.append(c); i += 1 }
                case "h", "w":
                    // GFM bare autolinks.
                    if !strict, c == "h" || c == "w", (i == 0 || !chars[i - 1].isLetter), let (url, end) = bareURL(chars, i) {
                        flushText()
                        var f = RunFormat(); f.link = url.hasPrefix("www.") ? "http://" + url : url
                        tokens.append(.node(.run(url, f)))
                        i = end
                    } else { text.append(c); i += 1 }
                default:
                    text.append(c); i += 1
                }
            }
            flushText()
            return emphasis(tokens)
        }

        // MARK: Emphasis (CommonMark "process emphasis")

        private func emphasis(_ input: [Token]) -> [FlatItem] {
            // Work on a list of entries that are either finished inline items (already styled) or delimiter runs.
            struct Entry { var token: Token; var items: [FlatItem]? }
            var list: [Entry] = input.map { t in
                if case .node(let n) = t { return Entry(token: t, items: [n]) }
                return Entry(token: t, items: nil)
            }
            func delim(_ e: Entry) -> (Character, Int, Bool, Bool)? {
                if case .delim(let c, let n, let o, let cl) = e.token, e.items == nil { return (c, n, o, cl) }
                return nil
            }
            var closerIndex = 0
            while closerIndex < list.count {
                guard let (ch, count, _, canClose) = delim(list[closerIndex]), canClose else { closerIndex += 1; continue }
                var opener = closerIndex - 1
                var found = false
                while opener >= 0 {
                    if let (och, ocount, canOpen, ocanClose) = delim(list[opener]), och == ch, canOpen {
                        // Multiple-of-3 rule.
                        let closerCanOpen = delim(list[closerIndex])!.2
                        if (ocanClose || closerCanOpen) && (ocount + count) % 3 == 0 && !(ocount % 3 == 0 && count % 3 == 0) { opener -= 1; continue }
                        found = true
                        break
                    }
                    opener -= 1
                }
                guard found, let (_, ocount, oOpen, oClose) = delim(list[opener]) else { closerIndex += 1; continue }
                let use: Int = ch == "~" ? 2 : (ocount >= 2 && count >= 2 ? 2 : 1)
                // Gather what is between.
                var inner: [FlatItem] = []
                for e in list[(opener + 1)..<closerIndex] {
                    if let items = e.items { inner += items }
                    else if case .delim(let c, let n, _, _) = e.token { inner.append(.run(String(repeating: c, count: n), RunFormat())) }
                }
                inner = inner.map { item in
                    if case .run(let t, var f) = item {
                        if ch == "~" { f.strike = true } else if use == 2 { f.bold = true } else { f.italic = true }
                        return .run(t, f)
                    }
                    return item
                }
                let remainingOpen = ocount - use, remainingClose = count - use
                var replacement: [Entry] = []
                if remainingOpen > 0 { replacement.append(Entry(token: .delim(ch, remainingOpen, canOpen: oOpen, canClose: oClose), items: nil)) }
                replacement.append(Entry(token: .node(.lineBreak), items: inner))
                var closerEntry: Entry?
                if remainingClose > 0 {
                    let (_, _, co, cc) = delim(list[closerIndex])!
                    closerEntry = Entry(token: .delim(ch, remainingClose, canOpen: co, canClose: cc), items: nil)
                }
                list.replaceSubrange(opener...closerIndex, with: replacement + (closerEntry.map { [$0] } ?? []))
                closerIndex = opener + replacement.count
                if closerEntry == nil { continue }
            }
            var out: [FlatItem] = []
            for e in list {
                if let items = e.items { for item in items { Self.append(item, to: &out) } }
                else if case .delim(let c, let n, _, _) = e.token { Self.append(.run(String(repeating: c, count: n), RunFormat()), to: &out) }
            }
            return out
        }

        private static func append(_ item: FlatItem, to out: inout [FlatItem]) {
            if case .run(let t, let f) = item, case .run(let p, let pf)? = out.last, pf == f { out[out.count - 1] = .run(p + t, f) } else { out.append(item) }
        }

        // MARK: Pieces

        func findClosing(_ chars: [Character], from: Int, _ close: String) -> Int? {
            let target = Array(close)
            var j = from
            while j + target.count <= chars.count {
                if Array(chars[j..<j + target.count]) == target { return j }
                j += 1
            }
            return nil
        }

        func matchingBracket(_ chars: [Character], _ open: Int) -> Int? {
            var depth = 0
            var j = open
            while j < chars.count {
                let c = chars[j]
                if c == "\\" { j += 2; continue }
                if c == "`" {
                    let run = chars[j...].prefix(while: { $0 == "`" }).count
                    var k = j + run
                    var found = false
                    while k < chars.count { if chars[k] == "`" { let r = chars[k...].prefix(while: { $0 == "`" }).count; if r == run { j = k + r; found = true; break }; k += r } else { k += 1 } }
                    if found { continue }
                }
                if c == "[" { depth += 1 }
                if c == "]" { depth -= 1; if depth == 0 { return j } }
                j += 1
            }
            return nil
        }

        /// What follows a `]`: `(dest "title")`, `[ref]`, `[]`, or nothing (a shortcut reference). Returns the end index.
        func linkTail(_ chars: [Character], after close: Int, label: String) -> (String, String?, Int)? {
            let next = close + 1
            if next < chars.count, chars[next] == "(" {
                var j = next + 1
                while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }
                var destination = ""
                if j < chars.count, chars[j] == "<" {
                    j += 1
                    while j < chars.count, chars[j] != ">" { destination.append(chars[j]); j += 1 }
                    j += 1
                } else {
                    var depth = 0
                    while j < chars.count {
                        let c = chars[j]
                        if c == "\\", j + 1 < chars.count { destination.append(chars[j + 1]); j += 2; continue }
                        if c == "(" { depth += 1 }
                        if c == ")" { if depth == 0 { break }; depth -= 1 }
                        if c == " " || c == "\n" { break }
                        destination.append(c); j += 1
                    }
                }
                while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }
                var title: String?
                if j < chars.count, "\"'(".contains(chars[j]) {
                    let quote = chars[j] == "(" ? ")" : chars[j]
                    var t = ""
                    j += 1
                    while j < chars.count, chars[j] != quote { if chars[j] == "\\", j + 1 < chars.count { j += 1 }; t.append(chars[j]); j += 1 }
                    j += 1
                    title = t
                    while j < chars.count, chars[j] == " " || chars[j] == "\n" { j += 1 }
                }
                guard j < chars.count, chars[j] == ")" else { return nil }
                return (destination, title, j + 1)
            }
            var key = label
            var end = close + 1
            if next < chars.count, chars[next] == "[", let c2 = chars[next...].firstIndex(of: "]") {
                let k = String(chars[(next + 1)..<c2])
                if !k.isEmpty { key = k }
                end = c2 + 1
            }
            if let ref = references[key.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")] ?? references[key.lowercased()] { return (ref.destination, ref.title, end) }
            return nil
        }

        mutating func resource(_ destination: String) -> String {
            if destination.hasPrefix("data:"), let comma = destination.firstIndex(of: ",") {
                let header = destination[..<comma]
                let payload = String(destination[destination.index(after: comma)...])
                let data = header.contains("base64") ? Data(base64Encoded: payload) : payload.removingPercentEncoding.map { Data($0.utf8) }
                if let data {
                    let ext = header.contains("png") ? "png" : header.contains("jpeg") || header.contains("jpg") ? "jpg" : header.contains("gif") ? "gif" : header.contains("svg") ? "svg" : "img"
                    let key = "image\(resources.count + 1).\(ext)"
                    resources[key] = data
                    return key
                }
            }
            if let base = baseURL, !destination.contains("://") {
                let path = destination.removingPercentEncoding ?? destination
                let file = base.appendingPathComponent(path).standardizedFileURL
                // Only files inside the document's folder are read.
                if file.path.hasPrefix(base.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: file) { resources[destination] = data }
            }
            return destination
        }

        /// Inline HTML: `<br>`, `<img>`, and the paired tags people put in Markdown (`<sup>`, `<u>`, `<b>`, `<a href>`, …).
        /// Returns the items and the index after the construct.
        mutating func htmlInline(_ chars: [Character], at start: Int, tagEnd: Int) -> ([FlatItem], Int)? {
            let inside = String(chars[(start + 1)..<tagEnd]).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let name = inside.split(whereSeparator: { $0.isWhitespace }).first.map { $0.lowercased() } ?? ""
            let attributes = Self.attributes(String(chars[(start + 1)..<tagEnd]))
            if name == "br" { return ([.lineBreak], tagEnd + 1) }
            if name == "img", let src = attributes["src"] {
                return ([.image(resource: resource(src), alt: attributes["alt"].flatMap { $0.isEmpty ? nil : $0 }, link: nil)], tagEnd + 1)
            }
            let styles: [String: (inout RunFormat) -> Void] = [
                "b": { $0.bold = true }, "strong": { $0.bold = true }, "i": { $0.italic = true }, "em": { $0.italic = true },
                "u": { $0.underline = true }, "ins": { $0.underline = true }, "s": { $0.strike = true }, "del": { $0.strike = true },
                "strike": { $0.strike = true }, "sup": { $0.superscript = true }, "sub": { $0.subscripted = true },
                "code": { $0.code = true }, "kbd": { $0.code = true }, "a": { _ in },
            ]
            guard let apply = styles[name], !chars[start + 1] .isWhitespace, chars[start + 1] != "/",
                  let close = findClosing(chars, from: tagEnd + 1, "</\(name)>") else { return nil }
            var items = flat(String(chars[(tagEnd + 1)..<close]))
            let href = name == "a" ? attributes["href"] : nil
            for k in items.indices {
                if case .run(let t, var f) = items[k] { apply(&f); if let href { f.link = href }; items[k] = .run(t, f) }
                if case .image(let r, let a, _) = items[k], let href { items[k] = .image(resource: r, alt: a, link: href) }
            }
            return (items, close + name.count + 3)
        }

        static func attributes(_ tag: String) -> [String: String] {
            var out: [String: String] = [:]
            let pattern = try! NSRegularExpression(pattern: "([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))")
            let ns = tag as NSString
            for m in pattern.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1)).lowercased()
                for g in 2...4 where m.range(at: g).location != NSNotFound { out[key] = HTMLEntities.decode(ns.substring(with: m.range(at: g))); break }
            }
            return out
        }

        func bareURL(_ chars: [Character], _ start: Int) -> (String, Int)? {
            let prefixes = ["https://", "http://", "www."]
            let rest = String(chars[start...].prefix(8))
            guard prefixes.contains(where: { rest.hasPrefix($0) }) else { return nil }
            var j = start
            while j < chars.count, !chars[j].isWhitespace, chars[j] != "<" { j += 1 }
            while j > start, ".,:;!?\"')]*_~".contains(chars[j - 1]) { j -= 1 }
            let url = String(chars[start..<j])
            guard url.count > 8 else { return nil }
            return (url, j)
        }

        static func entity(_ name: String) -> String? {
            if name.hasPrefix("#x") || name.hasPrefix("#X"), let v = UInt32(name.dropFirst(2), radix: 16), let s = Unicode.Scalar(v) { return String(Character(s)) }
            if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let s = Unicode.Scalar(v) { return String(Character(s)) }
            return HTMLEntities.table[name]
        }
    }
}
