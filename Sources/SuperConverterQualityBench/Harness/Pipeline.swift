import Foundation
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
