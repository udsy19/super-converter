import Foundation
import SuperConverterCore

/// PDF analysis → `Workbook` (formats §5 O-PDF-SHEET): a sheet per table (or all tables on one sheet), numbers stored as
/// numbers with a matching number format, header rows bold; a file without tables puts all its text on one sheet (lines → rows,
/// words split into cells at wide gaps). Adapted from Super PDF's `SpreadsheetWriter`; OfficeKit writes the XLSX.
enum WorkbookBuilder {
    static func build(_ analysis: PDFAnalysis, options: OptionValues) -> Workbook {
        let singleSheet = options["singleSheet"]?.bool ?? false
        let withText = options["nonTableContent"]?.bool ?? false
        let tables = analysis.pages.flatMap { page in page.tables.map { (page, $0) } }
        var sheets: [Sheet] = []
        if tables.isEmpty {
            var rows: [[Cell]] = []
            for page in analysis.pages {
                if !rows.isEmpty { rows.append([]) }
                rows += textRows(page)
            }
            sheets.append(Sheet(name: "Text", rows: rows, columnWidths: widths(rows)))
        } else if singleSheet {
            var sheet = Sheet(name: "Sheet1")
            for (_, table) in tables {
                if !sheet.rows.isEmpty { sheet.rows.append([]) }
                append(table, to: &sheet)
            }
            if withText { sheets.append(Sheet(name: "Text", rows: analysis.pages.flatMap(textRows))) }
            sheet.columnWidths = widths(sheet.rows)
            sheets.insert(sheet, at: 0)
        } else {
            for (n, (_, table)) in tables.enumerated() {
                var sheet = Sheet(name: "Table \(n + 1)")
                append(table, to: &sheet)
                sheet.columnWidths = widths(sheet.rows)
                sheets.append(sheet)
            }
            if withText { sheets.append(Sheet(name: "Text", rows: analysis.pages.flatMap(textRows))) }
        }
        return Workbook(sheets: uniqueNames(sheets), title: analysis.title)
    }

    // MARK: Tables

    static func append(_ table: PageTable, to sheet: inout Sheet) {
        let top = sheet.rows.count
        let width = max(table.columnCount, 1)
        sheet.rows += [[Cell]](repeating: [Cell](repeating: Cell(), count: width), count: max(table.rowCount, 1))
        for cell in table.cells where cell.row < table.rowCount && cell.column < width {
            var value = cellValue(cell.text.replacingOccurrences(of: "\n", with: " "))
            if table.hasHeaderRow && cell.row == 0 { value.style.bold = true }
            sheet.rows[top + cell.row][cell.column] = value
            if cell.rowSpan > 1 || cell.columnSpan > 1 {
                sheet.merges.append(CellRange(firstRow: top + cell.row, firstColumn: cell.column,
                                              lastRow: top + min(cell.row + cell.rowSpan, table.rowCount) - 1,
                                              lastColumn: min(cell.column + cell.columnSpan, width) - 1))
            }
        }
    }

    static func cellValue(_ text: String) -> Cell {
        guard !text.isEmpty else { return Cell() }
        if let number = Number.parse(text) {
            return Cell(value: .number(number.value), numberFormat: number.format, displayText: text)
        }
        return Cell(value: .text(text))
    }

    /// A page's text as rows: each line a row, its words split into cells where the gap is wider than the font size.
    static func textRows(_ page: AnalysedPage) -> [[Cell]] {
        var rows: [[Cell]] = []
        for element in page.readingOrder {
            guard case .block(let id) = element, let block = page.blocks.first(where: { $0.id == id }) else { continue }
            for line in block.lines {
                var cells: [String] = []
                var previous: PageWord?
                for word in line.words {
                    if let previous, word.bounds.minX - previous.bounds.maxX <= max(CGFloat(word.fontSize), CGFloat(previous.fontSize), 4), !cells.isEmpty {
                        cells[cells.count - 1] += " " + word.text
                    } else {
                        cells.append(word.text)
                    }
                    previous = word
                }
                if !cells.isEmpty { rows.append(cells.map(cellValue)) }
            }
        }
        return rows
    }

