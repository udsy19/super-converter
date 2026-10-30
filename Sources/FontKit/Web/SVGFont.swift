import Foundation
import SuperConverterCore

/// SVG 1.1 fonts (`<font>`, `<font-face>`, `<missing-glyph>`, `<glyph d="…">`), both ways. Glyph paths are in font units with
/// y pointing up. Kerning (`hkern`/`vkern`) and ligature glyphs are not carried.
enum SVGFont {
    // MARK: Writing

    static func write(_ model: FontModel) -> [UInt8] {
        var out = """
        <?xml version="1.0" standalone="no"?>
        <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
        <svg xmlns="http://www.w3.org/2000/svg" version="1.1">
        <defs>

        """
        let id = escape(SFNTWriter.postScriptName(model))
        let defaultAdvance = model.glyphs.dropFirst().first?.advance ?? model.unitsPerEm
        let style = model.styleName.lowercased()
        let weight = style.contains("bold") ? 700 : 400
        let italic = style.contains("italic") || style.contains("oblique")
        out += "<font id=\"\(id)\" horiz-adv-x=\"\(defaultAdvance)\">\n"
        out += "<font-face font-family=\"\(escape(model.familyName))\" font-weight=\"\(weight)\" font-style=\"\(italic ? "italic" : "normal")\" "
        out += "units-per-em=\"\(model.unitsPerEm)\" ascent=\"\(model.ascent)\" descent=\"\(model.descent)\" />\n"
        if let notdef = model.glyphs.first {
            out += "<missing-glyph horiz-adv-x=\"\(notdef.advance)\"\(pathAttribute(notdef, model.outlineKind)) />\n"
        }
        var codes: [Int: [UInt32]] = [:]
        for (code, g) in model.characterMap where g > 0 && g < model.glyphs.count { codes[g, default: []].append(code) }
        for g in 1..<max(model.glyphs.count, 1) {
            guard let list = codes[g] else { continue }
            let glyph = model.glyphs[g]
            for code in list.sorted() {
                guard let scalar = Unicode.Scalar(code), isXMLChar(code) else { continue }
                out += "<glyph glyph-name=\"\(escape(glyph.name))\" unicode=\"\(escape(String(Character(scalar))))\" horiz-adv-x=\"\(glyph.advance)\"\(pathAttribute(glyph, model.outlineKind)) />\n"
            }
        }
        out += "</font>\n</defs>\n</svg>\n"
        return Array(out.utf8)
    }

