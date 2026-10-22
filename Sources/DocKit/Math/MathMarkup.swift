import Foundation

/// MathML and OMML ↔ `MathNode`. MathML written here carries the TeX in an `annotation`, so reading it back is exact; other
/// MathML and Word's OMML are read structurally.
enum MathML {
    // MARK: Reading

    /// TeX for a `<math>` element: the TeX annotation when there is one, else the structure.
    static func tex(_ math: XMLNode) -> String {
        if let annotation = math.all("annotation").first(where: { $0.attr("encoding")?.lowercased().contains("tex") == true }) {
            return annotation.allText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return TeX.emit(node(math))
    }

    static func node(_ element: XMLNode) -> MathNode {
        let kids = element.children
        func arg(_ i: Int) -> MathNode { i < kids.count ? node(kids[i]) : .row([]) }
        switch element.name {
        case "math", "mrow", "mstyle", "mpadded", "mphantom", "merror", "mtd":
            if element.name == "mrow", kids.count >= 2, let open = kids.first, let close = kids.last, open.name == "mo", close.name == "mo",
               open.attr("stretchy") == "true", close.attr("stretchy") == "true" {
                let inner = kids.dropFirst().dropLast().map(node)
                return MathNode.fence(open: open.allText.trimmed, close: close.allText.trimmed, MathNode.make(inner))
            }
            return MathNode.make(kids.map(node))
        case "semantics": return kids.first.map(node) ?? .row([])
        case "annotation", "annotation-xml": return .row([])
        case "mi":
            let t = element.allText.trimmed
            if MathSymbols.functions.contains(t) { return .function(t) }
            if t.count == 1 { return .ident(t) }
            return MathNode.make(t.map { .ident(String($0)) })
        case "mn": return .number(element.allText.trimmed)
        case "mo":
            let t = element.allText.trimmed
            return .op(t == "−" ? "-" : t)
        case "mtext": return .text(element.allText)
        case "mspace": return .space("\\,")
        case "mfrac": return .frac(arg(0), arg(1))
        case "msqrt": return .sqrt(MathNode.make(kids.map(node)), index: nil)
        case "mroot": return .sqrt(arg(0), index: arg(1))
        case "msup": return .sup(arg(0), arg(1))
        case "msub": return .sub(arg(0), arg(1))
        case "msubsup", "munderover": return .subsup(arg(0), arg(1), arg(2))
        case "munder": return .sub(arg(0), arg(1))
        case "mover":
            if element.attr("accent") == "true", case .op(let mark) = arg(1) { return .accent(arg(0), mark == "‾" ? "¯" : mark) }
            return .sup(arg(0), arg(1))
        case "mfenced":
            let open = element.attr("open") ?? "(", close = element.attr("close") ?? ")"
            return MathNode.fence(open: open, close: close, MathNode.make(kids.map(node)))
        case "mtable":
            let rows = kids.map { $0.children.map(node) }
            return .matrix(rows, open: "", close: "")
        default: return MathNode.make(kids.map(node))
        }
    }

    // MARK: Writing

    /// A `<math>` element as a string; `tex` rides along as the annotation.
    static func write(tex source: String, display: Bool) -> String {
        let body = markup(TeX.parse(source), display: display)
        return "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"\(display ? " display=\"block\"" : "")><semantics><mrow>\(body)</mrow>"
            + "<annotation encoding=\"application/x-tex\">\(XML.escape(source))</annotation></semantics></math>"
    }

    private static func markup(_ node: MathNode, display: Bool) -> String {
        func m(_ n: MathNode) -> String { markup(n, display: display) }
        func wrap(_ n: MathNode) -> String { "<mrow>\(m(n))</mrow>" }
        switch node {
        case .row(let c): return c.map(m).joined()
        case .ident(let s): return "<mi>\(XML.escape(s))</mi>"
        case .number(let s): return "<mn>\(XML.escape(s))</mn>"
        case .op(let s): return "<mo>\(XML.escape(s == "-" ? "−" : s))</mo>"
        case .text(let s): return "<mtext>\(XML.escape(s))</mtext>"
        case .function(let s): return "<mi mathvariant=\"normal\">\(XML.escape(s))</mi>"
        case .frac(let a, let b): return "<mfrac>\(wrap(a))\(wrap(b))</mfrac>"
        case .sqrt(let a, let index): return index.map { "<mroot>\(wrap(a))\(wrap($0))</mroot>" } ?? "<msqrt>\(m(a))</msqrt>"
        case .sup(let b, let p): return limits(b) ? "<mover>\(wrap(b))\(wrap(p))</mover>" : "<msup>\(wrap(b))\(wrap(p))</msup>"
        case .sub(let b, let s): return limits(b) ? "<munder>\(wrap(b))\(wrap(s))</munder>" : "<msub>\(wrap(b))\(wrap(s))</msub>"
        case .subsup(let b, let s, let p):
            return limits(b) ? "<munderover>\(wrap(b))\(wrap(s))\(wrap(p))</munderover>" : "<msubsup>\(wrap(b))\(wrap(s))\(wrap(p))</msubsup>"
        case .fenced(let open, let close, let body):
            let o = open.isEmpty ? "" : "<mo stretchy=\"true\">\(XML.escape(open))</mo>"
            let c = close.isEmpty ? "" : "<mo stretchy=\"true\">\(XML.escape(close))</mo>"
            return "<mrow>\(o)\(m(body))\(c)</mrow>"
        case .matrix(let rows, let open, let close):
            let table = "<mtable>" + rows.map { "<mtr>" + $0.map { "<mtd>\(m($0))</mtd>" }.joined() + "</mtr>" }.joined() + "</mtable>"
            if open.isEmpty && close.isEmpty { return table }
            let o = open.isEmpty ? "" : "<mo stretchy=\"true\">\(XML.escape(open))</mo>"
            let c = close.isEmpty ? "" : "<mo stretchy=\"true\">\(XML.escape(close))</mo>"
            return "<mrow>\(o)\(table)\(c)</mrow>"
        case .accent(let base, let mark): return "<mover accent=\"true\">\(wrap(base))<mo>\(XML.escape(mark))</mo></mover>"
        case .space: return "<mspace width=\"0.17em\"/>"
        case .raw(let s): return "<mtext>\(XML.escape(s))</mtext>"
        }
    }

    private static func limits(_ base: MathNode) -> Bool {
        if case .op(let s) = base { return MathSymbols.nary.contains(s) && s != "∫" }
        if case .function(let f) = base { return f == "lim" || f == "max" || f == "min" }
        return false
    }
}

enum OMML {
    // MARK: Reading

