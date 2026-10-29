// Adapted from visioncortex src/color_clusters/{builder,cluster,container,runner}.rs and src/color.rs (`ColorSum`)
// (MIT, 0.8.8, commit 63d21c5b77489daa266304fdacf302b4c2d3a53e). Copyright (c) 2022 Tsang Hao Fung. See
// THIRD_PARTY_NOTICES.md.
// What changed: Swift; the runner's closures are written out (vtracer's `RunnerConfig` is the only configuration used);
// stage 1 and stage 2 run to completion with progress and cancellation between rows and area levels instead of ticking;
// the hole and depth bookkeeping of `merge_cluster_into` is left out (vtracer draws clusters without cutting holes).
import Foundation
import SuperConverterCore

/// Hierarchical colour clustering: pixels of the same colour (at the configured precision) are clustered, then clusters
/// are merged into their most similar neighbour from the smallest up. A cluster that is large enough and different
/// enough from that neighbour is kept as a layer ("deepened") while its pixels also join the neighbour, so every layer
/// covers the ones above it (vtracer's stacked output).
struct ColorClusters {
    struct RGBA: Equatable { var r: UInt8, g: UInt8, b: UInt8, a: UInt8 }

    struct ColorSum {
        var r = 0, g = 0, b = 0, a = 0, count = 0
        mutating func add(_ c: RGBA) { r += Int(c.r); g += Int(c.g); b += Int(c.b); a += Int(c.a); count += 1 }
        mutating func merge(_ o: ColorSum) { r += o.r; g += o.g; b += o.b; a += o.a; count += o.count }
        var average: RGBA {
            guard count > 0 else { return RGBA(r: 0, g: 0, b: 0, a: 0) }
            return RGBA(r: UInt8(r / count), g: UInt8(g / count), b: UInt8(b / count), a: UInt8(a / count))
        }
    }

    struct Cluster {
        var indices: [Int] = []
        var sum = ColorSum()
        var residueSum = ColorSum()
        var rect = BoundingRect()
        var area: Int { indices.count }
        var colour: RGBA { sum.average }
        var residueColour: RGBA { residueSum.average }
    }

    /// vtracer's `RunnerConfig` for colour images (`color_image_to_svg`).
    struct Config {
        var diagonal: Bool
        var goodMinArea: Int
        var goodMaxArea: Int
        /// Bits dropped before comparing colours (8 − colour precision).
        var sameShift: Int
        var sameThreshold = 1
        var deepenDiff: Int
        /// Pixels of this colour are left out (keyed transparency); nil when nothing is keyed.
        var key: RGBA?
    }

    let width: Int, height: Int
    private(set) var clusters: [Cluster] = [Cluster()]
    private var clusterIndices: [Int]
    /// The kept clusters, smallest first; the last is the background.
    private(set) var output: [Int] = []
    private let pixels: [UInt8]
    private let config: Config

    /// Cluster 0 is reserved.
    private static let zero = 0

    init(pixels: [UInt8], width: Int, height: Int, config: Config) {
        self.pixels = pixels; self.width = width; self.height = height; self.config = config
        clusterIndices = [Int](repeating: 0, count: width * height)
    }

    // MARK: Colours (runner.rs)

    private static func diff(_ a: RGBA, _ b: RGBA) -> Int { abs(Int(a.r) - Int(b.r)) + abs(Int(a.g) - Int(b.g)) + abs(Int(a.b) - Int(b.b)) }

    private func same(_ a: RGBA, _ b: RGBA) -> Bool {
        let s = config.sameShift, t = config.sameThreshold
        return abs(Int(a.r >> s) - Int(b.r >> s)) <= t && abs(Int(a.g >> s) - Int(b.g >> s)) <= t && abs(Int(a.b >> s) - Int(b.b >> s)) <= t
    }

    private func pixel(_ x: Int, _ y: Int) -> RGBA? {
        guard x >= 0, y >= 0 else { return nil }
        let i = (y * width + x) * 4
        guard i < pixels.count else { return nil }
        return RGBA(r: pixels[i], g: pixels[i + 1], b: pixels[i + 2], a: pixels[i + 3])
    }

