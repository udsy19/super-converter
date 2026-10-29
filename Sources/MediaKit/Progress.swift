import Foundation
import SuperConverterCore

/// FFmpeg's machine-readable progress (`-progress <file>`): blocks of `key=value` lines, each ending in `progress=continue`
/// or, last, `progress=end`. MediaKit points it at a file in the work folder (the runner keeps a process's pipes to itself)
/// and turns what is written there into the step's progress (ARCHITECTURE §4: `AsyncStream` of progress, ux §7.1 units).
enum FFmpegProgress {
    struct Block: Equatable {
        /// Output time reached, seconds.
        var outTime: Double?
        var frame: Int?
        var speed: Double?
        var finished: Bool
    }

    /// The last complete block of `text` (a block in the middle of being written is ignored).
    static func last(_ text: String) -> Block? {
        var current: [String: String] = [:]
        var result: Block?
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            current[key] = value
            if key == "progress" {
                // `out_time_us` is microseconds; `out_time_ms` is (despite its name) microseconds too; `out_time` is HH:MM:SS.
                let micros = current["out_time_us"].flatMap(Double.init) ?? current["out_time_ms"].flatMap(Double.init)
                let time = micros.map { $0 / 1_000_000 } ?? current["out_time"].flatMap(MediaTime.seconds)
                let speed = current["speed"].flatMap { Double($0.replacingOccurrences(of: "x", with: "")) }
                result = Block(outTime: time.flatMap { $0 >= 0 ? $0 : nil }, frame: current["frame"].flatMap(Int.init), speed: speed,
                               finished: value == "end")
                current = [:]
            }
        }
        return result
    }

    /// Progress as the card shows it: the fraction of `duration` done and "1:02 of 3:40".
    static func stepProgress(_ block: Block, duration: Double?) -> StepProgress {
        guard let time = block.outTime else { return StepProgress(fraction: block.finished ? 1 : nil) }
        guard let duration, duration > 0 else { return StepProgress(fraction: block.finished ? 1 : nil, unit: MediaTime.clock(time)) }
        let fraction = block.finished ? 1 : min(max(time / duration, 0), 0.999)
        return StepProgress(fraction: fraction, unit: "\(MediaTime.clock(min(time, duration))) of \(MediaTime.clock(duration))")
    }

    /// Follows the progress file while FFmpeg writes it, until the stream is finished by the caller. Repeats are dropped.
    static func follow(_ file: URL, duration: Double?, every interval: TimeInterval = 0.25) -> AsyncStream<StepProgress> {
        AsyncStream { continuation in
            let task = Task {
                var last: StepProgress?
                while !Task.isCancelled {
                    if let text = try? String(contentsOf: file, encoding: .utf8), let block = Self.last(text) {
                        let progress = stepProgress(block, duration: duration)
                        if progress != last { continuation.yield(progress); last = progress }
                        if block.finished { break }
                    }
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Times as options carry them ("HH:MM:SS(.mmm)", formats §5 `trim_start`) and as cards show them.
enum MediaTime {
    /// "01:02:03.5", "2:03", "93.25" → seconds; nil for anything else.
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// "0:07", "3:40", "1:02:03".
    static func clock(_ seconds: Double) -> String {
        // A damaged file's timestamps can be anything; a clock shows up to about 30,000 years.
        let s = seconds.isFinite ? Int(min(max(seconds, -1e12), 1e12).rounded(.down)) : 0
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The argument form FFmpeg reads exactly: seconds with microseconds.
    static func argument(_ seconds: Double) -> String { String(format: "%.6f", seconds) }
}
