import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore

/// A table ready for layout: an optional header row, body rows, column alignments.
struct GridTable {
    struct Cell {
        var pieces: [InlinePiece]
        var text: String
        var span = 1
        var numeric = false
    }
    var header: [Cell]?
    var body: [[Cell]]
    var alignments: [Character]   // l, c, r
    var caption: DocText?
}

/// Booktabs tables (quality §3.2): `\toprule`, `\midrule`, `\bottomrule` and no vertical rules, `\tabcolsep` 6 pt,
/// numbers right- and decimal-aligned. A table too wide for the measure steps down to `\small`, then `\footnotesize`,
/// then wraps its text columns. Captioned tables that fit on a page float (`[tbp]`) with the caption above; others
/// stay in the text and break across pages with the header repeated (longtable).
final class TableComposer {
    unowned let composer: Composer
    let ctx: BlockContext
    var style: StyleSheet { composer.style }

    init(composer: Composer, ctx: BlockContext) { self.composer = composer; self.ctx = ctx }

    struct Result {
        var items: [VItem]
        var isFloat: Bool
    }

    // MARK: From the document model

    func compose(_ t: DocTable, number: Int?) -> Result {
        let columns = t.rows.map { $0.reduce(0) { $0 + max(1, $1.columnSpan) } }.max() ?? 0
        guard columns > 0 else { return Result(items: [], isFloat: false) }
        var rows = t.rows
        var header: [DocTable.Cell]? = nil
        if let first = rows.first, first.allSatisfy(\.isHeader) { header = first; rows.removeFirst() }
        if t.rows.contains(where: { $0.contains { $0.rowSpan > 1 } }) { composer.noteTableSimplified() }
        let base = composer.runStyle(ctx)
        func cell(_ c: DocTable.Cell, bold: Bool) -> GridTable.Cell {
            var s = base
            if bold && composer.look == .asWritten { s.bold = true }
            var pieces: [InlinePiece] = []
            for (k, block) in c.blocks.enumerated() {
                if k > 0 { pieces.append(.lineBreak) }
                pieces += inlineOf(block, s)
            }
            let text = c.blocks.map(Self.text).joined(separator: " ")
            return GridTable.Cell(pieces: pieces, text: text, span: max(1, c.columnSpan), numeric: Self.isNumber(text))
        }
        var alignments: [Character] = (0..<columns).map { j in
            guard j < t.alignments.count else { return "l" }
            switch t.alignments[j] {
            case .centre: return "c"
            case .end: return "r"
            default: return "l"
            }
        }
        let body = rows.map { $0.map { cell($0, bold: false) } }
        // Columns of numbers are right-aligned (and decimal-aligned in layout) unless the source said otherwise.
        for j in 0..<columns where j >= t.alignments.count || t.alignments[j] == .start {
            let values = body.compactMap { j < $0.count ? $0[j] : nil }.filter { !$0.text.isEmpty }
            if values.count >= 2 && values.allSatisfy(\.numeric) { alignments[j] = "r" }
        }
        return layout(GridTable(header: header.map { $0.map { cell($0, bold: true) } }, body: body, alignments: alignments,
                                caption: t.caption), number: number)
    }

    private func inlineOf(_ block: DocBlock, _ s: RunStyle) -> [InlinePiece] {
        switch block {
        case .paragraph(let text, _): return composer.inline(text, ctx, base: s)
        case .heading(_, let text): var b = s; b.bold = true; return composer.inline(text, ctx, base: b)
        case .code(_, let text): var c = s; c.family = .mono; c.verbatim = true; return [.text(text, c)]
        case .math(let tex, _): return [.math(tex, s)]
        case .list(let ordered, let start, let entries):
            var out: [InlinePiece] = []
            for (k, e) in entries.enumerated() {
                if k > 0 { out.append(.lineBreak) }
                out.append(.text(ordered ? "\(start + k). " : "\u{2022} ", s))
                for b in e { out += inlineOf(b, s) }
            }
            return out
        case .quote(let inner): return inner.flatMap { inlineOf($0, s) }
        default: return []
        }
    }

    static func text(_ block: DocBlock) -> String {
        switch block {
        case .paragraph(let t, _), .heading(_, let t): return Composer.plainText(t)
        case .code(_, let s): return s
        case .math(let tex, _): return tex
        default: return ""
        }
    }

    static func isNumber(_ s: String) -> Bool {
        var t = s.trimmingCharacters(in: .whitespaces)
        for c in [",", "%", "$", "€", "£"] { t = t.replacingOccurrences(of: c, with: "") }
        t = t.replacingOccurrences(of: "\u{2212}", with: "-")
        return !t.isEmpty && Double(t) != nil
    }

    // MARK: Layout

