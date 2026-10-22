import Foundation

/// TeX math ↔ `MathNode`: the subset that articles use (fractions, roots, scripts, big operators, delimiters, matrices,
/// accents, text, Greek and the usual symbols). What the parser does not know is kept as `.raw`, so TeX → TeX never loses it.
enum TeX {
    static func parse(_ source: String) -> MathNode {
        var parser = Parser(Array(source))
        let row = parser.parseRow(until: { _ in false })
        return MathNode.make(row)
    }

    // MARK: Parsing

    private struct Parser {
        let chars: [Character]
        var i = 0

        init(_ chars: [Character]) { self.chars = chars }

        var atEnd: Bool { i >= chars.count }

        mutating func skipSpaces() { while i < chars.count, chars[i] == " " || chars[i] == "\n" || chars[i] == "\t" { i += 1 } }

        /// Parses atoms until the end, a closing `}` / `&` / `\\` / `\right` / `\end` the caller handles (not consumed).
        mutating func parseRow(until stop: (inout Parser) -> Bool) -> [MathNode] {
            var out: [MathNode] = []
            while true {
                skipSpaces()
                if atEnd || chars[i] == "}" || chars[i] == "&" || stop(&self) { break }
                if chars[i] == "\\" {
                    if i + 1 < chars.count, chars[i + 1] == "\\" { break }
                    if lookingAt("\\right") || lookingAt("\\end") { break }
                }
                guard var atom = parseAtom() else { break }
                atom = parseScripts(atom)
                out.append(atom)
            }
            return out
        }

        func lookingAt(_ s: String) -> Bool {
            let target = Array(s)
            guard i + target.count <= chars.count, Array(chars[i..<i + target.count]) == target else { return false }
            // A command name ends at a non-letter.
            if target.count > 1, target[0] == "\\", let last = target.last, last.isLetter,
               i + target.count < chars.count, chars[i + target.count].isLetter { return false }
            return true
        }

        mutating func parseScripts(_ base: MathNode) -> MathNode {
            var sub: MathNode?, sup: MathNode?
            while true {
                skipSpaces()
                guard !atEnd else { break }
                if chars[i] == "_", sub == nil { i += 1; sub = parseArgument() }
                else if chars[i] == "^", sup == nil { i += 1; sup = parseArgument() }
                else if chars[i] == "'", sup == nil {
                    var primes = ""
                    while !atEnd, chars[i] == "'" { primes += "′"; i += 1 }
                    sup = .op(primes)
                } else { break }
            }
            switch (sub, sup) {
            case (let s?, let p?): return .subsup(base, s, p)
            case (let s?, nil): return .sub(base, s)
            case (nil, let p?): return .sup(base, p)
            default: return base
            }
        }

        /// One argument: a `{group}` or a single atom.
        mutating func parseArgument() -> MathNode {
            skipSpaces()
            guard !atEnd else { return .row([]) }
            if chars[i] == "{" {
                i += 1
                let row = parseRow(until: { _ in false })
                if !atEnd, chars[i] == "}" { i += 1 }
                return MathNode.make(row)
            }
            return parseAtom() ?? .row([])
        }

        /// Raw text of a `{…}` group (for `\text`), braces balanced.
        mutating func parseRawGroup() -> String {
            skipSpaces()
            guard !atEnd, chars[i] == "{" else { return "" }
            var depth = 0
            var text = ""
            while !atEnd {
                let c = chars[i]; i += 1
                if c == "{" { depth += 1; if depth == 1 { continue } }
                if c == "}" { depth -= 1; if depth == 0 { break } }
                text.append(c)
            }
            return text
        }

        mutating func parseAtom() -> MathNode? {
            guard !atEnd else { return nil }
            let c = chars[i]
            switch c {
            case "{":
                i += 1
                let row = parseRow(until: { _ in false })
                if !atEnd, chars[i] == "}" { i += 1 }
                return MathNode.make(row)
            case "\\": return parseCommand()
            case "^", "_": i += 1; return .row([])   // a script with no base
            case "~": i += 1; return .space("~")
            default:
                if c.isNumber || (c == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                    var digits = ""
                    while !atEnd, chars[i].isNumber || (chars[i] == "." && i + 1 < chars.count && chars[i + 1].isNumber) { digits.append(chars[i]); i += 1 }
                    return .number(digits)
                }
                i += 1
                if c.isLetter { return .ident(String(c)) }
                return .op(String(c))
            }
        }

