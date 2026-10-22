// Adapted from Super PDF Sources/LayoutKit/PageInput.swift (commit 058469b): analysis types renamed (Page*) so they don't collide with Core's
// LayoutDocument model, made internal, SuperPDFCore removed.
import CoreGraphics
import Foundation

// What one page hands the analyser: positioned words (PDFKit or OCR) plus the page's drawing (ruling lines, images,
// vector clusters). Pure values, so the analysis runs off the main actor and fixtures can be built by hand.

/// A thin horizontal or vertical stroke or filled rectangle: a table ruling, an underline or a separator.
struct Ruling: Hashable, Sendable {
    var bounds: CGRect
    var isHorizontal: Bool

    init(bounds: CGRect, isHorizontal: Bool) { self.bounds = bounds; self.isHorizontal = isHorizontal }

    /// The ruling's fixed coordinate (y for horizontal, x for vertical).
    var position: CGFloat { isHorizontal ? bounds.midY : bounds.midX }
    /// The ruling's extent along its direction.
    var span: ClosedRange<CGFloat> { isHorizontal ? bounds.minX...bounds.maxX : bounds.minY...bounds.maxY }
}

/// The page's drawing, as `PageGraphicsScanner` reads it from the content stream.
struct PageGraphics: Hashable, Sendable {
    var rulings: [Ruling]
    /// Placed image XObjects (and inline images), page space.
    var images: [CGRect]
    /// Bounding boxes of filled or stroked paths that are not rulings.
    var vectors: [CGRect]

    init(rulings: [Ruling] = [], images: [CGRect] = [], vectors: [CGRect] = []) {
        self.rulings = rulings; self.images = images; self.vectors = vectors
    }

    static let empty = PageGraphics()
}

/// One page's input to `LayoutAnalyzer`.
struct PageInput: Hashable, Sendable {
    var index: Int
    /// Crop box size, unrotated.
    var size: CGSize
    var rotation: Int
    var origin: TextOrigin
    var words: [PageWord]
    var graphics: PageGraphics

    init(index: Int, size: CGSize, rotation: Int = 0, origin: TextOrigin = .embedded, words: [PageWord], graphics: PageGraphics = .empty) {
        self.index = index; self.size = size; self.rotation = rotation; self.origin = origin; self.words = words; self.graphics = graphics
    }
}
