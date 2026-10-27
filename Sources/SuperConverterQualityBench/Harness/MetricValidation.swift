import Foundation

/// Every metric checked against published reference values before the bench trusts it (quality §9). The cases run only
/// when all of these pass.
enum MetricValidation {
    struct Outcome {
        var name: String
        var passed: Bool
        var skipped: Bool = false
        var detail: String
    }

    static func runAll() -> [Outcome] {
        [deltaE2000Sharma(), colorSyncLab(), colorSyncDeltaE(), gaussianWindow(), ssimConstants(), ssimIdentity(), ssimDetectsChange(), msSSIMConstants(),
         psnr(), thdQuantisation(), thdHarmonic(), loudnessParser(), loudnessEBUTestTone(), sha256Vectors(), manifestRoundTrip(), regressionBand()]
    }

    private static func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

    // MARK: CIEDE2000

    /// The 34 test pairs of Sharma, Wu and Dalal, "The CIEDE2000 Colour-Difference Formula: Implementation Notes,
    /// Supplementary Test Data, and Mathematical Observations" (Color Research & Application 30, 2005), table 1.
    static let sharma: [(Lab, Lab, Double)] = [
        (Lab(l: 50, a: 2.6772, b: -79.7751), Lab(l: 50, a: 0, b: -82.7485), 2.0425),
        (Lab(l: 50, a: 3.1571, b: -77.2803), Lab(l: 50, a: 0, b: -82.7485), 2.8615),
        (Lab(l: 50, a: 2.8361, b: -74.0200), Lab(l: 50, a: 0, b: -82.7485), 3.4412),
        (Lab(l: 50, a: -1.3802, b: -84.2814), Lab(l: 50, a: 0, b: -82.7485), 1.0000),
        (Lab(l: 50, a: -1.1848, b: -84.8006), Lab(l: 50, a: 0, b: -82.7485), 1.0000),
        (Lab(l: 50, a: -0.9009, b: -85.5211), Lab(l: 50, a: 0, b: -82.7485), 1.0000),
        (Lab(l: 50, a: 0, b: 0), Lab(l: 50, a: -1, b: 2), 2.3669),
        (Lab(l: 50, a: -1, b: 2), Lab(l: 50, a: 0, b: 0), 2.3669),
        (Lab(l: 50, a: 2.49, b: -0.001), Lab(l: 50, a: -2.49, b: 0.0009), 7.1792),
        (Lab(l: 50, a: 2.49, b: -0.001), Lab(l: 50, a: -2.49, b: 0.0010), 7.1792),
        (Lab(l: 50, a: 2.49, b: -0.001), Lab(l: 50, a: -2.49, b: 0.0011), 7.2195),
        (Lab(l: 50, a: 2.49, b: -0.001), Lab(l: 50, a: -2.49, b: 0.0012), 7.2195),
        (Lab(l: 50, a: -0.001, b: 2.49), Lab(l: 50, a: 0.0009, b: -2.49), 4.8045),
        (Lab(l: 50, a: -0.001, b: 2.49), Lab(l: 50, a: 0.0010, b: -2.49), 4.8045),
        (Lab(l: 50, a: -0.001, b: 2.49), Lab(l: 50, a: 0.0011, b: -2.49), 4.7461),
        (Lab(l: 50, a: 2.5, b: 0), Lab(l: 50, a: 0, b: -2.5), 4.3065),
        (Lab(l: 50, a: 2.5, b: 0), Lab(l: 73, a: 25, b: -18), 27.1492),
        (Lab(l: 50, a: 2.5, b: 0), Lab(l: 61, a: -5, b: 29), 22.8977),
        (Lab(l: 50, a: 2.5, b: 0), Lab(l: 56, a: -27, b: -3), 31.9030),
        (Lab(l: 50, a: 2.5, b: 0), Lab(l: 58, a: 24, b: 15), 19.4535),
        (Lab(l: 50, a: 2.5, b: 0), Lab(l: 50, a: 3.1736, b: 0.5854), 1.0000),
        (Lab(l: 50, a: 2.5, b: 0), Lab(l: 50, a: 3.2972, b: 0), 1.0000),
        (Lab(l: 50, a: 2.5, b: 0), Lab(l: 50, a: 1.8634, b: 0.5757), 1.0000),
        (Lab(l: 50, a: 2.5, b: 0), Lab(l: 50, a: 3.2592, b: 0.3350), 1.0000),
        (Lab(l: 60.2574, a: -34.0099, b: 36.2677), Lab(l: 60.4626, a: -34.1751, b: 39.4387), 1.2644),
        (Lab(l: 63.0109, a: -31.0961, b: -5.8663), Lab(l: 62.8187, a: -29.7946, b: -4.0864), 1.2630),
        (Lab(l: 61.2901, a: 3.7196, b: -5.3901), Lab(l: 61.4292, a: 2.2480, b: -4.9620), 1.8731),
        (Lab(l: 35.0831, a: -44.1164, b: 3.7933), Lab(l: 35.0232, a: -40.0716, b: 1.5901), 1.8645),
        (Lab(l: 22.7233, a: 20.0904, b: -46.6940), Lab(l: 23.0331, a: 14.9730, b: -42.5619), 2.0373),
        (Lab(l: 36.4612, a: 47.8580, b: 18.3852), Lab(l: 36.2715, a: 50.5065, b: 21.2231), 1.4146),
        (Lab(l: 90.8027, a: -2.0831, b: 1.4410), Lab(l: 91.1528, a: -1.6435, b: 0.0447), 1.4441),
        (Lab(l: 90.9257, a: -0.5406, b: -0.9208), Lab(l: 88.6381, a: -0.8985, b: -0.7239), 1.5381),
        (Lab(l: 6.7747, a: -0.2908, b: -2.4247), Lab(l: 5.8714, a: -0.0985, b: -2.2286), 0.6377),
        (Lab(l: 2.0776, a: 0.0795, b: -1.1350), Lab(l: 0.9033, a: -0.0636, b: -0.5514), 0.9082),
    ]

