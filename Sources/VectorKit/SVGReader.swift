import CoreGraphics
import Foundation
import SuperConverterCore

/// SVG 1.1 + common SVG 2 → VectorDocument (formats §3.2): paths, shapes, transforms, gradients, patterns, clip, mask
/// (rasterised), text with font fallback, images, `use`/`symbol`, markers and a CSS cascade subset. Filters and
/// `foreignObject` are skipped and reported, so a caller can route those files through WebKit.
public enum SVGReader {
    public static func read(_ data: Data, baseURL: URL? = nil) throws -> VectorReadResult {
        let xml = Gzip.isGzip(data) ? try Gzip.decompress(data) : data
        let root = try XMLTree.parse(xml)
        guard root.name == "svg" else { throw ConversionError.damaged("svg") }
        return SVGInterpreter(root: root, baseURL: baseURL).run()
    }
}

typealias SVGProps = [String: String]

/// What a traversal level carries.
struct SVGContext {
    var ctm: VectorTransform
    var props: SVGProps
    var viewport: CGSize
    var vw: Double { Double(viewport.width) }
    var vh: Double { Double(viewport.height) }
}

final class SVGInterpreter {
    let root: XNode
    let baseURL: URL?
    var ids: [String: XNode] = [:]
    var rules: [SVGValues.Rule] = []
    var lossNotes: Set<LossNote> = []
    var warnings: [String] = []
    var budget = 600_000
    var depth = 0
    var useStack: [XNode] = []

    init(root: XNode, baseURL: URL?) { self.root = root; self.baseURL = baseURL }

    // MARK: Run

