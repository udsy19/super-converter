import Foundation

/// A box at its place on a page: x from the column's left edge, baseline y from the top of the text block (y down).
struct Placed {
    var box: VBox
    var x: Double
    var y: Double
}

/// A finished page.
struct Page {
    enum Style { case plain, headings, empty }
    var number: Int
    var style: Style = .plain
    var runningHead: String? = nil
    /// Text-block material per column, top floats included.
    var columns: [[Placed]] = []
    /// Footnotes per column, y from the top of the text block.
    var footnotes: [[Placed]] = []
    /// The footnote rule's top edge per column, when the column has footnotes.
    var footnoteRules: [Double?] = []
    /// Full-width material above the columns (the title of a two-column document).
    var header: [Placed] = []
    var headerHeight = 0.0
    var marks: [HeadingMark] = []
}

/// TeX's page builder (The TeXbook, chapter 15) with LaTeX's output routine reduced to what documents need: the best
/// break by badness and penalties with `\raggedbottom` (glue at natural size unless the page must shrink), `\topskip`,
/// footnotes that take room from the page they are referenced on, floats at the top of this or a later page, float
/// pages for tall floats, columns, repeated table headers, and chapters starting on a new page.
final class PageBuilder {
    let style: StyleSheet
    let footnotes: [Int: [VItem]]
    let tableHeaders: [Int: [VItem]]
    private(set) var pages: [Page] = []
    private var deferred: [FloatBlock] = []
    private var runningHead: String? = nil
    /// Full-width material at the top of the first page (`\twocolumn[\@maketitle]`).
    var firstPageHeader: [VItem] = []
    /// `\maketitle` sets `\@topnum` to 0: no floats at the top of the title page.
    var noTopFloatsOnFirstPage = false

    static let awfulBad = Int.max / 4
    static let deplorable = 100_000

    init(style: StyleSheet, footnotes: [Int: [VItem]], tableHeaders: [Int: [VItem]]) {
        self.style = style; self.footnotes = footnotes; self.tableHeaders = tableHeaders
    }

    private var geometry: PageGeometry { style.geometry }

    // MARK: Footnote heights

    private var footnoteHeights: [Int: (height: Double, firstHeight: Double, lastDepth: Double)] = [:]

    private func footnoteMetrics(_ n: Int) -> (height: Double, firstHeight: Double, lastDepth: Double) {
        if let m = footnoteHeights[n] { return m }
        var h = 0.0, first: Double? = nil, lastDepth = 0.0
        for item in footnotes[n] ?? [] {
            switch item {
            case .box(let b):
                if first == nil { first = b.box.height } else { h += lastDepth + b.box.height }
                lastDepth = b.box.depth
            case .glue(let g): if first != nil { h += g.width }
            case .kern(let k): if first != nil { h += k }
            default: break
            }
        }
        let m = (height: h + (first ?? 0) + lastDepth, firstHeight: first ?? 0, lastDepth: lastDepth)
        footnoteHeights[n] = m
        return m
    }

    /// The room footnotes take below a column: `\skip\footins`, then each footnote a `\baselineskip` from the last.
    private func footnoteArea(_ numbers: [Int]) -> Double {
        guard !numbers.isEmpty else { return 0 }
        var h = style.footinsSkip.width
        var prevDepth: Double? = nil
        for n in numbers {
            let m = footnoteMetrics(n)
            if let pd = prevDepth { h += max(style.size(.footnotesize).leading - pd - m.firstHeight, 0) + pd }
            h += m.height - m.lastDepth
            prevDepth = m.lastDepth
        }
        return h + (prevDepth ?? 0)
    }

    // MARK: Building

