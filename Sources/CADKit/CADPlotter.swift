import Foundation
import SuperConverterCore

// Plotting (formats §3.2, quality §6): a `CADDrawing` becomes a `VectorDocument` page per sheet, zoomed to extents. The drawing
// is first flattened into drawing-space primitives (inserts expanded, BYLAYER/BYBLOCK resolved, text laid out), the extents are
// measured on those, and only then are they mapped to page points. Writing the SVG, PDF, EPS or raster file is the next
// step's business (VectorKit, RenderKit).

public struct CADPlotOptions: Sendable {
    /// One page per paper-space layout instead of model space.
    public var allLayouts = false
    /// Extents from the 0.1–99.9 percentile of the geometry, so stray far-away entities don't shrink the drawing.
    public var autoZoom = true
    /// "fit", "a4", "a3", "a2", "a1", "a0" or "letter".
    public var paper = "fit"
    public var monochrome = false
    public var background = VectorColour(red: 1, green: 1, blue: 1)
    public var thinLines = false
    /// The long side of a page that fits the drawing, in points.
    public var longSide = 842.0

    public init() {}

    /// From the O-CAD options. Raster targets get a page whose long side is the requested size in pixels at the 96 dpi that
    /// RenderKit renders vector pages at by default.
    public init(_ options: OptionValues, rasterTarget: Bool) {
        allLayouts = options["allLayouts"]?.bool ?? false
        autoZoom = options["autoZoom"]?.bool ?? true
        paper = options["paper"]?.string ?? "fit"
        monochrome = options["colours"]?.string == "mono"
        thinLines = options["lineWeights"]?.string == "thin"
        if let hex = options["background"]?.string, let colour = VectorColour(hex: hex) { background = colour }
        if rasterTarget {
            let pixels = Double(options["width"]?.int ?? options["height"]?.int ?? 3000)
            longSide = pixels * 72 / 96
        }
    }
}

extension VectorColour {
    /// "#RRGGBB".
    init?(hex: String) {
        let t = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard t.count == 6, let v = Int(t, radix: 16) else { return nil }
        self.init(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
    }
}

public enum CADPlotter {
    public struct Result: Sendable {
        public var document: VectorDocument
        public var lossNotes: [LossNote]
    }

    public static func plot(_ drawing: CADDrawing, options: CADPlotOptions = CADPlotOptions()) -> Result {
        var plot = Plot(drawing: drawing, options: options)
        return plot.run()
    }
}

// MARK: - Primitives (drawing space)

private struct Affine {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0
    static let identity = Affine()

    func apply(_ p: (Double, Double)) -> (Double, Double) { (a * p.0 + c * p.1 + tx, b * p.0 + d * p.1 + ty) }
    func linear(_ v: (Double, Double)) -> (Double, Double) { (a * v.0 + c * v.1, b * v.0 + d * v.1) }
    /// `self` after `other` (other applies first).
    func concat(_ o: Affine) -> Affine {
        Affine(a: a * o.a + c * o.b, b: b * o.a + d * o.b, c: a * o.c + c * o.d, d: b * o.c + d * o.d,
               tx: a * o.tx + c * o.ty + tx, ty: b * o.tx + d * o.ty + ty)
    }
    static func translation(_ x: Double, _ y: Double) -> Affine { Affine(tx: x, ty: y) }
    static func scale(_ x: Double, _ y: Double) -> Affine { Affine(a: x, d: y) }
    static func rotation(_ radians: Double) -> Affine { Affine(a: cos(radians), b: sin(radians), c: -sin(radians), d: cos(radians)) }
}

private struct StrokeSpec {
    var colour: VectorColour
    var weight: Double
    /// Drawing units, already multiplied by the linetype scales.
    var dash: [Double]
}

private struct TextPrim {
    var text: String
    var font: String
    var origin: (Double, Double)
    var height: Double
    var rotation: Double
    var widthFactor: Double
    var oblique: Double
    var colour: VectorColour
    /// The far end of the baseline, for extents.
    var end: (Double, Double)
}

private struct HatchFamily {
    var direction: (Double, Double)
    var base: (Double, Double)
    var offset: (Double, Double)
    var dashes: [Double]
}

private indirect enum Prim {
    case path(segments: [PathSegment], fill: VectorColour?, stroke: StrokeSpec?)
    case text(TextPrim)
    case dot(x: Double, y: Double, colour: VectorColour)
    case hatch(loops: [[(Double, Double)]], families: [HatchFamily], colour: VectorColour, weight: Double)
    case clipped([Prim], clip: [(Double, Double)])
}

// MARK: - Context

private struct Context {
    var affine = Affine.identity
    /// The layer "0" entities in a block take.
    var layer = "0"
    var blockColour: VectorColour?
    var blockLineType: [Double]?
    var blockWeight: Double?
    var inBlock = false
    var depth = 0
    var blockStack: [String] = []
}

private struct Plot {
    let drawing: CADDrawing
    let options: CADPlotOptions
    var layers: [String: CADDrawing.Layer] = [:]
    var lineTypes: [String: [Double]] = [:]
    var styles: [String: CADDrawing.TextStyle] = [:]
    var blocks: [String: CADDrawing.Block] = [:]
    var shxFonts = Set<String>()
    var imagesSkipped = 0
    var foreground: VectorColour
    /// Entities left to draw. Nested and arrayed inserts multiply (ten inserts of a block of ten inserts, twelve levels
    /// deep), so a small damaged file could otherwise ask for more geometry than memory holds; the rest is left out.
    static let maxEntities = 1_000_000
    var entityBudget = Plot.maxEntities
    var entitiesLeftOut = false

