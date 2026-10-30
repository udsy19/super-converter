import Foundation
import SuperConverterCore

/// Parsers for the value grammars of SVG: colours, numbers and lengths, transform lists, path data, and a CSS subset.
enum SVGValues {
    // MARK: Numbers and lengths

    /// A scanner over an attribute value, used by the number-list and path parsers.
    struct Scanner {
        let chars: [UInt8]
        var pos = 0
        init(_ text: String) { chars = Array(text.utf8) }
        var atEnd: Bool { pos >= chars.count }

        mutating func skipSeparators() {
            while pos < chars.count, chars[pos] == 0x20 || chars[pos] == 0x2c || chars[pos] == 0x09 || chars[pos] == 0x0a || chars[pos] == 0x0d { pos += 1 }
        }
        mutating func skipSpace() {
            while pos < chars.count, chars[pos] == 0x20 || chars[pos] == 0x09 || chars[pos] == 0x0a || chars[pos] == 0x0d { pos += 1 }
        }
        var peek: UInt8? { pos < chars.count ? chars[pos] : nil }

        /// A number per the SVG grammar (sign, digits, fraction, exponent); nil when none starts here.
        mutating func number() -> Double? {
            skipSeparators()
            let start = pos
            var p = pos
            if p < chars.count, chars[p] == 0x2b || chars[p] == 0x2d { p += 1 }
            var digits = 0
            while p < chars.count, chars[p] >= 0x30, chars[p] <= 0x39 { p += 1; digits += 1 }
            if p < chars.count, chars[p] == 0x2e {
                p += 1
                while p < chars.count, chars[p] >= 0x30, chars[p] <= 0x39 { p += 1; digits += 1 }
            }
            guard digits > 0 else { return nil }
            if p < chars.count, chars[p] == 0x65 || chars[p] == 0x45 {
                var q = p + 1
                if q < chars.count, chars[q] == 0x2b || chars[q] == 0x2d { q += 1 }
                if q < chars.count, chars[q] >= 0x30, chars[q] <= 0x39 {
                    while q < chars.count, chars[q] >= 0x30, chars[q] <= 0x39 { q += 1 }
                    p = q
                }
            }
            pos = p
            return Double(String(decoding: chars[start..<p], as: UTF8.self))
        }

        /// A single 0/1 arc flag (may be written without separators).
        mutating func flag() -> Bool? {
            skipSeparators()
            guard let c = peek, c == 0x30 || c == 0x31 else { return nil }
            pos += 1
            return c == 0x31
        }
    }

    static func numberList(_ text: String?) -> [Double] {
        guard let text else { return [] }
        var s = Scanner(text)
        var out: [Double] = []
        while let n = s.number() { out.append(n) }
        return out
    }

    /// A length with its unit.
    struct Length {
        var value: Double
        var unit: String
        var isPercent: Bool { unit == "%" }
    }

