import CoreGraphics
import CoreText
import Foundation

/// Paragraph alignment, as LaTeX's `\leftskip`/`\rightskip`/`\parfillskip` settings.
enum ParagraphAlignment: Sendable {
    case justified, raggedRight, centred, raggedLeft
}

/// Where the paragraph's lines go and how they are shaped.
struct ParagraphShape {
    var width: Double
    var indent: Double = 0
    var alignment: ParagraphAlignment = .justified
    /// `\hangindent` for lines after the first (numbered headings hang under their title).
    var hangIndent: Double = 0
    var hyphenate = true
}

/// A set line: the box and what the lint needs to know.
struct SetLine {
    var box: HBox
    var x: Double
    var info: LineInfo
    var footnotes: [Int]
    var endsWithHyphen: Bool
    /// The line's natural width (display math's short skips, the contents page's leaders).
    var naturalWidth: Double
}

/// Turns inline pieces into Knuth–Plass items (word fragments shaped with Core Text so kerning and ligatures apply,
/// glue with TeX's space factors, hyphenation and explicit-hyphen penalties, microtype protrusion), breaks them into
/// lines and sets each line's glue.
final class ParagraphSetter {
    let fonts: FontResolver
    let hyphenator: Hyphenator?
    let mathBox: (String, RunStyle) -> HBox
    var paragraphCounter = 0

    init(fonts: FontResolver, hyphenator: Hyphenator?, mathBox: @escaping (String, RunStyle) -> HBox) {
        self.fonts = fonts; self.hyphenator = hyphenator; self.mathBox = mathBox
    }

    // MARK: Building

    private struct Word {
        var string: NSAttributedString
        var height: Double
        var depth: Double
        var link: String?
        /// Underline/strike ranges in the word's UTF-16 indices.
        var decorations: [(range: NSRange, underline: Bool, strike: Bool, size: Double)]
    }

    private enum Fragment {
        case word(Int, NSRange)
        case object(HBox, link: String?)
        case footnote(HBox, number: Int)
        case kern
    }

    private struct Built {
        var items: [BreakItem] = []
        var fragments: [Fragment] = []
        var words: [Word] = []
    }

    static let underlineKey = NSAttributedString.Key("TSUnderline")
    static let strikeKey = NSAttributedString.Key("TSStrike")

    /// Characters' protrusion into the margins, in thousandths of their width: microtype's settings for Latin Modern
    /// in T1 (mt-cmr.cfg: `cmr-default`, `cmr-T1`, `lmr-T1`), as `\usepackage{microtype}` applies them.
    static let protrusion: [Character: (left: Double, right: Double)] = [
        "A": (50, 50), "F": (0, 50), "J": (50, 0), "K": (0, 50), "L": (0, 50), "T": (50, 50), "V": (50, 50),
        "W": (50, 50), "X": (50, 50), "Y": (50, 50), "k": (0, 50), "r": (0, 50), "t": (0, 70), "v": (50, 50),
        "w": (50, 50), "x": (50, 50), "y": (50, 70), "0": (0, 50), "1": (100, 200), "2": (50, 50), "3": (50, 50),
        "4": (70, 70), "5": (0, 50), "6": (0, 50), "7": (50, 100), "8": (0, 50), "9": (0, 50), ".": (0, 700),
        ",": (0, 500), ":": (0, 500), ";": (0, 500), "!": (0, 100), "?": (0, 200), "@": (50, 50), "~": (200, 250),
        "%": (50, 50), "*": (300, 300), "+": (250, 250), "(": (300, 0), ")": (0, 300), "/": (200, 300),
        "-": (400, 500), "\u{2010}": (400, 500), "\u{2013}": (400, 300), "\u{2014}": (300, 200),
        "\u{2018}": (500, 700), "\u{2019}": (500, 600), "\u{201C}": (300, 400), "\u{201D}": (300, 400),
        "\u{201A}": (400, 400), "\u{201E}": (400, 400), "\u{2039}": (400, 400), "\u{203A}": (300, 500),
        "\u{00AB}": (300, 200), "\u{00BB}": (100, 400), "\u{00A1}": (100, 0), "\u{00BF}": (100, 0),
        "_": (200, 200), "\\": (200, 300), "\"": (300, 300), "{": (400, 200), "}": (200, 400), "<": (200, 100),
        ">": (100, 200),
    ]

