import Foundation
import SuperConverterCore

/// CADKit (quality §6 DXF rows): plotting with zoom-to-extents, and the DXF writer re-read by our own reader.
enum CADKitCases {
    /// DXF → drawing → vector page → pixels, straight through the converters: needs no other kit besides RenderKit.
    static let plotRoute = [Step(.dxfReader, "dxf", .cadDrawing), Step(.cadKit, .cadDrawing, .vectorDocument), Step(.renderKit, .vectorDocument, .imageAsset)]
    static let plotOptions = OptionValues(["width": 1000])

    static let all: [BenchCase] = [
        // The sample drawing is 100 x 60 units: zoom-to-extents must fill the page with that aspect, not leave it a speck.
        BenchCase(id: "cadkit.dxf-plot", category: .cad, fixture: "generated/sample.dxf", target: "png", route: plotRoute, options: plotOptions, checks: [
            .pictureHasInk(inkAtLeast: 0.01, aspect: 100.0 / 60.0, tolerance: 0.06),
        ]),
        // Every DXF we write, read back by our reader, plots the same picture (SSIM, quality §6 "DXF writer").
        BenchCase(id: "cadkit.dxf-rewrite", category: .cad, fixture: "generated/sample.dxf", target: "dxf",
                  route: [Step(.dxfReader, "dxf", .cadDrawing), Step(.dxfWriter, .cadDrawing, "dxf")], checks: [
            .producesFormat("dxf"),
            Check(name: "re-read plots like the source") { ctx in
                let a = await Pipeline.convertSteps(ctx.source, steps: plotRoute, target: "png", options: plotOptions, into: ctx.work.appendingPathComponent("a"))
                let b = await Pipeline.convertSteps(try unwrap(ctx.output), steps: plotRoute, target: "png", options: plotOptions, into: ctx.work.appendingPathComponent("b"))
                guard case .converted(let ra) = a.outcome, case .converted(let rb) = b.outcome, let pa = ra.outputs.first.flatMap({ Raster(contentsOf: $0) }),
                      let pb = rb.outputs.first.flatMap({ Raster(contentsOf: $0) }) else { throw CheckFailure("a plot failed: \(a.outcome) / \(b.outcome)") }
                guard pa.width == pb.width, pa.height == pb.height else { throw CheckFailure("plots differ in size: \(pa.width)x\(pa.height) vs \(pb.width)x\(pb.height)") }
                guard let ssim = SSIM.ssim(pa, pb) else { throw CheckFailure("plots too small for SSIM") }
                ctx.attach("source plot", raster: pa, name: "source.png"); ctx.attach("rewritten plot", raster: pb, name: "rewritten.png")
                return [.ssim("ssim vs source plot", ssim.mean, atLeast: 0.99)]
            },
        ]),
        // Through the planner once VectorKit lands: skipped (not passed) until then.
        BenchCase(id: "cadkit.dxf-svg", category: .cad, fixture: "generated/sample.dxf", target: "svg", checks: [
            .producesFormat("svg"), .textContains(["<svg", "SUPER CONVERTER"]),
        ]),
        BenchCase(id: "cadkit.dxf-pdf", category: .cad, fixture: "generated/sample.dxf", target: "pdf", checks: [
            .producesFormat("pdf"), .pdf(pages: 1, text: ["SUPER CONVERTER"]),
        ]),
    ]

    private static func unwrap(_ url: URL?) throws -> URL { guard let url else { throw CheckFailure("no output") }; return url }
}
