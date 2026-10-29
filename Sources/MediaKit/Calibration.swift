import Foundation

/// CloudConvert's `crf` (the x264 scale, 0–51, lower = better) → VideoToolbox's constant quality
/// (`kVTCompressionPropertyKey_Quality`, 0…1), quality §5.1.
///
/// How the table was measured (WP-M). The spec asks for the VideoToolbox quality that matches the VMAF of x264 `-crf N
/// -preset medium` from a dev-only GPL FFmpeg. Super Converter's workers may not run a GPL build even as a test tool, and
/// libvmaf only ships in such builds here, so the table is measured with the quality bench's own SSIM and PSNR
/// (`SuperConverterQualityBench/Metrics/SSIM.swift`, validated against published values) on the bench's synthetic clips
/// (screen recording, smooth motion, animation, film grain, low light, fine detail; `mediakit.vt-calibration`):
///   1. crf 20 is anchored where VideoToolbox reaches a mean luma SSIM of 0.985 on a clip (the region where VMAF ≈ 95, the
///      spec's target for the default).
///   2. Every other crf N asks for the PSNR at that anchor minus (N − 20) dB: in H.264 and HEVC the quantiser step doubles
///      every 6 QP, which quarters the MSE (−6.02 dB per 6 steps), and x264's CRF moves its QP one step per CRF unit.
///   3. Each clip's VideoToolbox quality for that PSNR is read off its measured quality → PSNR curve; the table holds the
///      mean over the clips, rounded to 0.01, made monotonic and limited to the range VideoToolbox accepts.
/// The bench case re-measures the curve and fails when a shipped value drifts by more than 0.05 (an encoder change in a
/// new macOS). The measuring code is the bench case; it does not ship.
enum VideoToolboxCalibration {
    /// Quality for crf 0…51 (index = crf), H.264.
    static let h264: [Double] = table(anchors: [
        14: 0.74, 17: 0.68, 20: 0.62, 23: 0.55, 26: 0.48, 29: 0.41, 32: 0.34, 35: 0.27,
    ])
    /// Quality for crf 0…51, HEVC (its quantiser runs on the same QP scale; the encoder needs slightly more quality for
    /// the same PSNR at low rates).
    static let hevc: [Double] = table(anchors: [
        14: 0.75, 17: 0.69, 20: 0.63, 23: 0.56, 26: 0.49, 29: 0.42, 32: 0.35, 35: 0.28,
    ])

    /// The measured crf values (quality §5.1: N = 14…35, every third step).
    static let measuredCRFs = [14, 17, 20, 23, 26, 29, 32, 35]

    static func quality(crf: Int, hevc: Bool) -> Double {
        let values = hevc ? Self.hevc : Self.h264
        return values[min(max(crf, 0), 51)]
    }

    /// Linear between the measured anchors and beyond them along the end segments, limited to 0.05…1 and monotonic.
    static func table(anchors: [Int: Double]) -> [Double] {
        let keys = anchors.keys.sorted()
        func value(_ crf: Int) -> Double {
            let (a, b): (Int, Int)
            if crf <= keys[0] { (a, b) = (keys[0], keys[1]) }
            else if crf >= keys[keys.count - 1] { (a, b) = (keys[keys.count - 2], keys[keys.count - 1]) }
            else { let i = keys.lastIndex { $0 <= crf }!; (a, b) = (keys[i], keys[i + 1]) }
            let t = Double(crf - a) / Double(b - a)
            return anchors[a]! + t * (anchors[b]! - anchors[a]!)
        }
        var out: [Double] = []
        for crf in 0...51 {
            let v = min(max((value(crf) * 100).rounded() / 100, 0.05), 1)
            out.append(min(v, out.last ?? 1))
        }
        return out
    }
}
