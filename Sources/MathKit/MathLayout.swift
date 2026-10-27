import CoreGraphics
import CoreText
import Foundation

/// Fonts for text inside formulas (`\text`, unknown commands), supplied by the caller so they match the document.
public protocol MathTextFonts {
    func mathTextFont(size: Double, bold: Bool, italic: Bool, mono: Bool) -> CTFont
}

/// A typeset formula: glyphs and rules relative to its origin (left end of the baseline, y up), in points.
public struct MathRendering {
    public struct Glyph {
        public let font: CTFont
        public let glyph: CGGlyph
        public let x: Double
        public let y: Double
        /// Set in red: an unknown command, as MathJax shows it.
        public let isError: Bool
    }
    public var width: Double
    public var height: Double
    public var depth: Double
    public var glyphs: [Glyph]
    /// Filled rectangles: x, y (bottom), width, height.
    public var rules: [CGRect]
    /// Commands and environments the formula used that MathKit does not know.
    public var problems: [String]
    /// `\tag{…}`: the equation number to set at the right margin.
    public var tag: String?
}

/// TeX-quality formula layout (The TeXbook, Appendix G) driven by an OpenType MATH table, as LuaTeX and XeTeX do it:
/// atoms and inter-atom spacing, sub/superscripts, fractions, radicals, big operators with limits, growing delimiters
/// and accents (size variants, then glyph assemblies), arrays.
public final class MathTypesetter: @unchecked Sendable {
    let primary: MathFont
    let fallback: MathFont?

    public init(font: MathFont, fallback: MathFont? = nil) {
        primary = font; self.fallback = fallback
    }

    public func typeset(_ tex: String, display: Bool, size: Double, text: MathTextFonts) -> MathRendering {
        let (list, problems, tag) = MathParser.parse(tex)
        let engine = Engine(font: primary, fallback: fallback, base: size, text: text)
        let box = engine.layoutList(list, Ctx(level: display ? .display : .text, cramped: false))
        var glyphs: [MathRendering.Glyph] = []
        var rules: [CGRect] = []
        Engine.flatten(box, x: 0, y: 0, glyphs: &glyphs, rules: &rules)
        return MathRendering(width: box.width, height: box.height, depth: box.depth, glyphs: glyphs, rules: rules,
                             problems: problems, tag: tag)
    }
}

struct Ctx {
    var level: StyleLevel
    var cramped: Bool
    var sup: Ctx { Ctx(level: level <= .text ? .script : .scriptScript, cramped: cramped) }
    var sub: Ctx { Ctx(level: level <= .text ? .script : .scriptScript, cramped: true) }
    var num: Ctx { Ctx(level: level == .display ? .text : level == .text ? .script : .scriptScript, cramped: cramped) }
    var den: Ctx { Ctx(level: num.level, cramped: true) }
    var crampedCopy: Ctx { Ctx(level: level, cramped: true) }
}

struct MBox {
    var width = 0.0, height = 0.0, depth = 0.0
    var italic = 0.0
    var items: [MItem] = []
    /// Horizontal top-accent attachment point (single glyphs).
    var accentAttach: Double? = nil
    var isChar = false

    mutating func append(_ b: MBox, x: Double, y: Double) {
        items.append(.box(b, x: x, y: y))
        height = max(height, b.height + y)
        depth = max(depth, b.depth - y)
    }
}

enum MItem {
    case glyph(CTFont, CGGlyph, x: Double, y: Double, error: Bool)
    case rule(x: Double, y: Double, w: Double, h: Double)
    case box(MBox, x: Double, y: Double)
}

final class Engine {
    let font: MathFont
    let fallback: MathFont?
    let base: Double
    let text: MathTextFonts

    init(font: MathFont, fallback: MathFont?, base: Double, text: MathTextFonts) {
        self.font = font; self.fallback = fallback; self.base = base; self.text = text
    }

    // MARK: Sizes and constants

    func size(_ c: Ctx) -> Double {
        switch c.level {
        case .display, .text: base
        case .script: base * Double(font.table[.scriptPercentScaleDown]) / 100
        case .scriptScript: base * Double(font.table[.scriptScriptPercentScaleDown]) / 100
        }
    }
    func ssty(_ c: Ctx) -> Int { c.level == .script ? 1 : c.level == .scriptScript ? 2 : 0 }
    func k(_ m: MathConstant, _ c: Ctx) -> Double { font.constant(m, size: size(c)) }
    func mu(_ c: Ctx) -> Double { size(c) / 18 }
    /// TeX's `\nulldelimiterspace` (1.2 pt at 10 pt).
    var nullDelimiterSpace: Double { 0.12 * base }

