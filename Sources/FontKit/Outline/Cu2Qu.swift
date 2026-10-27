import Foundation

// Cubic to quadratic Bézier approximation: a Swift port of fontTools.cu2qu (https://github.com/fonttools/fonttools,
// MIT licence; the algorithm is by Google Inc., "Fast and efficient cubic-to-quadratic curve conversion", 2015).
// Copyright (c) 2015 Google Inc.; fontTools Copyright (c) 2017 Just van Rossum. See THIRD_PARTY_NOTICES.md.
//
// A cubic is approximated by a spline of n quadratics whose joins are implied on-curve points (the TrueType convention),
// for the smallest n up to 100 whose every point stays within `tolerance` of the cubic.

private struct C {
    var re: Double, im: Double
    init(_ re: Double, _ im: Double) { self.re = re; self.im = im }
    init(_ p: Pt) { re = p.x; im = p.y }
    static let zero = C(0, 0)
    static func + (a: C, b: C) -> C { C(a.re + b.re, a.im + b.im) }
    static func - (a: C, b: C) -> C { C(a.re - b.re, a.im - b.im) }
    static func * (a: C, k: Double) -> C { C(a.re * k, a.im * k) }
    var magnitude: Double { (re * re + im * im).squareRoot() }
    var point: Pt { Pt(re, im) }
    func dot(_ b: C) -> Double { re * b.re + im * b.im }
}

enum Cu2Qu {
    static let maxN = 100

    /// The off-curve points of a quadratic spline approximating the cubic p0..p3 (consecutive off-curve points imply the
    /// on-curve points between them; the spline ends at p3). Nil when no spline up to 100 segments fits.
    static func approximate(_ p0: Pt, _ p1: Pt, _ p2: Pt, _ p3: Pt, tolerance: Double) -> [Pt]? {
        let cubic = (C(p0), C(p1), C(p2), C(p3))
        for n in 1...maxN {
            if let spline = approximateSpline(cubic, n: n, tolerance: tolerance) {
                return spline.dropFirst().dropLast().map(\.point)
            }
        }
        return nil
    }

    private typealias Cubic = (C, C, C, C)

    private static func control(_ t: Double, _ c: Cubic) -> C {
        let a = c.0 + (c.1 - c.0) * 1.5
        let b = c.3 + (c.2 - c.3) * 1.5
        return a + (b - a) * t
    }

    private static func intersect(_ a: C, _ b: C, _ c: C, _ d: C) -> C? {
        let ab = b - a, cd = d - c
        let p = C(-ab.im, ab.re)
        let denominator = p.dot(cd)
        if denominator == 0 { return nil }
        let h = p.dot(a - c) / denominator
        return c + cd * h
    }

    private static func farthestFitInside(_ p0: C, _ p1: C, _ p2: C, _ p3: C, _ tolerance: Double, depth: Int = 0) -> Bool {
        if p2.magnitude <= tolerance && p1.magnitude <= tolerance { return true }
        let mid = (p0 + (p1 + p2) * 3 + p3) * 0.125
        if mid.magnitude > tolerance { return false }
        if depth > 24 { return true }
        let deriv3 = (p3 + p2 - p1 - p0) * 0.125
        return farthestFitInside(p0, (p0 + p1) * 0.5, mid - deriv3, mid, tolerance, depth: depth + 1)
            && farthestFitInside(mid, mid + deriv3, (p2 + p3) * 0.5, p3, tolerance, depth: depth + 1)
    }

    private static func approximateQuadratic(_ c: Cubic, _ tolerance: Double) -> [C]? {
        guard let q1 = intersect(c.0, c.1, c.2, c.3) else { return nil }
        let c1 = c.0 + (q1 - c.0) * (2.0 / 3.0)
        let c2 = c.3 + (q1 - c.3) * (2.0 / 3.0)
        guard farthestFitInside(.zero, c1 - c.1, c2 - c.2, .zero, tolerance) else { return nil }
        return [c.0, q1, c.3]
    }

    private static func lerp(_ a: C, _ b: C, _ t: Double) -> C { a + (b - a) * t }

    private static func splitLeft(_ c: Cubic, _ t: Double) -> Cubic {
        let ab = lerp(c.0, c.1, t), bc = lerp(c.1, c.2, t), cd = lerp(c.2, c.3, t)
        let abc = lerp(ab, bc, t), bcd = lerp(bc, cd, t)
        return (c.0, ab, abc, lerp(abc, bcd, t))
    }

    private static func splitRight(_ c: Cubic, _ t: Double) -> Cubic {
        let ab = lerp(c.0, c.1, t), bc = lerp(c.1, c.2, t), cd = lerp(c.2, c.3, t)
        let abc = lerp(ab, bc, t), bcd = lerp(bc, cd, t)
        return (lerp(abc, bcd, t), bcd, cd, c.3)
    }

    /// The sub-curve of `c` between parameters t0 and t1.
    private static func piece(_ c: Cubic, _ t0: Double, _ t1: Double) -> Cubic {
        let right = t0 > 0 ? splitRight(c, t0) : c
        let scaled = t0 < 1 ? (t1 - t0) / (1 - t0) : 1
        return scaled < 1 ? splitLeft(right, scaled) : right
    }

    private static func approximateSpline(_ cubic: Cubic, n: Int, tolerance: Double) -> [C]? {
        if n == 1 { return approximateQuadratic(cubic, tolerance) }
        let pieces = (0..<n).map { piece(cubic, Double($0) / Double(n), Double($0 + 1) / Double(n)) }
        var index = 0
        var next = pieces[index]
        var nextQ1 = control(0, next)
        var q2 = cubic.0
        var d1 = C.zero
        var spline = [cubic.0, nextQ1]
        for i in 1...n {
            let (_, c1, c2, c3) = next
            let q0 = q2
            let q1 = nextQ1
            if i < n {
                index += 1
                next = pieces[index]
                nextQ1 = control(Double(i) / Double(n - 1), next)
                spline.append(nextQ1)
                q2 = (q1 + nextQ1) * 0.5
            } else {
                q2 = c3
            }
            let d0 = d1
            d1 = q2 - c3
            if d1.magnitude > tolerance
                || !farthestFitInside(d0, q0 + (q1 - q0) * (2.0 / 3.0) - c1, q2 + (q1 - q2) * (2.0 / 3.0) - c2, d1, tolerance) {
                return nil
            }
        }
        spline.append(cubic.3)
        return spline
    }
}
