import Foundation
import PDFKit
import SuperConverterCore

/// LayoutKit (PDF → editable documents, quality §3.6) and RenderKit (PDF pages → pixels, §2.2). The sample PDF has a
/// heading, three paragraphs and a ruled 4 x 3 table on page 1 and a second page of text.
enum LayoutKitCases {
    static let tableWords = ["Item", "Quantity", "Price", "Widget", "Gadget", "Gizmo", "12.25", "0.99", "150"]

    static let all: [BenchCase] = [
        // Born-digital PDF: character error rate 0 — every word comes back in order.
        BenchCase(id: "layoutkit.pdf-docx", category: .document, fixture: "generated/sample.pdf", target: "docx", checks: [
            .producesFormat("docx"), .zipEntryContains("word/document.xml", ["Super Converter sample", "Second page"] + tableWords), .wordRecall(atLeast: 1.0),
        ]),
        BenchCase(id: "layoutkit.pdf-md", category: .document, fixture: "generated/sample.pdf", target: "md", checks: [
            .producesFormat("md"), .textContains(["# **Super Converter sample**", "| Widget | 12 | 3.50 |", "## **Second page**"]), .wordRecall(atLeast: 1.0),
        ]),
        BenchCase(id: "layoutkit.pdf-epub", category: .ebook, tier: .full, fixture: "generated/sample.pdf", target: "epub", checks: [
            .producesFormat("epub"), .zipHasEntries(["mimetype", "META-INF/container.xml"]), .wordRecall(atLeast: 1.0), .epubMimetypeFirstAndStored(),
        ]),
        BenchCase(id: "layoutkit.pdf-html", category: .document, tier: .full, fixture: "generated/sample.pdf", target: "html", checks: [
            .producesFormat("html"), .textContains(["Super Converter sample", "<table"] + tableWords), .wordRecall(atLeast: 1.0),
        ]),
        BenchCase(id: "layoutkit.pdf-txt", category: .document, tier: .full, fixture: "generated/sample.pdf", target: "txt", checks: [
            .producesFormat("txt"), .wordRecall(atLeast: 1.0),
        ]),

        // RenderKit rasterises through CoreGraphics; an independent PDFKit render of the same page at the same density must match.
        BenchCase(id: "renderkit.pdf-raster", category: .image, fixture: "generated/sample.pdf", target: "png",
                  route: [Step(.renderKit, "pdf", .imageAsset)], options: OptionValues(["pixelDensity": 96, "pages": "1"]), checks: [
            .imageMatches(reference: { ctx in
                let url = ctx.work.appendingPathComponent("reference.png")
                let document = PDFDocument(url: ctx.source)   // kept alive while its page draws
                if let page = document?.page(at: 0), let raster = PDFRender.raster(page, dpi: 96) { raster.writePNG(to: url) }
                return url
            }, ssimAtLeast: 0.97, meanDeltaEAtMost: 1.0, p95DeltaEAtMost: 2.5, psnrAtLeast: 30),
            .pictureHasInk(inkAtLeast: 0.003),
        ]),
    ]
}