        mutating func readName() -> String {
            var name = ""
            while !atEnd, chars[i].isLetter, chars[i].isASCII { name.append(chars[i]); i += 1 }
            return name
        }

        mutating func delimiter() -> String {
            skipSpaces()
            guard !atEnd else { return "" }
            if chars[i] == "\\" {
                i += 1
                if atEnd { return "" }
                if chars[i].isLetter {
                    let name = readName()
                    return MathSymbols.symbols[name] ?? (name == "vert" ? "|" : name == "Vert" ? "‖" : "")
                }
                let c = chars[i]; i += 1
                return c == "|" ? "‖" : String(c)
            }
            let c = chars[i]; i += 1
            return c == "." ? "" : String(c)
        }

        mutating func parseCommand() -> MathNode? {
            let start = i
            i += 1   // backslash
            guard !atEnd else { return .op("\\") }
            if !chars[i].isLetter {
                let c = chars[i]; i += 1
                switch c {
                case ",", ";", ":", "!", " ", ">": return .space("\\" + String(c))
                case "{", "}", "%", "$", "&", "#", "_": return .op(String(c))
                case "|": return .op("‖")
                default: return .raw("\\" + String(c))
                }
            }
            let name = readName()
            switch name {
            case "frac", "dfrac", "tfrac":
                let a = parseArgument(), b = parseArgument()
                return .frac(a, b)
            case "sqrt":
                skipSpaces()
                var index: MathNode?
                if !atEnd, chars[i] == "[" {
                    i += 1
                    var inner = ""
                    while !atEnd, chars[i] != "]" { inner.append(chars[i]); i += 1 }
                    if !atEnd { i += 1 }
                    index = TeX.parse(inner)
                }
                return .sqrt(parseArgument(), index: index)
            case "left":
                let open = delimiter()
                let body = parseRow(until: { _ in false })
                var close = ""
                if lookingAt("\\right") { i += 6; close = delimiter() }
                return MathNode.fence(open: open, close: close, MathNode.make(body))
            case "begin":
                return parseEnvironment()
            case "text", "mbox", "textrm", "mathrm", "operatorname", "textit", "textbf":
                skipSpaces()
                if name == "mathrm", !atEnd, chars[i] != "{" { return parseAtom() }
                let raw = parseRawGroup()
                if name == "operatorname" { return .function(raw) }
                return .text(raw)
            case "mathbf", "mathit", "mathcal", "mathbb", "mathsf", "mathtt", "boldsymbol", "bm", "mathfrak", "displaystyle", "textstyle":
                return name == "displaystyle" || name == "textstyle" ? .row([]) : parseArgument()
            case "quad": return .space("\\quad")
            case "qquad": return .space("\\qquad")
            case "limits", "nolimits": return .row([])
            default:
                if let accent = MathSymbols.accents[name] { return .accent(parseArgument(), accent) }
                if MathSymbols.functions.contains(name) { return .function(name) }
                if let g = MathSymbols.greek[name] { return .ident(g) }
                if let s = MathSymbols.symbols[name] { return .op(s) }
                if name == "vert" { return .op("|") }
                if name == "Vert" { return .op("‖") }
                return .raw(String(chars[start..<i]))
            }
        }

        mutating func parseEnvironment() -> MathNode {
            let environment = parseRawGroup()
            var rows: [[MathNode]] = [[]]
            while true {
                let cell = parseRow(until: { _ in false })
                rows[rows.count - 1].append(MathNode.make(cell))
                skipSpaces()
                if atEnd { break }
                if chars[i] == "&" { i += 1; continue }
                if lookingAt("\\\\") { i += 2; rows.append([]); continue }
                if lookingAt("\\end") {
                    i += 4
                    _ = parseRawGroup()
                    break
                }
                if chars[i] == "}" { i += 1; continue }
                break
            }
            if rows.last?.count == 1, rows.last?.first?.isEmpty == true, rows.count > 1 { rows.removeLast() }
            let (open, close): (String, String) = switch environment {
            case "pmatrix": ("(", ")")
            case "bmatrix": ("[", "]")
            case "Bmatrix": ("{", "}")
            case "vmatrix": ("|", "|")
            case "Vmatrix": ("‖", "‖")
            case "cases": ("{", "")
            default: ("", "")
            }
            return .matrix(rows, open: open, close: close)
        }
    }

