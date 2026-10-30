import Foundation
import MathKit
import SuperConverterCore

// MathKit's checks (WP-T): MathJax loads in JavaScriptCore and sets TeX as vector paths with TeX's metrics — scripts
// raised and lowered, fractions with their rule on the axis, radicals, growing delimiters, limits in display style,
// environments, at TeX's sizes; `\text` as text, the outer list's glue — with undefined macros and parse errors
// reported, and 200 formulas measured against ARCHITECTURE §12.6.
func registerMathKitTests() {
    SelfTest.cases.append(("MathKit.loads", { mathLoads() }))
    SelfTest.cases.append(("MathKit.layout", { mathLayout() }))
    SelfTest.cases.append(("MathKit.environments", { mathEnvironments() }))
    SelfTest.cases.append(("MathKit.source", { mathSource() }))
    SelfTest.cases.append(("MathKit.speed", { mathSpeed() }))
}

private func mathJax() -> MathJax? {
    switch MathJax.shared {
    case .success(let m): return m
    case .failure(let e): check(false, "MathJax loads: \(e)"); return nil
    }
}

private func set(_ m: MathJax, _ tex: String, display: Bool = false) -> MathRendering {
    m.typeset(tex, display: display, size: 10)
}

/// Every path point of a rendering, to check where ink is.
private func points(_ r: MathRendering) -> [VectorPoint] {
    r.nodes.flatMap { node -> [VectorPoint] in
        guard case .path(let segments, _, _, _) = node else { return [] }
        return segments.compactMap {
            switch $0 {
            case .move(let p), .line(let p): p
            case .cubic(_, _, let p), .quad(_, let p): p
            case .close: nil
            }
        }
    }
}

private func mathLoads() {
    guard let script = MathJax.bundledScript() else { check(false, "the MathJax script is bundled"); return }
    let (loaded, seconds) = threadCPUSeconds { try? MathJax(script: script) }
    check(loaded != nil, "MathJax evaluates in JavaScriptCore")
    print("  MathJax load: \(String(format: "%.2f", seconds)) s of CPU")
    check(seconds < 3 * budgetScale, "MathJax loads in \(String(format: "%.2f", seconds)) s")
    let missing = URL(fileURLWithPath: "/nonexistent/mathjax.js")
    check((try? MathJax(script: missing)) == nil, "a missing script is an error, not a crash")
}

private func mathLayout() {
    guard let m = mathJax() else { return }
    let x = set(m, "x"), x2 = set(m, "x^2"), xi = set(m, "x_i")
    check(x.nodes.count == 1 && x.problems.isEmpty, "a letter is one path (\(x.nodes.count))")
    check(abs(x.width - 5.72) < 0.05, "x is cmmi10's 5.72 pt wide at 10 pt (\(x.width))")
    check(x2.height > x.height + 2 && x2.width > x.width, "x^2 raises a smaller 2 (height \(x2.height))")
    check(xi.depth > 1, "x_i lowers the i (depth \(xi.depth))")

    let textFrac = set(m, "\\frac{a}{b}"), displayFrac = set(m, "\\frac{a}{b}", display: true)
    let bar = textFrac.nodes.compactMap { node -> Double? in
        guard case .path(let s, _, _, _) = node, s.count == 5, case .move(let p) = s[0] else { return nil }
        return p.y
    }
    check(bar.contains { abs($0 - 2.3) < 0.4 }, "the fraction rule sits on the math axis (2.5 pt at 10 pt): \(bar)")
    check(displayFrac.height > textFrac.height + 1, "display fractions are taller than text fractions")

    let root = set(m, "\\sqrt{x}")
    check(root.height > x.height + 1, "a radical has a surd and an overbar")
    let plain = set(m, "(x)"), grown = set(m, "\\left( \\frac{a}{b} \\right)", display: true)
    check(grown.height > plain.height + 3, "\\left( grows around a display fraction")
    let sumText = set(m, "\\sum_{i=1}^n i"), sumDisplay = set(m, "\\sum_{i=1}^n i", display: true)
    check(sumDisplay.height > sumText.height + 4, "∑ takes its limits above and below in display style")
    check(set(m, "a+b").width > set(m, "ab").width + 4, "binary operators get medium spaces")
    let ink = points(set(m, "x^2"))
    check(ink.allSatisfy { $0.x >= -0.5 && $0.x <= x2.width + 0.5 && $0.y <= x2.height + 0.5 && $0.y >= -x2.depth - 0.5 },
          "the ink stays inside the box, y up from the baseline")

    let unknown = set(m, "x + \\frobnicate{y}")
    check(unknown.problems == ["\\frobnicate"], "undefined macros are reported: \(unknown.problems)")
    check(unknown.nodes.contains { if case .text(let t) = $0, case .solid(let c) = t.fill { return t.text == "\\frobnicate" && c.red > 0.9 && c.green < 0.1 }; return false },
          "undefined macros are set in red")
    let broken = set(m, "\\frac{a}{b")
    check(broken.problems.first?.hasPrefix("Missing close brace") == true, "parse errors are reported: \(broken.problems)")
    check(broken.width > 10 && broken.nodes.count == 1, "a formula that does not parse shows its source")
    texMetrics(m)
    check(set(m, "\\color{blue}{x}").nodes.contains { if case .path(_, .solid(let c)?, _, _) = $0 { return c.blue == 1 && c.red == 0 }; return false },
          "\\color reaches the paths")
}

