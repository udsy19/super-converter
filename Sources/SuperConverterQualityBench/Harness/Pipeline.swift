import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore

/// One conversion through the same planner and queue the app and `sconv` use (no UI).
@MainActor
enum Pipeline {
    enum Outcome {
        case converted(ConversionResult)
        /// The pair cannot run here (not offered, engine unavailable, helper not installed): not a failure, not a pass.
        case skipped(String)
        case failed(String)
    }

    struct Run {
        var sourceFormat: FormatID?
        var outcome: Outcome
        var seconds: Double
    }

    static func sourceFormat(of file: URL) -> FormatID? {
        (try? Services.sniffer.sniff(file))?.format ?? FormatCatalog.format(forFileName: file.lastPathComponent)?.id
    }

    /// Runs `steps` through the registered converters, one after the other, and writes the last value into `folder`.
    static func convertSteps(_ source: URL, steps: [Step], target: FormatID, options: OptionValues = OptionValues(),
                             into folder: URL) async -> Run {
        let started = Date()
        func done(_ format: FormatID?, _ outcome: Outcome) -> Run { Run(sourceFormat: format, outcome: outcome, seconds: Date().timeIntervalSince(started)) }
        guard let format = sourceFormat(of: source) else { return done(nil, .failed("the sniffer does not know \(source.lastPathComponent)")) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var value = StepValue.file(source)
        var notes: [LossNote] = [], warnings: [String] = []
        for (index, step) in steps.enumerated() {
            guard let converter = Services.converters.converter(for: step.engine), converter.handles(step) else { return done(format, .skipped("no converter handles \(step)")) }
            if case .unavailable(let why) = converter.availability() { return done(format, .skipped("\(step.engine.rawValue) is unavailable: \(why)")) }
            if case .needsHelper(let helper) = converter.availability() { return done(format, .skipped("needs \(helper.rawValue)")) }
            let context = StepContext(workFolder: folder, source: source, sourceFormat: format, targetFormat: target, options: options, isFinalStep: index == steps.count - 1)
            do {
                let output = try await converter.run(step, input: value, context: context)
                value = output.value; notes += output.lossNotes; warnings += output.warnings
            } catch { return done(format, .failed("\(step): \(error)")) }
        }
        do { return done(format, .converted(ConversionResult(outputs: try write(value, into: folder, name: source.deletingPathExtension().lastPathComponent), lossNotes: notes, warnings: warnings))) }
        catch { return done(format, .failed("\(error)")) }
    }

    /// A file stays where it is; an `ImageAsset` becomes one PNG per frame.
    private static func write(_ value: StepValue, into folder: URL, name: String) throws -> [URL] {
        switch value {
        case .file(let url): return [url]
        case .image(let asset):
            return try asset.frames.enumerated().map { index, frame in
                let url = folder.appendingPathComponent(asset.frames.count == 1 ? "\(name).png" : "\(name)-\(index + 1).png")
                switch frame.pixels {
                case .file(let source): try FileManager.default.copyItem(at: source, to: url)
                case .rgba8(let data, let bytesPerRow):
                    guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
                          let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space,
                                              bitmapInfo: CGBitmapInfo(rawValue: frame.hasAlpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue),
                                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw CheckFailure("a frame cannot be written") }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { throw CheckFailure("a frame cannot be written") }
                case .rgbaHalf: throw CheckFailure("half-float frames are not written by the bench")
                }
                return url
            }
        default: throw CheckFailure("the route ends in a model the bench cannot write")
        }
    }

    static func convert(_ source: URL, to target: FormatID, options: OptionValues = OptionValues(), look: DocumentLook? = nil,
                        into folder: URL, timeout: TimeInterval = 180) async -> Run {
        let started = Date()
        func done(_ format: FormatID?, _ outcome: Outcome) -> Run { Run(sourceFormat: format, outcome: outcome, seconds: Date().timeIntervalSince(started)) }
        guard let format = sourceFormat(of: source) else { return done(nil, .failed("the sniffer does not know \(source.lastPathComponent)")) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let request = ConversionRequest(source: source, sourceFormat: format, target: target, options: options, look: look)
        let plan = Services.planner.plan(for: request)
        switch plan.choice {
        case .unavailable(let reason): return done(format, .skipped("\(format.pill) → \(target.pill) is not available: \(reason)"))
        case .helper(_, _, let missing) where !missing.isEmpty:
            return done(format, .skipped("needs \(missing.map(\.rawValue).joined(separator: ", ")) (not installed)"))
        default: break
        }
        let events = Services.queue.events
        let job = Services.queue.enqueue(plan, into: .folder(folder))
        let watchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if !Task.isCancelled { Services.queue.cancel(job) }
        }
        defer { watchdog.cancel() }
        for await event in events {
            switch event {
            case .finished(let id, let result) where id == job:
                return done(format, .converted(result))
            case .failed(let id, let error) where id == job:
                if case .helperMissing(let helper) = error { return done(format, .skipped("needs \(helper.rawValue) (not installed)")) }
                return done(format, .failed(Strings.problem(error).message + " [\(error)]"))
            case .cancelled(let id) where id == job:
                return done(format, .failed("timed out after \(Int(timeout)) s"))
            default: break
            }
        }
        return done(format, .failed("the queue closed"))
    }
}