    init(drawing: CADDrawing, options: CADPlotOptions) {
        self.drawing = drawing
        self.options = options
        let b = options.background
        let dark = 0.299 * b.red + 0.587 * b.green + 0.114 * b.blue < 0.5
        foreground = dark ? VectorColour(red: 1, green: 1, blue: 1) : VectorColour(red: 0, green: 0, blue: 0)
        for l in drawing.layers { layers[l.name.lowercased()] = l }
        for t in drawing.lineTypes { lineTypes[t.name.lowercased()] = t.pattern }
        for s in drawing.textStyles { styles[s.name.lowercased()] = s }
        for b in drawing.blocks { blocks[b.name.lowercased()] = b }
    }

    // MARK: Pages

    mutating func run() -> CADPlotter.Result {
        var pages: [VectorPage] = []
        let modelHasContent = !drawing.modelSpace.isEmpty
        let layoutsWithContent = drawing.layouts.filter { !$0.entities.isEmpty }
        if options.allLayouts, !drawing.layouts.isEmpty {
            for layout in drawing.layouts { pages.append(page(for: layout)) }
        } else if !modelHasContent, let first = layoutsWithContent.first {
            pages.append(page(for: first))
        } else {
            var context = Context()
            let prims = generate(drawing.modelSpace, &context)
            pages.append(compose(prims, paperSize: nil))
        }
        var notes: [LossNote] = []
        if !shxFonts.isEmpty {
            notes.append(LossNote(.fontsReplaced, detail: "\(shxFonts.count) CAD font\(shxFonts.count == 1 ? "" : "s") → Helvetica"))
        }
        if entitiesLeftOut { notes.append(LossNote(.otherLoss, detail: "Not drawn: the blocks expand to more than \(Plot.maxEntities) entities")) }
        if imagesSkipped > 0 { notes.append(LossNote(.imagesDropped, detail: "\(imagesSkipped) attached image\(imagesSkipped == 1 ? "" : "s") drawn as outlines")) }
        return CADPlotter.Result(document: VectorDocument(pages: pages), lossNotes: notes)
    }

    private mutating func page(for layout: CADDrawing.Layout) -> VectorPage {
        var prims: [Prim] = []
        var context = Context()
        for entity in layout.entities {
            if case .viewport(let centre, let w, let h, let viewCentre, let viewHeight, let layerName) = unwrap(entity).entity,
               viewHeight > 0, w > 0, h > 0, isVisible(layerName, context) {
                let scale = h / viewHeight
                var inner = Context()
                inner.affine = Affine.translation(centre.x, centre.y).concat(.scale(scale, scale)).concat(.translation(-viewCentre.x, -viewCentre.y))
                let content = generate(drawing.modelSpace, &inner)
                let clip = [(centre.x - w / 2, centre.y - h / 2), (centre.x + w / 2, centre.y - h / 2),
                            (centre.x + w / 2, centre.y + h / 2), (centre.x - w / 2, centre.y + h / 2)]
                prims.append(.clipped(content, clip: clip))
            } else {
                prims.append(contentsOf: generate([entity], &context))
            }
        }
        return compose(prims, paperSize: layout.paperSize)
    }

    // MARK: Composition (drawing space → page)

