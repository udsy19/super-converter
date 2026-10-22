import Foundation

/// The semantic document hub (formats §3.2): headings, paragraphs with inline styles, lists, tables, figures, footnotes,
/// math, code, quotes, page breaks and metadata. DocKit's readers produce it, its writers and TypesetKit consume it.
public struct DocModel: Hashable, Codable, Sendable {
    public var metadata: DocMetadata
    public var blocks: [DocBlock]
    /// Pictures and other embedded parts by name (referenced from `DocInline.image`).
    public var resources: [String: Data]

    public init(metadata: DocMetadata = DocMetadata(), blocks: [DocBlock] = [], resources: [String: Data] = [:]) {
        self.metadata = metadata; self.blocks = blocks; self.resources = resources
    }
}

public struct DocMetadata: Hashable, Codable, Sendable {
    public var title: String?
    public var authors: [String]
    public var language: String?
    public var date: Date?
    public var summary: String?
    /// The page setup the source declared (points); nil for flowing sources.
    public var pageSize: VectorSize?

    public init(title: String? = nil, authors: [String] = [], language: String? = nil, date: Date? = nil,
                summary: String? = nil, pageSize: VectorSize? = nil) {
        self.title = title; self.authors = authors; self.language = language; self.date = date
        self.summary = summary; self.pageSize = pageSize
    }
}

public indirect enum DocBlock: Hashable, Codable, Sendable {
    case heading(level: Int, DocText)
    case paragraph(DocText, DocParagraphStyle)
    case list(ordered: Bool, start: Int, items: [[DocBlock]])
    case table(DocTable)
    case figure(resource: String, caption: DocText?, altText: String?)
    case code(language: String?, text: String)
    case quote([DocBlock])
    case math(tex: String, display: Bool)
    case footnote(id: String, [DocBlock])
    case thematicBreak
    case pageBreak
}

public struct DocParagraphStyle: Hashable, Codable, Sendable {
    public enum Alignment: String, Codable, Sendable { case start, centre, end, justified }
    public var alignment: Alignment
    /// Source font name and size when "As written" should use them.
    public var fontName: String?
    public var fontSize: Double?
    public var spaceBefore: Double?
    public var spaceAfter: Double?
    public init(alignment: Alignment = .start, fontName: String? = nil, fontSize: Double? = nil,
                spaceBefore: Double? = nil, spaceAfter: Double? = nil) {
        self.alignment = alignment; self.fontName = fontName; self.fontSize = fontSize
        self.spaceBefore = spaceBefore; self.spaceAfter = spaceAfter
    }
}

public typealias DocText = [DocInline]

public indirect enum DocInline: Hashable, Codable, Sendable {
    case text(String)
    case emphasis(DocText)
    case strong(DocText)
    case strike(DocText)
    case code(String)
    case link(DocText, destination: String)
    case image(resource: String, altText: String?)
    case footnoteReference(id: String)
    case math(tex: String)
    case styled(DocText, DocRunStyle)
    case lineBreak
}

public struct DocRunStyle: Hashable, Codable, Sendable {
    public var fontName: String?
    public var fontSize: Double?
    /// "#RRGGBB".
    public var colour: String?
    public var underline: Bool
    public var superscript: Bool
    public var subscripted: Bool
    public init(fontName: String? = nil, fontSize: Double? = nil, colour: String? = nil, underline: Bool = false,
                superscript: Bool = false, subscripted: Bool = false) {
        self.fontName = fontName; self.fontSize = fontSize; self.colour = colour; self.underline = underline
        self.superscript = superscript; self.subscripted = subscripted
    }
}

public struct DocTable: Hashable, Codable, Sendable {
    public struct Cell: Hashable, Codable, Sendable {
        public var blocks: [DocBlock]
        public var columnSpan: Int
        public var rowSpan: Int
        public var isHeader: Bool
        public init(blocks: [DocBlock], columnSpan: Int = 1, rowSpan: Int = 1, isHeader: Bool = false) {
            self.blocks = blocks; self.columnSpan = columnSpan; self.rowSpan = rowSpan; self.isHeader = isHeader
        }
    }

    public var rows: [[Cell]]
    public var caption: DocText?
    /// Column alignments, one per column.
    public var alignments: [DocParagraphStyle.Alignment]
    public init(rows: [[Cell]], caption: DocText? = nil, alignments: [DocParagraphStyle.Alignment] = []) {
        self.rows = rows; self.caption = caption; self.alignments = alignments
    }
}
