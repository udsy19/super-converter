import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SuperConverterCore

/// Where a block sits: list nesting, margins, the paragraph settings in force (LaTeX's list environments change them).
struct BlockContext {
    var left = 0.0
    var right = 0.0
    var listDepth = 0
    var parindent: Double
    var parskip: Glue
    var size: SizeCommand = .normalsize
    var tags: [TagNode] = []
}

/// The look a document is set in (O-DOC-PDF): LaTeX's, or the document's own fonts and spacing ("As written").
enum Look: Sendable { case latex, asWritten }

/// Turns a DocModel into TeX's main vertical list: title block, headings with LaTeX's spacing and numbering, justified
/// paragraphs, lists, quotes, verbatim code, display math, figures and tables (floats), footnotes, with the penalties
/// that keep headings with their text and avoid widows and orphans.
final class Composer {
    let style: StyleSheet
    let look: Look
    let fonts: FontResolver
    let setter: ParagraphSetter
    let math: MathBridge
    let resources: [String: Data]
    let numberSections: Bool
    /// The DocModel heading level LaTeX's \section stands for.
    let sectionLevel: Int
    /// Pages of headings from the previous pass (for the contents page).
    let headingPages: [String: String]
    let defaultFont: String?

    var items: [VItem] = []
    private var prevDepth: Double? = nil
    private var afterHeading = false
    private var suppressParskip = false
    private var noIndentNext = false
    private var pendingLabels: [(HBox, Double)] = []
    private var pendingRunIn: [InlinePiece]? = nil
    private var lastLine: (natural: Double, x: Double)? = nil
    private var counters = [0, 0, 0, 0, 0]
    private var chapter = 0
    /// Footnote ids by number: every reference is a footnote of its own, numbered in order (as LaTeX's \footnote).
    private var footnoteIDs: [Int: String] = [:]
    private var footnoteDefinitions: [String: [DocBlock]] = [:]
    private(set) var footnotes: [Int: [VItem]] = [:]
    private var figureCount = 0
    private var tableCount = 0
    private var tagCount = 0
    private var tableIDs = 0
    private(set) var tableHeaders: [Int: [VItem]] = [:]
    private var headingCount = 0
    private var droppedImages = 0
    private var formattingDropped = false
    private var tableSimplified = false

    init(style: StyleSheet, look: Look, fonts: FontResolver, setter: ParagraphSetter, math: MathBridge, doc: DocModel,
         numberSections: Bool, sectionLevel: Int, headingPages: [String: String]) {
        self.style = style; self.look = look; self.fonts = fonts; self.setter = setter; self.math = math
        self.resources = doc.resources; self.numberSections = numberSections; self.sectionLevel = sectionLevel
        self.headingPages = headingPages
        self.defaultFont = look == .asWritten ? (Self.firstFont(doc.blocks) ?? "Calibri") : nil
        collectFootnotes(doc.blocks)
    }

    // MARK: Context

    var rootContext: BlockContext {
        BlockContext(parindent: look == .latex ? style.parindent : 0, parskip: look == .latex ? style.parskip : .zero)
    }

    func lineWidth(_ ctx: BlockContext) -> Double { style.geometry.columnWidth - ctx.left - ctx.right }

    func nextTag(_ kind: TagKind, actualText: String? = nil, alt: String? = nil) -> TagNode {
        tagCount += 1
        return TagNode(kind: kind, id: tagCount, actualText: actualText, alt: alt)
    }

    func runStyle(_ ctx: BlockContext) -> RunStyle {
        var s = RunStyle(size: style.size(ctx.size).size)
        if look == .asWritten { s.documentFont = defaultFont }
        return s
    }

    func runStyle(_ ctx: BlockContext, paragraph p: DocParagraphStyle) -> RunStyle {
        var s = runStyle(ctx)
        if look == .asWritten {
            if let f = p.fontName { s.documentFont = f }
            if let size = p.fontSize { s.size = size }
        } else if p.fontName != nil || p.fontSize != nil {
            formattingDropped = true
        }
        return s
    }

    // MARK: The vertical list

    /// TeX's `append_to_vlist`: interline glue from `\baselineskip`, or `\lineskip` when the boxes would come closer
    /// than `\lineskiplimit`.
    func appendBox(_ b: VBox, baselineskip: Double) {
        if let pd = prevDepth {
            let g = baselineskip - pd - b.box.height
            items.append(.glue(Glue(width: g < style.lineskiplimit ? style.lineskip : g)))
        }
        items.append(.box(b))
        prevDepth = b.box.depth
    }

    /// LaTeX's `\addvspace`: the larger of this and a space just added.
    func addVSpace(_ g: Glue) {
        if case .glue(let last)? = items.last {
            if g.width > last.width { items[items.count - 1] = .glue(g) }
            return
        }
        items.append(.glue(g))
    }

    /// LaTeX's `\addpenalty`: the penalty goes before a space just added, so the space stays a single break.
    func addPenalty(_ p: Int) {
        if case .glue(let last)? = items.last {
            items.removeLast()
            items.append(.penalty(p))
            items.append(.glue(last))
        } else {
            items.append(.penalty(p))
        }
    }

    // MARK: Blocks

