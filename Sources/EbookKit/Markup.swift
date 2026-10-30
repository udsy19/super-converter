import Foundation

/// A forgiving HTML/XML tree for e-book content. XHTML in an EPUB is well formed, but HTMLZ, CHM and hand-made OEB files
/// are not, and OPF, NCX and FB2 need the same tree, so one tolerant parser serves them all. Names are stored without their
/// prefix (`dc:title` is `title`); in HTML mode they are lower-cased and void/implied-end rules apply.
final class MarkupNode {
    let name: String
    var attributes: [String: String]
    var children: [MarkupNode] = []
    /// Set for text nodes (name "#text").
    let text: String?
    weak var parent: MarkupNode?

    init(name: String, attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes; text = nil }
    init(text: String) { name = "#text"; attributes = [:]; self.text = text }

    var isText: Bool { text != nil }
    var elements: [MarkupNode] { children.filter { !$0.isText } }

    /// An attribute by its written name (`epub:type`) or its local name (`type`).
    func attribute(_ key: String) -> String? { attributes[key] }

    func elements(named n: String) -> [MarkupNode] { children.filter { $0.name == n } }
    func first(_ n: String) -> MarkupNode? { children.first { $0.name == n } }

    /// First descendant (depth first) with this name.
    func descendant(_ n: String) -> MarkupNode? {
        for c in children where !c.isText {
            if c.name == n { return c }
            if let d = c.descendant(n) { return d }
        }
        return nil
    }

    func descendants(_ n: String) -> [MarkupNode] {
        var out: [MarkupNode] = []
        for c in children where !c.isText {
            if c.name == n { out.append(c) }
            out += c.descendants(n)
        }
        return out
    }

    /// All text below this node, whitespace collapsed.
    var plainText: String {
        var s = ""
        func walk(_ n: MarkupNode) {
            if let t = n.text { s += t } else if n.name != "script" && n.name != "style" { n.children.forEach(walk) }
        }
        walk(self)
        return s.collapsingWhitespace()
    }

    var rawText: String {
        var s = ""
        func walk(_ n: MarkupNode) { if let t = n.text { s += t } else { n.children.forEach(walk) } }
        walk(self)
        return s
    }
}

extension String {
    func collapsingWhitespace() -> String {
        var out = ""
        var pendingSpace = false
        for ch in self {
            if ch.isWhitespace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" "); pendingSpace = false }
                out.append(ch)
            }
        }
        return out
    }
}