    static func deltaE2000Sharma() -> Outcome {
        var worst = 0.0, bad: [Int] = []
        for (i, pair) in sharma.enumerated() {
            let d = abs(DeltaE.ciede2000(pair.0, pair.1) - pair.2)
            worst = max(worst, d)
            if d > 5e-5 { bad.append(i + 1) }
        }
        return Outcome(name: "ΔE2000 matches Sharma et al. (34 pairs, 4 decimals)", passed: bad.isEmpty,
                       detail: bad.isEmpty ? "largest difference \(String(format: "%.1e", worst))" : "pairs \(bad) differ")
    }

    // MARK: ColorSync

    private static func labOf(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Lab? { DeltaE.lab(of: Raster(width: 1, height: 1, red: r, green: g, blue: b))?.first }

    /// sRGB primaries in D50 Lab as published by Lindbloom (Bradford-adapted sRGB): red 54.29 80.80 69.89; white 100 0 0;
    /// the 50 % grey (code 128) is 53.585 on any white point.
    static func colorSyncLab() -> Outcome {
        guard let white = labOf(255, 255, 255), let black = labOf(0, 0, 0), let red = labOf(255, 0, 0), let grey = labOf(128, 128, 128) else {
            return Outcome(name: "ColorSync sRGB → Lab D50", passed: false, detail: "the transform could not be built")
        }
        let reference = [("white", white, Lab(l: 100, a: 0, b: 0)), ("black", black, Lab(l: 0, a: 0, b: 0)),
                         ("red", red, Lab(l: 54.29, a: 80.80, b: 69.89)), ("grey", grey, Lab(l: 53.585, a: 0, b: 0))]
        var failures: [String] = []
        for (name, got, want) in reference where DeltaE.ciede2000(got, want) > 0.5 {
            failures.append("\(name) \(String(format: "%.2f %.2f %.2f", got.l, got.a, got.b))")
        }
        return Outcome(name: "ColorSync sRGB → Lab D50 matches published values", passed: failures.isEmpty,
                       detail: failures.isEmpty ? "white, black, red, grey within ΔE00 0.5" : failures.joined(separator: "; "))
    }

    /// Whole-picture path: identical pictures give 0, and pure white against black gives the full L* range (ΔE00 100).
    static func colorSyncDeltaE() -> Outcome {
        let white = Raster(width: 4, height: 4, red: 255, green: 255, blue: 255), black = Raster(width: 4, height: 4, red: 0, green: 0, blue: 0)
        guard let same = DeltaE.map(white, white), let wb = DeltaE.map(white, black) else { return Outcome(name: "ΔE00 over pictures", passed: false, detail: "no Lab") }
        let full = DeltaE.summarise(wb).mean
        return Outcome(name: "ΔE00 over pictures: identical = 0, white/black = 100", passed: DeltaE.summarise(same).max == 0 && near(full, 100, 0.01),
                       detail: "white/black \(String(format: "%.3f", full))")
    }

    // MARK: SSIM

    /// The 11-tap window sums to 1, is symmetric, and its centre is exp(0) / sum for sigma 1.5.
    static func gaussianWindow() -> Outcome {
        let k = SSIM.kernel
        let sum = k.reduce(0, +)
        let symmetric = (0..<k.count).allSatisfy { near(Double(k[$0]), Double(k[k.count - 1 - $0]), 1e-9) }
        // Wang's fspecial('gaussian', 11, 1.5): centre tap 0.2662 in one dimension (0.0709 in 2-D is its square).
        return Outcome(name: "SSIM window is the 11 x 11 Gaussian, sigma 1.5", passed: near(Double(sum), 1, 1e-6) && symmetric && near(Double(k[5]), 0.2662, 1e-3),
                       detail: "centre \(String(format: "%.4f", k[5]))")
    }

    /// Constant pictures a and b: variances and covariance are zero, so SSIM = (2ab + C1) / (a² + b² + C1) exactly.
    static func ssimConstants() -> Outcome {
        let c1 = pow(Double(0.01) * 255, 2)
        var worst = 0.0
        for (a, b) in [(0.0, 255.0), (100.0, 120.0), (30.0, 30.0), (200.0, 10.0)] {
            let x = SSIM.Plane(width: 24, height: 24, values: [Double](repeating: Double(a), count: 576))
            let y = SSIM.Plane(width: 24, height: 24, values: [Double](repeating: Double(b), count: 576))
            guard let r = SSIM.compare(x, y) else { return Outcome(name: "SSIM of constant pictures", passed: false, detail: "no result") }
            worst = max(worst, abs(r.mean - (2 * a * b + c1) / (a * a + b * b + c1)))
        }
        return Outcome(name: "SSIM of constant pictures = (2ab + C1) / (a² + b² + C1)", passed: worst < 1e-5, detail: "largest difference \(String(format: "%.1e", worst))")
    }

    private static func noise(width: Int, height: Int, seed: UInt64 = 7) -> SSIM.Plane {
        var state = seed
        let values = (0..<width * height).map { _ -> Double in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 256)
        }
        return SSIM.Plane(width: width, height: height, values: values)
    }

