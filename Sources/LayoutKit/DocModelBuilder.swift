import CoreGraphics
import Foundation
import NaturalLanguage
import SuperConverterCore

/// What the "PDF → editable" options mean for the builders (formats §5 O-PDF-OFFICE).
struct BuildOptions {
    /// Join words hyphenated at a line end.
    var connectHyphens = true
    /// Keep the page's line breaks and page breaks instead of reflowing.
    var visualAppearance = false

    init(_ options: OptionValues = OptionValues()) {
        connectHyphens = options["connectHyphens"]?.bool ?? true
        visualAppearance = options["visualAppearance"]?.bool ?? false
    }
}

/// PDF analysis → `DocModel` (quality §3.6): real headings, paragraphs with bold/italic runs, lists, tables and pictures in
/// reading order, running headers and footers left out. Adapted from Super PDF's `WordWriter` flow, producing the model
/// instead of OOXML (DocKit writes DOCX).
struct DocModelBuilder {
    let analysis: PDFAnalysis
    let options: BuildOptions
    private var pictures: PagePictures?
    private var resources: [String: Data] = [:]
    private var figureCount = 0

    init(analysis: PDFAnalysis, options: BuildOptions) throws {
        self.analysis = analysis; self.options = options
        if analysis.pages.contains(where: { !$0.figures.isEmpty }) { pictures = try PagePictures(url: analysis.url, password: analysis.password) }
    }

    mutating func build() -> DocModel {
        var blocks: [DocBlock] = []
        for (number, page) in analysis.pages.enumerated() {
            var pageBlocks = self.blocks(of: page)
            if number > 0 {
                if options.visualAppearance { blocks.append(.pageBreak) }
                else if let first = pageBlocks.first, Self.continues(blocks.last, with: first) {
                    if case .paragraph(let a, let style) = blocks.removeLast(), case .paragraph(let b, _) = pageBlocks.removeFirst() {
                        blocks.append(.paragraph(a + [.text(" ")] + b, style))
                    }
                }
            }
            blocks += pageBlocks
        }
        var metadata = DocMetadata(title: analysis.title, authors: analysis.authors)
        if let first = analysis.pages.first {
            let size = Geometry.displayedSize(first)
            metadata.pageSize = VectorSize(width: size.width, height: size.height)
        }
        let sample = String(blocks.prefix(40).map { Self.plain($0) }.joined(separator: " ").prefix(2000))
        metadata.language = NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue
        return DocModel(metadata: metadata, blocks: blocks, resources: resources)
    }

    // MARK: Page

    private mutating func blocks(of page: AnalysedPage) -> [DocBlock] {
        var result: [DocBlock] = []
        var pendingList: [(level: Int, marker: String, text: DocText)] = []
        func flushList() {
            if !pendingList.isEmpty { result += Self.lists(pendingList); pendingList = [] }
        }
        let captionIDs = Set(page.figures.compactMap(\.captionBlockID))
        for element in page.readingOrder {
            switch element {
            case .block(let id):
                guard let block = page.blocks.first(where: { $0.id == id }) else { continue }
                let text = inline(block.lines)
                switch block.kind {
                case .listItem(let level, let marker): pendingList.append((level, marker, text))
                case .heading(let level): flushList(); result.append(.heading(level: level, text))
                case .paragraph:
                    flushList(); result.append(.paragraph(text, style(block, page: page)))
                case .caption:
                    flushList()
                    if !captionIDs.contains(block.id) { result.append(.paragraph(text, style(block, page: page))) }
                case .header, .footer, .pageNumber: continue
                }
            case .table(let id):
                flushList()
                if let table = page.tables.first(where: { $0.id == id }) { result.append(.table(docTable(table))) }
            case .figure(let id):
                flushList()
                guard let figure = page.figures.first(where: { $0.id == id }), let name = addPicture(figure, page: page) else { continue }
                let caption = figure.captionBlockID.flatMap { cid in page.blocks.first { $0.id == cid } }.map { inline($0.lines) }
                result.append(.figure(resource: name, caption: caption, altText: nil))
            }
        }
        flushList()
        return result
    }

    private mutating func addPicture(_ figure: PageFigure, page: AnalysedPage) -> String? {
        guard let image = pictures?.crop(figure.bounds, of: page), let data = PagePictures.encode(image, jpeg: figure.kind == .image) else { return nil }
        figureCount += 1
        let name = "figure-\(figureCount).\(figure.kind == .image ? "jpg" : "png")"
        resources[name] = data
        return name
    }