    static func widths(_ rows: [[Cell]]) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for row in rows {
            for (c, cell) in row.enumerated() {
                let length = Double((cell.displayText ?? { if case .text(let t) = cell.value { t } else { "" } }()).count)
                result[c] = min(max(result[c] ?? 8, length * 1.1 + 2), 60)
            }
        }
        return result
    }

    /// Excel's sheet-name rules: no []:*?/\, at most 31 characters, not empty, unique without regard to case.
    static func uniqueNames(_ sheets: [Sheet]) -> [Sheet] {
        var used: Set<String> = []
        return sheets.map { sheet in
            var sheet = sheet
            var base = String(sheet.name.filter { !"[]:*?/\\".contains($0) }.trimmingCharacters(in: CharacterSet(charactersIn: "' ")).prefix(31))
            if base.isEmpty { base = "Sheet" }
            var name = base
            var n = 2
            while used.contains(name.lowercased()) {
                let suffix = " \(n)"
                name = String(base.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(name.lowercased())
            sheet.name = name
            return sheet
        }
    }

    /// Numbers as printed ("1,234.50", "(12)", "$9.99", "12%", "12,5") → the value and an Excel number format that prints it
    /// the same way; nil for text (including codes with leading zeros, phone numbers and over-long digit runs).
    /// Adapted from Super PDF's `OfficeNumber`.
    enum Number {
        struct Parsed: Equatable { var value: Double; var format: String? }

        static func parse(_ text: String) -> Parsed? {
            var s = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{2212}", with: "-")
                .replacingOccurrences(of: "\u{00A0}", with: "").replacingOccurrences(of: "\u{202F}", with: "")
            guard !s.isEmpty, s.count <= 32 else { return nil }
            var negative = false, parentheses = false, percent = false
            var currency: (symbol: String, before: Bool)?
            if s.hasPrefix("("), s.hasSuffix(")") { parentheses = true; negative = true; s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces) }
            if s.hasSuffix("%") { percent = true; s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
            if s.hasPrefix("-") { negative.toggle(); s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
            for symbol in ["$", "€", "£", "¥", "₹"] {
                if s.hasPrefix(symbol) { currency = (symbol, true); s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces); break }
                if s.hasSuffix(symbol) { currency = (symbol, false); s = String(s.dropLast()).trimmingCharacters(in: .whitespaces); break }
            }
            if s.hasPrefix("-") { negative.toggle(); s = String(s.dropFirst()) }
            guard let first = s.first, first.isNumber || first == "." else { return nil }

            var thousands = false
            var normalized: String
            if s.range(of: #"^\d{1,3}(,\d{3})+(\.\d+)?$"#, options: .regularExpression) != nil {
                thousands = true; normalized = s.replacingOccurrences(of: ",", with: "")
            } else if s.range(of: #"^\d{1,3}(\.\d{3})+(,\d+)?$"#, options: .regularExpression) != nil {
                thousands = true; normalized = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else if s.range(of: #"^\d+,\d{1,2}$"#, options: .regularExpression) != nil {
                normalized = s.replacingOccurrences(of: ",", with: ".")
            } else if s.range(of: #"^(\d+(\.\d*)?|\.\d+)$"#, options: .regularExpression) != nil {
                normalized = s
            } else {
                return nil
            }
            let integerPart = normalized.split(separator: ".", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if integerPart.count > 1, integerPart.hasPrefix("0") { return nil }
            guard normalized.filter(\.isNumber).count <= 15, var value = Double(normalized) else { return nil }
            let decimals = normalized.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
            if negative { value = -value }
            if percent { value /= 100 }

            guard thousands || decimals > 0 || percent || currency != nil || parentheses else { return Parsed(value: value, format: nil) }
            var body = (thousands ? "#,##0" : "0") + (decimals > 0 ? "." + String(repeating: "0", count: decimals) : "")
            if percent { body += "%" }
            if let currency {
                let quoted = "\"\(currency.symbol)\""
                body = currency.before ? quoted + body : body + quoted
            }
            return Parsed(value: value, format: parentheses ? "\(body);(\(body))" : body)
        }
    }
}
