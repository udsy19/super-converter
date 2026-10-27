import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore

extension SVGInterpreter {
    // MARK: Fonts

    nonisolated(unsafe) static var fontCache: [String: String] = [:]
    static let fontLock = NSLock()

    /// A PostScript font name for a CSS font-family list, weight and style, falling back through the generic families.
    static func postScriptName(families: String, weight: String, italic: Bool) -> String {
        let key = "\(families)|\(weight)|\(italic)"
        fontLock.lock(); defer { fontLock.unlock() }
        if let hit = fontCache[key] { return hit }
        let numeric: Int = {
            switch weight { case "bold", "bolder": return 700; case "normal": return 400; case "lighter": return 300; default: return Int(weight) ?? 400 }
        }()
        let generics = ["serif": "Times", "sans-serif": "Helvetica", "monospace": "Courier", "cursive": "Apple Chancery", "fantasy": "Papyrus",
                        "system-ui": "Helvetica Neue", "ui-sans-serif": "Helvetica Neue", "ui-serif": "Times", "ui-monospace": "Menlo",
                        "arial": "Arial", "helvetica": "Helvetica", "times": "Times", "courier": "Courier"]
        var base: CTFont?
        for raw in families.split(separator: ",") {
            let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard !name.isEmpty else { continue }
            let target = generics[name.lowercased()] ?? name
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: target] as CFDictionary)
            if let match = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, nil) {
                let font = CTFontCreateWithFontDescriptor(match, 12, nil)
                let family = CTFontCopyFamilyName(font) as String
                if family.caseInsensitiveCompare(target) == .orderedSame { base = font; break }
            }
            let byName = CTFontCreateWithName(target as CFString, 12, nil)
            let full = CTFontCopyFullName(byName) as String, ps = CTFontCopyPostScriptName(byName) as String
            if full.caseInsensitiveCompare(target) == .orderedSame || ps.caseInsensitiveCompare(target) == .orderedSame { base = byName; break }
        }
        let font = base ?? CTFontCreateWithName("Times" as CFString, 12, nil)
        var traits: CTFontSymbolicTraits = []
        if numeric >= 600 { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        var result = CTFontCopyPostScriptName(font) as String
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, 12, nil, traits, traits) {
            result = CTFontCopyPostScriptName(styled) as String
        } else if numeric < 600 && !italic {
            // Ask for the regular face when the family's default is something else (e.g. a bold-first family).
            if let regular = CTFontCreateCopyWithSymbolicTraits(font, 12, nil, [], [.traitBold, .traitItalic]) { result = CTFontCopyPostScriptName(regular) as String }
        }
        fontCache[key] = result
        return result
    }

    static func advance(of text: String, font: CTFont) -> Double {
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, [kCTFontAttributeName: font] as CFDictionary))
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }

    // MARK: Layout

    struct TextChar {
        var ch: Character
        var props: SVGProps
        var spanID: Int
        var path: XNode?
    }

    /// Flattens `<text>` content into characters with their computed properties (XML whitespace rules applied).
    func collectTextChars(_ node: XNode, props: SVGProps, spanID: Int, nextID: inout Int, out: inout [TextChar],
                          positions: inout [(start: Int, node: XNode, props: SVGProps)], pathNode: XNode?) {
        let preserve = node.attr("space") == "preserve"
        positions.append((out.count, node, props))
        for part in node.parts {
            switch part {
            case .text(let raw):
                var text = raw.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
                if !preserve {
                    var collapsed = ""
                    var lastSpace = (out.last?.ch == " ") || out.isEmpty
                    for c in text { if c == " " { if !lastSpace { collapsed.append(c) }; lastSpace = true } else { collapsed.append(c); lastSpace = false } }
                    text = collapsed
                }
                for c in text { out.append(TextChar(ch: c, props: props, spanID: spanID, path: pathNode)) }
            case .element(let child):
                guard ["tspan", "a", "textPath", "tref", "altGlyph"].contains(child.name) else { continue }
                var childProps = computeProps(child, parent: props)
                childProps["transform"] = nil
                if childProps["display"] == "none" { continue }
                nextID += 1
                if child.name == "tref", let target = reference(child.attr("href")) {
                    for c in target.text.split(whereSeparator: { $0.isNewline }).joined(separator: " ") { out.append(TextChar(ch: c, props: childProps, spanID: nextID, path: pathNode)) }
                    continue
                }
                collectTextChars(child, props: childProps, spanID: nextID, nextID: &nextID, out: &out, positions: &positions,
                                 pathNode: child.name == "textPath" ? reference(child.attr("href")) : pathNode)
            }
        }
    }

    func renderText(_ node: XNode, ctx: SVGContext, into out: inout [VectorNode]) {
        var chars: [TextChar] = []
        var positions: [(start: Int, node: XNode, props: SVGProps)] = []
        var nextID = 0
        collectTextChars(node, props: ctx.props, spanID: 0, nextID: &nextID, out: &chars, positions: &positions, pathNode: nil)
        while chars.last?.ch == " " { chars.removeLast() }
        var leading = 0
        while leading < chars.count, chars[leading].ch == " " { leading += 1 }
        if leading > 0 { chars.removeFirst(leading); positions = positions.map { (max(0, $0.start - leading), $0.node, $0.props) } }
        guard !chars.isEmpty else { return }

        // Per-character position lists.
        var xs = [Double?](repeating: nil, count: chars.count), ys = xs, dxs = xs, dys = xs
        var rotates = xs
        for (index, entry) in positions.enumerated() {
            let end = Self.spanEnd(of: entry.node, positions: positions, index: index, total: chars.count)
            func assign(_ key: String, _ target: inout [Double?], base: Double) {
                guard let text = entry.node.attr(key) else { return }
                let values = text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { length(String($0), entry.props, percentBase: base) }
                for (k, v) in values.enumerated() where entry.start + k < min(end, chars.count) { target[entry.start + k] = v }
            }
            assign("x", &xs, base: ctx.vw); assign("y", &ys, base: ctx.vh)
            assign("dx", &dxs, base: ctx.vw); assign("dy", &dys, base: ctx.vh)
            if let r = entry.node.attr("rotate") {
                let values = SVGValues.numberList(r)
                if !values.isEmpty { for k in 0..<max(0, min(end, chars.count) - entry.start) { rotates[entry.start + k] = values[min(k, values.count - 1)] } }
            }
        }

        struct Piece { var text: String; var x: Double; var y: Double; var props: SVGProps; var rotate: Double; var width: Double; var chunk: Int; var path: XNode? }
        var pieces: [Piece] = []
        var penX = 0.0, penY = 0.0
        var chunk = -1
        var chunkWidths: [Int: Double] = [:], chunkAnchor: [Int: String] = [:]
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let size = fontSize(c.props)
            let fontName = Self.postScriptName(families: c.props["font-family"] ?? "serif", weight: c.props["font-weight"] ?? "normal",
                                               italic: (c.props["font-style"] ?? "normal") != "normal")
            let font = VectorRenderer.font(named: fontName, size: size)
            let spacing = length(c.props["letter-spacing"], c.props, percentBase: size)
            let wordSpacing = length(c.props["word-spacing"], c.props, percentBase: size)
            if xs[i] != nil || ys[i] != nil || chunk < 0 {
                chunk += 1
                if let x = xs[i] { penX = x }
                if let y = ys[i] { penY = y }
                chunkAnchor[chunk] = c.props["text-anchor"] ?? "start"
                chunkWidths[chunk] = 0
            }
            penX += dxs[i] ?? 0; penY += dys[i] ?? 0
            // Group following characters that share this character's span and need no individual placement.
            var j = i + 1
            let simple = spacing == 0 && wordSpacing == 0 && rotates[i] == nil && c.path == nil
            if simple {
                while j < chars.count, chars[j].spanID == c.spanID, xs[j] == nil, ys[j] == nil, dxs[j] == nil, dys[j] == nil, rotates[j] == nil { j += 1 }
            }
            let text = String(chars[i..<j].map(\.ch))
            let width = Self.advance(of: text, font: font) + spacing * Double(j - i) + (text == " " ? wordSpacing : 0)
            pieces.append(Piece(text: text, x: penX, y: penY, props: c.props, rotate: rotates[i] ?? 0, width: width, chunk: chunk, path: c.path))
            penX += width
            chunkWidths[chunk, default: 0] += width
            i = j
        }

        // Anchor shifts per chunk.
        for k in pieces.indices {
            let width = chunkWidths[pieces[k].chunk] ?? 0
            switch chunkAnchor[pieces[k].chunk] ?? "start" {
            case "middle": pieces[k].x -= width / 2
            case "end": pieces[k].x -= width
            default: break
            }
        }

        let flatText = abs(ctx.ctm.b) < 1e-9 && abs(ctx.ctm.c) < 1e-9 && ctx.ctm.a > 0 && ctx.ctm.d < 0 && abs(ctx.ctm.a + ctx.ctm.d) < 1e-9 * max(1, ctx.ctm.a)
        let toLocalFlip = VectorTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        let minX = pieces.map(\.x).min() ?? 0
        let maxX = pieces.map { $0.x + $0.width }.max() ?? minX
        let wholeBox = CGRect(x: minX, y: (pieces.map(\.y).min() ?? 0) - fontSize(ctx.props), width: maxX - minX, height: fontSize(ctx.props) * 1.3)
        var nodes: [VectorNode] = []
        for piece in pieces {
            if piece.props["visibility"] == "hidden" { continue }
            let size = fontSize(piece.props)
            let fontName = Self.postScriptName(families: piece.props["font-family"] ?? "serif", weight: piece.props["font-weight"] ?? "normal",
                                               italic: (piece.props["font-style"] ?? "normal") != "normal")
            var pieceCtx = ctx; pieceCtx.props = piece.props
            let fill = resolvePaint("fill", opacityKey: "fill-opacity", ctx: pieceCtx, bbox: wholeBox, leaf: flatText ? ctx.ctm : .identity)
            var fillPaint: VectorPaint?
            switch fill {
            case .paint(let p): fillPaint = p
            case .skewed(let p, _): fillPaint = Self.firstColour(p)
            default: break
            }
            let hasStroke = (piece.props["stroke"] ?? "none") != "none" && length(piece.props["stroke-width"], piece.props, percentBase: size, default: 1) > 0
            if fillPaint == nil, !hasStroke { continue }

            var origin = (x: piece.x, y: piece.y)
            var placement: VectorTransform?
            if let pathNode = piece.path, let at = Self.pointOnPath(geometry(pathNode, ctx: ctx), distance: piece.x + piece.width / 2) {
                // textPath: put each piece's centre on the path and rotate to its tangent.
                placement = VectorTransform(a: cos(at.angle), b: sin(at.angle), c: -sin(at.angle), d: cos(at.angle), tx: 0, ty: 0).then(.translation(at.x, at.y))
                origin = (x: -piece.width / 2, y: piece.y)
            }
            let r = piece.rotate * .pi / 180
            let rotation: VectorTransform? = placement ?? (piece.rotate != 0
                ? VectorTransform(a: cos(r), b: sin(r), c: -sin(r), d: cos(r), tx: 0, ty: 0).around(x: origin.x, y: origin.y) : nil)

            if hasStroke {
                // Outlined text: stroke needs geometry.
                let run = VectorTextRun(text: piece.text, fontName: fontName, size: size, origin: VectorPoint(origin.x, -origin.y), fill: .solid(.black))
                if case .path(let glyphs, _, _, _) = VectorOutlines.glyphPaths(run) {
                    var user = glyphs.transformed(by: toLocalFlip)
                    if let rotation { user = user.transformed(by: rotation) }
                    nodes.append(contentsOf: shapeNodes(user, ctx: pieceCtx, fillOverride: fillPaint.map { .paint($0) } ?? Resolved.none))
                }
                continue
            }
            guard let paint = fillPaint else { continue }
            if flatText, rotation == nil {
                let p = ctx.ctm.apply(VectorPoint(origin.x, origin.y))
                nodes.append(.text(VectorTextRun(text: piece.text, fontName: fontName, size: size * ctx.ctm.a, origin: p, fill: paint)))
            } else {
                let run = VectorTextRun(text: piece.text, fontName: fontName, size: size, origin: VectorPoint(origin.x, -origin.y), fill: paint)
                var local = toLocalFlip
                if let rotation { local = toLocalFlip.then(rotation) }
                nodes.append(.group([.text(run)], transform: local.then(ctx.ctm), clip: nil, opacity: 1))
            }
        }
        out.append(contentsOf: nodes)
    }

    /// Where the span that starts at `positions[index]` ends: the start of the next entry that is not a descendant.
    static func spanEnd(of node: XNode, positions: [(start: Int, node: XNode, props: SVGProps)], index: Int, total: Int) -> Int {
        for later in positions[(index + 1)...] {
            var ancestor: XNode? = later.node
            var inside = false
            while let a = ancestor { if a === node { inside = true; break }; ancestor = a.parent }
            if !inside { return later.start }
        }
        return total
    }

    /// The point and tangent angle at `distance` along a path's flattened outline.
    static func pointOnPath(_ geometry: [PathSegment], distance: Double) -> (x: Double, y: Double, angle: Double)? {
        let polyline = PathFlattener.subpaths(geometry).first?.points ?? []
        guard polyline.count >= 2 else { return nil }
        var remaining = distance
        for k in 0..<(polyline.count - 1) {
            let a = polyline[k], b = polyline[k + 1]
            let seg = hypot(b.x - a.x, b.y - a.y)
            if seg == 0 { continue }
            if remaining <= seg || k == polyline.count - 2 {
                let t = max(0, remaining) / seg
                return (a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, atan2(b.y - a.y, b.x - a.x))
            }
            remaining -= seg
        }
        return nil
    }
}