    private func compose(_ prims: [Prim], paperSize: VectorSize?) -> VectorPage {
        var xs: [Double] = [], ys: [Double] = []
        for prim in prims { collect(prim, &xs, &ys) }
        var minX = 0.0, maxX = 100.0, minY = 0.0, maxY = 100.0
        if let paperSize {
            maxX = paperSize.width; maxY = paperSize.height
        } else if !xs.isEmpty {
            xs.sort(); ys.sort()
            let n = xs.count
            let lo = options.autoZoom ? Int(Double(n - 1) * 0.001) : 0
            let hi = options.autoZoom ? Int((Double(n - 1) * 0.999).rounded(.up)) : n - 1
            // Coordinates near the limit of a Double can span more than one: such extents fall back to the default sheet.
            if (xs[hi] - xs[lo]).isFinite && (ys[hi] - ys[lo]).isFinite { minX = xs[lo]; maxX = xs[hi]; minY = ys[lo]; maxY = ys[hi] }
        }
        let width = max(maxX - minX, 1e-9), height = max(maxY - minY, 1e-9)
        // Page size: a named paper, or the drawing's shape with the long side fixed.
        let mmToPt = 72 / 25.4
        let named: [String: (Double, Double)] = ["a4": (297, 210), "a3": (420, 297), "a2": (594, 420), "a1": (841, 594),
                                                 "a0": (1189, 841), "letter": (279.4, 215.9)]
        var page: VectorSize
        var margin: Double
        if let paper = named[options.paper] {
            let landscape = width >= height
            page = VectorSize(width: (landscape ? paper.0 : paper.1) * mmToPt, height: (landscape ? paper.1 : paper.0) * mmToPt)
            margin = 10 * mmToPt
        } else if paperSize != nil {
            let k = options.longSide / max(width, height)
            page = VectorSize(width: width * k, height: height * k)
            margin = 0
        } else {
            let m = options.longSide * 0.02
            let k = (options.longSide - 2 * m) / max(width, height)
            page = VectorSize(width: width * k + 2 * m, height: height * k + 2 * m)
            margin = m
        }
        let scale = min((page.width - 2 * margin) / width, (page.height - 2 * margin) / height)
        let offX = (page.width - width * scale) / 2 - minX * scale
        let offY = (page.height - height * scale) / 2 - minY * scale
        let toPage = Affine(a: scale, d: scale, tx: offX, ty: offY)
        var nodes: [VectorNode] = []
        for prim in prims { nodes.append(contentsOf: emit(prim, toPage, scale)) }
        return VectorPage(size: page, background: options.background, nodes: nodes)
    }

    private func collect(_ prim: Prim, _ xs: inout [Double], _ ys: inout [Double]) {
        func add(_ p: (Double, Double)) { if p.0.isFinite && p.1.isFinite { xs.append(p.0); ys.append(p.1) } }
        switch prim {
        case .path(let segments, _, _):
            for s in segments {
                switch s {
                case .move(let p), .line(let p): add((p.x, p.y))
                case .cubic(_, _, let p): add((p.x, p.y))
                case .quad(_, let p): add((p.x, p.y))
                case .close: break
                }
            }
        case .text(let t): add(t.origin); add(t.end)
        case .dot(let x, let y, _): add((x, y))
        case .hatch(let loops, _, _, _): for loop in loops { loop.forEach(add) }
        case .clipped(_, let clip): clip.forEach(add)
        }
    }

    // MARK: Emission

    private func emit(_ prim: Prim, _ toPage: Affine, _ s: Double) -> [VectorNode] {
        func pt(_ p: VectorPoint) -> VectorPoint { let q = toPage.apply((p.x, p.y)); return VectorPoint(q.0, q.1) }
        func map(_ segments: [PathSegment]) -> [PathSegment] {
            segments.map {
                switch $0 {
                case .move(let p): .move(pt(p))
                case .line(let p): .line(pt(p))
                case .cubic(let a, let b, let c): .cubic(pt(a), pt(b), pt(c))
                case .quad(let a, let b): .quad(pt(a), pt(b))
                case .close: .close
                }
            }
        }
        switch prim {
        case .path(let segments, let fill, let stroke):
            let strokeSpec = stroke.map { spec -> VectorStroke in
                let width = options.thinLines ? 0.5 : max(spec.weight, 0.5)
                let dash = spec.dash.map { $0 * s }
                let period = dash.reduce(0) { $0 + abs($1) }
                // A pattern finer than a point would only smear the line.
                let usable = period >= 1.5 && dash.count >= 2
                return VectorStroke(paint: .solid(spec.colour), width: width,
                                    dash: usable ? dash.map { $0 == 0 ? width * 0.5 : abs($0) } : [])
            }
            return [.path(map(segments), fill: fill.map { .solid($0) }, stroke: strokeSpec)]
        case .dot(let x, let y, let colour):
            let c = toPage.apply((x, y)), r = 1.0, k = 0.5523 * r
            let seg: [PathSegment] = [
                .move(VectorPoint(c.0 + r, c.1)),
                .cubic(VectorPoint(c.0 + r, c.1 + k), VectorPoint(c.0 + k, c.1 + r), VectorPoint(c.0, c.1 + r)),
                .cubic(VectorPoint(c.0 - k, c.1 + r), VectorPoint(c.0 - r, c.1 + k), VectorPoint(c.0 - r, c.1)),
                .cubic(VectorPoint(c.0 - r, c.1 - k), VectorPoint(c.0 - k, c.1 - r), VectorPoint(c.0, c.1 - r)),
                .cubic(VectorPoint(c.0 + k, c.1 - r), VectorPoint(c.0 + r, c.1 - k), VectorPoint(c.0 + r, c.1)),
                .close]
            return [.path(seg, fill: .solid(colour), stroke: nil)]
        case .text(let t):
            let o = toPage.apply(t.origin)
            let size = t.height * s
            guard size > 0.05 else { return [] }
            let cosθ = cos(t.rotation), sinθ = sin(t.rotation), shear = tan(t.oblique * .pi / 180)
            let transform = VectorTransform(a: t.widthFactor * cosθ, b: t.widthFactor * sinθ, c: shear * cosθ - sinθ, d: shear * sinθ + cosθ,
                                            tx: o.0, ty: o.1)
            let run = VectorTextRun(text: t.text, fontName: t.font, size: size, origin: VectorPoint(0, 0), fill: .solid(t.colour))
            return [.group([.text(run)], transform: transform, clip: nil, opacity: 1)]
        case .clipped(let prims, let clip):
            let pts = clip.map { toPage.apply($0) }
            let rect: [PathSegment] = [.move(VectorPoint(pts[0].0, pts[0].1))] + pts.dropFirst().map { .line(VectorPoint($0.0, $0.1)) } + [.close]
            return [.group(prims.flatMap { emit($0, toPage, s) }, transform: .identity, clip: rect, opacity: 1)]
        case .hatch(let loops, let families, let colour, let weight):
            return emitHatch(loops, families, colour, weight, toPage, s)
        }
    }

