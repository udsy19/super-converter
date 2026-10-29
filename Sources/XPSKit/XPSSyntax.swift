import Foundation
import SuperConverterCore
import VectorKit

/// The value grammars of XPS markup: numbers, the path mini-language, colours, matrices, point lists, GUID part names.
enum XPSSyntax {
    struct Scanner {
        let chars: [UInt8]
        var pos = 0
        init(_ text: String) { chars = Array(text.utf8) }
        var atEnd: Bool { pos >= chars.count }
        var peek: UInt8? { pos < chars.count ? chars[pos] : nil }

        mutating func skipSeparators() {
            while pos < chars.count, chars[pos] == 0x20 || chars[pos] == 0x2c || chars[pos] == 0x09 || chars[pos] == 0x0a || chars[pos] == 0x0d { pos += 1 }
        }

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
            guard let v = Double(String(decoding: chars[start..<p], as: UTF8.self)), v.isFinite else { return nil }
            return v
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard let c = peek, c == 0x30 || c == 0x31 else { return nil }
            pos += 1
            return c == 0x31
        }
    }

    static func numbers(_ text: String?) -> [Double] {
        guard let text else { return [] }
        var s = Scanner(text)
        var out: [Double] = []
        while let n = s.number() { out.append(n) }
        return out
    }

    static func points(_ text: String?) -> [VectorPoint] {
        let n = numbers(text)
        return stride(from: 0, to: n.count - 1, by: 2).map { VectorPoint(n[$0], n[$0 + 1]) }
    }

    /// `m11,m12,m21,m22,offsetX,offsetY` (also "Identity").
    static func matrix(_ text: String?) -> VectorTransform? {
        guard let text else { return nil }
        let n = numbers(text)
        guard n.count == 6 else { return nil }
        return VectorTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
    }

    /// The fill rule and segments of the path mini-language; a syntax error keeps what was read before it.
    static func pathData(_ text: String) -> (rule: FillRule, segments: [PathSegment]) {
        var s = Scanner(text)
        var rule = FillRule.evenOdd
        s.skipSeparators()
        if let c = s.peek, c == 0x46 || c == 0x66 {
            s.pos += 1
            if let flag = s.flag() { rule = flag ? .nonZero : .evenOdd }
        }
        var out: [PathSegment] = []
        var cur = VectorPoint(0, 0), start = VectorPoint(0, 0)
        var lastCubic: VectorPoint?, lastQuad: VectorPoint?
        var command: UInt8 = 0
        func isCommand(_ c: UInt8) -> Bool { "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c) }
        while true {
            s.skipSeparators()
            guard let c = s.peek else { break }
            if isCommand(c) { command = c; s.pos += 1 }
            else if command == 0 || command == 0x5a || command == 0x7a { break }
            else if command == 0x4d { command = 0x4c } else if command == 0x6d { command = 0x6c }
            let rel = command >= 0x61
            let upper = rel ? command - 0x20 : command
            func p(_ x: Double, _ y: Double) -> VectorPoint { rel ? VectorPoint(cur.x + x, cur.y + y) : VectorPoint(x, y) }
            switch upper {
            case 0x4d:
                guard let x = s.number(), let y = s.number() else { return (rule, out) }
                cur = p(x, y); start = cur; out.append(.move(cur)); lastCubic = nil; lastQuad = nil
            case 0x4c:
                guard let x = s.number(), let y = s.number() else { return (rule, out) }
                cur = p(x, y); out.append(.line(cur)); lastCubic = nil; lastQuad = nil
            case 0x48:
                guard let x = s.number() else { return (rule, out) }
                cur = VectorPoint(rel ? cur.x + x : x, cur.y); out.append(.line(cur)); lastCubic = nil; lastQuad = nil
            case 0x56:
                guard let y = s.number() else { return (rule, out) }
                cur = VectorPoint(cur.x, rel ? cur.y + y : y); out.append(.line(cur)); lastCubic = nil; lastQuad = nil
            case 0x43:
                guard let a = s.number(), let b = s.number(), let c2 = s.number(), let d = s.number(), let x = s.number(), let y = s.number() else { return (rule, out) }
                let e = p(x, y), cc = p(c2, d)
                out.append(.cubic(p(a, b), cc, e)); lastCubic = cc; lastQuad = nil; cur = e
            case 0x53:
                guard let c2 = s.number(), let d = s.number(), let x = s.number(), let y = s.number() else { return (rule, out) }
                let c1 = lastCubic.map { VectorPoint(2 * cur.x - $0.x, 2 * cur.y - $0.y) } ?? cur
                let cc = p(c2, d), e = p(x, y)
                out.append(.cubic(c1, cc, e)); lastCubic = cc; lastQuad = nil; cur = e
            case 0x51:
                guard let a = s.number(), let b = s.number(), let x = s.number(), let y = s.number() else { return (rule, out) }
                let c1 = p(a, b), e = p(x, y)
                out.append(.quad(c1, e)); lastQuad = c1; lastCubic = nil; cur = e
            case 0x54:
                guard let x = s.number(), let y = s.number() else { return (rule, out) }
                let c1 = lastQuad.map { VectorPoint(2 * cur.x - $0.x, 2 * cur.y - $0.y) } ?? cur
                let e = p(x, y)
                out.append(.quad(c1, e)); lastQuad = c1; lastCubic = nil; cur = e
            case 0x41:
                guard let rx = s.number(), let ry = s.number(), let rot = s.number(), let large = s.flag(), let sweep = s.flag(), let x = s.number(), let y = s.number() else { return (rule, out) }
                let e = p(x, y)
                let arcs = PathBuilder.arc(from: cur, to: e, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                if arcs.isEmpty, e != cur { out.append(.line(e)) } else { out.append(contentsOf: arcs) }
                cur = e; lastCubic = nil; lastQuad = nil
            default:
                out.append(.close); cur = start; lastCubic = nil; lastQuad = nil
            }
        }
        return (rule, out)
    }

    // MARK: Colours

    static func srgbEncode(_ v: Double) -> Double {
        let x = min(max(v, 0), 1)
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    /// `#RGB`-style hex (`#AARRGGBB`, `#RRGGBB`), `sc#a,r,g,b` (scRGB, linear), or `ContextColor /part.icc a,c1,c2,c3`.
    /// The ICC profile is not applied: the flag says the colour was approximated.
    static func colour(_ text: String) -> (colour: VectorColour, approximated: Bool)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("sc#") {
            let n = numbers(String(t.dropFirst(3)))
            if n.count == 3 { return (VectorColour(red: srgbEncode(n[0]), green: srgbEncode(n[1]), blue: srgbEncode(n[2])), false) }
            if n.count >= 4 { return (VectorColour(red: srgbEncode(n[1]), green: srgbEncode(n[2]), blue: srgbEncode(n[3]), alpha: min(max(n[0], 0), 1)), false) }
            return nil
        }
        if t.hasPrefix("#") {
            let hex = Array(t.dropFirst())
            func v(_ r: Range<Int>) -> Double? { Int(String(hex[r]), radix: 16).map(Double.init) }
            switch hex.count {
            case 6:
                guard let r = v(0..<2), let g = v(2..<4), let b = v(4..<6) else { return nil }
                return (VectorColour(red: r / 255, green: g / 255, blue: b / 255), false)
            case 8:
                guard let a = v(0..<2), let r = v(2..<4), let g = v(4..<6), let b = v(6..<8) else { return nil }
                return (VectorColour(red: r / 255, green: g / 255, blue: b / 255, alpha: a / 255), false)
            default: return nil
            }
        }
        if t.hasPrefix("ContextColor") {
            let parts = t.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            let n = numbers(parts[2])
            guard n.count >= 2 else { return nil }
            let alpha = min(max(n[0], 0), 1), c = Array(n.dropFirst())
            let colour: VectorColour
            switch c.count {
            case 1: colour = VectorColour(red: c[0], green: c[0], blue: c[0], alpha: alpha)
            case 3: colour = VectorColour(red: c[0], green: c[1], blue: c[2], alpha: alpha)
            case 4: colour = VectorColour(red: (1 - c[0]) * (1 - c[3]), green: (1 - c[1]) * (1 - c[3]), blue: (1 - c[2]) * (1 - c[3]), alpha: alpha)
            default: colour = VectorColour(red: 0, green: 0, blue: 0, alpha: alpha)
            }
            return (colour, true)
        }
        return nil
    }

    // MARK: Obfuscated fonts

    /// The 16 key bytes for an obfuscated font part named `{GUID}.odttf`; nil when the name is not a GUID.
    static func obfuscationKey(partName: String) -> [UInt8]? {
        let stem = (partName as NSString).lastPathComponent.split(separator: ".").first.map(String.init) ?? ""
        let hex = stem.filter { $0 != "-" && $0 != "{" && $0 != "}" }
        guard hex.count == 32 else { return nil }
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        return bytes.reversed()
    }

    /// XORs the first 32 bytes with the key (the operation is its own inverse).
    static func xorFont(_ data: Data, key: [UInt8]) -> Data {
        var out = data
        for i in 0..<min(32, out.count) { out[out.startIndex + i] ^= key[i % 16] }
        return out
    }

    /// Resolves a part reference against the part that contains it.
    static func resolve(_ target: String, base: String) -> String {
        var t = target
        if let hash = t.firstIndex(of: "#") { t = String(t[..<hash]) }
        if let q = t.firstIndex(of: "?") { t = String(t[..<q]) }
        t = t.removingPercentEncoding ?? t
        var parts: [Substring]
        if t.hasPrefix("/") { parts = [] } else { parts = base.split(separator: "/").dropLast().map { $0 } }
        for piece in t.split(separator: "/") {
            if piece == "." { continue }
            if piece == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(piece) }
        }
        return "/" + parts.joined(separator: "/")
    }
}