extension VectorTransform {
    /// This transform applied about the point (x, y).
    func around(x: Double, y: Double) -> VectorTransform { VectorTransform.translation(-x, -y).then(self).then(.translation(x, y)) }
}

public enum PathFlattener {
    /// Subpaths as polylines, curves cut into straight pieces (more for long curves).
    public static func subpaths(_ segments: [PathSegment]) -> [(points: [VectorPoint], closed: Bool)] {
        var out: [(points: [VectorPoint], closed: Bool)] = []
        var current: [VectorPoint] = []
        var cur = VectorPoint(0, 0), start = VectorPoint(0, 0)
        func finish(closed: Bool) { if current.count > 1 || (current.count == 1 && closed) { out.append((current, closed)) }; current = [] }
        for s in segments {
            switch s {
            case .move(let p): finish(closed: false); current = [p]; cur = p; start = p
            case .line(let p): if current.isEmpty { current = [cur] }; current.append(p); cur = p
            case .quad(let c, let p):
                if current.isEmpty { current = [cur] }
                let steps = curveSteps(cur, c, p)
                for i in 1...steps { let t = Double(i) / Double(steps), u = 1 - t; current.append(VectorPoint(u * u * cur.x + 2 * u * t * c.x + t * t * p.x, u * u * cur.y + 2 * u * t * c.y + t * t * p.y)) }
                cur = p
            case .cubic(let c1, let c2, let p):
                if current.isEmpty { current = [cur] }
                let steps = curveSteps(cur, c1, c2, p)
                for i in 1...steps {
                    let t = Double(i) / Double(steps), u = 1 - t
                    current.append(VectorPoint(u * u * u * cur.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p.x,
                                               u * u * u * cur.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p.y))
                }
                cur = p
            case .close: finish(closed: true); cur = start
            }
        }
        finish(closed: false)
        return out
    }

    private static func curveSteps(_ pts: VectorPoint...) -> Int {
        var length = 0.0
        for i in 1..<pts.count { length += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
        return max(4, min(48, Int(length / 3)))
    }
}
