import Foundation
import SuperConverterCore

/// VectorizeKit (formats §5 O-TRACE): raster → SVG through the planner. The route decodes with ImageKit first, so these
/// cases are skipped until ImageKit is built; the tracer's own accuracy is measured in its self-tests.
enum VectorizeKitCases {
    static let all: [BenchCase] = [
        BenchCase(id: "vectorizekit.png-svg", category: .vector, fixture: "generated/logo-alpha-128.png", target: "svg", checks: [
            .producesFormat("svg"), .textContains(["<path"]),
        ]),
        BenchCase(id: "vectorizekit.png-svg-bw", category: .vector, fixture: "generated/checker-512.png", target: "svg", options: OptionValues(["preset": "bw"]), checks: [
            .producesFormat("svg"), .textContains(["<path"]),
        ]),
    ]
}
