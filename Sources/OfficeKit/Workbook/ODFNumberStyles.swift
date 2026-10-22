import Foundation

// Excel number format codes ("#,##0.00", "0%", "yyyy-mm-dd", "h:mm:ss") as OpenDocument data styles and back. Supported:
// plain, grouped and percent numbers with literal prefixes and suffixes, scientific numbers, dates and times. A code
// outside that (fractions, conditions) is written as a plain number and reads back as General.

enum ODFNumberStyles {
    /// Characters a code can carry without quotes.
    private static let bareLiterals = Set("$-+/():!^&'~{}<>= .,")

    /// The `number:*-style` element named `name` for `code`, or nil when the code has no data style.
    static func element(code: String, name: String) -> String? {
        let section = firstSection(code)
        guard !section.isEmpty, section.lowercased() != "general", section != "@" else { return nil }
        if SheetNumberFormat(code: code).isDate { return dateElement(section, name: name) }
        return numberElement(section, name: name)
    }

    // MARK: Writing numbers

    private enum Token { case literal(String), digit(Character), point, comma, percent, exponent }

    private static func numberElement(_ section: String, name: String) -> String? {
        var tokens: [Token] = []
        let chars = Array(section)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\"":
                var j = i + 1, text = ""
                while j < chars.count, chars[j] != "\"" { text.append(chars[j]); j += 1 }
                tokens.append(.literal(text)); i = j + 1
            case "\\":
                if i + 1 < chars.count { tokens.append(.literal(String(chars[i + 1]))) }
                i += 2
            case "_": tokens.append(.literal(" ")); i += 2
            case "*": i += 2
            case "[":
                var j = i + 1, inner = ""
                while j < chars.count, chars[j] != "]" { inner.append(chars[j]); j += 1 }
                if inner.hasPrefix("$") {
                    tokens.append(.literal(inner.dropFirst().split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""))
                }
                i = j + 1
            case "0", "#", "?": tokens.append(.digit(c)); i += 1
            case ".": tokens.append(.point); i += 1
            case ",": tokens.append(.comma); i += 1
            case "%": tokens.append(.percent); i += 1
            case "E", "e":
                if i + 1 < chars.count, chars[i + 1] == "+" || chars[i + 1] == "-" { tokens.append(.exponent); i += 2 } else { tokens.append(.literal(String(c))); i += 1 }
            default: tokens.append(.literal(String(c))); i += 1
            }
        }
        guard let first = tokens.firstIndex(where: { if case .digit = $0 { true } else { false } }) else { return nil }
        let exponentIndex = tokens.firstIndex(where: { if case .exponent = $0 { true } else { false } })
        let mantissaEnd = exponentIndex ?? tokens.count
        let last = tokens[..<mantissaEnd].lastIndex(where: { if case .digit = $0 { true } else { false } }) ?? first
        var prefix = "", suffix = ""
        var integerDigits = 0, minInteger = 0, fractionDigits = 0
        var seenPoint = false, grouping = false, percent = false
        for (index, token) in tokens.enumerated() {
            switch token {
            case .percent: percent = true
            case .literal(let text):
                if index < first { prefix += text } else if index > last, exponentIndex == nil || index < exponentIndex! { suffix += text }
            case .digit(let d):
                if index > last { break }
                if seenPoint { fractionDigits += 1 } else { integerDigits += 1; if d == "0" { minInteger += 1 } }
            case .point: seenPoint = true
            case .comma: if index > first, index < last, !seenPoint { grouping = true }
            case .exponent: break
            }
        }
        let exponentDigits = exponentIndex.map { start in
            tokens[(start + 1)...].filter { if case .digit("0") = $0 { true } else { false } }.count
        } ?? 0
        func text(_ s: String) -> String { s.isEmpty ? "" : "<number:text>\(XML.escape(s))</number:text>" }
        let number: String
        if exponentIndex != nil {
            number = "<number:scientific-number number:decimal-places=\"\(fractionDigits)\" number:min-integer-digits=\"\(max(minInteger, 1))\" number:min-exponent-digits=\"\(max(exponentDigits, 1))\"/>"
        } else {
            number = "<number:number number:decimal-places=\"\(fractionDigits)\" number:min-integer-digits=\"\(minInteger)\"\(grouping ? " number:grouping=\"true\"" : "")/>"
        }
        let tag = percent ? "number:percentage-style" : "number:number-style"
        return "<\(tag) style:name=\"\(name)\">\(text(prefix))\(number)\(percent ? "<number:text>%</number:text>" : "")\(text(suffix))</\(tag)>"
    }

    // MARK: Writing dates

    private static func dateElement(_ section: String, name: String) -> String? {
        enum Piece { case run(Character, Int), literal(String), ampm }
        var pieces: [Piece] = []
        let chars = Array(section)
        var i = 0
        while i < chars.count {
            let c = chars[i], lc = Character(c.lowercased())
            if c == "\"" {
                var j = i + 1, text = ""
                while j < chars.count, chars[j] != "\"" { text.append(chars[j]); j += 1 }
                pieces.append(.literal(text)); i = j + 1
            } else if c == "\\" {
                if i + 1 < chars.count { pieces.append(.literal(String(chars[i + 1]))) }
                i += 2
            } else if c == "_" {
                pieces.append(.literal(" ")); i += 2
            } else if c == "[" {
                var j = i + 1
                while j < chars.count, chars[j] != "]" { j += 1 }
                i = j + 1
            } else if section.lowercased().dropFirst(i).hasPrefix("am/pm") {
                pieces.append(.ampm); i += 5
            } else if "ymdhs".contains(lc) {
                var j = i
                while j < chars.count, Character(chars[j].lowercased()) == lc { j += 1 }
                pieces.append(.run(lc, j - i)); i = j
            } else {
                pieces.append(.literal(String(c))); i += 1
            }
        }
        // "m" is minutes right after an hour or right before a second.
        func isMinute(_ index: Int) -> Bool {
            var k = index - 1
            while k >= 0 { if case .run(let l, _) = pieces[k] { return l == "h" }; k -= 1 }
            k = index + 1
            while k < pieces.count { if case .run(let l, _) = pieces[k] { return l == "s" }; k += 1 }
            return false
        }
        var hasDate = false
        var body = ""
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case .literal(let s): body += "<number:text>\(XML.escape(s))</number:text>"
            case .ampm: body += "<number:am-pm/>"
            case .run(let l, let n):
                let long = n >= 2 ? " number:style=\"long\"" : ""
                switch l {
                case "y": hasDate = true; body += "<number:year\(n >= 3 ? " number:style=\"long\"" : "")/>"
                case "m" where isMinute(index): body += "<number:minutes\(long)/>"
                case "m":
                    hasDate = true
                    body += n >= 3 ? "<number:month number:textual=\"true\"\(n >= 4 ? " number:style=\"long\"" : "")/>" : "<number:month\(long)/>"
                case "d":
                    hasDate = true
                    body += n >= 3 ? "<number:day-of-week\(n >= 4 ? " number:style=\"long\"" : "")/>" : "<number:day\(long)/>"
                case "h": body += "<number:hours\(long)/>"
                default: body += "<number:seconds\(long)/>"
                }
            }
        }
        let tag = hasDate ? "number:date-style" : "number:time-style"
        return "<\(tag) style:name=\"\(name)\">\(body)</\(tag)>"
    }

    // MARK: Reading

    /// The Excel-style code of a `number:*-style` element.
    static func code(from node: XMLNode) -> String? {
        switch node.name {
        case "number-style", "percentage-style", "currency-style": return numberCode(node)
        case "date-style", "time-style": return dateCode(node)
        default: return nil
        }
    }

    private static func literal(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return text.allSatisfy({ bareLiterals.contains($0) || $0 == "%" }) ? text : "\"" + text.replacingOccurrences(of: "\"", with: "") + "\""
    }

    private static func numberCode(_ node: XMLNode) -> String? {
        var code = ""
        var found = false
        for child in node.children {
            switch child.name {
            case "text": code += literal(child.allText)
            case "currency-symbol": code += literal(child.allText)
            case "number":
                found = true
                let decimals = child.attr("decimal-places").flatMap(Int.init) ?? 0
                let minimum = max(child.attr("min-integer-digits").flatMap(Int.init) ?? 1, 0)
                let grouped = child.attr("grouping") == "true"
                code += (grouped ? "#,##" + String(repeating: "0", count: max(minimum, 1)) : String(repeating: "0", count: minimum))
                if decimals > 0 { code += "." + String(repeating: "0", count: decimals) }
            case "scientific-number":
                found = true
                let decimals = child.attr("decimal-places").flatMap(Int.init) ?? 0
                let exponent = child.attr("min-exponent-digits").flatMap(Int.init) ?? 2
                code += "0" + (decimals > 0 ? "." + String(repeating: "0", count: decimals) : "") + "E+" + String(repeating: "0", count: max(exponent, 1))
            default: break
            }
        }
        return found ? code : nil
    }

    private static func dateCode(_ node: XMLNode) -> String? {
        var code = ""
        for child in node.children {
            let long = child.attr("style") == "long"
            switch child.name {
            case "text": code += literal(child.allText)
            case "year": code += long ? "yyyy" : "yy"
            case "month": code += child.attr("textual") == "true" ? (long ? "mmmm" : "mmm") : (long ? "mm" : "m")
            case "day": code += long ? "dd" : "d"
            case "day-of-week": code += long ? "dddd" : "ddd"
            case "hours": code += long ? "hh" : "h"
            case "minutes": code += long ? "mm" : "m"
            case "seconds": code += long ? "ss" : "s"
            case "am-pm": code += "AM/PM"
            default: break
            }
        }
        return code.isEmpty ? nil : code
    }

    private static func firstSection(_ code: String) -> String {
        var current = "", quoted = false, bracket = false, escaped = false
        for c in code {
            if escaped { current.append(c); escaped = false; continue }
            switch c {
            case "\\": escaped = true; current.append(c)
            case "\"": quoted.toggle(); current.append(c)
            case "[" where !quoted: bracket = true; current.append(c)
            case "]" where !quoted: bracket = false; current.append(c)
            case ";" where !quoted && !bracket: return current
            default: current.append(c)
            }
        }
        return current
    }
}
