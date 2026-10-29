import Foundation
import SuperConverterCore

/// VectorizeKit (formats §5 O-TRACE): raster → SVG through the planner, decoded by ImageKit first; the tracer's own
/// accuracy is measured in its self-tests. The black-and-white preset traces text: a 1-pixel checkerboard would be all
/// specks, which the preset's speckle filter removes (as vtracer's does).
enum VectorizeKitCases {
    static let all: [BenchCase] = [
        BenchCase(id: "vectorizekit.png-svg", category: .vector, fixture: "generated/logo-alpha-128.png", target: "svg", checks: [
            .producesFormat("svg"), .textContains(["<path"]),
        ]),
        BenchCase(id: "vectorizekit.png-svg-bw", category: .vector, fixture: "generated/red-text-240.png", target: "svg", options: OptionValues(["preset": "bw"]), checks: [
            .producesFormat("svg"), .textContains(["<path"]),
        ]),
    ]
}
