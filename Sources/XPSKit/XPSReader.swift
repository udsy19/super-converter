import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore
import VectorKit

/// XPS, OpenXPS and DWFx packages → VectorDocument (formats §3.2): paths, canvases, solid/gradient/image brushes and glyph
/// runs, with embedded (obfuscated) fonts. Every feature the model cannot carry is reported as a loss note.
public enum XPSReader {
    public static func read(_ url: URL) throws -> VectorReadResult {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.damaged("xps") }
        return try read(data: data)
    }

    public static func read(data: Data) throws -> VectorReadResult {
        let package = try XPSPackage(data)
        let shared = XPSShared(zip: package.zip)
        var pages: [VectorPage] = []
        for part in try package.pageParts() {
            guard let bytes = try? package.zip.read(part), bytes.count < 128 << 20, let root = try? XMLTree.parse(bytes, format: "xps"), root.name == "FixedPage" else { continue }
            pages.append(XPSPageReader(part: part, shared: shared).page(root))
        }
        guard !pages.isEmpty else { throw ConversionError.damaged("xps") }
        return VectorReadResult(document: VectorDocument(pages: pages),
                                lossNotes: shared.lossNotes.sorted { ($0.kind.rawValue, $0.detail) < ($1.kind.rawValue, $1.detail) }, warnings: shared.warnings)
    }
}

/// State shared by the pages of one package.
final class XPSShared {
    let zip: ZipReader
    var lossNotes: Set<LossNote> = []
    var warnings: [String] = []
    var images: [String: ImageAsset?] = [:]
    var fonts: [String: XPSFont?] = [:]

    init(zip: ZipReader) { self.zip = zip }

    func note(_ kind: LossNote.Kind, _ detail: String) {
        lossNotes.insert(LossNote(kind, detail: detail))
        if !warnings.contains(detail) { warnings.append(detail) }
    }

    func image(_ part: String) -> ImageAsset? {
        if let hit = images[part] { return hit }
        var asset: ImageAsset?
        if let data = try? zip.read(part), data.count < 200 << 20 { asset = ImageBridge.asset(decoding: data) }
        images[part] = .some(asset)
        return asset
    }

    func font(_ part: String) -> XPSFont? {
        if let hit = fonts[part] { return hit }
        var font: XPSFont?
        if var data = try? zip.read(part), data.count < 100 << 20 {
            if let key = XPSSyntax.obfuscationKey(partName: part), part.lowercased().hasSuffix(".odttf") { data = XPSSyntax.xorFont(data, key: key) }
            font = XPSFont(data: data)
        }
        fonts[part] = .some(font)
        return font
    }
}

/// An embedded font program: carried on text runs, or opened for outlines.
struct XPSFont {
    let data: Data
    let cgFont: CGFont
    let postScriptName: String

    init?(data: Data) {
        guard data.count > 12, let provider = CGDataProvider(data: data as CFData), let cg = CGFont(provider) else { return nil }
        self.data = data; cgFont = cg
        postScriptName = (cg.postScriptName as String?) ?? "Embedded"
    }

    func ctFont(size: Double) -> CTFont { CTFontCreateWithGraphicsFont(cgFont, CGFloat(size), nil, nil) }
}

/// How a fill ended up: nothing, a paint in the shape's coordinates, a paint needing its own matrix, or drawn pictures.
enum XPSFill {
    case none
    case paint(VectorPaint)
    case skewed(VectorPaint, VectorTransform)
    case pictures([VectorNode])
}

final class XPSPageReader {
    let part: String
    let shared: XPSShared
    var dictionaries: [[String: XNode]] = []
    var budget = 400_000
    var depth = 0

    init(part: String, shared: XPSShared) { self.part = part; self.shared = shared }

