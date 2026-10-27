import Foundation
import SuperConverterCore

enum Status: String, Codable { case passed, failed, regressed, skipped }

struct CaseResult: Codable {
    var id: String
    var category: Category
    var tier: Tier
    var status: Status
    var message: String
    var measurements: [Measurement]
    var artifacts: [Artifact]
    var seconds: Double
    var lossNotes: [String]
    var inputBytes: Int64
    var outputBytes: Int64
}

/// Runs cases through the planner and measures them.
@MainActor
struct Runner {
    var tier: Tier
    var only: [String] = []
    var bless: Set<String> = []
    var memory = RegressionMemory()
    let scratch = RepoRoot.quality.appendingPathComponent("work", isDirectory: true)
    let artifactRoot = RepoRoot.quality.appendingPathComponent("artifacts", isDirectory: true)

    func selected(_ cases: [BenchCase]) -> [BenchCase] {
        cases.filter { c in
            (only.isEmpty ? tier.includes(c.tier) : only.contains { c.id == $0 || c.id.hasPrefix($0 + ".") })
        }
    }

    mutating func run(_ cases: [BenchCase], progress: (CaseResult) -> Void) async -> [CaseResult] {
        try? FileManager.default.removeItem(at: scratch)
        try? FileManager.default.removeItem(at: artifactRoot)
        var results: [CaseResult] = []
        for c in selected(cases) {
            let result = await run(c)
            if result.status == .passed { memory.ratchet(c.id, result.measurements) }
            results.append(result)
            progress(result)
        }
        memory.save()
        try? FileManager.default.removeItem(at: scratch)
        return results
    }

    private func run(_ c: BenchCase) async -> CaseResult {
        let started = Date()
        func result(_ status: Status, _ message: String, _ measurements: [Measurement] = [], artifacts: [Artifact] = [], notes: [String] = [],
                    input: Int64 = 0, output: Int64 = 0) -> CaseResult {
            CaseResult(id: c.id, category: c.category, tier: c.tier, status: status, message: message, measurements: measurements, artifacts: artifacts,
                       seconds: Date().timeIntervalSince(started), lossNotes: notes, inputBytes: input, outputBytes: output)
        }
        let fixture = RepoRoot.corpus.appendingPathComponent(c.fixture)
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            return result(.skipped, "fixture \(c.fixture) is missing (\(c.fixture.hasPrefix("external/") ? "scripts/fetch-corpus.sh" : "swift scripts/make-fixtures.swift"))")
        }
        let work = scratch.appendingPathComponent(c.id, isDirectory: true)
        let out = work.appendingPathComponent("out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let run: Pipeline.Run
        if let route = c.route { run = await Pipeline.convertSteps(fixture, steps: route, target: c.target, options: c.options, registry: c.useFakes ? FakeEngines.registry : nil, into: out) }
        else { run = await Pipeline.convert(fixture, to: c.target, options: c.options, look: c.look, into: out, timeout: c.timeout) }
        let converted: ConversionResult
        switch run.outcome {
        case .skipped(let why): return result(.skipped, why)
        case .failed(let why): return result(.failed, why)
        case .converted(let r): converted = r
        }
        guard !converted.outputs.isEmpty else { return result(.failed, "the conversion wrote no output") }
        if let missing = converted.outputs.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) { return result(.failed, "\(missing.lastPathComponent) was reported but is not on disk") }

        let context = CaseContext(bench: c, source: fixture, sourceFormat: run.sourceFormat ?? "", outputs: converted.outputs, result: converted, work: work,
                                  artifactFolder: artifactRoot.appendingPathComponent(c.id, isDirectory: true))
        var measurements: [Measurement] = []
        var problems: [String] = []
        for check in c.checks {
            do { measurements += try await check.run(context) } catch { problems.append("\(check.name): \(error)") }
        }
        // A blessed golden's thresholds replace the code's (reviewed in the PR that changed them).
        if let thresholds = RegressionMemory.golden(c.id)?.thresholds {
            measurements = measurements.map { var m = $0; if let limit = thresholds[m.name], m.limit != nil { m.limit = limit }; return m }
        }
        for m in measurements where !m.passes { problems.append("\(m.name) = \(Measurement.format(m.value)) \(m.unit), needs \(m.limit?.text ?? "")") }

        if c.exactOutput { problems += exactnessProblems(c, converted.outputs) }
        let notes = converted.lossNotes.map { $0.detail.isEmpty ? $0.kind.rawValue : "\($0.kind.rawValue): \($0.detail)" }
        let bytes = (converted.inputBytes != 0 ? converted.inputBytes : fileSize(fixture), converted.outputBytes != 0 ? converted.outputBytes : converted.outputs.reduce(0) { $0 + fileSize($1) })
        if bless.contains(c.id) && problems.isEmpty { blessCase(c, measurements, converted.outputs) }

        if !problems.isEmpty { return result(.failed, problems.joined(separator: "; "), measurements, artifacts: context.artifacts, notes: notes, input: bytes.0, output: bytes.1) }
        let regressions = memory.regressions(c.id, measurements)
        if !regressions.isEmpty && !bless.contains(c.id) {
            return result(.regressed, regressions.joined(separator: "; "), measurements, artifacts: context.artifacts, notes: notes, input: bytes.0, output: bytes.1)
        }
        return result(.passed, "", measurements, artifacts: context.artifacts, notes: notes, input: bytes.0, output: bytes.1)
    }

    private func fileSize(_ url: URL) -> Int64 { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0 }

    // MARK: Goldens

    private func hashes(_ outputs: [URL]) -> [String: String] {
        Dictionary(outputs.compactMap { url in Manifest.sha256(ofFile: url).map { (url.lastPathComponent, $0) } }, uniquingKeysWith: { $1 })
    }

    private func exactnessProblems(_ c: BenchCase, _ outputs: [URL]) -> [String] {
        guard let expected = RegressionMemory.golden(c.id)?.outputs else { return [] }   // not blessed yet: nothing to compare
        let actual = hashes(outputs)
        return expected.keys.sorted().compactMap { actual[$0] == expected[$0] ? nil : "output \($0) differs from the golden hash" }
            + actual.keys.sorted().filter { expected[$0] == nil }.map { "unexpected output \($0)" }
    }

    /// `--bless <case>`: writes `Tests/Golden/<case>/metrics.json` (thresholds, accepted values, output hashes).
    private func blessCase(_ c: BenchCase, _ measurements: [Measurement], _ outputs: [URL]) {
        let limited = measurements.filter { $0.limit != nil }
        let golden = GoldenMetrics(thresholds: Dictionary(limited.map { ($0.name, $0.limit!) }, uniquingKeysWith: { $1 }),
                                   accepted: Dictionary(limited.map { ($0.name, $0.value) }, uniquingKeysWith: { $1 }),
                                   outputs: c.exactOutput ? hashes(outputs) : nil)
        let url = RegressionMemory.goldenURL(c.id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(golden).write(to: url)
    }
}
