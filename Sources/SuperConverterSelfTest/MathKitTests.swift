import CoreText
import Foundation
import MathKit
import SuperConverterCore

// MathKit's checks (WP-T): the MATH table of Latin Modern Math is read, and formulas are laid out by TeX's rules —
// scripts raised and lowered, fractions with their rule, radicals, delimiters that grow, limits in display style,
// arrays — with unknown commands reported rather than dropped, and 200 formulas set well under two seconds.
func registerMathKitTests() {
    SelfTest.cases.append(("MathKit.layout", { mathLayout() }))
    SelfTest.cases.append(("MathKit.environments", { mathEnvironments() }))
    SelfTest.cases.append(("MathKit.speed", { mathSpeed() }))
}

private struct TestTextFonts: MathTextFonts {
    func mathTextFont(size: Double, bold: Bool, italic: Bool, mono: Bool) -> CTFont {
        CTFontCreateWithName((mono ? "Courier" : "Times-Roman") as CFString, CGFloat(size), nil)
    }
}

private func mathTypesetter() -> MathTypesetter? {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { root.deleteLastPathComponent() }
    let fonts = root.appendingPathComponent("Resources/Fonts")
    guard let lm = try? MathFont(url: fonts.appendingPathComponent("LatinModernMath/latinmodern-math.otf")) else {
        check(false, "Latin Modern Math opens and has a MATH table"); return nil
    }
    let stix = try? MathFont(url: fonts.appendingPathComponent("STIXTwo/STIXTwoMath-Regular.otf"))
    check(stix != nil, "STIX Two Math opens and has a MATH table")
    return MathTypesetter(font: lm, fallback: stix)
}

private func set(_ m: MathTypesetter, _ tex: String, display: Bool = false) -> MathRendering {
    m.typeset(tex, display: display, size: 10, text: TestTextFonts())
}

private func mathLayout() {
    guard let m = mathTypesetter() else { return }
    let x = set(m, "x"), x2 = set(m, "x^2"), xi = set(m, "x_i")
    check(x.glyphs.count == 1 && x.problems.isEmpty, "a letter is one glyph")
    check(x2.height > x.height + 2 && x2.width > x.width, "x^2 raises a smaller 2 (height \(x2.height))")
    check(xi.depth > 1, "x_i lowers the i (depth \(xi.depth))")
    let both = set(m, "x_i^2")
    check(both.height > x.height && both.depth > 1, "x_i^2 has both scripts")

    let textFrac = set(m, "\\frac{a}{b}"), displayFrac = set(m, "\\frac{a}{b}", display: true)
    check(textFrac.rules.count == 1, "a fraction has its rule")
    if let rule = textFrac.rules.first {
        check(abs(Double(rule.midY) - 2.5) < 0.3, "the fraction rule sits on the math axis (2.5 pt at 10 pt): \(rule.midY)")
    }
    check(displayFrac.height > textFrac.height + 1, "display fractions are taller than text fractions")
    check(set(m, "\\binom{n}{k}").rules.isEmpty, "a binomial has no rule")

    let root = set(m, "\\sqrt{x}")
    check(root.rules.count == 1 && root.height > x.height + 1, "a radical has a surd and an overbar")
    check(set(m, "\\sqrt[3]{x}").glyphs.count == 3, "a radical's degree is set")

    let plain = set(m, "(x)"), grown = set(m, "\\left( \\frac{a}{b} \\right)", display: true)
    check(grown.height > plain.height + 3, "\\left( grows around a display fraction")
    let tall = set(m, "\\left( \\sum_{i=1}^{n} \\frac{1}{i^2} \\right)", display: true)
    check(tall.height + tall.depth > 20, "delimiters grow to cover a display sum (\(tall.height + tall.depth) pt)")

    let sumText = set(m, "\\sum_{i=1}^n i"), sumDisplay = set(m, "\\sum_{i=1}^n i", display: true)
    check(sumDisplay.height > sumText.height + 4, "∑ takes its limits above and below in display style")
    check(set(m, "\\int_0^1 f(x)\\,dx", display: true).problems.isEmpty, "integrals with limits set cleanly")
    check(set(m, "\\lim_{n \\to \\infty} a_n", display: true).depth > 4, "\\lim takes its subscript below in display style")

    check(set(m, "a+b").width > set(m, "ab").width + 4, "binary operators get medium spaces")
    let base = set(m, "x").glyphs[0].glyph, script = set(m, "y^x").glyphs[1].glyph
    check(base != script, "scripts use the font's ssty script-size designs (x \(base), script x \(script))")
    let integral = set(m, "\\int_0^1", display: true)
    check(integral.height > 12 && integral.glyphs.count == 3, "a display integral's limits hang at its top and bottom (height \(integral.height))")
    check(set(m, "\\hat{x}").glyphs.count == 2 && set(m, "\\vec{v}").glyphs.count == 2, "accents sit over their base")
    check(set(m, "\\alpha\\beta\\Gamma\\mathbb{R}\\mathcal{L}").problems.isEmpty, "Greek and math alphabets are known")

    let unknown = set(m, "x + \\frobnicate{y}")
    check(unknown.problems == ["\\frobnicate"], "unknown commands are reported: \(unknown.problems)")
    check(unknown.glyphs.contains { $0.isError }, "unknown commands are set in red")
    check(set(m, "x = 1 \\tag{3}").tag == "(3)", "\\tag gives the equation number")
}