    private static func isXMLChar(_ c: UInt32) -> Bool {
        c == 9 || c == 10 || c == 13 || (c >= 0x20 && c <= 0xD7FF) || (c >= 0xE000 && c <= 0xFFFD) || (c >= 0x10000 && c <= 0x10FFFF)
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                if u.value < 0x20 || (u.value >= 0x7F && u.value < 0xA0) { out += "&#x\(String(u.value, radix: 16, uppercase: true));" } else { out.unicodeScalars.append(u) }
            }
        }
        return out
    }

    private static func number(_ v: Double) -> String {
        let r = (v * 1000).rounded() / 1000
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.3f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    private static func pathAttribute(_ glyph: FontModel.Glyph, _ kind: FontModel.OutlineKind) -> String {
        var d = ""
        for contour in glyph.contours {
            guard let path = Outlines.path(contour, kind: kind), !path.segs.isEmpty else { continue }
            d += "M\(number(path.start.x)) \(number(path.start.y))"
            for s in path.segs {
                switch s {
                case .line(let p): d += "L\(number(p.x)) \(number(p.y))"
                case .quad(let c, let p): d += "Q\(number(c.x)) \(number(c.y)) \(number(p.x)) \(number(p.y))"
                case .cubic(let a, let b, let p): d += "C\(number(a.x)) \(number(a.y)) \(number(b.x)) \(number(b.y)) \(number(p.x)) \(number(p.y))"
                }
            }
            d += "Z"
        }
        return d.isEmpty ? "" : " d=\"\(d)\""
    }

    // MARK: Reading

    static func read(_ bytes: [UInt8]) throws -> (FontModel, [LossNote]) {
        let collector = Collector()
        let parser = XMLParser(data: Data(bytes))
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        guard parser.parse() || collector.sawFontEnd else { throw FontError.damaged("not valid XML") }
        guard collector.sawFont else {
            throw FontError.unsupported("This SVG doesn’t contain a font, so there are no letters to convert.")
        }
        return collector.model()
    }

    private final class Collector: NSObject, XMLParserDelegate {
        struct RawGlyph { var name: String?; var unicode: String?; var advance: Double?; var d: String? }
        var sawFont = false, sawFontEnd = false, inFirstFont = false
        var fontAdvance = 1000.0, unitsPerEm = 1000.0
        var ascent: Double?, descent: Double?
        var family = "Untitled", weight = 400.0, italic = false
        var missing: RawGlyph?
        var glyphs: [RawGlyph] = []
        var skipped = 0

        /// A metric attribute in font units: a damaged file can say anything, and the font stores 16-bit values.
        private func metric(_ value: String?) -> Double? {
            guard let v = value.flatMap(Double.init), v.isFinite, abs(v) <= 32767 else { return nil }
            return v
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            let local = name.split(separator: ":").last.map(String.init) ?? name
            switch local {
            case "font":
                guard !sawFont else { return }
                sawFont = true; inFirstFont = true
                fontAdvance = metric(a["horiz-adv-x"]) ?? 1000
            case "font-face" where inFirstFont:
                unitsPerEm = metric(a["units-per-em"]) ?? 1000
                ascent = metric(a["ascent"]); descent = metric(a["descent"])
                family = a["font-family"]?.split(separator: ",").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) } ?? family
                weight = metric(a["font-weight"]) ?? (a["font-weight"] == "bold" ? 700 : 400)
                italic = a["font-style"].map { $0 == "italic" || $0 == "oblique" } ?? false
            case "missing-glyph" where inFirstFont:
                missing = RawGlyph(name: ".notdef", unicode: nil, advance: metric(a["horiz-adv-x"]), d: a["d"])
            case "glyph" where inFirstFont:
                if a["orientation"] == "v" || a["arabic-form"].map({ $0 != "isolated" }) == true || a["lang"] != nil { skipped += 1; return }
                glyphs.append(RawGlyph(name: a["glyph-name"], unicode: a["unicode"], advance: metric(a["horiz-adv-x"]), d: a["d"]))
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if (name.split(separator: ":").last.map(String.init) ?? name) == "font", inFirstFont { inFirstFont = false; sawFontEnd = true }
        }

        func model() -> (FontModel, [LossNote]) {
            var parsed: [[OutlinePath]] = []
            var needsCubic = false
            var arcs = false
            func parse(_ d: String?) -> [OutlinePath] {
                guard let d, !d.isEmpty else { return [] }
                let r = PathData.parse(d)
                if r.paths.contains(where: { $0.segs.contains { if case .cubic = $0 { true } else { false } } }) { needsCubic = true }
                if r.approximatedArcs { arcs = true }
                return r.paths
            }
            let all = [missing ?? RawGlyph(name: ".notdef", unicode: nil, advance: nil, d: nil)] + glyphs
            for g in all { parsed.append(parse(g.d)) }
            let kind: FontModel.OutlineKind = needsCubic ? .cubic : .quadratic
            var out: [FontModel.Glyph] = []
            var map: [UInt32: Int] = [:]
            var used = Set<String>()
            for (i, g) in all.enumerated() {
                let contours = parsed[i].map { kind == .cubic ? Outlines.cubicContour($0) : Outlines.quadraticContour($0) }
                var name = g.name?.isEmpty == false ? g.name! : (i == 0 ? ".notdef" : "glyph\(i)")
                if used.contains(name) { name = "\(name).\(i)" }
                used.insert(name)
                out.append(FontModel.Glyph(name: name, advance: Int((g.advance ?? fontAdvance).rounded()), contours: contours))
                if i > 0, let u = g.unicode, u.unicodeScalars.count == 1, let scalar = u.unicodeScalars.first, map[scalar.value] == nil {
                    map[scalar.value] = i
                }
            }
            let em = Int(unitsPerEm.rounded())
            var notes: [LossNote] = []
            if arcs { notes.append(LossNote(.otherLoss, detail: "Elliptical arcs in the glyph paths were drawn as straight lines")) }
            if skipped > 0 { notes.append(LossNote(.otherLoss, detail: "\(skipped) vertical or contextual glyphs were skipped")) }
            let style = (weight >= 600 ? "Bold" : "") + (italic ? (weight >= 600 ? " Italic" : "Italic") : "")
            let model = FontModel(familyName: family, styleName: style.isEmpty ? "Regular" : style, unitsPerEm: max(em, 16),
                                  ascent: Int((ascent ?? unitsPerEm * 0.8).rounded()), descent: Int((descent ?? -unitsPerEm * 0.2).rounded()),
                                  outlineKind: kind, glyphs: out, characterMap: map, tables: [:])
            return (model, notes)
        }
    }
}

