import Foundation
import MathKit

/// Sets formulas with MathKit (MathJax, quality §3.4) and turns them into boxes: MathJax's Computer Modern outlines as
/// vector paths, tagged as a Formula with the TeX source as /ActualText so copying and screen readers get `x^2`.
final class MathBridge {
    let mathJax: MathJax?
    /// Why formulas cannot be set at all (MathJax missing or broken), for the loss note.
    let unavailable: String?
    private(set) var problems: Set<String> = []
    /// Formulas left out because MathJax is unavailable.
    private(set) var skipped = 0
    private var formulaCount = 0
    private var cache: [String: MathRendering] = [:]

    init() {
        switch MathJax.shared {
        case .success(let m): mathJax = m; unavailable = nil
        case .failure(let e): mathJax = nil; unavailable = e.description
        }
    }

    /// The formula as a box, and its `\tag` when it has one.
    func box(_ tex: String, display: Bool, size: Double) -> (box: HBox, tag: String?) {
        let key = "\(display ? "D" : "T")\(size)|\(tex)"
        var rendering = cache[key]
        if rendering == nil, let r = mathJax?.typeset(tex, display: display, size: size) {
            problems.formUnion(r.problems)
            cache[key] = r
            rendering = r
        }
        guard let r = rendering else { skipped += 1; return (.empty, nil) }
        formulaCount += 1
        let tagged = DrawOp.tagged(TagNode(kind: .formula, id: -formulaCount, actualText: tex), [.vector(r.nodes, x: 0, y: 0, scale: 1)])
        return (HBox(width: r.width, height: r.height, depth: r.depth, ops: [tagged]), r.tag)
    }
}
