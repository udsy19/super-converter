import Foundation

typealias MathList = [MathNode]

/// TeX's math styles: display, text, script, scriptscript (each also cramped).
enum StyleLevel: Int, Comparable, Sendable {
    case display, text, script, scriptScript
    static func < (a: StyleLevel, b: StyleLevel) -> Bool { a.rawValue < b.rawValue }
}

struct Atom {
    enum Nucleus {
        case char(Unicode.Scalar)
        case list(MathList)
        /// A named operator (`\sin`), set upright.
        case named(String)
        case empty
    }
    var type: AtomType
    var nucleus: Nucleus
    var sup: MathList?
    var sub: MathList?
    /// nil: the operator's default (limits in display style for ∑, never for ∫).
    var limits: Bool?
    var largeOp = false
    /// Set for operators whose default is limits in display style.
    var defaultLimits = false
}

struct MathArray {
    enum Kind { case matrix, smallMatrix, cases, aligned, gathered, array, substack }
    var kind: Kind
    var rows: [[MathList]]
    /// "l", "c" or "r" per column.
    var columns: [Character]
    var left: Unicode.Scalar?
    var right: Unicode.Scalar?
    /// Vertical rules after these column indices (array's `|`).
    var verticalRules: Set<Int> = []
}

indirect enum MathNode {
    case atom(Atom)
    case fraction(num: MathList, den: MathList, rule: Bool, left: Unicode.Scalar?, right: Unicode.Scalar?, style: StyleLevel?)
    case radical(degree: MathList?, body: MathList)
    case leftRight(left: Unicode.Scalar?, body: MathList, right: Unicode.Scalar?)
    case middle(Unicode.Scalar?)
    case accent(Unicode.Scalar, stretchy: Bool, body: MathList)
    case overline(MathList)
    case underline(MathList)
    case brace(MathList, over: Bool)
    case stack(over: MathList?, base: MathList, under: MathList?, type: AtomType)
    case space(Double, SpaceUnit)
    case style(StyleLevel)
    case text(String, bold: Bool, italic: Bool, mono: Bool)
    case array(MathArray)
    case sizedDelimiter(Unicode.Scalar?, size: Int, type: AtomType)
    case phantom(MathList, horizontal: Bool, vertical: Bool)
    case boxed(MathList)
    case error(String)
}

/// Parses the TeX math subset LaTeX documents use (amsmath included) into TeX's math list: atoms with nucleus,
/// superscript and subscript; fractions and binomials; radicals; `\left…\middle…\right`; accents; over/underlines and
/// braces; `\text`; math alphabets; matrices, `cases`, `aligned`, `gathered`, `array`; spacing and style commands.
/// Unknown commands become error nodes (set in red, as MathJax does) and are listed in `problems`.
struct MathParser {
    private let s: [Unicode.Scalar]
    private var i = 0
    private var alphabet: MathAlphabet? = nil
    private(set) var problems: [String] = []
    private(set) var tag: String?

    init(_ tex: String) { s = Array(tex.unicodeScalars) }

    static func parse(_ tex: String) -> (MathList, problems: [String], tag: String?) {
        // A top level with & or \\ (Markdown's `$$ a &= b \\ c &= d $$`) is an aligned block.
        var p = MathParser(needsAlignment(tex) ? "\\begin{aligned}" + tex + "\\end{aligned}" : tex)
        var list: MathList = []
        while !p.atEnd {
            list += p.parseList(stop: [])
            if p.peek() == "}" { p.i += 1 }
        }
        return (list, p.problems, p.tag)
    }

    private enum Stop: Hashable { case brace, right, end, ampersand, newline, bracket }

    private var atEnd: Bool { i >= s.count }
    private func peek(_ k: Int = 0) -> Unicode.Scalar? { i + k < s.count ? s[i + k] : nil }

    private mutating func skipSpace() { while let c = peek(), c.properties.isWhitespace { i += 1 } }