/// SVG path data → closed outlines (M, L, H, V, C, S, Q, T, Z in both cases; A is drawn as a line).
enum PathData {
    static func parse(_ d: String) -> (paths: [OutlinePath], approximatedArcs: Bool) {
        let chars = Array(d.utf8)
        var i = 0
        var paths: [OutlinePath] = []
        var current: OutlinePath?
        var pos = Pt(0, 0), start = Pt(0, 0)
        var lastControl: Pt?, lastQuad: Pt?
        var arcs = false

        func skipSeparators() { while i < chars.count, chars[i] == 0x20 || chars[i] == 0x2C || chars[i] == 0x09 || chars[i] == 0x0A || chars[i] == 0x0D { i += 1 } }
        func number() -> Double? {
            skipSeparators()
            let begin = i
            if i < chars.count, chars[i] == 0x2B || chars[i] == 0x2D { i += 1 }
            var digits = false, dot = false
            while i < chars.count {
                let c = chars[i]
                if c >= 0x30 && c <= 0x39 { digits = true; i += 1 }
                else if c == 0x2E && !dot { dot = true; i += 1 }
                else { break }
            }
            if digits, i < chars.count, chars[i] == 0x65 || chars[i] == 0x45 {
                var j = i + 1
                if j < chars.count, chars[j] == 0x2B || chars[j] == 0x2D { j += 1 }
                if j < chars.count, chars[j] >= 0x30 && chars[j] <= 0x39 {
                    while j < chars.count, chars[j] >= 0x30 && chars[j] <= 0x39 { j += 1 }
                    i = j
                }
            }
            guard digits else { i = begin; return nil }
            return Double(String(decoding: chars[begin..<i], as: UTF8.self))
        }
        func numbers(_ n: Int) -> [Double]? {
            var v: [Double] = []
            for _ in 0..<n { guard let x = number() else { return nil }; v.append(x) }
            return v
        }
        func flush() { if let c = current, !c.segs.isEmpty { paths.append(c) }; current = nil }

        var command: UInt8 = 0
        while true {
            skipSeparators()
            guard i < chars.count else { break }
            let c = chars[i]
            if (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) { command = c; i += 1 }
            else if command == 0 || command | 0x20 == 0x7A { break }
            else if command == 0x4D { command = 0x4C } else if command == 0x6D { command = 0x6C }
            let relative = command >= 0x61
            let base = relative ? pos : Pt(0, 0)
            switch command | 0x20 {
            case 0x6D:
                guard let v = numbers(2) else { flush(); return (paths, arcs) }
                flush()
                pos = Pt(base.x + v[0], base.y + v[1]); start = pos
                current = OutlinePath(start: pos, segs: [])
                lastControl = nil; lastQuad = nil
            case 0x6C:
                guard let v = numbers(2) else { flush(); return (paths, arcs) }
                pos = Pt(base.x + v[0], base.y + v[1]); current?.segs.append(.line(pos)); lastControl = nil; lastQuad = nil
            case 0x68:
                guard let v = numbers(1) else { flush(); return (paths, arcs) }
                pos = Pt((relative ? pos.x : 0) + v[0], pos.y); current?.segs.append(.line(pos)); lastControl = nil; lastQuad = nil
            case 0x76:
                guard let v = numbers(1) else { flush(); return (paths, arcs) }
                pos = Pt(pos.x, (relative ? pos.y : 0) + v[0]); current?.segs.append(.line(pos)); lastControl = nil; lastQuad = nil
            case 0x63:
                guard let v = numbers(6) else { flush(); return (paths, arcs) }
                let c1 = Pt(base.x + v[0], base.y + v[1]), c2 = Pt(base.x + v[2], base.y + v[3]), p = Pt(base.x + v[4], base.y + v[5])
                current?.segs.append(.cubic(c1, c2, p)); lastControl = c2; lastQuad = nil; pos = p
            case 0x73:
                guard let v = numbers(4) else { flush(); return (paths, arcs) }
                let c1 = lastControl.map { Pt(2 * pos.x - $0.x, 2 * pos.y - $0.y) } ?? pos
                let c2 = Pt(base.x + v[0], base.y + v[1]), p = Pt(base.x + v[2], base.y + v[3])
                current?.segs.append(.cubic(c1, c2, p)); lastControl = c2; lastQuad = nil; pos = p
            case 0x71:
                guard let v = numbers(4) else { flush(); return (paths, arcs) }
                let c1 = Pt(base.x + v[0], base.y + v[1]), p = Pt(base.x + v[2], base.y + v[3])
                current?.segs.append(.quad(c1, p)); lastQuad = c1; lastControl = nil; pos = p
            case 0x74:
                guard let v = numbers(2) else { flush(); return (paths, arcs) }
                let c1 = lastQuad.map { Pt(2 * pos.x - $0.x, 2 * pos.y - $0.y) } ?? pos
                let p = Pt(base.x + v[0], base.y + v[1])
                current?.segs.append(.quad(c1, p)); lastQuad = c1; lastControl = nil; pos = p
            case 0x61:
                guard let v = numbers(7) else { flush(); return (paths, arcs) }
                arcs = true
                pos = Pt(base.x + v[5], base.y + v[6]); current?.segs.append(.line(pos)); lastControl = nil; lastQuad = nil
            case 0x7A:
                if current != nil { pos = start }
                flush()
                lastControl = nil; lastQuad = nil
                skipSeparators()
                if i < chars.count, chars[i] != 0x4D, chars[i] != 0x6D { current = OutlinePath(start: start, segs: []) }
            default:
                flush(); return (paths, arcs)
            }
        }
        flush()
        return (paths, arcs)
    }
}
