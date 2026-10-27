import Foundation
import SuperConverterCore

/// Outlines as segment lists, and back to the model's point lists. `FontModel` keeps TrueType-style contours (quadratic:
/// off-curve points with implied on-curve points between neighbours, a contour may start off-curve) or PostScript-style
/// ones (cubic: a start on-curve point, then lines or off, off, on triples; a trailing off, off pair curves back to the start).
struct Pt: Equatable {
    var x: Double, y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    static func + (a: Pt, b: Pt) -> Pt { Pt(a.x + b.x, a.y + b.y) }
    static func - (a: Pt, b: Pt) -> Pt { Pt(a.x - b.x, a.y - b.y) }
    static func * (a: Pt, k: Double) -> Pt { Pt(a.x * k, a.y * k) }
}

enum Seg: Equatable {
    case line(Pt)
    case quad(Pt, Pt)
    case cubic(Pt, Pt, Pt)

    var end: Pt {
        switch self {
        case .line(let p), .quad(_, let p), .cubic(_, _, let p): p
        }
    }
}

/// A closed outline: `start`, then segments; the closing line back to `start` is implicit.
struct OutlinePath: Equatable {
    var start: Pt
    var segs: [Seg]

    /// The same outline traversed backwards (TrueType and PostScript wind outer contours in opposite directions).
    func reversed() -> OutlinePath {
        var points = [start]
        for s in segs { points.append(s.end) }
        var out: [Seg] = []
        let begin = points.last!
        var index = segs.count - 1
        while index >= 0 {
            let to = points[index]
            switch segs[index] {
            case .line: out.append(.line(to))
            case .quad(let c, _): out.append(.quad(c, to))
            case .cubic(let c1, let c2, _): out.append(.cubic(c2, c1, to))
            }
            index -= 1
        }
        return OutlinePath(start: begin, segs: out)
    }
}

enum Outlines {
    typealias Contour = FontModel.Contour
    typealias Point = FontModel.Contour.Point

    /// A quadratic (TrueType) contour as a path, resolving implied on-curve points.
    static func quadraticPath(_ contour: Contour) -> OutlinePath? {
        let pts = contour.points
        guard pts.count >= 2 else { return nil }
        let start: Pt
        let order: [Point]
        if let i0 = pts.firstIndex(where: { $0.onCurve }) {
            start = Pt(pts[i0].x, pts[i0].y)
            order = Array(pts[(i0 + 1)...]) + Array(pts[..<i0])
        } else {
            start = Pt((pts[pts.count - 1].x + pts[0].x) / 2, (pts[pts.count - 1].y + pts[0].y) / 2)
            order = pts
        }
        var segs: [Seg] = []
        var pending: Pt?
        for p in order {
            let q = Pt(p.x, p.y)
            if p.onCurve {
                if let c = pending { segs.append(.quad(c, q)); pending = nil } else { segs.append(.line(q)) }
            } else {
                if let c = pending { segs.append(.quad(c, Pt((c.x + q.x) / 2, (c.y + q.y) / 2))) }
                pending = q
            }
        }
        if let c = pending { segs.append(.quad(c, start)) }
        return OutlinePath(start: start, segs: segs)
    }

    /// A cubic (PostScript) contour as a path.
    static func cubicPath(_ contour: Contour) -> OutlinePath? {
        let pts = contour.points
        guard pts.count >= 2 else { return nil }
        let start = Pt(pts[0].x, pts[0].y)
        var segs: [Seg] = []
        var offs: [Pt] = []
        for p in pts.dropFirst() {
            let q = Pt(p.x, p.y)
            if p.onCurve {
                switch offs.count {
                case 0: segs.append(.line(q))
                case 1: segs.append(.quad(offs[0], q))
                default: segs.append(.cubic(offs[0], offs[1], q))
                }
                offs.removeAll()
            } else {
                offs.append(q)
            }
        }
        if offs.count >= 2 { segs.append(.cubic(offs[0], offs[1], start)) }
        else if offs.count == 1 { segs.append(.quad(offs[0], start)) }
        return OutlinePath(start: start, segs: segs)
    }

    static func path(_ contour: Contour, kind: FontModel.OutlineKind) -> OutlinePath? {
        kind == .quadratic ? quadraticPath(contour) : cubicPath(contour)
    }

    /// A path as a quadratic contour: cubic segments must already be gone.
    static func quadraticContour(_ path: OutlinePath) -> Contour {
        var pts: [Point] = [Point(path.start.x, path.start.y)]
        for s in path.segs {
            switch s {
            case .line(let p): pts.append(Point(p.x, p.y))
            case .quad(let c, let p): pts.append(Point(c.x, c.y, onCurve: false)); pts.append(Point(p.x, p.y))
            case .cubic(_, _, let p): pts.append(Point(p.x, p.y))
            }
        }
        if pts.count > 2, let last = pts.last, last.onCurve, last.x == path.start.x, last.y == path.start.y { pts.removeLast() }
        return Contour(points: pts)
    }

    /// Drops on-curve points that sit exactly midway between their off-curve neighbours: TrueType implies them, so the curve is
    /// unchanged and the glyph is smaller.
    static func dropImpliedPoints(_ contour: Contour) -> Contour {
        let pts = contour.points
        let n = pts.count
        guard n > 3 else { return contour }
        var out: [Point] = []
        for i in 0..<n {
            let p = pts[i]
            if p.onCurve {
                let a = pts[(i + n - 1) % n], b = pts[(i + 1) % n]
                if !a.onCurve && !b.onCurve && abs((a.x + b.x) / 2 - p.x) < 1e-9 && abs((a.y + b.y) / 2 - p.y) < 1e-9 { continue }
            }
            out.append(p)
        }
        return Contour(points: out)
    }

    /// A path as a cubic contour: quadratic segments are raised to cubic exactly.
    static func cubicContour(_ path: OutlinePath) -> Contour {
        var pts: [Point] = [Point(path.start.x, path.start.y)]
        var current = path.start
        for (i, s) in path.segs.enumerated() {
            let isLast = i == path.segs.count - 1
            switch s {
            case .line(let p):
                if !(isLast && p == path.start) { pts.append(Point(p.x, p.y)) }
            case .quad(let c, let p):
                let c1 = current + (c - current) * (2.0 / 3.0)
                let c2 = p + (c - p) * (2.0 / 3.0)
                append(&pts, c1, c2, p, closing: isLast && p == path.start)
            case .cubic(let c1, let c2, let p):
                append(&pts, c1, c2, p, closing: isLast && p == path.start)
            }
            current = s.end
        }
        return Contour(points: pts)
    }

    private static func append(_ pts: inout [Point], _ c1: Pt, _ c2: Pt, _ p: Pt, closing: Bool) {
        pts.append(Point(c1.x, c1.y, onCurve: false)); pts.append(Point(c2.x, c2.y, onCurve: false))
        if !closing { pts.append(Point(p.x, p.y)) }
    }
}

extension FontModel {
    /// Control-point bounds of a glyph; nil when empty.
    func bounds(of glyph: Glyph) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var any = false
        for c in glyph.contours { for p in c.points { any = true; minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) } }
        return any ? (minX, minY, maxX, maxY) : nil
    }
}