    /// TeX for an `m:oMath` element.
    static func tex(_ math: XMLNode) -> String { TeX.emit(MathNode.make(nodes(math))) }

    private static func children(_ element: XMLNode, _ local: String) -> MathNode {
        MathNode.make(element.child(local)?.children.flatMap(nodes) ?? [])
    }

    private static func nodes(_ element: XMLNode) -> [MathNode] {
        switch element.name {
        case "r":
            let text = element.children("t").map(\.allText).joined()
            let upright = element.child("rPr")?.child("sty")?.attr("val") == "p"
            if element.child("rPr")?.child("nor") != nil { return [.text(text)] }
            return runNodes(text, upright: upright)
        case "f": return [.frac(children(element, "num"), children(element, "den"))]
        case "rad":
            let hidden = element.child("radPr")?.child("degHide")?.attr("val").map { $0 != "0" && $0 != "false" } ?? false
            let degree = children(element, "deg")
            return [.sqrt(children(element, "e"), index: hidden || degree.isEmpty ? nil : degree)]
        case "sSup": return [.sup(children(element, "e"), children(element, "sup"))]
        case "sSub": return [.sub(children(element, "e"), children(element, "sub"))]
        case "sSubSup": return [.subsup(children(element, "e"), children(element, "sub"), children(element, "sup"))]
        case "nary":
            let chr = element.child("naryPr")?.child("chr")?.attr("val") ?? "∫"
            let sub = children(element, "sub"), sup = children(element, "sup")
            let base = MathNode.op(chr)
            let head: MathNode = switch (sub.isEmpty, sup.isEmpty) {
            case (false, false): .subsup(base, sub, sup)
            case (false, true): .sub(base, sub)
            case (true, false): .sup(base, sup)
            default: base
            }
            return [head] + children(element, "e").items
        case "d":
            let pr = element.child("dPr")
            let open = pr?.child("begChr")?.attr("val") ?? "(", close = pr?.child("endChr")?.attr("val") ?? ")"
            let separator = pr?.child("sepChr")?.attr("val") ?? "|"
            let parts = element.children("e").map { MathNode.make($0.children.flatMap(nodes)) }
            var body: [MathNode] = []
            for (i, part) in parts.enumerated() { if i > 0 { body.append(.op(separator)) }; body += part.items }
            return [MathNode.fence(open: open, close: close, MathNode.make(body))]
        case "m":
            let rows = element.children("mr").map { $0.children("e").map { MathNode.make($0.children.flatMap(nodes)) } }
            return [.matrix(rows, open: "", close: "")]
        case "eqArr":
            let rows = element.children("e").map { [MathNode.make($0.children.flatMap(nodes))] }
            return [.matrix(rows, open: "", close: "")]
        case "acc":
            return [.accent(children(element, "e"), element.child("accPr")?.child("chr")?.attr("val") ?? "^")]
        case "func":
            let name = children(element, "fName")
            let fn: MathNode = if case .function = name { name } else if case .row(let c) = name, c.count == 1 { c[0] } else { name }
            return [fn] + children(element, "e").items
        case "limLow": return [.sub(children(element, "e"), children(element, "lim"))]
        case "limUpp": return [.sup(children(element, "e"), children(element, "lim"))]
        case "bar": return [.accent(children(element, "e"), "¯")]
        case "oMath", "oMathPara", "e", "num", "den", "sub", "sup", "deg", "lim", "fName": return element.children.flatMap(nodes)
        default: return []
        }
    }

