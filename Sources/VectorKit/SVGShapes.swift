import CoreGraphics
import Foundation
import SuperConverterCore

extension SVGInterpreter {
    // MARK: Geometry

    /// Path segments of a basic shape or path element in its own user space.
    func geometry(_ node: XNode, ctx: SVGContext) -> [PathSegment] {
        let props = ctx.props
        let w = ctx.vw, h = ctx.vh
        func len(_ key: String, _ base: Double) -> Double { length(node.attr(key), props, percentBase: base) }
        switch node.name {
        case "path": return SVGValues.pathData(node.attr("d") ?? "")
        case "rect":
            let rw = len("width", w), rh = len("height", h)
            guard rw > 0, rh > 0 else { return [] }
            let x = len("x", w), y = len("y", h)
            var rx = node.attr("rx").map { length($0, props, percentBase: w) }, ry = node.attr("ry").map { length($0, props, percentBase: h) }
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            let radiusX = min(max(0, rx ?? 0), rw / 2), radiusY = min(max(0, ry ?? 0), rh / 2)
            if radiusX == 0 || radiusY == 0 { return PathBuilder.rect(x: x, y: y, width: rw, height: rh) }
            let k = 0.5522847498307936
            let p = { VectorPoint($0, $1) }
            return [
                .move(p(x + radiusX, y)), .line(p(x + rw - radiusX, y)),
                .cubic(p(x + rw - radiusX + k * radiusX, y), p(x + rw, y + radiusY - k * radiusY), p(x + rw, y + radiusY)),
                .line(p(x + rw, y + rh - radiusY)),
                .cubic(p(x + rw, y + rh - radiusY + k * radiusY), p(x + rw - radiusX + k * radiusX, y + rh), p(x + rw - radiusX, y + rh)),
                .line(p(x + radiusX, y + rh)),
                .cubic(p(x + radiusX - k * radiusX, y + rh), p(x, y + rh - radiusY + k * radiusY), p(x, y + rh - radiusY)),
                .line(p(x, y + radiusY)),
                .cubic(p(x, y + radiusY - k * radiusY), p(x + radiusX - k * radiusX, y), p(x + radiusX, y)),
                .close,
            ]
        case "circle":
            let diagonal: Double = ((w * w + h * h) / 2).squareRoot()
            let r = length(node.attr("r"), props, percentBase: diagonal)
            guard r > 0 else { return [] }
            return PathBuilder.ellipse(cx: len("cx", w), cy: len("cy", h), rx: r, ry: r)
        case "ellipse":
            var rx = node.attr("rx").map { length($0, props, percentBase: w) }, ry = node.attr("ry").map { length($0, props, percentBase: h) }
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            guard let rxv = rx, let ryv = ry, rxv > 0, ryv > 0 else { return [] }
            return PathBuilder.ellipse(cx: len("cx", w), cy: len("cy", h), rx: rxv, ry: ryv)
        case "line":
            return [.move(VectorPoint(len("x1", w), len("y1", h))), .line(VectorPoint(len("x2", w), len("y2", h)))]
        case "polyline", "polygon":
            let n = SVGValues.numberList(node.attr("points"))
            guard n.count >= 4 else { return [] }
            var out: [PathSegment] = [.move(VectorPoint(n[0], n[1]))]
            var i = 2
            while i + 1 < n.count { out.append(.line(VectorPoint(n[i], n[i + 1]))); i += 2 }
            if node.name == "polygon" { out.append(.close) }
            return out
        default: return []
        }
    }

    func renderShape(_ node: XNode, ctx: SVGContext, into out: inout [VectorNode]) {
        let segments = geometry(node, ctx: ctx)
        guard !segments.isEmpty else { return }
        out.append(contentsOf: shapeNodes(segments, ctx: ctx))
        if ["path", "line", "polyline", "polygon"].contains(node.name) { out.append(contentsOf: markers(for: segments, node: node, ctx: ctx)) }
    }

    // MARK: Drawing a shape

    /// Resolved paint for one of fill/stroke.
    enum Resolved {
        case none
        case paint(VectorPaint)
        /// A gradient defined in its own space; the path is drawn inside a group carrying `transform`.
        case skewed(VectorPaint, VectorTransform)
        case pattern(XNode, opacity: Double)
    }

