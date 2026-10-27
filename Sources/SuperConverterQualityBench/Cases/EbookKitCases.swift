import Foundation
import SuperConverterCore

/// EbookKit (quality §4): EPUB packaging rules, text carried over, comics passed through untouched.
enum EbookKitCases {
    static let all: [BenchCase] = [
        BenchCase(id: "ebookkit.epub-txt", category: .ebook, fixture: "generated/sample.epub", target: "txt", checks: [
            .producesFormat("txt"), .textContains(["Chapter 1", "quiet morning", "Chapter 2", "typeset, measured, and checked"]), .wordRecall(atLeast: 1.0),
        ]),
        BenchCase(id: "ebookkit.epub-oeb", category: .ebook, fixture: "generated/sample.epub", target: "oeb", checks: [
            .producesFormat("oeb"), .zipEntryContains("content.opf", ["Super Converter sample book", "OEB 1.2"]), .zipEntryContains("text/0001.html", ["Chapter 1", "quiet morning"]),
        ]),
        // Every EPUB we write: `mimetype` first and stored, a container, a package with a spine (what EPUBCheck requires first).
        BenchCase(id: "ebookkit.docx-epub", category: .ebook, fixture: "generated/sample.docx", target: "epub", checks: [
            .producesFormat("epub"), .zipHasEntries(["mimetype", "META-INF/container.xml"]), .epubMimetypeFirstAndStored(),
            .wordRecall(atLeast: 1.0),
        ]),
        BenchCase(id: "ebookkit.html-epub", category: .ebook, fixture: "generated/sample.html", target: "epub", checks: [
            .producesFormat("epub"), .epubMimetypeFirstAndStored(), .wordRecall(atLeast: 0.95, ignoring: ["https", "example", "com", "page"]),
        ]),
        // Comics: one page per picture, never recompressed (SHA-256 of each picture equals the source's).
        BenchCase(id: "ebookkit.cbz-epub", category: .ebook, fixture: "generated/sample.cbz", target: "epub", checks: [
            .producesFormat("epub"), .epubMimetypeFirstAndStored(), .picturesPassThrough(),
        ]),
        // A real EPUB 3 from the IDPF samples (CC BY-SA; `scripts/fetch-corpus.sh --only idpf-wasteland`): skipped until fetched.
        BenchCase(id: "ebookkit.idpf-wasteland-txt", category: .ebook, tier: .full, fixture: "external/epub/wasteland.epub", target: "txt", checks: [
            .producesFormat("txt"), .textContains(["April is the cruellest month"]), .wordRecall(atLeast: 0.9),
        ]),
        BenchCase(id: "ebookkit.epub-rtf", category: .ebook, tier: .full, fixture: "generated/sample.epub", target: "rtf", checks: [
            .producesFormat("rtf"), .textContains(["{\\rtf1", "Chapter 1"]),
        ]),
    ]
}