    static func length(_ text: String?) -> Length? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        var s = Scanner(text)
        guard let n = s.number() else { return nil }
        let unit = String(decoding: s.chars[s.pos...], as: UTF8.self).trimmingCharacters(in: .whitespaces).lowercased()
        return Length(value: n, unit: unit)
    }

    // MARK: Transforms

    static func transform(_ text: String?) -> VectorTransform {
        guard let text, !text.isEmpty else { return .identity }
        var result = VectorTransform.identity
        var s = Scanner(text)
        while true {
            s.skipSeparators()
            guard !s.atEnd else { break }
            var name = ""
            while let c = s.peek, (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) { name.append(Character(UnicodeScalar(c))); s.pos += 1 }
            s.skipSpace()
            guard !name.isEmpty, s.peek == 0x28 else { return result }
            s.pos += 1
            var args: [Double] = []
            while true {
                s.skipSeparators()
                if s.peek == 0x29 { s.pos += 1; break }
                guard let n = s.number() else { return result }
                // CSS angle/length units in `transform` property values.
                if let c = s.peek, c >= 0x61, c <= 0x7a {
                    var unit = ""
                    while let u = s.peek, u >= 0x61, u <= 0x7a { unit.append(Character(UnicodeScalar(u))); s.pos += 1 }
                    args.append(unit == "rad" ? n * 180 / .pi : unit == "turn" ? n * 360 : unit == "grad" ? n * 0.9 : n)
                } else { args.append(n) }
            }
            var t = VectorTransform.identity
            switch (name, args.count) {
            case ("matrix", 6): t = VectorTransform(a: args[0], b: args[1], c: args[2], d: args[3], tx: args[4], ty: args[5])
            case ("translate", 1): t = .translation(args[0], 0)
            case ("translate", 2): t = .translation(args[0], args[1])
            case ("translateX", 1): t = .translation(args[0], 0)
            case ("translateY", 1): t = .translation(0, args[0])
            case ("scale", 1): t = .scale(args[0], args[0])
            case ("scale", 2): t = .scale(args[0], args[1])
            case ("scaleX", 1): t = .scale(args[0], 1)
            case ("scaleY", 1): t = .scale(1, args[0])
            case ("rotate", 1), ("rotate", 3):
                let r = args[0] * .pi / 180
                t = VectorTransform(a: cos(r), b: sin(r), c: -sin(r), d: cos(r), tx: 0, ty: 0)
                if args.count == 3 { t = VectorTransform.translation(-args[1], -args[2]).then(t).then(.translation(args[1], args[2])) }
            case ("skewX", 1), ("skew", 1): t = VectorTransform(a: 1, b: 0, c: tan(args[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case ("skewY", 1): t = VectorTransform(a: 1, b: tan(args[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: return result
            }
            // The list is written outermost first: `a b` means a(b(x)), so each new item applies before the earlier ones.
            result = t.then(result)
        }
        return result
    }

    // MARK: Colours

    static func colour(_ text: String, currentColour: VectorColour = .black) -> VectorColour? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.isEmpty { return nil }
        if t == "currentcolor" { return currentColour }
        if t == "transparent" { return VectorColour(red: 0, green: 0, blue: 0, alpha: 0) }
        if t.hasPrefix("#") {
            let hex = Array(t.dropFirst())
            func v(_ s: ArraySlice<Character>) -> Double? { Int(String(s), radix: 16).map(Double.init) }
            switch hex.count {
            case 3, 4:
                guard let r = v(hex[0...0]), let g = v(hex[1...1]), let b = v(hex[2...2]) else { return nil }
                let a = hex.count == 4 ? (v(hex[3...3]) ?? 15) : 15
                return VectorColour(red: r / 15, green: g / 15, blue: b / 15, alpha: a / 15)
            case 6, 8:
                guard let r = v(hex[0...1]), let g = v(hex[2...3]), let b = v(hex[4...5]) else { return nil }
                let a = hex.count == 8 ? (v(hex[6...7]) ?? 255) : 255
                return VectorColour(red: r / 255, green: g / 255, blue: b / 255, alpha: a / 255)
            default: return nil
            }
        }
        if let open = t.firstIndex(of: "("), t.hasSuffix(")") {
            let fn = t[..<open].trimmingCharacters(in: .whitespaces)
            let inner = String(t[t.index(after: open)..<t.index(before: t.endIndex)])
            let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init).filter { !$0.isEmpty }
            func component(_ p: String, scale: Double) -> Double? {
                if p.hasSuffix("%") { return Double(p.dropLast()).map { $0 / 100 } }
                return Double(p).map { $0 / scale }
            }
            switch fn {
            case "rgb", "rgba":
                guard parts.count >= 3, let r = component(parts[0], scale: 255), let g = component(parts[1], scale: 255),
                      let b = component(parts[2], scale: 255) else { return nil }
                let a = parts.count > 3 ? (component(parts[3], scale: 1) ?? 1) : 1
                return VectorColour(red: clamp(r), green: clamp(g), blue: clamp(b), alpha: clamp(a))
            case "hsl", "hsla":
                guard parts.count >= 3, let h = Double(parts[0].replacingOccurrences(of: "deg", with: "")),
                      let s = component(parts[1], scale: 100), let l = component(parts[2], scale: 100) else { return nil }
                let a = parts.count > 3 ? (component(parts[3], scale: 1) ?? 1) : 1
                let (r, g, b) = hsl(h, clamp(s), clamp(l))
                return VectorColour(red: r, green: g, blue: b, alpha: clamp(a))
            default: return nil
            }
        }
        if let named = namedColours[t] {
            return VectorColour(red: Double((named >> 16) & 255) / 255, green: Double((named >> 8) & 255) / 255, blue: Double(named & 255) / 255)
        }
        return nil
    }

    static func clamp(_ v: Double) -> Double { max(0, min(1, v)) }

    private static func hsl(_ hDeg: Double, _ s: Double, _ l: Double) -> (Double, Double, Double) {
        let h = (hDeg.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(h + 1.0 / 3), channel(h), channel(h - 1.0 / 3))
    }

    static let namedColours: [String: Int] = [
        "aliceblue": 0xf0f8ff, "antiquewhite": 0xfaebd7, "aqua": 0x00ffff, "aquamarine": 0x7fffd4, "azure": 0xf0ffff,
        "beige": 0xf5f5dc, "bisque": 0xffe4c4, "black": 0x000000, "blanchedalmond": 0xffebcd, "blue": 0x0000ff,
        "blueviolet": 0x8a2be2, "brown": 0xa52a2a, "burlywood": 0xdeb887, "cadetblue": 0x5f9ea0, "chartreuse": 0x7fff00,
        "chocolate": 0xd2691e, "coral": 0xff7f50, "cornflowerblue": 0x6495ed, "cornsilk": 0xfff8dc, "crimson": 0xdc143c,
        "cyan": 0x00ffff, "darkblue": 0x00008b, "darkcyan": 0x008b8b, "darkgoldenrod": 0xb8860b, "darkgray": 0xa9a9a9,
        "darkgreen": 0x006400, "darkgrey": 0xa9a9a9, "darkkhaki": 0xbdb76b, "darkmagenta": 0x8b008b, "darkolivegreen": 0x556b2f,
        "darkorange": 0xff8c00, "darkorchid": 0x9932cc, "darkred": 0x8b0000, "darksalmon": 0xe9967a, "darkseagreen": 0x8fbc8f,
        "darkslateblue": 0x483d8b, "darkslategray": 0x2f4f4f, "darkslategrey": 0x2f4f4f, "darkturquoise": 0x00ced1,
        "darkviolet": 0x9400d3, "deeppink": 0xff1493, "deepskyblue": 0x00bfff, "dimgray": 0x696969, "dimgrey": 0x696969,
        "dodgerblue": 0x1e90ff, "firebrick": 0xb22222, "floralwhite": 0xfffaf0, "forestgreen": 0x228b22, "fuchsia": 0xff00ff,
        "gainsboro": 0xdcdcdc, "ghostwhite": 0xf8f8ff, "gold": 0xffd700, "goldenrod": 0xdaa520, "gray": 0x808080,
        "grey": 0x808080, "green": 0x008000, "greenyellow": 0xadff2f, "honeydew": 0xf0fff0, "hotpink": 0xff69b4,
        "indianred": 0xcd5c5c, "indigo": 0x4b0082, "ivory": 0xfffff0, "khaki": 0xf0e68c, "lavender": 0xe6e6fa,
        "lavenderblush": 0xfff0f5, "lawngreen": 0x7cfc00, "lemonchiffon": 0xfffacd, "lightblue": 0xadd8e6, "lightcoral": 0xf08080,
        "lightcyan": 0xe0ffff, "lightgoldenrodyellow": 0xfafad2, "lightgray": 0xd3d3d3, "lightgreen": 0x90ee90,
        "lightgrey": 0xd3d3d3, "lightpink": 0xffb6c1, "lightsalmon": 0xffa07a, "lightseagreen": 0x20b2aa, "lightskyblue": 0x87cefa,
        "lightslategray": 0x778899, "lightslategrey": 0x778899, "lightsteelblue": 0xb0c4de, "lightyellow": 0xffffe0,
        "lime": 0x00ff00, "limegreen": 0x32cd32, "linen": 0xfaf0e6, "magenta": 0xff00ff, "maroon": 0x800000,
        "mediumaquamarine": 0x66cdaa, "mediumblue": 0x0000cd, "mediumorchid": 0xba55d3, "mediumpurple": 0x9370db,
        "mediumseagreen": 0x3cb371, "mediumslateblue": 0x7b68ee, "mediumspringgreen": 0x00fa9a, "mediumturquoise": 0x48d1cc,
        "mediumvioletred": 0xc71585, "midnightblue": 0x191970, "mintcream": 0xf5fffa, "mistyrose": 0xffe4e1, "moccasin": 0xffe4b5,
        "navajowhite": 0xffdead, "navy": 0x000080, "oldlace": 0xfdf5e6, "olive": 0x808000, "olivedrab": 0x6b8e23,
        "orange": 0xffa500, "orangered": 0xff4500, "orchid": 0xda70d6, "palegoldenrod": 0xeee8aa, "palegreen": 0x98fb98,
        "paleturquoise": 0xafeeee, "palevioletred": 0xdb7093, "papayawhip": 0xffefd5, "peachpuff": 0xffdab9, "peru": 0xcd853f,
        "pink": 0xffc0cb, "plum": 0xdda0dd, "powderblue": 0xb0e0e6, "purple": 0x800080, "rebeccapurple": 0x663399, "red": 0xff0000,
        "rosybrown": 0xbc8f8f, "royalblue": 0x4169e1, "saddlebrown": 0x8b4513, "salmon": 0xfa8072, "sandybrown": 0xf4a460,
        "seagreen": 0x2e8b57, "seashell": 0xfff5ee, "sienna": 0xa0522d, "silver": 0xc0c0c0, "skyblue": 0x87ceeb,
        "slateblue": 0x6a5acd, "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xfffafa, "springgreen": 0x00ff7f,
        "steelblue": 0x4682b4, "tan": 0xd2b48c, "teal": 0x008080, "thistle": 0xd8bfd8, "tomato": 0xff6347,
        "turquoise": 0x40e0d0, "violet": 0xee82ee, "wheat": 0xf5deb3, "white": 0xffffff, "whitesmoke": 0xf5f5f5,
        "yellow": 0xffff00, "yellowgreen": 0x9acd32,
    ]

    // MARK: Path data

    /// Parses path data into absolute segments; on a syntax error the path up to the error is kept (SVG error handling).
    static func pathData(_ text: String) -> [PathSegment] {
        var s = Scanner(text)
        var out: [PathSegment] = []
        var cur = VectorPoint(0, 0), start = VectorPoint(0, 0)
        var lastCubicControl: VectorPoint?, lastQuadControl: VectorPoint?
        var command: UInt8 = 0
        var first = true

        func isCommand(_ c: UInt8) -> Bool { "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c) }

        while true {
            s.skipSeparators()
            guard let c = s.peek else { break }
            if isCommand(c) { command = c; s.pos += 1 }
            else if command == 0 || command == 0x5a || command == 0x7a { break }
            else if command == 0x4d { command = 0x4c } else if command == 0x6d { command = 0x6c }
            if first, command != 0x4d, command != 0x6d { break }
            first = false
            let rel = command >= 0x61
            let upper = rel ? command - 0x20 : command
            func p(_ x: Double, _ y: Double) -> VectorPoint { rel ? VectorPoint(cur.x + x, cur.y + y) : VectorPoint(x, y) }
            switch upper {
            case 0x4d: // M
                guard let x = s.number(), let y = s.number() else { return out }
                cur = p(x, y); start = cur
                out.append(.move(cur)); lastCubicControl = nil; lastQuadControl = nil
            case 0x4c: // L
                guard let x = s.number(), let y = s.number() else { return out }
                cur = p(x, y); out.append(.line(cur)); lastCubicControl = nil; lastQuadControl = nil
            case 0x48: // H
                guard let x = s.number() else { return out }
                cur = VectorPoint(rel ? cur.x + x : x, cur.y); out.append(.line(cur)); lastCubicControl = nil; lastQuadControl = nil
            case 0x56: // V
                guard let y = s.number() else { return out }
                cur = VectorPoint(cur.x, rel ? cur.y + y : y); out.append(.line(cur)); lastCubicControl = nil; lastQuadControl = nil
            case 0x43: // C
                guard let x1 = s.number(), let y1 = s.number(), let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { return out }
                let c1 = p(x1, y1), c2 = p(x2, y2), e = p(x, y)
                out.append(.cubic(c1, c2, e)); lastCubicControl = c2; lastQuadControl = nil; cur = e
            case 0x53: // S
                guard let x2 = s.number(), let y2 = s.number(), let x = s.number(), let y = s.number() else { return out }
                let c1 = lastCubicControl.map { VectorPoint(2 * cur.x - $0.x, 2 * cur.y - $0.y) } ?? cur
                let c2 = p(x2, y2), e = p(x, y)
                out.append(.cubic(c1, c2, e)); lastCubicControl = c2; lastQuadControl = nil; cur = e
            case 0x51: // Q
                guard let x1 = s.number(), let y1 = s.number(), let x = s.number(), let y = s.number() else { return out }
                let c1 = p(x1, y1), e = p(x, y)
                out.append(.quad(c1, e)); lastQuadControl = c1; lastCubicControl = nil; cur = e
            case 0x54: // T
                guard let x = s.number(), let y = s.number() else { return out }
                let c1 = lastQuadControl.map { VectorPoint(2 * cur.x - $0.x, 2 * cur.y - $0.y) } ?? cur
                let e = p(x, y)
                out.append(.quad(c1, e)); lastQuadControl = c1; lastCubicControl = nil; cur = e
            case 0x41: // A
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(), let large = s.flag(), let sweep = s.flag(),
                      let x = s.number(), let y = s.number() else { return out }
                let e = p(x, y)
                let arcs = PathBuilder.arc(from: cur, to: e, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                if arcs.isEmpty, e != cur { out.append(.line(e)) } else { out.append(contentsOf: arcs) }
                cur = e; lastCubicControl = nil; lastQuadControl = nil
            case 0x5a: // Z
                out.append(.close); cur = start; lastCubicControl = nil; lastQuadControl = nil
            default: return out
            }
        }
        return out
    }

    // MARK: CSS

    struct Declaration { var name: String; var value: String; var important: Bool }

    /// `fill:red; stroke : blue !important` → declarations.
    static func declarations(_ text: String) -> [Declaration] {
        var out: [Declaration] = []
        var depth = 0
        var current = ""
        var parts: [String] = []
        for ch in text {
            if ch == "(" { depth += 1 } else if ch == ")" { depth = max(0, depth - 1) }
            if ch == ";", depth == 0 { parts.append(current); current = "" } else { current.append(ch) }
        }
        parts.append(current)
        for part in parts {
            guard let colon = part.firstIndex(of: ":") else { continue }
            let name = part[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = part[part.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var important = false
            if let range = value.range(of: "!important", options: .caseInsensitive) { value = value[..<range.lowerBound].trimmingCharacters(in: .whitespaces); important = true }
            if !name.isEmpty, !value.isEmpty { out.append(Declaration(name: name, value: value, important: important)) }
        }
        return out
    }

    /// One compound selector step: `rect.a#b[fill=red]:first-child`.
    struct SimpleSelector {
        var tag: String?
        var ids: [String] = []
        var classes: [String] = []
        var attributes: [(name: String, value: String?)] = []
        var firstChild = false
    }

    struct Rule {
        /// A chain from the leftmost ancestor selector to the subject, with the combinator that joins each to the next.
        var chain: [(selector: SimpleSelector, combinator: Character)]
        var declarations: [Declaration]
        var specificity: Int
        var order: Int
    }

    static func stylesheet(_ css: String, startOrder: Int = 0) -> [Rule] {
        var text = css
        while let open = text.range(of: "/*"), let close = text.range(of: "*/", range: open.upperBound..<text.endIndex) { text.removeSubrange(open.lowerBound..<close.upperBound) }
        var rules: [Rule] = []
        var i = text.startIndex
        var order = startOrder
        while i < text.endIndex {
            guard let open = text[i...].firstIndex(of: "{") else { break }
            let selectorText = text[i..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip at-rule blocks (media queries, font-face, keyframes) including nested braces.
            var depth = 1
            var j = text.index(after: open)
            while j < text.endIndex, depth > 0 { if text[j] == "{" { depth += 1 } else if text[j] == "}" { depth -= 1 }; j = text.index(after: j) }
            // An unterminated block (the sheet ends inside it) runs to the end; otherwise it ends before its `}`.
            let body = String(text[text.index(after: open)..<(depth > 0 ? j : text.index(before: j))])
            i = j
            if selectorText.hasPrefix("@") { continue }
            let decls = declarations(body)
            for part in selectorText.split(separator: ",") {
                guard let chain = parseSelector(String(part)) else { continue }
                var spec = 0
                for step in chain { spec += step.selector.ids.count * 10000 + (step.selector.classes.count + step.selector.attributes.count + (step.selector.firstChild ? 1 : 0)) * 100 + (step.selector.tag == nil ? 0 : 1) }
                rules.append(Rule(chain: chain, declarations: decls, specificity: spec, order: order)); order += 1
            }
        }
        return rules
    }

    static func parseSelector(_ text: String) -> [(selector: SimpleSelector, combinator: Character)]? {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var chain: [(selector: SimpleSelector, combinator: Character)] = []
        var i = 0
        func skipSpaces() { while i < chars.count, chars[i].isWhitespace { i += 1 } }
        skipSpaces()
        while i < chars.count {
            var compound = SimpleSelector()
            var any = false
            var token = ""
            var kind: Character = "t"
            func flush() {
                guard !token.isEmpty else { return }
                switch kind {
                case "#": compound.ids.append(token)
                case ".": compound.classes.append(token)
                default: compound.tag = token == "*" ? nil : token
                }
                token = ""; any = true
            }
            while i < chars.count, !chars[i].isWhitespace, !">+~".contains(chars[i]) {
                let c = chars[i]
                if c == "#" || c == "." { flush(); kind = c }
                else if c == "[" {
                    flush(); kind = "t"
                    guard let close = chars[i...].firstIndex(of: "]") else { return nil }
                    let inner = String(chars[(i + 1)..<close])
                    if let eq = inner.firstIndex(of: "=") {
                        let name = String(inner[..<eq]).trimmingCharacters(in: .whitespaces)
                        let value = String(inner[inner.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                        compound.attributes.append((name, value))
                    } else { compound.attributes.append((inner.trimmingCharacters(in: .whitespaces), nil)) }
                    any = true; i = close
                } else if c == ":" {
                    flush(); kind = "t"
                    var pseudo = ""
                    i += 1
                    while i < chars.count, chars[i].isLetter || chars[i] == "-" { pseudo.append(chars[i]); i += 1 }
                    i -= 1
                    if pseudo == "first-child" { compound.firstChild = true } else if pseudo != "root" { return nil }
                    any = true
                } else { token.append(c) }
                i += 1
            }
            flush()
            guard any else { return nil }
            skipSpaces()
            var combinator: Character = " "
            if i < chars.count, ">+~".contains(chars[i]) { combinator = chars[i]; i += 1; skipSpaces() }
            chain.append((compound, combinator))
        }
        return chain.isEmpty ? nil : chain
    }

    static func matches(_ step: SimpleSelector, _ node: XNode) -> Bool {
        if let tag = step.tag, tag != node.name { return false }
        if !step.ids.allSatisfy({ node.attr("id") == $0 }) { return false }
        if !step.classes.isEmpty {
            let have = Set((node.attr("class") ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init))
            if !step.classes.allSatisfy(have.contains) { return false }
        }
        for (name, value) in step.attributes {
            guard let actual = node.attr(name) else { return false }
            if let value, actual != value { return false }
        }
        if step.firstChild, node.parent?.children.first !== node { return false }
        return true
    }

    static func matches(_ rule: Rule, _ node: XNode) -> Bool {
        var idx = rule.chain.count - 1
        guard matches(rule.chain[idx].selector, node) else { return false }
        var current = node
        while idx > 0 {
            idx -= 1
            let combinator = rule.chain[idx].combinator
            let step = rule.chain[idx].selector
            switch combinator {
            case ">":
                guard let parent = current.parent, matches(step, parent) else { return false }
                current = parent
            case "+":
                guard let parent = current.parent, let at = parent.children.firstIndex(where: { $0 === current }), at > 0, matches(step, parent.children[at - 1]) else { return false }
                current = parent.children[at - 1]
            case "~":
                guard let parent = current.parent, let at = parent.children.firstIndex(where: { $0 === current }),
                      let hit = parent.children[..<at].last(where: { matches(step, $0) }) else { return false }
                current = hit
            default:
                var ancestor = current.parent
                while let a = ancestor, !matches(step, a) { ancestor = a.parent }
                guard let found = ancestor else { return false }
                current = found
            }
        }
        return true
    }
}
