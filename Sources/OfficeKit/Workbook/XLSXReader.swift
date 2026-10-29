import Foundation
import SuperConverterCore

// Origin: Super PDF Sources/ConvertKit/Import/SpreadsheetImporter.swift @ 058469b (package, styles, shared strings and
// worksheet parsing), adapted: the result is Core's `Workbook` (values, formulas with cached results, number formats,
// styles, merges, widths, hidden sheets, print areas) instead of a print grid, and shared formulas are expanded.
//
// XLSX / XLSM reader (formats §3.2). Charts, pictures, pivot tables and macros are not carried over; each is reported.

enum XLSXReader {
    /// Bounds that keep a hostile or enormous workbook from filling memory.
    static let maxRows = 1_048_576
    static let maxColumns = 16_384
    static let maxCells = 5_000_000

    struct Result {
        var workbook: Workbook
        var lossNotes: [LossNote]
        var warnings: [String]
    }

    static func read(_ url: URL) throws -> Result {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.damaged(FormatID("xlsx")) }
        return try read(data)
    }

    static func read(_ data: Data) throws -> Result {
        // Password-protected OOXML is an OLE2 container, not a ZIP.
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { throw ConversionError.passwordRequired(FormatID("xlsx")) }
        let archive: ZipArchive
        do { archive = try ZipArchive(data: data) } catch { throw ConversionError.damaged(FormatID("xlsx")) }
        do { return try read(archive) } catch let error as ConversionError { throw error } catch { throw ConversionError.damaged(FormatID("xlsx")) }
    }

    private static func read(_ archive: ZipArchive) throws -> Result {
        let rootRels = SheetRels(archive: archive, part: "")
        let workbookPath = rootRels.target(ofType: "/officeDocument") ?? "xl/workbook.xml"
        guard let workbookData = try archive.data(workbookPath) else { throw ConversionError.damaged(FormatID("xlsx")) }
        let root = try XML.parse(workbookData)
        guard root.name == "workbook" else { throw ConversionError.damaged(FormatID("xlsx")) }
        let rels = SheetRels(archive: archive, part: workbookPath)
        let date1904 = ["1", "true"].contains(root.child("workbookPr")?.attr("date1904") ?? "")

        var strings: [String] = []
        if let path = rels.target(ofType: "/sharedStrings") ?? (archive.entry("xl/sharedStrings.xml") != nil ? "xl/sharedStrings.xml" : nil),
           let data = try archive.data(path) {
            strings = SharedStringsParser.parse(data)
        }
        var theme: [SheetRGB] = []
        if let path = rels.target(ofType: "/theme"), let data = try? archive.data(path), let themeRoot = try? XML.parse(data) {
            theme = themeColours(themeRoot)
        }
        var styles = StyleTable()
        if let path = rels.target(ofType: "/styles") ?? (archive.entry("xl/styles.xml") != nil ? "xl/styles.xml" : nil),
           let data = try archive.data(path), let stylesRoot = try? XML.parse(data) {
            styles = StyleTable(stylesRoot, theme: theme)
        }

        var printAreas: [Int: String] = [:]
        for name in root.child("definedNames")?.children("definedName") ?? [] where name.attr("name") == "_xlnm.Print_Area" {
            if let id = name.attr("localSheetId").flatMap(Int.init) { printAreas[id] = name.allText }
        }

        var sheets: [Sheet] = []
        var truncated = false
        var cellBudget = maxCells
        for (index, entry) in (root.child("sheets")?.children("sheet") ?? []).enumerated() {
            let name = entry.attr("name") ?? "Sheet\(index + 1)"
            let hidden = (entry.attr("state") ?? "visible") != "visible"
            guard let path = entry.attr("r:id").flatMap({ rels.target(id: $0) }), let data = try archive.data(path) else {
                // A chart sheet or a missing part: an empty sheet keeps the order and names.
                sheets.append(Sheet(name: name, isHidden: hidden))
                continue
            }
            let parsed = WorksheetParser.parse(data, maxRows: maxRows, maxColumns: maxColumns, budget: cellBudget)
            truncated = truncated || parsed.truncated
            var sheet = build(parsed, name: name, styles: styles, strings: strings, date1904: date1904, budget: &cellBudget, truncated: &truncated)
            sheet.isHidden = hidden
            sheet.printArea = printAreas[index].flatMap(printArea)
            sheets.append(sheet)
        }
        if sheets.isEmpty { throw ConversionError.damaged(FormatID("xlsx")) }

        var notes: [LossNote] = []
        var warnings: [String] = []
        if archive.entries.contains(where: { $0.path.hasPrefix("xl/charts/") || $0.path.hasPrefix("xl/chartsheets/") }) {
            notes.append(LossNote(.otherLoss, detail: "Charts weren’t carried over, only the cells."))
        }
        if archive.entries.contains(where: { $0.path.hasPrefix("xl/media/") }) {
            notes.append(LossNote(.imagesDropped, detail: "Pictures weren’t carried over, only the cells."))
        }
        if archive.entry("xl/vbaProject.bin") != nil { notes.append(LossNote(.macrosDropped)) }
        if truncated { warnings.append("This workbook is very large, so only its first rows and columns were read.") }

        var title: String?
        if let core = try? archive.data("docProps/core.xml"), let node = try? XML.parse(core) {
            let text = node.child("title")?.allText.trimmingCharacters(in: .whitespacesAndNewlines)
            title = (text?.isEmpty ?? true) ? nil : text
        }
        return Result(workbook: Workbook(sheets: sheets, title: title), lossNotes: notes, warnings: warnings)
    }

    // MARK: Building the model

    private static func build(_ parsed: WorksheetParser.Result, name: String, styles: StyleTable, strings: [String], date1904: Bool,
                              budget: inout Int, truncated: inout Bool) -> Sheet {
        var sheet = Sheet(name: name)
        sheet.rows = rows(parsed.cells, budget: &budget, truncated: &truncated) { cell($0, styles: styles, strings: strings, date1904: date1904) }
        sheet.merges = parsed.merges
        for (column, info) in parsed.columns {
            if let width = info.width { sheet.columnWidths[column] = width }
        }
        return sheet
    }

    /// Sparse cells (row → column → cell) laid out as the model's rows, each padded to its last cell, for as long as the grid
    /// stays within `budget` cells: a few cells far out to the right of many rows ("XFD1048576") must not become billions
    /// of empty ones. Rows past the budget are left out and `truncated` is set.
    static func rows<T>(_ cells: [Int: [Int: T]], budget: inout Int, truncated: inout Bool, cell: (T) -> Cell) -> [[Cell]] {
        var rows: [[Cell]] = []
        for r in cells.keys.sorted() {
            guard let row = cells[r], let lastColumn = row.keys.max() else { continue }
            guard lastColumn < budget else { truncated = true; break }
            budget -= lastColumn + 1
            var line = [Cell](repeating: Cell(), count: lastColumn + 1)
            for (c, value) in row { line[c] = cell(value) }
            if rows.count < r { rows += [[Cell]](repeating: [], count: r - rows.count) }
            rows.append(line)
        }
        return rows
    }

    private static func cell(_ raw: WorksheetParser.RawCell, styles: StyleTable, strings: [String], date1904: Bool) -> Cell {
        let xf = styles.xf(raw.style)
        var cell = Cell(style: xf.style)
        let code = xf.format.code
        if code != "General" { cell.numberFormat = code }
        cell.formula = raw.formula
        let text: String
        switch raw.type {
        case "s": text = Int(raw.value).flatMap { $0 >= 0 && $0 < strings.count ? strings[$0] : nil } ?? ""
        case "inlineStr": text = raw.inline.isEmpty ? raw.value : raw.inline
        default: text = raw.value
        }
        switch raw.type {
        case "s", "inlineStr", "str":
            cell.value = .text(text)
            if cell.numberFormat != nil, case let shown = xf.format.format(text: text), shown != text { cell.displayText = shown }
        case "b":
            cell.value = .bool(raw.value == "1" || raw.value == "true")
        case "e":
            cell.value = .error(raw.value)
        case "d":
            if let serial = SheetNumberFormat.serial(iso: raw.value, date1904: date1904),
               let date = SheetNumberFormat.date(fromSerial: serial, date1904: date1904) {
                cell.value = .date(date)
                cell.displayText = (xf.format.isDate ? xf.format : SheetNumberFormat(code: "yyyy-mm-dd")).format(serial, date1904: date1904)
                if cell.numberFormat == nil { cell.numberFormat = "yyyy-mm-dd" }
            } else {
                cell.value = .text(raw.value)
            }
        default:
            let trimmed = raw.value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return cell }
            guard let number = Double(trimmed) else { cell.value = .text(raw.value); return cell }
            if xf.format.isDate, let date = SheetNumberFormat.date(fromSerial: number, date1904: date1904) {
                cell.value = .date(date)
            } else {
                cell.value = .number(number)
            }
            if cell.numberFormat != nil { cell.displayText = xf.format.format(number, date1904: date1904) }
        }
        return cell
    }

    /// "Sheet1!$A$1:$C$5" or "'My Sheet'!$A$1" → the range; only the first area of a multi-area print range.
    private static func printArea(_ text: String) -> CellRange? {
        let area = text.split(separator: ",").first.map(String.init) ?? text
        let ref = area.split(separator: "!").last.map(String.init) ?? area
        let corners = ref.split(separator: ":").map(String.init)
        guard let a = corners.first.flatMap(WorksheetParser.reference) else { return nil }
        let b = corners.count > 1 ? WorksheetParser.reference(corners[1]) ?? a : a
        return CellRange(firstRow: min(a.row, b.row), firstColumn: min(a.column, b.column), lastRow: max(a.row, b.row), lastColumn: max(a.column, b.column))
    }

    /// The theme's colours in Excel's index order: lt1, dk1, lt2, dk2, accent1–6, hlink, folHlink.
    private static func themeColours(_ root: XMLNode) -> [SheetRGB] {
        guard let scheme = root.first("clrScheme") else { return [] }
        func colour(_ name: String) -> SheetRGB {
            guard let node = scheme.child(name) else { return .black }
            if let hex = node.child("srgbClr")?.attr("val"), let rgb = SheetRGB(hex: hex) { return rgb }
            if let hex = node.child("sysClr")?.attr("lastClr"), let rgb = SheetRGB(hex: hex) { return rgb }
            return .black
        }
        return ["lt1", "dk1", "lt2", "dk2", "accent1", "accent2", "accent3", "accent4", "accent5", "accent6", "hlink", "folHlink"].map(colour)
    }

    // MARK: Styles

    /// `cellXfs` resolved: one style and one number format per cell format.
    struct StyleTable {
        struct XF { var style: CellStyle; var format: SheetNumberFormat }
        private(set) var xfs: [XF] = []
        private let fallback = XF(style: CellStyle(), format: SheetNumberFormat(code: "General"))

        init() {}

        func xf(_ index: Int) -> XF { index >= 0 && index < xfs.count ? xfs[index] : (xfs.first ?? fallback) }

        init(_ root: XMLNode, theme: [SheetRGB]) {
            var codes: [Int: String] = [:]
            for fmt in root.child("numFmts")?.children("numFmt") ?? [] {
                if let id = fmt.attr("numFmtId").flatMap(Int.init), let code = fmt.attr("formatCode") { codes[id] = code }
            }
            func colour(_ node: XMLNode?) -> SheetRGB? {
                guard let node, node.attr("auto") != "1" else { return nil }
                var rgb: SheetRGB?
                if let hex = node.attr("rgb") { rgb = SheetRGB(hex: hex) }
                else if let index = node.attr("theme").flatMap(Int.init), index < theme.count { rgb = theme[index] }
                else if let index = node.attr("indexed").flatMap(Int.init) { rgb = SheetPalette.indexed(index) }
                if let tint = node.attr("tint").flatMap(Double.init) { rgb = rgb?.tinted(tint) }
                return rgb
            }
            struct Font { var name: String?; var size: Double?; var bold: Bool; var italic: Bool; var colour: SheetRGB? }
            let fonts: [Font] = (root.child("fonts")?.children("font") ?? []).map { font in
                func flag(_ name: String) -> Bool { font.child(name).map { $0.attr("val").map { $0 != "0" && $0 != "false" } ?? true } ?? false }
                return Font(name: font.child("name")?.attr("val"), size: font.child("sz")?.attr("val").flatMap(Double.init),
                            bold: flag("b"), italic: flag("i"), colour: colour(font.child("color")))
            }
            let fills: [SheetRGB?] = (root.child("fills")?.children("fill") ?? []).map { fill in
                if let pattern = fill.child("patternFill") {
                    guard pattern.attr("patternType") == "solid" else { return nil }
                    // Indexed 64 is "automatic": no fill.
                    if pattern.child("fgColor")?.attr("indexed") == "64" { return colour(pattern.child("bgColor")) }
                    return colour(pattern.child("fgColor")) ?? colour(pattern.child("bgColor"))
                }
                return fill.child("gradientFill")?.child("stop").flatMap { colour($0.child("color")) }
            }
            for xf in root.child("cellXfs")?.children("xf") ?? [] {
                var style = CellStyle()
                let fontIndex = xf.attr("fontId").flatMap(Int.init) ?? 0
                if fontIndex < fonts.count {
                    let font = fonts[fontIndex]
                    style.bold = font.bold; style.italic = font.italic
                    // The workbook's default font (font 0) is the baseline, not a choice a cell made.
                    if fontIndex > 0, let base = fonts.first {
                        if font.name != base.name { style.fontName = font.name }
                        if font.size != base.size { style.fontSize = font.size }
                    }
                    style.textColour = font.colour.flatMap { $0 == .black ? nil : $0.hash }
                }
                if let fill = xf.attr("fillId").flatMap(Int.init), fill < fills.count { style.fillColour = fills[fill]?.hash }
                if let alignment = xf.child("alignment") {
                    switch alignment.attr("horizontal") {
                    case "left": style.alignment = .start
                    case "center", "centerContinuous": style.alignment = .centre
                    case "right": style.alignment = .end
                    case "justify", "distributed": style.alignment = .justified
                    default: break
                    }
                    style.wrapsText = ["1", "true"].contains(alignment.attr("wrapText") ?? "")
                }
                let id = xf.attr("numFmtId").flatMap(Int.init) ?? 0
                xfs.append(XF(style: style, format: SheetNumberFormat(code: codes[id] ?? SheetNumberFormat.builtIn(id), builtInID: codes[id] == nil ? id : nil)))
            }
        }
    }
}

