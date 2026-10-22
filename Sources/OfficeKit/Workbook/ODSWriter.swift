import Foundation
import SuperConverterCore

// ODS writer (formats §3.2): OpenDocument 1.3 spreadsheets from `Workbook` — typed values, formulas (OpenFormula text with
// cached results), number formats as data styles, fonts, fills, alignment, merges, column widths, hidden sheets and print
// ranges. Deterministic output (no dates).

enum ODSWriter {
    static let mimeType = "application/vnd.oasis.opendocument.spreadsheet"
    static let namespaces = """
        xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0" \
        xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:of="urn:oasis:names:tc:opendocument:xmlns:of:1.2" \
        xmlns:calcext="urn:org:documentfoundation:names:experimental:calc:xmlns:calcext:1.0"
        """

    /// Excel's column width in characters ↔ inches (7-pixel digits plus 5 pixels of padding at 96 dpi).
    static func inches(characters: Double) -> Double { (characters * 7 + 5) / 96 }
    static func characters(inches: Double) -> Double { ((inches * 96 - 5) / 7 * 10_000).rounded() / 10_000 }

    private struct CellKey: Hashable {
        var style: CellStyle
        var format: String?
    }

    static func write(_ workbook: Workbook, keepFormulas: Bool = true) -> Data {
        var dataStyles: [String: String] = [:]        // format code → style name
        var dataStyleXML: [String] = []
        var cellStyles: [CellKey: String] = [:]
        var cellStyleXML: [String] = []
        var columnStyles: [Double: String] = [:]
        var columnStyleXML: [String] = []
        var tableStyleXML: [String] = []

        func dataStyle(_ code: String?) -> String? {
            guard let code, code != "General" else { return nil }
            if let name = dataStyles[code] { return name }
            let name = "N\(dataStyles.count + 1)"
            guard let xml = ODFNumberStyles.element(code: code, name: name) else { return nil }
            dataStyles[code] = name
            dataStyleXML.append(xml)
            return name
        }
        func cellStyle(_ cell: Cell) -> String? {
            var code = cell.numberFormat
            if code == nil, case .date = cell.value { code = "yyyy-mm-dd" }
            let key = CellKey(style: cell.style, format: code)
            if key.style == CellStyle(), dataStyle(code) == nil { return nil }
            if let name = cellStyles[key] { return name }
            let name = "ce\(cellStyles.count + 1)"
            cellStyles[key] = name
            var attributes = "style:name=\"\(name)\" style:family=\"table-cell\" style:parent-style-name=\"Default\""
            if let data = dataStyle(code) { attributes += " style:data-style-name=\"\(data)\"" }
            var xml = "<style:style \(attributes)>"
            let s = cell.style
            var cellProperties = ""
            if let fill = s.fillColour.flatMap({ SheetRGB(hex: $0) }) { cellProperties += " fo:background-color=\"\(fill.hash)\"" }
            if s.wrapsText { cellProperties += " fo:wrap-option=\"wrap\"" }
            if !cellProperties.isEmpty { xml += "<style:table-cell-properties\(cellProperties)/>" }
            if let alignment = s.alignment {
                let value = ["start": "start", "centre": "center", "end": "end", "justified": "justify"][alignment.rawValue] ?? "start"
                xml += "<style:paragraph-properties fo:text-align=\"\(value)\"/>"
            }
            var text = ""
            if s.bold { text += " fo:font-weight=\"bold\"" }
            if s.italic { text += " fo:font-style=\"italic\"" }
            if let font = s.fontName { text += " style:font-name=\"\(XML.escape(font))\" fo:font-family=\"\(XML.escape(font))\"" }
            if let size = s.fontSize { text += " fo:font-size=\"\(size)pt\"" }
            if let colour = s.textColour.flatMap({ SheetRGB(hex: $0) }) { text += " fo:color=\"\(colour.hash)\"" }
            if !text.isEmpty { xml += "<style:text-properties\(text)/>" }
            cellStyleXML.append(xml + "</style:style>")
            return name
        }
        func columnStyle(_ width: Double) -> String {
            if let name = columnStyles[width] { return name }
            let name = "co\(columnStyles.count + 1)"
            columnStyles[width] = name
            columnStyleXML.append("<style:style style:name=\"\(name)\" style:family=\"table-column\"><style:table-column-properties "
                                  + "style:column-width=\"\(String(format: "%.6f", inches(characters: width)))in\" fo:break-before=\"auto\"/></style:style>")
            return name
        }

        let names = XLSXWriter.sheetNames(workbook.sheets.map(\.name))
        let sheets = workbook.sheets.isEmpty ? [Sheet(name: "Sheet1")] : workbook.sheets
        var body = ""
        for (index, sheet) in sheets.enumerated() {
            let width = max(sheet.rows.map(\.count).max() ?? 0, sheet.columnWidths.keys.max().map { $0 + 1 } ?? 0)
            var tableAttributes = "table:name=\"\(XML.escape(names[index]))\""
            if sheet.isHidden {
                let style = "ta\(tableStyleXML.count + 1)"
                tableStyleXML.append("<style:style style:name=\"\(style)\" style:family=\"table\"><style:table-properties table:display=\"false\"/></style:style>")
                tableAttributes += " table:style-name=\"\(style)\""
            }
            if let area = sheet.printArea {
                let quoted = names[index].contains(" ") ? "'\(names[index])'" : names[index]
                tableAttributes += " table:print-ranges=\"\(XML.escape("\(quoted).\(XLSXWriter.reference(row: area.firstRow, column: area.firstColumn)):\(quoted).\(XLSXWriter.reference(row: area.lastRow, column: area.lastColumn))"))\""
            }
            var xml = "<table:table \(tableAttributes)>"
            // Columns: runs of equal width share one element.
            var column = 0
            while column < width {
                let columnWidth = sheet.columnWidths[column]
                var end = column
                while end + 1 < width, sheet.columnWidths[end + 1] == columnWidth { end += 1 }
                let repeated = end - column + 1
                xml += "<table:table-column\(columnWidth.map { " table:style-name=\"\(columnStyle($0))\"" } ?? "")"
                    + "\(repeated > 1 ? " table:number-columns-repeated=\"\(repeated)\"" : "")/>"
                column = end + 1
            }
            var anchors: [Int: [Int: CellRange]] = [:]
            var covered: Set<[Int]> = []
            for merge in sheet.merges where merge.lastRow >= merge.firstRow && merge.lastColumn >= merge.firstColumn {
                anchors[merge.firstRow, default: [:]][merge.firstColumn] = merge
                for r in merge.firstRow...merge.lastRow { for c in merge.firstColumn...merge.lastColumn where (r, c) != (merge.firstRow, merge.firstColumn) { covered.insert([r, c]) } }
            }
            let rowCount = max(sheet.rows.count, (sheet.merges.map(\.lastRow).max() ?? -1) + 1)
            for r in 0..<rowCount {
                let row = r < sheet.rows.count ? sheet.rows[r] : []
                xml += "<table:table-row>"
                var emptyRun = 0
                func flushEmpty() {
                    if emptyRun > 0 { xml += "<table:table-cell\(emptyRun > 1 ? " table:number-columns-repeated=\"\(emptyRun)\"" : "")/>"; emptyRun = 0 }
                }
                for c in 0..<width {
                    if covered.contains([r, c]) { flushEmpty(); xml += "<table:covered-table-cell/>"; continue }
                    let cell = c < row.count ? row[c] : Cell()
                    let merge = anchors[r]?[c]
                    let style = cellStyle(cell)
                    if cell.value == .empty, cell.formula == nil || !keepFormulas, style == nil, merge == nil { emptyRun += 1; continue }
                    flushEmpty()
                    xml += self.cell(cell, style: style, merge: merge, keepFormulas: keepFormulas)
                }
                // Trailing empties need no cells.
                emptyRun = 0
                xml += "</table:table-row>"
            }
            body += xml + "</table:table>"
        }

        let content = """
            <office:document-content \(namespaces) office:version="1.3"><office:scripts/><office:font-face-decls/>\
            <office:automatic-styles>\(dataStyleXML.joined())\(columnStyleXML.joined())\(tableStyleXML.joined())\(cellStyleXML.joined())</office:automatic-styles>\
            <office:body><office:spreadsheet>\(body)</office:spreadsheet></office:body></office:document-content>
            """
        let styles = """
            <office:document-styles \(namespaces) office:version="1.3"><office:styles>\
            <style:default-style style:family="table-cell"><style:text-properties style:font-name="Calibri" fo:font-size="11pt"/></style:default-style>\
            <style:style style:name="Default" style:family="table-cell"/></office:styles></office:document-styles>
            """
        let meta = """
            <office:document-meta \(namespaces) office:version="1.3"><office:meta>\
            <meta:generator>\(XML.escape(Strings.appName))</meta:generator>\(workbook.title.map { "<dc:title>\(XML.escape($0))</dc:title>" } ?? "")\
            </office:meta></office:document-meta>
            """
        let manifest = """
            <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">\
            <manifest:file-entry manifest:full-path="/" manifest:version="1.3" manifest:media-type="\(mimeType)"/>\
            <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>\
            <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>\
            <manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/></manifest:manifest>
            """
        var zip = ZipWriter()
        zip.add("mimetype", Data(mimeType.utf8), compress: false)
        zip.add("META-INF/manifest.xml", OfficePackage.xmlHeader + manifest)
        zip.add("content.xml", OfficePackage.xmlHeader + content)
        zip.add("styles.xml", OfficePackage.xmlHeader + styles)
        zip.add("meta.xml", OfficePackage.xmlHeader + meta)
        return zip.finish()
    }

    // MARK: Cells

    private static func cell(_ cell: Cell, style: String?, merge: CellRange?, keepFormulas: Bool) -> String {
        var attributes = style.map { " table:style-name=\"\($0)\"" } ?? ""
        if let merge {
            if merge.lastColumn > merge.firstColumn { attributes += " table:number-columns-spanned=\"\(merge.lastColumn - merge.firstColumn + 1)\"" }
            if merge.lastRow > merge.firstRow { attributes += " table:number-rows-spanned=\"\(merge.lastRow - merge.firstRow + 1)\"" }
        }
        if keepFormulas, let formula = cell.formula { attributes += " table:formula=\"\(XML.escape(ODFFormula.toODF(formula)))\"" }
        var shown = cell.displayText
        switch cell.value {
        case .empty:
            return "<table:table-cell\(attributes)/>"
        case .number(let n):
            let isPercent = cell.numberFormat?.hasSuffix("%") ?? false
            attributes += " office:value-type=\"\(isPercent ? "percentage" : "float")\" office:value=\"\(n)\""
            shown = cell.shown
        case .text:
            attributes += " office:value-type=\"string\""
            shown = cell.shown
        case .bool(let b):
            attributes += " office:value-type=\"boolean\" office:boolean-value=\"\(b)\""
            shown = shown ?? (b ? "TRUE" : "FALSE")
        case .date(let d):
            let iso = CSVWriter.isoDate(d).replacingOccurrences(of: " ", with: "T")
            attributes += " office:value-type=\"date\" office:date-value=\"\(iso)\""
            shown = cell.shown
        case .error(let e):
            attributes += " office:value-type=\"string\" office:string-value=\"\" calcext:value-type=\"error\""
            shown = e
        }
        return "<table:table-cell\(attributes)>\(paragraphs(shown ?? ""))</table:table-cell>"
    }

    /// Text as `text:p` elements: a line break starts a paragraph, tabs and runs of spaces (and edge spaces) use their own
    /// elements because XML consumers collapse plain white space.
    static func paragraphs(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n").map { line in
            var out = "", spaces = 0
            func flush(atEnd: Bool) {
                guard spaces > 0 else { return }
                out += spaces == 1 && !out.isEmpty && !atEnd ? " " : "<text:s\(spaces > 1 ? " text:c=\"\(spaces)\"" : "")/>"
                spaces = 0
            }
            for ch in line {
                switch ch {
                case " ": spaces += 1
                case "\t": flush(atEnd: false); out += "<text:tab/>"
                default: flush(atEnd: false); out += XML.escape(String(ch))
                }
            }
            flush(atEnd: true)
            return "<text:p>\(out)</text:p>"
        }.joined()
    }
}
