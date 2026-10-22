import Foundation
import SuperConverterCore

/// What the matrix and the registry disagree about (ARCHITECTURE §4): the launch check and the self-test read it.
public struct CoverageReport: Equatable, Sendable {
    /// Engines an offered route names that no converter registers.
    public var missingEngines: [EngineID] = []
    /// Registered converters that no route uses (dead code).
    public var unusedConverters: [EngineID] = []
    /// Steps whose engine is registered but whose converter does not handle that (from, to).
    public var unhandledSteps: [Step] = []

    public var isComplete: Bool { missingEngines.isEmpty && unusedConverters.isEmpty && unhandledSteps.isEmpty }
}

public enum Coverage {
    /// Checks every offered route's steps (built-in, helper and alternates) against `converters`.
    public static func verify(_ converters: [any Converter]) -> CoverageReport {
        let byID = Dictionary(converters.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var used: Set<EngineID> = []
        var steps: Set<Step> = []
        for route in FormatMatrix.offered {
            for chain in [route.builtin, route.helper].compactMap({ $0 }) + route.alternates.map(\.steps) {
                steps.formUnion(chain)
            }
            used.formUnion(route.engines)
        }
        var report = CoverageReport()
        report.missingEngines = used.filter { byID[$0] == nil }.sorted { $0.rawValue < $1.rawValue }
        report.unusedConverters = byID.keys.filter { !used.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        report.unhandledSteps = steps.filter { step in byID[step.engine].map { !$0.handles(step) } ?? false }
            .sorted { $0.description < $1.description }
        return report
    }
}