    private struct Plan {
        var size: SizeCommand
        var widths: [Double]
        var wrap: Bool
    }

    func layout(_ grid: GridTable, number: Int?) -> Result {
        let measure = composer.lineWidth(ctx)
        let columns = grid.alignments.count
        let sep = 6.0   // \tabcolsep
        let allRows = [grid.header].compactMap { $0 } + grid.body
        func widths(_ size: SizeCommand) -> (natural: [Double], minimum: [Double]) {
            var natural = [Double](repeating: 0, count: columns), minimum = natural
            for row in allRows {
                var j = 0
                for c in row {
                    if c.span == 1 && j < columns {
                        natural[j] = max(natural[j], naturalWidth(resized(c.pieces, size)))
                        minimum[j] = max(minimum[j], longestWord(c, size))
                    }
                    j += c.span
                }
            }
            return (natural, minimum)
        }
        let sizes: [SizeCommand] = [.normalsize, .small, .footnotesize]
        let available = measure - 2 * sep * Double(columns)
        var plan: Plan? = nil
        for size in sizes {
            let natural = widths(size).natural
            if natural.reduce(0, +) <= available { plan = Plan(size: size, widths: natural, wrap: false); break }
        }
        if plan == nil {
            for size in sizes {
                let (natural, minimum) = widths(size)
                if minimum.reduce(0, +) <= available {
                    plan = Plan(size: size, widths: distribute(natural: natural, minimum: minimum, available: available), wrap: true)
                    break
                }
            }
        }
        if plan == nil {
            // Still too wide: footnotesize columns squeezed to the measure; long words break where they must.
            let natural = widths(.footnotesize).natural
            let total = max(natural.reduce(0, +), 1)
            plan = Plan(size: .footnotesize, widths: natural.map { max(12, $0 / total * available) }, wrap: true)
            composer.noteTableSimplified()
        }
        let p = plan!
        let leading = style.size(p.size).leading
        let fontSize = style.size(p.size).size
        let strutHeight = 0.7 * leading, strutDepth = 0.3 * leading
        let tableWidth = p.widths.reduce(0, +) + 2 * sep * Double(columns)
        let left = ctx.left + max(0, (measure - tableWidth) / 2)
        var xs: [Double] = []
        var x = sep
        for w in p.widths { xs.append(x); x += w + 2 * sep }
        let decimals = decimalColumns(grid, p.size)
        let tableTag = composer.nextTag(.table)

        func rowBox(_ row: [GridTable.Cell], header: Bool) -> VBox {
            var ops: [DrawOp] = []
            var height = strutHeight, depth = strutDepth
            var j = 0
            let rowTag = composer.nextTag(.tableRow)
            for c in row {
                guard j < columns else { break }
                let span = min(c.span, columns - j)
                let width = p.widths[j..<(j + span)].reduce(0, +) + 2 * sep * Double(span - 1)
                let align = span > 1 ? "c" : grid.alignments[j]
                let pieces = resized(c.pieces, p.size)
                var cellOps: [DrawOp] = []
                if !p.wrap || naturalWidth(pieces) <= width + 0.01 {
                    let box = composer.setter.natural(pieces)
                    var dx = align == "l" ? 0 : align == "r" ? width - box.width : (width - box.width) / 2
                    if align == "r", let fracWidth = decimals[j], !header, c.numeric {
                        // Decimal points in a line: the integer part right-aligned on the column's widest.
                        let intWidth = composer.setter.natural([.text(splitDecimal(c.text).0, cellStyle(p.size))]).width
                        dx = width - fracWidth - intWidth
                    }
                    cellOps.append(.box(box, x: xs[j] + dx, y: 0))
                    height = max(height, box.height); depth = max(depth, box.depth)
                } else {
                    let lines = composer.cellLines(pieces, width: width, alignment: align == "c" ? .centred : align == "r" ? .raggedLeft : .raggedRight)
                    for (k, line) in lines.enumerated() { cellOps.append(.box(line.box, x: xs[j], y: -Double(k) * leading)) }
                    if let first = lines.first { height = max(height, first.box.height) }
                    if let last = lines.last { depth = max(depth, Double(lines.count - 1) * leading + max(strutDepth, last.box.depth)) }
                }
                ops.append(.tagged(composer.nextTag(header ? .tableHeaderCell : .tableCell), cellOps))
                j += span
            }
            return VBox(box: HBox(width: tableWidth, height: height, depth: depth, ops: ops), x: left, tags: ctx.tags + [tableTag, rowTag])
        }
        func rule(_ thickness: Double) -> VBox {
            VBox(box: HBox(width: tableWidth, height: thickness, depth: 0, ops: [.rule(x: 0, y: 0, width: tableWidth, height: thickness, colour: nil)]),
                 x: left, tags: ctx.tags + [tableTag])
        }
        let ex = 0.430554 * fontSize
        let heavy = 0.08 * fontSize, light = 0.05 * fontSize   // \heavyrulewidth, \lightrulewidth
        let above = 0.4 * ex, below = 0.65 * ex                 // \aboverulesep, \belowrulesep
        var items: [VItem] = []
        var prevDepth: Double? = nil
        // Rows on struts are a \baselineskip apart; after a rule TeX adds no interline glue (prev_depth is reset).
        func append(_ v: VBox, into list: inout [VItem]) {
            if let pd = prevDepth {
                let g = leading - pd - v.box.height
                list.append(.glue(Glue(width: g < 0 ? 1 : g)))
            }
            list.append(.box(v))
            prevDepth = v.box.depth
        }
        if let number, let caption = grid.caption {
            let saved = composer.items
            composer.items = []
            composer.captionLines(label: "Table \(number)", caption, ctx)
            items += composer.items
            composer.items = saved
            items.append(.glue(Glue(width: style.abovecaptionskip)))
        }
        var headerItems: [VItem] = [.box(rule(heavy)), .kern(below)]
        if let h = grid.header {
            append(rowBox(h, header: true), into: &headerItems)
            headerItems += [.kern(above), .box(rule(light)), .kern(below)]
            prevDepth = nil
        }
        items += headerItems
        let tableID = composer.nextTableID()
        for (k, row) in grid.body.enumerated() {
            var v = rowBox(row, header: false)
            v.tableID = tableID
            // No break after the first row or before the last (longtable's two-row minimum on a page).
            if k > 0 { items.append(.penalty(k == 1 || k == grid.body.count - 1 ? 10000 : 0)) }
            append(v, into: &items)
        }
        items += [.kern(above), .box(rule(heavy))]
        composer.registerTableHeader(tableID, headerItems)
        let isFloat = number != nil && Composer.height(of: items) <= style.geometry.textHeight * style.topfraction
        return Result(items: items, isFloat: isFloat)
    }