    private static func runNodes(_ text: String, upright: Bool) -> [MathNode] {
        var out: [MathNode] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c.isLetter, c.isASCII {
                var word = ""
                var j = i
                while j < chars.count, chars[j].isLetter, chars[j].isASCII { word.append(chars[j]); j += 1 }
                if MathSymbols.functions.contains(word) || (upright && word.count > 1) {
                    out.append(.function(word)); i = j; continue
                }
                out.append(.ident(String(c))); i += 1
            } else if c.isNumber || c == "." && i + 1 < chars.count && chars[i + 1].isNumber {
                var digits = ""
                while i < chars.count, chars[i].isNumber || (chars[i] == "." && i + 1 < chars.count && chars[i + 1].isNumber) { digits.append(chars[i]); i += 1 }
                out.append(.number(digits))
            } else if c.isLetter {
                out.append(.ident(String(c))); i += 1
            } else {
                out.append(.op(c == "−" ? "-" : String(c))); i += 1
            }
        }
        return out
    }

    // MARK: Writing

    /// The inside of an `m:oMath` (or the paragraph's math) for TeX source.
    static func write(tex source: String) -> String { runs(TeX.parse(source).items) }

    private static func run(_ text: String, upright: Bool = false) -> String {
        "<m:r>" + (upright ? "<m:rPr><m:sty m:val=\"p\"/></m:rPr>" : "") + "<w:rPr><w:rFonts w:ascii=\"Cambria Math\" w:hAnsi=\"Cambria Math\"/></w:rPr>"
            + "<m:t xml:space=\"preserve\">\(XML.escape(text))</m:t></m:r>"
    }

    private static func e(_ tag: String, _ node: MathNode) -> String { "<m:\(tag)>\(runs(node.items))</m:\(tag)>" }