    static func ssimIdentity() -> Outcome {
        let x = noise(width: 64, height: 64)
        guard let r = SSIM.compare(x, x) else { return Outcome(name: "SSIM(x, x) = 1", passed: false, detail: "no result") }
        return Outcome(name: "SSIM(x, x) = 1 on noise", passed: near(r.mean, 1, 1e-5), detail: "\(r.mean)")
    }

    /// Noise against independent noise is near 0; a picture against a copy with every value halved keeps structure
    /// (cs = 0.8) and keeps a 0.8 luminance term, so SSIM = 0.64 for large sigma, well between the two.
    static func ssimDetectsChange() -> Outcome {
        let x = noise(width: 64, height: 64), y = noise(width: 64, height: 64, seed: 99)
        let halved = SSIM.Plane(width: 64, height: 64, values: x.values.map { $0 / 2 })
        guard let unrelated = SSIM.compare(x, y), let half = SSIM.compare(x, halved) else { return Outcome(name: "SSIM orders changes", passed: false, detail: "no result") }
        let ok = abs(unrelated.mean) < 0.1 && half.mean > 0.6 && half.mean < 0.85
        return Outcome(name: "SSIM: unrelated noise ≈ 0, halved contrast ≈ 0.64", passed: ok, detail: "unrelated \(String(format: "%.3f", unrelated.mean)), halved \(String(format: "%.3f", half.mean))")
    }

    /// Constant pictures: every contrast-structure term is 1, so MS-SSIM = l₅^w₅ with the luminance term of scale 5.
    static func msSSIMConstants() -> Outcome {
        let c1 = pow(Double(0.01) * 255, 2), a = 100.0, b = 140.0
        let size = 192
        let x = SSIM.Plane(width: size, height: size, values: [Double](repeating: Double(a), count: size * size))
        let y = SSIM.Plane(width: size, height: size, values: [Double](repeating: Double(b), count: size * size))
        let identical = noise(width: size, height: size)
        guard let ms = SSIM.multiScale(x, y), let one = SSIM.multiScale(identical, identical) else { return Outcome(name: "MS-SSIM", passed: false, detail: "no result") }
        let want = pow((2 * a * b + c1) / (a * a + b * b + c1), SSIM.msWeights[4])
        let weightsOK = near(SSIM.msWeights.reduce(0, +), 1, 1e-4)
        return Outcome(name: "MS-SSIM: weights of Wang 2003 sum to 1; constants = l^0.1333; identical = 1", passed: near(ms, want, 1e-5) && near(one, 1, 1e-4) && weightsOK,
                       detail: "constants \(ms) vs \(want), identical \(one)")
    }

