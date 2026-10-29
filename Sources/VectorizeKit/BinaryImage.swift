// Adapted from visioncortex src/{clusters,bound}.rs, src/shape/geometry.rs (boundary), src/path/{paths,compound}.rs
// (MIT, 0.8.8, commit 63d21c5b77489daa266304fdacf302b4c2d3a53e). Copyright (c) 2022 Tsang Hao Fung. See
// THIRD_PARTY_NOTICES.md.
// What changed: Swift; `image_to_paths` and `image_to_splines` share one hole search; outlines are written in absolute
// coordinates (no `translate`), the numbers with at most two decimals (vtracer's `path_precision` 2).
import Foundation

/// A pixel rectangle; `right` and `bottom` are exclusive.
struct BoundingRect {
    var left = 0, top = 0, right = 0, bottom = 0

    var width: Int { right - left }
    var height: Int { bottom - top }
    var isEmpty: Bool { width == 0 && height == 0 }

    mutating func add(x: Int, y: Int) {
        if isEmpty { left = x; right = x + 1; top = y; bottom = y + 1; return }
        if x < left { left = x } else if x + 1 > right { right = x + 1 }
        if y < top { top = y } else if y + 1 > bottom { bottom = y + 1 }
    }

    mutating func merge(_ other: BoundingRect) {
        if other.isEmpty { return }
        if isEmpty { self = other; return }
        left = min(left, other.left); right = max(right, other.right)
        top = min(top, other.top); bottom = max(bottom, other.bottom)
    }
}

/// One bit per pixel.
struct BinaryImage {
    let width: Int, height: Int
    var bits: [Bool]

    init(width: Int, height: Int) { self.width = width; self.height = height; bits = [Bool](repeating: false, count: width * height) }

    func pixel(_ x: Int, _ y: Int) -> Bool { bits[y * width + x] }
    func pixelSafe(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height && bits[y * width + x] }
    func pixelSafe(_ p: PointI) -> Bool { pixelSafe(p.x, p.y) }
    mutating func set(_ x: Int, _ y: Int, _ v: Bool) { bits[y * width + x] = v }

    var negative: BinaryImage { var n = self; n.bits = bits.map { !$0 }; return n }

    private func isBoundary(_ x: Int, _ y: Int) -> Bool {
        pixel(x, y) && (!pixelSafe(x - 1, y) || !pixelSafe(x + 1, y) || !pixelSafe(x, y - 1) || !pixelSafe(x, y + 1))
    }

    /// The number of set pixels with an unset 4-neighbour (`Shape::image_boundary_list(..).len()`).
    var perimeter: Int {
        var n = 0
        for y in 0..<height { for x in 0..<width where isBoundary(x, y) { n += 1 } }
        return n
    }

    /// The first boundary pixel in reading order: where the walk starts.
    var boundaryStart: PointI? {
        for y in 0..<height { for x in 0..<width where isBoundary(x, y) { return PointI(x: x, y: y) } }
        return nil
    }

    /// 4-connected (or 8-connected when `diagonal`) clusters of set pixels, in order of first appearance.
    func clusters(diagonal: Bool) -> [BinaryCluster] {
        var clusters: [BinaryCluster] = []
        var map = [Int](repeating: 0, count: width * height)
        var next = 0
        func combine(_ from: Int, _ to: Int) {
            for p in clusters[from].points { map[p.y * width + p.x] = to }
            clusters[to].points += clusters[from].points
            clusters[from].points = []
            clusters[to].rect.merge(clusters[from].rect)
        }
        for y in 0..<height {
            for x in 0..<width {
                let v = pixel(x, y), up = pixelSafe(x, y - 1), left = pixelSafe(x - 1, y), upLeft = pixelSafe(x - 1, y - 1)
                var clusterUp = y > 0 ? map[(y - 1) * width + x] : 0
                var clusterLeft = x > 0 ? map[y * width + x - 1] : 0
                let clusterUpLeft = x > 0 && y > 0 ? map[(y - 1) * width + x - 1] : 0
                if (v || diagonal) && up && left && clusterLeft != clusterUp {
                    if clusters[clusterLeft].points.count <= clusters[clusterUp].points.count {
                        combine(clusterLeft, clusterUp)
                        if next > 0 && clusterLeft == next - 1 && next == clusters.count { next -= 1 }
                        clusterLeft = clusterUp
                    } else {
                        combine(clusterUp, clusterLeft)
                        clusterUp = clusterLeft
                    }
                }
                guard v else { continue }
                let target: Int
                if up { target = clusterUp } else if left { target = clusterLeft } else if upLeft && diagonal { target = clusterUpLeft } else {
                    var fresh = BinaryCluster()
                    fresh.add(PointI(x: x, y: y))
                    if next < clusters.count { clusters[next] = fresh } else { clusters.append(fresh) }
                    map[y * width + x] = next
                    next += 1
                    continue
                }
                map[y * width + x] = target
                clusters[target].add(PointI(x: x, y: y))
            }
        }
        return clusters.filter { !$0.points.isEmpty }
    }

