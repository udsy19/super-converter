import Foundation

/// Resampling (quality §2.4): separable Lanczos-3 in linear light on premultiplied values, a box pre-filter to twice
/// the target size for reductions beyond 2×, results clamped (no ringing overshoot); nearest-neighbour only for integer
/// pixel-art enlargements.
enum Resample {
    private struct Contribution { let first: Int; let weights: [Float] }

    private static func sinc(_ x: Double) -> Double {
        if x == 0 { return 1 }
        let px = Double.pi * x
        return sin(px) / px
    }

    private static func lanczos3(_ x: Double) -> Double { abs(x) < 3 ? sinc(x) * sinc(x / 3) : 0 }

    /// Lanczos-3 weights from `inSize` samples to `outSize` (kernel widened by the reduction factor when shrinking). Taps
    /// beyond the edges mirror back without repeating the edge sample (reflect-101), so the kernel is never truncated and
    /// a 1-px pattern keeps its average up to the border.
    private static func lanczosContributions(inSize: Int, outSize: Int) -> [Contribution] {
        let scale = Double(inSize) / Double(outSize)
        let filterScale = max(scale, 1)
        let support = 3 * filterScale
        func reflect(_ i: Int) -> Int {
            guard inSize > 1 else { return 0 }
            var j = i
            let period = 2 * (inSize - 1)
            j = ((j % period) + period) % period
            return j < inSize ? j : period - j
        }
        return (0..<outSize).map { o in
            let centre = (Double(o) + 0.5) * scale - 0.5
            let lo = Int(floor(centre - support)) + 1, hi = Int(ceil(centre + support)) - 1
            var taps: [(Int, Double)] = []
            var sum = 0.0
            for i in lo...max(lo, hi) {
                let w = lanczos3((Double(i) - centre) / filterScale)
                guard w != 0 else { continue }
                taps.append((reflect(i), w)); sum += w
            }
            guard sum != 0, let first = taps.map(\.0).min(), let last = taps.map(\.0).max() else {
                return Contribution(first: min(max(Int(centre.rounded()), 0), inSize - 1), weights: [1])
            }
            var weights = [Float](repeating: 0, count: last - first + 1)
            for (j, w) in taps { weights[j - first] += Float(w / sum) }
            return Contribution(first: first, weights: weights)
        }
    }

    /// Area-average (box) weights: each output sample averages exactly the input span it covers.
    private static func boxContributions(inSize: Int, outSize: Int) -> [Contribution] {
        let scale = Double(inSize) / Double(outSize)
        return (0..<outSize).map { o in
            let start = Double(o) * scale, end = start + scale
            let lo = Int(floor(start)), hi = min(Int(ceil(end)) - 1, inSize - 1)
            var weights: [Float] = []
            for i in lo...max(lo, hi) {
                let overlap = min(end, Double(i + 1)) - max(start, Double(i))
                weights.append(Float(max(overlap, 0) / scale))
            }
            return Contribution(first: lo, weights: weights)
        }
    }

