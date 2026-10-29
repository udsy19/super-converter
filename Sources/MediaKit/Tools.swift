import Foundation
import SuperConverterCore

/// The bundled LGPL `ffmpeg` and `ffprobe` (formats §3.3), always through HelperKit's runner (`Services.tools`, ARCHITECTURE
/// §4): MediaKit never starts a process itself and never looks for a system FFmpeg (Homebrew's is a GPL build).
struct MediaTools: Sendable {
    let runner: (any ToolRunning)?

    var availability: EngineAvailability {
        guard let runner else { return .unavailable("The video tools aren’t set up in this copy of Super Converter.") }
        for tool in [BundledTool.ffmpeg, .ffprobe] where runner.location(of: tool) == nil {
            return .unavailable("This copy of Super Converter is missing its \(tool.rawValue) tool. Reinstall the app.")
        }
        return .available
    }

    private func require() throws -> any ToolRunning {
        if case .unavailable(let why) = availability { throw ConversionError.failed(why) }
        return runner!
    }

    /// One FFmpeg encode. `arguments` are everything between the global flags and the output (inputs, maps, filters,
    /// codecs); the output is written as `format` to a hidden partial file that becomes `output` only when FFmpeg finished
    /// and the result has streams. Progress is followed while it runs; a failure or a cancellation deletes the partial file
    /// (ARCHITECTURE §4).
    func encode(_ arguments: [String], format: String, to output: URL, duration: Double?, context: StepContext,
                unit: String? = nil) async throws {
        let runner = try require()
        let fm = FileManager.default
        let tag = UUID().uuidString.prefix(8)
        let partial = output.deletingLastPathComponent().appendingPathComponent(".partial-\(tag).\(output.pathExtension)")
        let progressFile = context.workFolder.appendingPathComponent(".progress-\(tag).txt")
        defer { try? fm.removeItem(at: progressFile) }
        let invocation = ToolInvocation(tool: .ffmpeg, arguments: ["-nostdin", "-hide_banner", "-nostats", "-loglevel", "error",
                                                                          "-progress", progressFile.path] + arguments + ["-f", format, "-y", partial.path],
                                               workFolder: context.workFolder)
        let run = Task { try await runner.run(invocation) }
        let follow = Task {
            for await progress in FFmpegProgress.follow(progressFile, duration: duration) {
                if context.isCancelled() { run.cancel(); break }
                context.report(StepProgress(fraction: progress.fraction, unit: unit.map { u in progress.unit.map { "\(u) · \($0)" } ?? u } ?? progress.unit))
            }
        }
        // The queue's flag can be set without the task being cancelled (and the progress file may never appear): watch it.
        let watch = Task {
            while !Task.isCancelled {
                if context.isCancelled() { run.cancel(); return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer { follow.cancel(); watch.cancel() }
        let result: HelperRunResult
        do {
            result = try await withTaskCancellationHandler { try await run.value } onCancel: { run.cancel() }
        } catch {
            try? fm.removeItem(at: partial)
            if context.isCancelled() || Task.isCancelled { throw ConversionError.cancelled }
            throw error
        }
        guard !context.isCancelled() else { try? fm.removeItem(at: partial); throw ConversionError.cancelled }
        guard result.exitCode == 0, fm.fileExists(atPath: partial.path) else {
            try? fm.removeItem(at: partial)
            throw ConversionError.failed(Self.reason(result.standardError, fallback: "FFmpeg couldn’t convert this file"))
        }
        if fm.fileExists(atPath: output.path) { try? fm.removeItem(at: output) }
        do { try fm.moveItem(at: partial, to: output) } catch {
            try? fm.removeItem(at: partial)
            throw ConversionError.folderNotWritable(name: context.workFolder.lastPathComponent)
        }
        context.report(StepProgress(fraction: 1, unit: unit))
    }

    /// An analysis pass (`idet`, `loudnorm`, `ebur128`): FFmpeg decodes to the null muxer and its log is returned.
    func analyse(_ arguments: [String], workFolder: URL, logLevel: String = "info") async throws -> String {
        let runner = try require()
        let result = try await runner.run(ToolInvocation(tool: .ffmpeg, arguments: ["-nostdin", "-hide_banner", "-nostats", "-loglevel", logLevel]
                                                               + arguments + ["-f", "null", "-"], workFolder: workFolder))
        guard result.exitCode == 0 else { throw ConversionError.failed(Self.reason(result.standardError, fallback: "FFmpeg couldn’t read this file")) }
        return result.standardError
    }

    /// A plain FFmpeg run whose arguments name their own outputs (several files at once).
    func run(_ arguments: [String], workFolder: URL) async throws {
        let runner = try require()
        let result = try await runner.run(ToolInvocation(tool: .ffmpeg, arguments: ["-nostdin", "-hide_banner", "-nostats", "-loglevel", "error"] + arguments,
                                                         workFolder: workFolder))
        guard result.exitCode == 0 else { throw ConversionError.failed(Self.reason(result.standardError, fallback: "FFmpeg couldn’t convert this file")) }
    }

    /// `ffprobe` as JSON: format, streams and chapters (and frames when `arguments` ask for them).
    func probeJSON(_ url: URL, workFolder: URL, extra: [String] = []) async throws -> Data {
        let runner = try require()
        let out = workFolder.appendingPathComponent(".probe-\(UUID().uuidString.prefix(8)).json")
        defer { try? FileManager.default.removeItem(at: out) }
        // `-o` writes the JSON to a file: a pipe is capped by the runner, and a file with many chapters can exceed it.
        let result = try await runner.run(ToolInvocation(tool: .ffprobe, arguments: ["-hide_banner", "-loglevel", "error", "-of", "json",
                                                                                           "-show_format", "-show_streams", "-show_chapters"]
                                                               + extra + ["-o", out.path, url.path], workFolder: workFolder))
        guard result.exitCode == 0, let data = try? Data(contentsOf: out) else {
            throw ConversionError.damaged(FormatID(url.pathExtension.lowercased()))
        }
        return data
    }

    /// FFmpeg's last error line, made readable ("Invalid data found when processing input").
    static func reason(_ log: String, fallback: String) -> String {
        let lines = log.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let last = lines.last(where: { !$0.hasPrefix("Conversion failed") }) ?? lines.last else { return fallback }
        let text = last.replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
        return text.isEmpty ? fallback : "\(fallback): \(text.prefix(200))"
    }
}
