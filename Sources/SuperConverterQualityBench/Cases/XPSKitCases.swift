import Foundation
import SuperConverterCore

/// XPSKit (quality §6, vector rows): the XPS reader against WebKit's render of the same drawing as SVG, and the XPS writer
/// (obfuscated fonts) re-read by the reader against PDFKit's render of its PDF source.
enum XPSKitCases {
    static let all: [BenchCase] = [
        // The XPS fixture is the SVG fixture's drawing without the words (XPS glyphs need an embedded font).
        BenchCase(id: "xpskit.xps-pdf", category: .vector, fixture: "generated/sample.xps", target: "pdf", checks: [
            .producesFormat("pdf"),
            Check(name: "looks like the SVG drawing without its words") { ctx in
                var svg = String(decoding: try Data(contentsOf: RepoRoot.corpus.appendingPathComponent(VectorKitCases.svg)), as: UTF8.self)
                if let start = svg.range(of: "<text"), let end = svg.range(of: "</text>") { svg.removeSubrange(start.lowerBound..<end.upperBound) }
                let a = try await VectorBench.independent(try VectorBench.output(ctx), work: ctx.work), b = try await VectorBench.webKit(svg, work: ctx.work)
                ctx.attach("output", raster: a, name: "output.png"); ctx.attach("reference", raster: b, name: "reference.png")
                guard let ssim = SSIM.ssim(a, b) else { throw CheckFailure("pictures too small for SSIM") }
                return [.ssim("ssim vs WebKit", ssim.mean, atLeast: 0.98)]
            },
        ]),
        // The documents' XPS routes end in these two steps (a typeset or rendered PDF, read and written as XPS).
        BenchCase(id: "xpskit.pdf-xps", category: .vector, fixture: VectorKitCases.pdf, target: "xps",
                  route: [Step(.vectorKit, "pdf", .vectorDocument), Step(.xpsWriter, .vectorDocument, "xps")], checks: [
            .producesFormat("xps"), .zipHasEntries(["FixedDocumentSequence.fdseq", "[Content_Types].xml"]),
            VectorBench.looksLike(.ours, reference: .sourceIndependent, atLeast: 0.98), VectorBench.textKept(),
        ]),
    ]
}
