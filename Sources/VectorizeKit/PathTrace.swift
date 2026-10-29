// Adapted from visioncortex src/path/{walker,simplify,smooth,spline,util,paths}.rs (MIT, 0.8.8, commit
// 63d21c5b77489daa266304fdacf302b4c2d3a53e). Copyright (c) 2022 Tsang Hao Fung. See THIRD_PARTY_NOTICES.md.
// What changed: Swift; the walker returns its corners as an array (and stops instead of panicking when it has nowhere to
// go); a zero-length vector normalises to zero instead of NaN.
import Foundation

/// An integer point (pixel corners; y down).
struct PointI: Equatable {
    var x: Int, y: Int
    static func + (a: PointI, b: PointI) -> PointI { PointI(x: a.x + b.x, y: a.y + b.y) }
    var f: PointF { PointF(x: Double(x), y: Double(y)) }
}

/// A point or vector in pixel units (y down).
struct PointF: Equatable {
    var x: Double, y: Double
    static func + (a: PointF, b: PointF) -> PointF { PointF(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: PointF, b: PointF) -> PointF { PointF(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: PointF, k: Double) -> PointF { PointF(x: a.x * k, y: a.y * k) }
    func dot(_ o: PointF) -> Double { x * o.x + y * o.y }
    var norm: Double { (x * x + y * y).squareRoot() }
    var unit: PointF { let n = norm; return n > 0 ? PointF(x: x / n, y: y / n) : PointF(x: 0, y: 0) }
}

/// How outlines are simplified (visioncortex `PathSimplifyMode`).
enum PathSimplifyMode { case none, polygon, spline }

// MARK: Walking (walker.rs)

enum PathWalker {
    private static func dirVec(_ dir: Int) -> PointI {
        switch dir {
        case 0: PointI(x: 0, y: -1)
        case 2: PointI(x: 1, y: 0)
        case 4: PointI(x: 0, y: 1)
        default: PointI(x: -1, y: 0)
        }
    }

    /// The two pixels either side of the edge leaving a corner in `dir`.
    private static func sideVecs(_ dir: Int) -> (PointI, PointI) {
        switch dir {
        case 0: (PointI(x: -1, y: -1), PointI(x: 0, y: -1))
        case 2: (PointI(x: 0, y: 0), PointI(x: 0, y: -1))
        case 4: (PointI(x: -1, y: 0), PointI(x: 0, y: 0))
        default: (PointI(x: -1, y: 0), PointI(x: -1, y: -1))
        }
    }

    /// Walks the boundary of `image` from the corner `start`, returning the corners where the direction changes; the last
    /// corner is `start` again (a closed path).
    static func walk(_ image: BinaryImage, start: PointI, clockwise: Bool) -> [PointI] {
        var out = [start]
        var curr = start, prev = start, prevPrev = start
        var length = 0
        let range = clockwise ? [0, 2, 4, 6] : [6, 4, 2, 0]
        while !(curr == start && length > 0) {
            var dir = -1
            while true {
                var go = -1
                for k in range {
                    let ahead = curr + dirVec(k)
                    if ahead != prev && ahead != prevPrev {
                        let (a, b) = sideVecs(k)
                        if image.pixelSafe(curr + a) != image.pixelSafe(curr + b) { go = k; break }
                    }
                }
                if go == -1 { return out }
                if dir != -1 && dir != go { break }
                dir = go
                prevPrev = prev
                prev = curr
                curr = curr + dirVec(go)
                length += 1
            }
            if length > 1_000_000 { return out }
            out.append(curr)
        }
        return out
    }
}

// MARK: Simplification (simplify.rs)

enum PathSimplify {
    /// Origin top left: a positive signed area means clockwise.
    private static func signedArea(_ p1: PointI, _ p2: PointI, _ p3: PointI) -> Int {
        (p2.x - p1.x) * (p3.y - p1.y) - (p3.x - p1.x) * (p2.y - p1.y)
    }

    /// The path without its one-pixel staircases (the outward step of each kept, by the path's direction).
    static func removeStaircase(_ path: [PointI], clockwise: Bool) -> [PointI] {
        let len = path.count
        guard len > 0 else { return [] }
        func segmentLength(_ i: Int, _ j: Int) -> Int { abs(path[i].x - path[j].x) + abs(path[i].y - path[j].y) }
        var result: [PointI] = []
        for i in 0..<len {
            let j = (i + 1) % len, h = i > 0 ? i - 1 : len - 1
            let keep: Bool
            if i == 0 || i == len - 1 {
                keep = true
            } else if segmentLength(i, h) == 1 || segmentLength(i, j) == 1 {
                let area = signedArea(path[h], path[i], path[j])
                keep = area != 0 && (area > 0) == clockwise
            } else {
                keep = true
            }
            if keep { result.append(path[i]) }
        }
        return result
    }

    /// Drops points while the triangle penalty of the skipped run stays under `tolerance` (1 px upstream).
    static func limitPenalties(_ path: [PointI], tolerance: Double) -> [PointI] {
        let len = path.count
        guard len > 0 else { return [] }
        func penalty(_ a: PointI, _ b: PointI, _ c: PointI) -> Double {
            func sq(_ v: Int) -> Double { Double(v * v) }
            let l1 = (sq(a.x - b.x) + sq(a.y - b.y)).squareRoot(), l2 = (sq(b.x - c.x) + sq(b.y - c.y)).squareRoot()
            let l3 = (sq(c.x - a.x) + sq(c.y - a.y)).squareRoot()
            let p = (l1 + l2 + l3) / 2
            let area = (p * (p - l1) * (p - l2) * (p - l3)).squareRoot()
            return area * area / l3
        }
        func pastDelta(_ from: Int, _ to: Int) -> Double {
            var worst = 0.0
            if to > from + 1 { for i in (from + 1)..<to { worst = max(worst, penalty(path[from], path[i], path[to])) } }
            return worst
        }
        var result: [PointI] = []
        var last = 0
        for i in 0..<len {
            if i == 0 {
                result.append(path[i])
            } else if i == last + 1 {
                continue
            } else if pastDelta(last, i) >= tolerance {
                last = i - 1
                result.append(path[i - 1])
            }
            if i == len - 1 { result.append(path[i]) }
        }
        return result
    }
}

// MARK: Angles (util.rs)

private func angle(_ p: PointF) -> Double { p.y.sign == .minus ? -acos(p.x) : acos(p.x) }

/// Signed difference between angles in (−π, π]; positive is clockwise, 0° is the positive x axis.
private func signedAngleDifference(_ from: Double, _ to: Double) -> Double {
    var v2 = to
    if from > v2 { v2 += 2 * .pi }
    let diff = v2 - from
    return diff > .pi ? diff - 2 * .pi : diff
}

/// Intersection of lines p1p2 and p3p4: the midpoint of p2 and p3 when they coincide, nil when parallel.
private func findIntersection(_ p1: PointF, _ p2: PointF, _ p3: PointF, _ p4: PointF) -> PointF? {
    let epsilon = 1e-7
    let denom = (p4.y - p3.y) * (p2.x - p1.x) - (p4.x - p3.x) * (p2.y - p1.y)
    let numera = (p4.x - p3.x) * (p1.y - p3.y) - (p4.y - p3.y) * (p1.x - p3.x)
    let numerb = (p2.x - p1.x) * (p1.y - p3.y) - (p2.y - p1.y) * (p1.x - p3.x)
    if denom <= epsilon && numera <= epsilon && numerb <= epsilon { return (p2 + p3) * 0.5 }
    if denom <= epsilon { return nil }
    let mua = numera / denom
    return PointF(x: p1.x + mua * (p2.x - p1.x), y: p1.y + mua * (p2.y - p1.y))
}

// MARK: Smoothing (smooth.rs)

enum SubdivideSmooth {
    /// Corners of a closed path (last point = first): turns of at least `threshold` radians. One entry per distinct point.
    static func findCorners(_ closed: [PointF], threshold: Double) -> [Bool] {
        let path = closed.dropLast()
        let len = path.count
        guard len > 0 else { return [] }
        let p = Array(path)
        return (0..<len).map { i in
            let prev = i == 0 ? len - 1 : i - 1, next = (i + 1) % len
            let a1 = angle((p[i] - p[prev]).unit), a2 = angle((p[next] - p[i]).unit)
            return abs(signedAngleDifference(a1, a2)) >= threshold
        }
    }

    /// Splice points of a smoothed closed path: inflections, and where the accumulated turn reaches `threshold`.
    static func findSplicePoints(_ closed: [PointF], threshold: Double) -> [Bool] {
        let p = Array(closed.dropLast())
        let len = p.count
        guard len > 0 else { return [] }
        var splice = [Bool](repeating: false, count: len)
        var increasing = false
        var displacement = 0.0
        for i in 0..<len {
            let prev = i == 0 ? len - 1 : i - 1, next = (i + 1) % len
            let diff = signedAngleDifference(angle((p[i] - p[prev]).unit), angle((p[next] - p[i]).unit))
            let currently = diff.sign == .plus
            if i == 0 { increasing = currently } else if increasing != currently { splice[i] = true; increasing = currently }
            displacement += diff
            if abs(displacement) >= threshold { splice[i] = true }
            if splice[i] { displacement = 0 }
        }
        return splice
    }

    /// The first Bézier the curve fitter finds through the points, its handles retracted where they cross.
    static func fitPointsWithBezier(_ points: [PointF]) -> [PointF] {
        let zero = PointF(x: 0, y: 0)
        guard let curves = CurveFit.fit(points, maxError: 10), let curve = curves.first else { return [zero, zero, zero, zero] }
        return retractHandles(points[0], curve.c1, curve.c2, points[points.count - 1])
    }

    /// One pass of the 4-point subdivision scheme keeping corners: a new point between every pair longer than
    /// `segmentLength`, pushed out by 1/`outsetRatio`. Returns the path, its corners, and whether no segment is still long.
    static func subdivideKeepCorners(_ closed: [PointF], _ corners: [Bool], outsetRatio: Double, segmentLength: Double) -> ([PointF], [Bool], Bool) {
        let path = Array(closed.dropLast())
        let len = path.count
        var done = true
        var newPath: [PointF] = [], newCorners: [Bool] = []
        for i in 0..<len {
            newPath.append(path[i])
            newCorners.append(corners[i])
            let j = (i + 1) % len
            let lengthCurr = (path[i] - path[j]).norm
            if lengthCurr <= segmentLength { continue }
            var prev = i == 0 ? len - 1 : i - 1
            var next = (j + 1) % len
            let lengthPrev = (path[prev] - path[i]).norm, lengthNext = (path[next] - path[j]).norm
            if lengthPrev / lengthCurr >= 2 || lengthNext / lengthCurr >= 2 { continue }
            // The 3-point scheme next to corners keeps them sharp.
            if corners[i] { prev = i }
            if corners[j] { next = j }
            if prev == i && next == j { continue }
            let point = newPoint(path[i], path[j], path[prev], path[next], outsetRatio: outsetRatio)
            newPath.append(point)
            newCorners.append(false)
            if (path[i] - point).norm > segmentLength || (path[j] - point).norm > segmentLength { done = false }
        }
        newPath.append(newPath[0])
        return (newPath, newCorners, done)
    }

    private static func newPoint(_ pi: PointF, _ pj: PointF, _ p1: PointF, _ p2: PointF, outsetRatio: Double) -> PointF {
        let midOut = (pi + pj) * 0.5, midIn = (p1 + p2) * 0.5
        let vectorOut = midOut - midIn
        let magnitude = vectorOut.norm / outsetRatio
        if magnitude < Double.ulpOfOne { return midOut }
        return midOut + vectorOut.unit * magnitude
    }

    private static func retractHandles(_ a: PointF, _ b: PointF, _ c: PointF, _ d: PointF) -> [PointF] {
        let ab = b - a
        let dab = signedAngleDifference(angle((a - d).unit), angle(ab.unit))
        let abc = signedAngleDifference(angle(ab.unit), angle((c - b).unit))
        if (dab.sign == .plus) != (abc.sign == .plus), let x = findIntersection(a, b, c, d) { return [a, x, x, d] }
        return [a, b, c, d]
    }

    /// An integer polygon smoothed by repeated subdivision (`PathI32::smooth`).
    static func smooth(_ path: [PointI], cornerThreshold: Double, outsetRatio: Double, segmentLength: Double, maxIterations: Int) -> [PointF] {
        var current = path.map(\.f)
        var corners = findCorners(current, threshold: cornerThreshold)
        for _ in 0..<max(maxIterations, 1) {
            let result = subdivideKeepCorners(current, corners, outsetRatio: outsetRatio, segmentLength: segmentLength)
            current = result.0
            corners = result.1
            if result.2 { break }
        }
        return current
    }
}

// MARK: Splines (spline.rs)

/// Connected cubic Béziers: 1 + 3n points.
struct Spline {
    var points: [PointF]

    var isEmpty: Bool { points.count <= 3 }

    /// A polygon smoothed, cut at its splice points and fitted with one curve per piece (`Spline::from_path_f64`).
    static func from(_ closed: [PointF], spliceThreshold: Double) -> Spline {
        let splice = SubdivideSmooth.findSplicePoints(closed, threshold: spliceThreshold)
        let path = Array(closed.dropLast())
        let len = path.count
        if len <= 1 { return Spline(points: [PointF(x: 0, y: 0)]) }
        if len == 2 { return Spline(points: [path[0], path[1], path[1], path[1]]) }
        var cuts = splice.enumerated().filter(\.element).map(\.offset)
        if cuts.isEmpty { cuts.append(0) }
        if cuts.count == 1 { cuts.append((cuts[0] + len / 2) % len) }
        var points: [PointF] = []
        for i in 0..<cuts.count {
            let from = cuts[i], to = cuts[(i + 1) % cuts.count]
            let sub: [PointF] = from < to ? Array(path[from...to]) : from > to ? Array(path[from...]) + Array(path[0...to]) : []
            let bezier = SubdivideSmooth.fitPointsWithBezier(sub)
            if i == 0 { points = [bezier[0]] }
            points += bezier[1...3]
        }
        return Spline(points: points)
    }
}