    private func emitHatch(_ rawLoops: [[(Double, Double)]], _ families: [HatchFamily], _ colour: VectorColour, _ weight: Double,
                           _ toPage: Affine, _ s: Double) -> [VectorNode] {
        let loops = Plot.orient(rawLoops)
        func path(_ loops: [[(Double, Double)]]) -> [PathSegment] {
            loops.flatMap { loop -> [PathSegment] in
                let pts = loop.map { toPage.apply($0) }
                return [.move(VectorPoint(pts[0].0, pts[0].1))] + pts.dropFirst().map { PathSegment.line(VectorPoint($0.0, $0.1)) } + [.close]
            }
        }
        func solid(_ alpha: Double) -> [VectorNode] {
            var c = colour; c.alpha = alpha
            return [.path(path(loops), fill: .solid(c), stroke: nil)]
        }
        // Bounding box of the loops.
        let all = loops.flatMap { $0 }
        guard let first = all.first else { return [] }
        var box = (minX: first.0, maxX: first.0, minY: first.1, maxY: first.1)
        for p in all { box.minX = min(box.minX, p.0); box.maxX = max(box.maxX, p.0); box.minY = min(box.minY, p.1); box.maxY = max(box.maxY, p.1) }
        let corners = [(box.minX, box.minY), (box.maxX, box.minY), (box.maxX, box.maxY), (box.minX, box.maxY)]
        var segments: [PathSegment] = []
        var budget = 8000
        for family in families {
            let d = family.direction, n = (-d.1, d.0)
            let stepN = family.offset.0 * n.0 + family.offset.1 * n.1
            let stepD = family.offset.0 * d.0 + family.offset.1 * d.1
            // Lines too close together to resolve on the page become a light tint instead.
            guard abs(stepN) * s >= 2 else { return solid(0.35) }
            let tProj = corners.map { $0.0 * n.0 + $0.1 * n.1 }, sProj = corners.map { $0.0 * d.0 + $0.1 * d.1 }
            let baseN = family.base.0 * n.0 + family.base.1 * n.1, baseD = family.base.0 * d.0 + family.base.1 * d.1
            let k0 = (tProj.min()! - baseN) / stepN, k1 = (tProj.max()! - baseN) / stepN
            // More lines than the budget (or a range past what an Int holds) is a tint as well.
            let kMin = min(k0, k1).rounded(.down), kMax = max(k0, k1).rounded(.up)
            guard kMax - kMin < Double(budget), abs(kMin) < 1e15 else { return solid(0.35) }
            let kLow = Int(kMin), kHigh = Int(kMax)
            let sMin = sProj.min()!, sMax = sProj.max()!
            let period = family.dashes.reduce(0) { $0 + abs($1) }
            for k in kLow...kHigh {
                let t = baseN + Double(k) * stepN
                func line(_ from: Double, _ to: Double) {
                    let lo = max(from, sMin), hi = min(to, sMax)
                    guard hi > lo else { return }
                    let a = toPage.apply((d.0 * lo + n.0 * t, d.1 * lo + n.1 * t)), b = toPage.apply((d.0 * hi + n.0 * t, d.1 * hi + n.1 * t))
                    segments.append(.move(VectorPoint(a.0, a.1))); segments.append(.line(VectorPoint(b.0, b.1)))
                }
                if period <= 0 || family.dashes.count < 2 {
                    line(sMin, sMax)
                } else {
                    guard period * s >= 1.5 else { line(sMin, sMax); continue }
                    let origin = baseD + Double(k) * stepD
                    var position = origin + ((sMin - origin) / period).rounded(.down) * period
                    budget -= 1
                    outer: while position < sMax {
                        // Far from the origin a whole period can be below a Double's resolution: the line stops there.
                        let cycleStart = position
                        for item in family.dashes {
                            if item > 0 { line(position, position + item) }
                            position += abs(item)
                            if position >= sMax { break outer }
                        }
                        if segments.count > 40_000 || position == cycleStart { break }
                    }
                }
            }
        }
        guard !segments.isEmpty else { return solid(0.35) }
        let stroke = VectorStroke(paint: .solid(colour), width: options.thinLines ? 0.5 : max(min(weight, 0.5), 0.35))
        let hatchPath = VectorNode.path(segments, fill: nil, stroke: stroke)
        return [.group([hatchPath], transform: .identity, clip: path(loops), opacity: 1)]
    }