    /// One separable pass along x (horizontal) or y.
    private static func pass(_ src: [Float], width: Int, height: Int, channels: Int, horizontal: Bool,
                             contributions: [Contribution]) -> [Float] {
        let outW = horizontal ? contributions.count : width
        let outH = horizontal ? height : contributions.count
        var out = [Float](repeating: 0, count: outW * outH * channels)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                let sp = s.baseAddress!, dp = d.baseAddress!
                if horizontal {
                    DispatchQueue.concurrentPerform(iterations: height) { y in
                        let srcRow = sp + y * width * channels, dstRow = dp + y * outW * channels
                        for (x, c) in contributions.enumerated() {
                            let target = dstRow + x * channels
                            for (j, w) in c.weights.enumerated() {
                                let p = srcRow + (c.first + j) * channels
                                for k in 0..<channels { target[k] += p[k] * w }
                            }
                        }
                    }
                } else {
                    let rowFloats = width * channels
                    DispatchQueue.concurrentPerform(iterations: outH) { y in
                        let c = contributions[y]
                        let dstRow = dp + y * rowFloats
                        for (j, w) in c.weights.enumerated() {
                            let srcRow = sp + (c.first + j) * rowFloats
                            for i in 0..<rowFloats { dstRow[i] += srcRow[i] * w }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Resamples `raster` (already in linear light where that applies) to `width` × `height`.
    static func lanczos(_ raster: Raster, width: Int, height: Int) -> Raster {
        guard width != raster.width || height != raster.height else { return raster }
        let channels = raster.stride
        var data = premultiplied(raster)
        var w = raster.width, h = raster.height
        // Box pre-filter to 2× the target for reductions beyond 2× (quality §2.4).
        if w > 2 * width {
            data = pass(data, width: w, height: h, channels: channels, horizontal: true, contributions: boxContributions(inSize: w, outSize: 2 * width))
            w = 2 * width
        }
        if h > 2 * height {
            data = pass(data, width: w, height: h, channels: channels, horizontal: false, contributions: boxContributions(inSize: h, outSize: 2 * height))
            h = 2 * height
        }
        if w != width {
            data = pass(data, width: w, height: h, channels: channels, horizontal: true, contributions: lanczosContributions(inSize: w, outSize: width))
            w = width
        }
        if h != height {
            data = pass(data, width: w, height: h, channels: channels, horizontal: false, contributions: lanczosContributions(inSize: h, outSize: height))
            h = height
        }
        var out = raster
        out.width = width; out.height = height
        out.data = data
        unpremultiply(&out)
        out.clamp()
        return out
    }

    /// Integer nearest-neighbour enlargement (pixel art).
    static func nearest(_ raster: Raster, factor: Int) -> Raster {
        guard factor > 1 else { return raster }
        let s = raster.stride, w = raster.width * factor, h = raster.height * factor
        var data = [Float](repeating: 0, count: w * h * s)
        for y in 0..<h {
            let sy = y / factor
            for x in 0..<w {
                let si = (sy * raster.width + x / factor) * s, di = (y * w + x) * s
                for k in 0..<s { data[di + k] = raster.data[si + k] }
            }
        }
        var out = raster
        out.width = w; out.height = h; out.data = data
        return out
    }

    private static func premultiplied(_ raster: Raster) -> [Float] {
        guard raster.hasAlpha else { return raster.data }
        var data = raster.data
        let s = raster.stride, comps = s - 1
        for i in 0..<raster.pixelCount {
            let a = data[i * s + comps]
            for c in 0..<comps { data[i * s + c] *= a }
        }
        return data
    }

    private static func unpremultiply(_ raster: inout Raster) {
        guard raster.hasAlpha else { return }
        let s = raster.stride, comps = s - 1, count = raster.pixelCount
        raster.data.withUnsafeMutableBufferPointer { d in
            for i in 0..<count {
                let a = d[i * s + comps]
                if a > 1e-6 {
                    let inv = 1 / a
                    for c in 0..<comps { d[i * s + c] *= inv }
                } else {
                    for c in 0...comps { d[i * s + c] = 0 }
                }
            }
        }
    }

    /// Unsharp mask (radius 0.5 px, amount 40 %) in the encoded space, for icon entries ≤ 64 px (quality §2.4).
    static func iconSharpen(_ raster: inout Raster, radius: Double = 0.5, amount: Float = 0.4) {
        let s = raster.stride, comps = raster.space.components, w = raster.width, h = raster.height
        let taps = (-2...2).map { exp(-Double($0 * $0) / (2 * radius * radius)) }
        let sum = taps.reduce(0, +)
        let k = taps.map { Float($0 / sum) }
        func blur(_ src: [Float], horizontal: Bool) -> [Float] {
            var out = src
            for y in 0..<h {
                for x in 0..<w {
                    for c in 0..<comps {
                        var acc: Float = 0
                        for (j, wt) in k.enumerated() {
                            let xx = horizontal ? min(max(x + j - 2, 0), w - 1) : x
                            let yy = horizontal ? y : min(max(y + j - 2, 0), h - 1)
                            acc += src[(yy * w + xx) * s + c] * wt
                        }
                        out[(y * w + x) * s + c] = acc
                    }
                }
            }
            return out
        }
        let blurred = blur(blur(raster.data, horizontal: true), horizontal: false)
        for i in 0..<raster.pixelCount {
            for c in 0..<comps {
                let v = raster.data[i * s + c]
                raster.data[i * s + c] = min(max(v + amount * (v - blurred[i * s + c]), 0), 1)
            }
        }
    }
}