    /// The name after a backslash: letters, or one other character.
    private mutating func readCommandName() -> String {
        guard let c = peek() else { return "" }
        if c.properties.isAlphabetic && c.isASCII {
            var name = ""
            while let d = peek(), d.properties.isAlphabetic && d.isASCII { name.unicodeScalars.append(d); i += 1 }
            if peek() == "*" && ["operatorname", "tag"].contains(name) { i += 1; name += "*" }
            return name
        }
        i += 1
        return String(Character(c))
    }

    /// Parses until one of `stop` (not consumed, except `}` and `]`), or the end.
    private mutating func parseList(stop: Set<Stop>) -> MathList {
        var list: MathList = []
        var overSplit: (num: MathList, rule: Bool, left: Unicode.Scalar?, right: Unicode.Scalar?)? = nil
        while true {
            skipSpace()
            guard let c = peek() else { break }
            if c == "}" { if stop.contains(.brace) { i += 1 }; break }
            if c == "&" && stop.contains(.ampersand) { break }
            if c == "]" && stop.contains(.bracket) { i += 1; break }
            if c == "\\" {
                let save = i
                i += 1
                let name = readCommandName()
                if name == "\\" && stop.contains(.newline) { i = save; break }
                if name == "right" && stop.contains(.right) { i = save; break }
                if name == "end" && stop.contains(.end) { i = save; break }
                if name == "limits" || name == "nolimits" || name == "displaylimits" {
                    if case .atom(var a)? = list.last {
                        a.limits = name == "limits" ? true : name == "nolimits" ? false : nil
                        list[list.count - 1] = .atom(a)
                    }
                    continue
                }
                if ["over", "choose", "atop", "brack", "brace"].contains(name) {
                    let delims: (Unicode.Scalar?, Unicode.Scalar?) = name == "choose" ? ("(", ")") : name == "brack" ? ("[", "]")
                        : name == "brace" ? ("{", "}") : (nil, nil)
                    overSplit = (list, name == "over", delims.0, delims.1)
                    list = []
                    continue
                }
                i = save
            }
            if c == "^" || c == "_" || c == "'" {
                attachScript(to: &list)
                continue
            }
            if let node = parseAtom(stop: stop) { list.append(node) }
        }
        if let split = overSplit {
            return [.fraction(num: split.num, den: list, rule: split.rule, left: split.left, right: split.right, style: nil)]
        }
        return list
    }

    private mutating func attachScript(to list: inout MathList) {
        var atom: Atom
        if case .atom(let a)? = list.last { atom = a; list.removeLast() }
        else if let last = list.last { atom = Atom(type: .ord, nucleus: .list([last])); list.removeLast() }
        else { atom = Atom(type: .ord, nucleus: .empty) }
        while peek() == "'" {
            var primes = 0
            while peek() == "'" { primes += 1; i += 1 }
            let prime: Unicode.Scalar = primes == 1 ? "\u{2032}" : primes == 2 ? "\u{2033}" : primes == 3 ? "\u{2034}" : "\u{2057}"
            atom.sup = (atom.sup ?? []) + [.atom(Atom(type: .ord, nucleus: .char(prime)))]
            skipSpace()
            if peek() == "^" {
                i += 1
                atom.sup = (atom.sup ?? []) + parseArgument()
            }
        }
        skipSpace()
        while let c = peek(), c == "^" || c == "_" {
            i += 1
            let arg = parseArgument()
            if c == "^" {
                if atom.sup != nil { atom = Atom(type: .ord, nucleus: .list([.atom(atom)])) }
                atom.sup = arg
            } else {
                if atom.sub != nil { atom = Atom(type: .ord, nucleus: .list([.atom(atom)])) }
                atom.sub = arg
            }
            skipSpace()
            if peek() == "'" { break }
        }
        list.append(.atom(atom))
    }

    /// A macro argument: a braced group or one token.
    private mutating func parseArgument() -> MathList {
        skipSpace()
        guard let c = peek() else { return [] }
        if c == "{" { i += 1; return parseList(stop: [.brace]) }
        if let node = parseAtom(stop: []) { return [node] }
        return []
    }