/// A part's relationships (`_rels/*.rels`), with targets resolved to archive paths.
struct SheetRels {
    private var targets: [String: (type: String, target: String)] = [:]

    init(archive: ZipArchive, part: String) {
        let folder = (part as NSString).deletingLastPathComponent
        let relsPath = (folder.isEmpty ? "" : folder + "/") + "_rels/" + (part as NSString).lastPathComponent + ".rels"
        guard let data = try? archive.data(relsPath), let root = try? XML.parse(data) else { return }
        for rel in root.children("Relationship") {
            guard let id = rel.attr("Id"), let target = rel.attr("Target"), rel.attr("TargetMode") != "External" else { continue }
            targets[id] = (rel.attr("Type") ?? "", Self.resolve(target, from: folder))
        }
    }

    func target(id: String) -> String? { targets[id]?.target }

    /// The first target whose relationship type ends with `suffix` ("/styles").
    func target(ofType suffix: String) -> String? {
        targets.values.filter { $0.type.hasSuffix(suffix) }.map(\.target).sorted().first
    }

    static func resolve(_ target: String, from folder: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var parts = folder.split(separator: "/").map(String.init)
        for piece in target.split(separator: "/").map(String.init) {
            if piece == ".." { _ = parts.popLast() } else if piece != "." { parts.append(piece) }
        }
        return parts.joined(separator: "/")
    }
}