    private func cellStyle(_ size: SizeCommand) -> RunStyle {
        var s = composer.runStyle(ctx)
        s.size = style.size(size).size
        return s
    }

    /// The pieces at another size (`\small`, `\footnotesize`), keeping their other attributes.
    func resized(_ pieces: [InlinePiece], _ size: SizeCommand) -> [InlinePiece] {
        let ratio = style.size(size).size / style.normal.size
        guard abs(ratio - 1) > 0.001 else { return pieces }
        func r(_ v: Double) -> Double { (v * ratio * 100).rounded() / 100 }
        return pieces.map { p in
            switch p {
            case .text(let t, var s): s.size = r(s.size); return .text(t, s)
            case .math(let t, var s): s.size = r(s.size); return .math(t, s)
            case .footnote(let n, var s): s.size = r(s.size); return .footnote(n, s)
            default: return p
            }
        }
    }

    func naturalWidth(_ pieces: [InlinePiece]) -> Double {
        // The widest line between explicit line breaks.
        var widest = 0.0
        var current: [InlinePiece] = []
        for p in pieces + [.lineBreak] {
            if case .lineBreak = p { widest = max(widest, composer.setter.natural(current).width); current = [] } else { current.append(p) }
        }
        return widest
    }

    private func longestWord(_ c: GridTable.Cell, _ size: SizeCommand) -> Double {
        let s = cellStyle(size)
        let widest = c.text.split(whereSeparator: \.isWhitespace).map { composer.setter.natural([.text(String($0), s)]).width }.max() ?? 0
        return min(widest, 6 * style.size(size).size)
    }

    /// Widths that fit `available`: columns that need no wrapping keep their natural width; the rest share what is left
    /// in proportion to their natural widths, never below their longest word.
    private func distribute(natural: [Double], minimum: [Double], available: Double) -> [Double] {
        var widths = natural
        var fixed = Set<Int>()
        for _ in natural.indices {
            let flexible = natural.indices.filter { !fixed.contains($0) }
            let rest = available - fixed.reduce(0.0) { $0 + widths[$1] }
            let flexNatural = flexible.reduce(0.0) { $0 + natural[$1] }
            var changed = false
            for j in flexible {
                let share = flexNatural > 0 ? rest * natural[j] / flexNatural : rest / Double(flexible.count)
                if natural[j] <= share { widths[j] = natural[j]; fixed.insert(j); changed = true }
                else if minimum[j] > share { widths[j] = minimum[j]; fixed.insert(j); changed = true }
                else { widths[j] = share }
            }
            if !changed { break }
        }
        return widths
    }

    private func splitDecimal(_ s: String) -> (String, String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let dot = t.lastIndex(of: ".") { return (String(t[..<dot]), String(t[dot...])) }
        return (t, "")
    }