private func mathEnvironments() {
    guard let m = mathTypesetter() else { return }
    for tex in ["\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", "\\begin{bmatrix} 1 & 0 \\\\ 0 & 1 \\end{bmatrix}",
                "|x| = \\begin{cases} x & x \\ge 0 \\\\ -x & x < 0 \\end{cases}",
                "\\begin{aligned} a &= b + c \\\\ &= d \\end{aligned}", "\\begin{array}{c|c} 1 & 2 \\\\ 3 & 4 \\end{array}",
                "a &= b \\\\ c &= d", "\\overbrace{a+b}^{n}", "\\underbrace{x+y}_{m}", "\\sum_{\\substack{i<n \\\\ i \\text{ odd}}} i",
                "f'(x) = \\lim_{h\\to 0}\\frac{f(x+h)-f(x)}{h}", "\\phi = 1 + \\cfrac{1}{1 + \\cfrac{1}{1+\\dotsb}}",
                "\\mathbf{v} \\cdot \\mathbf{w} = \\|v\\|\\,\\|w\\| \\cos\\theta", "\\not\\in \\not= \\not\\subset",
                "\\overline{AB} \\underline{x} \\widehat{xyz} \\widetilde{abc}", "\\bigl( x \\bigr) \\Bigl[ y \\Bigr]"] {
        let r = set(m, tex, display: true)
        check(r.problems.isEmpty && r.width > 0 && !r.glyphs.isEmpty, "\(tex) sets without problems (\(r.problems))")
    }
    let matrix = set(m, "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", display: true)
    check(matrix.height > 8 && matrix.depth > 5, "a 2×2 matrix is centred on the axis (h \(matrix.height), d \(matrix.depth))")
    let aligned = set(m, "a &= b \\\\ c &= d", display: true)
    check(aligned.height + aligned.depth > 22, "aligned rows are a baseline and a \\jot apart")
}

/// ARCHITECTURE §12.6: 200 formulas in well under two seconds.
private func mathSpeed() {
    guard let m = mathTypesetter() else { return }
    let started = Date()
    for i in 0..<200 {
        _ = set(m, "\\sum_{k=1}^{\(i)} \\frac{k^2 + \\alpha_k}{\\sqrt{k + \(i)}} = \\left( \\int_0^1 x^{\(i)}\\,dx \\right)", display: i % 2 == 0)
    }
    let seconds = Date().timeIntervalSince(started)
    check(seconds < 2, "200 formulas set in \(String(format: "%.2f", seconds)) s")
}
