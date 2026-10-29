import Foundation

// LaTeX's metrics (quality §3.2), in TeX points (1 pt = 1/72.27 in). Values are those of article.cls/book.cls and
// size10.clo/size11.clo/size12.clo (bk1x.clo for the book class), including their rounding: `\@settopoint` truncates
// \textwidth, the side margins and \topmargin to whole points, as LaTeX does. The renderer converts to PDF units.

/// TeX glue: a natural width that can stretch and shrink. Stretch order 1 is `fil`.
struct Glue: Hashable, Sendable {
    var width: Double
    var stretch: Double = 0
    var shrink: Double = 0
    var stretchOrder: Int = 0

    static let zero = Glue(width: 0)
    static func fil(_ width: Double = 0) -> Glue { Glue(width: width, stretch: 1, stretchOrder: 1) }
    static func + (a: Glue, b: Glue) -> Glue {
        Glue(width: a.width + b.width, stretch: a.stretch + b.stretch, shrink: a.shrink + b.shrink,
             stretchOrder: max(a.stretchOrder, b.stretchOrder))
    }
}

extension Double {
    static let pointsPerInch = 72.27
    static let pointsPerMillimetre = 72.27 / 25.4
    /// TeX points to PDF units (big points).
    var bp: Double { self * 72 / 72.27 }
    /// PDF units to TeX points.
    var fromBP: Double { self * 72.27 / 72 }
}

/// Paper sizes in TeX points.
struct Paper: Hashable, Sendable {
    var width: Double
    var height: Double

    static let letter = Paper(width: 8.5 * .pointsPerInch, height: 11 * .pointsPerInch)
    static let legal = Paper(width: 8.5 * .pointsPerInch, height: 14 * .pointsPerInch)
    static let a3 = Paper(width: 297 * .pointsPerMillimetre, height: 420 * .pointsPerMillimetre)
    static let a4 = Paper(width: 210 * .pointsPerMillimetre, height: 297 * .pointsPerMillimetre)
    static let a5 = Paper(width: 148 * .pointsPerMillimetre, height: 210 * .pointsPerMillimetre)
    static let b5 = Paper(width: 176 * .pointsPerMillimetre, height: 250 * .pointsPerMillimetre)
    static let sixByNine = Paper(width: 6 * .pointsPerInch, height: 9 * .pointsPerInch)

    static func named(_ name: String) -> Paper? {
        switch name.lowercased() {
        case "letter": .letter
        case "legal": .legal
        case "a3": .a3
        case "a4": .a4
        case "a5": .a5
        case "b5": .b5
        case "6x9": .sixByNine
        default: nil
        }
    }

    /// Letter in the US, Canada, Mexico, the Philippines, Chile, Colombia and Venezuela, A4 elsewhere (O-DOC-PDF).
    static func forRegion(_ region: String?) -> Paper {
        ["US", "CA", "MX", "PH", "CL", "CO", "VE"].contains(region ?? "") ? .letter : .a4
    }
}

/// LaTeX's size commands.
enum SizeCommand: Int, Comparable, Sendable {
    case tiny, scriptsize, footnotesize, small, normalsize, large, Large, LARGE, huge, Huge
    static func < (a: SizeCommand, b: SizeCommand) -> Bool { a.rawValue < b.rawValue }
}

struct SizeLeading: Hashable, Sendable {
    var size: Double
    var leading: Double
}

/// One list nesting level's parameters (`\@listi`, `\@listii`, …).
struct ListLevel: Sendable {
    var leftMargin: Double
    var topsep: Glue
    var parsep: Glue
    var itemsep: Glue
    var partopsep: Glue
}

/// A sectioning command's look (`\@startsection`).
struct HeadingStyle: Sendable {
    var size: SizeCommand
    var bold: Bool
    /// Space before (the absolute value of LaTeX's negative before-skip).
    var before: Glue
    /// Space after; nil for run-in headings (`\paragraph`), which are followed by `runInSpace` on the same line.
    var after: Glue?
    var runInSpace: Double = 0
    var indent: Double = 0
    /// True when LaTeX numbers this level (`secnumdepth`).
    var numbered: Bool
}

/// Where the text block sits on the paper.
struct PageGeometry: Sendable {
    var paper: Paper
    var textWidth: Double
    var textHeight: Double
    /// Left edge of the text block on odd (and one-sided) pages, from the paper's left edge.
    var oddLeft: Double
    var evenLeft: Double
    /// Top of the text block (top of `\topskip`), from the paper's top edge.
    var textTop: Double
    var headSep: Double
    var footSkip: Double
    var topSkip: Double
    var columns: Int
    var columnSep: Double
    var columnWidth: Double { columns == 1 ? textWidth : (textWidth - columnSep * Double(columns - 1)) / Double(columns) }
}

/// The class and size option: article or book, 10/11/12 pt.
struct StyleSheet: Sendable {
    enum DocumentClass: Sendable { case article, book }
    enum MarginChoice: Sendable { case latex, narrow, wide }