    /// microtype's `basictext` set: protrusion for medium-weight roman and sans text up to `\large`; never for bold,
    /// monospaced or display sizes.
    private func protrudes(_ font: CTFont) -> Bool {
        let traits = CTFontGetSymbolicTraits(font)
        if traits.contains(.traitBold) || traits.contains(.traitMonoSpace) { return false }
        if (CTFontCopyPostScriptName(font) as String).lowercased().contains("mono") { return false }
        return Double(CTFontGetSize(font)) <= fonts.normalSize * 1.21
    }

    private func protrusionAmount(_ c: Character, right: Bool, font: CTFont) -> Double {
        guard let p = Self.protrusion[c], protrudes(font) else { return 0 }
        let factor = right ? p.right : p.left
        return factor == 0 ? 0 : factor / 1000 * advance(of: c, in: font)
    }

    private func advance(of c: Character, in font: CTFont) -> Double {
        let utf16 = Array(String(c).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) else { return 0 }
        return CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, nil, glyphs.count)
    }

    /// The inter-word glue of a style's font (TeX's \fontdimen2–4 and 7, in the proportions of the TFM files: roman
    /// ⅓ em plus ½ minus ⅓ of that; italic a little tighter; typewriter fixed).
    func spaceGlue(_ style: RunStyle, spaceFactor sf: Int) -> Glue {
        let w = advance(of: " ", in: fonts.font(for: style))
        var stretch: Double, shrink: Double, extra: Double
        if style.family == .mono && style.documentFont == nil { stretch = 0; shrink = 0; extra = w }
        else if style.italic && style.documentFont == nil { stretch = 0.4286 * w; shrink = 0.2857 * w; extra = 0.2857 * w }
        else { stretch = w / 2; shrink = w / 3; extra = w / 3 }
        var width = w
        if sf >= 2000 { width += extra }
        if sf != 1000 && sf > 0 { stretch = stretch * Double(sf) / 1000; shrink = shrink * 1000 / Double(sf) }
        return Glue(width: width, stretch: stretch, shrink: shrink)
    }

    private func attributes(_ style: RunStyle) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: fonts.font(for: style)]
        if let colour = style.colour, let cg = Self.colour(colour) {
            a[kCTForegroundColorAttributeName as NSAttributedString.Key] = cg
        } else {
            a[kCTForegroundColorFromContextAttributeName as NSAttributedString.Key] = true
        }
        if style.underline { a[Self.underlineKey] = style.size }
        if style.strike { a[Self.strikeKey] = style.size }
        return a
    }

    static func colour(_ hex: String) -> CGColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16), v != 0 else { return nil }
        return CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    private func build(_ pieces: [InlinePiece], shape: ParagraphShape) -> Built {
        var b = Built()
        if shape.indent > 0 {
            b.fragments.append(.kern)
            b.items.append(.box(shape.indent, fragment: 0))
        }
        var current = NSMutableAttributedString()
        var currentText = ""
        var currentLink: String?
        var currentVerbatim = true
        var currentURL = false
        var link: String?
        var previousChar: Character?
        var pendingSpace: RunStyle?
        var lastWordText = ""
        var lastWasWord = false

        func flushWord() {
            guard current.length > 0 else { return }
            emitWord(current, text: currentText, link: currentLink, verbatim: currentVerbatim, url: currentURL, into: &b, shape: shape)
            lastWordText = currentText
            lastWasWord = true
            current = NSMutableAttributedString(); currentText = ""; currentLink = nil; currentVerbatim = true; currentURL = false
        }
        func flushSpace(nonBreaking: Bool = false) {
            guard let style = pendingSpace else { return }
            pendingSpace = nil
            guard !b.items.isEmpty, b.items.last?.kind != .glue else { return }
            var sf = 1000
            if lastWasWord && !style.verbatim {
                sf = SpaceFactor.after(lastWordText)
                let bare = lastWordText.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "(\u{201C}\u{2018}\u{201D}\u{2019}\"')"))
                if sf >= 2000, SpaceFactor.abbreviations.contains(bare) { sf = 1000 }
            }
            if nonBreaking { b.items.append(.penalty(10000)) }
            b.items.append(.glue(spaceGlue(style, spaceFactor: sf)))
        }
        func appendObject(_ box: HBox, fragment: Fragment) {
            flushWord(); flushSpace()
            b.fragments.append(fragment)
            b.items.append(.box(box.width, fragment: b.fragments.count - 1))
            lastWasWord = false
        }

        for piece in pieces {
            switch piece {
            case .text(let raw, let style):
                if style.script != .none {
                    let box = scriptBox(raw, style)
                    appendObject(box, fragment: .object(box, link: link))
                    previousChar = raw.last
                    continue
                }
                let text = style.verbatim ? raw : Punctuation.smarten(raw, after: previousChar)
                let attrs = attributes(style)
                for c in text {
                    if c == "\u{00A0}" {
                        flushWord(); pendingSpace = style; flushSpace(nonBreaking: true); lastWasWord = false
                    } else if c.isWhitespace {
                        flushWord()
                        if pendingSpace == nil { pendingSpace = style }
                    } else if c == "\u{200B}" {
                        flushWord(); flushSpace(); b.items.append(.penalty(0))
                    } else {
                        if pendingSpace != nil { flushSpace() }
                        current.append(NSAttributedString(string: String(c), attributes: attrs))
                        currentText.append(c)
                        if !style.verbatim { currentVerbatim = false }
                        if style.isURL { currentURL = true }
                        if currentLink == nil { currentLink = link }
                    }
                    previousChar = c
                }
            case .math(let tex, let style):
                let box = mathBox(tex, style)
                appendObject(box, fragment: .object(box, link: link))
                previousChar = "x"
            case .footnote(let number, let style):
                let box = footnoteMark(number, style)
                appendObject(box, fragment: .footnote(box, number: number))
            case .image(let content, let w, let h):
                let box = HBox(width: w, height: h, depth: 0, ops: [.image(content, x: 0, y: 0, width: w, height: h)])
                appendObject(box, fragment: .object(box, link: link))
            case .box(let box):
                appendObject(box, fragment: .object(box, link: link))
            case .hskip(let g):
                flushWord(); pendingSpace = nil
                b.items.append(.glue(g))
                lastWasWord = false
            case .lineBreak:
                flushWord(); pendingSpace = nil
                while b.items.last?.kind == .glue { b.items.removeLast() }
                b.items.append(.glue(.fil()))
                b.items.append(.penalty(-10000))
                lastWasWord = false
            case .linkStart(let url):
                link = url
            case .linkEnd:
                flushWord()
                link = nil
            }
        }
        flushWord()
        // TeX's \par: remove the last glue (and a trailing \\), then \penalty10000 \parfillskip and the final break.
        while let last = b.items.last, last.kind == .glue || last.kind == .penalty { b.items.removeLast() }
        b.items.append(.penalty(10000))
        b.items.append(.glue(shape.alignment == .centred || shape.alignment == .raggedLeft ? .zero : .fil()))
        b.items.append(.penalty(-10000))
        return b
    }

    private func emitWord(_ string: NSAttributedString, text: String, link: String?, verbatim: Bool, url: Bool,
                          into b: inout Built, shape: ParagraphShape) {
        let attributed = italicCorrected(string)
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        var decorations: [(range: NSRange, underline: Bool, strike: Bool, size: Double)] = []
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            let u = attrs[Self.underlineKey] as? Double, s = attrs[Self.strikeKey] as? Double
            if u != nil || s != nil { decorations.append((range, u != nil, s != nil, u ?? s ?? 10)) }
        }
        let wordIndex = b.words.count
        b.words.append(Word(string: attributed, height: max(0, Double(ink.maxY)), depth: max(0, -Double(ink.minY)),
                            link: link, decorations: decorations))
        let ns = text as NSString
        let count = attributed.length

        // Break opportunities inside the word.
        struct Point { var index: Int; var hyphen: Bool; var penalty: Int; var flagged: Bool; var hyphenation: Bool; var lastResort: Bool }
        var points: [Point] = []
        // After explicit hyphens (\exhyphenpenalty 50), never at the very start or end.
        for i in 1..<max(1, count) where i < count - 1 {
            let c = ns.character(at: i - 1)
            if c == 0x2D || c == 0x2010 { points.append(Point(index: i, hyphen: false, penalty: 50, flagged: true, hyphenation: false, lastResort: false)) }
        }
        if url {
            // url.sty: breaks after / . - _ ? & = # :, not inside "//".
            for i in 1..<max(1, count) where i < count - 1 {
                let c = Character(UnicodeScalar(ns.character(at: i - 1)) ?? " ")
                let next = Character(UnicodeScalar(ns.character(at: i)) ?? " ")
                if "/.-_?&=#:".contains(c) && next != "/" {
                    points.append(Point(index: i, hyphen: false, penalty: 100, flagged: false, hyphenation: false, lastResort: false))
                }
            }
        } else if !verbatim, shape.hyphenate, points.isEmpty, let hyphenator {
            // The letters of the word, without leading and trailing punctuation.
            let leading = text.prefix(while: { !$0.isLetter })
            let core = String(String(text.dropFirst(leading.count)).reversed().drop(while: { !$0.isLetter }).reversed())
            for p in hyphenator.points(in: core) {
                points.append(Point(index: leading.utf16.count + p, hyphen: true, penalty: 50, flagged: true, hyphenation: true, lastResort: false))
            }
        }
        // Last resort: any grapheme boundary of a long word.
        if width > shape.width * 0.2 {
            let existing = Set(points.map(\.index))
            let alphabetic = text.allSatisfy { $0.isLetter }
            var idx = 0
            for ch in text.dropLast() {
                idx += ch.utf16.count
                if !existing.contains(idx) && idx > 1 && idx < count - 1 {
                    points.append(Point(index: idx, hyphen: alphabetic && !verbatim, penalty: alphabetic ? 5000 : 1000,
                                        flagged: alphabetic, hyphenation: false, lastResort: true))
                }
            }
        }
        points.sort { $0.index < $1.index }

        func fontAt(_ i: Int) -> CTFont {
            attributed.attribute(kCTFontAttributeName as NSAttributedString.Key, at: min(max(i, 0), count - 1), effectiveRange: nil) as! CTFont
        }
        let left = protrusionAmount(text.first!, right: false, font: fontAt(0))
        let right = protrusionAmount(text.last!, right: true, font: fontAt(count - 1))
        guard !points.isEmpty else {
            b.fragments.append(.word(wordIndex, NSRange(location: 0, length: count)))
            b.items.append(.box(width, fragment: b.fragments.count - 1, left: left, right: right))
            return
        }
        func offset(_ i: Int) -> Double { Double(CTLineGetOffsetForStringIndex(line, i, nil)) }
        func standalone(_ s: NSAttributedString) -> Double { CTLineGetTypographicBounds(CTLineCreateWithAttributedString(s), nil, nil, nil) }
        var start = 0
        var startOffset = 0.0
        for (k, p) in points.enumerated() {
            let o = offset(p.index)
            let before = Character(UnicodeScalar(ns.character(at: p.index - 1)) ?? " ")
            b.fragments.append(.word(wordIndex, NSRange(location: start, length: p.index - start)))
            b.items.append(.box(o - startOffset, fragment: b.fragments.count - 1, left: k == 0 ? left : 0,
                                right: protrusionAmount(before, right: true, font: fontAt(p.index - 1))))
            var item = BreakItem.penalty(p.penalty, flagged: p.flagged)
            item.isHyphenation = p.hyphenation
            item.lastResort = p.lastResort
            if p.lastResort {
                if p.hyphen { item.width = advance(of: "-", in: fontAt(p.index - 1)); item.hyphenText = "-" }
            } else {
                // The broken halves shaped on their own (kerning and ligatures across the break undone).
                let prefix = attributed.attributedSubstring(from: NSRange(location: 0, length: p.index))
                let suffix = attributed.attributedSubstring(from: NSRange(location: p.index, length: count - p.index))
                if p.hyphen {
                    let withHyphen = NSMutableAttributedString(attributedString: prefix)
                    withHyphen.append(NSAttributedString(string: "-", attributes: attributed.attributes(at: p.index - 1, effectiveRange: nil)))
                    item.width = standalone(withHyphen) - o
                    item.hyphenText = "-"
                    item.rightProtrusion = protrusionAmount("-", right: true, font: fontAt(p.index - 1))
                } else {
                    item.width = standalone(prefix) - o
                }
                item.postWidth = standalone(suffix) - (width - o)
            }
            b.items.append(item)
            start = p.index
            startOffset = o
        }
        b.fragments.append(.word(wordIndex, NSRange(location: start, length: count - start)))
        b.items.append(.box(width - startOffset, fragment: b.fragments.count - 1, left: 0, right: right))
    }

    /// TeX's italic correction (`\/`, which `\emph` and `\textit` add unless a period or comma follows) where italic
    /// text meets upright text inside a word or at the end of a word: the amount the last glyph's ink overhangs its
    /// advance.
    private func italicCorrected(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        var runs: [(NSRange, CTFont)] = []
        s.enumerateAttribute(kCTFontAttributeName as NSAttributedString.Key, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if let f = v { runs.append((r, f as! CTFont)) }
        }
        let ns = s.string as NSString
        for (k, (range, font)) in runs.enumerated() where CTFontGetSlantAngle(font) != 0 {
            let lastIndex = range.location + range.length - 1
            if k + 1 < runs.count {
                let next = ns.character(at: range.location + range.length)
                if next == 0x2E || next == 0x2C || CTFontGetSlantAngle(runs[k + 1].1) != 0 { continue }
            }
            let utf16 = Array(ns.substring(with: NSRange(location: lastIndex, length: 1)).utf16)
            var g = [CGGlyph](repeating: 0, count: utf16.count)
            guard CTFontGetGlyphsForCharacters(font, utf16, &g, utf16.count) else { continue }
            var rect = CGRect.zero
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, g, &rect, 1)
            let correction = Double(rect.maxX) - CTFontGetAdvancesForGlyphs(font, .horizontal, g, nil, 1)
            if correction > 0.01 {
                m.addAttribute(kCTKernAttributeName as NSAttributedString.Key, value: correction, range: NSRange(location: lastIndex, length: 1))
            }
        }
        return m
    }

    /// `\textsuperscript`/`\textsubscript`: the text at `\sf@size`, raised by 0.413 em or lowered by 0.15 em (cmsy's
    /// sup1 and sub1).
    private func scriptBox(_ text: String, _ style: RunStyle) -> HBox {
        var small = style
        small.size = StyleSheet.scriptSize(of: style.size)
        small.script = .none
        let attributed = NSAttributedString(string: text, attributes: attributes(small))
        let line = CTLineCreateWithAttributedString(attributed)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let shift = style.script == .raised ? 0.412892 * style.size : -0.149998 * style.size
        return HBox(width: CTLineGetTypographicBounds(line, nil, nil, nil), height: max(0, Double(ink.maxY) + shift),
                    depth: max(0, -Double(ink.minY) - shift), ops: [.text(attributed, x: 0, y: shift)])
    }

    /// A footnote mark (`\@makefnmark`): the number as a superscript, linked to the footnote.
    private func footnoteMark(_ number: Int, _ style: RunStyle) -> HBox {
        var plain = style
        plain.bold = false; plain.shape = .upright; plain.script = .raised; plain.underline = false; plain.strike = false
        var box = scriptBox("\(number)", plain)
        box.ops.append(.internalLink("fn\(number)", x: 0, y: -box.depth, width: box.width, height: box.height + box.depth))
        box.ops.append(.anchor("fnref\(number)", x: 0, y: box.height + 8))
        return box
    }

    // MARK: Setting

    /// Breaks `pieces` into lines of `shape` and sets them: Knuth–Plass for justified text; for ragged and centred text
    /// each line takes as many words as fit.
    func set(_ pieces: [InlinePiece], shape: ParagraphShape) -> (lines: [SetLine], pass: Int) {
        paragraphCounter += 1
        let built = build(pieces, shape: shape)
        let items = built.items
        let lineWidth: (Int) -> Double = { line in line == 0 || shape.hangIndent == 0 ? shape.width : shape.width - shape.hangIndent }
        let result: BreakResult
        if shape.alignment == .justified {
            var params = BreakParameters(lineWidth: lineWidth)
            params.hyphenate = shape.hyphenate && hyphenator != nil
            params.distinctLines = shape.hangIndent != 0 ? 2 : 0
            params.emergencyStretch = 3 * fonts.normalSize
            result = LineBreaker.breakLines(items, params)
        } else {
            result = LineBreaker.firstFit(items, lineWidth: lineWidth)
        }
        var lines: [SetLine] = []
        var start = 0
        var startPost = 0.0
        for (k, br) in result.breaks.enumerated() {
            let end = br.position
            let width = lineWidth(k)
            let set = setLine(built, from: start, to: end, postWidth: startPost, width: width, alignment: shape.alignment)
            let hyphenated = items[end].kind == .penalty && items[end].flagged
            let info = LineInfo(badness: br.filStretch || shape.alignment != .justified ? 0 : br.badness, hyphenated: hyphenated,
                                emergency: result.pass >= 3, overfull: set.overfull, paragraph: paragraphCounter,
                                lineInParagraph: k, linesInParagraph: result.breaks.count, text: set.text)
            lines.append(SetLine(box: set.box, x: k > 0 ? shape.hangIndent : 0, info: info, footnotes: set.footnotes,
                                 endsWithHyphen: hyphenated, naturalWidth: set.naturalContent))
            var j = end + 1
            while j < items.count, items[j].kind != .box, !(items[j].kind == .penalty && items[j].penalty <= -10000) { j += 1 }
            start = j
            startPost = items[end].kind == .penalty ? items[end].postWidth : 0
        }
        return (lines, result.pass)
    }

    private struct LineSet {
        var box: HBox
        var overfull: Double
        var naturalContent: Double
        var text: String
        var footnotes: [Int]
    }

    /// Sets items `start..<end` (and the break item `end`) on a line of `width`: TeX's glue set (fil glue takes the
    /// slack when there is any, else every space stretches or shrinks by the same ratio of its stretch or shrink —
    /// the real stretch, not the emergency stretch the breaker may have counted), protrusion moving the first and
    /// last characters into the margins.
    private func setLine(_ b: Built, from start: Int, to end: Int, postWidth: Double, width: Double,
                         alignment: ParagraphAlignment) -> LineSet {
        let items = b.items
        var natural = postWidth, naturalContent = postWidth, totalFil = 0.0, totalStretch = 0.0, totalShrink = 0.0
        var leftProt = 0.0
        var sawBox = false
        for i in start..<end {
            let it = items[i]
            switch it.kind {
            case .box:
                natural += it.width; naturalContent += it.width
                if !sawBox { leftProt = it.leftProtrusion; sawBox = true }
            case .glue:
                natural += it.width
                if it.stretchOrder > 0 { totalFil += it.stretch } else { naturalContent += it.width; totalStretch += it.stretch }
                totalShrink += it.shrink
            case .penalty: break
            }
        }
        let breakItem = items[end]
        if breakItem.kind == .penalty { natural += breakItem.width; naturalContent += breakItem.width }
        var rightProt = 0.0
        if breakItem.kind == .penalty && breakItem.penalty <= -10000 {
            rightProt = 0
        } else if breakItem.kind == .penalty && breakItem.hyphenText != nil {
            rightProt = breakItem.rightProtrusion
        } else {
            var j = end - 1
            while j >= start, items[j].kind == .penalty { j -= 1 }
            if j >= start && items[j].kind == .box { rightProt = items[j].rightProtrusion }
        }
        let justified = alignment == .justified
        if !justified { leftProt = 0; rightProt = 0 }
        let slack = width + leftProt + rightProt - natural
        let ratio = slack >= 0 ? (totalStretch > 0 ? slack / totalStretch : 0) : (totalShrink > 0 ? max(slack / totalShrink, -1) : 0)

        func glueWidth(_ it: BreakItem) -> Double {
            if it.stretchOrder > 0 { return it.width + (totalFil > 0 && slack > 0 && justified ? it.stretch * slack / totalFil : 0) }
            if !justified || (totalFil > 0 && slack >= 0) { return it.width }
            return ratio >= 0 ? it.width + it.stretch * ratio : it.width + it.shrink * ratio
        }

        var ops: [DrawOp] = []
        var x = -leftProt
        var height = 0.0, depth = 0.0
        var text = ""
        var footnotes: [Int] = []
        var links: [(String, Double, Double)] = []
        var firstBox = true
        var i = start
        while i < end {
            let it = items[i]
            switch it.kind {
            case .glue:
                x += glueWidth(it)
                if it.stretchOrder == 0 && it.width > 0 && !text.isEmpty { text += " " }
                i += 1
            case .penalty:
                i += 1
            case .box:
                var advance = it.width
                switch b.fragments[it.fragment] {
                case .kern:
                    i += 1
                case .object(let box, let link):
                    ops.append(.box(box, x: x, y: 0))
                    height = max(height, box.height); depth = max(depth, box.depth)
                    if let link { links.append((link, x, x + box.width)) }
                    i += 1
                case .footnote(let box, let number):
                    ops.append(.box(box, x: x, y: 0))
                    height = max(height, box.height); depth = max(depth, box.depth)
                    footnotes.append(number)
                    i += 1
                case .word(let w, let range):
                    // Consecutive parts of one word on this line are drawn as one piece of text.
                    var length = range.length
                    var j = i + 1
                    var lastBox = i
                    while j < end {
                        if items[j].kind == .penalty { j += 1; continue }
                        if items[j].kind == .box, case .word(let w2, let r2) = b.fragments[items[j].fragment], w2 == w {
                            length = r2.location + r2.length - range.location
                            advance += items[j].width
                            lastBox = j
                            j += 1
                            continue
                        }
                        break
                    }
                    let word = b.words[w]
                    let piece = NSMutableAttributedString(attributedString: word.string.attributedSubstring(
                        from: NSRange(location: range.location, length: length)))
                    // The hyphen of a hyphenation break right after this word's last part on the line.
                    if (lastBox + 1..<end).allSatisfy({ items[$0].kind == .penalty }), breakItem.kind == .penalty,
                       let h = breakItem.hyphenText {
                        piece.append(NSAttributedString(string: h, attributes: word.string.attributes(at: range.location + length - 1, effectiveRange: nil)))
                    }
                    ops.append(.text(piece, x: x, y: 0))
                    if !word.decorations.isEmpty {
                        let pieceLine = CTLineCreateWithAttributedString(piece)
                        for d in word.decorations {
                            let lo = max(d.range.location, range.location) - range.location
                            let hi = min(d.range.location + d.range.length, range.location + length) - range.location
                            guard hi > lo else { continue }
                            let x0 = x + Double(CTLineGetOffsetForStringIndex(pieceLine, lo, nil))
                            let x1 = x + Double(CTLineGetOffsetForStringIndex(pieceLine, hi, nil))
                            let t = 0.04 * d.size
                            if d.underline { ops.append(.rule(x: x0, y: -0.12 * d.size - t, width: x1 - x0, height: t, colour: nil)) }
                            if d.strike { ops.append(.rule(x: x0, y: 0.25 * d.size, width: x1 - x0, height: t, colour: nil)) }
                        }
                    }
                    if let link = word.link { links.append((link, x, x + advance)) }
                    height = max(height, word.height); depth = max(depth, word.depth)
                    text += piece.string
                    i = j
                }
                if firstBox { advance += postWidth; firstBox = false }
                x += advance
            }
        }
        // How far the set line reaches past the measure (protrusion excepted): the lint's "overfull".
        let reach = x + (breakItem.kind == .penalty ? breakItem.width : 0) - width - rightProt
        if !justified && slack > 0 && alignment != .raggedRight {
            let shift = alignment == .centred ? slack / 2 : slack
            ops = ops.map { Self.shifted($0, by: shift) }
            links = links.map { ($0.0, $0.1 + shift, $0.2 + shift) }
        }
        var merged: [(String, Double, Double)] = []
        for l in links {
            if let last = merged.last, last.0 == l.0, l.1 - last.2 < 8 { merged[merged.count - 1].2 = l.2 } else { merged.append(l) }
        }
        for (url, x0, x1) in merged {
            if url.hasPrefix("#") {
                ops.append(.internalLink(String(url.dropFirst()), x: x0, y: -depth, width: x1 - x0, height: height + depth))
            } else {
                ops.append(.link(url, x: x0, y: -depth, width: x1 - x0, height: height + depth))
            }
        }
        return LineSet(box: HBox(width: width, height: height, depth: depth, ops: ops), overfull: reach,
                       naturalContent: naturalContent, text: text, footnotes: footnotes)
    }

    static func shifted(_ op: DrawOp, by dx: Double) -> DrawOp {
        switch op {
        case .text(let s, let x, let y): .text(s, x: x + dx, y: y)
        case .vector(let n, let x, let y, let k): .vector(n, x: x + dx, y: y, scale: k)
        case .rule(let x, let y, let w, let h, let c): .rule(x: x + dx, y: y, width: w, height: h, colour: c)
        case .image(let i, let x, let y, let w, let h): .image(i, x: x + dx, y: y, width: w, height: h)
        case .link(let u, let x, let y, let w, let h): .link(u, x: x + dx, y: y, width: w, height: h)
        case .internalLink(let u, let x, let y, let w, let h): .internalLink(u, x: x + dx, y: y, width: w, height: h)
        case .anchor(let n, let x, let y): .anchor(n, x: x + dx, y: y)
        case .tagged(let t, let ops): .tagged(t, ops.map { shifted($0, by: dx) })
        case .box(let b, let x, let y): .box(b, x: x + dx, y: y)
        }
    }

    /// Text on one line at its natural width (section numbers, list labels, table cells that do not wrap).
    func natural(_ pieces: [InlinePiece]) -> HBox {
        var shape = ParagraphShape(width: 1_000_000)
        shape.hyphenate = false
        shape.alignment = .raggedRight
        let built = build(pieces, shape: shape)
        let set = setLine(built, from: 0, to: built.items.count - 1, postWidth: 0, width: 1_000_000, alignment: .raggedRight)
        var box = set.box
        box.width = set.naturalContent
        return box
    }
}
