import Accelerate
import Foundation

/// SSIM and MS-SSIM (Wang, Bovik, Sheikh and Simoncelli 2004; Wang, Simoncelli and Bovik 2003) on a luma plane, with the
/// standard 11 x 11 Gaussian window (sigma 1.5), K1 = 0.01, K2 = 0.03, L = 255, "valid" windows only (no padding).
enum SSIM {
    static let k1: Double = 0.01, k2: Double = 0.03, range: Double = 255
    static let windowSize = 11
    /// MS-SSIM scale weights (Wang 2003).
    static let msWeights: [Double] = [0.0448, 0.2856, 0.3001, 0.2363, 0.1333]

    struct Plane {
        var width: Int, height: Int
        var values: [Double]
    }

    struct Result {
        /// Mean SSIM over the valid windows.
        var mean: Double
        /// Mean of the contrast-structure term alone (what MS-SSIM multiplies at the coarse scales).
        var meanCS: Double
        /// The SSIM index per valid window, `mapWidth * mapHeight`.
        var map: [Double]
        var mapWidth: Int, mapHeight: Int
    }

    /// The normalised 1-D Gaussian (the 2-D window is its outer product).
    static let kernel: [Double] = {
        let sigma = 1.5, half = windowSize / 2
        let raw = (0..<windowSize).map { exp(-pow(Double($0 - half), 2) / (2 * sigma * sigma)) }
        let sum = raw.reduce(0, +)
        return raw.map { Double($0 / sum) }
    }()

    /// Valid separable convolution with `kernel` (vDSP does the multiply-adds, so debug builds stay fast).
    private static func filter(_ plane: Plane) -> Plane {
        let n = windowSize, w = plane.width, h = plane.height
        let ow = w - n + 1, oh = h - n + 1
        // Rows: (h x w) -> (h x ow).
        var horizontal = [Double](repeating: 0, count: ow * h)
        plane.values.withUnsafeBufferPointer { input in
            horizontal.withUnsafeMutableBufferPointer { output in
                for y in 0..<h { vDSP_convD(input.baseAddress! + y * w, 1, kernel, 1, output.baseAddress! + y * ow, 1, vDSP_Length(ow), vDSP_Length(n)) }
            }
        }
        // Columns: transpose (h x ow) -> (ow x h), filter rows -> (ow x oh), transpose back to (oh x ow).
        var transposed = [Double](repeating: 0, count: ow * h)
        vDSP_mtransD(horizontal, 1, &transposed, 1, vDSP_Length(ow), vDSP_Length(h))
        var columns = [Double](repeating: 0, count: ow * oh)
        transposed.withUnsafeBufferPointer { input in
            columns.withUnsafeMutableBufferPointer { output in
                for x in 0..<ow { vDSP_convD(input.baseAddress! + x * h, 1, kernel, 1, output.baseAddress! + x * oh, 1, vDSP_Length(oh), vDSP_Length(n)) }
            }
        }
        var out = [Double](repeating: 0, count: ow * oh)
        vDSP_mtransD(columns, 1, &out, 1, vDSP_Length(oh), vDSP_Length(ow))
        return Plane(width: ow, height: oh, values: out)
    }

    /// SSIM of two same-size planes; nil when either side is smaller than the window.
    static func compare(_ x: Plane, _ y: Plane) -> Result? {
        guard x.width == y.width, x.height == y.height, x.width >= windowSize, x.height >= windowSize else { return nil }
        let c1 = (k1 * range) * (k1 * range), c2 = (k2 * range) * (k2 * range)
        let mx = filter(x), my = filter(y)
        let xx = filter(Plane(width: x.width, height: x.height, values: vDSP.multiply(x.values, x.values)))
        let yy = filter(Plane(width: y.width, height: y.height, values: vDSP.multiply(y.values, y.values)))
        let xy = filter(Plane(width: x.width, height: x.height, values: vDSP.multiply(x.values, y.values)))
        var map = [Double](repeating: 0, count: mx.values.count)
        var total = 0.0, totalCS = 0.0
        for i in 0..<map.count {
            let ux = mx.values[i], uy = my.values[i]
            let sx = xx.values[i] - ux * ux, sy = yy.values[i] - uy * uy, sxy = xy.values[i] - ux * uy
            let cs = (2 * sxy + c2) / (sx + sy + c2)
            let l = (2 * ux * uy + c1) / (ux * ux + uy * uy + c1)
            map[i] = l * cs
            total += Double(l * cs); totalCS += Double(cs)
        }
        let count = Double(map.count)
        return Result(mean: total / count, meanCS: totalCS / count, map: map, mapWidth: mx.width, mapHeight: mx.height)
    }

    /// 2 x 2 box downsample (the MS-SSIM reference does the same between scales).
    static func halve(_ plane: Plane) -> Plane {
        let w = plane.width / 2, h = plane.height / 2
        var out = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (2 * y) * plane.width + 2 * x
                out[y * w + x] = (plane.values[i] + plane.values[i + 1] + plane.values[i + plane.width] + plane.values[i + plane.width + 1]) / 4
            }
        }
        return Plane(width: w, height: h, values: out)
    }

    /// MS-SSIM over five scales: the product of the contrast-structure terms of scales 1…4 and the full SSIM of scale 5,
    /// each raised to its weight. Nil when the picture is too small for five scales (176 px on the short side).
    static func multiScale(_ x: Plane, _ y: Plane) -> Double? {
        var a = x, b = y, product = 1.0
        for scale in 0..<msWeights.count {
            guard let r = compare(a, b) else { return nil }
            product *= pow(max(scale == msWeights.count - 1 ? r.mean : r.meanCS, 1e-9), msWeights[scale])
            if scale < msWeights.count - 1 { a = halve(a); b = halve(b) }
        }
        return product
    }

    static func luma(_ raster: Raster) -> Plane { Plane(width: raster.width, height: raster.height, values: raster.luma) }

    static func ssim(_ a: Raster, _ b: Raster) -> Result? { compare(luma(a), luma(b)) }
    static func msSSIM(_ a: Raster, _ b: Raster) -> Double? { multiScale(luma(a), luma(b)) }
}

enum PSNR {
    /// The value reported for identical pictures (the formula diverges).
    static let identical = 999.0

    /// PSNR in dB over all three channels of two same-size 8-bit pictures.
    static func compare(_ a: Raster, _ b: Raster) -> Double? {
        guard a.width == b.width, a.height == b.height else { return nil }
        var sum = 0.0
        for i in 0..<a.rgb.count { let d = Double(a.rgb[i]) - Double(b.rgb[i]); sum += d * d }
        let mse = sum / Double(a.rgb.count)
        return mse == 0 ? identical : 10 * log10(255 * 255 / mse)
    }
}