    var documentClass: DocumentClass
    var twoSided: Bool
    var sizes: [SizeCommand: SizeLeading]
    var geometry: PageGeometry
    var parindent: Double
    var parskip = Glue(width: 0, stretch: 1)
    var lineskip = 1.0
    var lineskiplimit = 0.0
    var labelsep: Double
    var lists: [ListLevel]
    var headings: [HeadingStyle]           // section, subsection, subsubsection, paragraph, subparagraph
    var chapterBefore = 50.0, chapterAfter = 40.0, chapterGap = 20.0
    var footinsSkip: Glue
    var footnoteSep: Double
    var abovedisplay: Glue
    var belowdisplay: Glue
    var abovedisplayShort: Glue
    var belowdisplayShort: Glue
    var textfloatsep = Glue(width: 20, stretch: 2, shrink: 4)
    var abovecaptionskip = 10.0
    var topfraction = 0.7
    // \clubpenalty and \widowpenalty are LaTeX's 150 made absolute, so the lint's "no widows or orphans" always holds.
    var clubPenalty = 10000
    var widowPenalty = 10000
    var brokenPenalty = 100
    var secPenalty = -300

    var normal: SizeLeading { sizes[.normalsize]! }
    var em: Double { normal.size }

    func size(_ s: SizeCommand) -> SizeLeading { sizes[s]! }

    /// `\sf@size`: the size LaTeX uses for superscripts at `size`.
    static func scriptSize(of size: Double) -> Double {
        switch size {
        case ..<7.5: return 5
        case ..<9.5: return 6
        case ..<10.5: return 7
        case ..<13: return 8
        case ..<15.5: return 10
        case ..<18: return 12
        case ..<22: return 14.4
        default: return 17.28
        }
    }

