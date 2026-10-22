import Foundation

/// Spreadsheets as a workbook (formats §3.2): sheets, cells, number formats, merged cells, widths, styles. Formulas are
/// kept as text with their cached values. OfficeKit's readers and writers share it.
public struct Workbook: Hashable, Codable, Sendable {
    public var sheets: [Sheet]
    public var title: String?
    public init(sheets: [Sheet], title: String? = nil) { self.sheets = sheets; self.title = title }
}

public enum CellValue: Hashable, Codable, Sendable {
    case empty
    case number(Double)
    case text(String)
    case bool(Bool)
    case date(Date)
    case error(String)
}

public struct Cell: Hashable, Codable, Sendable {
    public var value: CellValue
    /// The formula without "=", when the cell has one; `value` is its cached result.
    public var formula: String?
    /// The number format code as the source wrote it ("0.00", "yyyy-mm-dd").
    public var numberFormat: String?
    /// The text as the source displayed it, when it differs from `value` (formatted numbers).
    public var displayText: String?
    public var style: CellStyle
    public init(value: CellValue = .empty, formula: String? = nil, numberFormat: String? = nil, displayText: String? = nil,
                style: CellStyle = CellStyle()) {
        self.value = value; self.formula = formula; self.numberFormat = numberFormat; self.displayText = displayText; self.style = style
    }
}

public struct CellStyle: Hashable, Codable, Sendable {
    public var bold = false
    public var italic = false
    public var fontName: String?
    public var fontSize: Double?
    /// "#RRGGBB".
    public var textColour: String?
    public var fillColour: String?
    public var alignment: DocParagraphStyle.Alignment?
    public var wrapsText = false
    public init() {}
}

public struct CellRange: Hashable, Codable, Sendable {
    public var firstRow: Int, firstColumn: Int, lastRow: Int, lastColumn: Int
    public init(firstRow: Int, firstColumn: Int, lastRow: Int, lastColumn: Int) {
        self.firstRow = firstRow; self.firstColumn = firstColumn; self.lastRow = lastRow; self.lastColumn = lastColumn
    }
}

public struct Sheet: Hashable, Codable, Sendable {
    public var name: String
    /// Rows of cells, zero-based; short rows are padded by readers' consumers.
    public var rows: [[Cell]]
    public var merges: [CellRange]
    /// Column widths in characters, by column index.
    public var columnWidths: [Int: Double]
    public var printArea: CellRange?
    public var isHidden: Bool
    public init(name: String, rows: [[Cell]] = [], merges: [CellRange] = [], columnWidths: [Int: Double] = [:],
                printArea: CellRange? = nil, isHidden: Bool = false) {
        self.name = name; self.rows = rows; self.merges = merges; self.columnWidths = columnWidths
        self.printArea = printArea; self.isHidden = isHidden
    }
}