    // MARK: Text

    /// The lines as inline runs: bold and italic kept, colours when not black, hyphenated line ends joined (or the line
    /// breaks kept when the look matters more).
    func inline(_ lines: [PageLine]) -> DocText {
        var out: DocText = []
        var hyphenJoin = false
        for (n, line) in lines.enumerated() {
            if n > 0 {
                if options.visualAppearance { out.append(.lineBreak) }
                else if !hyphenJoin { out.append(.text(" ")) }
            }
            hyphenJoin = false
            var words = line.words
            if !options.visualAppearance, options.connectHyphens, n + 1 < lines.count, let last = words.last, last.text.count > 1, last.text.hasSuffix("-"),
               let next = lines[n + 1].words.first?.text.first, next.isLowercase, last.text.dropLast().last?.isLetter == true {
                words[words.count - 1].text = String(last.text.dropLast()); hyphenJoin = true
            }
            var run: [PageWord] = []
            func flush() {
                guard let first = run.first else { return }
                var piece: DocText = [.text(run.map(\.text).joined(separator: " "))]
                if first.isItalic { piece = [.emphasis(piece)] }
                if first.isBold { piece = [.strong(piece)] }
                if let colour = first.color, colour != "#000000" { piece = [.styled(piece, DocRunStyle(colour: colour))] }
                out += piece
                run = []
            }
            for word in words {
                if let first = run.first, (first.isBold, first.isItalic, first.color) != (word.isBold, word.isItalic, word.color) {
                    flush(); out.append(.text(" "))
                }
                run.append(word)
            }
            flush()
        }
        return out
    }

    func style(_ block: PageBlock, page: AnalysedPage) -> DocParagraphStyle {
        let words = block.lines.flatMap(\.words)
        var weights: [String: Int] = [:]
        for word in words { weights[Self.cleanFont(word.fontName), default: 0] += word.text.count }
        let font = weights.max { $0.value < $1.value }?.key
        let size = words.isEmpty ? nil : Double(median(words.map { CGFloat($0.fontSize) }))
        return DocParagraphStyle(alignment: Self.alignment(block, page: page), fontName: font?.isEmpty == false ? font : nil, fontSize: size)
    }

    /// "ABCDEF+Helvetica-Bold" → "Helvetica-Bold".
    static func cleanFont(_ name: String?) -> String {
        guard let name else { return "" }
        if name.count > 7, name[name.index(name.startIndex, offsetBy: 6)] == "+", name.prefix(6).allSatisfy(\.isUppercase) { return String(name.dropFirst(7)) }
        return name
    }

    static func alignment(_ block: PageBlock, page: AnalysedPage) -> DocParagraphStyle.Alignment {
        let lines = block.lines
        guard let first = lines.first else { return .start }
        let size = max(CGFloat(first.words.first?.fontSize ?? 10), 1)
        if lines.count >= 2 {
            let lefts = lines.map(\.bounds.minX), rights = lines.map(\.bounds.maxX), mids = lines.map(\.bounds.midX)
            if lefts.max()! - lefts.min()! <= size * 0.3 {
                let body = rights.dropLast()
                if body.count >= 2, body.max()! - body.min()! <= size * 0.3, rights.last! <= body.min()! + 0.5 { return .justified }
                return .start
            }
            if mids.max()! - mids.min()! <= size * 0.6 { return .centre }
            if rights.max()! - rights.min()! <= size * 0.3 { return .end }
            return .start
        }
        let pageMid = page.size.width / 2
        let narrow = first.bounds.width < page.size.width * 0.8
        if narrow, abs(first.bounds.midX - pageMid) < size, first.bounds.minX > page.size.width * 0.15 { return .centre }
        return .start
    }

    // MARK: Lists and tables