enum MarkupParser {
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param",
                                            "source", "track", "wbr", "basefont", "frame", "keygen"]
    private static let blockStarts: Set<String> = [
        "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
        "h6", "header", "hr", "main", "nav", "ol", "p", "pre", "section", "table", "ul"]
    private static let rawTextElements: Set<String> = ["script", "style"]
    /// Elements open at once, as libxml2 allows: deeper ones are still read, as siblings at this depth, so damaged or
    /// hostile nesting ("<div>" twenty thousand times) can't overflow the stack of the readers that walk the tree.
    static let maxDepth = 256

    static func parse(_ text: String, html: Bool, lowercase: Bool? = nil) -> MarkupNode {
        let lower = lowercase ?? html
        let bytes = Array(text.utf8)
        let root = MarkupNode(name: "#root")
        var stack: [MarkupNode] = [root]
        var i = 0
        let n = bytes.count
        var buffer: [UInt8] = []

        func flushText() {
            guard !buffer.isEmpty else { return }
            let raw = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll(keepingCapacity: true)
            let decoded = Entities.decode(raw)
            let node = MarkupNode(text: decoded)
            node.parent = stack.last
            stack.last!.children.append(node)
        }
        func isNameByte(_ b: UInt8) -> Bool { !(b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x2F || b == 0x3E || b == 0x3D) }
        func hasPrefix(_ s: String, at p: Int) -> Bool {
            let u = Array(s.utf8)
            guard p + u.count <= n else { return false }
            for k in 0..<u.count where bytes[p + k] != u[k] { return false }
            return true
        }
        func closeImplied(for tag: String) {
            guard html else { return }
            func popIf(_ names: Set<String>, stopAt barrier: Set<String>) {
                var k = stack.count - 1
                while k > 0 {
                    let name = stack[k].name
                    if names.contains(name) { stack.removeSubrange(k...); return }
                    if barrier.contains(name) { return }
                    k -= 1
                }
            }
            switch tag {
            case "li": popIf(["li"], stopAt: ["ul", "ol"])
            case "dt", "dd": popIf(["dt", "dd"], stopAt: ["dl"])
            case "tr": popIf(["tr"], stopAt: ["table"]); popIf(["td", "th"], stopAt: ["table", "tr"])
            case "td", "th": popIf(["td", "th"], stopAt: ["tr", "table"])
            case "thead", "tbody", "tfoot": popIf(["thead", "tbody", "tfoot", "tr", "td", "th"], stopAt: ["table"])
            case "option": popIf(["option"], stopAt: ["select"])
            default: break
            }
            if blockStarts.contains(tag), stack.last?.name == "p" { stack.removeLast() }
        }

        while i < n {
            let b = bytes[i]
            if b != 0x3C {   // <
                buffer.append(b); i += 1; continue
            }
            if hasPrefix("<!--", at: i) {
                flushText()
                var j = i + 4
                while j < n && !hasPrefix("-->", at: j) { j += 1 }
                i = min(n, j + 3); continue
            }
            if hasPrefix("<![CDATA[", at: i) {
                flushText()
                var j = i + 9
                while j < n && !hasPrefix("]]>", at: j) { j += 1 }
                let node = MarkupNode(text: String(decoding: bytes[(i + 9)..<min(j, n)], as: UTF8.self))
                node.parent = stack.last; stack.last!.children.append(node)
                i = min(n, j + 3); continue
            }
            if i + 1 < n, bytes[i + 1] == 0x21 || bytes[i + 1] == 0x3F {   // <! or <?
                flushText()
                var j = i + 2
                var depth = 0
                while j < n {
                    if bytes[j] == 0x5B { depth += 1 } else if bytes[j] == 0x5D { depth -= 1 } else if bytes[j] == 0x3E && depth <= 0 { break }
                    j += 1
                }
                i = min(n, j + 1); continue
            }
            if i + 1 < n, bytes[i + 1] == 0x2F {   // end tag
                var j = i + 2
                let s = j
                while j < n && bytes[j] != 0x3E { j += 1 }
                let nameText = String(decoding: bytes[s..<j], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                i = min(n, j + 1)
                flushText()
                var local = nameText.split(separator: ":").last.map(String.init) ?? nameText
                if lower { local = local.lowercased() }
                if let k = stack.lastIndex(where: { $0.name == local }), k > 0 { stack.removeSubrange(k...) }
                continue
            }
            // start tag
            guard i + 1 < n, bytes[i + 1].isLetter else { buffer.append(b); i += 1; continue }
            flushText()
            var j = i + 1
            let ns = j
            while j < n && isNameByte(bytes[j]) { j += 1 }
            let rawName = String(decoding: bytes[ns..<j], as: UTF8.self)
            var local = rawName.split(separator: ":").last.map(String.init) ?? rawName
            if lower { local = local.lowercased() }
            var attrs: [String: String] = [:]
            var selfClosing = false
            while j < n {
                while j < n && (bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D) { j += 1 }
                if j >= n { break }
                if bytes[j] == 0x3E { j += 1; break }
                if bytes[j] == 0x2F { if j + 1 < n, bytes[j + 1] == 0x3E { selfClosing = true; j += 2; break }; j += 1; continue }
                let ks = j
                while j < n && isNameByte(bytes[j]) { j += 1 }
                if j == ks { j += 1; continue }
                var key = String(decoding: bytes[ks..<j], as: UTF8.self)
                if lower { key = key.lowercased() }
                while j < n && (bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D) { j += 1 }
                var value = ""
                if j < n, bytes[j] == 0x3D {
                    j += 1
                    while j < n && (bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D) { j += 1 }
                    if j < n, bytes[j] == 0x22 || bytes[j] == 0x27 {
                        let q = bytes[j]; j += 1
                        let vs = j
                        while j < n && bytes[j] != q { j += 1 }
                        value = String(decoding: bytes[vs..<j], as: UTF8.self)
                        j = min(n, j + 1)
                    } else {
                        let vs = j
                        while j < n && !(bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D || bytes[j] == 0x3E) { j += 1 }
                        value = String(decoding: bytes[vs..<j], as: UTF8.self)
                    }
                }
                let decoded = Entities.decode(value)
                attrs[key] = decoded
                if let colon = key.lastIndex(of: ":") {
                    let short = String(key[key.index(after: colon)...])
                    if attrs[short] == nil { attrs[short] = decoded }
                }
            }
            i = j
            closeImplied(for: local)
            let node = MarkupNode(name: local, attributes: attrs)
            node.parent = stack.last
            stack.last!.children.append(node)
            if selfClosing || (html && voidElements.contains(local)) { continue }
            if html && rawTextElements.contains(local) {
                let close = "</" + local
                var k = i
                while k < n {
                    if bytes[k] == 0x3C, k + close.utf8.count <= n,
                       String(decoding: bytes[k..<k + close.utf8.count], as: UTF8.self).lowercased() == close { break }
                    k += 1
                }
                let t = MarkupNode(text: String(decoding: bytes[i..<min(k, n)], as: UTF8.self))
                t.parent = node; node.children.append(t)
                while k < n && bytes[k] != 0x3E { k += 1 }
                i = min(n, k + 1)
                continue
            }
            if stack.count <= maxDepth { stack.append(node) }
        }
        flushText()
        return root
    }
}