    // MARK: PSNR

    /// An error of one code value on every sample of an 8-bit picture is 20·log10(255) = 48.1308 dB; of 16, 24.0484 dB.
    static func psnr() -> Outcome {
        let base = Raster(width: 8, height: 8, red: 100, green: 100, blue: 100)
        let plus1 = Raster(width: 8, height: 8, red: 101, green: 101, blue: 101), plus16 = Raster(width: 8, height: 8, red: 116, green: 116, blue: 116)
        guard let a = PSNR.compare(base, plus1), let b = PSNR.compare(base, plus16), let same = PSNR.compare(base, base) else { return Outcome(name: "PSNR", passed: false, detail: "no result") }
        return Outcome(name: "PSNR: ±1 = 48.1308 dB, ±16 = 24.0484 dB, identical capped", passed: near(a, 48.1308, 1e-3) && near(b, 24.0484, 1e-3) && same == PSNR.identical,
                       detail: "\(String(format: "%.4f %.4f", a, b))")
    }

    // MARK: THD+N

    /// A full-scale sine quantised to N bits has SNR = 6.02 N + 1.76 dB, so THD+N = -(6.02 N + 1.76): -98.09 dB at 16 bits,
    /// -146.24 dB at 24 (Kester, "Taking the Mystery out of the Infamous Formula SNR = 6.02N + 1.76 dB", Analog Devices
    /// MT-001). The 997 Hz tone of AES17 is incommensurate with 48 kHz, so the quantisation error is not periodic.
    static func thdQuantisation() -> Outcome {
        let s16 = AudioMetrics.sine(frequency: 997, sampleRate: 48000, seconds: 4, amplitude: 1, bits: 16)
        let s24 = AudioMetrics.sine(frequency: 997, sampleRate: 48000, seconds: 4, amplitude: 1, bits: 24)
        guard let d16 = AudioMetrics.thdPlusN(s16, frequency: 997), let d24 = AudioMetrics.thdPlusN(s24, frequency: 997) else { return Outcome(name: "THD+N", passed: false, detail: "no result") }
        return Outcome(name: "THD+N of a quantised full-scale sine = -(6.02 N + 1.76) dB", passed: near(d16, -98.09, 0.5) && near(d24, -146.24, 1.0),
                       detail: "16-bit \(String(format: "%.2f", d16)), 24-bit \(String(format: "%.2f", d24))")
    }

    /// A 1 kHz sine with a 3rd harmonic at 1 % (-40 dB), and one at 0.001 % (-100 dB).
    static func thdHarmonic() -> Outcome {
        let loud = AudioMetrics.sine(frequency: 1000, sampleRate: 96000, seconds: 1, amplitude: 0.5, harmonics: [3: 0.01])
        let quiet = AudioMetrics.sine(frequency: 1000, sampleRate: 96000, seconds: 1, amplitude: 0.5, harmonics: [3: 0.00001])
        guard let a = AudioMetrics.thdPlusN(loud, frequency: 1000), let b = AudioMetrics.thdPlusN(quiet, frequency: 1000) else { return Outcome(name: "THD+N harmonic", passed: false, detail: "no result") }
        return Outcome(name: "THD+N of a sine with a 1 % / 0.001 % third harmonic = -40 / -100 dB", passed: near(a, -40, 0.01) && near(b, -100, 0.05),
                       detail: "\(String(format: "%.3f %.3f", a, b))")
    }

    // MARK: Loudness

    static func loudnessParser() -> Outcome {
        let log = """
        [Parsed_ebur128_0 @ 0x1] Summary:

          Integrated loudness:
            I:         -23.0 LUFS
            Threshold: -33.0 LUFS

          Loudness range:
            LRA:         0.0 LU
            LRA low:   -23.0 LUFS

          True peak:
            Peak:      -23.0 dBFS
        """
        let m = Loudness.parse(log)
        return Outcome(name: "ebur128 summary parser", passed: m == Loudness.Measurement(integrated: -23, range: 0, truePeak: -23), detail: "\(String(describing: m))")
    }

