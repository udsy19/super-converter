import Foundation

/// What LayoutKit finds on PDF pages: words, lines, paragraphs, columns, headings, lists, tables, figures and a reading
/// order (formats §3.2). Boxes are in points, y up, origin at the page's lower left.
public struct LayoutDocument: Hashable, Codable, Sendable {
    public var pages: [LayoutPage]
    public init(pages: [LayoutPage]) { self.pages = pages }
}

public struct LayoutBox: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct LayoutPage: Hashable, Codable, Sendable {
    public var size: VectorSize
    /// Blocks in reading order.
    public var blocks: [LayoutBlock]
    /// True when the text came from recognition rather than the PDF's own text.
    public var isRecognised: Bool
    public init(size: VectorSize, blocks: [LayoutBlock], isRecognised: Bool = false) {
        self.size = size; self.blocks = blocks; self.isRecognised = isRecognised
    }
}

public struct LayoutWord: Hashable, Codable, Sendable {
    public var text: String
    public var box: LayoutBox
    public var fontName: String
    public var fontSize: Double
    public var isBold: Bool
    public var isItalic: Bool
    public init(text: String, box: LayoutBox, fontName: String, fontSize: Double, isBold: Bool = false, isItalic: Bool = false) {
        self.text = text; self.box = box; self.fontName = fontName; self.fontSize = fontSize
        self.isBold = isBold; self.isItalic = isItalic
    }
}

public struct LayoutLine: Hashable, Codable, Sendable {
    public var words: [LayoutWord]
    public var box: LayoutBox
    public init(words: [LayoutWord], box: LayoutBox) { self.words = words; self.box = box }
}

public indirect enum LayoutBlock: Hashable, Codable, Sendable {
    case paragraph([LayoutLine], column: Int)
    case heading(level: Int, [LayoutLine])
    case listItem(marker: String, [LayoutLine])
    case table(rows: [[[LayoutLine]]], box: LayoutBox)
    case figure(box: LayoutBox, image: ImageAsset?)
    case header([LayoutLine])
    case footer([LayoutLine])
}