    // MARK: Glyph boxes

    func glyphBox(_ glyph: CGGlyph, _ mf: MathFont, _ c: Ctx, error: Bool = false) -> MBox {
        let s = size(c)
        let m = mf.metrics(glyph, size: s)
        var b = MBox(width: m.width, height: m.height, depth: m.depth, italic: m.italic)
        b.items = [.glyph(mf.font(size: s), glyph, x: 0, y: 0, error: error)]
        b.accentAttach = mf.topAccent(glyph, size: s)
        b.isChar = true
        return b
    }

    func lookup(_ scalar: Unicode.Scalar, _ c: Ctx) -> (CGGlyph, MathFont)? {
        if let g = font.glyph(for: scalar, ssty: ssty(c)) { return (g, font) }
        if let f = fallback, let g = f.glyph(for: scalar, ssty: ssty(c)) { return (g, f) }
        return nil
    }

    func charBox(_ scalar: Unicode.Scalar, _ c: Ctx) -> MBox {
        if let (g, mf) = lookup(scalar, c) { return glyphBox(g, mf, c) }
        return textBox(String(Character(scalar)), c, bold: false, italic: false, mono: false)
    }

    /// Text in the document's text font (or the system's, for characters it lacks).
    func textBox(_ string: String, _ c: Ctx, bold: Bool, italic: Bool, mono: Bool, error: Bool = false) -> MBox {
        let f = text.mathTextFont(size: size(c), bold: bold, italic: italic, mono: mono)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [kCTFontAttributeName as NSAttributedString.Key: f]))
        var b = MBox()
        b.width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        b.height = max(0, Double(ink.maxY)); b.depth = max(0, -Double(ink.minY))
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n)
            var positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for j in 0..<n {
                b.items.append(.glyph(runFont, glyphs[j], x: Double(positions[j].x), y: Double(positions[j].y), error: error))
            }
        }
        return b
    }

    // MARK: Growing glyphs

    /// The smallest vertical variant of `scalar` at least `target` tall, else an assembly of that size; centred on the
    /// math axis when `centre`.
    func verticalDelimiter(_ scalar: Unicode.Scalar?, target: Double, _ c: Ctx, centre: Bool = true) -> MBox {
        guard let scalar else { return MBox(width: nullDelimiterSpace) }
        guard let (g, mf) = lookup(scalar, c) else { return charBox(scalar, c) }
        var b = stretched(g, mf, target: target, vertical: true, c)
        if centre {
            let total = b.height + b.depth
            b = shifted(b, by: total / 2 + k(.axisHeight, c) - b.height)
        }
        return b
    }

    func stretched(_ g: CGGlyph, _ mf: MathFont, target: Double, vertical: Bool, _ c: Ctx) -> MBox {
        let scale = mf.scale(size(c))
        let constructions = vertical ? mf.table.verticalConstructions : mf.table.horizontalConstructions
        guard let cons = constructions[g] else { return glyphBox(g, mf, c) }
        var largest: CGGlyph = g
        for v in cons.variants {
            largest = v.glyph
            if Double(v.advance) * scale >= target - 0.01 { return glyphBox(v.glyph, mf, c) }
        }
        if let parts = cons.assembly, !parts.isEmpty {
            return assemble(parts, mf, target: target, vertical: vertical, c, italic: Double(cons.assemblyItalic) * scale)
        }
        return glyphBox(largest, mf, c)
    }

    /// A glyph assembly (OpenType MATH GlyphAssembly): repeat the extenders until the parts reach `target`, then spread
    /// the connector overlaps evenly.
    func assemble(_ parts: [MathTable.Part], _ mf: MathFont, target: Double, vertical: Bool, _ c: Ctx, italic: Double) -> MBox {
        let s = size(c)
        let scale = mf.scale(s)
        let minOverlap = Double(mf.table.minConnectorOverlap) * scale
        var sequence: [MathTable.Part] = []
        for repeats in 0..<100 {
            sequence = parts.flatMap { $0.isExtender ? Array(repeating: $0, count: repeats) : [$0] }
            let full = sequence.reduce(0.0) { $0 + Double($1.fullAdvance) * scale }
            if full - minOverlap * Double(max(sequence.count - 1, 0)) >= target || !parts.contains(where: \.isExtender) { break }
        }
        let full = sequence.reduce(0.0) { $0 + Double($1.fullAdvance) * scale }
        var overlap = max(minOverlap, (full - target) / Double(max(sequence.count - 1, 1)))
        var maxAllowed = Double.infinity
        for j in 0..<max(sequence.count - 1, 0) {
            maxAllowed = min(maxAllowed, Double(min(sequence[j].endConnector, sequence[j + 1].startConnector)) * scale)
        }
        if maxAllowed.isFinite { overlap = min(overlap, max(maxAllowed, minOverlap)) }
        var b = MBox()
        var cursor = 0.0
        let f = mf.font(size: s)
        var cross = 0.0, crossDepth = 0.0
        for (j, part) in sequence.enumerated() {
            let m = mf.metrics(part.glyph, size: s)
            if vertical {
                b.items.append(.glyph(f, part.glyph, x: 0, y: cursor + m.depth, error: false))
                cross = max(cross, m.width)
            } else {
                b.items.append(.glyph(f, part.glyph, x: cursor, y: 0, error: false))
                cross = max(cross, m.height)
                crossDepth = max(crossDepth, m.depth)
            }
            cursor += Double(part.fullAdvance) * scale
            if j < sequence.count - 1 { cursor -= overlap }
        }
        if vertical { b.width = cross; b.height = cursor } else { b.width = cursor; b.height = cross; b.depth = crossDepth }
        b.italic = italic
        return b
    }

    func shifted(_ b: MBox, by dy: Double) -> MBox {
        var out = MBox(width: b.width, height: b.height + dy, depth: b.depth - dy, italic: b.italic)
        out.items = [.box(b, x: 0, y: dy)]
        out.accentAttach = b.accentAttach
        return out
    }

    // MARK: Lists

    private struct Entry {
        var type: AtomType?
        var box: MBox
        var ctx: Ctx
    }

    func layoutList(_ list: MathList, _ start: Ctx) -> MBox {
        var ctx = start
        var entries: [Entry] = []
        for node in list {
            switch node {
            case .style(let level):
                ctx = Ctx(level: level, cramped: ctx.cramped)
            case .space(let v, let unit):
                entries.append(Entry(type: nil, box: MBox(width: unit == .mu ? v * mu(ctx) : v * size(ctx)), ctx: ctx))
            case .middle:
                break
            default:
                if let e = layoutNode(node, ctx) { entries.append(Entry(type: e.0, box: e.1, ctx: ctx)) }
            }
        }
        // Rules 5–6: a binary operator with nothing to operate on is an ordinary symbol.
        var lastIndex: Int? = nil
        for i in entries.indices {
            guard let t = entries[i].type else { continue }
            let last = lastIndex.flatMap { entries[$0].type }
            if t == .bin && (last == nil || [.bin, .op, .rel, .open, .punct].contains(last!)) { entries[i].type = .ord }
            if [.rel, .close, .punct].contains(t), let li = lastIndex, entries[li].type == .bin { entries[li].type = .ord }
            lastIndex = i
        }
        if let li = lastIndex, entries[li].type == .bin { entries[li].type = .ord }

        var out = MBox()
        var x = 0.0
        var previous: AtomType? = nil
        for e in entries {
            if let t = e.type, let p = previous { x += interAtomSpace(p, t, e.ctx) }
            out.append(e.box, x: x, y: 0)
            x += e.box.width
            if let t = e.type { previous = t }
        }
        out.width = x
        if entries.count == 1, entries[0].box.isChar {
            out.isChar = true; out.italic = entries[0].box.italic; out.accentAttach = entries[0].box.accentAttach
        } else if let last = entries.last {
            out.italic = last.box.italic
        }
        return out
    }

    /// TeX's inter-atom spacing (The TeXbook, chapter 18): 1 thin, 2 medium, 3 thick; negative entries only in display
    /// and text styles.
    private static let spacing: [[Int]] = [
        //        ord op bin rel open close punct inner
        /* ord */ [0, 1, -2, -3, 0, 0, 0, -1],
        /* op  */ [1, 1, 0, -3, 0, 0, 0, -1],
        /* bin */ [-2, -2, 0, 0, -2, 0, 0, -2],
        /* rel */ [-3, -3, 0, 0, -3, 0, 0, -3],
        /* open*/ [0, 0, 0, 0, 0, 0, 0, 0],
        /* clos*/ [0, 1, -2, -3, 0, 0, 0, -1],
        /* punc*/ [-1, -1, 0, -1, -1, -1, -1, -1],
        /* innr*/ [-1, 1, -2, -3, -1, 0, -1, -1],
    ]

    func interAtomSpace(_ a: AtomType, _ b: AtomType, _ c: Ctx) -> Double {
        let v = Self.spacing[a.rawValue][b.rawValue]
        if v == 0 || (v < 0 && c.level >= .script) { return 0 }
        return Double([0, 3, 4, 5][abs(v)]) * mu(c)
    }

    // MARK: Nodes

    func layoutNode(_ node: MathNode, _ c: Ctx) -> (AtomType, MBox)? {
        switch node {
        case .atom(let a):
            return layoutAtom(a, c)
        case .fraction(let num, let den, let rule, let l, let r, let style):
            return (.inner, fraction(num, den, rule: rule, left: l, right: r, forced: style, c))
        case .radical(let degree, let body):
            return (.ord, radical(degree, body, c))
        case .leftRight(let l, let body, let r):
            return (.inner, leftRight(l, body, r, c))
        case .accent(let a, let stretchy, let body):
            return (.ord, accent(a, stretchy: stretchy, body, c))
        case .overline(let body):
            let inner = layoutList(body, c.crampedCopy)
            let t = k(.overbarRuleThickness, c), gap = k(.overbarVerticalGap, c)
            var b = MBox(width: inner.width)
            b.append(inner, x: 0, y: 0)
            b.items.append(.rule(x: 0, y: inner.height + gap, w: inner.width, h: t))
            b.height = inner.height + gap + t + k(.overbarExtraAscender, c)
            return (.ord, b)
        case .underline(let body):
            let inner = layoutList(body, c)
            let t = k(.underbarRuleThickness, c), gap = k(.underbarVerticalGap, c)
            var b = MBox(width: inner.width)
            b.append(inner, x: 0, y: 0)
            b.items.append(.rule(x: 0, y: -(inner.depth + gap + t), w: inner.width, h: t))
            b.depth = inner.depth + gap + t + k(.underbarExtraDescender, c)
            return (.ord, b)
        case .brace(let body, let over):
            return (.op, brace(body, over: over, c))
        case .stack(let over, let base, let under, let type):
            let nucleus = layoutList(base, c)
            return (type, limits(nucleus, sup: over.map { layoutList($0, c.sup) }, sub: under.map { layoutList($0, c.sub) }, delta: 0, c))
        case .text(let s, let bold, let italic, let mono):
            return (.ord, textBox(s, c, bold: bold, italic: italic, mono: mono))
        case .array(let a):
            return (a.left != nil || a.right != nil ? .inner : .ord, array(a, c))
        case .sizedDelimiter(let d, let sizeIndex, let type):
            // amsmath: \big is a delimiter for a box 1.2 × the strut height (8.5 pt at 10 pt), \Big 1.5×, \bigg 2×, \Bigg 2.5×.
            let x = [0, 1.0, 1.5, 2.0, 2.5][sizeIndex] * 1.2 * 0.85 * base
            return (type, verticalDelimiter(d, target: max(x * 0.901, x - 0.5 * base), c))
        case .phantom(let body, let h, let v):
            let inner = layoutList(body, c)
            return (.ord, MBox(width: h ? inner.width : 0, height: v ? inner.height : 0, depth: v ? inner.depth : 0))
        case .boxed(let body):
            let inner = layoutList(body, c)
            let sep = 0.3 * base, rule = 0.04 * base
            var b = MBox(width: inner.width + 2 * (sep + rule))
            b.append(inner, x: sep + rule, y: 0)
            let top = inner.height + sep + rule, bottom = -(inner.depth + sep + rule)
            b.items += [.rule(x: 0, y: bottom, w: b.width, h: rule), .rule(x: 0, y: top - rule, w: b.width, h: rule),
                        .rule(x: 0, y: bottom, w: rule, h: top - bottom), .rule(x: b.width - rule, y: bottom, w: rule, h: top - bottom)]
            b.height = top; b.depth = -bottom
            return (.ord, b)
        case .error(let name):
            return (.ord, textBox(name, c, bold: false, italic: false, mono: false, error: true))
        case .style, .space, .middle:
            return nil
        }
    }

    func layoutAtom(_ a: Atom, _ c: Ctx) -> (AtomType, MBox) {
        var nucleus: MBox
        var delta = 0.0
        var braceLimits = false
        switch a.nucleus {
        case .char(let ch):
            nucleus = a.largeOp ? largeOperator(ch, c) : charBox(ch, c)
            delta = nucleus.italic
        case .list(let l):
            if l.count == 1, case .brace = l[0] { braceLimits = true }
            nucleus = layoutList(l, c)
            // A braced character is a box, not a character (TeX's {x}^2), for the script rules.
            nucleus.isChar = false
        case .named(let name):
            nucleus = namedOperator(name, c)
        case .empty:
            nucleus = MBox()
        }
        let useLimits = braceLimits || (a.type == .op && (a.limits ?? (a.defaultLimits && c.level == .display)))
        if useLimits && (a.sup != nil || a.sub != nil) {
            return (braceLimits ? .op : a.type, limits(nucleus, sup: a.sup.map { layoutList($0, c.sup) }, sub: a.sub.map { layoutList($0, c.sub) },
                                                      delta: delta, c))
        }
        if a.sup == nil && a.sub == nil {
            // Rule 17: the italic correction follows a character that has no subscript.
            if nucleus.isChar && delta != 0 { nucleus.width += delta }
            return (a.type, nucleus)
        }
        // A big operator's scripts hang from its box (rule 18a's drops), shifted by its italic correction.
        let scriptDelta = nucleus.isChar || a.largeOp ? delta : 0
        if a.largeOp { nucleus.isChar = false }
        return (a.type, scripts(nucleus, sup: a.sup, sub: a.sub, delta: scriptDelta, c))
    }

    /// `\operator@font`: upright letters, a thin space for a space ("lim sup").
    func namedOperator(_ name: String, _ c: Ctx) -> MBox {
        var b = MBox()
        var x = 0.0
        for ch in name.unicodeScalars {
            if ch == " " { x += 3 * mu(c); continue }
            let g = charBox(ch, c)
            b.append(g, x: x, y: 0)
            x += g.width
        }
        b.width = x
        return b
    }

    /// Rule 13: big operators, the display variant at least DisplayOperatorMinHeight tall, centred on the axis.
    func largeOperator(_ ch: Unicode.Scalar, _ c: Ctx) -> MBox {
        guard let (g, mf) = lookup(ch, c) else { return charBox(ch, c) }
        var b = glyphBox(g, mf, c)
        if c.level == .display, let cons = mf.table.verticalConstructions[g] {
            let minHeight = Double(mf.table[.displayOperatorMinHeight]) * mf.scale(size(c))
            for v in cons.variants where v.glyph != g {
                b = glyphBox(v.glyph, mf, c)
                if Double(v.advance) * mf.scale(size(c)) >= minHeight { break }
            }
        }
        var out = shifted(b, by: k(.axisHeight, c) - (b.height - b.depth) / 2)
        out.isChar = true
        return out
    }

    /// Rule 13a: limits above and below an operator, shifted by half its italic correction.
    func limits(_ nucleus: MBox, sup: MBox?, sub: MBox?, delta: Double, _ c: Ctx) -> MBox {
        let width = max(nucleus.width, sup?.width ?? 0, sub?.width ?? 0)
        var b = MBox(width: width)
        b.append(nucleus, x: (width - nucleus.width) / 2, y: 0)
        if let sup {
            let gap = max(k(.upperLimitBaselineRiseMin, c) - sup.depth, k(.upperLimitGapMin, c))
            b.append(sup, x: (width - sup.width) / 2 + delta / 2, y: nucleus.height + gap + sup.depth)
        }
        if let sub {
            let gap = max(k(.lowerLimitBaselineDropMin, c) - sub.height, k(.lowerLimitGapMin, c))
            b.append(sub, x: (width - sub.width) / 2 - delta / 2, y: -(nucleus.depth + gap + sub.height))
        }
        return b
    }

    /// Rule 18: superscripts and subscripts with the MATH table's shifts and gaps.
    func scripts(_ nucleus: MBox, sup supList: MathList?, sub subList: MathList?, delta: Double, _ c: Ctx) -> MBox {
        var u = 0.0, v = 0.0
        if !nucleus.isChar {
            u = nucleus.height - k(.superscriptBaselineDropMax, c)
            v = nucleus.depth + k(.subscriptBaselineDropMin, c)
        }
        var b = MBox(width: nucleus.width)
        b.append(nucleus, x: 0, y: 0)
        let after = k(.spaceAfterScript, c)
        guard let supList else {
            // TeX's sub1 (0.15 em in Computer Modern) for a lone subscript; the MATH table's SubscriptShiftDown is sub2,
            // which TeX uses only with a superscript.
            let sub = layoutList(subList ?? [], c.sub)
            v = max(v, 0.149998 * size(c), sub.height - k(.subscriptTopMax, c))
            b.append(sub, x: nucleus.width, y: -v)
            b.width = nucleus.width + sub.width + after
            return b
        }
        let sup = layoutList(supList, c.sup)
        // TeX's sup1 (0.413 em) in display style, sup2 (SuperscriptShiftUp) otherwise, sup3 when cramped.
        let shift = c.cramped ? k(.superscriptShiftUpCramped, c) : c.level == .display ? 0.412892 * size(c) : k(.superscriptShiftUp, c)
        u = max(u, shift, sup.depth + k(.superscriptBottomMin, c))
        if let subList {
            let sub = layoutList(subList, c.sub)
            v = max(v, k(.subscriptShiftDown, c))
            let gap = (u - sup.depth) - (sub.height - v)
            let minGap = k(.subSuperscriptGapMin, c)
            if gap < minGap {
                v += minGap - gap
                let psi = k(.superscriptBottomMaxWithSubscript, c) - (u - sup.depth)
                if psi > 0 { u += psi; v -= psi }
            }
            b.append(sup, x: nucleus.width + delta, y: u)
            b.append(sub, x: nucleus.width, y: -v)
            b.width = max(nucleus.width + delta + sup.width, nucleus.width + sub.width) + after
        } else {
            b.append(sup, x: nucleus.width + delta, y: u)
            b.width = nucleus.width + delta + sup.width + after
        }
        return b
    }

    /// Rule 15: fractions and stacks (binomials), with null delimiters (or the binomial's parentheses) at the sides.
    func fraction(_ numList: MathList, _ denList: MathList, rule: Bool, left: Unicode.Scalar?, right: Unicode.Scalar?,
                  forced: StyleLevel?, _ c0: Ctx) -> MBox {
        let c = forced.map { Ctx(level: $0, cramped: c0.cramped) } ?? c0
        let num = layoutList(numList, c.num)
        let den = layoutList(denList, c.den)
        let display = c.level == .display
        let axis = k(.axisHeight, c)
        var u: Double, v: Double
        let theta = rule ? k(.fractionRuleThickness, c) : 0
        if rule {
            u = display ? k(.fractionNumeratorDisplayStyleShiftUp, c) : k(.fractionNumeratorShiftUp, c)
            v = display ? k(.fractionDenominatorDisplayStyleShiftDown, c) : k(.fractionDenominatorShiftDown, c)
            let gapN = display ? k(.fractionNumDisplayStyleGapMin, c) : k(.fractionNumeratorGapMin, c)
            let gapD = display ? k(.fractionDenomDisplayStyleGapMin, c) : k(.fractionDenominatorGapMin, c)
            let clearN = (u - num.depth) - (axis + theta / 2)
            if clearN < gapN { u += gapN - clearN }
            let clearD = (axis - theta / 2) - (den.height - v)
            if clearD < gapD { v += gapD - clearD }
        } else {
            u = display ? k(.stackTopDisplayStyleShiftUp, c) : k(.stackTopShiftUp, c)
            v = display ? k(.stackBottomDisplayStyleShiftDown, c) : k(.stackBottomShiftDown, c)
            let gap = display ? k(.stackDisplayStyleGapMin, c) : k(.stackGapMin, c)
            let clear = (u - num.depth) - (den.height - v)
            if clear < gap { u += (gap - clear) / 2; v += (gap - clear) / 2 }
        }
        let width = max(num.width, den.width)
        var f = MBox(width: width)
        f.append(num, x: (width - num.width) / 2, y: u)
        f.append(den, x: (width - den.width) / 2, y: -v)
        if rule { f.items.append(.rule(x: 0, y: axis - theta / 2, w: width, h: theta)) }
        // TeX's delim1/delim2 sizes for a binomial's parentheses; \nulldelimiterspace otherwise.
        let target = max(display ? 2.39 * size(c) : 1.01 * size(c), f.height + f.depth)
        var out = MBox()
        var x = 0.0
        for part in [left != nil ? verticalDelimiter(left, target: target, c) : MBox(width: nullDelimiterSpace), f,
                     right != nil ? verticalDelimiter(right, target: target, c) : MBox(width: nullDelimiterSpace)] {
            out.append(part, x: x, y: 0)
            x += part.width
        }
        out.width = x
        return out
    }

    /// Rule 11: radicals, the degree placed by RadicalKernBeforeDegree, RadicalKernAfterDegree and
    /// RadicalDegreeBottomRaisePercent.
    func radical(_ degreeList: MathList?, _ bodyList: MathList, _ c: Ctx) -> MBox {
        let body = layoutList(bodyList, c.crampedCopy)
        let theta = k(.radicalRuleThickness, c)
        var gap = c.level == .display ? k(.radicalDisplayStyleVerticalGap, c) : k(.radicalVerticalGap, c)
        let target = body.height + body.depth + gap + theta
        let surd = verticalDelimiter("\u{221A}", target: target, c, centre: false)
        let total = surd.height + surd.depth
        if total > target { gap += (total - target) / 2 }
        let top = body.height + gap + theta
        var b = MBox()
        var x = 0.0
        if let degreeList {
            let degree = layoutList(degreeList, Ctx(level: .scriptScript, cramped: true))
            let raise = Double(font.table[.radicalDegreeBottomRaisePercent]) / 100 * total
            x = max(0, k(.radicalKernBeforeDegree, c))
            b.append(degree, x: x, y: top - total + raise + degree.depth)
            x = max(0, x + degree.width + k(.radicalKernAfterDegree, c))
        }
        b.append(shifted(surd, by: top - surd.height), x: x, y: 0)
        x += surd.width
        b.append(body, x: x, y: 0)
        b.items.append(.rule(x: x, y: body.height + gap, w: body.width, h: theta))
        b.width = x + body.width
        b.height = max(b.height, top + k(.radicalExtraAscender, c))
        return b
    }

    /// `\left…\middle…\right`: delimiters sized as TeX does (`\delimiterfactor` 901, `\delimitershortfall` 5 pt).
    func leftRight(_ left: Unicode.Scalar?, _ body: MathList, _ right: Unicode.Scalar?, _ c: Ctx) -> MBox {
        var segments: [MathList] = [[]]
        var middles: [Unicode.Scalar?] = []
        for node in body {
            if case .middle(let d) = node { middles.append(d); segments.append([]) } else { segments[segments.count - 1].append(node) }
        }
        let boxes = segments.map { layoutList($0, c) }
        let axis = k(.axisHeight, c)
        let delta1 = max((boxes.map(\.height).max() ?? 0) - axis, (boxes.map(\.depth).max() ?? 0) + axis)
        let target = max(delta1 / 500 * 901, 2 * delta1 - 0.5 * base)
        var out = MBox()
        var x = 0.0
        let l = verticalDelimiter(left, target: target, c)
        out.append(l, x: x, y: 0); x += l.width
        for (i, box) in boxes.enumerated() {
            out.append(box, x: x, y: 0); x += box.width
            if i < middles.count {
                let m = verticalDelimiter(middles[i], target: target, c)
                out.append(m, x: x, y: 0); x += m.width
            }
        }
        let r = verticalDelimiter(right, target: target, c)
        out.append(r, x: x, y: 0)
        out.width = x + r.width
        return out
    }

    /// Rule 12: accents over a base, aligned on the glyphs' top-accent attachment points; wide accents and arrows grow.
    func accent(_ a: Unicode.Scalar, stretchy: Bool, _ bodyList: MathList, _ c: Ctx) -> MBox {
        let base = layoutList(bodyList, c.crampedCopy)
        let combining = (0x300...0x36F).contains(a.value) || (0x20D0...0x20FF).contains(a.value)
        guard let (g, mf) = lookup(a, c) else { return base }
        let accentBox = stretchy || !combining ? stretched(g, mf, target: base.width, vertical: false, c) : glyphBox(g, mf, c)
        var b = MBox(width: base.width, italic: base.italic)
        b.append(base, x: 0, y: 0)
        if combining {
            let baseAttach = base.isChar ? (base.accentAttach ?? (base.width + base.italic) / 2) : base.width / 2
            let accentAttach = accentBox.accentAttach ?? accentBox.width / 2
            b.append(accentBox, x: baseAttach - accentAttach, y: base.height - min(base.height, k(.accentBaseHeight, c)))
        } else {
            b.append(accentBox, x: (base.width - accentBox.width) / 2, y: base.height + k(.overbarVerticalGap, c) / 2 + accentBox.depth)
        }
        return b
    }

    func brace(_ bodyList: MathList, over: Bool, _ c: Ctx) -> MBox {
        let base = layoutList(bodyList, c)
        guard let (g, mf) = lookup(over ? "\u{23DE}" : "\u{23DF}", c) else { return base }
        let brace = stretched(g, mf, target: base.width, vertical: false, c)
        var b = MBox(width: max(base.width, brace.width))
        b.append(base, x: (b.width - base.width) / 2, y: 0)
        let gap = k(.stretchStackGapBelowMin, c)
        b.append(brace, x: (b.width - brace.width) / 2,
                 y: over ? base.height + gap + brace.depth : -(base.depth + gap + brace.height))
        return b
    }

    /// Matrices, `cases`, `aligned`, `gathered`, `array`, `substack`: cells in rows on struts, centred on the axis.
    func array(_ a: MathArray, _ c: Ctx) -> MBox {
        let cellCtx: Ctx
        switch a.kind {
        case .aligned, .gathered: cellCtx = Ctx(level: .display, cramped: c.cramped)
        case .smallMatrix: cellCtx = Ctx(level: .script, cramped: c.cramped)
        case .substack: cellCtx = c
        default: cellCtx = Ctx(level: c.level == .display ? .text : c.level, cramped: c.cramped)
        }
        let small = a.kind == .smallMatrix || a.kind == .substack
        let baselineSkip = 1.2 * base * (small ? 0.7 : 1)
        let stretch = a.kind == .cases ? 1.2 : 1.0   // amsmath's cases: \arraystretch 1.2
        let strutH = 0.7 * baselineSkip * stretch, strutD = 0.3 * baselineSkip * stretch
        let jot = (a.kind == .aligned || a.kind == .gathered) ? 0.3 * base : 0
        let cols = max(a.columns.count, a.rows.map(\.count).max() ?? 0)
        let cells: [[MBox]] = a.rows.map { row in
            var r = row.enumerated().map { j, cell in
                // In `aligned` the right-hand column starts with an empty atom so a leading relation keeps its space.
                layoutList(a.kind == .aligned && j % 2 == 1 ? [.atom(Atom(type: .ord, nucleus: .empty))] + cell : cell, cellCtx)
            }
            while r.count < cols { r.append(MBox()) }
            return r
        }
        var widths = [Double](repeating: 0, count: cols)
        for r in cells { for (j, b) in r.enumerated() { widths[j] = max(widths[j], b.width) } }
        func gap(after j: Int) -> Double {
            switch a.kind {
            case .aligned: return j % 2 == 0 ? 0 : 2 * base
            case .cases: return base
            case .gathered, .substack: return 0
            case .smallMatrix: return 0.333 * base
            default: return base      // 2\arraycolsep
            }
        }
        let outer = a.kind == .array ? 0.5 * base : 0
        var xs: [Double] = []
        var x = outer
        for j in 0..<cols { xs.append(x); x += widths[j] + (j < cols - 1 ? gap(after: j) : 0) }
        let totalWidth = x + outer
        var rows: [(MBox, Double, Double)] = []
        for r in cells {
            var rowBox = MBox(width: totalWidth)
            var h = small ? 0 : strutH, d = small ? 0 : strutD
            for (j, b) in r.enumerated() {
                let align = j < a.columns.count ? a.columns[j] : "c"
                let dx = align == "l" ? 0 : align == "r" ? widths[j] - b.width : (widths[j] - b.width) / 2
                rowBox.append(b, x: xs[j] + dx, y: 0)
                h = max(h, b.height); d = max(d, b.depth)
            }
            if small { h = max(h, 0.7 * size(cellCtx)); d = max(d, 0.2 * size(cellCtx)) }
            rows.append((rowBox, h, d + jot))
        }
        if jot > 0, !rows.isEmpty { rows[rows.count - 1].2 -= jot }
        let totalHeight = rows.reduce(0.0) { $0 + $1.1 + $1.2 }
        let axis = k(.axisHeight, c)
        var y = totalHeight / 2 + axis
        var b = MBox(width: totalWidth)
        for (box, h, d) in rows {
            y -= h
            b.append(box, x: 0, y: y)
            y -= d
        }
        b.height = totalHeight / 2 + axis
        b.depth = totalHeight / 2 - axis
        for j in a.verticalRules where j >= 0 && j < cols - 1 {
            b.items.append(.rule(x: xs[j] + widths[j] + gap(after: j) / 2, y: -b.depth, w: 0.04 * base, h: b.height + b.depth))
        }
        guard a.left != nil || a.right != nil else { return b }
        let delta1 = max(b.height - axis, b.depth + axis)
        let target = max(delta1 / 500 * 901, 2 * delta1 - 0.5 * base)
        var out = MBox()
        let l = verticalDelimiter(a.left, target: target, c)
        out.append(l, x: 0, y: 0)
        out.append(b, x: l.width, y: 0)
        let r = verticalDelimiter(a.right, target: target, c)
        out.append(r, x: l.width + b.width, y: 0)
        out.width = l.width + b.width + r.width
        return out
    }

    // MARK: Output

    static func flatten(_ b: MBox, x: Double, y: Double, glyphs: inout [MathRendering.Glyph], rules: inout [CGRect]) {
        for item in b.items {
            switch item {
            case .glyph(let f, let g, let gx, let gy, let error):
                glyphs.append(MathRendering.Glyph(font: f, glyph: g, x: x + gx, y: y + gy, isError: error))
            case .rule(let rx, let ry, let w, let h):
                rules.append(CGRect(x: x + rx, y: y + ry, width: w, height: h))
            case .box(let inner, let bx, let by):
                flatten(inner, x: x + bx, y: y + by, glyphs: &glyphs, rules: &rules)
            }
        }
    }
}
