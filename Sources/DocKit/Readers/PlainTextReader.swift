import Foundation
import SuperConverterCore

/// Plain text → `DocModel` (formats §3.2 `PlainTextReader`): encoding detection (BOM, UTF-8, UTF-16, legacy code pages), then
/// prose or code (O-DOC-PDF+TXT "Treat as"). Prose becomes paragraphs (hard-wrapped lines are joined), underlined headings,
/// bullet and numbered lists; code is one verbatim block with tabs expanded.
enum PlainTextReader {
    static func read(_ url: URL, options: DocReadOptions = DocReadOptions()) throws -> DocReadResult {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let (text, _) = TextCoding.decode(data, hint: options.encoding)
        return parse(text, options: options)
    }

    static func parse(_ source: String, options: DocReadOptions = DocReadOptions()) -> DocReadResult {
        let text = source.normalisedNewlines
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let asCode: Bool
        switch options.treatAs {
        case "code": asCode = true
        case "prose": asCode = false
        default: asCode = looksLikeCode(lines)
        }
        if asCode {
            let expanded = lines.map { expandTabs($0, width: options.tabWidth) }
            var trimmed = expanded
            while trimmed.last?.isEmpty == true { trimmed.removeLast() }
            return DocReadResult(model: DocModel(blocks: [.code(language: nil, text: trimmed.joined(separator: "\n"))]))
        }
        return DocReadResult(model: DocModel(blocks: prose(lines)))
    }

    static func expandTabs(_ line: String, width: Int) -> String {
        guard line.contains("\t") else { return line }
        var out = ""
        for ch in line {
            if ch == "\t" { out += String(repeating: " ", count: width - out.count % max(width, 1)) } else { out.append(ch) }
        }
        return out
    }

    /// Source code, logs and config files: many lines that end in code punctuation or are indented.
    static func looksLikeCode(_ lines: [String]) -> Bool {
        let content = lines.filter { !$0.trimmed.isEmpty }
        guard content.count >= 3 else { return false }
        let codeish = content.filter { line in
            let t = line.trimmed
            return line.hasPrefix("    ") || line.hasPrefix("\t") || t.hasSuffix(";") || t.hasSuffix("{") || t.hasSuffix("}") || t.hasPrefix("//") || t.hasPrefix("#include")
                || t.hasPrefix("def ") || t.hasPrefix("import ") || t.hasPrefix("func ") || t.contains(" = ") && t.hasSuffix(")") || t.hasSuffix(":") && !t.contains(". ")
        }
        return Double(codeish.count) / Double(content.count) >= 0.4
    }

    private static func prose(_ lines: [String]) -> [DocBlock] {
        var blocks: [DocBlock] = []
        var i = 0
        func isBlank(_ s: String) -> Bool { s.trimmed.isEmpty }
        func bullet(_ s: String) -> (ordered: Bool, rest: String)? {
            let t = s.drop(while: { $0 == " " })
            for marker in ["- ", "* ", "• ", "+ "] where t.hasPrefix(marker) { return (false, String(t.dropFirst(marker.count))) }
            let digits = t.prefix { $0.isNumber }
            if !digits.isEmpty, digits.count <= 3, let d = t.dropFirst(digits.count).first, d == "." || d == ")", t.dropFirst(digits.count + 1).first == " " {
                return (true, String(t.dropFirst(digits.count + 1)).trimmed)
            }
            return nil
        }
        while i < lines.count {
            if isBlank(lines[i]) { i += 1; continue }
            // List.
            if let first = bullet(lines[i]) {
                var items: [[DocBlock]] = []
                while i < lines.count, let item = bullet(lines[i]), item.ordered == first.ordered {
                    var text = item.rest
                    i += 1
                    while i < lines.count, !isBlank(lines[i]), bullet(lines[i]) == nil, lines[i].hasPrefix(" ") { text += " " + lines[i].trimmed; i += 1 }
                    items.append([.paragraph([.text(text)], DocParagraphStyle())])
                    while i < lines.count, isBlank(lines[i]), i + 1 < lines.count, bullet(lines[i + 1]) != nil { i += 1 }
                }
                blocks.append(.list(ordered: first.ordered, start: 1, items: items))
                continue
            }
            var paragraph: [String] = []
            while i < lines.count, !isBlank(lines[i]) {
                if !paragraph.isEmpty, bullet(lines[i]) != nil { break }
                paragraph.append(lines[i]); i += 1
            }
            // Underlined heading.
            if paragraph.count == 2, let underline = paragraph.last?.trimmed, underline.count >= 3, underline.allSatisfy({ $0 == "=" }) || underline.allSatisfy({ $0 == "-" }) {
                blocks.append(.heading(level: underline.first == "=" ? 1 : 2, [.text(paragraph[0].trimmed)]))
                continue
            }
            let trimmedLines = paragraph.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t")) }
            // Hard-wrapped prose: every line but the last is long; otherwise the breaks mean something (verse, addresses).
            let wrapped = trimmedLines.count > 1 && trimmedLines.dropLast().allSatisfy { $0.count >= 40 }
            if wrapped || trimmedLines.count == 1 {
                blocks.append(.paragraph([.text(trimmedLines.joined(separator: " "))], DocParagraphStyle()))
            } else {
                var text: DocText = []
                for (n, line) in trimmedLines.enumerated() { if n > 0 { text.append(.lineBreak) }; text.append(.text(line)) }
                blocks.append(.paragraph(text, DocParagraphStyle()))
            }
        }
        return blocks
    }
}