    func run() -> VectorReadResult {
        index(root)
        collectStyles(root)
        let (width, height, viewBox) = documentSize()
        let pageW = width * 0.75, pageH = height * 0.75
        let vb = viewBoxTransform(viewBox: viewBox, preserveAspectRatio: root.attr("preserveAspectRatio"), width: width, height: height)
        let flip = VectorTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: pageH)
        let base = vb.then(.scale(0.75, 0.75)).then(flip)
        let viewport = viewBox.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: width, height: height)
        let props = computeProps(root, parent: Self.rootProps)
        var nodes: [VectorNode] = []
        renderChildren(of: root, ctx: SVGContext(ctm: base, props: props, viewport: viewport), into: &nodes)
        // The root's own opacity applies to everything drawn.
        if let o = props["opacity"], let value = Double(o), value < 1 { nodes = [.group(nodes, transform: .identity, clip: nil, opacity: max(0, value))] }
        var background: VectorColour?
        if let style = props["background-color"] ?? props["background"], let c = SVGValues.colour(style), c.alpha > 0 { background = c }
        let title = root.children.first(where: { $0.name == "title" })?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let page = VectorPage(size: VectorSize(width: pageW, height: pageH), background: background, nodes: nodes)
        return VectorReadResult(document: VectorDocument(pages: [page], title: title?.isEmpty == false ? title : nil),
                                lossNotes: lossNotes.sorted { $0.detail < $1.detail }, warnings: warnings)
    }

    static let rootProps: SVGProps = [
        "fill": "black", "fill-opacity": "1", "fill-rule": "nonzero", "stroke": "none", "stroke-width": "1", "stroke-opacity": "1",
        "stroke-linecap": "butt", "stroke-linejoin": "miter", "stroke-miterlimit": "4", "stroke-dasharray": "none", "stroke-dashoffset": "0",
        "clip-rule": "nonzero", "color": "black", "visibility": "visible", "font-size": "16", "font-family": "serif",
        "font-weight": "normal", "font-style": "normal", "text-anchor": "start", "letter-spacing": "0", "word-spacing": "0",
    ]

    func note(_ kind: LossNote.Kind, _ detail: String) {
        lossNotes.insert(LossNote(kind, detail: detail))
        if !warnings.contains(detail) { warnings.append(detail) }
    }

    func index(_ node: XNode) {
        if let id = node.attr("id"), ids[id] == nil { ids[id] = node }
        for child in node.children { index(child) }
    }

    func collectStyles(_ node: XNode) {
        if node.name == "style", (node.attr("type") ?? "text/css").contains("css") {
            rules += SVGValues.stylesheet(node.text, startOrder: rules.count)
        }
        for child in node.children { collectStyles(child) }
    }

    func reference(_ value: String?) -> XNode? {
        guard let value else { return nil }
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("url("), let close = text.firstIndex(of: ")") {
            text = String(text[text.index(text.startIndex, offsetBy: 4)..<close]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        }
        guard text.hasPrefix("#") else { return nil }
        return ids[String(text.dropFirst())]
    }

    // MARK: Document size and viewBox

    func documentSize() -> (Double, Double, CGRect?) {
        let vbNumbers = SVGValues.numberList(root.attr("viewBox"))
        let viewBox = vbNumbers.count == 4 && vbNumbers[2] > 0 && vbNumbers[3] > 0 ? CGRect(x: vbNumbers[0], y: vbNumbers[1], width: vbNumbers[2], height: vbNumbers[3]) : nil
        func dimension(_ key: String, vb: Double?) -> Double? {
            guard let l = SVGValues.length(root.attr(key)) else { return nil }
            if l.isPercent { return vb.map { $0 * l.value / 100 } }
            return Self.px(l, fontSize: 16)
        }
        var w = dimension("width", vb: viewBox.map { Double($0.width) }), h = dimension("height", vb: viewBox.map { Double($0.height) })
        if let vb = viewBox {
            let vbw = Double(vb.width), vbh = Double(vb.height)
            if w == nil, h == nil { w = vbw; h = vbh }
            else if w == nil { w = h! * vbw / vbh }
            else if h == nil { h = w! * vbh / vbw }
        }
        // No size at all: draw at 300 × 150 like browsers do for replaced elements without intrinsic size.
        return (max(1, w ?? 300), max(1, h ?? 150), viewBox)
    }

    static func px(_ l: SVGValues.Length, fontSize: Double, percentBase: Double = 0) -> Double {
        switch l.unit {
        case "", "px": return l.value
        case "pt": return l.value * 96 / 72
        case "pc": return l.value * 16
        case "mm": return l.value * 96 / 25.4
        case "cm": return l.value * 96 / 2.54
        case "in": return l.value * 96
        case "q": return l.value * 96 / 101.6
        case "em": return l.value * fontSize
        case "ex": return l.value * fontSize / 2
        case "rem": return l.value * 16
        case "%": return l.value * percentBase / 100
        default: return l.value
        }
    }

    /// The transform that fits a viewBox into a viewport of `width` × `height` (preserveAspectRatio).
    func viewBoxTransform(viewBox: CGRect?, preserveAspectRatio: String?, width: Double, height: Double) -> VectorTransform {
        guard let vb = viewBox else { return .identity }
        let parts = (preserveAspectRatio ?? "xMidYMid meet").split(separator: " ").map(String.init).filter { $0 != "defer" }
        let align = parts.first ?? "xMidYMid"
        let slice = parts.count > 1 && parts[1] == "slice"
        let vbw = Double(vb.width), vbh = Double(vb.height), vbx = Double(vb.minX), vby = Double(vb.minY)
        var sx = width / vbw, sy = height / vbh
        if align != "none" { let s = slice ? max(sx, sy) : min(sx, sy); sx = s; sy = s }
        var tx = -vbx * sx, ty = -vby * sy
        if align != "none" {
            let extraX = width - vbw * sx, extraY = height - vbh * sy
            if align.contains("xMid") { tx += extraX / 2 } else if align.contains("xMax") { tx += extraX }
            if align.contains("YMid") { ty += extraY / 2 } else if align.contains("YMax") { ty += extraY }
        }
        return VectorTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
    }

    // MARK: Properties and the cascade

    static let inherited: Set<String> = [
        "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap", "stroke-linejoin",
        "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "clip-rule", "color", "visibility", "font-family",
        "font-size", "font-weight", "font-style", "text-anchor", "letter-spacing", "word-spacing", "marker-start", "marker-mid",
        "marker-end", "direction", "font-variant", "text-decoration-line",
    ]
    static let presentation: Set<String> = inherited.union([
        "opacity", "display", "clip-path", "mask", "stop-color", "stop-opacity", "overflow", "filter", "transform",
        "background-color", "background", "mix-blend-mode", "isolation", "text-decoration", "baseline-shift", "dominant-baseline",
        "vector-effect", "paint-order", "marker", "font",
    ])

    func computeProps(_ node: XNode, parent: SVGProps) -> SVGProps {
        var props: SVGProps = [:]
        for key in Self.inherited { if let v = parent[key] { props[key] = v } }
        var declared: [(String, String, Int)] = []  // name, value, rank
        for (name, value) in node.attributes where Self.presentation.contains(name) { declared.append((name, value, 0)) }
        let matched = rules.filter { SVGValues.matches($0, node) }.sorted { ($0.specificity, $0.order) < ($1.specificity, $1.order) }
        for rule in matched { for d in rule.declarations { declared.append((d.name, d.value, d.important ? 4 : 1)) } }
        if let style = node.attr("style") { for d in SVGValues.declarations(style) { declared.append((d.name, d.value, d.important ? 5 : 2)) } }
        var rank: [String: Int] = [:]
        func set(_ name: String, _ value: String, _ r: Int) {
            guard r >= (rank[name] ?? -1) else { return }
            rank[name] = r
            props[name] = value == "inherit" ? parent[name] : value
        }
        for (name, value, r) in declared {
            if name == "marker" { for m in ["marker-start", "marker-mid", "marker-end"] { set(m, value, r) } }
            else if name == "font", let size = value.split(separator: " ").first(where: { SVGValues.length(String($0)) != nil }) { set("font-size", String(size), r) }
            else { set(name, value, r) }
        }
        // Resolve font-size to px so em/% in children compute against it.
        let parentSize = Double(parent["font-size"] ?? "16") ?? 16
        if let fs = props["font-size"] {
            if let l = SVGValues.length(fs) { props["font-size"] = String(Self.px(l, fontSize: parentSize, percentBase: parentSize)) }
            else {
                let keywords = ["xx-small": 9.0, "x-small": 10, "small": 13, "medium": 16, "large": 18, "x-large": 24, "xx-large": 32]
                if let k = keywords[fs] { props["font-size"] = String(k) }
                else if fs == "larger" { props["font-size"] = String(parentSize * 1.2) }
                else if fs == "smaller" { props["font-size"] = String(parentSize / 1.2) }
                else { props["font-size"] = String(parentSize) }
            }
        }
        return props
    }

    func fontSize(_ props: SVGProps) -> Double { Double(props["font-size"] ?? "16") ?? 16 }

    func length(_ text: String?, _ props: SVGProps, percentBase: Double, default def: Double = 0) -> Double {
        guard let l = SVGValues.length(text) else { return def }
        return Self.px(l, fontSize: fontSize(props), percentBase: percentBase)
    }

    // MARK: Traversal

    func renderChildren(of node: XNode, ctx: SVGContext, into out: inout [VectorNode]) {
        for child in node.children { render(child, ctx: ctx, into: &out) }
    }

    static let graphicElements: Set<String> = ["g", "a", "switch", "svg", "use", "rect", "circle", "ellipse", "line", "polyline", "polygon", "path", "text", "image", "foreignObject"]

    func render(_ node: XNode, ctx parent: SVGContext, into out: inout [VectorNode]) {
        guard Self.graphicElements.contains(node.name) else { return }
        budget -= 1
        guard budget > 0, depth < 128 else { return }
        depth += 1
        defer { depth -= 1 }

        var props = computeProps(node, parent: parent.props)
        if props["display"] == "none" { return }
        if !conditionsPass(node) { return }
        var ctx = SVGContext(ctm: parent.ctm, props: props, viewport: parent.viewport)
        let transform = node.attr("transform") ?? props["transform"]
        if let transform, node.name != "svg" || props["transform"] != nil { ctx.ctm = SVGValues.transform(transform).then(ctx.ctm) }
        props["transform"] = nil
        ctx.props = props

        if node.name == "foreignObject" { note(.otherLoss, "foreignObject"); return }
        if props["filter"] != nil, props["filter"] != "none" { note(.otherLoss, "filter") }

        var produced: [VectorNode] = []
        switch node.name {
        case "g", "a": renderChildren(of: node, ctx: ctx, into: &produced)
        case "switch":
            if let chosen = node.children.first(where: { Self.graphicElements.contains($0.name) && conditionsPass($0) }) { render(chosen, ctx: ctx, into: &produced) }
        case "svg": renderNestedSVG(node, ctx: ctx, widthOverride: nil, heightOverride: nil, into: &produced)
        case "use": renderUse(node, ctx: ctx, into: &produced)
        case "image": renderImage(node, ctx: ctx, into: &produced)
        case "text": renderText(node, ctx: ctx, into: &produced)
        default: renderShape(node, ctx: ctx, into: &produced)
        }
        if produced.isEmpty { return }

        // Compositing wrappers: clip, mask, then opacity.
        if let clipValue = props["clip-path"], clipValue != "none" { produced = applyClip(clipValue, to: produced, ctx: ctx, node: node) }
        if let maskValue = props["mask"], maskValue != "none" { produced = applyMask(maskValue, to: produced, ctx: ctx, node: node) }
        if let o = props["opacity"], let value = Double(o.trimmingCharacters(in: .whitespaces)), value < 1 {
            if !isShape(node) || shapeHasBoth(props) { produced = [.group(produced, transform: .identity, clip: nil, opacity: max(0, value))] }
            else { produced = produced.map { Self.scaleAlpha($0, value) } }
        }
        out.append(contentsOf: produced)
    }

    func isShape(_ node: XNode) -> Bool { ["rect", "circle", "ellipse", "line", "polyline", "polygon", "path"].contains(node.name) }
    func shapeHasBoth(_ props: SVGProps) -> Bool { (props["fill"] ?? "black") != "none" && (props["stroke"] ?? "none") != "none" }

    /// Multiplies a node's paint alphas (used when `opacity` applies to a shape with only one of fill and stroke).
    static func scaleAlpha(_ node: VectorNode, _ k: Double) -> VectorNode {
        func paint(_ p: VectorPaint?) -> VectorPaint? {
            guard let p else { return nil }
            switch p {
            case .solid(var c): c.alpha *= k; return .solid(c)
            case .linear(let a, let b, let stops): return .linear(from: a, to: b, stops: stops.map { var s = $0; s.colour.alpha *= k; return s })
            case .radial(let c, let r, let stops): return .radial(centre: c, radius: r, stops: stops.map { var s = $0; s.colour.alpha *= k; return s })
            case .rasterised: return p
            }
        }
        switch node {
        case .path(let seg, let fill, var stroke, let rule):
            if var s = stroke { s.paint = paint(s.paint) ?? s.paint; stroke = s }
            return .path(seg, fill: paint(fill), stroke: stroke, rule: rule)
        case .text(var run): run.fill = paint(run.fill) ?? run.fill; return .text(run)
        case .group(let kids, let t, let clip, let opacity): return .group(kids, transform: t, clip: clip, opacity: opacity * k)
        case .image: return .group([node], transform: .identity, clip: nil, opacity: k)
        }
    }

    func conditionsPass(_ node: XNode) -> Bool {
        if node.attr("requiredExtensions") != nil { return false }
        if let languages = node.attr("systemLanguage") {
            let wanted = languages.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if !wanted.contains(where: { $0 == "en" || $0.hasPrefix("en-") }) { return false }
        }
        return true
    }

    // MARK: Nested viewports, use

    func renderNestedSVG(_ node: XNode, ctx: SVGContext, widthOverride: Double?, heightOverride: Double?, into out: inout [VectorNode]) {
        var local = ctx
        let x = length(node.attr("x"), ctx.props, percentBase: ctx.vw)
        let y = length(node.attr("y"), ctx.props, percentBase: ctx.vh)
        let w = widthOverride ?? length(node.attr("width"), ctx.props, percentBase: ctx.vw, default: ctx.vw)
        let h = heightOverride ?? length(node.attr("height"), ctx.props, percentBase: ctx.vh, default: ctx.vh)
        guard w > 0, h > 0 else { return }
        let vbNumbers = SVGValues.numberList(node.attr("viewBox"))
        let vb = vbNumbers.count == 4 && vbNumbers[2] > 0 && vbNumbers[3] > 0 ? CGRect(x: vbNumbers[0], y: vbNumbers[1], width: vbNumbers[2], height: vbNumbers[3]) : nil
        let fit = viewBoxTransform(viewBox: vb, preserveAspectRatio: node.attr("preserveAspectRatio"), width: w, height: h)
        local.ctm = fit.then(.translation(x, y)).then(ctx.ctm)
        local.viewport = vb.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: w, height: h)
        var inner: [VectorNode] = []
        renderChildren(of: node, ctx: local, into: &inner)
        let overflow = ctx.props["overflow"] ?? "hidden"
        if overflow == "visible" || overflow == "auto" { out.append(contentsOf: inner) }
        else {
            let clip = PathBuilder.rect(x: x, y: y, width: w, height: h).transformed(by: ctx.ctm)
            out.append(.group(inner, transform: .identity, clip: clip, opacity: 1))
        }
    }

    func renderUse(_ node: XNode, ctx: SVGContext, into out: inout [VectorNode]) {
        guard let target = reference(node.attr("href")), !useStack.contains(where: { $0 === target }), useStack.count < 24 else { return }
        // A `use` cannot instantiate an ancestor of itself.
        var ancestor: XNode? = node
        while let a = ancestor { if a === target { return }; ancestor = a.parent }
        var local = ctx
        let x = length(node.attr("x"), ctx.props, percentBase: ctx.vw)
        let y = length(node.attr("y"), ctx.props, percentBase: ctx.vh)
        local.ctm = VectorTransform.translation(x, y).then(ctx.ctm)
        useStack.append(target)
        defer { _ = useStack.popLast() }
        if target.name == "symbol" || target.name == "svg" {
            let w = node.attr("width").map { length($0, ctx.props, percentBase: ctx.vw) }
            let h = node.attr("height").map { length($0, ctx.props, percentBase: ctx.vh) }
            var symbolCtx = local
            symbolCtx.props = computeProps(target, parent: ctx.props)
            if symbolCtx.props["display"] == "none" { return }
            // The symbol's own x/y are ignored; `use` supplies the position.
            let copy = XNode(name: "svg", attributes: target.attributes.filter { $0.key != "x" && $0.key != "y" })
            copy.children = target.children
            copy.parent = target.parent
            renderNestedSVG(copy, ctx: local, widthOverride: w, heightOverride: h, into: &out)
        } else {
            render(target, ctx: local, into: &out)
        }
    }
}