// MARK: - Streaming parsers (worksheets and shared strings can be large)

enum SharedStringsParser {
    static func parse(_ data: Data) -> [String] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inItem = false, inText = false, phonetic = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch WorksheetParser.local(name) {
            case "si": inItem = true; current = ""
            case "rPh": phonetic += 1
            case "t": inText = inItem && phonetic == 0
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch WorksheetParser.local(name) {
            case "si": strings.append(current); inItem = false
            case "rPh": phonetic -= 1
            case "t": inText = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }
    }
}

enum WorksheetParser {
    struct RawCell {
        var value = ""
        /// Inline string text (`<is>`).
        var inline = ""
        var type: String?
        var style = 0
        var formula: String?
    }

    struct ColumnInfo { var width: Double?; var hidden = false }

    struct Result {
        var cells: [Int: [Int: RawCell]] = [:]
        var columns: [Int: ColumnInfo] = [:]
        var merges: [CellRange] = []
        var cellCount = 0
        /// Cells past the row or column limit were left out.
        var truncated = false
    }

    static func parse(_ data: Data, maxRows: Int, maxColumns: Int, budget: Int) -> Result {
        let delegate = Delegate(maxRows: maxRows, maxColumns: maxColumns, budget: budget)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.finish()
    }

    static func local(_ name: String) -> Substring {
        guard let colon = name.lastIndex(of: ":") else { return Substring(name) }
        return name[name.index(after: colon)...]
    }