    /// Loops oriented by nesting depth (outer counter-clockwise, islands clockwise, and so on), so a non-zero fill leaves holes.
    static func orient(_ loops: [[(Double, Double)]]) -> [[(Double, Double)]] {
        func area(_ l: [(Double, Double)]) -> Double {
            var a = 0.0
            for i in l.indices { let p = l[i], q = l[(i + 1) % l.count]; a += p.0 * q.1 - q.0 * p.1 }
            return a / 2
        }
        func contains(_ l: [(Double, Double)], _ p: (Double, Double)) -> Bool {
            var inside = false
            var j = l.count - 1
            for i in l.indices {
                let a = l[i], b = l[j]
                if (a.1 > p.1) != (b.1 > p.1), p.0 < (b.0 - a.0) * (p.1 - a.1) / (b.1 - a.1) + a.0 { inside.toggle() }
                j = i
            }
            return inside
        }
        return loops.enumerated().map { index, loop in
            let depth = loops.enumerated().filter { $0.offset != index && $0.element.count >= 3 && contains($0.element, loop[0]) }.count
            let counterClockwise = area(loop) > 0
            return (depth % 2 == 0) == counterClockwise ? loop : loop.reversed()
        }
    }

    // MARK: Generation

    private func unwrap(_ e: CADDrawing.Entity) -> (entity: CADDrawing.Entity, appearance: CADDrawing.Appearance?) {
        if case .styled(let inner, let a) = e { let (u, _) = unwrap(inner); return (u, a) }
        return (e, nil)
    }

    private func layerOf(_ e: CADDrawing.Entity) -> String {
        switch e {
        case .line(_, _, let l), .polyline(_, _, _, let l), .circle(_, _, let l), .arc(_, _, _, _, let l), .ellipse(_, _, _, _, _, let l),
             .spline(_, _, _, _, let l), .text(_, _, _, _, _, _, _, let l), .multilineText(_, _, _, _, _, _, _, let l),
             .insert(_, _, _, _, let l), .hatch(_, _, _, _, let l), .point(_, let l), .solid(_, let l), .image(_, _, _, let l),
             .viewport(_, _, _, _, _, let l):
            return l
        case .styled(let inner, _): return layerOf(inner)
        }
    }

    private func effectiveLayer(_ name: String, _ context: Context) -> String { name == "0" && context.inBlock ? context.layer : name }

    private func isVisible(_ name: String, _ context: Context) -> Bool {
        layers[effectiveLayer(name, context).lowercased()]?.isVisible ?? true
    }