    // MARK: Emitting

    static func emit(_ node: MathNode) -> String {
        var out = ""
        append(node, to: &out)
        return out
    }

    private static func append(_ piece: String, to out: inout String) {
        // `\alpha` followed by a letter would read as `\alphax`.
        if let first = piece.first, first.isLetter, let backslash = out.lastIndex(of: "\\"),
           out[out.index(after: backslash)...].allSatisfy({ $0.isLetter && $0.isASCII }), !out[out.index(after: backslash)...].isEmpty {
            out += " "
        }
        out += piece
    }

    private static func append(_ node: MathNode, to out: inout String) {
        switch node {
        case .row(let children): for child in children { append(child, to: &out) }
        case .ident(let s): append(MathSymbols.greekByChar[s].map { "\\" + $0 } ?? s, to: &out)
        case .number(let s): append(s, to: &out)
        case .op(let s):
            if let name = MathSymbols.symbolByChar[s] { append("\\" + name, to: &out) }
            else if let name = MathSymbols.greekByChar[s] { append("\\" + name, to: &out) }
            else if s == "‖" { append("\\|", to: &out) }
            else if "{}%$&#_".contains(s) { append("\\" + s, to: &out) }
            else { append(s, to: &out) }
        case .text(let s): append("\\text{\(s)}", to: &out)
        case .function(let s): append(MathSymbols.functions.contains(s) ? "\\" + s : "\\operatorname{\(s)}", to: &out)
        case .frac(let a, let b): append("\\frac{\(emit(a))}{\(emit(b))}", to: &out)
        case .sqrt(let a, let index): append(index.map { "\\sqrt[\(emit($0))]{\(emit(a))}" } ?? "\\sqrt{\(emit(a))}", to: &out)
        case .sup(let b, let p): append(emit(b) + "^" + argument(p), to: &out)
        case .sub(let b, let s): append(emit(b) + "_" + argument(s), to: &out)
        case .subsup(let b, let s, let p): append(emit(b) + "_" + argument(s) + "^" + argument(p), to: &out)
        case .fenced(let open, let close, let body):
            append("\\left" + delimiter(open) + emit(body) + "\\right" + delimiter(close), to: &out)
        case .matrix(let rows, let open, let close):
            let environment: String = switch (open, close) {
            case ("(", ")"): "pmatrix"
            case ("[", "]"): "bmatrix"
            case ("{", "}"): "Bmatrix"
            case ("|", "|"): "vmatrix"
            case ("‖", "‖"): "Vmatrix"
            case ("{", ""): "cases"
            default: "matrix"
            }
            let body = rows.map { $0.map(emit).joined(separator: " & ") }.joined(separator: " \\\\ ")
            append("\\begin{\(environment)} \(body) \\end{\(environment)}", to: &out)
        case .accent(let base, let mark): append("\\" + (MathSymbols.accentByChar[mark] ?? "hat") + "{\(emit(base))}", to: &out)
        case .space(let s): append(s, to: &out)
        case .raw(let s): append(s, to: &out)
        }
    }

    private static func argument(_ node: MathNode) -> String {
        switch node {
        case .ident(let s) where s.count == 1 && s.first!.isASCII: return s
        case .number(let s) where s.count == 1: return s
        case .op(let s) where s.count == 1 && s.first!.isASCII && !"{}%$&#_".contains(s): return s
        default: return "{" + emit(node) + "}"
        }
    }

    private static func delimiter(_ d: String) -> String {
        switch d {
        case "": "."
        case "{", "}": "\\" + d
        case "‖": "\\|"
        case "⟨": "\\langle"
        case "⟩": "\\rangle"
        case "⌊": "\\lfloor"
        case "⌋": "\\rfloor"
        case "⌈": "\\lceil"
        case "⌉": "\\rceil"
        default: d
        }
    }
}
