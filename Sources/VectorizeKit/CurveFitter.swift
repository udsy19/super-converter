import Foundation

typealias Pt = SIMD2<Double>

private func dot(_ a: Pt, _ b: Pt) -> Double { a.x * b.x + a.y * b.y }
private func length(_ a: Pt) -> Double { dot(a, a).squareRoot() }
private func unit(_ a: Pt) -> Pt { let l = length(a); return l > 1e-12 ? a / l : Pt(0, 0) }

/// Cubic Bézier fitting (least squares with Newton reparametrisation, splitting at the worst point), after Schneider's
/// algorithm as published in Graphics Gems, written here from the published description.
enum CurveFitter {
    struct Bezier { var p0: Pt, p1: Pt, p2: Pt, p3: Pt }

    static func fit(_ points: [Pt], startTangent: Pt, endTangent: Pt, error: Double) -> [Bezier] {
        var out: [Bezier] = []
        guard points.count >= 2 else { return out }
        fitCubic(points, 0, points.count - 1, startTangent, endTangent, error * error, &out, depth: 0)
        return out
    }

    private static func point(_ b: Bezier, _ t: Double) -> Pt {
        let u = 1 - t
        return b.p0 * (u * u * u) + b.p1 * (3 * u * u * t) + b.p2 * (3 * u * t * t) + b.p3 * (t * t * t)
    }

    private static func fitCubic(_ d: [Pt], _ first: Int, _ last: Int, _ t1: Pt, _ t2: Pt, _ errorSq: Double, _ out: inout [Bezier], depth: Int) {
        let n = last - first + 1
        if n == 2 {
            let dist = length(d[last] - d[first]) / 3
            out.append(Bezier(p0: d[first], p1: d[first] + t1 * dist, p2: d[last] + t2 * dist, p3: d[last]))
            return
        }
        var u = chordLength(d, first, last)
        var bez = generate(d, first, last, u, t1, t2)
        var (maxErr, split) = maxError(d, first, last, bez, u)
        if maxErr < errorSq { out.append(bez); return }
        if maxErr < errorSq * 16 {
            for _ in 0..<6 {
                u = reparametrise(d, first, last, u, bez)
                bez = generate(d, first, last, u, t1, t2)
                (maxErr, split) = self.maxError(d, first, last, bez, u)
                if maxErr < errorSq { out.append(bez); return }
            }
        }
        if depth > 40 || n < 4 { out.append(bez); return }
        split = min(max(split, first + 1), last - 1)
        var center = unit(d[split - 1] - d[split + 1])
        if center == Pt(0, 0) { center = unit(Pt(-(d[split + 1] - d[split - 1]).y, (d[split + 1] - d[split - 1]).x)) }
        fitCubic(d, first, split, t1, center, errorSq, &out, depth: depth + 1)
        fitCubic(d, split, last, -center, t2, errorSq, &out, depth: depth + 1)
    }

    private static func chordLength(_ d: [Pt], _ first: Int, _ last: Int) -> [Double] {
        var u = [0.0]
        for i in (first + 1)...last { u.append(u[u.count - 1] + length(d[i] - d[i - 1])) }
        let total = u[u.count - 1]
        return total > 0 ? u.map { $0 / total } : u.indices.map { Double($0) / Double(max(u.count - 1, 1)) }
    }

    private static func generate(_ d: [Pt], _ first: Int, _ last: Int, _ u: [Double], _ t1: Pt, _ t2: Pt) -> Bezier {
        let n = last - first + 1
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
        let p0 = d[first], p3 = d[last]
        for i in 0..<n {
            let t = u[i], v = 1 - t
            let b0 = v * v * v, b1 = 3 * t * v * v, b2 = 3 * t * t * v, b3 = t * t * t
            let a1 = t1 * b1, a2 = t2 * b2
            c00 += dot(a1, a1); c01 += dot(a1, a2); c11 += dot(a2, a2)
            let tmp = d[first + i] - (p0 * (b0 + b1) + p3 * (b2 + b3))
            x0 += dot(a1, tmp); x1 += dot(a2, tmp)
        }
        let det = c00 * c11 - c01 * c01
        var alpha1 = 0.0, alpha2 = 0.0
        if abs(det) > 1e-12 { alpha1 = (x0 * c11 - x1 * c01) / det; alpha2 = (c00 * x1 - c01 * x0) / det }
        let seg = length(p3 - p0)
        let eps = 1e-6 * seg
        if alpha1 < eps || alpha2 < eps { alpha1 = seg / 3; alpha2 = seg / 3 }
        return Bezier(p0: p0, p1: p0 + t1 * alpha1, p2: p3 + t2 * alpha2, p3: p3)
    }