    private func colour(_ appearance: CADDrawing.Appearance?, layer: String, _ context: Context) -> VectorColour {
        func fromIndex(_ i: Int) -> VectorColour {
            if options.monochrome || i == 7 { return foreground }
            let c = ACI.rgb(i)
            return VectorColour(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
        }
        func fromRGB(_ v: Int) -> VectorColour {
            options.monochrome ? foreground : VectorColour(red: Double(v >> 16 & 255) / 255, green: Double(v >> 8 & 255) / 255, blue: Double(v & 255) / 255)
        }
        let l = layers[layer.lowercased()]
        let fromLayer: VectorColour = l.map { $0.trueColour.map(fromRGB) ?? fromIndex($0.colourIndex) } ?? foreground
        if let t = appearance?.trueColour { return fromRGB(t) }
        guard let index = appearance?.colourIndex else { return fromLayer }
        if index == 0 { return options.monochrome ? foreground : (context.blockColour ?? foreground) }
        return fromIndex(index)
    }

    private func weight(_ appearance: CADDrawing.Appearance?, layer: String, _ context: Context) -> Double {
        let mm: Double
        let layerWeight = layers[layer.lowercased()]?.lineWeight
        if let w = appearance?.lineWeight { mm = w < 0 ? (context.blockWeight ?? layerWeight ?? 0.25) : w } else { mm = layerWeight ?? 0.25 }
        return mm * 72 / 25.4
    }

    private func dashPattern(_ appearance: CADDrawing.Appearance?, layer: String, _ context: Context) -> [Double] {
        var name = appearance?.lineType ?? layers[layer.lowercased()]?.lineType ?? "CONTINUOUS"
        if name.uppercased() == "BYLAYER" { name = layers[layer.lowercased()]?.lineType ?? "CONTINUOUS" }
        if name.uppercased() == "BYBLOCK" { return context.blockLineType ?? [] }
        let scale = drawing.lineTypeScale * (appearance?.lineTypeScale ?? 1)
        return (lineTypes[name.lowercased()] ?? []).map { $0 * scale }
    }

    private mutating func generate(_ entities: [CADDrawing.Entity], _ context: inout Context) -> [Prim] {
        var out: [Prim] = []
        for e in entities { out.append(contentsOf: generate(e, context)) }
        return out
    }

    private mutating func generate(_ entity: CADDrawing.Entity, _ context: Context) -> [Prim] {
        guard entityBudget > 0 else { entitiesLeftOut = true; return [] }
        entityBudget -= 1
        let (e, appearance) = unwrap(entity)
        let layerName = effectiveLayer(layerOf(e), context)
        guard isVisible(layerName, context) else { return [] }
        let affine = context.affine
        let colour = self.colour(appearance, layer: layerName, context)
        let stroke = StrokeSpec(colour: colour, weight: weight(appearance, layer: layerName, context),
                                dash: dashPattern(appearance, layer: layerName, context))
        func P(_ x: Double, _ y: Double) -> VectorPoint { let q = affine.apply((x, y)); return VectorPoint(q.0, q.1) }

        switch e {
        case .line(let a, let b, _):
            return [.path(segments: [.move(P(a.x, a.y)), .line(P(b.x, b.y))], fill: nil, stroke: stroke)]
        case .polyline(let pts, let closed, let bulges, _):
            return [.path(segments: polylineSegments(pts, closed: closed, bulges: bulges, P), fill: nil, stroke: stroke)]
        case .circle(let c, let r, _):
            return [.path(segments: arcSegments(c.x, c.y, r, r, 0, 0, 2 * .pi, P) + [.close], fill: nil, stroke: stroke)]
        case .arc(let c, let r, let a0, let a1, _):
            var sweep = (a1 - a0).truncatingRemainder(dividingBy: 360)
            if sweep <= 0 { sweep += 360 }
            return [.path(segments: arcSegments(c.x, c.y, r, r, 0, a0 * .pi / 180, sweep * .pi / 180, P), fill: nil, stroke: stroke)]
        case .ellipse(let c, let major, let ratio, let t0, let t1, _):
            var sweep = t1 - t0
            if sweep <= 1e-9 { sweep += 2 * .pi }
            let rx = hypot(major.x, major.y)
            let full = abs(sweep - 2 * .pi) < 1e-6
            return [.path(segments: arcSegments(c.x, c.y, rx, rx * ratio, atan2(major.y, major.x), t0, sweep, P) + (full ? [.close] : []),
                          fill: nil, stroke: stroke)]
        case .spline(let degree, let control, let knots, let weights, _):
            let pts = NURBS.sample(degree: degree, controls: control, knots: knots, weights: weights, samples: max(24, control.count * 10))
            guard pts.count >= 2 else { return [] }
            return [.path(segments: [.move(P(pts[0].x, pts[0].y))] + pts.dropFirst().map { .line(P($0.x, $0.y)) }, fill: nil, stroke: stroke)]
        case .point(let p, _):
            let q = affine.apply((p.x, p.y))
            return [.dot(x: q.0, y: q.1, colour: colour)]
        case .solid(let pts, _):
            guard pts.count >= 3 else { return [] }
            return [.path(segments: [.move(P(pts[0].x, pts[0].y))] + pts.dropFirst().map { .line(P($0.x, $0.y)) } + [.close], fill: colour, stroke: nil)]
        case .image(_, let at, let size, _):
            imagesSkipped += 1
            let w = size.width, h = size.height
            return [.path(segments: [.move(P(at.x, at.y)), .line(P(at.x + w, at.y)), .line(P(at.x + w, at.y + h)), .line(P(at.x, at.y + h)), .close],
                          fill: nil, stroke: stroke)]
        case .viewport:
            return []
        case .styled:
            return []
        case .text(let value, let at, let height, let rotation, let style, let align, let widthFactor, _):
            let lines = [DrawingText.clean(value)]
            return textPrims(lines, at: at, height: height, rotation: rotation, style: style, align: align, widthFactor: widthFactor, colour: colour, context: context)
        case .multilineText(let value, let at, let height, let width, let rotation, let attachment, let style, _):
            return mtextPrims(value, at: at, height: height, width: width, rotation: rotation, attachment: attachment, style: style, colour: colour, context: context)
        case .hatch(let loops, _, let solid, let lines, _):
            let mapped = loops.map { $0.map { affine.apply(($0.x, $0.y)) } }.filter { $0.count >= 3 }
            guard !mapped.isEmpty else { return [] }
            if solid || lines.isEmpty {
                let o = Plot.orient(mapped)
                let segs = o.flatMap { loop -> [PathSegment] in
                    [.move(VectorPoint(loop[0].0, loop[0].1))] + loop.dropFirst().map { PathSegment.line(VectorPoint($0.0, $0.1)) } + [.close]
                }
                return [.path(segments: segs, fill: colour, stroke: nil)]
            }
            let families = lines.map { l -> HatchFamily in
                let a = l.angle * .pi / 180
                let dir = affine.linear((cos(a), sin(a)))
                let length = max(hypot(dir.0, dir.1), 1e-12)
                return HatchFamily(direction: (dir.0 / length, dir.1 / length), base: affine.apply((l.base.x, l.base.y)),
                                   offset: affine.linear((l.offset.x, l.offset.y)),
                                   dashes: l.dashes.map { $0 * length })
            }
            return [.hatch(loops: mapped, families: families, colour: colour, weight: stroke.weight)]
        case .insert(let name, let at, let scale, let rotation, _):
            guard let block = blocks[name.lowercased()], context.depth < 12,
                  !context.blockStack.contains(name.lowercased()) else { return [] }
            var inner = context
            let a = rotation * .pi / 180
            inner.affine = affine.concat(.translation(at.x, at.y)).concat(.rotation(a)).concat(.scale(scale.x, scale.y))
                .concat(.translation(-block.base.x, -block.base.y))
            inner.layer = layerName
            inner.inBlock = true
            inner.depth += 1
            inner.blockStack.append(name.lowercased())
            inner.blockColour = colour
            inner.blockLineType = dashPattern(appearance, layer: layerName, context)
            inner.blockWeight = stroke.weight * 25.4 / 72
            var out: [Prim] = []
            for child in block.entities { out.append(contentsOf: generate(child, inner)) }
            return out
        }
    }

    // MARK: Curves

    private func polylineSegments(_ pts: [CADDrawing.Point3], closed: Bool, bulges: [Double], _ P: (Double, Double) -> VectorPoint) -> [PathSegment] {
        guard let first = pts.first else { return [] }
        var segments: [PathSegment] = [.move(P(first.x, first.y))]
        let count = closed ? pts.count : pts.count - 1
        for i in 0..<max(count, 0) {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            let bulge = bulges.indices.contains(i) ? bulges[i] : 0
            if abs(bulge) > 1e-9, hypot(b.x - a.x, b.y - a.y) > 1e-12 {
                let arc = BulgeArc(from: (a.x, a.y), to: (b.x, b.y), bulge: bulge)
                var pieces = arcSegments(arc.centre.0, arc.centre.1, arc.radius, arc.radius, 0, arc.start, arc.sweep, P)
                // Land exactly on the vertex, not on a rounded arc end.
                if case .cubic(let c1, let c2, _)? = pieces.last { pieces[pieces.count - 1] = .cubic(c1, c2, P(b.x, b.y)) }
                if case .move? = pieces.first { pieces.removeFirst() }
                segments.append(contentsOf: pieces)
            } else if i < count - 1 || !closed {
                segments.append(.line(P(b.x, b.y)))
            } else {
                // The closing edge of a closed polyline is the close itself.
            }
        }
        if closed { segments.append(.close) }
        return segments
    }

    /// An elliptical arc as cubic Béziers: centre, radii along the rotated axes, rotation of the major axis, start parameter and
    /// sweep (radians, negative = clockwise). Starts with a move.
    private func arcSegments(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ axis: Double, _ start: Double, _ sweep: Double,
                             _ P: (Double, Double) -> VectorPoint) -> [PathSegment] {
        let ca = cos(axis), sa = sin(axis)
        func map(_ u: (Double, Double)) -> VectorPoint {
            let x = u.0 * rx, y = u.1 * ry
            return P(cx + x * ca - y * sa, cy + x * sa + y * ca)
        }
        var out: [PathSegment] = [.move(map((cos(start), sin(start))))]
        for piece in Geometry.unitArc(start: start, sweep: sweep) { out.append(.cubic(map(piece.c1), map(piece.c2), map(piece.end))) }
        return out
    }

    // MARK: Text

    private mutating func fontName(_ style: String) -> (name: String, widthFactor: Double, oblique: Double) {
        guard let s = styles[style.lowercased()] else { return ("Helvetica", 1, 0) }
        let file = s.font.lowercased()
        for ext in [".ttf", ".ttc", ".otf"] where file.hasSuffix(ext) {
            let stem = String(file.dropLast(ext.count))
            return (stem.prefix(1).uppercased() + stem.dropFirst(), s.widthFactor, s.oblique)
        }
        if !file.isEmpty { shxFonts.insert(file) }
        return ("Helvetica", s.widthFactor, s.oblique)
    }

    private mutating func textPrims(_ lines: [String], at: CADDrawing.Point3, height: Double, rotation: Double, style: String,
                                    align: CADDrawing.TextAlign, widthFactor: Double, colour: VectorColour, context: Context) -> [Prim] {
        let (font, styleWidth, oblique) = fontName(style)
        let wf = widthFactor * styleWidth
        var out: [Prim] = []
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let width = DrawingText.width(line, font: font) * height * wf
            let h: Double, v: Double
            switch align {
            case .topLeft, .middleLeft, .bottomLeft, .baselineLeft: h = 0
            case .topCentre, .middleCentre, .bottomCentre, .baselineCentre: h = 0.5
            default: h = 1
            }
            switch align {
            case .topLeft, .topCentre, .topRight: v = -height
            case .middleLeft, .middleCentre, .middleRight: v = -height / 2
            case .bottomLeft, .bottomCentre, .bottomRight: v = height * 0.2
            default: v = 0
            }
            out.append(contentsOf: [placeText(line, font: font, local: (-h * width, v - Double(index) * height * 5 / 3), at: at, width: width, height: height,
                                              rotation: rotation, wf: wf, oblique: oblique, colour: colour, context: context)])
        }
        return out
    }

