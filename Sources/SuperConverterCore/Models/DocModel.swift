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

    /// The date as a title block shows it, written out in the document's language ("March 14, 2024", "14. März 2024").
    public var longDate: String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: language ?? "en_US")
        f.setLocalizedDateFormatFromTemplate("MMMMdyyyy")
        return f.string(from: date)
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

// MARK: - Headings as the LaTeX look reads them

/// How the LaTeX look turns a document's headings into LaTeX's title and sections (quality §3.1, §3.2). TypesetKit and
/// DocKit's `LaTeXWriter` both read the document this way, so TypesetKit's PDF and TeX's run on the LaTeX of the same
/// document set the same title block and sections (the parity test, quality §3.7).
extension DocModel {
    /// The document with its opening heading as `metadata.title`, when that heading is the only one at its level and more
    /// headings follow — Markdown's "# Title" over "##" sections, which the LaTeX look sets as the title block
    /// (`\maketitle`), not as a section. A different title already in the metadata keeps the heading.
    public func liftingOpeningTitle() -> DocModel {
        guard let index = blocks.firstIndex(where: { if case .footnote = $0 { return false }; return true }),
              case .heading(let level, let text) = blocks[index] else { return self }
        let levels = Self.headingLevels(blocks)
        guard levels.count > 1, levels.filter({ $0 == level }).count == 1, metadata.title == nil || metadata.title == text.plainText else { return self }
        var lifted = self
        lifted.metadata.title = text.plainText
        lifted.blocks.remove(at: index)
        return lifted
    }

    /// The heading level set as `\section` (`\chapter` in a book): the shallowest one.
    public var sectionLevel: Int { Self.headingLevels(blocks).min() ?? 1 }

    /// "Numbered sections: auto" numbers three or more sections, unless the source numbers its own headings
    /// ("1. Introduction", "II. Methods").
    public var numbersSectionsByDefault: Bool {
        let pattern = try! NSRegularExpression(pattern: "^\\s*([0-9]+(\\.[0-9]+)*\\.?|[IVXLC]+\\.|[A-Z]\\.)\\s")
        let numbered = blocks.contains { b in
            guard case .heading(_, let t) = b else { return false }
            let s = t.plainText
            return pattern.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
        return !numbered && Self.headingLevels(blocks).filter { $0 == sectionLevel }.count >= 3
    }

    static func headingLevels(_ blocks: [DocBlock]) -> [Int] {
        blocks.compactMap { if case .heading(let l, _) = $0 { return l }; return nil }
    }
}

extension Array where Element == DocInline {
    /// The words as a reader sees them: code and math as their source, pictures and footnote marks left out.
    public var plainText: String {
        var s = ""
        for n in self {
            switch n {
            case .text(let x), .code(let x), .math(let x): s += x
            case .emphasis(let i), .strong(let i), .strike(let i), .link(let i, _), .styled(let i, _): s += i.plainText
            case .lineBreak: s += " "
            case .image, .footnoteReference: break
            }
        }
        return s
    }
}