    static func latex(_ cls: DocumentClass, baseSize: Int, paper: Paper, columns: Int, twoSided: Bool, margins: MarginChoice) -> StyleSheet {
        let base = [10, 11, 12].contains(baseSize) ? baseSize : 10
        let sizes: [SizeCommand: SizeLeading]
        let textWidthLimit: Double, parindent: Double, topsep: [Glue], parsep: [Glue], partopsep: Glue, footins: Glue
        let footnotesep: Double, display: (Glue, Glue, Glue)
        switch base {
        case 11:
            sizes = [.tiny: .init(size: 6, leading: 7), .scriptsize: .init(size: 8, leading: 9.5),
                     .footnotesize: .init(size: 9, leading: 11), .small: .init(size: 10, leading: 12),
                     .normalsize: .init(size: 10.95, leading: 13.6), .large: .init(size: 12, leading: 14),
                     .Large: .init(size: 14.4, leading: 18), .LARGE: .init(size: 17.28, leading: 22),
                     .huge: .init(size: 20.74, leading: 25), .Huge: .init(size: 24.88, leading: 30)]
            textWidthLimit = 360; parindent = 17
            topsep = [Glue(width: 9, stretch: 3, shrink: 5), Glue(width: 4.5, stretch: 2, shrink: 1), Glue(width: 2, stretch: 1, shrink: 1)]
            parsep = [Glue(width: 4.5, stretch: 2, shrink: 1), Glue(width: 2, stretch: 1, shrink: 1), .zero]
            partopsep = Glue(width: 3, stretch: 1, shrink: 1)
            footins = Glue(width: 10, stretch: 4, shrink: 2); footnotesep = 7.7
            display = (Glue(width: 11, stretch: 3, shrink: 6), Glue(width: 0, stretch: 3), Glue(width: 6.5, stretch: 3.5, shrink: 3))
        case 12:
            sizes = [.tiny: .init(size: 6, leading: 7), .scriptsize: .init(size: 8, leading: 9.5),
                     .footnotesize: .init(size: 10, leading: 12), .small: .init(size: 10.95, leading: 13.6),
                     .normalsize: .init(size: 12, leading: 14.5), .large: .init(size: 14.4, leading: 18),
                     .Large: .init(size: 17.28, leading: 22), .LARGE: .init(size: 20.74, leading: 25),
                     .huge: .init(size: 24.88, leading: 30), .Huge: .init(size: 24.88, leading: 30)]
            textWidthLimit = 390; parindent = 18
            topsep = [Glue(width: 10, stretch: 4, shrink: 6), Glue(width: 5, stretch: 2.5, shrink: 1), Glue(width: 2.5, stretch: 1, shrink: 1)]
            parsep = [Glue(width: 5, stretch: 2.5, shrink: 1), Glue(width: 2.5, stretch: 1, shrink: 1), .zero]
            partopsep = Glue(width: 3, stretch: 2, shrink: 2)
            footins = Glue(width: 10.8, stretch: 4, shrink: 2); footnotesep = 8.4
            display = (Glue(width: 12, stretch: 3, shrink: 7), Glue(width: 0, stretch: 3), Glue(width: 6.5, stretch: 3.5, shrink: 3))
        default:
            sizes = [.tiny: .init(size: 5, leading: 6), .scriptsize: .init(size: 7, leading: 8),
                     .footnotesize: .init(size: 8, leading: 9.5), .small: .init(size: 9, leading: 11),
                     .normalsize: .init(size: 10, leading: 12), .large: .init(size: 12, leading: 14),
                     .Large: .init(size: 14.4, leading: 18), .LARGE: .init(size: 17.28, leading: 22),
                     .huge: .init(size: 20.74, leading: 25), .Huge: .init(size: 24.88, leading: 30)]
            textWidthLimit = 345; parindent = 15
            topsep = [Glue(width: 8, stretch: 2, shrink: 4), Glue(width: 4, stretch: 2, shrink: 1), Glue(width: 2, stretch: 1, shrink: 1)]
            parsep = [Glue(width: 4, stretch: 2, shrink: 1), Glue(width: 2, stretch: 1, shrink: 1), .zero]
            partopsep = Glue(width: 2, stretch: 1, shrink: 1)
            footins = Glue(width: 9, stretch: 4, shrink: 2); footnotesep = 6.65
            display = (Glue(width: 10, stretch: 2, shrink: 5), Glue(width: 0, stretch: 3), Glue(width: 6, stretch: 3, shrink: 3))
        }
        let normal = sizes[.normalsize]!
        // article.cls sets the list margins in em of the font at class load time (Computer Modern at the base size).
        let em = normal.size
        var lists: [ListLevel] = []
        for (i, m) in [2.5 * em, 2.2 * em, 1.87 * em, 1.7 * em, em, em].enumerated() {
            let t = topsep[min(i, 2)], p = parsep[min(i, 2)]
            lists.append(ListLevel(leftMargin: m, topsep: t, parsep: p, itemsep: i >= 2 ? t : p,
                                   partopsep: i >= 2 ? Glue(width: 1, shrink: 1) : partopsep))
        }
        let ex = 0.430554 * normal.size   // LM Roman 10's x-height: TeX's `ex`
        let sectionBefore = Glue(width: 3.5 * ex, stretch: ex, shrink: 0.2 * ex)
        let lowerBefore = Glue(width: 3.25 * ex, stretch: ex, shrink: 0.2 * ex)
        let headings = [
            HeadingStyle(size: .Large, bold: true, before: sectionBefore, after: Glue(width: 2.3 * ex, stretch: 0.2 * ex), numbered: true),
            HeadingStyle(size: .large, bold: true, before: lowerBefore, after: Glue(width: 1.5 * ex, stretch: 0.2 * ex), numbered: true),
            HeadingStyle(size: .normalsize, bold: true, before: lowerBefore, after: Glue(width: 1.5 * ex, stretch: 0.2 * ex), numbered: cls == .article),
            HeadingStyle(size: .normalsize, bold: true, before: lowerBefore, after: nil, runInSpace: em, numbered: false),
            HeadingStyle(size: .normalsize, bold: true, before: lowerBefore, after: nil, runInSpace: em, indent: parindent, numbered: false),
        ]

        // Page geometry (size1x.clo / bk1x.clo, article.cls / book.cls).
        let baselineskip = normal.leading
        let topskip = normal.size
        let available = paper.width - 2 * .pointsPerInch
        var textWidth = (columns == 2 ? min(available, 2 * textWidthLimit) : min(available, textWidthLimit)).rounded(.towardZero)
        var textHeight = ((paper.height - 3.5 * .pointsPerInch) / baselineskip).rounded(.down) * baselineskip + topskip
        let headHeight = 12.0
        let headSep = cls == .book ? (base == 10 ? 0.25 : 0.275) * .pointsPerInch : 25.0
        let footSkip = cls == .book ? (base == 10 ? 0.35 : base == 11 ? 0.38 : 0.30) * .pointsPerInch : 30.0
        let free = paper.width - textWidth
        var odd = ((twoSided ? 0.4 : 0.5) * free - .pointsPerInch).rounded(.towardZero)
        var even = twoSided ? (0.6 * free - .pointsPerInch).rounded(.towardZero) : odd
        let topMargin = ((paper.height - 2 * .pointsPerInch - headHeight - headSep - textHeight - footSkip) / 2).rounded(.towardZero)
        var textTop = .pointsPerInch + topMargin + headHeight + headSep
        if margins != .latex {
            // geometry-style margins: the same on all four sides of the text block.
            let margin = margins == .narrow ? .pointsPerInch : 1.5 * .pointsPerInch
            textWidth = paper.width - 2 * margin
            odd = margin - .pointsPerInch; even = odd
            textHeight = ((paper.height - 2 * margin - topskip) / baselineskip).rounded(.down) * baselineskip + topskip
            textTop = margin
        }
        let geometry = PageGeometry(paper: paper, textWidth: textWidth, textHeight: textHeight,
                                    oddLeft: .pointsPerInch + odd, evenLeft: .pointsPerInch + even, textTop: textTop,
                                    headSep: headSep, footSkip: footSkip, topSkip: topskip, columns: columns, columnSep: 10)
        return StyleSheet(documentClass: cls, twoSided: twoSided, sizes: sizes, geometry: geometry,
                          parindent: columns == 2 ? em : parindent, labelsep: 0.5 * em, lists: lists, headings: headings,
                          footinsSkip: footins, footnoteSep: footnotesep, abovedisplay: display.0, belowdisplay: display.0,
                          abovedisplayShort: display.1, belowdisplayShort: display.2)
    }
}