    func page(_ root: XNode) -> VectorPage {
        let width = Double(root.attr("Width").flatMap { Double($0) } ?? 816), height = Double(root.attr("Height").flatMap { Double($0) } ?? 1056)
        let w = max(1, (width * 0.75 * 1000).rounded() / 1000), h = max(1, (height * 0.75 * 1000).rounded() / 1000)
        pushResources(of: root, owner: "FixedPage")
        var nodes: [VectorNode] = []
        for child in root.children where !child.name.contains(".") { render(child, into: &nodes) }
        let flip = VectorTransform(a: 0.75, b: 0, c: 0, d: -0.75, tx: 0, ty: h)
        return VectorPage(size: VectorSize(width: w, height: h), nodes: nodes.isEmpty ? [] : [.group(nodes, transform: flip, clip: nil, opacity: 1)])
    }

    // MARK: Resources

    func pushResources(of node: XNode, owner: String) {
        guard let holder = node.child("\(owner).Resources") else { return }
        var dict: [String: XNode] = [:]
        func collect(_ d: XNode, level: Int) {
            for item in d.children {
                if let key = item.attr("Key") { dict[key] = item }
            }
            if level < 3, let source = d.attr("Source") {
                let name = XPSSyntax.resolve(source, base: part)
                if let data = try? shared.zip.read(name), data.count < 8 << 20, let root = try? XMLTree.parse(data, format: "xps") { collect(root, level: level + 1) }
            }
        }
        for d in holder.children where d.name == "ResourceDictionary" { collect(d, level: 0) }
        dictionaries.append(dict)
    }

    func lookup(_ reference: String) -> XNode? {
        let t = reference.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("{StaticResource"), t.hasSuffix("}") else { return nil }
        let key = t.dropFirst("{StaticResource".count).dropLast().trimmingCharacters(in: .whitespaces)
        for d in dictionaries.reversed() { if let n = d[key] { return n } }
        return nil
    }

