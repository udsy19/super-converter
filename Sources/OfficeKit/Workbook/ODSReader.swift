import Foundation
import SuperConverterCore

// ODS reader (formats §3.2): OpenDocument spreadsheets into `Workbook` — typed values, formulas with cached results,
// number formats from data styles, cell styles, merges, column widths, hidden sheets and print ranges. Repeated rows and
// columns are expanded up to a limit; charts, pictures and macros are not carried over and are reported.

enum ODSReader {
    static let maxRows = 1_048_576
    static let maxColumns = 16_384
    /// Repeated cells or rows that hold something are expanded only this far (a styled-empty tail is never expanded).
    static let repeatLimit = 1_024

    static func read(_ url: URL) throws -> XLSXReader.Result {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.damaged(FormatID("ods")) }
        return try read(data)
    }

    static func read(_ data: Data) throws -> XLSXReader.Result {
        let archive: ZipArchive
        do { archive = try ZipArchive(data: data) } catch { throw ConversionError.damaged(FormatID("ods")) }
        guard let contentData = try? archive.data("content.xml"), let content = try? XML.parse(contentData),
              content.name == "document-content" else { throw ConversionError.damaged(FormatID("ods")) }
        if archive.entry("META-INF/manifest.xml").flatMap({ try? archive.data(for: $0) }).flatMap({ String(data: $0, encoding: .utf8) })?
            .contains("encryption-data") == true {
            throw ConversionError.passwordRequired(FormatID("ods"))
        }
        var styles = StyleSheet()
        if let data = try? archive.data("styles.xml"), let root = try? XML.parse(data) { styles.add(root) }
        styles.add(content)

        var sheets: [Sheet] = []
        var truncated = false
        var budget = XLSXReader.maxCells
        for table in content.first("spreadsheet")?.children("table") ?? [] {
            var sheet = Sheet(name: table.attr("table:name") ?? "Sheet\(sheets.count + 1)")
            if let style = table.attr("table:style-name"), styles.tableHidden.contains(style) { sheet.isHidden = true }
            sheet.printArea = table.attr("table:print-ranges").flatMap(printRange)
            truncated = read(table, into: &sheet, styles: styles, budget: &budget) || truncated
            sheets.append(sheet)
        }
        if sheets.isEmpty { throw ConversionError.damaged(FormatID("ods")) }

        var notes: [LossNote] = []
        if archive.entries.contains(where: { $0.path.hasPrefix("Object ") }) || content.first("chart") != nil {
            notes.append(LossNote(.otherLoss, detail: "Charts weren’t carried over, only the cells."))
        }
        if content.first("image") != nil { notes.append(LossNote(.imagesDropped, detail: "Pictures weren’t carried over, only the cells.")) }
        if archive.entries.contains(where: { $0.path.hasPrefix("Basic/") || $0.path.hasPrefix("Scripts/") }) { notes.append(LossNote(.macrosDropped)) }
        var title: String?
        if let metaData = try? archive.data("meta.xml"), let meta = try? XML.parse(metaData) {
            let text = meta.first("title")?.allText.trimmingCharacters(in: .whitespacesAndNewlines)
            title = (text?.isEmpty ?? true) ? nil : text
        }
        return XLSXReader.Result(workbook: Workbook(sheets: sheets, title: title), lossNotes: notes,
                                 warnings: truncated ? ["This spreadsheet is very large, so only its first rows and columns were read."] : [])
    }

    // MARK: Sheets

    /// A repeat or span count, from 1 to `limit`: a damaged "-1" or "2147483647" must neither run a loop backwards nor
    /// overflow the index it moves.
    private static func count(_ node: XMLNode, _ name: String, limit: Int) -> Int {
        min(max(node.attr(name).flatMap(Int.init) ?? 1, 1), limit)
    }

    /// Fills `sheet`, spending `budget` (the cells the sheet's rows hold, `XLSXReader.maxCells` for the workbook); true
    /// when rows or columns past the limits were left out.
    private static func read(_ table: XMLNode, into sheet: inout Sheet, styles: StyleSheet, budget: inout Int) -> Bool {
        var truncated = false
        // Columns: widths and default cell styles by index.
        var columnDefaults: [Int: String] = [:]
        var column = 0
        func columns(in node: XMLNode) {
            for child in node.children {
                switch child.name {
                case "table-column":
                    let repeated = Self.count(child, "table:number-columns-repeated", limit: maxColumns)
                    for c in column..<min(column + repeated, maxColumns) {
                        if let style = child.attr("table:style-name"), let width = styles.columnWidths[style] { sheet.columnWidths[c] = width }
                        if let style = child.attr("table:default-cell-style-name") { columnDefaults[c] = style }
                    }
                    column = min(column + repeated, maxColumns)
                case "table-column-group", "table-header-columns", "table-columns": columns(in: child)
                default: break
                }
            }
        }
        columns(in: table)

        var rows: [[Cell]] = []
        var merges: [CellRange] = []
        var rowIndex = 0
        func readRows(in node: XMLNode) {
            for child in node.children {
                switch child.name {
                case "table-row-group", "table-header-rows", "table-rows": readRows(in: child)
                case "table-row":
                    let repeated = Self.count(child, "table:number-rows-repeated", limit: maxRows)
                    var cells: [Cell] = []
                    var columnIndex = 0
                    var hasContent = false
                    for cellNode in child.children where cellNode.name == "table-cell" || cellNode.name == "covered-table-cell" {
                        let times = Self.count(cellNode, "table:number-columns-repeated", limit: maxColumns)
                        guard cellNode.name == "table-cell" else { columnIndex += times; continue }
                        let cell = Self.cell(cellNode, styles: styles, defaultStyle: columnDefaults[columnIndex])
                        let isEmpty = cell.value == .empty && cell.formula == nil && cell.style == CellStyle() && cell.numberFormat == nil
                        if isEmpty { columnIndex += times; continue }
                        hasContent = true
                        let count = min(times, repeatLimit)
                        if columnIndex + count > maxColumns { truncated = true; break }
                        if cells.count < columnIndex { cells += [Cell](repeating: Cell(), count: columnIndex - cells.count) }
                        for k in 0..<count {
                            cells.append(cell)
                            if k == 0 {
                                let spanColumns = Self.count(cellNode, "table:number-columns-spanned", limit: maxColumns)
                                let spanRows = Self.count(cellNode, "table:number-rows-spanned", limit: maxRows)
                                if spanColumns > 1 || spanRows > 1 {
                                    merges.append(CellRange(firstRow: rowIndex, firstColumn: columnIndex, lastRow: rowIndex + spanRows - 1,
                                                            lastColumn: columnIndex + spanColumns - 1))
                                }
                            }
                        }
                        columnIndex += times
                    }
                    if !hasContent { rowIndex += repeated; continue }
                    for _ in 0..<min(repeated, repeatLimit) {
                        if rowIndex >= maxRows || cells.count > budget { truncated = true; return }
                        budget -= cells.count
                        if rows.count < rowIndex { rows += [[Cell]](repeating: [], count: rowIndex - rows.count) }
                        rows.append(cells)
                        rowIndex += 1
                    }
                    if repeated > repeatLimit { rowIndex += repeated - repeatLimit }
                default: break
                }
            }
        }
        readRows(in: table)
        sheet.rows = rows
        sheet.merges = merges
        return truncated
    }

    // MARK: Cells

    private static func cell(_ node: XMLNode, styles: StyleSheet, defaultStyle: String?) -> Cell {
        var cell = Cell()
        if let name = node.attr("table:style-name") ?? defaultStyle {
            let resolved = styles.resolve(name)
            cell.style = resolved.style
            cell.numberFormat = resolved.format
        }
        if let formula = node.attr("table:formula") { cell.formula = ODFFormula.toExcel(formula) }
        let text = paragraphText(node)
        let hasText = !text.isEmpty
        switch node.attr("office:value-type") {
        case "float", "percentage", "currency":
            guard let value = node.attr("office:value").flatMap(Double.init) else { break }
            cell.value = .number(value)
            if node.attr("office:value-type") == "percentage", cell.numberFormat == nil { cell.numberFormat = "0%" }
            if hasText, cell.numberFormat != nil || text != SheetNumberFormat.general(value) { cell.displayText = text }
        case "date":
            if let iso = node.attr("office:date-value"), let date = parseDate(iso) {
                cell.value = .date(date)
                if cell.numberFormat == nil { cell.numberFormat = iso.contains("T") ? "yyyy-mm-dd hh:mm:ss" : "yyyy-mm-dd" }
                if hasText { cell.displayText = text }
            }
        case "time":
            if let duration = node.attr("office:time-value"), let days = parseDuration(duration) {
                cell.value = .number(days)
                if cell.numberFormat == nil { cell.numberFormat = "hh:mm:ss" }
                if hasText { cell.displayText = text }
            }
        case "boolean":
            cell.value = .bool(node.attr("office:boolean-value") == "true")
        case "string":
            if node.attr("calcext:value-type") == "error" { cell.value = .error(text) }
            else { cell.value = .text(node.attr("office:string-value") ?? text) }
        default:
            // No value type: a formula result is unknown; text, if any, is the value.
            if hasText { cell.value = .text(text) }
        }
        return cell
    }

    /// The paragraphs of a cell joined by line breaks, with `text:s`, `text:tab` and `text:line-break` expanded.
    static func paragraphText(_ node: XMLNode) -> String {
        node.children("p").map { runs($0) }.joined(separator: "\n")
    }

    private static func runs(_ node: XMLNode) -> String {
        node.content.map { item -> String in
            switch item {
            case .text(let t): return t
            case .element(let child):
                switch child.name {
                // At most a thousand spaces a run: a damaged count must not become a string of billions.
                case "s": return String(repeating: " ", count: min(max(child.attr("text:c").flatMap(Int.init) ?? 1, 0), 1_000))
                case "tab": return "\t"
                case "line-break": return "\n"
                default: return runs(child)
                }
            }
        }.joined()
    }

    /// "2024-03-15" or "2024-03-15T10:30:00[.5]" (UTC; a trailing zone is ignored).
    private static func parseDate(_ iso: String) -> Date? {
        let halves = iso.split(separator: "T", maxSplits: 1).map(String.init)
        guard let first = halves.first else { return nil }
        let day = first.split(separator: "-").compactMap { Int($0) }
        guard day.count == 3 else { return nil }
        var parts = DateComponents(year: day[0], month: day[1], day: day[2])
        var seconds = 0.0
        if halves.count > 1 {
            let clock = halves[1].prefix { $0.isNumber || $0 == ":" || $0 == "." }.split(separator: ":").compactMap { Double($0) }
            // Hours, minutes and seconds become Ints: a damaged "99999999999999999999" is not a time.
            guard clock.allSatisfy({ $0 < 1_000_000 }) else { return nil }
            parts.hour = clock.count > 0 ? Int(clock[0]) : 0
            parts.minute = clock.count > 1 ? Int(clock[1]) : 0
            let second = clock.count > 2 ? clock[2] : 0
            parts.second = Int(second)
            seconds = second - Double(Int(second))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: parts).map { $0.addingTimeInterval(seconds) }
    }

    /// "PT10H30M00S" → a fraction of a day.
    private static func parseDuration(_ text: String) -> Double? {
        guard text.hasPrefix("PT") else { return nil }
        var total = 0.0, number = ""
        for ch in text.dropFirst(2) {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            guard let value = Double(number) else { return nil }
            number = ""
            switch ch {
            case "H": total += value * 3600
            case "M": total += value * 60
            case "S": total += value
            default: return nil
            }
        }
        return total / 86_400
    }

    /// "Sheet1.A1:Sheet1.C5" or "$Sheet1.$A$1:.$C$5" → the first range.
    private static func printRange(_ text: String) -> CellRange? {
        let first = text.split(separator: " ").first.map(String.init) ?? text
        let refs = first.split(separator: ":").compactMap { part -> (row: Int, column: Int)? in
            let ref = part.split(separator: ".").last.map(String.init) ?? String(part)
            return WorksheetParser.reference(ref)
        }
        guard let a = refs.first else { return nil }
        let b = refs.count > 1 ? refs[1] : a
        return CellRange(firstRow: min(a.row, b.row), firstColumn: min(a.column, b.column), lastRow: max(a.row, b.row), lastColumn: max(a.column, b.column))
    }

    // MARK: Styles

    /// Cell styles, data styles, column widths and hidden tables from `styles.xml` and `content.xml`.
    struct StyleSheet {
        private var dataStyles: [String: String] = [:]
        private var cellStyles: [String: XMLNode] = [:]
        private(set) var columnWidths: [String: Double] = [:]
        private(set) var tableHidden: Set<String> = []

        mutating func add(_ root: XMLNode) {
            for group in [root.child("styles"), root.child("automatic-styles")].compactMap({ $0 }) {
                for node in group.children {
                    if let code = ODFNumberStyles.code(from: node), let name = node.attr("style:name") { dataStyles[name] = code }
                    guard node.name == "style", let name = node.attr("style:name") else { continue }
                    switch node.attr("style:family") {
                    case "table-cell": cellStyles[name] = node
                    case "table-column":
                        if let width = node.child("table-column-properties")?.attr("style:column-width").flatMap(Self.inches) {
                            columnWidths[name] = ODSWriter.characters(inches: width)
                        }
                    case "table": if node.child("table-properties")?.attr("table:display") == "false" { tableHidden.insert(name) }
                    default: break
                    }
                }
            }
        }

        private static func inches(_ length: String) -> Double? {
            let units: [(String, Double)] = [("in", 1), ("cm", 1 / 2.54), ("mm", 1 / 25.4), ("pt", 1 / 72), ("pc", 1 / 6)]
            for (suffix, factor) in units where length.hasSuffix(suffix) {
                return Double(length.dropLast(suffix.count)).map { $0 * factor }
            }
            return nil
        }

        /// A cell style with its parents' properties underneath.
        func resolve(_ name: String) -> (style: CellStyle, format: String?) {
            var chain: [XMLNode] = []
            var current: String? = name
            while let n = current, let node = cellStyles[n], chain.count < 16 {
                chain.insert(node, at: 0)
                current = node.attr("style:parent-style-name")
            }
            var style = CellStyle()
            var format: String?
            for node in chain {
                if let data = node.attr("style:data-style-name") { format = dataStyles[data] ?? format }
                if let text = node.child("text-properties") {
                    if let weight = text.attr("fo:font-weight") { style.bold = weight == "bold" || (Int(weight) ?? 400) >= 600 }
                    if let italic = text.attr("fo:font-style") { style.italic = italic == "italic" }
                    if let font = text.attr("style:font-name") ?? text.attr("fo:font-family") { style.fontName = font }
                    if let size = text.attr("fo:font-size"), size.hasSuffix("pt") { style.fontSize = Double(size.dropLast(2)) }
                    if let colour = text.attr("fo:color") { style.textColour = SheetRGB(hex: colour)?.hash }
                }
                if let properties = node.child("table-cell-properties") {
                    if let fill = properties.attr("fo:background-color") { style.fillColour = fill == "transparent" ? nil : SheetRGB(hex: fill)?.hash }
                    if let wrap = properties.attr("fo:wrap-option") { style.wrapsText = wrap == "wrap" }
                }
                if let align = node.child("paragraph-properties")?.attr("fo:text-align") {
                    switch align {
                    case "start", "left": style.alignment = .start
                    case "center": style.alignment = .centre
                    case "end", "right": style.alignment = .end
                    case "justify": style.alignment = .justified
                    default: break
                    }
                }
            }
            return (style, format)
        }
    }
}