private extension UInt8 {
    var isLetter: Bool { (self >= 0x41 && self <= 0x5A) || (self >= 0x61 && self <= 0x7A) || self == 0x5F }
}

enum Entities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}", "copy": "©", "reg": "®", "trade": "™",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«",
        "raquo": "»", "bull": "•", "middot": "·", "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "para": "¶",
        "sect": "§", "cent": "¢", "pound": "£", "euro": "€", "yen": "¥", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "aacute": "á", "agrave": "à", "acirc": "â", "auml": "ä",
        "aring": "å", "atilde": "ã", "ccedil": "ç", "iacute": "í", "icirc": "î", "iuml": "ï", "ntilde": "ñ", "oacute": "ó",
        "ocirc": "ô", "ouml": "ö", "oslash": "ø", "uacute": "ú", "ucirc": "û", "uuml": "ü", "szlig": "ß", "yacute": "ý",
        "Eacute": "É", "Agrave": "À", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "Ccedil": "Ç", "Ntilde": "Ñ", "AElig": "Æ",
        "aelig": "æ", "thinsp": "\u{2009}", "ensp": "\u{2002}", "emsp": "\u{2003}", "shy": "\u{AD}", "larr": "←", "rarr": "→",
        "uarr": "↑", "darr": "↓", "infin": "∞", "ne": "≠", "le": "≤", "ge": "≥", "minus": "−", "prime": "′", "Prime": "″",
        "dagger": "†", "Dagger": "‡", "sbquo": "‚", "bdquo": "„", "lsaquo": "‹", "rsaquo": "›", "iexcl": "¡", "iquest": "¿",
        "sup1": "¹", "sup2": "²", "sup3": "³", "micro": "µ", "alpha": "α", "beta": "β", "gamma": "γ", "pi": "π", "omega": "ω",
    ]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            guard ch == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") else { out.append(ch); i = s.index(after: i); continue }
            let body = s[s.index(after: i)..<semi]
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                if let v = UInt32(body.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
            } else if body.hasPrefix("#") {
                if let v = UInt32(body.dropFirst()), let u = Unicode.Scalar(v) { replacement = String(Character(u)) }
            } else {
                replacement = named[String(body)]
            }
            if let r = replacement { out += r; i = s.index(after: semi) } else { out.append(ch); i = s.index(after: i) }
        }
        return out
    }
}

/// Escapes text for XML output.
func xmlEscape(_ s: String, attribute: Bool = false) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s.unicodeScalars {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"" where attribute: out += "&quot;"
        case "\u{9}", "\u{A}", "\u{D}": out.unicodeScalars.append(ch)
        default:
            if ch.value < 0x20 || ch.value == 0xFFFE || ch.value == 0xFFFF || (0xD800...0xDFFF).contains(ch.value) { continue }
            out.unicodeScalars.append(ch)
        }
    }
    return out
}