    func compose(_ blocks: [DocBlock], _ ctx: BlockContext) {
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                heading(level: level, text: text, ctx)
            case .paragraph(let text, let pstyle):
                if let only = Self.soleImage(text) {
                    figure(resource: only.0, caption: nil, alt: only.1, ctx)
                } else {
                    paragraph(inline(text, ctx, base: runStyle(ctx, paragraph: pstyle)), ctx, pstyle: pstyle)
                }
            case .list(let ordered, let start, let entries):
                list(ordered: ordered, start: start, entries: entries, ctx)
            case .table(let table):
                self.table(table, ctx)
            case .figure(let resource, let caption, let alt):
                figure(resource: resource, caption: caption, alt: alt, ctx)
            case .code(_, let text):
                code(text, ctx)
            case .quote(let inner):
                quote(inner, ctx)
            case .math(let tex, let display):
                if display { displayMath(tex, ctx) } else { paragraph([.math(tex, runStyle(ctx))], ctx) }
            case .footnote:
                break   // set with the page that references it
            case .thematicBreak:
                thematicBreak(ctx)
            case .pageBreak:
                items.append(.clearPage)
                prevDepth = nil
            }
        }
        if let runIn = pendingRunIn {
            pendingRunIn = nil
            paragraph(runIn, ctx)
        }
    }

    private static func soleImage(_ text: DocText) -> (String, String?)? {
        let content = text.filter { if case .text(let s) = $0 { return !s.trimmingCharacters(in: .whitespaces).isEmpty }; return true }
        if content.count == 1, case .image(let r, let alt) = content[0] { return (r, alt) }
        return nil
    }

    private static func firstFont(_ blocks: [DocBlock]) -> String? {
        for b in blocks { if case .paragraph(_, let s) = b, let f = s.fontName { return f } }
        return nil
    }

    // MARK: Inline content

    func inline(_ text: DocText, _ ctx: BlockContext, base: RunStyle) -> [InlinePiece] {
        var out: [InlinePiece] = []
        func walk(_ t: DocText, _ s: RunStyle) {
            for node in t {
                switch node {
                case .text(let string):
                    out.append(.text(string, s))
                case .emphasis(let inner):
                    var e = s
                    e.shape = s.italic ? .upright : .italic   // \emph toggles
                    walk(inner, e)
                case .strong(let inner):
                    var b = s; b.bold = true
                    walk(inner, b)
                case .strike(let inner):
                    var b = s; b.strike = true
                    walk(inner, b)
                case .code(let code):
                    var c = s
                    c.family = .mono; c.verbatim = true; c.bold = false; c.shape = .upright
                    if look == .asWritten { c.documentFont = "Courier New" }
                    out.append(.text(code, c))
                case .link(let inner, let destination):
                    let plain = Self.plainText(inner)
                    out.append(.linkStart(destination))
                    if plain == destination || "mailto:" + plain == destination {
                        // \url: typewriter, breaking after slashes and dots.
                        var u = s
                        u.verbatim = true; u.isURL = true
                        if look == .latex { u.family = .mono; u.shape = .upright }
                        walk(inner, u)
                    } else {
                        walk(inner, s)
                    }
                    out.append(.linkEnd)
                case .image(let resource, let alt):
                    if let img = loadImage(resource) {
                        let scale = min(1, lineWidth(ctx) / img.width, style.geometry.textHeight * 0.4 / img.height)
                        out.append(.image(img.content, width: img.width * scale, height: img.height * scale))
                    } else {
                        droppedImages += 1
                        var a = s; a.shape = .italic
                        out.append(.text("[\(alt ?? resource)]", a))
                    }
                case .footnoteReference(let id):
                    out.append(.footnote(footnoteNumber(id), s))
                case .math(let tex):
                    out.append(.math(tex, s))
                case .styled(let inner, let rs):
                    var t = s
                    if rs.superscript { t.script = .raised }
                    if rs.subscripted { t.script = .lowered }
                    if rs.underline { t.underline = true }
                    if let name = rs.fontName?.lowercased(), name.contains("small caps") || name.hasSuffix("caps") { t.shape = .smallCaps }
                    if look == .asWritten {
                        if let f = rs.fontName { t.documentFont = f }
                        if let size = rs.fontSize { t.size = size }
                        t.colour = rs.colour
                    } else if rs.fontName != nil || rs.fontSize != nil || rs.colour != nil {
                        formattingDropped = true
                    }
                    walk(inner, t)
                case .lineBreak:
                    out.append(.lineBreak)
                }
            }
        }
        walk(text, base)
        return out
    }

    static func plainText(_ t: DocText) -> String {
        var s = ""
        for n in t {
            switch n {
            case .text(let x): s += x
            case .emphasis(let i), .strong(let i), .strike(let i), .link(let i, _), .styled(let i, _): s += plainText(i)
            case .code(let c): s += c
            case .math(let tex): s += tex
            case .lineBreak: s += " "
            case .image, .footnoteReference: break
            }
        }
        return s
    }

    // MARK: Paragraphs

    func paragraph(_ content: [InlinePiece], _ ctx: BlockContext, pstyle: DocParagraphStyle = DocParagraphStyle(),
                   indent: Bool? = nil, tag: TagKind = .paragraph) {
        var pieces = content
        if let runIn = pendingRunIn { pieces = runIn + pieces; pendingRunIn = nil }
        var baselineskip = style.size(ctx.size).leading
        var alignment: ParagraphAlignment = pstyle.alignment == .centre ? .centred : .justified
        if look == .asWritten {
            if let before = pstyle.spaceBefore, before > 0 { addVSpace(Glue(width: before)) }
            switch pstyle.alignment {
            case .justified: alignment = .justified
            case .centre: alignment = .centred
            case .end: alignment = .raggedLeft
            case .start: alignment = .raggedRight
            }
            let s = pieces.lazy.compactMap { if case .text(_, let st) = $0 { return st } else { return nil } }.first ?? runStyle(ctx)
            baselineskip = asWrittenLeading(s)
        }
        if !items.isEmpty && !suppressParskip { items.append(.glue(ctx.parskip)) }
        suppressParskip = false
        let indented = indent ?? !(afterHeading || noIndentNext || !pendingLabels.isEmpty)
        var shape = ParagraphShape(width: lineWidth(ctx))
        shape.indent = indented && alignment == .justified ? ctx.parindent : 0
        shape.alignment = alignment
        shape.hyphenate = setter.hyphenator != nil
        emitLines(setter.set(pieces, shape: shape).lines, ctx, baselineskip: baselineskip, tag: nextTag(tag))
        if look == .asWritten { addVSpace(Glue(width: pstyle.spaceAfter ?? 8)) }
        afterHeading = false
        noIndentNext = false
    }

    /// Word's "single" spacing times 1.08 (its Normal style): the font's ascent, descent and line gap.
    func asWrittenLeading(_ s: RunStyle) -> Double {
        let f = fonts.font(for: s)
        return ((Double(CTFontGetAscent(f) + CTFontGetDescent(f) + CTFontGetLeading(f)) * 1.08) * 100).rounded() / 100
    }

    /// Appends set lines with TeX's inter-line penalties (club, widow, broken) and any pending list labels.
    func emitLines(_ lines: [SetLine], _ ctx: BlockContext, baselineskip: Double, tag: TagNode, keepTogether: Bool = false,
                   heading: Bool = false) {
        let n = lines.count
        for (k, line) in lines.enumerated() {
            if k > 0 {
                var p = 0
                if keepTogether { p = 10000 } else {
                    if k == 1 { p += style.clubPenalty }
                    if k == n - 1 { p += style.widowPenalty }
                    if lines[k - 1].endsWithHyphen { p += style.brokenPenalty }
                }
                items.append(.penalty(min(p, 10000)))
            }
            var box = line.box
            if k == 0 && !pendingLabels.isEmpty {
                for (label, x) in pendingLabels { box.ops.append(.box(label, x: x - ctx.left, y: 0)) }
                box.height = max(box.height, pendingLabels.map(\.0.height).max() ?? 0)
                pendingLabels = []
            }
            for number in line.footnotes where footnotes[number] == nil { typesetFootnote(number) }
            var v = VBox(box: box, x: ctx.left + line.x, tags: ctx.tags + [tag], footnotes: line.footnotes, line: line.info)
            v.isHeading = heading
            appendBox(v, baselineskip: baselineskip)
        }
        if let last = lines.last { lastLine = (last.naturalWidth, ctx.left + last.x) }
    }

    // MARK: Headings

    /// LaTeX's `\@startsection`: penalty and space before (none right after another heading), the title in bold at the
    /// level's size with a hanging number, no break and the space after; run-in for `\paragraph`.
    func heading(level: Int, text: DocText, _ ctx: BlockContext, numbered: Bool = true, inContents: Bool = true) {
        let index = max(0, min(level - sectionLevel, 4))
        let hs = style.headings[index]
        if !afterHeading {
            addPenalty(style.secPenalty)
            addVSpace(hs.before)
        }
        headingCount += 1
        var number: String? = nil
        if numbered && numberSections && hs.numbered {
            counters[index] += 1
            for j in (index + 1)..<counters.count { counters[j] = 0 }
            number = ((style.documentClass == .book ? [chapter] : []) + counters[0...index]).map(String.init).joined(separator: ".")
        }
        let anchor = "sec\(headingCount)"
        var base = runStyle(ctx)
        base.size = look == .asWritten ? [16, 13, 12, 11, 11][index] * fonts.normalSize / 11 : style.size(hs.size).size
        base.bold = hs.bold
        let pieces = inline(text, ctx, base: base)
        items.append(.mark(HeadingMark(level: index, title: Self.plainText(text), number: number, anchor: anchor, inContents: inContents)))
        guard let after = hs.after else {
            // Run-in heading: the title starts the next paragraph, followed by an em.
            pendingRunIn = [.box(HBox(width: 0, height: 0, depth: 0, ops: [.anchor(anchor, x: 0, y: 10)]))] + pieces
                + [.hskip(Glue(width: hs.runInSpace))]
            afterHeading = false
            noIndentNext = hs.indent == 0
            return
        }
        var full = pieces
        var hang = 0.0
        if let number {
            let numberBox = setter.natural([.text(number, base)])
            full = [.box(numberBox), .hskip(Glue(width: base.size))] + pieces   // \@seccntformat: the number and a \quad
            hang = numberBox.width + base.size
        }
        var shape = ParagraphShape(width: lineWidth(ctx))
        shape.indent = hs.indent
        shape.hangIndent = hang
        shape.alignment = look == .asWritten ? .raggedRight : .justified
        var lines = setter.set(full, shape: shape).lines
        if !lines.isEmpty { lines[0].box.ops.append(.anchor(anchor, x: 0, y: lines[0].box.height + 2)) }
        emitLines(lines, ctx, baselineskip: style.size(hs.size).leading, tag: nextTag(.heading(min(index + 1, 6))),
                  keepTogether: true, heading: true)
        items.append(.penalty(10000))
        items.append(.glue(after))
        afterHeading = true
    }

    // MARK: Lists and quotes

    func listLevel(_ depth: Int) -> ListLevel { style.lists[min(depth, style.lists.count - 1)] }

    /// LaTeX's `itemize` and `enumerate`: `\topsep` (and `\partopsep` at the top level) around, `\itemsep` plus
    /// `\parsep` between items, labels right-aligned `\labelsep` before the text.
    func list(ordered: Bool, start: Int, entries: [[DocBlock]], _ ctx: BlockContext) {
        let depth = ctx.listDepth
        let spacing = listLevel(min(depth, 2))
        addPenalty(-51)   // \@beginparpenalty
        addVSpace(spacing.topsep + (depth == 0 ? spacing.partopsep : .zero))
        var inner = ctx
        inner.left += listLevel(depth).leftMargin
        inner.listDepth += 1
        inner.parindent = 0
        inner.parskip = spacing.parsep
        let listTag = nextTag(.list)
        for (k, entry) in entries.enumerated() {
            if k > 0 { addPenalty(-51); addVSpace(spacing.itemsep) }   // \@itempenalty
            let label = labelBox(ordered: ordered, number: start + k, depth: depth, ctx)
            pendingLabels.append((label, inner.left - style.labelsep - label.width))
            var itemCtx = inner
            itemCtx.tags = ctx.tags + [listTag, nextTag(.listItem)]
            suppressParskip = true
            afterHeading = false
            compose(entry, itemCtx)
            if !pendingLabels.isEmpty {
                // An empty item: the label on a line of its own.
                let empty = SetLine(box: HBox(width: lineWidth(inner), height: 0, depth: 0, ops: []), x: 0,
                                    info: LineInfo(badness: 0, hyphenated: false, emergency: false, overfull: 0, paragraph: -1,
                                                   lineInParagraph: 0, linesInParagraph: 1, text: ""),
                                    footnotes: [], endsWithHyphen: false, naturalWidth: 0)
                emitLines([empty], itemCtx, baselineskip: style.size(ctx.size).leading, tag: nextTag(.paragraph))
            }
        }
        addPenalty(-51)
        addVSpace(spacing.topsep + (depth == 0 ? spacing.partopsep : .zero))
        suppressParskip = false
    }

    /// `\labelitemi`… and `\labelenumi`…: •, bold –, ∗, · and 1., (a), i., A.
    func labelBox(ordered: Bool, number: Int, depth: Int, _ ctx: BlockContext) -> HBox {
        var s = runStyle(ctx)
        s.verbatim = true
        let text: String
        if ordered {
            switch depth % 4 {
            case 0: text = "\(number)."
            case 1: text = "(\(Self.alpha(number)))"
            case 2: text = "\(Self.roman(number))."
            default: text = "\(Self.alpha(number).uppercased())."
            }
        } else {
            switch depth % 4 {
            case 0: text = "\u{2022}"
            case 1: text = "\u{2013}"; s.bold = true
            case 2: text = "\u{2217}"
            default: text = "\u{00B7}"
            }
        }
        return setter.natural([.text(text, s)])
    }

    static func alpha(_ n: Int) -> String {
        var n = max(1, n), s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(UInt8(97 + n % 26))) + s; n /= 26 }
        return s
    }

    static func roman(_ n: Int) -> String {
        let table: [(Int, String)] = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"),
                                      (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
        var n = max(1, n), s = ""
        for (v, r) in table { while n >= v { s += r; n -= v } }
        return s
    }

    /// The `quote` environment: a list level with equal margins on both sides.
    func quote(_ blocks: [DocBlock], _ ctx: BlockContext) {
        let depth = ctx.listDepth
        let spacing = listLevel(min(depth, 2))
        addVSpace(spacing.topsep + (depth == 0 ? spacing.partopsep : .zero))
        var inner = ctx
        inner.left += listLevel(depth).leftMargin
        inner.right += listLevel(depth).leftMargin
        inner.listDepth += 1
        inner.parindent = 0
        inner.parskip = spacing.parsep
        inner.tags = ctx.tags + [nextTag(.blockQuote)]
        suppressParskip = true
        afterHeading = false
        compose(blocks, inner)
        addVSpace(spacing.topsep + (depth == 0 ? spacing.partopsep : .zero))
        suppressParskip = false
    }

    // MARK: Code

    /// `verbatim`: Latin Modern Mono, spaces kept, lines never justified; a line wider than the measure wraps with a
    /// two-space hanging indent rather than running into the margin.
    func code(_ text: String, _ ctx: BlockContext) {
        let spacing = listLevel(min(ctx.listDepth, 2))
        addVSpace(spacing.topsep + (ctx.listDepth == 0 ? spacing.partopsep : .zero))
        var mono = runStyle(ctx)
        mono.family = .mono; mono.verbatim = true
        if look == .asWritten { mono.documentFont = "Courier New"; mono.size = max(8, fonts.normalSize - 1) }
        let font = fonts.font(for: mono)
        let width = lineWidth(ctx)
        let tag = nextTag(.code)
        var sourceLines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while sourceLines.last?.isEmpty == true { sourceLines.removeLast() }
        let leading = look == .asWritten ? asWrittenLeading(mono) : style.size(ctx.size).leading
        var space = CTFontGetGlyphWithName(font, "space" as CFString)
        let charWidth = CTFontGetAdvancesForGlyphs(font, .horizontal, &space, nil, 1)
        let maxChars = max(8, Int(width / max(charWidth, 0.1)))
        var first = true
        for raw in sourceLines {
            var chunks: [String] = []
            var rest = Substring(Self.expandTabs(raw, width: 8))
            var continuation = false
            repeat {
                let limit = continuation ? maxChars - 2 : maxChars
                if rest.count <= limit {
                    chunks.append((continuation ? "  " : "") + rest); rest = ""
                } else {
                    // Break after the last space within the limit, else at the limit.
                    let window = rest.prefix(limit)
                    let cut = window.lastIndex(of: " ").map { rest.index(after: $0) } ?? window.endIndex
                    chunks.append((continuation ? "  " : "") + rest[rest.startIndex..<cut])
                    rest = rest[cut...]
                    continuation = true
                }
            } while !rest.isEmpty
            if chunks.isEmpty { chunks = [""] }
            for chunk in chunks {
                let attributed = NSAttributedString(string: chunk, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                                kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true])
                let line = CTLineCreateWithAttributedString(attributed)
                let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                let box = HBox(width: width, height: chunk.isEmpty ? 0 : max(0, Double(ink.maxY)),
                               depth: chunk.isEmpty ? 0 : max(0, -Double(ink.minY)), ops: chunk.isEmpty ? [] : [.text(attributed, x: 0, y: 0)])
                if !first { items.append(.glue(look == .latex ? style.parskip : .zero)) }
                first = false
                appendBox(VBox(box: box, x: ctx.left, tags: ctx.tags + [tag],
                               line: LineInfo(badness: 0, hyphenated: false, emergency: false,
                                              overfull: CTLineGetTypographicBounds(line, nil, nil, nil) - width,
                                              paragraph: -1, lineInParagraph: 0, linesInParagraph: 1, text: chunk)),
                          baselineskip: leading)
            }
        }
        addVSpace(spacing.topsep + (ctx.listDepth == 0 ? spacing.partopsep : .zero))
        afterHeading = false
    }

    static func expandTabs(_ s: String, width: Int) -> String {
        guard s.contains("\t") else { return s }
        var out = ""
        for c in s {
            if c == "\t" { out += String(repeating: " ", count: width - out.count % width) } else { out.append(c) }
        }
        return out
    }

    // MARK: Display math

    /// A display: `\predisplaypenalty`, `\abovedisplayskip` (or the short skip when the line before ends well left of
    /// the formula), the formula centred (scaled down if wider than the measure), its `\tag` at the right margin.
    func displayMath(_ tex: String, _ ctx: BlockContext) {
        let size = style.size(ctx.size)
        let (box, tag) = math.box(tex, display: true, size: size.size)
        let width = lineWidth(ctx)
        let tagBox = tag.map { setter.natural([.text($0, runStyle(ctx))]) }
        var formula = box
        let available = width - (tagBox.map { $0.width + size.size } ?? 0)
        if formula.width > available {
            let scale = available / formula.width
            formula = HBox(width: available, height: box.height * scale, depth: box.depth * scale,
                           ops: [.box(Self.scaled(box, scale), x: 0, y: 0)])
        }
        var x = (width - formula.width) / 2
        if let t = tagBox, x + formula.width > width - t.width - size.size { x = max(0, width - t.width - size.size - formula.width) }
        var short = true
        if let last = lastLine, !afterHeading, !items.isEmpty { short = last.natural + last.x + 2 * size.size < ctx.left + x }
        items.append(.penalty(10000))
        items.append(.glue(short ? style.abovedisplayShort : style.abovedisplay))
        var ops: [DrawOp] = [.box(formula, x: x, y: 0)]
        if let t = tagBox { ops.append(.box(t, x: width - t.width, y: 0)) }
        let line = HBox(width: width, height: max(formula.height, tagBox?.height ?? 0), depth: max(formula.depth, tagBox?.depth ?? 0), ops: ops)
        appendBox(VBox(box: line, x: ctx.left, tags: ctx.tags + [nextTag(.formula, actualText: tex)],
                       line: LineInfo(badness: 0, hyphenated: false, emergency: false, overfull: 0, paragraph: -1,
                                      lineInParagraph: 0, linesInParagraph: 1, text: tex)),
                  baselineskip: size.leading)
        items.append(.penalty(0))
        items.append(.glue(short ? style.belowdisplayShort : style.belowdisplay))
        noIndentNext = true
        afterHeading = false
        lastLine = nil
    }

    static func scaled(_ box: HBox, _ s: Double) -> HBox {
        func scale(_ op: DrawOp) -> DrawOp {
            switch op {
            case .text(let a, let x, let y): .text(a, x: x * s, y: y * s)
            case .glyphs(let f, let g, let p, let c):
                .glyphs(CTFontCreateCopyWithAttributes(f, CTFontGetSize(f) * s, nil, nil), g, p.map { CGPoint(x: $0.x * s, y: $0.y * s) }, colour: c)
            case .rule(let x, let y, let w, let h, let c): .rule(x: x * s, y: y * s, width: w * s, height: h * s, colour: c)
            case .image(let i, let x, let y, let w, let h): .image(i, x: x * s, y: y * s, width: w * s, height: h * s)
            case .tagged(let t, let ops): .tagged(t, ops.map(scale))
            case .box(let b, let x, let y): .box(scaled(b, s), x: x * s, y: y * s)
            default: op
            }
        }
        return HBox(width: box.width * s, height: box.height * s, depth: box.depth * s, ops: box.ops.map(scale))
    }

    // MARK: Rules

    /// A centred half-measure rule (what Pandoc writes for a horizontal rule).
    func thematicBreak(_ ctx: BlockContext) {
        let spacing = listLevel(min(ctx.listDepth, 2))
        addVSpace(spacing.topsep + spacing.partopsep)
        let width = lineWidth(ctx)
        let rule = HBox(width: width, height: 0.5, depth: 0, ops: [.rule(x: width / 4, y: 0, width: width / 2, height: 0.5, colour: nil)])
        appendBox(VBox(box: rule, x: ctx.left, tags: ctx.tags + [nextTag(.division)]), baselineskip: style.size(ctx.size).leading)
        addVSpace(spacing.topsep + spacing.partopsep)
    }

    // MARK: Footnotes

    private func collectFootnotes(_ blocks: [DocBlock]) {
        for b in blocks {
            switch b {
            case .footnote(let id, let inner): footnoteDefinitions[id] = inner; collectFootnotes(inner)
            case .list(_, _, let entries): entries.forEach(collectFootnotes)
            case .quote(let inner): collectFootnotes(inner)
            case .table(let t): t.rows.forEach { $0.forEach { collectFootnotes($0.blocks) } }
            default: break
            }
        }
    }

    func footnoteNumber(_ id: String) -> Int {
        let n = footnoteIDs.count + 1
        footnoteIDs[n] = id
        return n
    }

    /// `\@makefntext`: `\footnotesize`, the mark right-aligned in a 1.8 em box, a strut of `\footnotesep` on the first
    /// line, further paragraphs indented 1 em.
    private func typesetFootnote(_ number: Int) {
        guard let id = footnoteIDs[number] else { return }
        footnotes[number] = []   // reserved, in case the footnote refers to itself
        let saved = (items, prevDepth, afterHeading, suppressParskip, noIndentNext, pendingLabels, pendingRunIn, lastLine)
        items = []; prevDepth = nil; afterHeading = false; suppressParskip = false; noIndentNext = false
        pendingLabels = []; pendingRunIn = nil
        var ctx = rootContext
        ctx.size = .footnotesize
        let fsize = style.size(.footnotesize).size
        ctx.parindent = look == .latex ? fsize : 0
        ctx.tags = [nextTag(.note)]
        var blocks = footnoteDefinitions[id] ?? []
        if blocks.isEmpty { blocks = [.paragraph([.text("")], DocParagraphStyle())] }
        var markStyle = runStyle(ctx)
        markStyle.script = .raised
        let mark = setter.natural([.text("\(number)", markStyle)])
        let boxWidth = look == .latex ? 1.8 * fsize : mark.width + 0.3 * fsize
        let markBox = HBox(width: boxWidth, height: mark.height, depth: mark.depth,
                           ops: [.box(mark, x: boxWidth - mark.width, y: 0), .anchor("fn\(number)", x: 0, y: mark.height + 6),
                                 .internalLink("fnref\(number)", x: boxWidth - mark.width, y: 0, width: mark.width, height: mark.height)])
        if case .paragraph(let text, let ps) = blocks[0] {
            paragraph([.box(markBox)] + inline(text, ctx, base: runStyle(ctx, paragraph: ps)), ctx, pstyle: ps, indent: false)
            compose(Array(blocks.dropFirst()), ctx)
        } else {
            paragraph([.box(markBox)], ctx, indent: false)
            compose(blocks, ctx)
        }
        // \footnotesep: the first line is at least as tall as the strut.
        if let i = items.firstIndex(where: { if case .box = $0 { return true }; return false }), case .box(var v) = items[i] {
            v.box.height = max(v.box.height, style.footnoteSep)
            items[i] = .box(v)
        }
        while let last = items.last, last.isDiscardable { items.removeLast() }
        footnotes[number] = items
        (items, prevDepth, afterHeading, suppressParskip, noIndentNext, pendingLabels, pendingRunIn, lastLine) = saved
    }

    // MARK: Figures

    struct LoadedImage { var content: ImageContent; var width: Double; var height: Double }

    /// A picture at its natural size (72 dpi when the file says nothing, as pdfTeX assumes); JPEG data passes through
    /// to the PDF untouched; PDF pictures stay vector.
    func loadImage(_ name: String) -> LoadedImage? {
        guard let data = resources[name] else { return nil }
        if data.starts(with: Array("%PDF".utf8)), let provider = CGDataProvider(data: data as CFData),
           let doc = CGPDFDocument(provider), let page = doc.page(at: 1) {
            let box = page.getBoxRect(.cropBox)
            return LoadedImage(content: .pdf(page), width: Double(box.width).fromBP, height: Double(box.height).fromBP)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var image: CGImage?
        if (CGImageSourceGetType(source) as String?) == "public.jpeg", let provider = CGDataProvider(data: data as CFData) {
            image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        if image == nil { image = CGImageSourceCreateImageAtIndex(source, 0, nil) }
        guard let cg = image else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpiX = (props?[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 1 ? $0 : nil } ?? 72
        let dpiY = (props?[kCGImagePropertyDPIHeight] as? Double).flatMap { $0 > 1 ? $0 : nil } ?? dpiX
        return LoadedImage(content: .raster(cg), width: Double(cg.width) * 72.27 / dpiX, height: Double(cg.height) * 72.27 / dpiY)
    }

    /// A figure: a float (`[tbp]`) with "Figure n: …" below when it has a caption, else the picture centred in the text.
    func figure(resource: String, caption: DocText?, alt: String?, _ ctx: BlockContext) {
        let width = lineWidth(ctx)
        guard let img = loadImage(resource) else {
            droppedImages += 1
            var s = runStyle(ctx); s.shape = .italic
            paragraph([.text("[\(alt ?? resource)]", s)], ctx)
            return
        }
        let scale = min(1, width / img.width, style.geometry.textHeight * (caption == nil ? 0.9 : 0.75) / img.height)
        let w = img.width * scale, h = img.height * scale
        let picture = HBox(width: width, height: h, depth: 0, ops: [.image(img.content, x: (width - w) / 2, y: 0, width: w, height: h)])
        let tag = nextTag(.figure, alt: alt ?? caption.map(Self.plainText))
        if let caption {
            figureCount += 1
            let saved = (items, prevDepth)
            items = []; prevDepth = nil
            appendBox(VBox(box: picture, x: ctx.left, tags: ctx.tags + [tag]), baselineskip: style.normal.leading)
            items.append(.glue(Glue(width: style.abovecaptionskip)))
            captionLines(label: "Figure \(figureCount)", caption, ctx)
            let floatItems = items
            (items, prevDepth) = saved
            items.append(.float(FloatBlock(items: floatItems, height: Self.height(of: floatItems))))
            return
        }
        let spacing = listLevel(min(ctx.listDepth, 2))
        addVSpace(spacing.topsep + spacing.partopsep)
        appendBox(VBox(box: picture, x: ctx.left, tags: ctx.tags + [tag]), baselineskip: style.normal.leading)
        addVSpace(spacing.topsep + spacing.partopsep)
        afterHeading = false
        lastLine = nil
    }

    /// `\@makecaption`: "Figure 1: …" centred when it fits on a line, else a full-width paragraph.
    func captionLines(label: String, _ caption: DocText, _ ctx: BlockContext) {
        let s = runStyle(ctx)
        let pieces: [InlinePiece] = [.text(label + ": ", s)] + inline(caption, ctx, base: s)
        var shape = ParagraphShape(width: lineWidth(ctx))
        shape.alignment = setter.natural(pieces).width <= lineWidth(ctx) ? .centred : .justified
        emitLines(setter.set(pieces, shape: shape).lines, ctx, baselineskip: style.normal.leading, tag: nextTag(.caption))
    }

    /// Natural height of a vertical list.
    static func height(of items: [VItem]) -> Double {
        var h = 0.0, lastDepth = 0.0
        for item in items {
            switch item {
            case .box(let b): h += lastDepth + b.box.height; lastDepth = b.box.depth
            case .glue(let g): h += g.width
            case .kern(let k): h += k
            default: break
            }
        }
        return h + lastDepth
    }

    // MARK: Tables

    func nextTableID() -> Int { tableIDs += 1; return tableIDs }
    func registerTableHeader(_ id: Int, _ items: [VItem]) { tableHeaders[id] = items }
    func noteTableSimplified() { tableSimplified = true }

    func table(_ t: DocTable, _ ctx: BlockContext) {
        let number = t.caption != nil ? tableCount + 1 : nil
        if number != nil { tableCount += 1 }
        let result = TableComposer(composer: self, ctx: ctx).compose(t, number: number)
        if result.isFloat {
            items.append(.float(FloatBlock(items: result.items, height: Self.height(of: result.items))))
        } else {
            let spacing = listLevel(min(ctx.listDepth, 2))
            addVSpace(spacing.topsep + spacing.partopsep)
            items += result.items
            addVSpace(spacing.topsep + spacing.partopsep)
            prevDepth = nil
        }
        afterHeading = false
        lastLine = nil
    }

    /// A table of a spreadsheet, in the text.
    func appendTable(_ result: TableComposer.Result) {
        items += result.items
        items.append(.glue(Glue(width: 12, stretch: 2, shrink: 2)))
        prevDepth = nil
    }

    // MARK: Title block, abstract, contents

    /// `\maketitle` (article): `\null`, 2 em, the `center` environment with the title in `\LARGE`, 1.5 em, the authors
    /// in `\large` tabulars side by side, 1 em, the date; then 1.5 em.
    func titleBlock(_ meta: DocMetadata, _ ctx: BlockContext) {
        guard let title = meta.title, !title.isEmpty else { return }
        let em = style.em
        let center = style.lists[0]
        appendBox(VBox(box: .empty, x: 0, tags: [nextTag(.division)]), baselineskip: 0)   // \null
        items.append(.glue(Glue(width: 2 * em)))
        addVSpace(center.topsep + center.partopsep)
        var titleStyle = runStyle(ctx)
        let titleSize = style.size(.LARGE)
        titleStyle.size = titleSize.size
        if look == .asWritten { titleStyle.size = 2 * fonts.normalSize; titleStyle.bold = true }
        var shape = ParagraphShape(width: lineWidth(ctx))
        shape.alignment = .centred
        shape.hyphenate = false
        emitLines(setter.set([.text(title, titleStyle)], shape: shape).lines, ctx, baselineskip: titleSize.leading,
                  tag: nextTag(.heading(1)), keepTogether: true)
        items.append(.glue(Glue(width: 1.5 * em)))
        let large = style.size(.large)
        var authorStyle = runStyle(ctx)
        authorStyle.size = large.size
        // The authors' tabular is there even when it is empty, as in LaTeX; so is the 1 em before the date.
        emitLines([authorLine(meta.authors, authorStyle, width: lineWidth(ctx), leading: large.leading)], ctx,
                  baselineskip: large.leading, tag: nextTag(.paragraph), keepTogether: true)
        items.append(.glue(Glue(width: em)))
        if let date = meta.date {
            let f = DateFormatter()
            f.locale = Locale(identifier: meta.language ?? "en_US")
            f.setLocalizedDateFormatFromTemplate("MMMMdyyyy")
            emitLines(setter.set([.text(f.string(from: date), authorStyle)], shape: shape).lines, ctx, baselineskip: large.leading,
                      tag: nextTag(.paragraph), keepTogether: true)
        }
        addVSpace(center.topsep + center.partopsep)
        items.append(.glue(Glue(width: 1.5 * em)))
        afterHeading = false
        noIndentNext = false
    }

    /// The authors as `\begin{tabular}[t]{c}` boxes joined by `\and` (`\hskip 1em plus .17fil`), centred: each tabular
    /// has `\tabcolsep` on both sides and a strut, and the line's slack is shared by the centring and the .17fil glue.
    private func authorLine(_ authors: [String], _ s: RunStyle, width: Double, leading: Double) -> SetLine {
        let boxes = (authors.isEmpty ? [""] : authors).map { setter.natural([.text($0, s)]) }
        let tabcolsep = 6.0, quad = s.size
        let natural = boxes.reduce(0.0) { $0 + $1.width + 2 * tabcolsep } + Double(boxes.count - 1) * quad
        let slack = max(0, width - natural)
        let filTotal = 2 + 0.17 * Double(boxes.count - 1)
        var x = slack / filTotal
        var ops: [DrawOp] = []
        for (k, b) in boxes.enumerated() {
            if k > 0 { x += quad + slack * 0.17 / filTotal }
            ops.append(.box(b, x: x + tabcolsep, y: 0))
            x += b.width + 2 * tabcolsep
        }
        let height = max(0.7 * leading, boxes.map(\.height).max() ?? 0), depth = max(0.3 * leading, boxes.map(\.depth).max() ?? 0)
        return SetLine(box: HBox(width: width, height: height, depth: depth, ops: ops), x: 0,
                       info: LineInfo(badness: 0, hyphenated: false, emergency: false, overfull: 0, paragraph: -1, lineInParagraph: 0,
                                      linesInParagraph: 1, text: authors.joined(separator: " ")),
                       footnotes: [], endsWithHyphen: false, naturalWidth: natural)
    }

    /// The `abstract` environment: `\small`, a centred bold "Abstract", then a `quotation`.
    func abstract(_ text: String, _ ctx: BlockContext) {
        var c = ctx
        c.size = .small
        let small = style.size(.small)
        var heading = runStyle(c)
        heading.bold = true
        let spacing = style.lists[0]
        addVSpace(spacing.topsep + spacing.partopsep)
        var shape = ParagraphShape(width: lineWidth(c))
        shape.alignment = .centred
        emitLines(setter.set([.text("Abstract", heading)], shape: shape).lines, c, baselineskip: small.leading, tag: nextTag(.heading(2)))
        items.append(.glue(Glue(width: -0.5 * small.size)))
        addVSpace(spacing.topsep)
        var inner = c
        inner.left += spacing.leftMargin
        inner.right += spacing.leftMargin
        inner.parindent = 1.5 * small.size
        suppressParskip = true
        for para in text.components(separatedBy: "\n\n") where !para.trimmingCharacters(in: .whitespaces).isEmpty {
            paragraph([.text(para.replacingOccurrences(of: "\n", with: " "), runStyle(inner))], inner, indent: true)
        }
        addVSpace(spacing.topsep + spacing.partopsep)
    }

    /// `\tableofcontents`: an unnumbered "Contents" section, then a line per heading — sections in bold with the page
    /// at the right, lower levels indented with dot leaders (`\@dottedtocline`), each linked to its heading.
    func contents(_ marks: [HeadingMark], _ ctx: BlockContext) {
        heading(level: sectionLevel, text: [.text("Contents")], ctx, numbered: false, inContents: false)
        let em = style.em
        let pnumWidth = 1.55 * em, rightMargin = 2.55 * em
        let width = lineWidth(ctx)
        for mark in marks where mark.inContents && mark.level <= 2 {
            var s = runStyle(ctx)
            let indent: Double, numWidth: Double
            switch mark.level {
            case 0: indent = 0; numWidth = 1.5 * em; s.bold = look == .latex
            case 1: indent = 1.5 * em; numWidth = 2.3 * em
            default: indent = 3.8 * em; numWidth = 3.2 * em
            }
            if mark.level == 0 { addPenalty(style.secPenalty); addVSpace(Glue(width: em, stretch: 1)) }
            var pieces: [InlinePiece] = []
            if let n = mark.number {
                let nb = setter.natural([.text(n, s)])
                pieces.append(.box(HBox(width: max(numWidth, nb.width + 0.5 * em), height: nb.height, depth: nb.depth, ops: [.box(nb, x: 0, y: 0)])))
            }
            pieces.append(.text(mark.title, s))
            var shape = ParagraphShape(width: width - indent - rightMargin)
            shape.alignment = .raggedRight
            shape.hyphenate = false
            var lines = setter.set(pieces, shape: shape).lines
            guard var last = lines.last else { continue }
            let pageBox = setter.natural([.text(headingPages[mark.anchor] ?? "0", s)])
            let end = width - indent
            if mark.level > 0 {
                // \leaders\hbox{$\mkern 4.5mu . \mkern 4.5mu$}\hfill, aligned on a common grid.
                let dot = setter.natural([.text(".", runStyle(ctx))])
                let unit = 2 * 4.5 * em / 18 + dot.width
                var x = (((indent + last.naturalWidth + 0.5 * em) / unit).rounded(.down) + 1) * unit - indent
                while x + unit <= end - pnumWidth { last.box.ops.append(.box(dot, x: x + (unit - dot.width) / 2, y: 0)); x += unit }
            }
            last.box.ops.append(.box(pageBox, x: end - pageBox.width, y: 0))
            last.box.ops.append(.internalLink(mark.anchor, x: 0, y: -last.box.depth, width: end, height: last.box.height + last.box.depth))
            last.box.width = end
            lines[lines.count - 1] = last
            var c = ctx
            c.left += indent
            if !items.isEmpty { items.append(.glue(ctx.parskip)) }
            emitLines(lines, c, baselineskip: style.normal.leading, tag: nextTag(.tocItem))
        }
        afterHeading = false
    }

    // MARK: Book class

    /// `\chapter` (book): a new page, 50 pt down, "Chapter n" in `\huge` bold for numbered chapters, the title in
    /// `\Huge` bold, 40 pt after.
    func chapterHeading(_ title: String?, numbered: Bool, _ ctx: BlockContext) {
        items.append(.chapterStart(title))
        prevDepth = nil
        chapter += 1
        counters = [0, 0, 0, 0, 0]
        guard let title, !title.isEmpty else { return }
        headingCount += 1
        let anchor = "sec\(headingCount)"
        items.append(.mark(HeadingMark(level: -1, title: title, number: numbered ? "\(chapter)" : nil, anchor: anchor, inContents: true)))
        items.append(.kern(style.chapterBefore))
        var shape = ParagraphShape(width: lineWidth(ctx))
        shape.alignment = .raggedRight
        shape.hyphenate = false
        if numbered {
            var s = runStyle(ctx); s.bold = true; s.size = style.size(.huge).size
            emitLines(setter.set([.text("Chapter \(chapter)", s)], shape: shape).lines, ctx, baselineskip: style.size(.huge).leading,
                      tag: nextTag(.heading(1)), keepTogether: true, heading: true)
            items.append(.penalty(10000))
            items.append(.kern(style.chapterGap))
        }
        var s = runStyle(ctx); s.bold = true; s.size = style.size(.Huge).size
        var lines = setter.set([.text(title, s)], shape: shape).lines
        if !lines.isEmpty { lines[0].box.ops.append(.anchor(anchor, x: 0, y: lines[0].box.height + 2)) }
        emitLines(lines, ctx, baselineskip: style.size(.Huge).leading, tag: nextTag(.heading(1)), keepTogether: true, heading: true)
        items.append(.penalty(10000))
        items.append(.kern(style.chapterAfter))
        afterHeading = true
    }

    /// What could not be carried over.
    func finish() -> [LossNote] {
        var notes: [LossNote] = []
        if droppedImages > 0 { notes.append(LossNote(.imagesDropped, detail: "\(droppedImages) picture(s) couldn’t be read")) }
        if formattingDropped { notes.append(LossNote(.formattingSimplified, detail: "Fonts, sizes and colours follow the LaTeX look")) }
        if tableSimplified { notes.append(LossNote(.tableSimplified, detail: "Merged rows or very wide tables were simplified")) }
        return notes
    }

    /// Lines of text set at `width`, for table cells.
    func cellLines(_ pieces: [InlinePiece], width: Double, alignment: ParagraphAlignment) -> [SetLine] {
        var shape = ParagraphShape(width: width)
        shape.alignment = alignment
        shape.hyphenate = setter.hyphenator != nil
        return setter.set(pieces, shape: shape).lines
    }
}