    private static func reparametrise(_ d: [Pt], _ first: Int, _ last: Int, _ u: [Double], _ b: Bezier) -> [Double] {
        let q1 = [(b.p1 - b.p0) * 3, (b.p2 - b.p1) * 3, (b.p3 - b.p2) * 3]
        let q2 = [(q1[1] - q1[0]) * 2, (q1[2] - q1[1]) * 2]
        return u.enumerated().map { i, t in
            let p = point(b, t)
            let v = 1 - t
            let d1 = q1[0] * (v * v) + q1[1] * (2 * v * t) + q1[2] * (t * t)
            let d2 = q2[0] * v + q2[1] * t
            let diff = p - d[first + i]
            let num = dot(diff, d1), den = dot(d1, d1) + dot(diff, d2)
            return abs(den) < 1e-12 ? t : min(max(t - num / den, 0), 1)
        }
    }

    private static func maxError(_ d: [Pt], _ first: Int, _ last: Int, _ b: Bezier, _ u: [Double]) -> (Double, Int) {
        var worst = 0.0, split = (first + last) / 2
        for i in (first + 1)..<last {
            let diff = point(b, u[i - first]) - d[i]
            let e = dot(diff, diff)
            if e >= worst { worst = e; split = i }
        }
        return (worst, split)
    }
}