    // MARK: Outlines (clusters.rs `image_to_paths`, `image_to_splines`)

    /// The shape with its holes filled, then each hole (an unset region not touching the edge) on its own, with offsets.
    private func boundaries() -> [(BinaryImage, PointI)] {
        var outer = self
        var out: [(BinaryImage, PointI)] = []
        for hole in negative.clusters(diagonal: false) {
            if hole.rect.left == 0 || hole.rect.top == 0 || hole.rect.right == width || hole.rect.bottom == height { continue }
            for p in hole.points { outer.set(p.x, p.y, true) }
            out.append((hole.image, PointI(x: hole.rect.left, y: hole.rect.top)))
        }
        return [(outer, PointI(x: 0, y: 0))] + out
    }

    /// The outline (clockwise) and holes (counter-clockwise) of the image at `offset`, simplified by `mode`.
    func compoundPath(offset: PointI, mode: PathSimplifyMode, config: TraceConfig) -> [OutlinePath] {
        var out: [OutlinePath] = []
        for (i, (image, at)) in boundaries().enumerated() {
            let clockwise = i == 0
            guard let start = image.boundaryStart else { continue }
            var path = PathWalker.walk(image, start: start, clockwise: clockwise)
            if mode != .none { path = PathSimplify.limitPenalties(PathSimplify.removeStaircase(path, clockwise: clockwise), tolerance: config.penaltyTolerance) }
            let shift = PointI(x: offset.x + at.x, y: offset.y + at.y)
            switch mode {
            case .none, .polygon:
                if !path.isEmpty { out.append(.polygon(path.map { $0 + shift })) }
            case .spline:
                let smoothed = SubdivideSmooth.smooth(path, cornerThreshold: config.cornerThreshold, outsetRatio: 8,
                                                      segmentLength: config.lengthThreshold, maxIterations: config.maxIterations)
                let spline = Spline.from(smoothed, spliceThreshold: config.spliceThreshold)
                if !spline.isEmpty { out.append(.spline(spline.points.map { $0 + shift.f })) }
            }
        }
        return out
    }
}

/// A cluster of set pixels in absolute coordinates.
struct BinaryCluster {
    var points: [PointI] = []
    var rect = BoundingRect()

    mutating func add(_ p: PointI) { points.append(p); rect.add(x: p.x, y: p.y) }

    var image: BinaryImage {
        var image = BinaryImage(width: rect.width, height: rect.height)
        for p in points { image.set(p.x - rect.left, p.y - rect.top, true) }
        return image
    }

    func compoundPath(mode: PathSimplifyMode, config: TraceConfig) -> [OutlinePath] {
        image.compoundPath(offset: PointI(x: rect.left, y: rect.top), mode: mode, config: config)
    }
}

/// One closed outline of a compound path.
enum OutlinePath {
    case polygon([PointI])
    case spline([PointF])

    /// SVG path data: `M x y L … Z` for polygons (the last point repeats the first), `M x y C … Z` for splines.
    var svg: String {
        switch self {
        case .polygon(let points):
            guard let first = points.first else { return "" }
            var d = "M" + Self.pair(first.f)
            for p in points.dropFirst().dropLast() { d += "L" + Self.pair(p.f) }
            return d + "Z"
        case .spline(let points):
            guard let first = points.first else { return "" }
            var d = "M" + Self.pair(first)
            var i = 1
            while i + 2 < points.count {
                d += "C" + Self.pair(points[i]) + " " + Self.pair(points[i + 1]) + " " + Self.pair(points[i + 2])
                i += 3
            }
            return d + "Z"
        }
    }

    static func number(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if r == r.rounded() { return String(Int64(r)) }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    private static func pair(_ p: PointF) -> String { number(p.x) + " " + number(p.y) }
}
