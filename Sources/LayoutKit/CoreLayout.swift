import CoreGraphics
import Foundation
import SuperConverterCore

/// The analysis → Core's `LayoutDocument` (formats §3.2): boxes are in the displayed page, points, y up.
enum CoreLayout {
    static func document(_ analysis: PDFAnalysis) throws -> LayoutDocument {
        let pictures = analysis.pages.contains { !$0.figures.isEmpty } ? try PagePictures(url: analysis.url, password: analysis.password) : nil
        return LayoutDocument(pages: analysis.pages.map { page(analysisPage: $0, pictures: pictures) })
    }

    static func page(analysisPage page: AnalysedPage, pictures: PagePictures?) -> LayoutPage {
        func box(_ rect: CGRect) -> LayoutBox {
            let r = Geometry.displayed(rect, in: page)
            return LayoutBox(x: r.minX, y: r.minY, width: r.width, height: r.height)
        }
        func line(_ line: PageLine) -> LayoutLine {
            LayoutLine(words: line.words.map(word), box: box(line.bounds))
        }
        func word(_ w: PageWord) -> LayoutWord {
            LayoutWord(text: w.text, box: box(w.bounds), fontName: w.fontName ?? "", fontSize: w.fontSize, isBold: w.isBold, isItalic: w.isItalic)
        }
        var blocks: [LayoutBlock] = []
        for element in page.readingOrder {
            switch element {
            case .block(let id):
                guard let b = page.blocks.first(where: { $0.id == id }) else { continue }
                let lines = b.lines.map(line)
                switch b.kind {
                case .paragraph, .caption: blocks.append(.paragraph(lines, column: b.column))
                case .heading(let level): blocks.append(.heading(level: level, lines))
                case .listItem(_, let marker): blocks.append(.listItem(marker: marker, lines))
                case .header: blocks.append(.header(lines))
                case .footer, .pageNumber: blocks.append(.footer(lines))
                }
            case .table(let id):
                guard let t = page.tables.first(where: { $0.id == id }) else { continue }
                var rows = [[[LayoutLine]]](repeating: [[LayoutLine]](repeating: [], count: t.columnCount), count: t.rowCount)
                for cell in t.cells where cell.row < t.rowCount && cell.column < t.columnCount {
                    rows[cell.row][cell.column] = LineBuilder.baselineRows(cell.words).map { line($0.layoutLine) }
                }
                blocks.append(.table(rows: rows, box: box(t.bounds)))
            case .figure(let id):
                guard let f = page.figures.first(where: { $0.id == id }) else { continue }
                let image = pictures?.crop(f.bounds, of: page, dpi: 150, maxSide: 2000).flatMap { ImageFrame(cgImage: $0) }
                blocks.append(.figure(box: box(f.bounds), image: image.map { ImageAsset(frames: [$0]) }))
            }
        }
        let size = Geometry.displayedSize(page)
        return LayoutPage(size: VectorSize(width: size.width, height: size.height), blocks: blocks, isRecognised: page.origin == .recognized)
    }
}
