import Foundation

/// TeX's atom classes (The TeXbook, chapter 17).
enum AtomType: Int, Sendable {
    case ord, op, bin, rel, open, close, punct, inner
}

/// A math alphabet (`\mathbf`, `\mathcal`, …) and how letters and digits map into the Unicode Mathematical Alphanumeric
/// Symbols block.
enum MathAlphabet: Sendable {
    case italic, upright, bold, boldItalic, script, fraktur, doubleStruck, sansSerif, sansBold, monospace

    func map(_ c: Unicode.Scalar) -> Unicode.Scalar {
        let v = c.value
        let upper = (0x41...0x5A).contains(v), lower = (0x61...0x7A).contains(v), digit = (0x30...0x39).contains(v)
        func at(_ base: UInt32, _ offset: UInt32) -> Unicode.Scalar { Unicode.Scalar(base + offset) ?? c }
        let li = upper ? v - 0x41 : v - 0x61
        switch self {
        case .upright:
            return c
        case .italic:
            if c == "h" { return "\u{210E}" }
            if upper { return at(0x1D434, li) }
            if lower { return at(0x1D44E, li) }
            if let g = MathSymbols.greekItalic[v] { return g }
            return c
        case .bold:
            if upper { return at(0x1D400, li) }
            if lower { return at(0x1D41A, li) }
            if digit { return at(0x1D7CE, v - 0x30) }
            if let g = MathSymbols.greekBold[v] { return g }
            return c
        case .boldItalic:
            if upper { return at(0x1D468, li) }
            if lower { return at(0x1D482, li) }
            if digit { return at(0x1D7CE, v - 0x30) }
            return c
        case .script:
            let holes: [UInt32: UInt32] = [0x42: 0x212C, 0x45: 0x2130, 0x46: 0x2131, 0x48: 0x210B, 0x49: 0x2110, 0x4C: 0x2112,
                                           0x4D: 0x2133, 0x52: 0x211B, 0x65: 0x212F, 0x67: 0x210A, 0x6F: 0x2134]
            if let h = holes[v] { return Unicode.Scalar(h)! }
            if upper { return at(0x1D49C, li) }
            if lower { return at(0x1D4B6, li) }
            return c
        case .fraktur:
            let holes: [UInt32: UInt32] = [0x43: 0x212D, 0x48: 0x210C, 0x49: 0x2111, 0x52: 0x211C, 0x5A: 0x2128]
            if let h = holes[v] { return Unicode.Scalar(h)! }
            if upper { return at(0x1D504, li) }
            if lower { return at(0x1D51E, li) }
            return c
        case .doubleStruck:
            let holes: [UInt32: UInt32] = [0x43: 0x2102, 0x48: 0x210D, 0x4E: 0x2115, 0x50: 0x2119, 0x51: 0x211A, 0x52: 0x211D, 0x5A: 0x2124]
            if let h = holes[v] { return Unicode.Scalar(h)! }
            if upper { return at(0x1D538, li) }
            if lower { return at(0x1D552, li) }
            if digit { return at(0x1D7D8, v - 0x30) }
            return c
        case .sansSerif:
            if upper { return at(0x1D5A0, li) }
            if lower { return at(0x1D5BA, li) }
            if digit { return at(0x1D7E2, v - 0x30) }
            return c
        case .sansBold:
            if upper { return at(0x1D5D4, li) }
            if lower { return at(0x1D5EE, li) }
            if digit { return at(0x1D7EC, v - 0x30) }
            return c
        case .monospace:
            if upper { return at(0x1D670, li) }
            if lower { return at(0x1D68A, li) }
            if digit { return at(0x1D7F6, v - 0x30) }
            return c
        }
    }
}

/// What a control sequence means in math mode.
enum SymbolInfo: Sendable {
    case symbol(Unicode.Scalar, AtomType)
    /// A big operator; `limits` when its scripts go above and below in display style.
    case largeOp(Unicode.Scalar, limits: Bool)
    /// A named operator set upright (`\sin`, `\lim`).
    case namedOp(String, limits: Bool)
    /// A delimiter usable with `\left`/`\right`.
    case delimiter(Unicode.Scalar, AtomType)
    case accent(Unicode.Scalar, stretchy: Bool)
    case space(Double, unit: SpaceUnit)
    case alphabet(MathAlphabet)
}

enum SpaceUnit: Sendable { case mu, em }

