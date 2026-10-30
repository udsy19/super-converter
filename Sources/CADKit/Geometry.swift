import Foundation
import SuperConverterCore

// Small geometry the reader, plotter and writer share: the DXF arbitrary-axis (OCS) rule, bulge arcs, NURBS evaluation and
// circular arcs as cubic Béziers.

/// The object coordinate system of an entity with extrusion direction `normal` (the DXF "arbitrary axis algorithm").
struct OCS {
    let ax: (Double, Double, Double)
    let ay: (Double, Double, Double)
    let az: (Double, Double, Double)

    init(_ normal: (x: Double, y: Double, z: Double)) {
        let length = (normal.x * normal.x + normal.y * normal.y + normal.z * normal.z).squareRoot()
        let n = length > 1e-12 ? (normal.x / length, normal.y / length, normal.z / length) : (0.0, 0.0, 1.0)
        func cross(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> (Double, Double, Double) {
            (a.1 * b.2 - a.2 * b.1, a.2 * b.0 - a.0 * b.2, a.0 * b.1 - a.1 * b.0)
        }
        func unit(_ a: (Double, Double, Double)) -> (Double, Double, Double) {
            let l = (a.0 * a.0 + a.1 * a.1 + a.2 * a.2).squareRoot()
            return l > 0 ? (a.0 / l, a.1 / l, a.2 / l) : a
        }
        let x = abs(n.0) < 1.0 / 64 && abs(n.1) < 1.0 / 64 ? unit(cross((0, 1, 0), n)) : unit(cross((0, 0, 1), n))
        az = n; ax = x; ay = unit(cross(n, x))
    }

    var isIdentity: Bool { abs(az.0) < 1e-9 && abs(az.1) < 1e-9 && az.2 > 0 }
    /// The normal is −Z: the plane is mirrored in x.
    var isFlipped: Bool { abs(az.0) < 1e-9 && abs(az.1) < 1e-9 && az.2 < 0 }

    func world(_ p: CADDrawing.Point3) -> CADDrawing.Point3 {
        if isIdentity { return p }
        return .init(p.x * ax.0 + p.y * ay.0 + p.z * az.0, p.x * ax.1 + p.y * ay.1 + p.z * az.1, p.x * ax.2 + p.y * ay.2 + p.z * az.2)
    }
}

/// The circular arc a polyline bulge describes (bulge = tan(sweep / 4), positive counter-clockwise).
struct BulgeArc {
    var centre: (Double, Double)
    var radius: Double
    var start: Double
    var sweep: Double

    init(from p: (Double, Double), to q: (Double, Double), bulge: Double) {
        let dx = q.0 - p.0, dy = q.1 - p.1
        let chord = max(hypot(dx, dy), 1e-12)
        sweep = 4 * atan(bulge)
        radius = abs(chord / 2 / sin(sweep / 2))
        let h = chord / 2 / tan(sweep / 2)
        centre = ((p.0 + q.0) / 2 - dy / chord * h, (p.1 + q.1) / 2 + dx / chord * h)
        start = atan2(p.1 - centre.1, p.0 - centre.0)
    }

    /// Points strictly between the ends, about `step` radians apart.
    func interior(step: Double) -> [(Double, Double)] {
        let n = max(2, Int((abs(sweep) / step).rounded(.up)))
        return (1..<n).map { k in
            let a = start + sweep * Double(k) / Double(n)
            return (centre.0 + radius * cos(a), centre.1 + radius * sin(a))
        }
    }
}

enum Geometry {
    /// A unit-circle arc from angle `start` sweeping `sweep` radians (negative = clockwise) as cubic Béziers of at most 90°:
    /// (control 1, control 2, end) per piece, to be mapped by the caller's transform. The first point is (cos start, sin start).
    /// A sweep beyond a full turn only retraces the circle, so it is cut to one; a non-finite one draws nothing.
    static func unitArc(start: Double, sweep given: Double) -> [(c1: (Double, Double), c2: (Double, Double), end: (Double, Double))] {
        guard given.isFinite, start.isFinite else { return [] }
        let sweep = min(max(given, -2 * .pi), 2 * .pi)
        let pieces = max(1, Int((abs(sweep) / (.pi / 2) - 1e-9).rounded(.up)))
        let step = sweep / Double(pieces)
        let k = 4.0 / 3.0 * tan(step / 4)
        return (0..<pieces).map { i in
            let a = start + step * Double(i), b = a + step
            return ((cos(a) - k * sin(a), sin(a) + k * cos(a)), (cos(b) + k * sin(b), sin(b) - k * cos(b)), (cos(b), sin(b)))
        }
    }
}

enum NURBS {
    /// The highest degree evaluated: CAD kernels stop at 25 (AutoCAD at 11), and the cost grows with its square per sample.
    static let maxDegree = 25

    /// Points along a (possibly rational) B-spline. Missing or inconsistent knots become a clamped uniform vector.
    static func sample(degree p: Int, controls: [CADDrawing.Point3], knots given: [Double], weights: [Double], samples: Int) -> [CADDrawing.Point3] {
        let n = controls.count
        guard n >= 2 else { return controls }
        let degree = min(p, n - 1, maxDegree)
        var knots = given
        if knots.count != n + degree + 1 || !knots.starts(with: knots.sorted().prefix(0)) || zip(knots, knots.dropFirst()).contains(where: { $0 > $1 }) {
            knots = (0..<(n + degree + 1)).map { i in
                if i <= degree { return 0 }
                if i >= n { return Double(n - degree) }
                return Double(i - degree)
            }
        }
        let lo = knots[degree], hi = knots[n]
        guard hi > lo else { return controls }
        let w = weights.count == n ? weights : [Double](repeating: 1, count: n)
        func basis(_ span: Int, _ t: Double) -> [Double] {
            var left = [Double](repeating: 0, count: degree + 1), right = left
            var N = [Double](repeating: 0, count: degree + 1)
            N[0] = 1
            if degree > 0 {
                for j in 1...degree {
                    left[j] = t - knots[span + 1 - j]
                    right[j] = knots[span + j] - t
                    var saved = 0.0
                    for r in 0..<j {
                        let denom = right[r + 1] + left[j - r]
                        let temp = denom == 0 ? 0 : N[r] / denom
                        N[r] = saved + right[r + 1] * temp
                        saved = left[j - r] * temp
                    }
                    N[j] = saved
                }
            }
            return N
        }
        var out: [CADDrawing.Point3] = []
        // The samples run forward along the knots, so the span search carries on from the last sample's span.
        var span = degree
        for s in 0...samples {
            let t = s == samples ? hi : lo + (hi - lo) * Double(s) / Double(samples)
            while span < n - 1 && t >= knots[span + 1] { span += 1 }
            let N = basis(span, t)
            var x = 0.0, y = 0.0, z = 0.0, ws = 0.0
            for j in 0...degree {
                let i = span - degree + j
                let b = N[j] * w[i]
                x += b * controls[i].x; y += b * controls[i].y; z += b * controls[i].z; ws += b
            }
            if ws != 0 { out.append(.init(x / ws, y / ws, z / ws)) }
        }
        return out
    }
}