    /// Raw text up to the matching brace (for `\text`, `\operatorname`, environment names).
    private mutating func rawGroup() -> String {
        skipSpace()
        guard peek() == "{" else {
            if let c = peek() { i += 1; return String(Character(c)) }
            return ""
        }
        i += 1
        var depth = 1
        var out = ""
        while let c = peek() {
            i += 1
            if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { break } }
            if c == "\\", let d = peek(), "{}$%&#_ ".unicodeScalars.contains(d) { out.unicodeScalars.append(d); i += 1; continue }
            out.unicodeScalars.append(c)
        }
        return out
    }

    private mutating func optionalBracket() -> MathList? {
        skipSpace()
        guard peek() == "[" else { return nil }
        i += 1
        return parseList(stop: [.bracket])
    }

    private mutating func delimiterToken() -> Unicode.Scalar? {
        skipSpace()
        guard let c = peek() else { return nil }
        if c == "\\" {
            i += 1
            let name = readCommandName()
            if case .delimiter(let d, _)? = MathSymbols.table[name] { return d }
            if case .symbol(let d, _)? = MathSymbols.table[name] { return d }
            problems.append("\\" + name)
            return nil
        }
        i += 1
        if c == "." { return nil }
        if c == "<" { return "\u{27E8}" }
        if c == ">" { return "\u{27E9}" }
        return c
    }

    private func mapped(_ c: Unicode.Scalar) -> Unicode.Scalar {
        if let a = alphabet { return a.map(c) }
        return MathAlphabet.italic.map(c)
    }

    private mutating func parseAtom(stop: Set<Stop>) -> MathNode? {
        guard let c = peek() else { return nil }
        if c == "{" {
            i += 1
            return .atom(Atom(type: .ord, nucleus: .list(parseList(stop: [.brace]))))
        }
        if c == "\\" {
            i += 1
            return parseCommand(readCommandName(), stop: stop)
        }
        i += 1
        if c == "~" { return .space(1.0 / 3, .em) }
        if c == "$" || c == "&" || c == "#" { return nil }
        let isLetter = c.properties.isAlphabetic && (c.isASCII || (0x391...0x3C9).contains(c.value))
        if isLetter || ((0x30...0x39).contains(c.value) && alphabet != nil) {
            return .atom(Atom(type: .ord, nucleus: .char(mapped(c))))
        }
        let (ch, type) = MathSymbols.classify(c)
        if type == .op { return .atom(Atom(type: .op, nucleus: .char(ch), largeOp: true, defaultLimits: c.value == 0x2211 || c.value == 0x220F)) }
        return .atom(Atom(type: type, nucleus: .char(ch)))
    }

    private mutating func parseCommand(_ name: String, stop: Set<Stop>) -> MathNode? {
        switch name {
        case "frac", "dfrac", "tfrac", "cfrac", "binom", "dbinom", "tbinom":
            let num = parseArgument(), den = parseArgument()
            let style: StyleLevel? = ["dfrac", "cfrac", "dbinom"].contains(name) ? .display : ["tfrac", "tbinom"].contains(name) ? .text : nil
            let binom = name.hasSuffix("binom")
            return .fraction(num: num, den: den, rule: !binom, left: binom ? "(" : nil, right: binom ? ")" : nil, style: style)
        case "sqrt":
            let degree = optionalBracket()
            return .radical(degree: degree, body: parseArgument())
        case "left":
            let l = delimiterToken()
            let body = parseList(stop: [.right])
            var r: Unicode.Scalar? = nil
            if peek() == "\\" { i += 1; _ = readCommandName(); r = delimiterToken() }
            return .leftRight(left: l, body: body, right: r)
        case "middle":
            return .middle(delimiterToken())
        case "right":
            _ = delimiterToken()
            return nil
        case "big", "Big", "bigg", "Bigg", "bigl", "Bigl", "biggl", "Biggl", "bigr", "Bigr", "biggr", "Biggr", "bigm", "Bigm", "biggm", "Biggm":
            let size = name.hasPrefix("Bigg") ? 4 : name.hasPrefix("bigg") ? 3 : name.hasPrefix("Big") ? 2 : 1
            let type: AtomType = name.hasSuffix("l") ? .open : name.hasSuffix("r") ? .close : name.hasSuffix("m") ? .rel : .ord
            return .sizedDelimiter(delimiterToken(), size: size, type: type)
        case "text", "textrm", "textup", "textnormal", "mbox", "hbox", "textbf", "textit", "textsf", "texttt", "emph", "textmd":
            let t = rawGroup()
            return .text(t, bold: name == "textbf", italic: name == "textit" || name == "emph", mono: name == "texttt")
        case "operatorname", "operatorname*":
            return .atom(Atom(type: .op, nucleus: .named(rawGroup()), defaultLimits: name.hasSuffix("*")))
        case "mathop", "mathbin", "mathrel", "mathord", "mathopen", "mathclose", "mathpunct", "mathinner":
            let types: [String: AtomType] = ["mathop": .op, "mathbin": .bin, "mathrel": .rel, "mathord": .ord,
                                             "mathopen": .open, "mathclose": .close, "mathpunct": .punct, "mathinner": .inner]
            return .atom(Atom(type: types[name]!, nucleus: .list(parseArgument()), defaultLimits: name == "mathop"))
        case "displaystyle": return .style(.display)
        case "textstyle": return .style(.text)
        case "scriptstyle": return .style(.script)
        case "scriptscriptstyle": return .style(.scriptScript)
        case "overline": return .overline(parseArgument())
        case "underline": return .underline(parseArgument())
        case "overbrace": return .brace(parseArgument(), over: true)
        case "underbrace": return .brace(parseArgument(), over: false)
        case "overset", "stackrel":
            let over = parseArgument(), base = parseArgument()
            return .stack(over: over, base: base, under: nil, type: name == "stackrel" ? .rel : .ord)
        case "underset":
            let under = parseArgument(), base = parseArgument()
            return .stack(over: nil, base: base, under: under, type: .ord)
        case "phantom": return .phantom(parseArgument(), horizontal: true, vertical: true)
        case "hphantom": return .phantom(parseArgument(), horizontal: true, vertical: false)
        case "vphantom": return .phantom(parseArgument(), horizontal: false, vertical: true)
        case "boxed", "fbox": return .boxed(parseArgument())
        case "color":
            _ = rawGroup()
            return nil
        case "textcolor", "colorbox":
            _ = rawGroup()
            return .atom(Atom(type: .ord, nucleus: .list(parseArgument())))
        case "tag", "tag*":
            let t = rawGroup()
            tag = name == "tag*" ? t : "(\(t))"
            return nil
        case "label":
            _ = rawGroup()
            return nil
        case "ref", "eqref":
            let t = rawGroup()
            return .text(name == "eqref" ? "(\(t))" : t, bold: false, italic: false, mono: false)
        case "nonumber", "notag", "allowbreak", "nobreak", "relax", "strut", "mathstrut", "displaybreak", "noindent":
            return nil
        case "hspace", "kern", "mkern", "hskip", "mskip":
            return parseSpace(peek() == "{" ? rawGroup() : readDimension())
        case "not":
            skipSpace()
            if let next = parseAtom(stop: stop), case .atom(var a) = next, case .char(let c) = a.nucleus {
                let negated: [UInt32: UInt32] = [0x3D: 0x2260, 0x2208: 0x2209, 0x2282: 0x2284, 0x2283: 0x2285, 0x2286: 0x2288,
                                                  0x2287: 0x2289, 0x3C: 0x226E, 0x3E: 0x226F, 0x2264: 0x2270, 0x2265: 0x2271,
                                                  0x2261: 0x2262, 0x223C: 0x2241, 0x2248: 0x2249, 0x2245: 0x2247, 0x2223: 0x2224,
                                                  0x2225: 0x2226, 0x220B: 0x220C]
                if let n = negated[c.value], let u = Unicode.Scalar(n) { a.nucleus = .char(u); return .atom(a) }
                return .stack(over: nil, base: [.atom(a), .atom(Atom(type: .ord, nucleus: .char("\u{0338}")))], under: nil, type: .rel)
            }
            return nil
        case "pmod":
            let arg = parseArgument()
            return .atom(Atom(type: .ord, nucleus: .list([.space(1, .em), .atom(Atom(type: .open, nucleus: .char("("))),
                                                          .atom(Atom(type: .ord, nucleus: .named("mod"))), .space(6, .mu)] + arg
                                                        + [.atom(Atom(type: .close, nucleus: .char(")")))])))
        case "bmod":
            return .atom(Atom(type: .bin, nucleus: .named("mod")))
        case "mod":
            return .atom(Atom(type: .ord, nucleus: .list([.space(1, .em), .atom(Atom(type: .ord, nucleus: .named("mod"))), .space(6, .mu)])))
        case "begin":
            return parseEnvironment(rawGroup())
        case "substack":
            skipSpace()
            guard peek() == "{" else { return nil }
            i += 1
            var rows: [[MathList]] = []
            while true {
                rows.append([parseList(stop: [.newline, .brace])])
                if peek() == "\\" && peek(1) == "\\" { i += 2; continue }
                break
            }
            return .array(MathArray(kind: .substack, rows: rows, columns: ["c"], left: nil, right: nil))
        case "{", "}", "|", "lbrace", "rbrace":
            if case .delimiter(let d, let t)? = MathSymbols.table[name] { return .atom(Atom(type: t, nucleus: .char(d))) }
            return nil
        case "#", "$", "%", "&", "_":
            return .atom(Atom(type: .ord, nucleus: .char(Unicode.Scalar(name)!)))
        case "\\":
            return nil
        default:
            break
        }
        guard let info = MathSymbols.table[name] else {
            problems.append("\\" + name)
            return .error("\\" + name)
        }
        switch info {
        case .symbol(let c, let type):
            let lowerGreek = (0x3B1...0x3C9).contains(c.value) || [0x3F5, 0x3D1, 0x3D5, 0x3F1, 0x3D6, 0x3F0, 0x2202].contains(c.value)
            let upperGreek = (0x391...0x3A9).contains(c.value)
            var ch = c
            if let a = alphabet, upperGreek || lowerGreek { ch = a.map(c) } else if lowerGreek { ch = MathAlphabet.italic.map(c) }
            return .atom(Atom(type: type, nucleus: .char(ch)))
        case .largeOp(let c, let limits):
            return .atom(Atom(type: .op, nucleus: .char(c), largeOp: true, defaultLimits: limits))
        case .namedOp(let text, let limits):
            return .atom(Atom(type: .op, nucleus: .named(text), defaultLimits: limits))
        case .delimiter(let c, let type):
            return .atom(Atom(type: type, nucleus: .char(c)))
        case .accent(let c, let stretchy):
            return .accent(c, stretchy: stretchy, body: parseArgument())
        case .space(let v, let unit):
            return .space(v, unit)
        case .alphabet(let a):
            let saved = alphabet
            alphabet = a
            let arg = parseArgument()
            alphabet = saved
            return .atom(Atom(type: .ord, nucleus: .list(arg)))
        }
    }

    private mutating func readDimension() -> String {
        skipSpace()
        var out = ""
        while let c = peek(), c.properties.isAlphabetic || "0123456789.-+".unicodeScalars.contains(c) {
            out.unicodeScalars.append(c); i += 1
            if out.count > 2, ["pt", "em", "ex", "mu", "mm", "cm", "in", "bp"].contains(where: out.hasSuffix) { break }
        }
        return out
    }

    private func parseSpace(_ text: String) -> MathNode? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let units: [(String, Double, SpaceUnit)] = [("em", 1, .em), ("ex", 0.43, .em), ("mu", 1, .mu), ("pt", 0.1, .em),
                                                   ("bp", 0.1004, .em), ("mm", 0.2845, .em), ("cm", 2.845, .em), ("in", 7.227, .em)]
        for (suffix, factor, unit) in units where t.hasSuffix(suffix) {
            if let v = Double(t.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) { return .space(v * factor, unit) }
        }
        return nil
    }

    private mutating func parseEnvironment(_ env: String) -> MathNode? {
        let name = env.replacingOccurrences(of: "*", with: "")
        var columns: [Character] = []
        var rules: Set<Int> = []
        if name == "array" || name == "subarray" {
            for c in rawGroup() {
                if "lcr".contains(c) { columns.append(c) } else if c == "|" { rules.insert(columns.count - 1) }
            }
        }
        if name == "alignat" || name == "alignedat" { _ = rawGroup() }
        var rows: [[MathList]] = []
        var row: [MathList] = []
        while !atEnd {
            row.append(parseList(stop: [.ampersand, .newline, .end]))
            skipSpace()
            if peek() == "&" { i += 1; continue }
            if peek() == "\\" && peek(1) == "\\" {
                i += 2
                _ = optionalBracket()
                rows.append(row); row = []
                continue
            }
            if peek() == "\\" {
                i += 1
                _ = readCommandName()   // end
                _ = rawGroup()
            }
            break
        }
        if !(row.count == 1 && row[0].isEmpty) || rows.isEmpty { rows.append(row) }
        let kind: MathArray.Kind
        var left: Unicode.Scalar? = nil, right: Unicode.Scalar? = nil
        switch name {
        case "matrix": kind = .matrix
        case "pmatrix": kind = .matrix; left = "("; right = ")"
        case "bmatrix": kind = .matrix; left = "["; right = "]"
        case "Bmatrix": kind = .matrix; left = "{"; right = "}"
        case "vmatrix": kind = .matrix; left = "|"; right = "|"
        case "Vmatrix": kind = .matrix; left = "\u{2016}"; right = "\u{2016}"
        case "smallmatrix": kind = .smallMatrix
        case "cases", "dcases": kind = .cases; left = "{"
        case "rcases": kind = .cases; right = "}"
        case "aligned", "align", "alignat", "alignedat", "split", "eqnarray", "flalign", "multline":
            kind = .aligned
        case "gathered", "gather", "equation", "displaymath", "math":
            kind = .gathered
        case "array", "subarray": kind = .array
        default:
            problems.append("\\begin{\(env)}")
            kind = .matrix
        }
        if ["equation", "displaymath", "math"].contains(name), rows.count == 1, rows[0].count == 1 {
            return .atom(Atom(type: .ord, nucleus: .list(rows[0][0])))
        }
        let count = rows.map(\.count).max() ?? 1
        switch kind {
        case .aligned: columns = (0..<count).map { $0 % 2 == 0 ? "r" : "l" }
        case .cases: columns = (0..<count).map { _ in "l" }
        default: if columns.isEmpty { columns = (0..<count).map { _ in "c" } }
        }
        return .array(MathArray(kind: kind, rows: rows, columns: columns, left: left, right: right, verticalRules: rules))
    }

    /// True when a top-level formula has alignment points or line breaks outside any group or environment.
    static func needsAlignment(_ tex: String) -> Bool {
        let chars = Array(tex)
        var depth = 0, env = 0
        var k = 0
        while k < chars.count {
            let c = chars[k]
            if c == "\\" {
                let rest = String(chars[(k + 1)...].prefix(5))
                if rest.hasPrefix("begin") { env += 1 }
                if rest.hasPrefix("end") { env -= 1 }
                if depth == 0 && env == 0 && rest.hasPrefix("\\") { return true }
                k += 2
                continue
            }
            if c == "{" { depth += 1 }
            if c == "}" { depth -= 1 }
            if c == "&" && depth == 0 && env == 0 { return true }
            k += 1
        }
        return false
    }
}
