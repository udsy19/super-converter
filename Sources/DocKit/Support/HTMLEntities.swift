import Foundation

/// Named character references: the ones documents use (HTML 4 Latin-1, symbols and punctuation, Greek, arrows, maths).
enum HTMLEntities {
    static let table: [String: String] = {
        var t: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}", "ensp": "\u{2002}", "emsp": "\u{2003}",
            "thinsp": "\u{2009}", "zwj": "\u{200D}", "zwnj": "\u{200C}", "shy": "\u{AD}", "hellip": "…", "mdash": "—", "ndash": "–",
            "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„", "bull": "•", "middot": "·",
            "dagger": "†", "Dagger": "‡", "permil": "‰", "prime": "′", "Prime": "″", "lsaquo": "‹", "rsaquo": "›", "oline": "‾",
            "euro": "€", "trade": "™", "larr": "←", "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔", "lArr": "⇐", "rArr": "⇒",
            "hArr": "⇔", "forall": "∀", "part": "∂", "exist": "∃", "empty": "∅", "nabla": "∇", "isin": "∈", "notin": "∉", "ni": "∋",
            "prod": "∏", "sum": "∑", "minus": "−", "lowast": "∗", "radic": "√", "prop": "∝", "infin": "∞", "ang": "∠", "and": "∧",
            "or": "∨", "cap": "∩", "cup": "∪", "int": "∫", "there4": "∴", "sim": "∼", "cong": "≅", "asymp": "≈", "ne": "≠",
            "equiv": "≡", "le": "≤", "ge": "≥", "sub": "⊂", "sup": "⊃", "sube": "⊆", "supe": "⊇", "oplus": "⊕", "otimes": "⊗",
            "perp": "⊥", "sdot": "⋅", "loz": "◊", "spades": "♠", "clubs": "♣", "hearts": "♥", "diams": "♦", "fnof": "ƒ",
            "circ": "ˆ", "tilde": "˜", "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š", "Yuml": "Ÿ", "image": "ℑ", "weierp": "℘",
            "real": "ℜ", "alefsym": "ℵ", "check": "✓", "lang": "⟨", "rang": "⟩", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
        ]
        let greek = ["Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta", "Theta", "Iota", "Kappa", "Lambda", "Mu", "Nu", "Xi", "Omicron", "Pi", "Rho", "", "Sigma", "Tau", "Upsilon", "Phi", "Chi", "Psi", "Omega"]
        for (i, name) in greek.enumerated() where !name.isEmpty {
            t[name] = String(UnicodeScalar(0x391 + UInt32(i))!)
            t[name.lowercased()] = String(UnicodeScalar(0x3B1 + UInt32(i))!)
        }
        t["sigmaf"] = "ς"
        let latin1 = ["nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo", "not", "shy", "reg", "macr",
                      "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot", "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest",
                      "Agrave", "Aacute", "Acirc", "Atilde", "Auml", "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute", "Icirc", "Iuml",
                      "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times", "Oslash", "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig",
                      "agrave", "aacute", "acirc", "atilde", "auml", "aring", "aelig", "ccedil", "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc", "iuml",
                      "eth", "ntilde", "ograve", "oacute", "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave", "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml"]
        for (i, name) in latin1.enumerated() { t[name] = String(UnicodeScalar(0xA0 + UInt32(i))!) }
        return t
    }()

    /// Replaces every `&name;`, `&#n;` and `&#xh;` in `text`.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "&", let semicolon = text[i...].prefix(12).firstIndex(of: ";") {
                let name = String(text[text.index(after: i)..<semicolon])
                var decoded: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X"), let v = UInt32(name.dropFirst(2), radix: 16), let s = Unicode.Scalar(v) { decoded = String(Character(s)) }
                else if name.hasPrefix("#"), let v = UInt32(name.dropFirst()), let s = Unicode.Scalar(v) { decoded = String(Character(s)) }
                else { decoded = table[name] }
                if let decoded { out += decoded; i = text.index(after: semicolon); continue }
            }
            out.append(c)
            i = text.index(after: i)
        }
        return out
    }

    /// Text for element content and attribute values.
    static func escape(_ text: String, attribute: Bool = false) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}
