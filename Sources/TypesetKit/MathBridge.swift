import CoreGraphics
import CoreText
import Foundation
import MathKit

/// Sets formulas with MathKit and turns them into boxes: glyphs of Latin Modern Math drawn as real text (subset-embedded,
/// searchable), tagged as a Formula with the TeX source as /ActualText (quality §3.4).
final class MathBridge: MathTextFonts {
    let typesetter: MathTypesetter?
    let fonts: FontResolver
    private(set) var problems: Set<String> = []
    private var formulaCount = 0
    private var cache: [String: MathRendering] = [:]

    init(library: FontLibrary, fonts: FontResolver) {
        self.fonts = fonts
        if let primary = try? MathFont(url: library.url("LatinModernMath/latinmodern-math.otf")) {
            typesetter = MathTypesetter(font: primary, fallback: try? MathFont(url: library.url("STIXTwo/STIXTwoMath-Regular.otf")))
        } else {
            typesetter = nil
        }
    }

    func mathTextFont(size: Double, bold: Bool, italic: Bool, mono: Bool) -> CTFont {
        mono ? fonts.font(for: RunStyle(family: .mono, bold: bold, size: size)) : fonts.textFont(size: size, bold: bold, italic: italic)
    }

    /// The formula as a box, and its `\tag` when it has one.
    func box(_ tex: String, display: Bool, size: Double) -> (box: HBox, tag: String?) {
        let key = "\(display ? "D" : "T")\(size)|\(tex)"
        var rendering = cache[key]
        if rendering == nil, let r = typesetter?.typeset(tex, display: display, size: size, text: self) {
            problems.formUnion(r.problems)
            cache[key] = r
            rendering = r
        }
        guard let r = rendering else { return (.empty, nil) }
        formulaCount += 1
        var ops: [DrawOp] = []
        // Consecutive glyphs of one font and colour go into one draw call.
        var current: (CTFont, Bool)? = nil
        var glyphs: [CGGlyph] = [], points: [CGPoint] = []
        func flush() {
            guard let (font, error) = current, !glyphs.isEmpty else { return }
            ops.append(.glyphs(font, glyphs, points, colour: error ? CGColor(srgbRed: 0.8, green: 0, blue: 0, alpha: 1) : nil))
            glyphs = []; points = []
        }
        for g in r.glyphs {
            if let c = current, CFEqual(c.0, g.font), c.1 == g.isError {} else { flush(); current = (g.font, g.isError) }
            glyphs.append(g.glyph)
            points.append(CGPoint(x: g.x, y: g.y))
        }
        flush()
        for rule in r.rules {
            ops.append(.rule(x: Double(rule.minX), y: Double(rule.minY), width: Double(rule.width), height: Double(rule.height), colour: nil))
        }
        let tagged = DrawOp.tagged(TagNode(kind: .formula, id: -formulaCount, actualText: tex), ops)
        return (HBox(width: r.width, height: r.height, depth: r.depth, ops: [tagged]), r.tag)
    }
}
