import CoreGraphics
import CoreText
import Foundation

// The typeset material between composition and the PDF: TeX-like boxes in TeX points. Inside a box, x runs right from
// the box's left edge and y runs up from its baseline.

/// What the PDF's structure tree calls an element (tagged PDF, quality §3.7).
enum TagKind: Hashable, Sendable {
    case paragraph, heading(Int), list, listItem, table, tableRow, tableHeaderCell, tableCell
    case figure, formula, caption, blockQuote, code, note, tocItem, division
}

/// One element of the structure path a box belongs to; `id` keeps siblings apart.
struct TagNode: Hashable, Sendable {
    var kind: TagKind
    var id: Int
    var actualText: String? = nil
    var alt: String? = nil
}

/// Something drawn at a position inside a box.
enum DrawOp {
    /// Text set with Core Text at (x, y): one word or word part, kerned and ligatured by the font.
    case text(NSAttributedString, x: Double, y: Double)
    /// Glyphs at positions relative to the box origin (math).
    case glyphs(CTFont, [CGGlyph], [CGPoint], colour: CGColor?)
    /// A filled rectangle; y is its bottom edge.
    case rule(x: Double, y: Double, width: Double, height: Double, colour: CGColor?)
    case image(ImageContent, x: Double, y: Double, width: Double, height: Double)
    case link(String, x: Double, y: Double, width: Double, height: Double)
    case internalLink(String, x: Double, y: Double, width: Double, height: Double)
    case anchor(String, x: Double, y: Double)
    /// Ops inside a structure element of their own (a formula with its TeX as /ActualText, a table cell).
    case tagged(TagNode, [DrawOp])
    case box(HBox, x: Double, y: Double)
}

/// A picture to draw: raster (passed through when JPEG) or a PDF page (vector).
enum ImageContent {
    case raster(CGImage)
    case pdf(CGPDFPage)
}

/// A horizontal box: a line of a paragraph, a table row, a formula.
struct HBox {
    var width: Double
    var height: Double
    var depth: Double
    var ops: [DrawOp]

    static let empty = HBox(width: 0, height: 0, depth: 0, ops: [])
}

/// What the typographic lint (quality §3.7) needs to know about a paragraph line.
struct LineInfo: Sendable {
    var badness: Int
    var hyphenated: Bool
    var emergency: Bool
    /// How far the set line reaches past the measure (protrusion excepted); > 0.1 pt is overfull.
    var overfull: Double
    var paragraph: Int
    var lineInParagraph: Int
    var linesInParagraph: Int
    var text: String
}

/// A box on the vertical list: its content, where it sits horizontally, and what it carries along.
struct VBox {
    var box: HBox
    /// Offset of the box's left edge from the column's left edge.
    var x: Double = 0
    var tags: [TagNode] = []
    /// Footnotes whose marks are on this line, by number; they go to the page the line lands on.
    var footnotes: [Int] = []
    var line: LineInfo? = nil
    /// Set on a heading's lines, so the lint can check no heading ends a page.
    var isHeading = false
    /// Body rows of a table that may break across pages: a page that starts with one repeats the table's header.
    var tableID: Int? = nil
}

/// A float (figure, captioned table): placed at the top of this or a later page (`[tbp]`).
struct FloatBlock {
    var items: [VItem]
    var height: Double
}

/// A heading's mark: bookmarks, the contents page and running heads read these.
struct HeadingMark {
    var level: Int
    var title: String
    var number: String?
    var anchor: String
    var inContents: Bool
}

/// Items of a vertical list (TeX's main vertical list), in TeX points.
enum VItem {
    case box(VBox)
    case glue(Glue)
    case kern(Double)
    case penalty(Int)
    case float(FloatBlock)
    case mark(HeadingMark)
    /// `\clearpage`: ends the page and flushes pending floats.
    case clearPage
    /// A chapter (book class) starts a new page; its title feeds the running heads.
    case chapterStart(String?)

    var isDiscardable: Bool {
        switch self {
        case .glue, .kern, .penalty: true
        default: false
        }
    }
}
