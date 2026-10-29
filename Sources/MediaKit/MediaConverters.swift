import Foundation
import SuperConverterCore

// MediaKit's converters (ARCHITECTURE §4, §6): one per engine id `format-matrix.json` names for this module — AVFoundation,
// FFmpeg, SoundFontReader. The matrix puts AVFoundation on the pairs Apple's frameworks can do and FFmpeg on the rest; inside a
// step the route is chosen again from what the file really holds (quality §5.1 "copy first"): stream copy → AVFoundation →
// FFmpeg, so an MP4 → MOV whose streams fit is a re-wrap, and an MP4 with Opus sound still converts.

/// The FFmpeg engine: every audio/video pair AVFoundation cannot do alone (formats §3.3), animations both ways, and slides or
/// animation frames (`ImageAsset`) to video.
struct FFmpegConverter: Converter {
    let tools: MediaTools
    var id: EngineID { .ffmpeg }

    var handles: [StepPattern] {
        [StepPattern(from: .anyFile, to: .formats(MediaRoutes.ffmpegTargets)),
         StepPattern(from: .model(.imageAsset), to: .formats(MediaRoutes.videoTargets))]
    }

    func availability() -> EngineAvailability { tools.availability }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        if context.isCancelled() { throw ConversionError.cancelled }
        guard case .format(let target) = step.to else { throw ConversionError.impossiblePair(reason: "A file format was expected here.") }
        switch input {
        case .file(let url):
            return try await MediaRun(tools: tools, context: context).ffmpeg(url, sourceFormat: Self.format(of: step, url: url), target: target)
        case .image(let asset):
            return try await MediaRun(tools: tools, context: context).frames(asset, target: target)
        default:
            throw ConversionError.impossiblePair(reason: "A video or a set of pictures was expected here.")
        }
    }

    static func format(of step: Step, url: URL) -> FormatID {
        if case .format(let f) = step.from { return f }
        return FormatID(url.pathExtension.lowercased())
    }
}

/// The AVFoundation engine (formats §3.1): AVAssetExportSession pass-through for re-wraps, AVAssetReader/Writer with
/// VideoToolbox and AudioToolbox for encodes; FFmpeg when a stream or an option is outside what Apple's frameworks do.
struct AVFoundationConverter: Converter {
    let tools: MediaTools
    var id: EngineID { .avFoundation }

    var handles: [StepPattern] { [StepPattern(from: .anyFile, to: .formats(MediaRoutes.avFoundationTargets))] }

    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        if context.isCancelled() { throw ConversionError.cancelled }
        guard case .file(let url) = input, case .format(let target) = step.to else {
            throw ConversionError.impossiblePair(reason: "A file was expected here.")
        }
        return try await MediaRun(tools: tools, context: context).avFoundation(url, sourceFormat: FFmpegConverter.format(of: step, url: url), target: target)
    }
}

/// The targets each engine writes (the matrix's steps for this module; the self-test checks every one is handled).
enum MediaRoutes {
    static let videoTargets: Set<FormatID> = Set(MediaContainer.table.values.filter(\.isVideo).map(\.format))
    static let audioTargets: Set<FormatID> = Set(MediaContainer.table.values.filter { !$0.isVideo }.map(\.format))
    static let animationTargets: Set<FormatID> = ["gif", "webp"]
    static let ffmpegTargets = videoTargets.union(audioTargets).union(animationTargets)
    /// What AVFoundation writes (formats §3.1): the QuickTime family and the audio files AudioToolbox writes.
    static let avFoundationTargets: Set<FormatID> = ["mov", "mp4", "m4v", "3gp", "3gpp", "3g2", "aac", "aif", "aifc", "aiff", "caf", "flac",
                                                     "m4a", "m4b", "wav"]
}
