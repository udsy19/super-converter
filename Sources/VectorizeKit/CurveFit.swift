// Adapted from flo_curves src/bezier/fit.rs (Apache-2.0, 0.3.1, commit fccd933942532562557be2a61a706ebc0a1f1888)
// Copyright (c) Andrew Hunter (Logicalshift). Licensed under the Apache License, Version 2.0; see THIRD_PARTY_NOTICES.md.
// What changed: Swift on `PointF`; a zero-length tangent or chord stays zero instead of becoming NaN.
import Foundation

/// A cubic Bézier: start, two control points, end.
struct CubicBezier { var start: PointF, c1: PointF, c2: PointF, end: PointF }

/// Fits cubic Béziers through points within a maximum error (Philip J. Schneider, Graphics Gems), as visioncortex's
/// spline step calls it (`Curve::fit_from_points(points, 10.0)`).
enum CurveFit {
    /// Maximum number of iterations when improving a fit.
    private static let maxIterations = 4
    /// How far outside the error bound (as a ratio of it) a fit may be and still be improved by reparameterising.
    private static let fitAttemptRatio = 4.0
    /// Points fitted at once; longer runs are fitted in blocks (the algorithm is quadratic).
    private static let maxPointsToFit = 100

    static func fit(_ points: [PointF], maxError: Double) -> [CubicBezier]? {
        guard points.count >= 2 else { return nil }
        var curves: [CubicBezier] = []
        let blocks = (points.count - 1) / maxPointsToFit + 1
        for block in 0..<blocks {
            let start = block * maxPointsToFit
            let count = min(maxPointsToFit, points.count - start)
            if count < 2 { continue }
            let slice = Array(points[start..<(start + count)])
            curves += fitCubic(slice, startTangent: (slice[1] - slice[0]).unit, endTangent: (slice[count - 2] - slice[count - 1]).unit, maxError: maxError)
        }
        return curves
    }

    private static func fitCubic(_ points: [PointF], startTangent: PointF, endTangent: PointF, maxError: Double) -> [CubicBezier] {
        if points.count <= 2 {
            // Two points are a line, with its control points a third of the way along.
            let direction = points[1] - points[0]
            return [CubicBezier(start: points[0], c1: points[0] + direction * 0.33, c2: points[0] + direction * 0.66, end: points[1])]
        }
        var chords = chordsForPoints(points)
        var curve = generateBezier(points, chords, startTangent, endTangent)
        var (error, split) = maxErrorForCurve(points, chords, curve)
        if error > maxError && error < maxError * fitAttemptRatio {
            for _ in 0..<maxIterations {
                chords = reparameterize(points, chords, curve)
                curve = generateBezier(points, chords, startTangent, endTangent)
                (error, split) = maxErrorForCurve(points, chords, curve)
                if error <= maxError { break }
            }
        }
        if error <= maxError { return [curve] }
        // Still too far out: split at the worst point and fit both sides.
        let split1 = min(max(split, 1), points.count - 2)
        let centre = tangentBetween(points[split1 - 1], points[split1], points[split1 + 1])
        let lhs = fitCubic(Array(points[0...split1]), startTangent: startTangent, endTangent: centre, maxError: maxError)
        let rhs = fitCubic(Array(points[split1...]), startTangent: centre * -1, endTangent: endTangent, maxError: maxError)
        return lhs + rhs
    }

    /// Chord-length parameterisation: an estimate of each point's t on the final curve.
    private static func chordsForPoints(_ points: [PointF]) -> [Double] {
        var distances = [0.0]
        var total = 0.0
        for p in 1..<points.count {
            total += (points[p - 1] - points[p]).norm
            distances.append(total)
        }
        return total > 0 ? distances.map { $0 / total } : distances
    }

    /// Least-squares fit of the two control points along the end tangents.
    private static func generateBezier(_ points: [PointF], _ chords: [Double], _ startTangent: PointF, _ endTangent: PointF) -> CubicBezier {
        let a = chords.map { chord -> (PointF, PointF) in
            let inverse = 1 - chord
            return (startTangent * (3 * chord * inverse * inverse), endTangent * (3 * chord * chord * inverse))
        }
        var c00 = 0.0, c01 = 0.0, c11 = 0.0, x0 = 0.0, x1 = 0.0
        let first = points[0], last = points[points.count - 1]
        for i in 0..<points.count {
            c00 += a[i].0.dot(a[i].0)
            c01 += a[i].0.dot(a[i].1)
            c11 += a[i].1.dot(a[i].1)
            let chord = chords[i], inverse = 1 - chord
            let b0 = inverse * inverse * inverse, b1 = 3 * chord * inverse * inverse, b2 = 3 * chord * chord * inverse, b3 = chord * chord * chord
            let tmp = points[i] - (first * b0 + first * b1 + last * b2 + last * b3)
            x0 += a[i].0.dot(tmp)
            x1 += a[i].1.dot(tmp)
        }
        let detC0C1 = c00 * c11 - c01 * c01
        let detC0X = c00 * x1 - c01 * x0
        let detXC1 = x0 * c11 - x1 * c01
        let alphaL = abs(detC0C1) < 1e-4 ? 0 : detXC1 / detC0C1
        let alphaR = abs(detC0C1) < 1e-4 ? 0 : detC0X / detC0C1
        // The Wu/Barsky heuristic when an alpha is negative.
        let segLength = (first - last).norm
        let epsilon = 1e-6 * segLength
        if alphaL < epsilon || alphaR < epsilon {
            let dist = segLength / 3
            return CubicBezier(start: first, c1: first + startTangent * dist, c2: last + endTangent * dist, end: last)
        }
        return CubicBezier(start: first, c1: first + startTangent * alphaL, c2: last + endTangent * alphaR, end: last)
    }

    /// The largest distance of a point from its estimated position on the curve, and that point's index.
    private static func maxErrorForCurve(_ points: [PointF], _ chords: [Double], _ curve: CubicBezier) -> (Double, Int) {
        var biggest = 0.0, at = 0
        for (i, point) in points.enumerated() {
            let offset = point - pointAt(curve, chords[i])
            let e = offset.dot(offset)
            if e > biggest { biggest = e; at = i }
        }
        return (biggest.squareRoot(), at)
    }

    private static func tangentBetween(_ p1: PointF, _ p2: PointF, _ p3: PointF) -> PointF {
        (((p1 - p2) + (p2 - p3)) * 0.5).unit
    }

    /// Newton–Raphson improvement of the t values.
    private static func reparameterize(_ points: [PointF], _ chords: [Double], _ curve: CubicBezier) -> [Double] {
        zip(points, chords).map { point, t in
            let qt = pointAt(curve, t)
            let qn1 = (curve.c1 - curve.start) * 3, qn2 = (curve.c2 - curve.c1) * 3, qn3 = (curve.end - curve.c2) * 3
            let qnn1 = (qn2 - qn1) * 2, qnn2 = (qn3 - qn2) * 2
            let u = 1 - t
            let qnt = qn1 * (u * u) + qn2 * (2 * u * t) + qn3 * (t * t)
            let qnnt = qnn1 * u + qnn2 * t
            let numerator = (qt - point).dot(qnt)
            let denominator = qnt.dot(qnt) + (qt - point).dot(qnnt)
            return denominator == 0 ? t : t - numerator / denominator
        }
    }

    static func pointAt(_ b: CubicBezier, _ t: Double) -> PointF {
        let u = 1 - t
        return b.start * (u * u * u) + b.c1 * (3 * u * u * t) + b.c2 * (3 * u * t * t) + b.end * (t * t * t)
    }
}
