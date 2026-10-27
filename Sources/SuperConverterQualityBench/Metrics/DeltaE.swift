import ApplicationServices
import Foundation

/// CIE Lab (D50) colour and the CIEDE2000 difference (Sharma, Wu and Dalal 2005; quality §9).
struct Lab: Equatable {
    var l: Double, a: Double, b: Double
}

enum DeltaE {
    /// CIEDE2000 between two Lab colours, with kL = kC = kH = 1. Implements the equations of Sharma et al., §3, including
    /// the hue-difference and mean-hue branches.
    static func ciede2000(_ x: Lab, _ y: Lab) -> Double {
        let rad = Double.pi / 180
        let c1 = (x.a * x.a + x.b * x.b).squareRoot(), c2 = (y.a * y.a + y.b * y.b).squareRoot()
        let cBar = (c1 + c2) / 2
        let cBar7 = pow(cBar, 7)
        let g = 0.5 * (1 - (cBar7 / (cBar7 + pow(25, 7))).squareRoot())
        let a1 = (1 + g) * x.a, a2 = (1 + g) * y.a
        let cp1 = (a1 * a1 + x.b * x.b).squareRoot(), cp2 = (a2 * a2 + y.b * y.b).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double {
            if b == 0 && a == 0 { return 0 }
            let h = atan2(b, a) / rad
            return h >= 0 ? h : h + 360
        }
        let hp1 = hue(x.b, a1), hp2 = hue(y.b, a2)

        let dLp = y.l - x.l, dCp = cp2 - cp1
        var dhp = 0.0
        if cp1 * cp2 != 0 {
            dhp = hp2 - hp1
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (cp1 * cp2).squareRoot() * sin(dhp / 2 * rad)

        let lBar = (x.l + y.l) / 2, cpBar = (cp1 + cp2) / 2
        var hpBar = hp1 + hp2
        if cp1 * cp2 != 0 {
            if abs(hp1 - hp2) <= 180 { hpBar = (hp1 + hp2) / 2 }
            else if hp1 + hp2 < 360 { hpBar = (hp1 + hp2 + 360) / 2 }
            else { hpBar = (hp1 + hp2 - 360) / 2 }
        }
        let t = 1 - 0.17 * cos((hpBar - 30) * rad) + 0.24 * cos(2 * hpBar * rad) + 0.32 * cos((3 * hpBar + 6) * rad) - 0.20 * cos((4 * hpBar - 63) * rad)
        let dTheta = 30 * exp(-pow((hpBar - 275) / 25, 2))
        let cpBar7 = pow(cpBar, 7)
        let rc = 2 * (cpBar7 / (cpBar7 + pow(25, 7))).squareRoot()
        let sl = 1 + 0.015 * pow(lBar - 50, 2) / (20 + pow(lBar - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cpBar, sh = 1 + 0.015 * cpBar * t
        let rt = -sin(2 * dTheta * rad) * rc
        let l = dLp / sl, c = dCp / sc, h = dHp / sh
        return (l * l + c * c + h * h + rt * c * h).squareRoot()
    }

    /// sRGB → CIE Lab D50 for every pixel, through a ColorSync transform to the generic Lab profile (so the reference is the
    /// system's own colour management, not a formula of ours).
    static func lab(of raster: Raster) -> [Lab]? {
        guard let transform = labTransform else { return nil }
        let source = raster.rgb.map { Float($0) / 255 }
        var out = [Float](repeating: 0, count: raster.pixelCount * 3)
        let ok = source.withUnsafeBytes { input in
            out.withUnsafeMutableBytes { output in
                ColorSyncTransformConvert(transform, raster.width, raster.height, output.baseAddress, kColorSync32BitFloat, ColorSyncDataLayout(kColorSyncAlphaNone.rawValue),
                                          raster.width * 12, input.baseAddress, kColorSync32BitFloat, ColorSyncDataLayout(kColorSyncAlphaNone.rawValue),
                                          raster.width * 12, nil)
            }
        }
        guard ok else { return nil }
        // ColorSync's float Lab encoding: L in 0…1 for 0…100, a and b as value·255 − 127.5.
        return (0..<raster.pixelCount).map {
            Lab(l: Double(out[$0 * 3]) * 100, a: Double(out[$0 * 3 + 1]) * 255 - 127.5, b: Double(out[$0 * 3 + 2]) * 255 - 127.5)
        }
    }

    private static let labTransform: ColorSyncTransform? = {
        guard let source = ColorSyncProfileCreateWithName(kColorSyncSRGBProfile.takeUnretainedValue())?.takeRetainedValue(),
              let lab = ColorSyncProfileCreateWithName(kColorSyncGenericLabProfile.takeUnretainedValue())?.takeRetainedValue() else { return nil }
        func entry(_ profile: ColorSyncProfile, _ tag: CFString) -> [String: Any] {
            [kColorSyncProfile.takeUnretainedValue() as String: profile,
             kColorSyncRenderingIntent.takeUnretainedValue() as String: kColorSyncRenderingIntentRelative.takeUnretainedValue(),
             kColorSyncTransformTag.takeUnretainedValue() as String: tag]
        }
        let sequence = [entry(source, kColorSyncTransformDeviceToPCS.takeUnretainedValue()),
                        entry(lab, kColorSyncTransformPCSToDevice.takeUnretainedValue())]
        return ColorSyncTransformCreate(sequence as CFArray, nil)?.takeRetainedValue()
    }()

    /// Per-pixel ΔE00 between two same-size pictures.
    static func map(_ a: Raster, _ b: Raster) -> [Double]? {
        guard a.width == b.width, a.height == b.height, let la = lab(of: a), let lb = lab(of: b) else { return nil }
        return zip(la, lb).map { ciede2000($0, $1) }
    }

    struct Summary: Equatable { var mean: Double, p95: Double, max: Double }

    static func summarise(_ values: [Double]) -> Summary {
        guard !values.isEmpty else { return Summary(mean: 0, p95: 0, max: 0) }
        let sorted = values.sorted()
        return Summary(mean: values.reduce(0, +) / Double(values.count), p95: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], max: sorted[sorted.count - 1])
    }
}