    private static func runs(_ items: [MathNode]) -> String {
        var out = ""
        var i = 0
        while i < items.count {
            let node = items[i]
            // A big operator with limits (or alone) takes the next item as its body.
            let head: (op: String, sub: MathNode?, sup: MathNode?)? = switch node {
            case .op(let s) where MathSymbols.nary.contains(s): (s, nil, nil)
            case .sub(.op(let s), let b) where MathSymbols.nary.contains(s): (s, b, nil)
            case .sup(.op(let s), let p) where MathSymbols.nary.contains(s): (s, nil, p)
            case .subsup(.op(let s), let b, let p) where MathSymbols.nary.contains(s): (s, b, p)
            default: nil
            }
            if let head {
                let body = i + 1 < items.count ? items[i + 1] : .row([])
                if i + 1 < items.count { i += 1 }
                out += "<m:nary><m:naryPr><m:chr m:val=\"\(XML.escape(head.op))\"/>"
                    + "\(head.sub == nil ? "<m:subHide m:val=\"1\"/>" : "")\(head.sup == nil ? "<m:supHide m:val=\"1\"/>" : "")</m:naryPr>"
                    + "\(head.sub.map { e("sub", $0) } ?? "<m:sub/>")\(head.sup.map { e("sup", $0) } ?? "<m:sup/>")\(e("e", body))</m:nary>"
            } else if case .function(let name) = node {
                let body = i + 1 < items.count ? items[i + 1] : .row([])
                if i + 1 < items.count { i += 1 }
                out += "<m:func><m:fName><m:r><m:rPr><m:sty m:val=\"p\"/></m:rPr><m:t>\(XML.escape(name))</m:t></m:r></m:fName>\(e("e", body))</m:func>"
            } else {
                out += single(node)
            }
            i += 1
        }
        return out
    }

    private static func single(_ node: MathNode) -> String {
        switch node {
        case .row(let c): return runs(c)
        case .ident(let s), .number(let s), .op(let s): return run(s)
        case .text(let s): return "<m:r><m:rPr><m:nor/></m:rPr><m:t xml:space=\"preserve\">\(XML.escape(s))</m:t></m:r>"
        case .function: return ""
        case .frac(let a, let b): return "<m:f>\(e("num", a))\(e("den", b))</m:f>"
        case .sqrt(let a, let index):
            return "<m:rad><m:radPr>\(index == nil ? "<m:degHide m:val=\"1\"/>" : "")</m:radPr>\(index.map { e("deg", $0) } ?? "<m:deg/>")\(e("e", a))</m:rad>"
        case .sup(let b, let p): return "<m:sSup>\(e("e", b))\(e("sup", p))</m:sSup>"
        case .sub(let b, let s): return "<m:sSub>\(e("e", b))\(e("sub", s))</m:sSub>"
        case .subsup(let b, let s, let p): return "<m:sSubSup>\(e("e", b))\(e("sub", s))\(e("sup", p))</m:sSubSup>"
        case .fenced(let open, let close, let body):
            return "<m:d><m:dPr><m:begChr m:val=\"\(XML.escape(open))\"/><m:endChr m:val=\"\(XML.escape(close))\"/></m:dPr>\(e("e", body))</m:d>"
        case .matrix(let rows, let open, let close):
            let table = "<m:m>" + rows.map { "<m:mr>" + $0.map { e("e", $0) }.joined() + "</m:mr>" }.joined() + "</m:m>"
            if open.isEmpty && close.isEmpty { return table }
            return "<m:d><m:dPr><m:begChr m:val=\"\(XML.escape(open))\"/><m:endChr m:val=\"\(XML.escape(close))\"/></m:dPr><m:e>\(table)</m:e></m:d>"
        case .accent(let base, let mark): return "<m:acc><m:accPr><m:chr m:val=\"\(XML.escape(mark))\"/></m:accPr>\(e("e", base))</m:acc>"
        case .space: return run(" ")
        case .raw(let s): return run(s)
        }
    }
}
