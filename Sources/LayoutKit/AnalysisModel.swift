// Adapted from Super PDF Sources/SuperPDFCore/Model/Layout.swift (commit 058469b): the analysis model LayoutKit works in. Internal and
// renamed (Page*); Core's LayoutDocument is the result (see CoreLayout.swift). Not Codable (no fixtures here).
import CoreGraphics
import Foundation

// The text and layout model LayoutKit produces (features §2.4) and Edit text, PDF → Word/Excel/PowerPoint/HTML/EPUB,
// Reflow, Compare, auto-tagging and form-field detection consume. Coordinates are page space: points, origin at the crop box's lower-left corner, y up, before the
// page's /Rotate is applied.

/// Where a page's text came from.
enum TextOrigin: String, Sendable {
    /// The PDF's own text (PDFKit character positions).
    case embedded
    /// Vision OCR of the rendered page.
    case recognized
}

/// One word with its position and style.
struct PageWord: Hashable, Sendable {
    var text: String
    var bounds: CGRect
    var fontName: String?
    var fontSize: Double
    var isBold: Bool
    var isItalic: Bool
    /// "#RRGGBB" fill colour, when known.
    var color: String?
    /// OCR confidence 0…1; 1 for embedded text.
    var confidence: Double

    init(text: String, bounds: CGRect, fontName: String? = nil, fontSize: Double = 0, isBold: Bool = false, isItalic: Bool = false,
                color: String? = nil, confidence: Double = 1) {
        self.text = text; self.bounds = bounds; self.fontName = fontName; self.fontSize = fontSize; self.isBold = isBold
        self.isItalic = isItalic; self.color = color; self.confidence = confidence
    }
}

struct PageLine: Hashable, Sendable {
    var words: [PageWord]
    var bounds: CGRect
    /// The baseline's y in page space.
    var baseline: Double

    init(words: [PageWord], bounds: CGRect, baseline: Double) {
        self.words = words; self.bounds = bounds; self.baseline = baseline
    }

    var text: String { words.map(\.text).joined(separator: " ") }
}

/// What a block of lines is.
enum PageBlockKind: Hashable, Sendable {
    case paragraph
    /// Level 1 is the largest heading on the document.
    case heading(level: Int)
    /// A list item at an indent level, with its bullet or number as printed ("•", "3.", "(b)").
    case listItem(level: Int, marker: String)
    case caption
    /// Running headers, footers and page numbers: excluded from the reading order.
    case header, footer, pageNumber
}

struct PageBlock: Hashable, Identifiable, Sendable {
    var id: Int
    var kind: PageBlockKind
    var bounds: CGRect
    var lines: [PageLine]
    /// 0-based column on the page.
    var column: Int

    init(id: Int, kind: PageBlockKind, bounds: CGRect, lines: [PageLine], column: Int = 0) {
        self.id = id; self.kind = kind; self.bounds = bounds; self.lines = lines; self.column = column
    }

    var text: String { lines.map(\.text).joined(separator: "\n") }
}

struct PageTableCell: Hashable, Sendable {
    var row: Int
    var column: Int
    var rowSpan: Int
    var columnSpan: Int
    var bounds: CGRect
    var text: String
    /// The words in the cell, for the positioned forms.
    var words: [PageWord]

    init(row: Int, column: Int, rowSpan: Int = 1, columnSpan: Int = 1, bounds: CGRect, text: String, words: [PageWord] = []) {
        self.row = row; self.column = column; self.rowSpan = rowSpan; self.columnSpan = columnSpan; self.bounds = bounds
        self.text = text; self.words = words
    }
}

/// A table found from ruling lines and alignment grids.
struct PageTable: Hashable, Identifiable, Sendable {
    var id: Int
    var bounds: CGRect
    var rowCount: Int
    var columnCount: Int
    var cells: [PageTableCell]
    /// The first row repeats as a header (and on later pages).
    var hasHeaderRow: Bool

    init(id: Int, bounds: CGRect, rowCount: Int, columnCount: Int, cells: [PageTableCell], hasHeaderRow: Bool = false) {
        self.id = id; self.bounds = bounds; self.rowCount = rowCount; self.columnCount = columnCount; self.cells = cells
        self.hasHeaderRow = hasHeaderRow
    }
}

/// An image XObject or a cluster of vector drawing.
struct PageFigure: Hashable, Identifiable, Sendable {
    enum Kind: String, Sendable { case image, vector }

    var id: Int
    var kind: Kind
    var bounds: CGRect
    /// The caption block, when one sits next to it.
    var captionBlockID: Int?

    init(id: Int, kind: Kind, bounds: CGRect, captionBlockID: Int? = nil) {
        self.id = id; self.kind = kind; self.bounds = bounds; self.captionBlockID = captionBlockID
    }
}

/// One element in reading order.
enum PageElement: Hashable, Sendable {
    case block(Int)
    case table(Int)
    case figure(Int)
}

struct AnalysedPage: Hashable, Sendable {
    /// 0-based page index.
    var index: Int
    /// The crop box size.
    var size: CGSize
    /// The page's /Rotate (0, 90, 180, 270).
    var rotation: Int
    var origin: TextOrigin
    var blocks: [PageBlock]
    var tables: [PageTable]
    var figures: [PageFigure]
    /// Column-aware, top-left to bottom-right, headers and footers excluded.
    var readingOrder: [PageElement]

    init(index: Int, size: CGSize, rotation: Int = 0, origin: TextOrigin = .embedded, blocks: [PageBlock] = [],
                tables: [PageTable] = [], figures: [PageFigure] = [], readingOrder: [PageElement] = []) {
        self.index = index; self.size = size; self.rotation = rotation; self.origin = origin; self.blocks = blocks
        self.tables = tables; self.figures = figures; self.readingOrder = readingOrder
    }
}

/// When LayoutKit runs Vision on a page before analysing it (features §2.4: scanned pages go through Vision first).
enum RecognitionPolicy: String, Sendable {
    case never, whenPageHasNoText, always
}

struct AnalysisOptions: Hashable, Sendable {
    var recognition: RecognitionPolicy
    /// BCP-47 codes for OCR; empty means automatic.
    var languages: [String]
    var detectTables: Bool
    var excludeHeadersAndFooters: Bool

    init(recognition: RecognitionPolicy = .whenPageHasNoText, languages: [String] = [], detectTables: Bool = true,
                excludeHeadersAndFooters: Bool = true) {
        self.recognition = recognition; self.languages = languages; self.detectTables = detectTables
        self.excludeHeadersAndFooters = excludeHeadersAndFooters
    }
}

/// A line of OCR output (Vision `VNRecognizedTextObservation`, already in page space), the input LayoutKit accepts
/// for scanned pages and FixKit writes as the invisible text layer.
struct RecognizedLine: Hashable, Sendable {
    var text: String
    var bounds: CGRect
    var confidence: Double
    /// Per-word boxes, so selection and search land on the right word.
    var words: [PageWord]

    init(text: String, bounds: CGRect, confidence: Double, words: [PageWord] = []) {
        self.text = text; self.bounds = bounds; self.confidence = confidence; self.words = words
    }
}