    /// "AB12" → (row 11, column 27); nil when malformed.
    static func reference(_ ref: String) -> (row: Int, column: Int)? {
        var column = 0, row = 0, sawLetter = false, sawDigit = false
        for scalar in ref.unicodeScalars {
            switch scalar.value {
            case 65...90, 97...122:
                guard !sawDigit else { return nil }
                column = column * 26 + Int((scalar.value & 0xDF) - 64)
                sawLetter = true
                if column > 20_000 { return nil }
            case 48...57:
                row = row * 10 + Int(scalar.value - 48)
                sawDigit = true
                if row > 2_000_000 { return nil }
            case 36: continue   // "$A$1"
            default: return nil
            }
        }
        guard sawLetter, sawDigit, row > 0 else { return nil }
        return (row - 1, column - 1)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var result = Result()
        let maxRows: Int, maxColumns: Int, budget: Int
        private var row = -1, nextColumn = 0, columnWork = 0
        private var cell: RawCell?
        private var cellPosition: (row: Int, column: Int)?
        private var inValue = false, inInline = false, inInlineText = false, inFormula = false, phonetic = 0
        private var formulaShare: (si: String, isMaster: Bool)?
        /// Shared formulas: index → (anchor row, anchor column, text).
        private var masters: [String: (row: Int, column: Int, text: String)] = [:]
        private var dependents: [(row: Int, column: Int, si: String)] = []

        init(maxRows: Int, maxColumns: Int, budget: Int) { self.maxRows = maxRows; self.maxColumns = maxColumns; self.budget = budget }

        func finish() -> Result {
            for dependent in dependents {
                guard let master = masters[dependent.si] else { continue }
                result.cells[dependent.row]?[dependent.column]?.formula = FormulaShift.shift(master.text, rows: dependent.row - master.row,
                                                                                            columns: dependent.column - master.column)
            }
            return result
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch local(name) {
            case "row":
                // Held to the sheet's rows (and one past, where cells are left out) so a damaged "r" can't overflow the count.
                row = attributes["r"].flatMap(Int.init).map { min(max($0, 0), maxRows + 1) - 1 } ?? min(row + 1, maxRows)
                nextColumn = 0
            case "c":
                var position = attributes["r"].flatMap(WorksheetParser.reference) ?? (row, nextColumn)
                if position.row < 0 { position.row = max(row, 0) }
                nextColumn = position.column + 1
                cellPosition = position
                cell = RawCell(type: attributes["t"], style: attributes["s"].flatMap(Int.init) ?? 0)
            case "f":
                guard cell != nil else { return }
                inFormula = true
                if attributes["t"] == "shared", let si = attributes["si"] { formulaShare = (si, attributes["ref"] != nil) } else { formulaShare = nil }
            case "v": inValue = cell != nil
            case "is": inInline = cell != nil
            case "rPh": phonetic += 1
            case "t": inInlineText = inInline && phonetic == 0
            case "col":
                guard let min = attributes["min"].flatMap(Int.init), let max = attributes["max"].flatMap(Int.init), min >= 1, max >= min else { return }
                let info = ColumnInfo(width: attributes["width"].flatMap(Double.init).map { Swift.min(Swift.max($0, 0), 255) },
                                      hidden: attributes["hidden"] == "1" || attributes["hidden"] == "true")
                let upper = Swift.min(max, maxColumns)
                // Valid `col`s don't overlap, so a sheet's widths take at most a few passes over its columns; damaged ones
                // that each span the sheet must not take hours.
                guard min - 1 < upper, columnWork < 4 * maxColumns else { return }
                columnWork += upper - (min - 1)
                for c in (min - 1)..<upper { result.columns[c] = info }
            case "mergeCell":
                guard let ref = attributes["ref"] else { return }
                let corners = ref.split(separator: ":").map(String.init)
                guard let a = corners.first.flatMap(WorksheetParser.reference) else { return }
                let b = corners.count > 1 ? WorksheetParser.reference(corners[1]) ?? a : a
                let merge = CellRange(firstRow: Swift.min(a.row, b.row), firstColumn: Swift.min(a.column, b.column),
                                      lastRow: Swift.max(a.row, b.row), lastColumn: Swift.max(a.column, b.column))
                if merge.firstRow < maxRows, merge.firstColumn < maxColumns, result.merges.count < 50_000 { result.merges.append(merge) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch local(name) {
            case "c":
                defer { cell = nil; cellPosition = nil; formulaShare = nil }
                guard let cell, let position = cellPosition else { return }
                guard position.row < maxRows, position.column < maxColumns, result.cellCount < budget else { result.truncated = true; return }
                guard !cell.value.isEmpty || !cell.inline.isEmpty || cell.style != 0 || cell.formula != nil else { return }
                result.cells[position.row, default: [:]][position.column] = cell
                result.cellCount += 1
            case "f":
                inFormula = false
                guard let share = formulaShare, let position = cellPosition else { return }
                if share.isMaster, let text = cell?.formula { masters[share.si] = (position.row, position.column, text) }
                else if cell?.formula == nil { dependents.append((position.row, position.column, share.si)) }
            case "v": inValue = false
            case "is": inInline = false
            case "rPh": phonetic -= 1
            case "t": inInlineText = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue { cell?.value += string }
            else if inInlineText { cell?.inline += string }
            else if inFormula { let existing = cell?.formula ?? ""; cell?.formula = existing + string }
        }
    }
}

/// Moves the relative references of a formula by whole rows and columns (what copying a cell does): shared formulas store
/// the text once and every other cell in the range derives from it.
enum FormulaShift {
    private static let reference = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.\]!'])(\$?)([A-Z]{1,3})(\$?)([0-9]{1,7})(?![A-Za-z0-9_(])"#)

    static func shift(_ formula: String, rows: Int, columns: Int) -> String {
        guard rows != 0 || columns != 0 else { return formula }
        // Text in double quotes is left alone: split into quoted and unquoted runs.
        var out = ""
        var run = ""
        var quoted = false
        func flush() { out += quoted ? run : shiftReferences(run, rows: rows, columns: columns); run = "" }
        for ch in formula {
            if ch == "\"" {
                if quoted { run.append(ch); flush(); quoted = false } else { flush(); quoted = true; run.append(ch) }
            } else {
                run.append(ch)
            }
        }
        flush()
        return out
    }

    private static func shiftReferences(_ text: String, rows: Int, columns: Int) -> String {
        let ns = text as NSString
        var out = "", last = 0
        for match in reference.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let columnAbsolute = !ns.substring(with: match.range(at: 1)).isEmpty
            let rowAbsolute = !ns.substring(with: match.range(at: 3)).isEmpty
            let columnName = ns.substring(with: match.range(at: 2))
            let row = Int(ns.substring(with: match.range(at: 4))) ?? 1
            var column = 0
            for scalar in columnName.unicodeScalars { column = column * 26 + Int(scalar.value - 64) }
            let newColumn = columnAbsolute ? column : column + columns
            let newRow = rowAbsolute ? row : row + rows
            if newColumn < 1 || newColumn > 16_384 || newRow < 1 || newRow > 1_048_576 {
                out += "#REF!"
            } else {
                out += (columnAbsolute ? "$" : "") + XLSXWriter.columnName(newColumn - 1) + (rowAbsolute ? "$" : "") + "\(newRow)"
            }
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }
}