enum MathSymbols {
    static let greekLowerNames: [(String, UInt32)] = [
        ("alpha", 0x3B1), ("beta", 0x3B2), ("gamma", 0x3B3), ("delta", 0x3B4), ("varepsilon", 0x3B5), ("zeta", 0x3B6),
        ("eta", 0x3B7), ("theta", 0x3B8), ("iota", 0x3B9), ("kappa", 0x3BA), ("lambda", 0x3BB), ("mu", 0x3BC),
        ("nu", 0x3BD), ("xi", 0x3BE), ("omicron", 0x3BF), ("pi", 0x3C0), ("rho", 0x3C1), ("varsigma", 0x3C2),
        ("sigma", 0x3C3), ("tau", 0x3C4), ("upsilon", 0x3C5), ("varphi", 0x3C6), ("chi", 0x3C7), ("psi", 0x3C8),
        ("omega", 0x3C9), ("epsilon", 0x3F5), ("vartheta", 0x3D1), ("phi", 0x3D5), ("varrho", 0x3F1), ("varpi", 0x3D6),
        ("varkappa", 0x3F0), ("digamma", 0x3DD),
    ]
    static let greekUpperNames: [(String, UInt32)] = [
        ("Gamma", 0x393), ("Delta", 0x394), ("Theta", 0x398), ("Lambda", 0x39B), ("Xi", 0x39E), ("Pi", 0x3A0),
        ("Sigma", 0x3A3), ("Upsilon", 0x3A5), ("Phi", 0x3A6), ("Psi", 0x3A8), ("Omega", 0x3A9),
    ]

    /// Lower-case Greek to its math italic form (U+1D6FC…); capitals stay upright, as in TeX.
    static let greekItalic: [UInt32: Unicode.Scalar] = {
        var m: [UInt32: Unicode.Scalar] = [:]
        for (i, v) in (0x3B1...0x3C9).enumerated() { m[UInt32(v)] = Unicode.Scalar(0x1D6FC + UInt32(i)) }
        m[0x2202] = Unicode.Scalar(0x1D715); m[0x3F5] = Unicode.Scalar(0x1D716); m[0x3D1] = Unicode.Scalar(0x1D717)
        m[0x3F0] = Unicode.Scalar(0x1D718); m[0x3D5] = Unicode.Scalar(0x1D719); m[0x3F1] = Unicode.Scalar(0x1D71A)
        m[0x3D6] = Unicode.Scalar(0x1D71B)
        return m
    }()
    static let greekBold: [UInt32: Unicode.Scalar] = {
        var m: [UInt32: Unicode.Scalar] = [:]
        for (i, v) in (0x391...0x3A9).enumerated() where v != 0x3A2 { m[UInt32(v)] = Unicode.Scalar(0x1D6A8 + UInt32(i)) }
        for (i, v) in (0x3B1...0x3C9).enumerated() { m[UInt32(v)] = Unicode.Scalar(0x1D6C2 + UInt32(i)) }
        return m
    }()

