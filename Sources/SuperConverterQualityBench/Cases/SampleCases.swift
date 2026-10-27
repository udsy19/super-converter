import Foundation
import SuperConverterCore

/// One sample case per metric family, run against `FakeEngines`: they prove the harness, the metrics and the report work end to
/// end for categories whose real engines belong to other kits (images, audio, archives). A real kit adds its own cases.
enum SampleCases {
    static let all: [BenchCase] = [
        // Lossless re-encode: the decoded pixels are identical (quality §2.8 "Lossless round trips").
        BenchCase(id: "sample.image-lossless", category: .image, fixture: "generated/colorchecker-24.png", target: "tiff", route: [Step(.imageIO, "png", "tiff")], useFakes: true, checks: [
            .producesFormat("tiff"),
            .imageMatches(reference: { $0.source }, ssimAtLeast: 0.9999, meanDeltaEAtMost: 0.01, p95DeltaEAtMost: 0.01, psnrAtLeast: 90),
        ]),
        // Lossy defaults (quality §2.8 "Photo lossy defaults"): SSIM >= 0.985, mean ΔE00 <= 1.5.
        BenchCase(id: "sample.image-jpeg", category: .image, fixture: "generated/gradient-256.png", target: "jpg", route: [Step(.imageIO, "png", "jpg")], useFakes: true, checks: [
            .producesFormat("jpg"),
            .imageMatches(reference: { $0.source }, ssimAtLeast: 0.985, meanDeltaEAtMost: 1.5, p95DeltaEAtMost: 3.0, psnrAtLeast: 35),
        ]),
        // 997 Hz tone through an audio "conversion" keeps its THD+N (quality §5.3 "Resampling" bound: -100 dB for resamplers;
        // a 16-bit file at -1 dBFS cannot be cleaner than its own quantisation, about -97 dB).
        BenchCase(id: "sample.audio-thd", category: .audio, fixture: "generated/tone-997-48k.wav", target: "wav", route: [Step(.avFoundation, "wav", "wav")], useFakes: true, checks: [
            .thdPlusN(frequency: 997, atMost: -95),
        ]),
        // EBU Tech 3341 test case 1: -23 dBFS stereo sine reads -23.0 LUFS (quality §5.3 "Loudness option": +-0.5 LU).
        BenchCase(id: "sample.audio-loudness", category: .audio, fixture: "generated/tone-1k-minus23-stereo.wav", target: "wav", route: [Step(.avFoundation, "wav", "wav")], useFakes: true, checks: [
            .loudness(integrated: -23, tolerance: 0.5, truePeakAtMost: -22.5),
        ]),
        // Archive extraction: the manifest (paths, sizes, SHA-256, empty folders) equals an independent extraction's (quality §8).
        BenchCase(id: "sample.archive-manifest", category: .archive, fixture: "generated/sample.docx", target: "zip", route: [Step(.libarchive, "zip", "zip")], useFakes: true, checks: [
            .manifestMatchesExtraction(),
        ]),
    ]
}