    func build(_ list: [VItem]) -> [Page] {
        var queue = list[...]
        var page = newPage()
        var columns: [[Placed]] = [], notes: [[Placed]] = [], rules: [Double?] = [], marks: [HeadingMark] = []
        var guardCount = 0
        while !queue.isEmpty || !deferred.isEmpty {
            guardCount += 1
            if guardCount > 200_000 { break }
            if columns.isEmpty, let first = deferred.first, first.height > geometry.textHeight * style.topfraction || queue.isEmpty {
                // A float too tall for the top of a text page, or the floats left at the end: a float page.
                deferred.removeFirst()
                emitFloatPage(first)
                page = newPage()
                continue
            }
            let available = geometry.textHeight - (pages.isEmpty ? page.headerHeight : 0)
            let column = fillColumn(&queue, available: available, allowTopFloats: !(pages.isEmpty && noTopFloatsOnFirstPage))
            columns.append(column.placed)
            notes.append(column.footnotes)
            rules.append(column.footnoteRule)
            marks += column.marks
            if columns.count >= geometry.columns || column.forcePage || queue.isEmpty {
                while columns.count < geometry.columns { columns.append([]); notes.append([]); rules.append(nil) }
                page.columns = columns; page.footnotes = notes; page.footnoteRules = rules; page.marks = marks
                finishPage(&page, chapter: column.chapter)
                columns = []; notes = []; rules = []; marks = []
                if column.chapterFollows && style.twoSided && style.documentClass == .book && pages.count % 2 == 1 {
                    // \cleardoublepage: in a two-sided book, chapters open on an odd page.
                    var blank = newPage()
                    blank.style = .empty
                    blank.columns = Array(repeating: [], count: geometry.columns)
                    finishPage(&blank, chapter: nil)
                    pages[pages.count - 1].style = .empty
                }
                page = newPage()
            }
        }
        if pages.isEmpty {
            var p = newPage()
            p.columns = [[]]
            finishPage(&p, chapter: nil)
        }
        return pages
    }

    private func newPage() -> Page {
        var p = Page(number: pages.count + 1)
        guard pages.isEmpty, !firstPageHeader.isEmpty else { return p }
        var y = 0.0
        var lastDepth = 0.0
        for item in firstPageHeader {
            switch item {
            case .box(let b):
                if p.header.isEmpty { y += max(0, geometry.topSkip - b.box.height) }
                y += lastDepth + b.box.height
                p.header.append(Placed(box: b, x: b.x, y: y))
                lastDepth = b.box.depth
            case .glue(let g): y += g.width
            case .kern(let k): y += k
            default: break
            }
        }
        p.headerHeight = y + lastDepth + style.normal.leading
        return p
    }

    private func finishPage(_ page: inout Page, chapter: String??) {
        page.number = pages.count + 1
        if style.documentClass == .book {
            if case .some(let title) = chapter {
                page.style = .plain   // \thispagestyle{plain} on a chapter's first page
                runningHead = title
            } else {
                page.style = .headings
            }
            page.runningHead = runningHead?.uppercased()
        }
        pages.append(page)
    }

    private func emitFloatPage(_ f: FloatBlock) {
        var p = newPage()
        // \@fptop and \@fpbot are 0pt plus 1fil: the float is centred on the page.
        let offset = max(0, (geometry.textHeight - f.height) / 2)
        p.columns = [place(f.items, startY: offset, shrinkRatio: 0).placed]
        while p.columns.count < geometry.columns { p.columns.append([]) }
        p.footnotes = Array(repeating: [], count: geometry.columns)
        p.footnoteRules = Array(repeating: nil, count: geometry.columns)
        finishPage(&p, chapter: nil)
    }

    // MARK: One column

    private struct ColumnResult {
        var placed: [Placed]
        var footnotes: [Placed]
        var footnoteRule: Double?
        var marks: [HeadingMark]
        var forcePage: Bool
        /// Set when a chapter starts in this column (with its title).
        var chapter: String??
        /// A chapter starts right after this column.
        var chapterFollows: Bool
    }

