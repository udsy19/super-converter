import Foundation

/// A forgiving HTML tokenizer and tree builder: enough of the HTML parsing algorithm (void elements, raw-text elements,
/// implied end tags for paragraphs, list items, definition lists, table rows and cells, unmatched end tags) to read real
/// pages. It never runs scripts or loads anything. The brief's reader walks a WebKit DOM; this one needs no web process,
/// which keeps conversion deterministic and safe on hostile input (scripts are skipped, nothing is fetched).
final class HTMLNode {
    let tag: String          // lower-case; "#text" for text, "#root" for the document
    var attributes: [String: String]
    var children: [HTMLNode] = []
    var text: String = ""
    weak var parent: HTMLNode?

    init(tag: String, attributes: [String: String] = [:], text: String = "") {
        self.tag = tag; self.attributes = attributes; self.text = text
    }

    var isText: Bool { tag == "#text" }
    func attr(_ name: String) -> String? { attributes[name] }
    var classes: Set<String> { Set((attributes["class"] ?? "").split(separator: " ").map(String.init)) }

    /// All text inside, concatenated.
    var allText: String { isText ? text : children.map(\.allText).joined() }

    func first(where match: (HTMLNode) -> Bool) -> HTMLNode? {
        for child in children {
            if match(child) { return child }
            if let found = child.first(where: match) { return found }
        }
        return nil
    }

    func all(where match: (HTMLNode) -> Bool) -> [HTMLNode] {
        var out: [HTMLNode] = []
        for child in children {
            if match(child) { out.append(child) }
            out += child.all(where: match)
        }
        return out
    }

    func firstTag(_ name: String) -> HTMLNode? { first { $0.tag == name } }

    /// The CSS declarations in the `style` attribute, lower-cased names.
    var style: [String: String] {
        var out: [String: String] = [:]
        for declaration in (attributes["style"] ?? "").split(separator: ";") {
            guard let colon = declaration.firstIndex(of: ":") else { continue }
            out[declaration[..<colon].trimmed.lowercased()] = declaration[declaration.index(after: colon)...].trimmed
        }
        return out
    }
}

