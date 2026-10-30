import CoreText
import Foundation
import MathKit
import SuperConverterCore
import VectorKit

/// An inline formula as the paragraph builder takes it: the pieces between the spaces of its outer list, the spaces as
/// glue (no breakpoint unless a penalty below 10000 comes first), and TeX's break penalties after relations and binary
/// operators (TeXbook ch. 18).
enum MathPiece {
    case box(HBox)
    case glue(Glue)
    case penalty(Int)
}

/// Sets formulas with MathKit (MathJax, quality §3.4) and turns them into boxes: MathJax's Computer Modern outlines as
/// vector paths and `\text{…}` as text in the text font, as LaTeX sets it, tagged as a Formula with the TeX source as
/// /ActualText so copying and screen readers get `x^2`.
final class MathBridge {
    let mathJax: MathJax?
    private let fonts: FontResolver
    /// Why formulas cannot be set at all (MathJax missing or broken), for the loss note.
    let unavailable: String?
    private(set) var problems: Set<String> = []
    /// Formulas left out because MathJax is unavailable.
    private(set) var skipped = 0
    private var formulaCount = 0
    private var cache: [String: MathRendering] = [:]

    init(fonts: FontResolver) {
        self.fonts = fonts
        switch MathJax.shared {
        case .success(let m): mathJax = m; unavailable = nil
        case .failure(let e): mathJax = nil; unavailable = e.description
        }
    }

    /// A display formula as a box, and its `\tag` when it has one.
    func display(_ tex: String, size: Double) -> (box: HBox, tag: String?) {
        guard let r = rendering(tex, display: true, size: size) else { return (.empty, nil) }
        formulaCount += 1
        return (piece(r, from: 0, to: r.width, ink: -.infinity ..< .infinity, actualText: tex), r.tag)
    }

    /// An inline formula cut at the glue of its outer list. Every piece has the formula's height and depth; the first
    /// carries the TeX source as /ActualText, the others an empty one, so copying gives the source once.
    func inline(_ tex: String, size: Double) -> [MathPiece] {
        guard let r = rendering(tex, display: false, size: size) else { return [] }
        formulaCount += 1
        var pieces: [MathPiece] = [], start = 0.0, cut = -Double.infinity
        for b in r.breaks {
            let middle = b.x + b.width / 2
            pieces.append(.box(piece(r, from: start, to: b.x, ink: cut ..< middle, actualText: pieces.isEmpty ? tex : "")))
            pieces.append(.penalty(b.penalty))
            pieces.append(.glue(Glue(width: b.width, stretch: b.stretch, shrink: b.shrink)))
            start = b.x + b.width
            cut = middle
        }
        pieces.append(.box(piece(r, from: start, to: r.width, ink: cut ..< .infinity, actualText: pieces.isEmpty ? tex : "")))
        return pieces
    }

    private func rendering(_ tex: String, display: Bool, size: Double) -> MathRendering? {
        let key = "\(display ? "D" : "T")\(size)|\(tex)"
        if let r = cache[key] { return r }
        guard let r = mathJax?.typeset(tex, display: display, size: size) else { skipped += 1; return nil }
        problems.formUnion(r.problems)
        cache[key] = r
        return r
    }

    /// The part of the formula from `from` to `to`, moved to 0: the nodes whose middle (a text run's start) lies in `ink`,
    /// which runs to the middle of the glue on either side.
    private func piece(_ r: MathRendering, from: Double, to: Double, ink: Range<Double>, actualText: String) -> HBox {
        var paths: [VectorNode] = [], texts: [DrawOp] = []
        for node in r.nodes {
            if case .text(let run) = node {
                if ink.contains(run.origin.x) { texts.append(text(run, dx: -from)) }
            } else if ink.contains(node.bounds.map { Double($0.midX) } ?? from) {
                paths.append(node)
            }
        }
        let tagged = DrawOp.tagged(TagNode(kind: .formula, id: -formulaCount, actualText: actualText),
                                   [.vector(paths, x: -from, y: 0, scale: 1)] + texts)
        return HBox(width: to - from, height: r.height, depth: r.depth, ops: [tagged])
    }

    /// A text run of the formula in Latin Modern at its size, in its style (MathKit names the face it would use) and
    /// colour; characters Latin Modern lacks come from its cascade.
    private func text(_ run: VectorTextRun, dx: Double) -> DrawOp {
        let font = fonts.textFont(size: run.size, bold: run.fontName.contains("Bold"), italic: run.fontName.contains("Italic"),
                                  mono: run.fontName.hasPrefix("Menlo"))
        var colour = CGColor(gray: 0, alpha: 1)
        if case .solid(let c) = run.fill { colour = CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha) }
        let string = NSAttributedString(string: run.text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                       kCTForegroundColorAttributeName as NSAttributedString.Key: colour])
        return .text(string, x: run.origin.x + dx, y: run.origin.y)
    }
}