    private func fillColumn(_ queue: inout ArraySlice<VItem>, available: Double, allowTopFloats: Bool) -> ColumnResult {
        var goal = available
        var topFloats: [FloatBlock] = []
        // Deferred floats first, at the top (at most two, at most \topfraction of the page).
        if allowTopFloats {
            var used = 0.0
            while let f = deferred.first, topFloats.count < 2, used + f.height <= geometry.textHeight * style.topfraction {
                topFloats.append(f); deferred.removeFirst()
                used += f.height + style.textfloatsep.width
            }
            goal -= used
        }
        // `content` is what this column took; `fromQueue` marks what goes back when the break comes before it.
        var content: [VItem] = []
        var fromQueue: [Bool] = []
        func add(_ item: VItem, queued: Bool) { content.append(item); fromQueue.append(queued) }

        var total = 0.0, stretch = 0.0, shrink = 0.0, fil = 0.0
        var lastDepth = 0.0
        var sawBox = false
        var lastWasBox = false
        // A table that continues from the previous page repeats its header.
        if let first = queue.first(where: { !$0.isDiscardable }), case .box(let b) = first, let id = b.tableID, let header = tableHeaders[id] {
            for item in header {
                switch item {
                case .box(let v):
                    if !sawBox { let ts = max(0, geometry.topSkip - v.box.height); add(.glue(Glue(width: ts)), queued: false); total += ts }
                    total += lastDepth + v.box.height
                    lastDepth = v.box.depth
                    sawBox = true
                case .glue(let g): total += g.width
                case .kern(let k): total += k
                default: break
                }
                add(item, queued: false)
            }
        }
        var footnoteNumbers: [Int] = []
        var footnoteHeight = 0.0
        var best: (index: Int, cost: Int, goal: Double, total: Double, shrink: Double)? = nil
        var forced = false
        var chapter: String?? = nil

        func badness() -> Int {
            if total <= goal { return fil > 0 ? 0 : LineBreaker.badness(goal - total, stretch) }
            return total - goal > shrink ? Self.awfulBad : LineBreaker.badness(total - goal, shrink)
        }

        var idx = queue.startIndex
        loop: while true {
            let atEnd = idx >= queue.endIndex
            let item: VItem = atEnd ? .penalty(-10000) : queue[idx]
            // Discardable items at the top of a column vanish.
            if !sawBox && !atEnd && item.isDiscardable { idx += 1; continue }
            var breakPenalty: Int? = nil
            switch item {
            case .penalty(let p): breakPenalty = p
            case .glue: if lastWasBox { breakPenalty = 0 }
            case .clearPage, .chapterStart: if sawBox { breakPenalty = -10000 }
            default: break
            }
            if let p = breakPenalty, p < 10000, sawBox || atEnd {
                let b = badness()
                let c: Int
                if b < Self.awfulBad {
                    c = p <= -10000 ? p : b < LineBreaker.infBad ? b + p : Self.deplorable
                } else { c = b }
                if best == nil || c <= best!.cost { best = (content.count, c, goal, total, shrink) }
                if c == Self.awfulBad || p <= -10000 {
                    forced = p <= -10000 && c != Self.awfulBad
                    break loop
                }
            }
            if atEnd { break }
            switch item {
            case .box(let v):
                if !sawBox {
                    let ts = max(0, geometry.topSkip - v.box.height)   // \topskip
                    add(.glue(Glue(width: ts)), queued: false)
                    total += ts
                }
                total += lastDepth + v.box.height
                lastDepth = v.box.depth
                sawBox = true
                lastWasBox = true
                for n in v.footnotes where !footnoteNumbers.contains(n) {
                    footnoteNumbers.append(n)
                    let area = footnoteArea(footnoteNumbers)
                    goal -= area - footnoteHeight
                    footnoteHeight = area
                }
                add(item, queued: true)
            case .glue(let g):
                total += g.width
                if g.stretchOrder > 0 { fil += g.stretch } else { stretch += g.stretch }
                shrink += g.shrink
                lastWasBox = false
                add(item, queued: true)
            case .kern(let k):
                total += k
                lastWasBox = false
                add(item, queued: true)
            case .penalty:
                lastWasBox = false
                add(item, queued: true)
            case .float(let f):
                // The top of this column if it fits with what is already here (LaTeX's \@addtotoporbot), else later.
                if allowTopFloats && topFloats.count < 2 && deferred.isEmpty
                    && f.height + style.textfloatsep.width + total <= goal
                    && topFloats.reduce(0.0, { $0 + $1.height }) + f.height <= geometry.textHeight * style.topfraction {
                    topFloats.append(f)
                    goal -= f.height + style.textfloatsep.width
                } else {
                    deferred.append(f)
                }
            case .mark, .clearPage:
                add(item, queued: true)
            case .chapterStart(let title):
                chapter = .some(title)
                add(item, queued: true)
            }
            idx += 1
        }
        let b = best ?? (content.count, 0, goal, total, shrink)
        let kept = Array(content[..<b.index])
        var returned: [VItem] = []
        for k in b.index..<content.count where fromQueue[k] { returned.append(content[k]) }
        queue = (returned + Array(queue[min(idx, queue.endIndex)...]))[...]
        if !kept.contains(where: { if case .chapterStart = $0 { return true }; return false }) { chapter = nil }

        var fns: [Int] = []
        var marks: [HeadingMark] = []
        for item in kept {
            if case .box(let v) = item { for n in v.footnotes where !fns.contains(n) { fns.append(n) } }
            if case .mark(let m) = item { marks.append(m) }
        }
        // \raggedbottom: glue at its natural size unless the column has to shrink to fit.
        let shrinkRatio = b.total > b.goal && b.shrink > 0 ? min(1, (b.total - b.goal) / b.shrink) : 0
        var y = 0.0
        var placed: [Placed] = []
        for f in topFloats {
            let r = place(f.items, startY: y, shrinkRatio: 0)
            placed += r.placed
            y = r.endY + style.textfloatsep.width
        }
        let body = place(kept, startY: y, shrinkRatio: shrinkRatio)
        placed += body.placed
        // With \raggedbottom the footnotes follow the text: \skip\footins below it, the rule 3 pt above them.
        var footnotePlaced: [Placed] = []
        var rule: Double? = nil
        if !fns.isEmpty {
            var fy = body.endY + style.footinsSkip.width
            rule = fy - 3
            var prevDepth: Double? = nil
            for n in fns {
                var first = true
                for item in footnotes[n] ?? [] {
                    switch item {
                    case .box(let v):
                        if let pd = prevDepth {
                            fy += first ? max(style.size(.footnotesize).leading - pd - v.box.height, 0) + pd : pd
                        }
                        fy += v.box.height
                        footnotePlaced.append(Placed(box: v, x: v.x, y: fy))
                        prevDepth = v.box.depth
                        first = false
                    case .glue(let g): fy += g.width
                    case .kern(let k): fy += k
                    default: break
                    }
                }
            }
        }
        let cleared = kept.contains { if case .clearPage = $0 { return true }; return false }
        let chapterFollows = queue.first(where: { !$0.isDiscardable }).map { if case .chapterStart = $0 { return true }; return false } ?? false
        return ColumnResult(placed: placed, footnotes: footnotePlaced, footnoteRule: rule, marks: marks,
                            forcePage: (forced && b.cost <= -10000) || cleared || chapterFollows, chapter: chapter,
                            chapterFollows: chapterFollows)
    }

    /// Positions of a vertical list's boxes, glue shrunk by `shrinkRatio`.
    private func place(_ list: [VItem], startY: Double, shrinkRatio: Double) -> (placed: [Placed], endY: Double) {
        var y = startY
        var placed: [Placed] = []
        var lastDepth = 0.0
        for item in list {
            switch item {
            case .box(let v):
                y += lastDepth + v.box.height
                placed.append(Placed(box: v, x: v.x, y: y))
                lastDepth = v.box.depth
            case .glue(let g):
                y += g.width - g.shrink * shrinkRatio
            case .kern(let k):
                y += k
            default:
                break
            }
        }
        return (placed, y + lastDepth)
    }
}
