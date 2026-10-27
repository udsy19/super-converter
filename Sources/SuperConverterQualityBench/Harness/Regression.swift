import Foundation

/// Regression memory (quality §9): the last accepted value of every limited metric, per case. A metric that gets worse by
/// more than its noise band fails even when it is still inside its threshold.
///
/// Two stores, the committed one wins: `Tests/Golden/<case>/metrics.json` (written by `--bless <case>`, reviewed in the PR
/// that blesses) and `.build/quality/memory.json` (this machine's best passing values, ratcheted by every green run).
struct GoldenMetrics: Codable, Equatable {
    var thresholds: [String: Limit]
    var accepted: [String: Double]
    /// SHA-256 of every output by file name, for cases with `exactOutput`.
    var outputs: [String: String]?
}

struct RegressionMemory {
    private(set) var cases: [String: [String: Double]]
    private let url: URL

    init(url: URL = RepoRoot.quality.appendingPathComponent("memory.json")) {
        self.url = url
        cases = (try? JSONDecoder().decode([String: [String: Double]].self, from: Data(contentsOf: url))) ?? [:]
    }

    static func goldenURL(_ id: String) -> URL { RepoRoot.golden.appendingPathComponent(id).appendingPathComponent("metrics.json") }

    static func golden(_ id: String) -> GoldenMetrics? {
        (try? Data(contentsOf: goldenURL(id))).flatMap { try? JSONDecoder().decode(GoldenMetrics.self, from: $0) }
    }

    func accepted(_ id: String) -> [String: Double] { Self.golden(id)?.accepted ?? cases[id] ?? [:] }

    /// Messages for every metric worse than accepted by more than its noise band.
    func regressions(_ id: String, _ measurements: [Measurement]) -> [String] {
        let previous = accepted(id)
        return measurements.compactMap { m in
            guard let limit = m.limit, let before = previous[m.name] else { return nil }
            let worse: Bool
            switch limit {
            case .atLeast: worse = m.value < before - m.noise
            case .atMost: worse = m.value > before + m.noise
            case .within(let target, _): worse = abs(m.value - target) > abs(before - target) + m.noise
            }
            return worse ? "\(m.name) regressed: \(Measurement.format(m.value)) vs accepted \(Measurement.format(before)) (noise band \(Measurement.format(m.noise)))" : nil
        }
    }

    /// Keeps the better of the stored and new value for a passing case.
    mutating func ratchet(_ id: String, _ measurements: [Measurement]) {
        var stored = cases[id] ?? [:]
        for m in measurements {
            guard let limit = m.limit else { continue }
            guard let old = stored[m.name] else { stored[m.name] = m.value; continue }
            switch limit {
            case .atLeast: stored[m.name] = max(old, m.value)
            case .atMost: stored[m.name] = min(old, m.value)
            case .within(let target, _): stored[m.name] = abs(m.value - target) < abs(old - target) ? m.value : old
            }
        }
        cases[id] = stored
    }

    func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(cases).write(to: url)
    }
}
