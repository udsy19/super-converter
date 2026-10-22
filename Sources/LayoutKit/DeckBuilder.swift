import CoreGraphics
import Foundation
import SuperConverterCore

/// PDF analysis → `Deck` (formats §6): one slide per page at the page's size, every text block an editable text shape where it
/// sat, tables as table shapes, figures as pictures. Shape boxes follow Deck's convention (origin top-left, y down), so the
/// analysis' y-up boxes are flipped here. Adapted from Super PDF's `PresentationWriter`; OfficeKit writes the PPTX.
struct DeckBuilder {
    let analysis: PDFAnalysis
    let options: OptionValues
    var lossNotes: [LossNote] = []

    init(analysis: PDFAnalysis, options: OptionValues) { self.analysis = analysis; self.options = options }

    /// PowerPoint's slide size limit is 56 inches a side.
    static let maxSide: CGFloat = 4032

    mutating func build() throws -> Deck {
        let first = analysis.pages.first.map(Geometry.displayedSize) ?? CGSize(width: 720, height: 540)
        let scale = min(1, Self.maxSide / max(first.width, first.height))
        let size = CGSize(width: max(first.width * scale, 72), height: max(first.height * scale, 72))
        let pictures = analysis.pages.contains { !$0.figures.isEmpty } ? try PagePictures(url: analysis.url, password: analysis.password) : nil
        var builder = BuildOptions(options)
        builder.visualAppearance = true   // text boxes keep the page's line breaks
        let doc = try DocModelBuilder(analysis: analysis, options: builder)
        var slides: [Slide] = []
        var drewVectors = false
        for page in analysis.pages {
            let shown = Geometry.displayedSize(page)
            let fit = min(size.width / max(shown.width, 1), size.height / max(shown.height, 1))
            let offset = CGPoint(x: (size.width - shown.width * fit) / 2, y: (size.height - shown.height * fit) / 2)
            func box(_ rect: CGRect) -> LayoutBox {
                let r = Geometry.displayed(rect, in: page)
                return LayoutBox(x: offset.x + r.minX * fit, y: offset.y + (shown.height - r.maxY) * fit, width: r.width * fit, height: r.height * fit)
            }
            var shapes: [SlideShape] = []
            var title: (level: Int, text: String)?
            for element in page.readingOrder {
                switch element {
                case .block(let id):
                    guard let block = page.blocks.first(where: { $0.id == id }) else { continue }
                    let content = doc.blocks(for: block, on: page)
                    guard !content.isEmpty else { continue }
                    if case .heading(let level) = block.kind, level < (title?.level ?? Int.max) {
                        title = (level, block.lines.map(\.text).joined(separator: " "))
                    }
                    shapes.append(SlideShape(box: box(block.bounds), content: .text(content)))
                case .table(let id):
                    guard let table = page.tables.first(where: { $0.id == id }) else { continue }
                    shapes.append(SlideShape(box: box(table.bounds), content: .text([.table(doc.docTable(table))])))
                case .figure(let id):
                    guard let figure = page.figures.first(where: { $0.id == id }),
                          let image = pictures?.crop(figure.bounds, of: page, dpi: 160).flatMap({ ImageFrame(cgImage: $0) }) else { continue }
                    if figure.kind == .vector { drewVectors = true }
                    shapes.append(SlideShape(box: box(figure.bounds), content: .picture(ImageAsset(frames: [image]))))
                }
            }
            slides.append(Slide(title: title?.text, shapes: shapes))
        }
        if drewVectors { lossNotes.append(LossNote(.otherLoss, detail: "Drawings were placed as pictures")) }
        return Deck(size: VectorSize(width: size.width, height: size.height), slides: slides)
    }
}

extension DocModelBuilder {
    /// A single block as slide content: a list item is a one-item list, everything else as in the document.
    func blocks(for block: PageBlock, on page: AnalysedPage) -> [DocBlock] {
        let text = inline(block.lines)
        guard !text.isEmpty else { return [] }
        switch block.kind {
        case .heading(let level): return [.heading(level: level, text)]
        case .listItem(_, let marker): return Self.lists([(0, marker, text)])
        case .paragraph, .caption: return [.paragraph(text, style(block, page: page))]
        case .header, .footer, .pageNumber: return []
        }
    }
}
