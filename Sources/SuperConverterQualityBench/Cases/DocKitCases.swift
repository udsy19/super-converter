import Foundation
import SuperConverterCore

/// DocKit: the readers and writers, with the quality §3.7 round trips (MD → DOCX → MD, MD → ODT → MD, MD → HTML → MD).
enum DocKitCases {
    static let all: [BenchCase] = [
        BenchCase(id: "dockit.md-docx", category: .document, fixture: "generated/sample.md", target: "docx", checks: [
            .producesFormat("docx"),
            .zipEntryContains("word/document.xml", ["Super Converter sample", "emphasis", "DocKit", "Ünïcödé"]),
            .roundTrip(to: "md", wordsAtLeast: 1.0),
        ]),
        BenchCase(id: "dockit.md-odt", category: .document, fixture: "generated/sample.md", target: "odt", checks: [
            .producesFormat("odt"),
            .zipEntryContains("content.xml", ["Super Converter sample", "EbookKit"]),
            .roundTrip(to: "md", wordsAtLeast: 1.0),
        ]),
        BenchCase(id: "dockit.md-html", category: .document, fixture: "generated/sample.md", target: "html", checks: [
            .producesFormat("html"), .textContains(["<h1", "<table", "<em>", "https://example.com/page"]),
            .roundTrip(to: "md", wordsAtLeast: 1.0),
        ]),
        BenchCase(id: "dockit.docx-md", category: .document, fixture: "generated/sample.docx", target: "md", checks: [
            .producesFormat("md"), .textContains(["# Super Converter sample", "## A table", "| DOCX | DocKit |"]), .wordRecall(atLeast: 1.0),
        ]),
        BenchCase(id: "dockit.odt-md", category: .document, fixture: "generated/sample.odt", target: "md", checks: [
            .producesFormat("md"), .textContains(["# Super Converter sample", "| ODT | DocKit |"]), .wordRecall(atLeast: 1.0),
        ]),
        BenchCase(id: "dockit.html-docx", category: .document, fixture: "generated/sample.html", target: "docx", checks: [
            .producesFormat("docx"), .zipEntryContains("word/document.xml", ["Super Converter sample", "Second bullet", "EbookKit"]), .wordRecall(atLeast: 0.95, ignoring: ["https", "example", "com", "page"]),
        ]),
        // WebKit renders the page: a PDF with the text, a picture with ink.
        BenchCase(id: "dockit.html-pdf", category: .document, fixture: "generated/sample.html", target: "pdf", checks: [
            .producesFormat("pdf"), .pdf(pages: 1, text: ["Super Converter sample", "Second bullet"]),
        ]),
        BenchCase(id: "dockit.html-png", category: .document, fixture: "generated/sample.html", target: "png", checks: [
            .producesFormat("png"), .pictureHasInk(inkAtLeast: 0.003),
        ]),
        BenchCase(id: "dockit.md-tex", category: .document, tier: .full, fixture: "generated/sample.md", target: "tex", checks: [
            .producesFormat("tex"), .textContains(["\\section", "\\emph", "\\begin{tabular}"]),
        ]),
        BenchCase(id: "dockit.md-rtf", category: .document, tier: .full, fixture: "generated/sample.md", target: "rtf", checks: [
            .producesFormat("rtf"), .textContains(["{\\rtf1", "Super Converter sample"]), .roundTrip(to: "md", wordsAtLeast: 0.95),
        ]),
        BenchCase(id: "dockit.md-txt", category: .document, tier: .full, fixture: "generated/sample.md", target: "txt", checks: [
            .producesFormat("txt"), .textContains(["Super Converter sample", "Second bullet", "Quality is measured"]),
        ]),
        BenchCase(id: "dockit.rtf-md", category: .document, tier: .full, fixture: "generated/sample.rtf", target: "md", checks: [
            .producesFormat("md"), .textContains(["Super Converter sample", "**strong text**"]),
        ]),
    ]
}
