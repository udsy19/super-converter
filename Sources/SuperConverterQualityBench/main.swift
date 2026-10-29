import ArchiveKit
import CADKit
import ConvertKit
import DocKit
import EbookKit
import FontKit
import Foundation
import HelperKit
import ImageKit
import LayoutKit
import MathKit
import MediaKit
import OfficeKit
import RenderKit
import SuperConverterCore
import TypesetKit
import VectorKit
import VectorizeKit
import XPSKit

// The quality bench (quality §9). `swift run SuperConverterQualityBench [--tier fast|full] [--only <case>]… [--bless <case>]…
// [--list] [--validate-only]`. Exit status: 0 everything green (skipped cases are reported, not failures), 1 a failure,
// regression or failed metric validation, 64 wrong usage.
setvbuf(stdout, nil, _IOLBF, 0)

struct Options {
    var tier = Tier.fast
    var only: [String] = []
    var bless: [String] = []
    var list = false
    var validateOnly = false
}

func parse(_ arguments: [String]) -> Options? {
    var o = Options()
    var queue = arguments[...]
    while let a = queue.popFirst() {
        switch a {
        case "--tier": guard let v = queue.popFirst(), let t = Tier(rawValue: v) else { return nil }; o.tier = t
        case "--only": guard let v = queue.popFirst() else { return nil }; o.only += v.split(separator: ",").map(String.init)
        case "--bless": guard let v = queue.popFirst() else { return nil }; o.bless.append(v); o.only.append(v)
        case "--list": o.list = true
        case "--validate-only": o.validateOnly = true
        default: return nil
        }
    }
    return o
}

guard let options = parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data("usage: SuperConverterQualityBench [--tier fast|full] [--only <case>[,<case>…]] [--bless <case>] [--list] [--validate-only]\n".utf8))
    exit(64)
}

// 1. The metrics are checked against published values first; nothing else is trusted until they pass.
print("Metric self-validation")
let validation = MetricValidation.runAll()
for v in validation { print("  \(v.skipped ? "skip" : v.passed ? "ok  " : "FAIL") \(v.name) — \(v.detail)") }
let validationEntries = validation.map { Report.ValidationEntry(name: $0.name, passed: $0.passed, skipped: $0.skipped, detail: $0.detail) }
let validationFailed = validation.contains { !$0.passed }
if validationFailed { print("Metric self-validation FAILED"); exit(1) }
if options.validateOnly { print("Metric self-validation green (\(validation.count) checks)"); exit(0) }

// Throwaway data and settings: the bench never touches the real Application Support folder or preferences.
let dataFolder = RepoRoot.quality.appendingPathComponent("data", isDirectory: true)
try? FileManager.default.removeItem(at: dataFolder)
SuperConverterPaths.base = dataFolder.appendingPathComponent("Application Support", isDirectory: true)
SuperConverterPaths.cacheBase = dataFolder.appendingPathComponent("Caches", isDirectory: true)
let suite = "superconverter-qualitybench-\(UUID().uuidString)"
Defaults.store = UserDefaults(suiteName: suite)!

if options.list {
    for c in CaseRegistry.all { print("\(c.id)\t\(c.tier.rawValue)\t\(c.category.rawValue)\t\(c.fixture) -> \(c.target.rawValue)") }
    exit(0)
}

Task { @MainActor in
    // Same launch sequence as `sconv` (ARCHITECTURE §9, step 2).
    HelperKitModule.install()
    ImageKitModule.install(); VectorKitModule.install(); XPSKitModule.install(); VectorizeKitModule.install()
    CADKitModule.install(); DocKitModule.install(); TypesetKitModule.install(); MathKitModule.install()
    LayoutKitModule.install(); RenderKitModule.install(); OfficeKitModule.install(); EbookKitModule.install(extractor: ArchiveKitModule.extractor())
    ArchiveKitModule.install(); MediaKitModule.install(); FontKitModule.install()
    ConvertKitModule.install(collisionPolicy: { .addNumber })

    var runner = Runner(tier: options.tier, only: options.only, bless: Set(options.bless))
    let cases = runner.selected(CaseRegistry.all)
    if cases.isEmpty { print("No case matches."); exit(options.only.isEmpty ? 0 : 64) }
    print("\nRunning \(cases.count) cases (tier \(options.tier.rawValue))")
    let results = await runner.run(CaseRegistry.all) { r in
        let mark = ["passed": "ok  ", "failed": "FAIL", "regressed": "REGR", "skipped": "skip"][r.status.rawValue]!
        print("  \(mark) \(r.id) (\(String(format: "%.1f", r.seconds)) s)" + (r.message.isEmpty ? "" : " — \(r.message)"))
    }
    let report = Report(tier: options.tier, date: Date(), validation: validationEntries, cases: results)
    let files = report.write()
    let c = report.count
    print("\n\(results.count) cases: \(c[.passed] ?? 0) passed, \(c[.failed] ?? 0) failed, \(c[.regressed] ?? 0) regressed, \(c[.skipped] ?? 0) skipped")
    print("Report: \(files.html.path)")
    try? FileManager.default.removeItem(at: dataFolder)
    exit(report.failures.isEmpty ? 0 : 1)
}
RunLoop.main.run()   // WebKit (DocKit's web engines) needs the real main thread and its run loop