    private func isSame(_ a: RGBA?, _ b: RGBA?) -> Bool { if let a, let b { same(a, b) } else { false } }

    // MARK: Building (builder.rs)

    /// Runs both stages. `progress` gets 0…1.
    mutating func run(progress: (Double) -> Void, isCancelled: () -> Bool) throws {
        try stage1(progress: progress, isCancelled: isCancelled)
        try stage2(progress: progress, isCancelled: isCancelled)
    }

    private mutating func combine(_ from: Int, _ to: Int) {
        for i in clusters[from].indices { clusterIndices[i] = to }
        clusters[to].indices += clusters[from].indices
        clusters[from].indices = []
        clusters[to].sum.merge(clusters[from].sum)
        clusters[to].rect.merge(clusters[from].rect)
        clusters[from].sum = ColorSum()
        clusters[from].rect = BoundingRect()
    }

    /// Stage 1: a raster scan joining each pixel to its upper or left neighbour's cluster when the colours are the same.
    private mutating func stage1(progress: (Double) -> Void, isCancelled: () -> Bool) throws {
        var next = 1
        for y in 0..<height {
            if isCancelled() { throw ConversionError.cancelled }
            for x in 0..<width {
                let i = y * width + x
                let colour = pixel(x, y), up = pixel(x, y - 1), left = pixel(x - 1, y), upLeft = pixel(x - 1, y - 1)
                var clusterUp = y > 0 ? clusterIndices[i - width] : Self.zero
                var clusterLeft = x > 0 ? clusterIndices[i - 1] : Self.zero
                let clusterUpLeft = x > 0 && y > 0 ? clusterIndices[i - width - 1] : Self.zero
                if clusterLeft != clusterUp && isSame(left, up) && (config.diagonal || isSame(colour, left) && isSame(colour, up)) {
                    if clusters[clusterLeft].area <= clusters[clusterUp].area {
                        combine(clusterLeft, clusterUp)
                        if clusterLeft == next - 1 && next == clusters.count { next -= 1 }
                        clusterLeft = clusterUp
                    } else {
                        combine(clusterUp, clusterLeft)
                        clusterUp = clusterLeft
                    }
                }
                guard let c = colour else { continue }
                var target: Int?
                if let key = config.key, c == key {
                    continue   // keyed pixels are discarded (stacked output)
                } else if isSame(colour, up) && isSame(colour, upLeft) {
                    target = clusterUp
                } else if isSame(colour, left) && isSame(colour, upLeft) {
                    target = clusterLeft
                } else if config.diagonal && isSame(colour, upLeft) {
                    target = clusterUpLeft
                }
                if let target {
                    clusterIndices[i] = target
                    clusters[target].indices.append(i); clusters[target].sum.add(c); clusters[target].rect.add(x: x, y: y)
                } else {
                    var fresh = Cluster()
                    fresh.indices.append(i); fresh.sum.add(c); fresh.rect.add(x: x, y: y)
                    if next < clusters.count { clusters[next] = fresh } else { clusters.append(fresh) }
                    clusterIndices[i] = next
                    next += 1
                }
            }
            progress(0.5 * Double(y + 1) / Double(height))
        }
    }