    /// Columns of numbers aligned on the decimal point (as siunitx does): the width of their widest fraction part.
    private func decimalColumns(_ grid: GridTable, _ size: SizeCommand) -> [Int: Double] {
        var out: [Int: Double] = [:]
        let s = cellStyle(size)
        for j in grid.alignments.indices where grid.alignments[j] == "r" {
            let cells = grid.body.compactMap { j < $0.count && $0[j].span == 1 ? $0[j] : nil }.filter { !$0.text.isEmpty }
            guard cells.count >= 2, cells.allSatisfy(\.numeric), cells.contains(where: { $0.text.contains(".") }) else { continue }
            let frac = cells.map { c -> Double in
                let f = splitDecimal(c.text).1
                return f.isEmpty ? 0 : composer.setter.natural([.text(f, s)]).width
            }.max() ?? 0
            out[j] = frac
        }
        return out
    }

    // MARK: Spreadsheets (quality §4)

    /// A sheet as booktabs tables: the header row detected and repeated, numbers decimal-aligned, wide sheets split into
    /// column bands that fit the measure.
    func sheet(_ sheet: Sheet) -> [Result] {
        var rows = sheet.rows
        if let area = sheet.printArea {
            rows = Array(rows[min(area.firstRow, rows.count)..<min(area.lastRow + 1, rows.count)])
                .map { Array($0[min(area.firstColumn, $0.count)..<min(area.lastColumn + 1, $0.count)]) }
        }
        while let last = rows.last, last.allSatisfy({ $0.value == .empty }) { rows.removeLast() }
        let columns = rows.map { r in (r.lastIndex { $0.value != .empty } ?? -1) + 1 }.max() ?? 0
        guard columns > 0, !rows.isEmpty else { return [] }
        let base = composer.runStyle(ctx)
        func cell(_ c: Cell?) -> GridTable.Cell {
            guard let c else { return GridTable.Cell(pieces: [], text: "") }
            let text = Self.display(c)
            var s = base
            if c.style.bold { s.bold = true }
            if c.style.italic { s.shape = .italic }
            var numeric = false
            if case .number = c.value { numeric = true }
            return GridTable.Cell(pieces: text.isEmpty ? [] : [.text(text, s)], text: text, numeric: numeric)
        }
        let grid = rows.map { r in (0..<columns).map { j in cell(j < r.count ? r[j] : nil) } }
        // A header: a first row of text over rows that hold numbers.
        let first = grid[0]
        let hasHeader = grid.count > 1 && first.allSatisfy { !$0.numeric } && first.contains { !$0.text.isEmpty }
            && grid.dropFirst().contains { $0.contains(where: \.numeric) }
        let body = hasHeader ? Array(grid.dropFirst()) : grid
        var alignments: [Character] = (0..<columns).map { j in
            let values = body.map { $0[j] }.filter { !$0.text.isEmpty }
            return !values.isEmpty && values.allSatisfy(\.numeric) ? "r" : "l"
        }
        for j in 0..<columns {
            if let a = rows.dropFirst(hasHeader ? 1 : 0).compactMap({ j < $0.count ? $0[j].style.alignment : nil }).first {
                alignments[j] = a == .centre ? "c" : a == .end ? "r" : alignments[j]
            }
        }
        // Column bands that fit the measure at \small.
        let measure = composer.lineWidth(ctx)
        var bands: [[Int]] = []
        var current: [Int] = []
        var width = 0.0
        for j in 0..<columns {
            let natural = ((hasHeader ? [first] : []) + body).map { naturalWidth(resized($0[j].pieces, .small)) }.max() ?? 0
            let w = min(natural, measure / 2) + 12
            if !current.isEmpty && width + w > measure { bands.append(current); current = []; width = 0 }
            current.append(j); width += w
        }
        if !current.isEmpty { bands.append(current) }
        return bands.map { band in
            layout(GridTable(header: hasHeader ? band.map { first[$0] } : nil, body: body.map { r in band.map { r[$0] } },
                             alignments: band.map { alignments[$0] }, caption: nil), number: nil)
        }
    }

    /// A cell as the spreadsheet showed it.
    static func display(_ c: Cell) -> String {
        if let shown = c.displayText { return shown }
        switch c.value {
        case .empty: return ""
        case .text(let t): return t
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e
        case .date(let d):
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withFullDate]
            return f.string(from: d)
        case .number(let n):
            if n == n.rounded() && abs(n) < 1e15 { return String(Int64(n)) }
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.usesGroupingSeparator = false
            f.usesSignificantDigits = true
            f.maximumSignificantDigits = 10
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: NSNumber(value: n)) ?? "\(n)"
        }
    }
}