    /// EBU Tech 3341 test case 1: a stereo 1 kHz sine at -23 dBFS reads -23.0 LUFS (+-0.1 LU); at -33 dBFS, -33.0.
    static func loudnessEBUTestTone() -> Outcome {
        let name = "ffmpeg ebur128: EBU Tech 3341 tone, -23 dBFS stereo = -23.0 LUFS"
        guard let ffmpeg = FFmpegLocator.find() else { return Outcome(name: name, passed: true, skipped: true, detail: "ffmpeg not found (scripts/tools.sh fetch)") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("qbench-loudness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var results: [Double] = []
            for level in [-23.0, -33.0] {
                let wav = folder.appendingPathComponent("tone\(Int(-level)).wav")
                try AudioMetrics.writeWAV(AudioMetrics.sine(frequency: 1000, sampleRate: 48000, seconds: 20, amplitude: pow(10, level / 20), bits: 16), channels: 2, to: wav)
                guard let m = Loudness.measure(wav, ffmpeg: ffmpeg) else { return Outcome(name: name, passed: false, detail: "no measurement") }
                results.append(m.integrated)
            }
            return Outcome(name: name, passed: near(results[0], -23, 0.1) && near(results[1], -33, 0.1), detail: results.map { String(format: "%.2f", $0) }.joined(separator: ", "))
        } catch { return Outcome(name: name, passed: false, detail: "\(error)") }
    }

    // MARK: Hashing

    /// FIPS 180-2 appendix B test vectors.
    static func sha256Vectors() -> Outcome {
        let vectors: [(String, String)] = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
            (String(repeating: "a", count: 1_000_000), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"),
        ]
        let bad = vectors.filter { Manifest.sha256(Data($0.0.utf8)) != $0.1 }
        return Outcome(name: "SHA-256 matches the FIPS 180-2 vectors", passed: bad.isEmpty, detail: "\(vectors.count) vectors")
    }

    /// A manifest sees content, names, empty folders and links, and its digest changes with any of them.
    static func manifestRoundTrip() -> Outcome {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("qbench-manifest-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        do {
            try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
            try Data("abc".utf8).write(to: root.appendingPathComponent("a.txt"))
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "a.txt")
            let before = Manifest.entries(of: root)
            let digest = Manifest.digest(before)
            let file = before.first { $0.path == "a.txt" }
            let shapeOK = before.map(\.path) == ["a.txt", "empty", "link"] && file?.sha256 == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
                && before.first { $0.path == "link" }?.symlinkTarget == "a.txt" && before.first { $0.path == "empty" }?.kind == .directory
            try Data("abd".utf8).write(to: root.appendingPathComponent("a.txt"))
            let after = Manifest.entries(of: root)
            let changed = Manifest.digest(after) != digest && Manifest.differences(before, after) == ["changed a.txt"]
            return Outcome(name: "manifest records files, empty folders, links; digest and diff see changes", passed: shapeOK && changed, detail: "\(before.count) entries")
        } catch { return Outcome(name: "manifest", passed: false, detail: "\(error)") }
    }

    // MARK: Regression memory

    /// A drop inside the noise band passes, a drop beyond it is flagged, an improvement ratchets the accepted value up.
    static func regressionBand() -> Outcome {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qbench-memory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var memory = RegressionMemory(url: url)
        memory.ratchet("case", [.ssim("ssim", 0.990, atLeast: 0.98), .deltaE("deltaE", 0.50, atMost: 1.0)])
        let inside = memory.regressions("case", [.ssim("ssim", 0.989, atLeast: 0.98), .deltaE("deltaE", 0.55, atMost: 1.0)])
        let beyond = memory.regressions("case", [.ssim("ssim", 0.986, atLeast: 0.98), .deltaE("deltaE", 0.70, atMost: 1.0)])
        memory.ratchet("case", [.ssim("ssim", 0.995, atLeast: 0.98)])
        let ratcheted = memory.regressions("case", [.ssim("ssim", 0.992, atLeast: 0.98)])
        memory.save()
        let reloaded = RegressionMemory(url: url).accepted("case")["ssim"]
        let ok = inside.isEmpty && beyond.count == 2 && ratcheted.count == 1 && reloaded == 0.995
        return Outcome(name: "regression memory: inside the noise band passes, beyond it fails, improvements ratchet", passed: ok,
                       detail: "inside \(inside.count), beyond \(beyond.count), after ratchet \(ratcheted.count)")
    }
}
