import Foundation

/// Orientation, fit, crop and pad (quality §2.1 order: orientation → crop → resample).
enum Geometry {
    /// Applies an EXIF orientation (1–8) to the pixels; the result is orientation 1.
    static func orient(_ raster: Raster, _ orientation: Int) -> Raster {
        guard (2...8).contains(orientation) else { return raster }
        let w = raster.width, h = raster.height, s = raster.stride
        let swap = orientation >= 5
        let ow = swap ? h : w, oh = swap ? w : h
        var data = [Float](repeating: 0, count: raster.data.count)
        raster.data.withUnsafeBufferPointer { src in
            data.withUnsafeMutableBufferPointer { dst in
                for y in 0..<oh {
                    for x in 0..<ow {
                        let (sx, sy): (Int, Int)
                        switch orientation {
                        case 2: (sx, sy) = (w - 1 - x, y)
                        case 3: (sx, sy) = (w - 1 - x, h - 1 - y)
                        case 4: (sx, sy) = (x, h - 1 - y)
                        case 5: (sx, sy) = (y, x)
                        case 6: (sx, sy) = (y, h - 1 - x)
                        case 7: (sx, sy) = (w - 1 - y, h - 1 - x)
                        default: (sx, sy) = (w - 1 - y, x)
                        }
                        let si = (sy * w + sx) * s, di = (y * ow + x) * s
                        for k in 0..<s { dst[di + k] = src[si + k] }
                    }
                }
            }
        }
        var out = raster
        out.width = ow; out.height = oh; out.data = data
        return out
    }

    /// The size a source is resampled to, and the final canvas (crop or pad).
    struct Plan: Equatable {
        var scaledWidth: Int
        var scaledHeight: Int
        var canvasWidth: Int
        var canvasHeight: Int
    }

    /// formats §5 "Fit": max (never enlarges), crop (cover then centre-crop), scale (stretch), pad (fit then fill).
    static func plan(width: Int, height: Int, size: ImageSettings.Size, fit: ImageSettings.Fit) -> Plan {
        func r(_ v: Double) -> Int { max(Int(v.rounded()), 1) }
        switch size {
        case .original:
            return Plan(scaledWidth: width, scaledHeight: height, canvasWidth: width, canvasHeight: height)
        case .percent(let p):
            let w = r(Double(width) * p), h = r(Double(height) * p)
            return Plan(scaledWidth: w, scaledHeight: h, canvasWidth: w, canvasHeight: h)
        case .box(let bw, let bh):
            let sx = bw.map { Double($0) / Double(width) }, sy = bh.map { Double($0) / Double(height) }
            switch fit {
            case .scale:
                let w = bw ?? r(Double(width) * (sy ?? 1)), h = bh ?? r(Double(height) * (sx ?? 1))
                return Plan(scaledWidth: w, scaledHeight: h, canvasWidth: w, canvasHeight: h)
            case .crop where sx != nil && sy != nil:
                let s = max(sx!, sy!), boxW = bw!, boxH = bh!
                return Plan(scaledWidth: max(r(Double(width) * s), boxW), scaledHeight: max(r(Double(height) * s), boxH),
                            canvasWidth: boxW, canvasHeight: boxH)
            case .crop, .max, .pad:
                let s = min(sx ?? .infinity, sy ?? .infinity, 1)   // never enlarges
                let w = r(Double(width) * s), h = r(Double(height) * s)
                if fit == .pad, let bw, let bh { return Plan(scaledWidth: w, scaledHeight: h, canvasWidth: max(bw, w), canvasHeight: max(bh, h)) }
                return Plan(scaledWidth: w, scaledHeight: h, canvasWidth: w, canvasHeight: h)
            }
        }
    }

    /// Centres `raster` on a `width` × `height` canvas: crops when smaller, fills with `fill` (every channel) when larger.
    static func canvas(_ raster: Raster, width: Int, height: Int, fill: [Float]) -> Raster {
        guard width != raster.width || height != raster.height else { return raster }
        let s = raster.stride
        var data = [Float](repeating: 0, count: width * height * s)
        for i in 0..<(width * height) { for k in 0..<s { data[i * s + k] = fill[k] } }
        let ox = (width - raster.width) / 2, oy = (height - raster.height) / 2
        for y in 0..<raster.height {
            let ty = y + oy
            guard ty >= 0, ty < height else { continue }
            for x in 0..<raster.width {
                let tx = x + ox
                guard tx >= 0, tx < width else { continue }
                let si = (y * raster.width + x) * s, di = (ty * width + tx) * s
                for k in 0..<s { data[di + k] = raster.data[si + k] }
            }
        }
        var out = raster
        out.width = width; out.height = height; out.data = data
        return out
    }
}

/// Bit-depth reduction (quality §2.1: once, with dither): Floyd–Steinberg error diffusion with serpentine scanning, so
/// 16-bit gradients do not band in 8 bits.
enum Dither {
    /// Rounds every component to `bits` levels, diffusing the error; alpha is rounded plainly.
    static func quantise(_ raster: inout Raster, bits: Int) {
        let levels = Float((1 << bits) - 1)
        let s = raster.stride, comps = raster.space.components, w = raster.width, h = raster.height
        var errCurrent = [Float](repeating: 0, count: (w + 2) * comps)
        var errNext = [Float](repeating: 0, count: (w + 2) * comps)
        raster.data.withUnsafeMutableBufferPointer { d in
            for y in 0..<h {
                let leftToRight = y % 2 == 0
                let fwd = leftToRight ? 1 : -1
                for step in 0..<w {
                    let x = leftToRight ? step : w - 1 - step
                    let i = (y * w + x) * s
                    for c in 0..<comps {
                        let v = min(max(d[i + c] + errCurrent[(x + 1) * comps + c], 0), 1)
                        let q = (v * levels).rounded() / levels
                        d[i + c] = q
                        let e = v - q
                        errCurrent[(x + 1 + fwd) * comps + c] += e * 7 / 16
                        errNext[(x + 1 - fwd) * comps + c] += e * 3 / 16
                        errNext[(x + 1) * comps + c] += e * 5 / 16
                        errNext[(x + 1 + fwd) * comps + c] += e / 16
                    }
                    if s > comps { d[i + comps] = (min(max(d[i + comps], 0), 1) * levels).rounded() / levels }
                }
                swap(&errCurrent, &errNext)
                for k in 0..<errNext.count { errNext[k] = 0 }
            }
        }
    }
}