/// Widths and heights against TeX's own (Tectonic, cmr/cmmi/cmsy at 10, 7 and 5 pt): the quality §3.7 parity fixtures
/// break lines where LaTeX does only with these.
private func texMetrics(_ m: MathJax) {
    let cases: [(String, Bool, Double, Double)] = [
        ("\\beta", false, 6.184, 8.889), ("f", false, 5.972, 8.889), ("y^{2}", false, 9.748, 10.084), ("z_{j}^{k}", false, 10.010, 12.454),
        ("x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", false, 69.602, 13.888), ("\\sum_{i=1}^{n} i", false, 29.122, 11.042),
        ("\\sqrt{x}", false, 14.049, 10.400), ("\\left( x \\right.", false, 10.804, 10.0),
        ("\\begin{aligned} (a + b)^2 &= a^2 + 2ab + b^2 \\\\ (a - b)^2 &= a^2 - 2ab + b^2 \\end{aligned}", true, 104.968, 28.480),
        ("|x| = \\begin{cases} x & \\text{if } x \\geq 0 \\\\ -x & \\text{otherwise} \\end{cases}", true, 98.543, 30.0),
    ]
    for (tex, display, width, total) in cases {
        let r = set(m, tex, display: display)
        check(abs(r.width - width) < 0.25, "\(tex) is TeX's \(width) pt wide (\(String(format: "%.3f", r.width)))")
        check(abs(r.height + r.depth - total) < 0.6, "\(tex) is TeX's \(total) pt tall (\(String(format: "%.3f", r.height + r.depth)))")
    }
    let text = set(m, "\\text{otherwise}")
    check(text.nodes.count == 1 && text.nodes.contains { if case .text(let t) = $0 { return t.text == "otherwise" }; return false },
          "\\text{…} is a text run, not outlines")
    let breaks = set(m, "ax^2 + bx = 0").breaks
    check(breaks.map(\.penalty) == [10000, 700, 10000, 500] && abs(breaks[0].stretch - 10.0 / 9) < 0.01 && abs(breaks[2].stretch - 50.0 / 18) < 0.01,
          "the outer list has TeX's glue and break penalties: \(breaks)")
}

private func mathEnvironments() {
    guard let m = mathJax() else { return }
    for tex in ["\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", "\\begin{bmatrix} 1 & 0 \\\\ 0 & 1 \\end{bmatrix}",
                "|x| = \\begin{cases} x & x \\ge 0 \\\\ -x & x < 0 \\end{cases}",
                "\\begin{aligned} a &= b + c \\\\ &= d \\end{aligned}", "\\begin{array}{c|c} 1 & 2 \\\\ 3 & 4 \\end{array}",
                "\\overbrace{a+b}^{n}", "\\underbrace{x+y}_{m}", "\\sum_{\\substack{i<n \\\\ i \\text{ odd}}} i",
                "f'(x) = \\lim_{h\\to 0}\\frac{f(x+h)-f(x)}{h}", "\\phi = 1 + \\cfrac{1}{1 + \\cfrac{1}{1+\\dotsb}}",
                "\\mathbf{v} \\cdot \\mathbf{w} = \\|v\\|\\,\\|w\\| \\cos\\theta", "\\not\\in \\not= \\not\\subset",
                "\\overline{AB} \\underline{x} \\widehat{xyz} \\widetilde{abc}", "\\bigl( x \\bigr) \\Bigl[ y \\Bigr]",
                "\\boxed{E = mc^2}", "\\ce{H2O + CO2 -> H2CO3}", "\\mathbb{R}\\mathcal{L}\\mathfrak{g}"] {
        let r = set(m, tex, display: true)
        check(r.problems.isEmpty && r.width > 0 && !r.nodes.isEmpty, "\(tex) sets without problems (\(r.problems))")
    }
    let matrix = set(m, "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", display: true)
    check(matrix.height > 8 && matrix.depth > 5, "a 2×2 matrix is centred on the axis (h \(matrix.height), d \(matrix.depth))")
    let rows = set(m, "a &= b \\\\ c &= d", display: true)
    check(rows.problems.isEmpty && rows.height + rows.depth > 22, "bare rows are set as aligned (\(rows.height + rows.depth) pt)")
    let cjk = set(m, "\\text{日本} x")
    check(cjk.nodes.contains { if case .text(let t) = $0 { return t.text.contains("日") }; return false }, "characters MathJax lacks stay text")
}

private func mathSource() {
    guard let m = mathJax() else { return }
    check(set(m, "x = 1 \\tag{3}").tag == "(3)", "\\tag gives the equation number")
    check(set(m, "x = 1 \\tag*{A}").tag == "A", "\\tag* gives its text as is")
    let labelled = set(m, "x \\label{eq:x} = 1 \\nonumber")
    check(labelled.tag == nil && labelled.problems.isEmpty, "\\label and \\nonumber are dropped")
    check(set(m, "a \\\\ b", display: true).height > set(m, "a", display: true).height + 5, "rows without & are gathered")
}

/// ARCHITECTURE §12.6: 200 formulas in under two seconds (JavaScriptCore; the app has no JIT entitlement).
private func mathSpeed() {
    guard let m = mathJax() else { return }
    let (_, seconds) = threadCPUSeconds {
        for i in 0..<200 {
            _ = set(m, "\\sum_{k=1}^{\(i)} \\frac{k^2 + \\alpha_k}{\\sqrt{k + \(i)}} = \\left( \\int_0^1 x^{\(i)}\\,dx \\right)", display: i % 2 == 0)
        }
    }
    print("  200 formulas: \(String(format: "%.2f", seconds)) s of CPU")
    check(seconds < 2 * budgetScale, "200 formulas set in \(String(format: "%.2f", seconds)) s")
}