    func isReference(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).hasPrefix("{StaticResource") }

    // MARK: Elements

    func render(_ node: XNode, into out: inout [VectorNode]) {
        budget -= 1
        guard budget > 0, depth < 100 else { return }
        depth += 1
        defer { depth -= 1 }
        if node.attr("NavigateUri") != nil { shared.note(.hyperlinksDropped, "Links in the document were dropped") }
        if node.attr("OpacityMask") != nil || node.child("\(node.name).OpacityMask") != nil { shared.note(.otherLoss, "An opacity mask was ignored") }
        var produced: [VectorNode] = []
        let pushed = node.name == "Canvas" && node.child("Canvas.Resources") != nil
        if pushed { pushResources(of: node, owner: "Canvas") }
        defer { if pushed { _ = dictionaries.popLast() } }
        switch node.name {
        case "Canvas":
            for child in node.children where !child.name.contains(".") { render(child, into: &produced) }
        case "Path": renderPath(node, into: &produced)
        case "Glyphs": renderGlyphs(node, into: &produced)
        default: return
        }
        guard !produced.isEmpty else { return }
        let transform = matrixProperty(node, "RenderTransform") ?? .identity
        let clip = geometry(node, property: "Clip")?.segments
        var opacity = Double(node.attr("Opacity") ?? "1") ?? 1
        opacity = min(max(opacity, 0), 1)
        if transform.isIdentity, clip == nil, opacity >= 0.999 { out.append(contentsOf: produced) }
        else { out.append(.group(produced, transform: transform, clip: clip, opacity: opacity)) }
    }

    /// A matrix given as an attribute, a resource reference or a `<X.Prop><MatrixTransform Matrix="…"/></X.Prop>` child.
    func matrixProperty(_ node: XNode, _ property: String) -> VectorTransform? {
        if let a = node.attr(property) {
            if let n = lookup(a) { return XPSSyntax.matrix(n.attr("Matrix")) }
            return XPSSyntax.matrix(a)
        }
        if let holder = node.child("\(node.name).\(property)"), let m = holder.children.first { return XPSSyntax.matrix(m.attr("Matrix")) }
        return nil
    }

    // MARK: Geometry

    func geometry(_ node: XNode, property: String) -> (rule: FillRule, segments: [PathSegment])? {
        if let a = node.attr(property) {
            if let n = lookup(a) { return geometry(of: n) }
            let g = XPSSyntax.pathData(a)
            return g.segments.isEmpty ? nil : g
        }
        if let holder = node.child("\(node.name).\(property)"), let g = holder.children.first { return geometry(of: g) }
        return nil
    }

    func geometry(of node: XNode) -> (rule: FillRule, segments: [PathSegment])? {
        guard node.name == "PathGeometry" else { return nil }
        let rule: FillRule = (node.attr("FillRule") ?? "EvenOdd").lowercased() == "nonzero" ? .nonZero : .evenOdd
        var segments: [PathSegment] = []
        if let figures = node.attr("Figures") { segments += XPSSyntax.pathData(figures).segments }
        for fig in node.children where fig.name == "PathFigure" { segments += figure(fig) }
        if let t = matrixProperty(node, "Transform") { segments = segments.transformed(by: t) }
        return segments.isEmpty ? nil : (rule, segments)
    }

    func figure(_ fig: XNode) -> [PathSegment] {
        let start = XPSSyntax.points(fig.attr("StartPoint")).first ?? VectorPoint(0, 0)
        var out: [PathSegment] = [.move(start)]
        var cur = start
        for seg in fig.children {
            switch seg.name {
            case "PolyLineSegment":
                for p in XPSSyntax.points(seg.attr("Points")) { out.append(.line(p)); cur = p }
            case "PolyBezierSegment":
                let pts = XPSSyntax.points(seg.attr("Points"))
                for i in stride(from: 0, to: pts.count - 2, by: 3) { out.append(.cubic(pts[i], pts[i + 1], pts[i + 2])); cur = pts[i + 2] }
            case "PolyQuadraticBezierSegment":
                let pts = XPSSyntax.points(seg.attr("Points"))
                for i in stride(from: 0, to: pts.count - 1, by: 2) { out.append(.quad(pts[i], pts[i + 1])); cur = pts[i + 1] }
            case "ArcSegment":
                guard let end = XPSSyntax.points(seg.attr("Point")).first, let size = XPSSyntax.points(seg.attr("Size")).first else { continue }
                let rot = Double(seg.attr("RotationAngle") ?? "0") ?? 0
                let large = (seg.attr("IsLargeArc") ?? "false").lowercased() == "true"
                let sweep = (seg.attr("SweepDirection") ?? "Counterclockwise").lowercased() == "clockwise"
                let arcs = PathBuilder.arc(from: cur, to: end, rx: size.x, ry: size.y, rotation: rot, large: large, sweep: sweep)
                if arcs.isEmpty, end != cur { out.append(.line(end)) } else { out.append(contentsOf: arcs) }
                cur = end
            default: break
            }
        }
        if (fig.attr("IsClosed") ?? "false").lowercased() == "true" { out.append(.close) }
        return out
    }

    // MARK: Paths

    func renderPath(_ node: XNode, into out: inout [VectorNode]) {
        guard let (rule, segments) = geometry(node, property: "Data"), (node.attr("Visibility") ?? "Visible") != "Hidden" else { return }
        let bounds = segments.cgPath.boundingBoxOfPath
        let fill = fillFor(node, property: "Fill", bounds: bounds)
        var stroke: VectorStroke?
        if let spec = brushSpec(node, "Stroke") {
            let thickness = Double(node.attr("StrokeThickness") ?? "1") ?? 1
            if thickness > 0 {
                var paint: VectorPaint?
                switch makeFill(spec, bounds: bounds, segments: segments) {
                case .paint(let p): paint = p
                case .skewed(let p, _):
                    if case .linear(_, _, let s) = p { paint = s.first.map { .solid($0.colour) } } else if case .radial(_, _, let s) = p { paint = s.first.map { .solid($0.colour) } }
                    shared.note(.shadingRasterised, "A gradient stroke became a flat colour")
                case .pictures: shared.note(.otherLoss, "A picture stroke was drawn without the picture")
                case .none: break
                }
                if let paint {
                    var dashes = XPSSyntax.numbers(node.attr("StrokeDashArray")).map { $0 * thickness }
                    if dashes.count % 2 == 1 { dashes += dashes }
                    if dashes.contains(where: { $0 < 0 }) || dashes.reduce(0, +) <= 0 { dashes = [] }
                    let capName = (node.attr("StrokeStartLineCap") ?? "Flat").lowercased()
                    let cap: LineCap = capName == "round" ? .round : capName == "square" ? .square : .butt
                    let joinName = (node.attr("StrokeLineJoin") ?? "Miter").lowercased()
                    let join: LineJoin = joinName == "round" ? .round : joinName == "bevel" ? .bevel : .miter
                    if capName == "triangle" { shared.note(.otherLoss, "Triangle line caps were drawn flat") }
                    stroke = VectorStroke(paint: paint, width: thickness, dash: dashes, dashPhase: (Double(node.attr("StrokeDashOffset") ?? "0") ?? 0) * thickness,
                                          cap: cap, join: join, miterLimit: max(1, Double(node.attr("StrokeMiterLimit") ?? "10") ?? 10))
                }
            }
        }
        switch fill {
        case .none: if let stroke { out.append(.path(segments, fill: nil, stroke: stroke, rule: rule)) }
        case .paint(let p): out.append(.path(segments, fill: p, stroke: stroke, rule: rule))
        case .skewed(let p, let m):
            if let inverse = m.inverted { out.append(.group([.path(segments.transformed(by: inverse), fill: p, stroke: nil, rule: rule)], transform: m, clip: nil, opacity: 1)) }
            if let stroke { out.append(.path(segments, fill: nil, stroke: stroke, rule: rule)) }
        case .pictures(let nodes):
            if !nodes.isEmpty { out.append(.group(nodes, transform: .identity, clip: segments, opacity: 1)) }
            if let stroke { out.append(.path(segments, fill: nil, stroke: stroke, rule: rule)) }
        }
    }

    // MARK: Brushes

    enum Spec { case colour(VectorColour), node(XNode) }

    func colourValue(_ text: String) -> VectorColour? {
        guard let (c, approx) = XPSSyntax.colour(text) else { return nil }
        if approx { shared.note(.colourProfileDropped, "Colours with a profile were read without it") }
        return c
    }

    func brushSpec(_ node: XNode, _ property: String) -> Spec? {
        if let a = node.attr(property) {
            if let n = lookup(a) { return .node(n) }
            return colourValue(a).map { .colour($0) }
        }
        if let holder = node.child("\(node.name).\(property)"), let b = holder.children.first { return .node(b) }
        return nil
    }

    func fillFor(_ node: XNode, property: String, bounds: CGRect) -> XPSFill {
        guard let spec = brushSpec(node, property) else { return .none }
        return makeFill(spec, bounds: bounds, segments: nil)
    }

    func makeFill(_ spec: Spec, bounds: CGRect, segments: [PathSegment]?) -> XPSFill {
        switch spec {
        case .colour(let c): return .paint(.solid(c))
        case .node(let n):
            let opacity = min(max(Double(n.attr("Opacity") ?? "1") ?? 1, 0), 1)
            switch n.name {
            case "SolidColorBrush":
                guard let c = n.attr("Color").flatMap(colourValue) else { return .none }
                var colour = c; colour.alpha *= opacity
                return .paint(.solid(colour))
            case "LinearGradientBrush", "RadialGradientBrush": return gradient(n, bounds: bounds, opacity: opacity)
            case "ImageBrush": return imageBrush(n, bounds: bounds, opacity: opacity)
            case "VisualBrush":
                shared.note(.otherLoss, "A visual brush was left out")
                return .none
            default: return .none
            }
        }
    }

    func gradient(_ n: XNode, bounds: CGRect, opacity: Double) -> XPSFill {
        let linear = n.name == "LinearGradientBrush"
        var stops: [GradientStop] = []
        if let holder = n.child("\(n.name).GradientStops") {
            for s in holder.children where s.name == "GradientStop" {
                guard var c = s.attr("Color").flatMap(colourValue) else { continue }
                c.alpha *= opacity
                stops.append(GradientStop(offset: min(max(Double(s.attr("Offset") ?? "0") ?? 0, 0), 1), colour: c))
            }
        }
        stops.sort { $0.offset < $1.offset }
        guard !stops.isEmpty else { return .none }
        if stops.count == 1 { return .paint(.solid(stops[0].colour)) }
        let spread = (n.attr("SpreadMethod") ?? "Pad").lowercased()
        if spread != "pad" { shared.note(.otherLoss, "Repeating gradients were drawn without repeating") }
        let relative = (n.attr("MappingMode") ?? "Absolute").lowercased() != "absolute"
        var m = VectorTransform.identity
        let paint: VectorPaint
        if linear {
            let a = XPSSyntax.points(n.attr("StartPoint")).first ?? VectorPoint(0, 0), b = XPSSyntax.points(n.attr("EndPoint")).first ?? VectorPoint(relative ? 1 : 0, 0)
            paint = .linear(from: a, to: b, stops: stops)
        } else {
            let c = XPSSyntax.points(n.attr("Center")).first ?? VectorPoint(0.5, 0.5)
            let rx = Double(n.attr("RadiusX") ?? "0.5") ?? 0.5, ry = Double(n.attr("RadiusY") ?? "0.5") ?? 0.5
            guard rx > 0, ry > 0 else { return .paint(.solid(stops.last!.colour)) }
            paint = .radial(centre: VectorPoint(0, 0), radius: 1, stops: stops)
            m = VectorTransform.scale(rx, ry).then(.translation(c.x, c.y))
        }
        if let t = matrixProperty(n, "Transform") { m = m.then(t) }
        if relative {
            guard bounds.width > 0, bounds.height > 0 else { return .none }
            m = m.then(VectorTransform(a: Double(bounds.width), b: 0, c: 0, d: Double(bounds.height), tx: Double(bounds.minX), ty: Double(bounds.minY)))
        }
        if m.isIdentity { return .paint(paint) }
        if m.isSimilarity {
            switch paint {
            case .linear(let a, let b, let s): return .paint(.linear(from: m.apply(a), to: m.apply(b), stops: s))
            case .radial(let c, let r, let s): return .paint(.radial(centre: m.apply(c), radius: r * m.lengthScale, stops: s))
            default: break
            }
        }
        return .skewed(paint, m)
    }

    func rect4(_ text: String?) -> CGRect? {
        let n = XPSSyntax.numbers(text)
        return n.count == 4 ? CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) : nil
    }

    func imageBrush(_ n: XNode, bounds: CGRect, opacity: Double) -> XPSFill {
        guard let source = n.attr("ImageSource") else { return .none }
        let part = XPSSyntax.resolve(source, base: self.part)
        guard let asset = shared.image(part), let frame = asset.frames.first else {
            shared.note(.imagesDropped, "A picture couldn’t be decoded")
            return .none
        }
        let iw = Double(frame.width), ih = Double(frame.height)
        guard var viewbox = rect4(n.attr("Viewbox")), var viewport = rect4(n.attr("Viewport")), viewbox.width > 0, viewbox.height > 0 else { return .none }
        if (n.attr("ViewboxUnits") ?? "Absolute").lowercased() != "absolute" { viewbox = CGRect(x: viewbox.minX * iw, y: viewbox.minY * ih, width: viewbox.width * iw, height: viewbox.height * ih) }
        if (n.attr("ViewportUnits") ?? "Absolute").lowercased() != "absolute" {
            viewport = CGRect(x: bounds.minX + viewport.minX * bounds.width, y: bounds.minY + viewport.minY * bounds.height,
                              width: viewport.width * bounds.width, height: viewport.height * bounds.height)
        }
        guard viewport.width > 0, viewport.height > 0 else { return .none }
        let brushTransform = matrixProperty(n, "Transform") ?? .identity
        let unitToImage = VectorTransform(a: iw, b: 0, c: 0, d: -ih, tx: 0, ty: ih)
        let sx = Double(viewport.width / viewbox.width), sy = Double(viewport.height / viewbox.height)
        let toViewport = VectorTransform(a: sx, b: 0, c: 0, d: sy, tx: Double(viewport.minX) - Double(viewbox.minX) * sx, ty: Double(viewport.minY) - Double(viewbox.minY) * sy)
        let mode = (n.attr("TileMode") ?? "None").lowercased()
        var offsets: [(Double, Double)] = [(0, 0)]
        if mode != "none" {
            // Tile indices are counted in Double first: a tiny viewport gives numbers no Int holds (or NaN, which is no
            // tiling either).
            let i0 = floor(Double((bounds.minX - viewport.minX) / viewport.width)), i1 = ceil(Double((bounds.maxX - viewport.minX) / viewport.width))
            let j0 = floor(Double((bounds.minY - viewport.minY) / viewport.height)), j1 = ceil(Double((bounds.maxY - viewport.minY) / viewport.height))
            if mode != "tile" { shared.note(.otherLoss, "Mirrored picture tiles were drawn unmirrored") }
            if brushTransform.isIdentity, (i1 - i0) * (j1 - j0) <= 400, i1 > i0, j1 > j0, abs(i0) < 1e9, abs(j0) < 1e9 {
                offsets = []
                for j in Int(j0)..<Int(j1) { for i in Int(i0)..<Int(i1) { offsets.append((Double(i) * Double(viewport.width), Double(j) * Double(viewport.height))) } }
            } else if !brushTransform.isIdentity || !((i1 - i0) * (j1 - j0) <= 400) { shared.note(.otherLoss, "A tiled picture was drawn once") }
        }
        var nodes: [VectorNode] = []
        for (dx, dy) in offsets {
            let place = unitToImage.then(toViewport).then(.translation(dx, dy)).then(brushTransform)
            let cell = PathBuilder.rect(x: Double(viewport.minX) + dx, y: Double(viewport.minY) + dy, width: Double(viewport.width), height: Double(viewport.height)).transformed(by: brushTransform)
            nodes.append(.group([.image(asset, transform: place)], transform: .identity, clip: cell, opacity: opacity))
        }
        return .pictures(nodes)
    }

    // MARK: Glyphs

    func renderGlyphs(_ node: XNode, into out: inout [VectorNode]) {
        guard (node.attr("Visibility") ?? "Visible") != "Hidden", let text = node.attr("UnicodeString"), let em = node.attr("FontRenderingEmSize").flatMap({ Double($0) }), em > 0, em.isFinite else { return }
        let ox = Double(node.attr("OriginX") ?? "0") ?? 0, oy = Double(node.attr("OriginY") ?? "0") ?? 0
        guard let spec = brushSpec(node, "Fill") else { return }
        let box = CGRect(x: ox, y: oy - em, width: Double(text.count) * em * 0.6, height: em * 1.3)
        var paint: VectorPaint?
        switch makeFill(spec, bounds: box, segments: nil) {
        case .paint(let p): paint = p
        case .skewed(let p, _):
            if case .linear(_, _, let s) = p { paint = s.first.map { .solid($0.colour) } } else if case .radial(_, _, let s) = p { paint = s.first.map { .solid($0.colour) } }
        default: break
        }
        guard let fill = paint else { return }
        let fontPart = (node.attr("FontUri")).map { XPSSyntax.resolve($0, base: part) }
        let bidiOdd = (Int(node.attr("BidiLevel") ?? "0") ?? 0) % 2 == 1
        if let fontPart, let font = shared.font(fontPart) {
            let ct = font.ctFont(size: em)
            let chars = Array(text.utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            _ = CTFontGetGlyphsForCharacters(ct, chars, &glyphs, chars.count)
            // Indices: "gid,advance,uOff,vOff;…" (advance and offsets in 1/100 em); a glyph index outside 16 bits names none.
            var entries: [(gid: Int?, advance: Double?, du: Double, dv: Double)] = []
            if let indices = node.attr("Indices"), !indices.isEmpty {
                for raw in indices.split(separator: ";", omittingEmptySubsequences: false).prefix(200_000) {
                    var item = String(raw)
                    if item.hasPrefix("("), let close = item.firstIndex(of: ")") { item = String(item[item.index(after: close)...]) }
                    let f = item.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    entries.append((f.indices.contains(0) ? Int(f[0]).flatMap { CGGlyph(exactly: $0) }.map(Int.init) : nil, f.indices.contains(1) ? Double(f[1]) : nil,
                                    f.indices.contains(2) ? Double(f[2]) ?? 0 : 0, f.indices.contains(3) ? Double(f[3]) ?? 0 : 0))
                }
            } else {
                entries = glyphs.map { (Int($0), nil, 0, 0) }
            }
            // Text stays text in the embedded program (quality §6) when the program's own character map, advances and
            // positions give exactly what the Indices say; otherwise it is drawn as outlines.
            let natural = glyphs.map { g -> Double in var g = g, size = CGSize.zero; CTFontGetAdvancesForGlyphs(ct, .horizontal, &g, &size, 1); return Double(size.width) }
            let asText = !bidiOdd && !glyphs.contains(0) && entries.count <= glyphs.count && entries.enumerated().allSatisfy { i, e in
                (e.gid == nil || e.gid == Int(glyphs[i])) && e.du == 0 && e.dv == 0 && (e.advance.map { abs($0 * em / 100 - natural[i]) <= max(0.01, natural[i] * 0.01) } ?? true)
            }
            if asText {
                let run = VectorTextRun(text: text, fontName: font.postScriptName, size: em, origin: VectorPoint(0, 0), fill: fill, fontData: font.data)
                out.append(.group([.text(run)], transform: VectorTransform(a: 1, b: 0, c: 0, d: -1, tx: ox, ty: oy), clip: nil, opacity: 1))
                return
            }
            var outline: [PathSegment] = []
            var pen = ox
            for (i, e) in entries.enumerated() {
                let gid = e.gid ?? (i < glyphs.count ? Int(glyphs[i]) : 0)
                var advance = e.advance.map { $0 * em / 100 }
                if advance == nil {
                    var g = CGGlyph(gid), size = CGSize.zero
                    CTFontGetAdvancesForGlyphs(ct, .horizontal, &g, &size, 1)
                    advance = Double(size.width)
                }
                let adv = advance ?? 0
                let x = (bidiOdd ? pen - adv : pen) + e.du * em / 100, y = oy - e.dv * em / 100
                if let path = CTFontCreatePathForGlyph(ct, CGGlyph(gid), nil) {
                    outline += path.segments.transformed(by: VectorTransform(a: 1, b: 0, c: 0, d: -1, tx: x, ty: y))
                }
                pen += bidiOdd ? -adv : adv
            }
            if !outline.isEmpty {
                out.append(.path(outline, fill: fill, stroke: nil, rule: .nonZero))
                shared.note(.textAsOutlines, "Text in embedded fonts")
            }
            return
        }
        // No usable embedded program: keep the text, named after the font file.
        var name = ((fontPart ?? "Helvetica") as NSString).lastPathComponent
        if let dot = name.lastIndex(of: "."), dot != name.startIndex { name = String(name[..<dot]) }
        if name.isEmpty || XPSSyntax.obfuscationKey(partName: name + ".odttf") != nil { name = "Helvetica" }
        shared.note(.fontsReplaced, "Fonts the file didn’t carry were replaced")
        let run = VectorTextRun(text: text, fontName: name, size: em, origin: VectorPoint(0, 0), fill: fill)
        out.append(.group([.text(run)], transform: VectorTransform(a: 1, b: 0, c: 0, d: -1, tx: ox, ty: oy), clip: nil, opacity: 1))
    }
}