/// Turns pixel-edge loops into path data.
enum OutlineWriter {
    static func number(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if r == r.rounded() { return String(Int64(r)) }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    private static func pair(_ p: Pt) -> String { number(p.x) + " " + number(p.y) }

    /// Perpendicular distance of `p` from the segment `a`–`b`.
    private static func distance(_ p: Pt, _ a: Pt, _ b: Pt) -> Double {
        let ab = b - a
        let l2 = dot(ab, ab)
        if l2 < 1e-12 { return length(p - a) }
        let t = min(max(dot(p - a, ab) / l2, 0), 1)
        return length(p - (a + ab * t))
    }

    /// Indices kept by Douglas–Peucker between `lo` and `hi` (both included; indices wrap around `pts`).
    private static func simplify(_ pts: [Pt], _ lo: Int, _ hi: Int, _ tolerance: Double) -> [Int] {
        var keep: Set<Int> = [lo, hi]
        var stack = [(lo, hi)]
        while let (a, b) = stack.popLast() {
            if b - a < 2 { continue }
            var worst = 0.0, at = -1
            let pa = pts[a % pts.count], pb = pts[b % pts.count]
            for i in (a + 1)..<b {
                let dist = distance(pts[i % pts.count], pa, pb)
                if dist > worst { worst = dist; at = i }
            }
            if worst > tolerance, at >= 0 { keep.insert(at); stack.append((a, at)); stack.append((at, b)) }
        }
        return keep.sorted()
    }

    /// The loop's vertices where the direction changes.
    static func corners(_ loop: Loop) -> [Pt] {
        let n = loop.count
        var out: [Pt] = []
        for i in 0..<n {
            let p = (i + n - 1) % n, q = (i + 1) % n
            let d1x = loop.xs[i] - loop.xs[p], d1y = loop.ys[i] - loop.ys[p]
            let d2x = loop.xs[q] - loop.xs[i], d2y = loop.ys[q] - loop.ys[i]
            if d1x != d2x || d1y != d2y { out.append(Pt(Double(loop.xs[i]), Double(loop.ys[i]))) }
        }
        return out
    }

    static func pixelPath(_ loop: Loop) -> String {
        let c = corners(loop)
        guard let first = c.first else { return "" }
        var d = "M" + pair(first)
        var cur = first
        for p in c.dropFirst() {
            if p.y == cur.y { d += "H" + number(p.x) } else if p.x == cur.x { d += "V" + number(p.y) } else { d += "L" + pair(p) }
            cur = p
        }
        return d + "Z"
    }

    static func polygonPath(_ loop: Loop, tolerance: Double) -> String {
        let pts = (0..<loop.count).map { Pt(Double(loop.xs[$0]), Double(loop.ys[$0])) }
        guard pts.count >= 4 else { return pixelPath(loop) }
        let far = (1..<pts.count).max { length(pts[$0] - pts[0]) < length(pts[$1] - pts[0]) } ?? 1
        let kept = Set(simplify(pts, 0, far, tolerance) + simplify(pts, far, pts.count, tolerance).map { $0 % pts.count }).sorted()
        var d = ""
        for (i, k) in kept.enumerated() { d += (i == 0 ? "M" : "L") + pair(pts[k]) }
        return d + "Z"
    }

    static func splinePath(_ loop: Loop, tolerance: Double, simplification: Double) -> String {
        let n = loop.count
        if n < 12 { return polygonPath(loop, tolerance: 0.5) }
        let u = (0..<n).map { Pt(Double(loop.xs[$0]), Double(loop.ys[$0])) }
        let mid = (0..<n).map { (u[$0] + u[($0 + 1) % n]) / 2 }
        // Corner detection on a coarse polygon.
        let far = (1..<n).max { length(u[$0] - u[0]) < length(u[$1] - u[0]) } ?? 1
        let kept = Set(simplify(u, 0, far, 0.7) + simplify(u, far, n, 0.7).map { $0 % n }).sorted()
        var cornerIndices: [Int] = []
        let m = kept.count
        if m >= 3 {
            for j in 0..<m {
                let a = u[kept[(j + m - 1) % m]], b = u[kept[j]], c = u[kept[(j + 1) % m]]
                let v1 = unit(b - a), v2 = unit(c - b)
                let angle = acos(min(1, max(-1, dot(v1, v2)))) * 180 / .pi
                if angle > 65 { cornerIndices.append(kept[j]) }
            }
        }
        var d = ""
        func emit(_ beziers: [CurveFitter.Bezier]) {
            for b in beziers {
                let chord = b.p3 - b.p0
                let flat = distance(b.p1, b.p0, b.p3) < 0.05 && distance(b.p2, b.p0, b.p3) < 0.05 && length(chord) > 0
                if flat { d += "L" + pair(b.p3) } else { d += "C" + pair(b.p1) + " " + pair(b.p2) + " " + pair(b.p3) }
            }
        }
        let tol = 0.6 + 0.4 * simplification
        func tangent(_ pts: [Pt], fromStart: Bool) -> Pt {
            if fromStart { for p in pts.dropFirst() where length(p - pts[0]) >= 2.5 { return unit(p - pts[0]) }; return unit(pts[pts.count - 1] - pts[0]) }
            let last = pts[pts.count - 1]
            for p in pts.dropLast().reversed() where length(p - last) >= 2.5 { return unit(p - last) }
            return unit(pts[0] - last)
        }
        if cornerIndices.isEmpty {
            // Smooth closed outline: split in two at opposite points, tangents from the neighbours.
            let half = n / 2
            let a = Array(mid[0...half]), b = Array(mid[half..<n]) + [mid[0]]
            func centred(_ i: Int) -> Pt {
                let back = mid[(i + n - 3) % n], fwd = mid[(i + 3) % n]
                return unit(fwd - back)
            }
            let t0 = centred(0), th = centred(half)
            d = "M" + pair(mid[0])
            emit(CurveFitter.fit(a, startTangent: t0, endTangent: -th, error: tol))
            emit(CurveFitter.fit(b, startTangent: th, endTangent: -t0, error: tol))
            return d + "Z"
        }
        d = "M" + pair(u[cornerIndices[0]])
        for (j, a) in cornerIndices.enumerated() {
            var b = cornerIndices[(j + 1) % cornerIndices.count]
            if b <= a { b += n }
            var pts = [u[a]]
            for k in a..<b { pts.append(mid[k % n]) }
            pts.append(u[b % n])
            if pts.count == 2 { d += "L" + pair(pts[1]); continue }
            emit(CurveFitter.fit(pts, startTangent: tangent(pts, fromStart: true), endTangent: tangent(pts, fromStart: false), error: tol))
        }
        return d + "Z"
    }
}
