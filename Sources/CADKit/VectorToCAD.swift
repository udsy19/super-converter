import Foundation
import SuperConverterCore

/// Vector artwork (PDF, SVG, EMF … read by VectorKit) as a `CADDrawing` for the DXF writer (formats §6.9: "VectorKit → DXFWriter").
/// Curves are flattened to polylines, filled shapes become solid hatches, colours become true colours. Page units are points; the
/// drawing is scaled to the unit the card asks for. Pages sit side by side.
enum VectorToCAD {
    static func convert(_ document: VectorDocument, unit: String) -> (drawing: CADDrawing, lossNotes: [LossNote]) {
        let cadUnit: CADDrawing.Unit
        let perPoint: Double
        switch unit {
        case "cm": cadUnit = .centimetres; perPoint = 2.54 / 72
        case "m": cadUnit = .metres; perPoint = 0.0254 / 72
        case "in": cadUnit = .inches; perPoint = 1.0 / 72
        case "ft": cadUnit = .feet; perPoint = 1.0 / 864
        default: cadUnit = .millimetres; perPoint = 25.4 / 72
        }
        var drawing = CADDrawing(unit: cadUnit, layers: [.init(name: "0")], sourceVersion: nil)
        var dropped = Set<String>()
        var offset = 0.0
        for page in document.pages {
            let affine: Matrix = (perPoint, 0, 0, perPoint, offset * perPoint, 0)
            walk(page.nodes, transform: affine, into: &drawing.modelSpace, dropped: &dropped)
            offset += page.size.width + 36
        }
        var notes: [LossNote] = []
        if dropped.contains("image") { notes.append(LossNote(.imagesDropped)) }
        if dropped.contains("clip") { notes.append(LossNote(.otherLoss, detail: "Clipping paths were not kept")) }
        if dropped.contains("gradient") { notes.append(LossNote(.shadingRasterised, detail: "Gradients became flat colours")) }
        return (drawing, notes)
    }

    private typealias Matrix = (a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double)

    private static func mul(_ m: Matrix, _ t: VectorTransform) -> Matrix {
        // result = m ∘ t (t applies first)
        (m.a * t.a + m.c * t.b, m.b * t.a + m.d * t.b, m.a * t.c + m.c * t.d, m.b * t.c + m.d * t.d,
         m.a * t.tx + m.c * t.ty + m.tx, m.b * t.tx + m.d * t.ty + m.ty)
    }

    private static func apply(_ m: Matrix, _ p: VectorPoint) -> CADDrawing.Point3 {
        .init(m.a * p.x + m.c * p.y + m.tx, m.b * p.x + m.d * p.y + m.ty)
    }

    private static func colour(_ paint: VectorPaint, dropped: inout Set<String>) -> VectorColour? {
        switch paint {
        case .solid(let c): return c
        case .linear(_, _, let stops), .radial(_, _, let stops):
            dropped.insert("gradient"); return stops.first?.colour
        case .rasterised: dropped.insert("image"); return nil
        }
    }

    /// The colour as a true colour with its nearest colour index (for readers that ignore true colour), and an optional line weight.
    private static func appearance(_ c: VectorColour, weightMM: Double? = nil) -> CADDrawing.Appearance {
        let rgb = (Int((c.red * 255).rounded()) << 16) | (Int((c.green * 255).rounded()) << 8) | Int((c.blue * 255).rounded())
        return .init(colourIndex: ACI.nearest(r: rgb >> 16, g: rgb >> 8 & 255, b: rgb & 255), trueColour: rgb, lineWeight: weightMM)
    }

    private static func walk(_ nodes: [VectorNode], transform m: Matrix, into out: inout [CADDrawing.Entity], dropped: inout Set<String>) {
        for node in nodes {
            switch node {
            case .path(let segments, let fill, let stroke, _):
                let loops = flatten(segments, m)
                if let fill, let c = colour(fill, dropped: &dropped) {
                    let closed = loops.filter { $0.points.count >= 3 }.map(\.points)
                    if !closed.isEmpty { out.append(.styled(.hatch(loops: closed, pattern: "SOLID", solid: true, layer: "0"), appearance(c))) }
                }
                if let stroke, let c = colour(stroke.paint, dropped: &dropped) {
                    for loop in loops where loop.points.count >= 2 {
                        out.append(.styled(.polyline(loop.points, closed: loop.closed, bulges: [], layer: "0"),
                                           appearance(c, weightMM: stroke.width * 25.4 / 72)))
                    }
                }
            case .text(let run):
                guard let c = colour(run.fill, dropped: &dropped) else { continue }
                let scale = (m.a * m.d - m.b * m.c).magnitude.squareRoot()
                let o = apply(m, run.origin)
                out.append(.styled(.text(run.text, at: o, height: run.size * scale, rotation: atan2(m.b, m.a) * 180 / .pi, style: "Standard", layer: "0"), appearance(c)))
            case .image:
                dropped.insert("image")
            case .group(let children, let transform, let clip, _):
                if clip != nil { dropped.insert("clip") }
                walk(children, transform: mul(m, transform), into: &out, dropped: &dropped)
            }
        }
    }

    private static func flatten(_ segments: [PathSegment], _ m: Matrix) -> [(points: [CADDrawing.Point3], closed: Bool)] {
        var loops: [(points: [CADDrawing.Point3], closed: Bool)] = []
        var current: [CADDrawing.Point3] = []
        var last = VectorPoint(0, 0), start = VectorPoint(0, 0)
        func flush(closed: Bool) {
            if current.count >= 2 { loops.append((current, closed)) }
            current = []
        }
        for s in segments {
            switch s {
            case .move(let p): flush(closed: false); current = [apply(m, p)]; last = p; start = p
            case .line(let p): if current.isEmpty { current = [apply(m, last)] }; current.append(apply(m, p)); last = p
            case .cubic(let a, let b, let c):
                if current.isEmpty { current = [apply(m, last)] }
                for k in 1...12 {
                    let t = Double(k) / 12, u = 1 - t
                    let x = u * u * u * last.x + 3 * u * u * t * a.x + 3 * u * t * t * b.x + t * t * t * c.x
                    let y = u * u * u * last.y + 3 * u * u * t * a.y + 3 * u * t * t * b.y + t * t * t * c.y
                    current.append(apply(m, VectorPoint(x, y)))
                }
                last = c
            case .quad(let a, let b):
                if current.isEmpty { current = [apply(m, last)] }
                for k in 1...8 {
                    let t = Double(k) / 8, u = 1 - t
                    current.append(apply(m, VectorPoint(u * u * last.x + 2 * u * t * a.x + t * t * b.x, u * u * last.y + 2 * u * t * a.y + t * t * b.y)))
                }
                last = b
            case .close:
                if let first = current.first, current.count >= 2 {
                    // Drop the repeated start point; the polyline closes itself.
                    if let l = current.last, abs(l.x - first.x) < 1e-9, abs(l.y - first.y) < 1e-9 { current.removeLast() }
                    flush(closed: true)
                    last = start
                    current = []
                }
            }
        }
        flush(closed: false)
        return loops
    }
}
