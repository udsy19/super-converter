import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore

/// What a reader produced: the drawing and everything it could not carry over.
public struct VectorReadResult: Sendable {
    public var document: VectorDocument
    public var lossNotes: [LossNote]
    public var warnings: [String]
    public init(document: VectorDocument, lossNotes: [LossNote] = [], warnings: [String] = []) {
        self.document = document; self.lossNotes = lossNotes; self.warnings = warnings
    }
}

/// What a writer produced: the file's bytes and what it could not express.
public struct VectorWriteResult: Sendable {
    public var data: Data
    public var lossNotes: [LossNote]
    public init(data: Data, lossNotes: [LossNote] = []) { self.data = data; self.lossNotes = lossNotes }
}

/// The O-VEC options every writer understands (formats §5).
public struct VectorWriteOptions: Sendable {
    /// Text becomes shapes (default on for DXF and CGM).
    public var textAsOutlines: Bool
    /// Pixels per inch for effects that must be rasterised.
    public var density: Double
    /// Zero-based pages to write; nil writes all.
    public var pages: [Int]?
    /// Document title for formats that carry one.
    public var title: String?
    /// PDF/A-2b output where the writer can.
    public var pdfA: Bool
    /// EPS: embed a TIFF preview (DOS EPS binary header) so page-layout programs can show the file.
    public var epsPreview: Bool

    public init(textAsOutlines: Bool = false, density: Double = 96, pages: [Int]? = nil, title: String? = nil, pdfA: Bool = false,
                epsPreview: Bool = false) {
        self.textAsOutlines = textAsOutlines; self.density = density; self.pages = pages; self.title = title; self.pdfA = pdfA
        self.epsPreview = epsPreview
    }

    /// Reads the O-VEC option keys (`textToPath`, `pages`, `pixelDensity`, `pdfA`, `epsPreview`).
    public init(_ values: OptionValues, title: String? = nil, textAsOutlinesDefault: Bool = false) {
        self.init(textAsOutlines: values["textToPath"]?.bool ?? textAsOutlinesDefault,
                  density: values["pixelDensity"]?.double ?? 96,
                  pages: nil, title: title, pdfA: values["pdfA"]?.bool ?? false, epsPreview: values["epsPreview"]?.string == "tiff")
        if let range = values["pages"]?.string, let selected = Self.parsePages(range) { pages = selected }
    }

    /// "1-3, 5" → [0, 1, 2, 4]; nil for empty or unparsable text (all pages).
    public static func parsePages(_ text: String) -> [Int]? {
        var out: [Int] = []
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 1 { out.append(bounds[0] - 1) }
            else if bounds.count == 2, bounds[1] >= bounds[0] { out.append(contentsOf: (bounds[0] - 1)...(bounds[1] - 1)) }
            else { return nil }
        }
        return out.isEmpty ? nil : out.filter { $0 >= 0 }
    }
}

public extension VectorDocument {
    /// The selected pages (all when `pages` is nil; indices past the end are ignored).
    func selecting(_ pages: [Int]?) -> VectorDocument {
        guard let pages else { return self }
        var copy = self
        copy.pages = pages.compactMap { self.pages.indices.contains($0) ? self.pages[$0] : nil }
        return copy
    }

    /// Text runs replaced by their glyph outlines (CoreText), so a target without fonts keeps the look.
    func outlinedText() -> VectorDocument {
        var copy = self
        copy.pages = pages.map { page in
            var p = page
            p.nodes = page.nodes.map(VectorOutlines.convert)
            return p
        }
        return copy
    }

    /// Whether any text run is present (so writers know whether `textAsOutlines` matters).
    var containsText: Bool { pages.contains { $0.nodes.contains(where: \.containsText) } }
}

public extension VectorNode {
    var containsText: Bool {
        switch self {
        case .text: true
        case .group(let children, _, _, _): children.contains(where: \.containsText)
        default: false
        }
    }
}

public enum VectorOutlines {
    /// A node with its text turned into filled glyph paths in the node's own coordinates.
    public static func convert(_ node: VectorNode) -> VectorNode {
        switch node {
        case .text(let run): return glyphPaths(run)
        case .group(let children, let t, let clip, let opacity): return .group(children.map(convert), transform: t, clip: clip, opacity: opacity)
        default: return node
        }
    }

    /// The outline of one run: every glyph's path placed at its pen position.
    public static func glyphPaths(_ run: VectorTextRun) -> VectorNode {
        let font = VectorDrawing.font(for: run)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, run.text as CFString, attributes as CFDictionary))
        var segments: [PathSegment] = []
        for ctRun in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(ctRun)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(ctRun, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(ctRun, CFRange(location: 0, length: 0), &positions)
            let runFont = ((CTRunGetAttributes(ctRun) as? [CFString: Any])?[kCTFontAttributeName]).map { $0 as! CTFont } ?? font
            for i in 0..<count {
                guard let path = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
                let t = VectorTransform.translation(run.origin.x + Double(positions[i].x), run.origin.y + Double(positions[i].y))
                segments.append(contentsOf: path.segments.transformed(by: t))
            }
        }
        return .path(segments, fill: run.fill, stroke: nil)
    }
}