    func shapeNodes(_ userSegments: [PathSegment], ctx: SVGContext, fillOverride: Resolved? = nil) -> [VectorNode] {
        let props = ctx.props
        guard props["visibility"] != "hidden", props["visibility"] != "collapse" else { return [] }
        let flat = ctx.ctm.isSimilarity
        let leaf = flat ? ctx.ctm : VectorTransform.identity
        let scale = flat ? ctx.ctm.lengthScale : 1
        let bbox = userSegments.cgPath.boundingBoxOfPath
        let rule: FillRule = props["fill-rule"] == "evenodd" ? .evenOdd : .nonZero
        let leafSegments = userSegments.transformed(by: leaf)

        let fill = fillOverride ?? resolvePaint("fill", opacityKey: "fill-opacity", ctx: ctx, bbox: bbox, leaf: leaf)
        let diag: Double = ((ctx.vw * ctx.vw + ctx.vh * ctx.vh) / 2).squareRoot()
        let strokeWidth = length(props["stroke-width"], props, percentBase: diag, default: 1)
        var strokePaint: VectorPaint?
        if strokeWidth > 0 {
            switch resolvePaint("stroke", opacityKey: "stroke-opacity", ctx: ctx, bbox: bbox, leaf: leaf) {
            case .paint(let p): strokePaint = p
            case .skewed(let p, _):
                // A stroke gradient under a skew: keep the first stop's colour.
                strokePaint = Self.firstColour(p)
                note(.shadingRasterised, "A gradient stroke under a skew became a flat colour")
            case .pattern: note(.otherLoss, "A pattern stroke was drawn without the pattern")
            case .none: break
            }
        }
        var stroke: VectorStroke?
        if let paint = strokePaint {
            var dashes = (props["stroke-dasharray"].map { dashList($0, props: props, ctx: ctx) } ?? []).map { $0 * scale }
            if dashes.count % 2 == 1 { dashes += dashes }
            if dashes.contains(where: { $0 < 0 }) || dashes.reduce(0, +) <= 0 { dashes = [] }
            let cap: LineCap = props["stroke-linecap"] == "round" ? .round : props["stroke-linecap"] == "square" ? .square : .butt
            let join: LineJoin = props["stroke-linejoin"] == "round" ? .round : props["stroke-linejoin"] == "bevel" ? .bevel : .miter
            stroke = VectorStroke(paint: paint, width: strokeWidth * scale, dash: dashes,
                                  dashPhase: length(props["stroke-dashoffset"], props, percentBase: ctx.vw) * scale, cap: cap, join: join,
                                  miterLimit: max(1, Double(props["stroke-miterlimit"] ?? "4") ?? 4))
        }

        var nodes: [VectorNode] = []
        switch fill {
        case .none:
            if let stroke { nodes.append(.path(leafSegments, fill: nil, stroke: stroke, rule: rule)) }
        case .paint(let paint):
            nodes.append(.path(leafSegments, fill: paint, stroke: stroke, rule: rule))
        case .skewed(let paint, let transform):
            if let inverse = transform.inverted {
                nodes.append(.group([.path(leafSegments.transformed(by: inverse), fill: paint, stroke: nil, rule: rule)], transform: transform, clip: nil, opacity: 1))
                if let stroke { nodes.append(.path(leafSegments, fill: nil, stroke: stroke, rule: rule)) }
            }
        case .pattern(let pattern, let opacity):
            let tiles = patternNodes(pattern, ctx: ctx, bbox: bbox, leaf: leaf, opacity: opacity)
            if !tiles.isEmpty { nodes.append(.group(tiles, transform: .identity, clip: leafSegments, opacity: 1)) }
            if let stroke { nodes.append(.path(leafSegments, fill: nil, stroke: stroke, rule: rule)) }
        }
        if !flat, !nodes.isEmpty { return [.group(nodes, transform: ctx.ctm, clip: nil, opacity: 1)] }
        return nodes
    }

    /// A flat stand-in for a gradient: its first colour.
    static func firstColour(_ paint: VectorPaint) -> VectorPaint? {
        switch paint {
        case .solid: return paint
        case .linear(_, _, let s), .radial(_, _, let s): return s.first.map { .solid($0.colour) }
        case .rasterised: return nil
        }
    }