    /// Stage 2: from the smallest area up, each cluster merges into its most similar neighbour; one that is good (big and
    /// solid enough) and differs from it by more than `deepenDiff` is kept as a layer first.
    private mutating func stage2(progress: (Double) -> Void, isCancelled: () -> Bool) throws {
        for i in clusters.indices { clusters[i].residueSum = clusters[i].sum }
        var counts: [Int: Int] = [:]
        for c in clusters where c.area > 0 { counts[c.area, default: 0] += 1 }
        var areas = counts.map { (area: $0.key, count: $0.value) }.sorted { $0.area < $1.area }
        let canDiscardPixels = config.key != nil
        var iteration = 0
        while iteration < areas.count {
            if isCancelled() { throw ConversionError.cancelled }
            if areas[iteration].count == 0 { iteration += 1; continue }
            let current = areas[iteration].area
            for index in clusters.indices where clusters[index].area == current {
                let mine = clusters[index].colour
                var infos = neighbours(index).map { (index: $0, diff: Self.diff(mine, clusters[$0].colour)) }
                if infos.isEmpty {
                    // The final background, or an island among discarded (keyed) pixels.
                    if iteration == areas.count - 1 || canDiscardPixels { output.append(index) }
                    continue
                }
                infos.sort { ($0.diff, $0.index) < ($1.diff, $1.index) }
                let target = infos[0].index
                let deepen = patchGood(index) && infos[0].diff > config.deepenDiff
                if deepen { output.append(index) }
                let targetArea = clusters[target].area
                areas[areas.partitioningIndex { $0.area >= targetArea }].count -= 1
                mergeCluster(index, into: target, deepen: deepen)
                let updated = clusters[target].area
                let pos = areas.partitioningIndex { $0.area >= updated }
                if pos < areas.count && areas[pos].area == updated { areas[pos].count += 1 } else { areas.insert((updated, 1), at: pos) }
            }
            iteration += 1
            progress(0.5 + 0.4 * Double(iteration) / Double(max(areas.count, 1)))
        }
    }

    private mutating func mergeCluster(_ from: Int, into to: Int, deepen: Bool) {
        if !deepen {
            clusters[to].residueSum.merge(clusters[from].residueSum)
            combine(from, to)
            return
        }
        // Keep the layer: its pixels join the target, but it keeps its own copy.
        let kept = clusters[from]
        combine(from, to)
        clusters[from].sum = kept.sum; clusters[from].rect = kept.rect; clusters[from].indices = kept.indices
    }

    /// Big enough, not the whole picture, and not a thread thinner than 2 px.
    private func patchGood(_ index: Int) -> Bool {
        let c = clusters[index]
        guard config.goodMinArea < c.area && c.area < config.goodMaxArea else { return false }
        return config.goodMinArea == 0 || image(of: c).perimeter < c.area
    }

    /// 4-neighbouring clusters, sorted by index.
    private func neighbours(_ index: Int) -> [Int] {
        let c = clusters[index]
        guard let first = c.indices.first else { return [] }
        let myself = clusterIndices[first]
        var found = Set<Int>()
        for i in c.indices {
            let x = i % width, y = i / width
            for n in [y > 0 ? clusterIndices[i - width] : Self.zero, y < height - 1 ? clusterIndices[i + width] : Self.zero,
                      x > 0 ? clusterIndices[i - 1] : Self.zero, x < width - 1 ? clusterIndices[i + 1] : Self.zero]
            where n != Self.zero && n != myself { found.insert(n) }
        }
        return found.sorted()
    }

    // MARK: Output (cluster.rs)

    /// The cluster's pixels in its own rectangle (holes not cut: vtracer passes `hole: false`).
    func image(of c: Cluster) -> BinaryImage {
        var image = BinaryImage(width: c.rect.width, height: c.rect.height)
        for i in c.indices { image.set(i % width - c.rect.left, i / width - c.rect.top, true) }
        return image
    }

    /// The outlines of every 4-connected piece of a kept cluster.
    func compoundPath(_ index: Int, mode: PathSimplifyMode, config: TraceConfig) -> [OutlinePath] {
        let c = clusters[index]
        return image(of: c).clusters(diagonal: false).flatMap { piece in
            piece.image.compoundPath(offset: PointI(x: c.rect.left + piece.rect.left, y: c.rect.top + piece.rect.top), mode: mode, config: config)
        }
    }
}

private extension Array {
    /// The first index whose element satisfies `belongs` (which must be false then true along the array).
    func partitioningIndex(where belongs: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi { let mid = (lo + hi) / 2; if belongs(self[mid]) { hi = mid } else { lo = mid + 1 } }
        return lo
    }
}
