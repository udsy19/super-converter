import Foundation

/// Pixels reduced to a small palette: `labels[p]` is a palette index, or -1 where the pixel is (nearly) transparent.
struct Quantized {
    var width: Int
    var height: Int
    var labels: [Int32]
    var palette: [(r: Int, g: Int, b: Int)]
}

enum Quantizer {
    private struct Bin { var count = 0, r = 0, g = 0, b = 0 }

    static func key(_ r: UInt8, _ g: UInt8, _ b: UInt8, bits: Int) -> UInt32 {
        let s = UInt32(8 - bits)
        return UInt32(r >> s) << 16 | UInt32(g >> s) << 8 | UInt32(b >> s)
    }

    /// Number of distinct reduced colours among opaque pixels and the most frequent one's luminance (0...1).
    static func survey(_ raster: Raster, bits: Int) -> (distinct: Int, dominantLuminance: Double) {
        var counts: [UInt32: Int] = [:]
        var sums: [UInt32: (Int, Int, Int)] = [:]
        for p in 0..<(raster.width * raster.height) where raster.rgba[p * 4 + 3] >= 128 {
            let k = key(raster.rgba[p * 4], raster.rgba[p * 4 + 1], raster.rgba[p * 4 + 2], bits: bits)
            counts[k, default: 0] += 1
            let s = sums[k] ?? (0, 0, 0)
            sums[k] = (s.0 + Int(raster.rgba[p * 4]), s.1 + Int(raster.rgba[p * 4 + 1]), s.2 + Int(raster.rgba[p * 4 + 2]))
        }
        guard let top = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }), let s = sums[top.key] else { return (0, 1) }
        let n = Double(top.value)
        return (counts.count, (0.299 * Double(s.0) + 0.587 * Double(s.1) + 0.114 * Double(s.2)) / n / 255)
    }

    /// Median cut to at most `size` colours at `bits` bits per channel.
    static func medianCut(_ raster: Raster, size: Int, bits: Int, isCancelled: () -> Bool) -> Quantized {
        let total = raster.width * raster.height
        var bins: [UInt32: Bin] = [:]
        var pixelKeys = [UInt32](repeating: .max, count: total)
        for p in 0..<total where raster.rgba[p * 4 + 3] >= 128 {
            let r = raster.rgba[p * 4], g = raster.rgba[p * 4 + 1], b = raster.rgba[p * 4 + 2]
            let k = key(r, g, b, bits: bits)
            pixelKeys[p] = k
            var bin = bins[k] ?? Bin()
            bin.count += 1; bin.r += Int(r); bin.g += Int(g); bin.b += Int(b)
            bins[k] = bin
        }
        var boxes: [[UInt32]] = bins.isEmpty ? [] : [bins.keys.sorted()]
        func population(_ box: [UInt32]) -> Int { box.reduce(0) { $0 + bins[$1]!.count } }
        while boxes.count < size, !isCancelled() {
            var best = -1, bestPop = 0
            for (i, box) in boxes.enumerated() where box.count > 1 {
                let pop = population(box)
                if pop > bestPop { best = i; bestPop = pop }
            }
            if best < 0 { break }
            let box = boxes[best]
            var lo = [Int](repeating: 255, count: 3), hi = [Int](repeating: 0, count: 3)
            for k in box {
                for c in 0..<3 { let v = Int((k >> UInt32(16 - 8 * c)) & 255); lo[c] = min(lo[c], v); hi[c] = max(hi[c], v) }
            }
            var channel = 0
            for c in 1..<3 where hi[c] - lo[c] > hi[channel] - lo[channel] { channel = c }
            let shift = UInt32(16 - 8 * channel)
            let sorted = box.sorted { (($0 >> shift) & 255, $0) < (($1 >> shift) & 255, $1) }
            var running = 0, cut = 1
            for (i, k) in sorted.enumerated() {
                running += bins[k]!.count
                if running * 2 >= bestPop { cut = min(max(i + 1, 1), sorted.count - 1); break }
            }
            boxes[best] = Array(sorted[..<cut])
            boxes.append(Array(sorted[cut...]))
        }
        var boxOf: [UInt32: Int32] = [:]
        var palette: [(r: Int, g: Int, b: Int)] = []
        for (i, box) in boxes.enumerated() {
            var n = 0, r = 0, g = 0, b = 0
            for k in box { let bin = bins[k]!; n += bin.count; r += bin.r; g += bin.g; b += bin.b; boxOf[k] = Int32(i) }
            palette.append(((r + n / 2) / n, (g + n / 2) / n, (b + n / 2) / n))
        }
        var labels = [Int32](repeating: -1, count: total)
        for p in 0..<total where pixelKeys[p] != .max { labels[p] = boxOf[pixelKeys[p]]! }
        return Quantized(width: raster.width, height: raster.height, labels: labels, palette: palette)
    }

    /// Two classes by Otsu's threshold on luminance: label 0 is the dark class (drawn), label 1 the light one.
    static func blackAndWhite(_ raster: Raster) -> Quantized {
        let total = raster.width * raster.height
        var hist = [Int](repeating: 0, count: 256)
        var lum = [Int](repeating: -1, count: total)
        for p in 0..<total where raster.rgba[p * 4 + 3] >= 128 {
            let l = (299 * Int(raster.rgba[p * 4]) + 587 * Int(raster.rgba[p * 4 + 1]) + 114 * Int(raster.rgba[p * 4 + 2]) + 500) / 1000
            lum[p] = l; hist[l] += 1
        }
        let count = hist.reduce(0, +)
        var sumAll = 0
        for i in 0..<256 { sumAll += i * hist[i] }
        var bestT = 127, bestVar = -1.0, wB = 0, sumB = 0
        for t in 0..<256 {
            wB += hist[t]; sumB += t * hist[t]
            let wF = count - wB
            if wB == 0 || wF == 0 { continue }
            let mB = Double(sumB) / Double(wB), mF = Double(sumAll - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > bestVar { bestVar = between; bestT = t }
        }
        var labels = [Int32](repeating: -1, count: total)
        var sums = [[Int]](repeating: [0, 0, 0, 0], count: 2)
        var grey = true
        for p in 0..<total where lum[p] >= 0 {
            let label = bestVar < 0 ? (lum[p] < 128 ? 0 : 1) : (lum[p] <= bestT ? 0 : 1)
            labels[p] = Int32(label)
            let r = Int(raster.rgba[p * 4]), g = Int(raster.rgba[p * 4 + 1]), b = Int(raster.rgba[p * 4 + 2])
            sums[label][0] += r; sums[label][1] += g; sums[label][2] += b; sums[label][3] += 1
            if label == 0, abs(r - g) > 8 || abs(g - b) > 8 { grey = false }
        }
        func mean(_ l: Int) -> (r: Int, g: Int, b: Int) {
            let n = max(sums[l][3], 1)
            return ((sums[l][0] + n / 2) / n, (sums[l][1] + n / 2) / n, (sums[l][2] + n / 2) / n)
        }
        return Quantized(width: raster.width, height: raster.height, labels: labels, palette: [grey ? (0, 0, 0) : mean(0), mean(1)])
    }

    /// Merges 4-connected regions smaller than `limit` pixels into the neighbour they share the longest border with
    /// (transparent included, so a speck on a transparent background disappears).
    static func removeSpecks(_ q: inout Quantized, limit: Int, isCancelled: () -> Bool) {
        guard limit > 1 else { return }
        let w = q.width, h = q.height
        var seen = [Bool](repeating: false, count: w * h)
        var queue: [Int] = []
        for start in 0..<(w * h) where !seen[start] {
            if start % 4096 == 0, isCancelled() { return }
            let label = q.labels[start]
            queue.removeAll(keepingCapacity: true)
            queue.append(start); seen[start] = true
            var head = 0
            var borders: [Int32: Int] = [:]
            while head < queue.count {
                let p = queue[head]; head += 1
                let x = p % w, y = p / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                    let n = ny * w + nx
                    if q.labels[n] == label {
                        if !seen[n] { seen[n] = true; queue.append(n) }
                    } else if queue.count < limit { borders[q.labels[n], default: 0] += 1 }
                }
            }
            if queue.count < limit, let target = borders.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key {
                for p in queue { q.labels[p] = target }
            }
        }
    }
}