    func dashList(_ text: String, props: SVGProps, ctx: SVGContext) -> [Double] {
        if text == "none" { return [] }
        return text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { length(String($0), props, percentBase: ctx.vw, default: .nan) }.filter { !$0.isNaN }
    }

    // MARK: Paint

    func resolvePaint(_ key: String, opacityKey: String, ctx: SVGContext, bbox: CGRect, leaf: VectorTransform) -> Resolved {
        let props = ctx.props
        let raw = (props[key] ?? (key == "fill" ? "black" : "none")).trimmingCharacters(in: .whitespaces)
        var opacity = Double(props[opacityKey]?.trimmingCharacters(in: .whitespaces) ?? "1") ?? 1
        if let v = props[opacityKey], v.hasSuffix("%"), let p = Double(v.dropLast()) { opacity = p / 100 }
        opacity = SVGValues.clamp(opacity)
        let current = SVGValues.colour(props["color"] ?? "black") ?? .black
        if raw == "none" || raw.isEmpty { return .none }
        if raw.hasPrefix("url(") {
            let fallback = raw.firstIndex(of: ")").map { String(raw[raw.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
            if let server = reference(raw) {
                switch server.name {
                case "linearGradient", "radialGradient":
                    if let result = gradientPaint(server, ctx: ctx, bbox: bbox, leaf: leaf, opacity: opacity) { return result }
                case "pattern": return .pattern(server, opacity: opacity)
                default: break
                }
            }
            if fallback == "none" || fallback.isEmpty { return .none }
            return SVGValues.colour(fallback, currentColour: current).map { var c = $0; c.alpha *= opacity; return .paint(.solid(c)) } ?? .none
        }
        guard var colour = SVGValues.colour(raw, currentColour: current) else { return .none }
        colour.alpha *= opacity
        return .paint(.solid(colour))
    }

    /// Attribute lookup along a gradient's `href` chain.
    func gradientAttr(_ g: XNode, _ key: String) -> String? {
        var node: XNode? = g
        var seen = 0
        while let n = node, seen < 16 {
            if let v = n.attr(key) { return v }
            node = reference(n.attr("href")); seen += 1
        }
        return nil
    }

    func gradientStopsNode(_ g: XNode) -> XNode? {
        var node: XNode? = g
        var seen = 0
        while let n = node, seen < 16 {
            if n.children.contains(where: { $0.name == "stop" }) { return n }
            node = reference(n.attr("href")); seen += 1
        }
        return nil
    }

    func gradientPaint(_ g: XNode, ctx: SVGContext, bbox: CGRect, leaf: VectorTransform, opacity: Double) -> Resolved? {
        var stops: [GradientStop] = []
        if let holder = gradientStopsNode(g) {
            var last = 0.0
            for stop in holder.children where stop.name == "stop" {
                let p = computeProps(stop, parent: ["color": ctx.props["color"] ?? "black"])
                var offset = 0.0
                if let o = stop.attr("offset")?.trimmingCharacters(in: .whitespaces) {
                    offset = o.hasSuffix("%") ? (Double(o.dropLast()) ?? 0) / 100 : (Double(o) ?? 0)
                }
                offset = max(last, SVGValues.clamp(offset)); last = offset
                let currentColour = SVGValues.colour(p["color"] ?? "black") ?? .black
                var colour = SVGValues.colour(p["stop-color"] ?? "black", currentColour: currentColour) ?? .black
                var stopOpacity = Double(p["stop-opacity"] ?? "1") ?? 1
                if let so = p["stop-opacity"], so.hasSuffix("%"), let v = Double(so.dropLast()) { stopOpacity = v / 100 }
                colour.alpha *= SVGValues.clamp(stopOpacity) * opacity
                stops.append(GradientStop(offset: offset, colour: colour))
            }
        }
        if stops.isEmpty { return Resolved.none }
        if stops.count == 1 { return .paint(.solid(stops[0].colour)) }

        let isLinear = g.name == "linearGradient"
        let objectBox = (gradientAttr(g, "gradientUnits") ?? "objectBoundingBox") == "objectBoundingBox"
        if objectBox, bbox.width <= 0 || bbox.height <= 0 { return Resolved.none }
        let bboxMatrix = objectBox ? VectorTransform(a: Double(bbox.width), b: 0, c: 0, d: Double(bbox.height), tx: Double(bbox.minX), ty: Double(bbox.minY)) : .identity
        let g2u = SVGValues.transform(gradientAttr(g, "gradientTransform")).then(bboxMatrix)
        guard let u2g = g2u.inverted else { return Resolved.none }
        func coord(_ key: String, _ def: String, base: Double) -> Double {
            let text = gradientAttr(g, key) ?? def
            guard let l = SVGValues.length(text) else { return 0 }
            if objectBox { return l.isPercent ? l.value / 100 : l.value }
            return Self.px(l, fontSize: fontSize(ctx.props), percentBase: base)
        }
        let diagonal: Double = ((ctx.vw * ctx.vw + ctx.vh * ctx.vh) / 2).squareRoot()
        let spread = gradientAttr(g, "spreadMethod") ?? "pad"
        // The bounding box in gradient space decides how many repeats a reflect/repeat gradient needs.
        let corners = [CGPoint(x: bbox.minX, y: bbox.minY), CGPoint(x: bbox.maxX, y: bbox.minY), CGPoint(x: bbox.minX, y: bbox.maxY), CGPoint(x: bbox.maxX, y: bbox.maxY)]
            .map { u2g.apply(VectorPoint($0)) }

        var paintInGradientSpace: VectorPaint
        if isLinear {
            let x1 = coord("x1", "0%", base: ctx.vw), y1 = coord("y1", "0%", base: ctx.vh)
            let x2 = coord("x2", "100%", base: ctx.vw), y2 = coord("y2", "0%", base: ctx.vh)
            let dx = x2 - x1, dy = y2 - y1
            let lengthSq = dx * dx + dy * dy
            if lengthSq == 0 { return .paint(.solid(stops.last!.colour)) }
            var from = VectorPoint(x1, y1), to = VectorPoint(x2, y2)
            if spread != "pad" {
                let ts = corners.map { (($0.x - x1) * dx + ($0.y - y1) * dy) / lengthSq }
                let (extended, k0, k1) = Self.spreadStops(stops, tMin: ts.min() ?? 0, tMax: ts.max() ?? 1, reflect: spread == "reflect")
                stops = extended
                from = VectorPoint(x1 + dx * k0, y1 + dy * k0); to = VectorPoint(x1 + dx * k1, y1 + dy * k1)
            }
            paintInGradientSpace = .linear(from: from, to: to, stops: stops)
        } else {
            let cx = coord("cx", "50%", base: ctx.vw), cy = coord("cy", "50%", base: ctx.vh)
            var r = coord("r", "50%", base: diagonal)
            if r <= 0 { return .paint(.solid(stops.last!.colour)) }
            if spread != "pad" {
                let distances: [Double] = corners.map { c in
                    let dx = c.x - cx, dy = c.y - cy
                    return (dx * dx + dy * dy).squareRoot() / r
                }
                let (extended, _, k1) = Self.spreadStops(stops, tMin: 0, tMax: distances.max() ?? 1, reflect: spread == "reflect")
                stops = extended; r *= k1
            }
            paintInGradientSpace = .radial(centre: VectorPoint(cx, cy), radius: r, stops: stops)
        }
        // Into leaf space.
        let m = g2u.then(leaf)
        if m.isSimilarity {
            switch paintInGradientSpace {
            case .linear(let a, let b, let s): return .paint(.linear(from: m.apply(a), to: m.apply(b), stops: s))
            case .radial(let c, let r, let s): return .paint(.radial(centre: m.apply(c), radius: r * m.lengthScale, stops: s))
            default: break
            }
        }
        return .skewed(paintInGradientSpace, m)
    }

    /// Repeats or mirrors `stops` over [floor(tMin), ceil(tMax)] (capped), returning the new stops and the integer range.
    static func spreadStops(_ stops: [GradientStop], tMin: Double, tMax: Double, reflect: Bool) -> ([GradientStop], Double, Double) {
        var k0 = Int(floor(tMin)), k1 = Int(ceil(tMax))
        if k1 <= k0 { k1 = k0 + 1 }
        if k1 - k0 > 64 { let mid = (k0 + k1) / 2; k0 = mid - 32; k1 = mid + 32 }
        var out: [GradientStop] = []
        let span = Double(k1 - k0)
        for k in k0..<k1 {
            let mirrored = reflect && (k % 2 != 0)
            let ordered = mirrored ? stops.reversed().map { GradientStop(offset: 1 - $0.offset, colour: $0.colour) } : stops
            for s in ordered { out.append(GradientStop(offset: (Double(k - k0) + s.offset) / span, colour: s.colour)) }
        }
        return (out, Double(k0), Double(k1))
    }

    // MARK: Patterns

    /// Nodes (in leaf space) that tile a pattern over `bbox`, to be clipped by the shape.
    func patternNodes(_ pattern: XNode, ctx: SVGContext, bbox: CGRect, leaf: VectorTransform, opacity: Double) -> [VectorNode] {
        func attr(_ key: String) -> String? {
            var node: XNode? = pattern
            var n = 0
            while let p = node, n < 16 { if let v = p.attr(key) { return v }; node = reference(p.attr("href")); n += 1 }
            return nil
        }
        var contentHolder: XNode? = pattern
        var hops = 0
        while let p = contentHolder, p.children.filter({ Self.graphicElements.contains($0.name) }).isEmpty, hops < 16 { contentHolder = reference(p.attr("href")); hops += 1 }
        guard let holder = contentHolder else { return [] }
        let objectBox = (attr("patternUnits") ?? "objectBoundingBox") == "objectBoundingBox"
        let contentObjectBox = attr("patternContentUnits") == "objectBoundingBox"
        let bw = Double(bbox.width), bh = Double(bbox.height), bx = Double(bbox.minX), by = Double(bbox.minY)
        func coord(_ key: String, base: Double, boxSize: Double, origin: Double) -> Double {
            guard let l = SVGValues.length(attr(key)) else { return 0 }
            if objectBox { return origin + (l.isPercent ? l.value / 100 : l.value) * boxSize }
            return Self.px(l, fontSize: fontSize(ctx.props), percentBase: base)
        }
        func size(_ key: String, base: Double, boxSize: Double) -> Double {
            guard let l = SVGValues.length(attr(key)) else { return 0 }
            if objectBox { return (l.isPercent ? l.value / 100 : l.value) * boxSize }
            return Self.px(l, fontSize: fontSize(ctx.props), percentBase: base)
        }
        let x = coord("x", base: ctx.vw, boxSize: bw, origin: bx)
        let y = coord("y", base: ctx.vh, boxSize: bh, origin: by)
        let w = size("width", base: ctx.vw, boxSize: bw), h = size("height", base: ctx.vh, boxSize: bh)
        guard w > 0, h > 0 else { return [] }
        let patternTransform = SVGValues.transform(attr("patternTransform"))
        let vbNumbers = SVGValues.numberList(attr("viewBox"))
        let vb = vbNumbers.count == 4 && vbNumbers[2] > 0 && vbNumbers[3] > 0 ? CGRect(x: vbNumbers[0], y: vbNumbers[1], width: vbNumbers[2], height: vbNumbers[3]) : nil
        var content = viewBoxTransform(viewBox: vb, preserveAspectRatio: attr("preserveAspectRatio"), width: w, height: h)
        if vb == nil, contentObjectBox { content = VectorTransform(a: bw, b: 0, c: 0, d: bh, tx: 0, ty: 0) }

        // Render the tile's content once, in tile-local coordinates.
        var tileProps = computeProps(holder, parent: ctx.props)
        tileProps["opacity"] = nil
        var tileContent: [VectorNode] = []
        renderChildren(of: holder, ctx: SVGContext(ctm: content, props: tileProps, viewport: CGSize(width: w, height: h)), into: &tileContent)
        guard !tileContent.isEmpty else { return [] }
        if opacity < 1 { tileContent = tileContent.map { Self.scaleAlpha($0, opacity) } }

        // Which tiles cover the shape: map the bbox corners into pattern space.
        guard let inverse = patternTransform.inverted else { return [] }
        let corners = [VectorPoint(bx, by), VectorPoint(bx + bw, by), VectorPoint(bx, by + bh), VectorPoint(bx + bw, by + bh)].map { inverse.apply($0) }
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!, minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        let i0 = Int(floor((minX - x) / w)), i1 = Int(ceil((maxX - x) / w))
        let j0 = Int(floor((minY - y) / h)), j1 = Int(ceil((maxY - y) / h))
        let count = max(0, i1 - i0) * max(0, j1 - j0)
        guard count > 0 else { return [] }
        guard count <= 20_000 else { note(.shadingRasterised, "A pattern with too many tiles was left out"); return [] }
        let clip = PathBuilder.rect(x: 0, y: 0, width: w, height: h)
        var out: [VectorNode] = []
        out.reserveCapacity(count)
        for j in j0..<j1 {
            for i in i0..<i1 {
                let t = VectorTransform.translation(x + Double(i) * w, y + Double(j) * h).then(patternTransform).then(leaf)
                out.append(.group(tileContent, transform: t, clip: clip, opacity: 1))
            }
        }
        return out
    }

    // MARK: Clipping

    /// The element bounds in user space (from what was produced, in page space).
    func userBounds(of produced: [VectorNode], ctx: SVGContext) -> CGRect {
        let boxes = produced.compactMap(\.bounds)
        guard var box = boxes.first else { return .zero }
        for b in boxes.dropFirst() { box = box.union(b) }
        guard let inverse = ctx.ctm.inverted else { return box }
        return box.applying(inverse.cg)
    }

    func clipSegments(_ clipNode: XNode, ctx: SVGContext, produced: [VectorNode]) -> [PathSegment] {
        var matrix = SVGValues.transform(clipNode.attr("transform"))
        if clipNode.attr("clipPathUnits") == "objectBoundingBox" {
            let b = userBounds(of: produced, ctx: ctx)
            matrix = matrix.then(VectorTransform(a: Double(b.width), b: 0, c: 0, d: Double(b.height), tx: Double(b.minX), ty: Double(b.minY)))
        }
        let base = matrix.then(ctx.ctm)
        var props = computeProps(clipNode, parent: Self.rootProps)
        props["transform"] = nil
        var out: [PathSegment] = []
        func add(_ child: XNode, _ inheritedProps: SVGProps, _ transform: VectorTransform) {
            let p = computeProps(child, parent: inheritedProps)
            if p["display"] == "none" || p["visibility"] == "hidden" { return }
            let t = SVGValues.transform(child.attr("transform") ?? p["transform"]).then(transform)
            let local = SVGContext(ctm: .identity, props: p, viewport: ctx.viewport)
            if child.name == "use", let target = reference(child.attr("href")), target.name != "use" {
                let x = length(child.attr("x"), p, percentBase: ctx.vw), y = length(child.attr("y"), p, percentBase: ctx.vh)
                add(target, p, VectorTransform.translation(x, y).then(t))
            } else if ["rect", "circle", "ellipse", "line", "polyline", "polygon", "path"].contains(child.name) {
                out.append(contentsOf: geometry(child, ctx: local).transformed(by: t))
            } else if child.name == "text" {
                // Text as a clip: use its outlines.
                var nodes: [VectorNode] = []
                renderText(child, ctx: SVGContext(ctm: t, props: p, viewport: ctx.viewport), into: &nodes)
                for n in nodes { if case .path(let s, _, _, _) = VectorOutlines.convert(n) { out.append(contentsOf: s) } }
            }
        }
        for child in clipNode.children { add(child, props, base) }
        return out
    }

    func applyClip(_ value: String, to produced: [VectorNode], ctx: SVGContext, node: XNode) -> [VectorNode] {
        guard let clipNode = reference(value), clipNode.name == "clipPath" else { return produced }
        let segments = clipSegments(clipNode, ctx: ctx, produced: produced)
        var result: [VectorNode] = [.group(produced, transform: .identity, clip: segments, opacity: 1)]
        // A clipPath may itself be clipped: nest.
        if let inner = clipNode.attr("clip-path"), inner != "none" { result = applyClip(inner, to: result, ctx: ctx, node: clipNode) }
        return result
    }
}
