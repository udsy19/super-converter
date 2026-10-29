import Foundation
import SuperConverterCore

/// VectorizeKit: raster to SVG tracing (vtracer port) (ARCHITECTURE §3). An engine: it carries no app policy and registers its converters in `install()`.
public enum VectorizeKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {
        Services.converters.register(TraceConverter())
    }
}

/// `VectorizeKit`: ImageAsset → SVG file in the work folder, with the O-TRACE options.
struct TraceConverter: Converter {
    let id = EngineID.vectorizeKit
    let handles = [StepPattern(from: .model(.imageAsset), to: .formats(["svg"]))]

    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        if context.isCancelled() { throw ConversionError.cancelled }
        guard case .image(let asset) = input else { throw ConversionError.impossiblePair(reason: "The picture wasn’t handed over.") }
        let report = context.report
        let result = try Vectorizer.trace(asset, settings: TraceSettings(context.options),
                                          progress: { report(StepProgress(fraction: $0, unit: "Tracing")) }, isCancelled: context.isCancelled)
        let stem = context.source.deletingPathExtension().lastPathComponent
        var url = context.workFolder.appendingPathComponent(stem).appendingPathExtension("svg")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = context.workFolder.appendingPathComponent("\(stem) \(n)").appendingPathExtension("svg")
            n += 1
        }
        do { try result.svg.write(to: url, options: .atomic) } catch { throw ConversionError.folderNotWritable(name: context.workFolder.lastPathComponent) }
        let notes = asset.frames.count > 1 ? [LossNote(.animationDropped, detail: "Only the first frame was traced")] : []
        return StepOutput(.file(url), lossNotes: notes)
    }
}
