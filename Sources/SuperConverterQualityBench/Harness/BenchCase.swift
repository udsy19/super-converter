import Foundation
import SuperConverterCore

/// *fast* runs on every push and before every commit that touches an engine; *full* adds every other case (quality §9).
enum Tier: String, Codable, CaseIterable {
    case fast, full

    /// A full run includes the fast cases.
    func includes(_ other: Tier) -> Bool { self == .full || other == .fast }
}

enum Category: String, Codable, CaseIterable {
    case image, vector, cad, document, spreadsheet, presentation, ebook, font, archive, audio, video, helper
}

/// How a measured number must compare to pass.
enum Limit: Equatable {
    case atLeast(Double)
    case atMost(Double)
    /// Within `tolerance` of `target`.
    case within(Double, tolerance: Double)

    func accepts(_ value: Double) -> Bool {
        switch self {
        case .atLeast(let x): value >= x
        case .atMost(let x): value <= x
        case .within(let target, let tolerance): abs(value - target) <= tolerance
        }
    }

    var text: String {
        switch self {
        case .atLeast(let x): "≥ \(Measurement.format(x))"
        case .atMost(let x): "≤ \(Measurement.format(x))"
        case .within(let t, let tol): "\(Measurement.format(t)) ± \(Measurement.format(tol))"
        }
    }
}

extension Limit: Codable {
    /// `{"atLeast": 0.98}`, `{"atMost": 1.0}`, `{"target": 100, "tolerance": 5}` — what `Tests/Golden/<case>/metrics.json` holds.
    private enum Keys: String, CodingKey { case atLeast, atMost, target, tolerance }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let x = try c.decodeIfPresent(Double.self, forKey: .atLeast) { self = .atLeast(x) }
        else if let x = try c.decodeIfPresent(Double.self, forKey: .atMost) { self = .atMost(x) }
        else { self = .within(try c.decode(Double.self, forKey: .target), tolerance: try c.decode(Double.self, forKey: .tolerance)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .atLeast(let x): try c.encode(x, forKey: .atLeast)
        case .atMost(let x): try c.encode(x, forKey: .atMost)
        case .within(let t, let tol): try c.encode(t, forKey: .target); try c.encode(tol, forKey: .tolerance)
        }
    }
}

/// One number a check produced, with the threshold it must meet (quality tables) and the noise band inside which a change
/// from the last accepted run is not a regression (§9: SSIM 0.002, ΔE 0.1, VMAF 0.5, MOS 0.05).
struct Measurement: Codable, Equatable {
    var name: String
    var value: Double
    var unit: String = ""
    var limit: Limit?
    var noise: Double = 0

    var passes: Bool { limit?.accepts(value) ?? true }

    static func format(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e9 ? String(Int(x)) : String(format: "%.4g", x)
    }

    // The metrics the spec gives noise bands for.
    static func ssim(_ name: String = "ssim", _ value: Double, atLeast: Double) -> Measurement { Measurement(name: name, value: value, limit: .atLeast(atLeast), noise: 0.002) }
    static func deltaE(_ name: String, _ value: Double, atMost: Double) -> Measurement { Measurement(name: name, value: value, unit: "ΔE00", limit: .atMost(atMost), noise: 0.1) }
    static func psnr(_ value: Double, atLeast: Double) -> Measurement { Measurement(name: "psnr", value: value, unit: "dB", limit: .atLeast(atLeast), noise: 0.1) }
    static func count(_ name: String, _ value: Int, atLeast: Int) -> Measurement { Measurement(name: name, value: Double(value), limit: .atLeast(Double(atLeast))) }
    static func exact(_ name: String, _ value: Double, equals target: Double) -> Measurement { Measurement(name: name, value: value, limit: .within(target, tolerance: 0)) }
    /// Informational: recorded in the report, never failing.
    static func info(_ name: String, _ value: Double, unit: String = "") -> Measurement { Measurement(name: name, value: value, unit: unit) }
}

/// Something the HTML report shows next to a case: a picture, a difference heat map, a histogram.
struct Artifact: Codable, Equatable {
    var label: String
    /// A PNG or SVG file.
    var path: String
}

/// What a check sees after the conversion ran.
@MainActor
final class CaseContext {
    let bench: BenchCase
    /// The fixture, resolved under Tests/Corpus.
    let source: URL
    let sourceFormat: FormatID
    /// The files the conversion wrote, in the order the engine reported them.
    let outputs: [URL]
    let result: ConversionResult
    /// A scratch folder for derived files (renders, round trips); deleted after the run unless artifacts live there.
    let work: URL
    /// Where artifacts for the report go (`.build/quality/artifacts/<case>`).
    let artifactFolder: URL
    private(set) var artifacts: [Artifact] = []

    init(bench: BenchCase, source: URL, sourceFormat: FormatID, outputs: [URL], result: ConversionResult, work: URL, artifactFolder: URL) {
        self.bench = bench; self.source = source; self.sourceFormat = sourceFormat; self.outputs = outputs
        self.result = result; self.work = work; self.artifactFolder = artifactFolder
    }

    var output: URL? { outputs.first }

    func attach(_ label: String, file name: String, data: Data) {
        try? FileManager.default.createDirectory(at: artifactFolder, withIntermediateDirectories: true)
        let url = artifactFolder.appendingPathComponent(name)
        if (try? data.write(to: url)) != nil { artifacts.append(Artifact(label: label, path: url.path)) }
    }

    func attach(_ label: String, raster: Raster, name: String) {
        try? FileManager.default.createDirectory(at: artifactFolder, withIntermediateDirectories: true)
        let url = artifactFolder.appendingPathComponent(name)
        if raster.writePNG(to: url) { artifacts.append(Artifact(label: label, path: url.path)) }
    }

    /// The golden folder of this case (`Tests/Golden/<id>/`), created on demand when blessing.
    var golden: URL { RepoRoot.golden.appendingPathComponent(bench.id, isDirectory: true) }
}

struct CheckFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// A named measurement step run on the converted output.
struct Check {
    var name: String
    var run: @MainActor (CaseContext) async throws -> [Measurement]
}

/// One conversion with the checks its output must pass. Adding a case: see `CaseRegistry`.
struct BenchCase {
    var id: String
    var category: Category
    var tier: Tier = .fast
    /// The input, relative to `Tests/Corpus/` (generated fixtures live in `generated/`, downloaded ones in `external/`).
    var fixture: String
    var target: FormatID
    /// Run these steps straight through the registered converters instead of asking the planner — for an engine whose full
    /// route needs a sibling that is not built yet, or to measure one engine on its own. The last step must end in a file
    /// or an `ImageAsset` (written as PNGs). `target` still names the format of the result.
    var route: [Step]?
    var options = OptionValues()
    var look: DocumentLook?
    /// Run `route` on `FakeEngines` instead of the registered converters (the harness's own sample cases).
    var useFakes = false
    var checks: [Check]
    /// Compare the outputs' SHA-256 against `Tests/Golden/<id>/outputs.json` (written by `--bless`) — for byte-exact claims.
    var exactOutput = false
    var timeout: TimeInterval = 180
}
