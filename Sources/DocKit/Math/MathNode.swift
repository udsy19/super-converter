import Foundation

// The common form of a formula: TeX (what DocModel stores), MathML (HTML, EPUB) and OMML (Word) all convert through it,
// so each format needs one parser and one emitter, not one per pair (formats §3.2: OMML/MathML ↔ TeX).

indirect enum MathNode: Equatable {
    case row([MathNode])
    /// A variable: one letter or Greek letter.
    case ident(String)
    case number(String)
    /// An operator, relation, delimiter or other symbol, as its Unicode character.
    case op(String)
    /// `\text{…}` and other upright words.
    case text(String)
    /// `\sin`, `\lim`: an upright function name.
    case function(String)
    case frac(MathNode, MathNode)
    case sqrt(MathNode, index: MathNode?)
    case sup(MathNode, MathNode)
    case sub(MathNode, MathNode)
    case subsup(MathNode, MathNode, MathNode)
    /// A bracketed group that grows with its content (`\left( … \right)`); "" for an absent delimiter.
    case fenced(open: String, close: String, MathNode)
    /// A matrix or `cases`; the delimiters are those of the environment.
    case matrix([[MathNode]], open: String, close: String)
    /// A mark over the base (`\hat`, `\bar`, `\vec`), by its combining-free character.
    case accent(MathNode, String)
    /// A horizontal space, as the TeX command that makes it ("\\,", "\\quad").
    case space(String)
    /// TeX the parser did not understand, kept verbatim.
    case raw(String)

    var isEmpty: Bool { if case .row(let c) = self { c.isEmpty } else { false } }

    /// The children of a row, or the node itself as one.
    var items: [MathNode] { if case .row(let c) = self { c } else { [self] } }

    static func make(_ items: [MathNode]) -> MathNode { items.count == 1 ? items[0] : .row(items) }

    /// Brackets around a bare matrix are the matrix's own delimiters (`pmatrix`), however the source spelled them.
    static func fence(open: String, close: String, _ body: MathNode) -> MathNode {
        if case .matrix(let rows, "", "") = body { return .matrix(rows, open: open, close: close) }
        return .fenced(open: open, close: close, body)
    }
}

enum MathSymbols {
    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ϵ", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "varpi": "ϖ", "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ", "phi": "ϕ",
        "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
        "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω", "ell": "ℓ", "hbar": "ℏ",
        "aleph": "ℵ", "partial": "∂", "nabla": "∇", "infty": "∞", "emptyset": "∅", "imath": "ı", "jmath": "ȷ",
    ]

    static let symbols: [String: String] = [
        "pm": "±", "mp": "∓", "times": "×", "div": "÷", "cdot": "⋅", "ast": "∗", "star": "⋆", "circ": "∘", "bullet": "∙",
        "oplus": "⊕", "ominus": "⊖", "otimes": "⊗", "odot": "⊙", "cap": "∩", "cup": "∪", "setminus": "∖",
        "wedge": "∧", "vee": "∨", "land": "∧", "lor": "∨", "neg": "¬", "lnot": "¬", "forall": "∀", "exists": "∃",
        "in": "∈", "notin": "∉", "ni": "∋", "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼",
        "simeq": "≃", "cong": "≅", "propto": "∝", "ll": "≪", "gg": "≫", "perp": "⊥", "parallel": "∥", "mid": "∣",
        "to": "→", "rightarrow": "→", "leftarrow": "←", "gets": "←", "leftrightarrow": "↔", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "Leftrightarrow": "⇔", "implies": "⟹", "iff": "⟺", "mapsto": "↦", "uparrow": "↑",
        "downarrow": "↓", "ldots": "…", "dots": "…", "cdots": "⋯", "vdots": "⋮", "ddots": "⋱", "prime": "′",
        "angle": "∠", "triangle": "△", "degree": "°", "dagger": "†", "ddagger": "‡", "S": "§", "P": "¶",
        "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋", "lceil": "⌈", "rceil": "⌉",
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "iint": "∬", "iiint": "∭", "oint": "∮",
        "bigcup": "⋃", "bigcap": "⋂", "bigoplus": "⨁", "bigotimes": "⨂", "bigvee": "⋁", "bigwedge": "⋀",
    ]

    /// Operators that take limits: they become `m:nary` in Word.
    static let nary: Set<String> = ["∑", "∏", "∐", "∫", "∬", "∭", "∮", "⋃", "⋂", "⨁", "⨂", "⋁", "⋀"]

    static let functions: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
        "log", "ln", "lg", "exp", "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "gcd", "deg", "dim",
        "ker", "arg", "Pr", "hom", "mod",
    ]

    static let accents: [String: String] = [
        "hat": "^", "widehat": "^", "bar": "¯", "overline": "¯", "vec": "→", "tilde": "~", "widetilde": "~", "dot": "˙",
        "ddot": "¨", "check": "ˇ", "breve": "˘", "acute": "´", "grave": "`",
    ]

    static let greekByChar: [String: String] = Dictionary(greek.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
    static let symbolByChar: [String: String] = Dictionary(symbols.map { ($0.value, $0.key) }, uniquingKeysWith: { a, b in a.count <= b.count ? a : b })
    static let accentByChar: [String: String] = ["^": "hat", "¯": "bar", "→": "vec", "~": "tilde", "˙": "dot", "¨": "ddot", "ˇ": "check", "˘": "breve", "´": "acute", "`": "grave"]

}