    private func placeText(_ line: String, font: String, local: (Double, Double), at: CADDrawing.Point3, width: Double, height: Double, rotation: Double,
                           wf: Double, oblique: Double, colour: VectorColour, context: Context) -> Prim {
        let r = rotation * .pi / 180
        let origin = (at.x + local.0 * cos(r) - local.1 * sin(r), at.y + local.0 * sin(r) + local.1 * cos(r))
        let end = (origin.0 + width * cos(r), origin.1 + width * sin(r))
        let a = context.affine
        let o = a.apply(origin), e = a.apply(end)
        let xAxis = a.linear((cos(r), sin(r))), yAxis = a.linear((-sin(r), cos(r)))
        let lenX = max(hypot(xAxis.0, xAxis.1), 1e-12), lenY = max(hypot(yAxis.0, yAxis.1), 1e-12)
        return .text(TextPrim(text: line, font: font, origin: o, height: height * lenY, rotation: atan2(xAxis.1, xAxis.0), widthFactor: wf * lenX / lenY,
                              oblique: oblique, colour: colour, end: e))
    }

    private mutating func mtextPrims(_ raw: String, at: CADDrawing.Point3, height: Double, width: Double, rotation: Double, attachment: Int,
                                     style: String, colour: VectorColour, context: Context) -> [Prim] {
        let (font, styleWidth, oblique) = fontName(style)
        var lines: [String] = []
        for paragraph in DrawingText.mtextParagraphs(raw) {
            lines.append(contentsOf: DrawingText.wrap(paragraph, limit: width > 0 ? width / (height * styleWidth) : 0, font: font))
        }
        guard !lines.isEmpty else { return [] }
        let pitch = height * 5 / 3
        let blockHeight = Double(lines.count - 1) * pitch + height
        let column = (attachment - 1) % 3, row = (attachment - 1) / 3
        let top = row == 0 ? 0.0 : row == 1 ? blockHeight / 2 : blockHeight
        var out: [Prim] = []
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let w = DrawingText.width(line, font: font) * height * styleWidth
            let x: Double
            switch column {
            case 0: x = 0
            case 1: x = -w / 2
            default: x = -w
            }
            let y = top - height - Double(index) * pitch
            out.append(placeText(line, font: font, local: (x, y), at: at, width: w, height: height, rotation: rotation, wf: styleWidth,
                                 oblique: oblique, colour: colour, context: context))
        }
        return out
    }
}
