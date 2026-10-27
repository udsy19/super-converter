import Foundation
import SuperConverterCore

/// HelperKit: routes that run through an installed helper (Pandoc's readers, LibreOffice). A helper that is not installed
/// makes its case *skipped*, never passed — a pair with no passing case cannot be marked shipped.
enum HelperKitCases {
    static let all: [BenchCase] = [
        BenchCase(id: "helperkit.pandoc-rst-md", category: .helper, fixture: "generated/sample.rst", target: "md", checks: [
            .producesFormat("md"), .textContains(["Super Converter sample", "*emphasis*", "**strong text**", "First bullet"]),
        ]),
        BenchCase(id: "helperkit.pandoc-tex-md", category: .helper, fixture: "generated/sample.tex", target: "md", checks: [
            .producesFormat("md"), .textContains(["Super Converter sample", "*emphasis*", "First bullet"]),
        ]),
        // LibreOffice: the original-layout route for formats we only write through it.
        BenchCase(id: "helperkit.libreoffice-docx-odt", category: .helper, tier: .full, fixture: "generated/sample.docx", target: "odt", checks: [
            .producesFormat("odt"), .zipEntryContains("content.xml", ["Super Converter sample", "EbookKit"]), .wordRecall(atLeast: 1.0),
        ]),
        BenchCase(id: "helperkit.libreoffice-docx-pdf", category: .helper, tier: .full, fixture: "generated/sample.docx", target: "pdf", checks: [
            .producesFormat("pdf"), .pdf(pages: 1, text: ["Super Converter sample", "DocKit"]), .wordRecall(atLeast: 1.0),
        ]),
    ]
}
