import Foundation
import os
import SuperConverterCore

/// A cooperative cancellation flag shared by the queue, the runner and the engines' `isCancelled`.
final class CancelFlag: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}

/// Turns a step's progress into the job's: the fraction across all steps, the unit, and a time estimate. Repeats are dropped.
final class ProgressMeter: @unchecked Sendable {
    private struct State { var last: JobProgress?; var stepIndex = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let stepCount: Int
    private let started = Date()
    private let emit: @Sendable (JobProgress) -> Void

    init(steps: Int, emit: @escaping @Sendable (JobProgress) -> Void) { stepCount = max(steps, 1); self.emit = emit }

    func beginStep(_ index: Int) { state.withLock { $0.stepIndex = index } }

    func report(_ step: StepProgress) {
        let progress: JobProgress? = state.withLock { state in
            var fraction: Double?
            if let f = step.fraction { fraction = min(max((Double(state.stepIndex) + min(max(f, 0), 1)) / Double(stepCount), 0), 1) }
            var left: Double?
            let elapsed = Date().timeIntervalSince(started)
            if let fraction, fraction > 0.02, elapsed > 1 { left = elapsed * (1 - fraction) / fraction }
            let next = JobProgress(fraction: fraction.map { ($0 * 1000).rounded() / 1000 }, unit: step.unit, secondsLeft: left.map { $0.rounded() })
            if next.fraction == state.last?.fraction && next.unit == state.last?.unit { return nil }
            state.last = next
            return next
        }
        if let progress { emit(progress) }
    }
}

/// How a job ended.
enum JobOutcome: Sendable {
    case finished(ConversionResult)
    case failed(ConversionError)
    case cancelled
}

/// Runs one planned route: a work folder, the steps in order (a model value or a file between them), then the result is
/// moved into place by the output policy. Partial output never leaves the work folder; cancelling deletes it.
struct JobRunner: Sendable {
    let id: JobID
    let plan: ConversionPlan
    let place: OutputPlace
    let steps: [(step: Step, converter: any Converter)]
    /// Main-actor isolated; only ever called through `MainActor.run`.
    nonisolated(unsafe) let output: OutputPolicy
    let cancel: CancelFlag
    let meter: ProgressMeter

    func run() async -> JobOutcome {
        let work = WorkFolder(id)
        defer { work.remove() }
        do {
            return .finished(try await execute(in: work.url))
        } catch {
            if cancel.isCancelled || error is CancellationError || (error as? ConversionError) == .cancelled { return .cancelled }
            if let conversionError = error as? ConversionError { return .failed(conversionError) }
            return .failed(.failed((error as NSError).localizedDescription))
        }
    }

    private func execute(in work: URL) async throws -> ConversionResult {
        let request = plan.request
        guard FileManager.default.fileExists(atPath: request.source.path) else {
            throw ConversionError.failed("Super Converter can’t find \(Strings.quoted(request.source.lastPathComponent))")
        }
        let inputBytes = Self.size(of: request.source)

        // Fail early, before any work: the place must be writable and the volume must have room.
        let early = try await MainActor.run { try output.target(for: request.source, format: request.target, place: place, multipleFiles: false) }
        let folder = early.url.deletingLastPathComponent()
        if SuperConverterPaths.freeSpace(at: folder) < inputBytes {
            throw ConversionError.notEnoughSpace(volume: OutputRules.volumeName(of: folder), needed: inputBytes - SuperConverterPaths.freeSpace(at: folder))
        }

        var value = StepValue.file(request.source)
        var lossNotes: [LossNote] = []
        var warnings: [String] = []
        for (index, entry) in steps.enumerated() {
            try checkCancelled()
            meter.beginStep(index)
            let context = StepContext(workFolder: work, source: request.source, sourceFormat: request.sourceFormat,
                                      targetFormat: request.target, options: request.options, look: request.look,
                                      isFinalStep: index == steps.count - 1,
                                      report: { [meter] in meter.report($0) },
                                      isCancelled: { [cancel] in cancel.isCancelled })
            let produced = try await entry.converter.run(entry.step, input: value, context: context)
            for note in produced.lossNotes where !lossNotes.contains(note) { lossNotes.append(note) }
            warnings += produced.warnings.filter { !warnings.contains($0) }
            value = produced.value
        }
        try checkCancelled()

        guard case .file(let produced) = value else { throw ConversionError.failed("The last step didn’t produce a file") }
        let files = try Self.collect(produced, work: work)
        guard !files.isEmpty else { throw ConversionError.failed("Nothing was produced") }
        let outputBytes = files.reduce(0) { $0 + Self.size(of: $1) }

        let multiple = files.count > 1
        let placed = try await MainActor.run {
            let target = try output.target(for: request.source, format: request.target, place: place, multipleFiles: multiple)
            return try output.place(files, for: request.source, into: target)
        }
        return ConversionResult(outputs: placed, lossNotes: lossNotes, warnings: warnings, inputBytes: inputBytes, outputBytes: outputBytes)
    }

    private func checkCancelled() throws {
        if cancel.isCancelled || Task.isCancelled { throw ConversionError.cancelled }
    }

    /// The files a final step produced: the file itself, or the items of the folder it made (several files). A file
    /// outside the work folder is copied in first, so the move below never takes something the job doesn’t own.
    private static func collect(_ produced: URL, work: URL) throws -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: produced.path, isDirectory: &isDirectory) else {
            throw ConversionError.failed("The converted file is missing")
        }
        let owned = produced.standardizedFileURL.path.hasPrefix(work.standardizedFileURL.path + "/")
        var url = produced
        if !owned {
            url = work.appendingPathComponent("copy-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            let copy = url.appendingPathComponent(produced.lastPathComponent)
            try fileManager.copyItem(at: produced, to: copy)
            return isDirectory.boolValue ? try items(of: copy) : [copy]
        }
        return isDirectory.boolValue ? try items(of: url) : [url]
    }

    private static func items(of folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Bytes of a file, or of everything under a folder.
    static func size(of url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue { return ((try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0 }
        var total: Int64 = 0
        for case let child as URL in fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) ?? NSEnumerator() {
            total += Int64((try? child.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
