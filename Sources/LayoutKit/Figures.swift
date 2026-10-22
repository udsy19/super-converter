// Adapted from Super PDF Sources/LayoutKit/Figures.swift (commit 058469b): analysis types renamed (Page*) so they don't collide with Core's
// LayoutDocument model, made internal, SuperPDFCore removed.
import CoreGraphics
import Foundation

// Figures: placed images and clusters of vector drawing (charts, logos, diagrams). Rulings that tables consumed and
// page-sized backgrounds are not figures.

enum FigureDetector {
    static func figures(from graphics: PageGraphics, tables: [CGRect], pageSize: CGSize) -> [PageFigure] {
        let pageArea = pageSize.width * pageSize.height
        var result: [PageFigure] = []
        func isBackground(_ rect: CGRect) -> Bool { rect.width * rect.height >= 0.9 * pageArea }
        func inTable(_ rect: CGRect) -> Bool { tables.contains { $0.insetBy(dx: -2, dy: -2).contains(rect) } }

        for image in graphics.images where image.width >= 4 && image.height >= 4 && !isBackground(image) && !inTable(image) {
            result.append(PageFigure(id: result.count, kind: .image, bounds: image.rounded))
        }

        // Vector clusters: paths within 6 pt of each other, big enough to be a drawing.
        let vectors = graphics.vectors.filter { !isBackground($0) && !inTable($0) }
        if !vectors.isEmpty {
            var sets = DisjointSets(count: vectors.count)
            for i in vectors.indices {
                for j in (i + 1)..<vectors.count where vectors[i].gap(to: vectors[j]) <= 6 { sets.union(i, j) }
            }
            for group in sets.groups() {
                let bounds = CGRect.union(group.map { vectors[$0] })
                guard bounds.width >= 12, bounds.height >= 12, bounds.width * bounds.height >= 400, !isBackground(bounds) else { continue }
                // Drawing inside a placed image (frames) belongs to it.
                if result.contains(where: { $0.bounds.insetBy(dx: -3, dy: -3).contains(bounds) }) { continue }
                result.append(PageFigure(id: result.count, kind: .vector, bounds: bounds.rounded))
            }
        }
        return result
    }
}