    /// Items with their levels → nested lists; each run of equal ordered-ness at a level is one list.
    static func lists(_ items: [(level: Int, marker: String, text: DocText)]) -> [DocBlock] {
        var result: [DocBlock] = []
        var index = 0
        let base = items.map(\.level).min() ?? 0
        while index < items.count {
            let ordered = isOrdered(items[index].marker)
            var group: [[DocBlock]] = []
            let start = startNumber(items[index].marker)
            while index < items.count, items[index].level == base, isOrdered(items[index].marker) == ordered || group.isEmpty {
                var item: [DocBlock] = [.paragraph(items[index].text, DocParagraphStyle())]
                index += 1
                var nested: [(level: Int, marker: String, text: DocText)] = []
                while index < items.count, items[index].level > base { nested.append(items[index]); index += 1 }
                item += lists(nested)
                group.append(item)
                if index < items.count, items[index].level == base, isOrdered(items[index].marker) != ordered { break }
            }
            result.append(.list(ordered: ordered, start: start, items: group))
        }
        return result
    }

    static func isOrdered(_ marker: String) -> Bool { marker.rangeOfCharacter(from: .alphanumerics) != nil }

    static func startNumber(_ marker: String) -> Int {
        Int(marker.trimmingCharacters(in: CharacterSet(charactersIn: "().:]"))) ?? 1
    }

    func docTable(_ table: PageTable) -> DocTable {
        var covered = Set<[Int]>()
        var rows: [[DocTable.Cell]] = []
        var numeric = [Int](repeating: 0, count: table.columnCount), filled = [Int](repeating: 0, count: table.columnCount)
        for cell in table.cells where (cell.row > 0 || table.rowCount == 1) && cell.column < table.columnCount {
            if !cell.text.isEmpty { filled[cell.column] += 1; if TableDetector.isNumeric(cell.text) { numeric[cell.column] += 1 } }
        }
        for row in 0..<table.rowCount {
            var cells: [DocTable.Cell] = []
            let here = table.cells.filter { $0.row == row }.sorted { $0.column < $1.column }
            var column = 0
            while column < table.columnCount {
                if covered.contains([row, column]) { column += 1; continue }
                if let cell = here.first(where: { $0.column == column }) {
                    for r in row..<min(row + cell.rowSpan, table.rowCount) {
                        for c in column..<min(column + cell.columnSpan, table.columnCount) where (r, c) != (row, column) { covered.insert([r, c]) }
                    }
                    cells.append(DocTable.Cell(blocks: [.paragraph(inline(Self.cellLines(cell)), DocParagraphStyle())],
                                               columnSpan: cell.columnSpan, rowSpan: cell.rowSpan, isHeader: table.hasHeaderRow && row == 0))
                    column += max(cell.columnSpan, 1)
                } else {
                    cells.append(DocTable.Cell(blocks: [.paragraph([], DocParagraphStyle())], isHeader: table.hasHeaderRow && row == 0))
                    column += 1
                }
            }
            rows.append(cells)
        }
        let alignments = (0..<table.columnCount).map { filled[$0] > 0 && numeric[$0] * 2 >= filled[$0] ? DocParagraphStyle.Alignment.end : .start }
        return DocTable(rows: rows, alignments: alignments)
    }

    /// The cell's words as one line per baseline row.
    static func cellLines(_ cell: PageTableCell) -> [PageLine] {
        LineBuilder.baselineRows(cell.words).map(\.layoutLine)
    }

    // MARK: Joining paragraphs across pages

    /// A paragraph that stops mid-sentence at the end of a page and goes on in lower case on the next.
    static func continues(_ previous: DocBlock?, with next: DocBlock) -> Bool {
        guard case .paragraph(let a, _)? = previous, case .paragraph(let b, _) = next else { return false }
        guard let last = plain(a).last, let first = plain(b).first else { return false }
        return !".!?:;\"”’)".contains(last) && first.isLowercase
    }

    static func plain(_ block: DocBlock) -> String {
        switch block {
        case .paragraph(let t, _), .heading(_, let t): plain(t)
        case .list(_, _, let items): items.flatMap { $0.map(plain) }.joined(separator: " ")
        case .table(let table): table.rows.flatMap { $0.map { $0.blocks.map(plain).joined(separator: " ") } }.joined(separator: " ")
        case .quote(let inner): inner.map(plain).joined(separator: " ")
        default: ""
        }
    }

    static func plain(_ text: DocText) -> String {
        text.map { piece -> String in
            switch piece {
            case .text(let s), .code(let s): s
            case .emphasis(let t), .strong(let t), .strike(let t), .link(let t, _), .styled(let t, _): plain(t)
            case .lineBreak: "\n"
            default: ""
            }
        }.joined()
    }
}