enum HTMLParser {
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    private static let rawText: Set<String> = ["script", "style", "textarea", "title", "xmp"]
    private static let blockStarts: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "div", "dl", "fieldset", "figcaption", "figure", "footer", "form",
        "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "nav", "ol", "p", "pre", "section", "table", "ul",
    ]
    /// Elements nested deeper than this are not nested further, so hostile pages cannot exhaust the stack.
    private static let maxDepth = 400
    private static let scopeBoundaries: Set<String> = ["table", "td", "th", "caption", "button", "object", "template", "html", "#root"]

    static func parse(_ source: String) -> HTMLNode {
        let root = HTMLNode(tag: "#root")
        var stack: [HTMLNode] = [root]
        let chars = Array(source)
        var i = 0
        var text = ""

        func flushText() {
            guard !text.isEmpty else { return }
            let node = HTMLNode(tag: "#text", text: HTMLEntities.decode(text))
            node.parent = stack.last
            stack.last?.children.append(node)
            text = ""
        }
        func closeIfOpen(_ tag: String, upTo boundaries: Set<String>) {
            for index in stride(from: stack.count - 1, to: 0, by: -1) {
                if boundaries.contains(stack[index].tag) { return }
                if stack[index].tag == tag { stack.removeSubrange(index...); return }
            }
        }
        func open(_ name: String, _ attributes: [String: String], selfClosing: Bool) {
            flushText()
            // Implied end tags.
            if blockStarts.contains(name) { closeIfOpen("p", upTo: scopeBoundaries.union(["li", "dd", "dt", "blockquote", "div", "section", "article"])) }
            switch name {
            case "li": closeIfOpen("li", upTo: ["ul", "ol", "table", "#root"])
            case "dt", "dd": closeIfOpen("dt", upTo: ["dl", "#root"]); closeIfOpen("dd", upTo: ["dl", "#root"])
            case "tr": closeIfOpen("tr", upTo: ["table", "#root"])
            case "td", "th": closeIfOpen("td", upTo: ["tr", "table", "#root"]); closeIfOpen("th", upTo: ["tr", "table", "#root"])
            case "thead", "tbody", "tfoot": closeIfOpen("thead", upTo: ["table"]); closeIfOpen("tbody", upTo: ["table"]); closeIfOpen("tfoot", upTo: ["table"])
            case "option": closeIfOpen("option", upTo: ["select"])
            default: break
            }
            let node = HTMLNode(tag: name, attributes: attributes)
            node.parent = stack.last
            stack.last?.children.append(node)
            if !voidElements.contains(name) && !selfClosing && stack.count < maxDepth { stack.append(node) }
        }
        func close(_ name: String) {
            flushText()
            for index in stride(from: stack.count - 1, to: 0, by: -1) where stack[index].tag == name {
                stack.removeSubrange(index...)
                return
            }
        }

        while i < chars.count {
            let c = chars[i]
            if c != "<" { text.append(c); i += 1; continue }
            // Comment, doctype, CDATA.
            if hasPrefix(chars, i, "<!--") {
                flushText()
                if let end = find(chars, i + 4, "-->") { i = end + 3 } else { i = chars.count }
                continue
            }
            if hasPrefix(chars, i, "<![CDATA[") {
                if let end = find(chars, i + 9, "]]>") { text += String(chars[(i + 9)..<end]); i = end + 3 } else { i = chars.count }
                continue
            }
            if i + 1 < chars.count, chars[i + 1] == "!" || chars[i + 1] == "?" {
                flushText()
                while i < chars.count, chars[i] != ">" { i += 1 }
                i += 1
                continue
            }
            // End tag.
            if i + 1 < chars.count, chars[i + 1] == "/" {
                var j = i + 2
                var name = ""
                while j < chars.count, chars[j] != ">", !chars[j].isWhitespace { name.append(chars[j]); j += 1 }
                while j < chars.count, chars[j] != ">" { j += 1 }
                if name.first?.isLetter == true { close(name.lowercased()) } else { text += "</" + name }
                i = j + 1
                continue
            }
            // Start tag.
            guard i + 1 < chars.count, chars[i + 1].isLetter else { text.append(c); i += 1; continue }
            var j = i + 1
            var name = ""
            while j < chars.count, !chars[j].isWhitespace, chars[j] != ">", chars[j] != "/" { name.append(chars[j]); j += 1 }
            name = name.lowercased()
            var attributes: [String: String] = [:]
            var selfClosing = false
            while j < chars.count, chars[j] != ">" {
                if chars[j].isWhitespace { j += 1; continue }
                if chars[j] == "/" { selfClosing = j + 1 < chars.count && chars[j + 1] == ">"; j += 1; continue }
                var key = ""
                while j < chars.count, !chars[j].isWhitespace, chars[j] != "=", chars[j] != ">", chars[j] != "/" { key.append(chars[j]); j += 1 }
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                var value = ""
                if j < chars.count, chars[j] == "=" {
                    j += 1
                    while j < chars.count, chars[j].isWhitespace { j += 1 }
                    if j < chars.count, chars[j] == "\"" || chars[j] == "'" {
                        let q = chars[j]; j += 1
                        while j < chars.count, chars[j] != q { value.append(chars[j]); j += 1 }
                        j += 1
                    } else {
                        while j < chars.count, !chars[j].isWhitespace, chars[j] != ">" { value.append(chars[j]); j += 1 }
                    }
                }
                if !key.isEmpty { attributes[key.lowercased()] = HTMLEntities.decode(value) }
            }
            i = j + 1
            open(name, attributes, selfClosing: selfClosing)
            if rawText.contains(name), !selfClosing {
                // Everything up to the matching end tag is text (scripts and styles are dropped by the reader).
                let closing = "</" + name
                var k = i
                var body = ""
                while k < chars.count {
                    if chars[k] == "<", hasPrefixCaseInsensitive(chars, k, closing) { break }
                    body.append(chars[k]); k += 1
                }
                if !body.isEmpty {
                    let node = HTMLNode(tag: "#text", text: name == "script" || name == "style" ? body : HTMLEntities.decode(body))
                    node.parent = stack.last
                    stack.last?.children.append(node)
                }
                i = k
            }
        }
        flushText()
        return root
    }

    private static func hasPrefix(_ chars: [Character], _ at: Int, _ s: String) -> Bool {
        let t = Array(s)
        return at + t.count <= chars.count && Array(chars[at..<at + t.count]) == t
    }

    private static func hasPrefixCaseInsensitive(_ chars: [Character], _ at: Int, _ s: String) -> Bool {
        let t = Array(s.lowercased())
        return at + t.count <= chars.count && Array(chars[at..<at + t.count]).map { Character($0.lowercased()) } == t
    }

    private static func find(_ chars: [Character], _ from: Int, _ s: String) -> Int? {
        let t = Array(s)
        var j = from
        while j + t.count <= chars.count {
            if Array(chars[j..<j + t.count]) == t { return j }
            j += 1
        }
        return nil
    }
}