    static let table: [String: SymbolInfo] = {
        var t: [String: SymbolInfo] = [:]
        for (name, v) in greekLowerNames { t[name] = .symbol(Unicode.Scalar(v)!, .ord) }
        for (name, v) in greekUpperNames { t[name] = .symbol(Unicode.Scalar(v)!, .ord) }
        func add(_ type: AtomType, _ pairs: [(String, UInt32)]) {
            for (n, v) in pairs { t[n] = .symbol(Unicode.Scalar(v)!, type) }
        }
        add(.ord, [("infty", 0x221E), ("partial", 0x2202), ("nabla", 0x2207), ("forall", 0x2200), ("exists", 0x2203),
                   ("nexists", 0x2204), ("neg", 0xAC), ("lnot", 0xAC), ("emptyset", 0x2205), ("varnothing", 0x2205),
                   ("hbar", 0x210F), ("hslash", 0x210F), ("ell", 0x2113), ("wp", 0x2118), ("Re", 0x211C), ("Im", 0x2111),
                   ("aleph", 0x2135), ("beth", 0x2136), ("gimel", 0x2137), ("top", 0x22A4), ("bot", 0x22A5),
                   ("angle", 0x2220), ("measuredangle", 0x2221), ("triangle", 0x25B3), ("surd", 0x221A), ("prime", 0x2032),
                   ("backprime", 0x2035), ("flat", 0x266D), ("natural", 0x266E), ("sharp", 0x266F), ("clubsuit", 0x2663),
                   ("diamondsuit", 0x2662), ("heartsuit", 0x2661), ("spadesuit", 0x2660), ("imath", 0x1D6A4),
                   ("jmath", 0x1D6A5), ("mho", 0x2127), ("Box", 0x25A1), ("square", 0x25A1), ("blacksquare", 0x25A0),
                   ("checkmark", 0x2713), ("degree", 0xB0), ("complement", 0x2201), ("Finv", 0x2132), ("eth", 0xF0),
                   ("backslash", 0x5C), ("vdots", 0x22EE), ("ddots", 0x22F1), ("dagger", 0x2020), ("ddagger", 0x2021),
                   ("S", 0xA7), ("P", 0xB6), ("pounds", 0xA3), ("copyright", 0xA9), ("lozenge", 0x25CA),
                   ("bigstar", 0x2605), ("diagdown", 0x27CD), ("diagup", 0x27CB)])
        add(.inner, [("ldots", 0x2026), ("dots", 0x2026), ("cdots", 0x22EF), ("dotsc", 0x2026), ("dotsb", 0x22EF),
                     ("dotsm", 0x22EF), ("dotsi", 0x22EF), ("dotso", 0x2026)])
        add(.bin, [("pm", 0xB1), ("mp", 0x2213), ("times", 0xD7), ("div", 0xF7), ("cdot", 0x22C5), ("ast", 0x2217),
                   ("star", 0x22C6), ("circ", 0x2218), ("bullet", 0x2219), ("cap", 0x2229), ("cup", 0x222A),
                   ("uplus", 0x228E), ("sqcap", 0x2293), ("sqcup", 0x2294), ("vee", 0x2228), ("lor", 0x2228),
                   ("wedge", 0x2227), ("land", 0x2227), ("setminus", 0x2216), ("smallsetminus", 0x2216), ("wr", 0x2240),
                   ("diamond", 0x22C4), ("bigtriangleup", 0x25B3), ("bigtriangledown", 0x25BD),
                   ("triangleleft", 0x25C1), ("triangleright", 0x25B7), ("oplus", 0x2295), ("ominus", 0x2296),
                   ("otimes", 0x2297), ("oslash", 0x2298), ("odot", 0x2299), ("bigcirc", 0x25EF), ("amalg", 0x2A3F),
                   ("ltimes", 0x22C9), ("rtimes", 0x22CA), ("dotplus", 0x2214), ("centerdot", 0x22C5),
                   ("boxplus", 0x229E), ("boxtimes", 0x22A0), ("intercal", 0x22BA)])
        add(.rel, [("le", 0x2264), ("leq", 0x2264), ("ge", 0x2265), ("geq", 0x2265), ("ne", 0x2260), ("neq", 0x2260),
                   ("equiv", 0x2261), ("sim", 0x223C), ("simeq", 0x2243), ("asymp", 0x224D), ("approx", 0x2248),
                   ("cong", 0x2245), ("subset", 0x2282), ("supset", 0x2283), ("subseteq", 0x2286), ("supseteq", 0x2287),
                   ("subsetneq", 0x228A), ("supsetneq", 0x228B), ("nsubseteq", 0x2288), ("nsupseteq", 0x2289),
                   ("sqsubset", 0x228F), ("sqsupset", 0x2290), ("sqsubseteq", 0x2291), ("sqsupseteq", 0x2292),
                   ("in", 0x2208), ("ni", 0x220B), ("owns", 0x220B), ("notin", 0x2209), ("vdash", 0x22A2),
                   ("dashv", 0x22A3), ("models", 0x22A8), ("mid", 0x2223), ("nmid", 0x2224), ("parallel", 0x2225),
                   ("nparallel", 0x2226), ("perp", 0x27C2), ("smile", 0x2323), ("frown", 0x2322), ("propto", 0x221D),
                   ("prec", 0x227A), ("succ", 0x227B), ("preceq", 0x2AAF), ("succeq", 0x2AB0), ("ll", 0x226A),
                   ("gg", 0x226B), ("lll", 0x22D8), ("ggg", 0x22D9), ("bowtie", 0x22C8), ("doteq", 0x2250),
                   ("coloneqq", 0x2254), ("eqqcolon", 0x2255), ("triangleq", 0x225C), ("approxeq", 0x224A),
                   ("leqslant", 0x2A7D), ("geqslant", 0x2A7E), ("lesssim", 0x2272), ("gtrsim", 0x2273),
                   ("nless", 0x226E), ("ngtr", 0x226F), ("nleq", 0x2270), ("ngeq", 0x2271), ("nsim", 0x2241),
                   ("ncong", 0x2247), ("to", 0x2192), ("rightarrow", 0x2192), ("leftarrow", 0x2190), ("gets", 0x2190),
                   ("leftrightarrow", 0x2194), ("Rightarrow", 0x21D2), ("Leftarrow", 0x21D0), ("Leftrightarrow", 0x21D4),
                   ("longrightarrow", 0x27F6), ("longleftarrow", 0x27F5), ("longleftrightarrow", 0x27F7),
                   ("Longrightarrow", 0x27F9), ("implies", 0x27F9), ("Longleftarrow", 0x27F8), ("impliedby", 0x27F8),
                   ("Longleftrightarrow", 0x27FA), ("iff", 0x27FA), ("mapsto", 0x21A6), ("longmapsto", 0x27FC),
                   ("uparrow", 0x2191), ("downarrow", 0x2193), ("updownarrow", 0x2195), ("Uparrow", 0x21D1),
                   ("Downarrow", 0x21D3), ("Updownarrow", 0x21D5), ("nearrow", 0x2197), ("searrow", 0x2198),
                   ("swarrow", 0x2199), ("nwarrow", 0x2196), ("hookrightarrow", 0x21AA), ("hookleftarrow", 0x21A9),
                   ("rightharpoonup", 0x21C0), ("rightharpoondown", 0x21C1), ("leftharpoonup", 0x21BC),
                   ("leftharpoondown", 0x21BD), ("rightleftharpoons", 0x21CC), ("leftrightarrows", 0x21C6),
                   ("rightleftarrows", 0x21C4), ("twoheadrightarrow", 0x21A0), ("rightsquigarrow", 0x21DD),
                   ("leadsto", 0x21DD), ("Vdash", 0x22A9), ("vDash", 0x22A8), ("nvdash", 0x22AC),
                   ("between", 0x226C), ("pitchfork", 0x22D4), ("therefore", 0x2234), ("because", 0x2235),
                   ("lhd", 0x22B2), ("rhd", 0x22B3), ("unlhd", 0x22B4), ("unrhd", 0x22B5),
                   ("vartriangleleft", 0x22B2), ("vartriangleright", 0x22B3), ("risingdotseq", 0x2253),
                   ("fallingdotseq", 0x2252), ("eqsim", 0x2242), ("backsim", 0x223D), ("circeq", 0x2257),
                   ("Subset", 0x22D0), ("Supset", 0x22D1), ("multimap", 0x22B8)])
        add(.punct, [("colon", 0x3A), ("ldotp", 0x2E), ("cdotp", 0x22C5)])
        let ops: [(String, UInt32, Bool)] = [
            ("sum", 0x2211, true), ("prod", 0x220F, true), ("coprod", 0x2210, true), ("int", 0x222B, false),
            ("iint", 0x222C, false), ("iiint", 0x222D, false), ("oint", 0x222E, false), ("oiint", 0x222F, false),
            ("bigcup", 0x22C3, true), ("bigcap", 0x22C2, true), ("bigvee", 0x22C1, true), ("bigwedge", 0x22C0, true),
            ("bigoplus", 0x2A01, true), ("bigotimes", 0x2A02, true), ("bigodot", 0x2A00, true), ("biguplus", 0x2A04, true),
            ("bigsqcup", 0x2A06, true), ("smallint", 0x222B, false),
        ]
        for (n, v, l) in ops { t[n] = .largeOp(Unicode.Scalar(v)!, limits: l) }
        for n in ["arccos", "arcsin", "arctan", "arg", "cos", "cosh", "cot", "coth", "csc", "deg", "dim", "exp", "hom",
                  "ker", "lg", "ln", "log", "sec", "sin", "sinh", "tan", "tanh", "sgn", "tr", "Tr", "rank", "diag", "span", "erf"] {
            t[n] = .namedOp(n, limits: false)
        }
        for n in ["det", "gcd", "inf", "lim", "liminf", "limsup", "max", "min", "Pr", "sup", "argmax", "argmin"] {
            let shown = ["liminf": "lim inf", "limsup": "lim sup", "argmax": "arg max", "argmin": "arg min"][n] ?? n
            t[n] = .namedOp(shown, limits: true)
        }
        let delimiters: [(String, UInt32, AtomType)] = [
            ("lbrace", 0x7B, .open), ("rbrace", 0x7D, .close), ("{", 0x7B, .open), ("}", 0x7D, .close),
            ("langle", 0x27E8, .open), ("rangle", 0x27E9, .close), ("lfloor", 0x230A, .open), ("rfloor", 0x230B, .close),
            ("lceil", 0x2308, .open), ("rceil", 0x2309, .close), ("vert", 0x7C, .ord), ("Vert", 0x2016, .ord),
            ("|", 0x2016, .ord), ("lvert", 0x7C, .open), ("rvert", 0x7C, .close), ("lVert", 0x2016, .open),
            ("rVert", 0x2016, .close), ("lbrack", 0x5B, .open), ("rbrack", 0x5D, .close), ("lgroup", 0x27EE, .open),
            ("rgroup", 0x27EF, .close), ("lmoustache", 0x23B0, .open), ("rmoustache", 0x23B1, .close),
            ("ulcorner", 0x231C, .open), ("urcorner", 0x231D, .close), ("llcorner", 0x231E, .open), ("lrcorner", 0x231F, .close),
        ]
        for (n, v, ty) in delimiters { t[n] = .delimiter(Unicode.Scalar(v)!, ty) }
        let accents: [(String, UInt32, Bool)] = [
            ("hat", 0x302, false), ("check", 0x30C, false), ("tilde", 0x303, false), ("acute", 0x301, false),
            ("grave", 0x300, false), ("dot", 0x307, false), ("ddot", 0x308, false), ("dddot", 0x20DB, false),
            ("breve", 0x306, false), ("bar", 0x304, false), ("vec", 0x20D7, false), ("mathring", 0x30A, false),
            ("widehat", 0x302, true), ("widetilde", 0x303, true), ("widecheck", 0x30C, true),
            ("overrightarrow", 0x2192, true), ("overleftarrow", 0x2190, true), ("overleftrightarrow", 0x2194, true),
        ]
        for (n, v, s) in accents { t[n] = .accent(Unicode.Scalar(v)!, stretchy: s) }
        let spaces: [(String, Double, SpaceUnit)] = [
            (",", 3, .mu), ("thinspace", 3, .mu), (":", 4, .mu), (">", 4, .mu), ("medspace", 4, .mu), (";", 5, .mu),
            ("thickspace", 5, .mu), ("!", -3, .mu), ("negthinspace", -3, .mu), ("negmedspace", -4, .mu),
            ("negthickspace", -5, .mu), ("quad", 1, .em), ("qquad", 2, .em), (" ", 1.0 / 3, .em), ("enspace", 0.5, .em),
            ("enskip", 0.5, .em),
        ]
        for (n, v, u) in spaces { t[n] = .space(v, unit: u) }
        let alphabets: [(String, MathAlphabet)] = [
            ("mathrm", .upright), ("mathup", .upright), ("mathbf", .bold), ("mathit", .italic), ("mathcal", .script),
            ("mathscr", .script), ("mathfrak", .fraktur), ("mathbb", .doubleStruck), ("mathsf", .sansSerif),
            ("mathtt", .monospace), ("boldsymbol", .boldItalic), ("bm", .boldItalic), ("mathbfit", .boldItalic),
            ("mathsfbf", .sansBold), ("Bbb", .doubleStruck), ("mathnormal", .italic),
        ]
        for (n, a) in alphabets { t[n] = .alphabet(a) }
        return t
    }()

    /// Characters typed directly: their atom type and the character set.
    static func classify(_ c: Unicode.Scalar) -> (Unicode.Scalar, AtomType) {
        switch c {
        case "+": return (c, .bin)
        case "-": return ("\u{2212}", .bin)
        case "*": return ("\u{2217}", .bin)
        case "=", "<", ">", ":": return (c, .rel)
        case ",", ";": return (c, .punct)
        case "(", "[": return (c, .open)
        case ")", "]", "!", "?": return (c, .close)
        default:
            switch c.value {
            case 0x2190...0x21FF, 0x2260...0x22A9, 0x2208...0x220D, 0x27F0...0x27FF, 0x2264, 0x2265: return (c, .rel)
            case 0x2211, 0x220F, 0x222B...0x2233: return (c, .op)
            case 0xB1, 0xD7, 0xF7, 0x2212, 0x2213, 0x2218, 0x2219, 0x2229, 0x222A, 0x2295...0x2299, 0x22C5: return (c, .bin)
            default: return (c, .ord)
            }
        }
    }
}
