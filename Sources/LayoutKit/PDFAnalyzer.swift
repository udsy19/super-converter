// Adapted from Super PDF Sources/LayoutKit/LayoutService.swift (commit 058469b): takes a file URL and password instead of a
// PDFSource, reports progress and cancellation, and has no cache (a job analyses a file once).
import CoreGraphics
import Foundation
import PDFKit
import SuperConverterCore

/// What analysing a PDF gives the builders.
struct PDFAnalysis {
    var url: URL
    var password: String?
    var pages: [AnalysedPage]
    var title: String?
    var authors: [String]
}

enum PDFAnalyzer {
    /// Reads PDFKit's words on the main actor page by page, then does the content-stream scan, OCR and analysis off it.
    static func analyze(_ url: URL, password: String?, pages selection: String?, options: AnalysisOptions,
                        context: StepContext) async throws -> PDFAnalysis {
        let (inputs, title, authors) = try await MainActor.run { () throws -> ([PageInput], String?, [String]) in
            guard let pdf = PDFDocument(url: url) else { throw ConversionError.damaged("pdf") }
            if pdf.isLocked {
                guard let password, !password.isEmpty, pdf.unlock(withPassword: password) else { throw ConversionError.passwordRequired("pdf") }
            }
            let indices = PageSelection.indices(selection, pageCount: pdf.pageCount)
            guard !indices.isEmpty else { throw ConversionError.failed("None of those pages are in this file.") }
            var inputs: [PageInput] = []
            for index in indices {
                guard let page = pdf.page(at: index) else { throw ConversionError.damaged("pdf") }
                let words = options.recognition == .always ? [] : TextExtractor.words(on: page)
                inputs.append(PageInput(index: index, size: page.bounds(for: .cropBox).size, rotation: page.rotation, words: words))
            }
            // Read from the Info dictionary itself: PDFKit's `documentAttributes` raises (and so ends the app) when a damaged
            // file has a key that isn't valid text.
            func info(_ key: String) -> String? {
                var string: CGPDFStringRef?
                guard let info = pdf.documentRef?.info, CGPDFDictionaryGetString(info, key, &string), let string else { return nil }
                return CGPDFStringCopyTextString(string) as String?
            }
            return (inputs, info("Title"), info("Author").map { [$0] } ?? [])
        }
        let pages = try await Task.detached(priority: .userInitiated) {
            try analyze(inputs, url: url, password: password, options: options, context: context)
        }.value
        return PDFAnalysis(url: url, password: password, pages: pages, title: title?.isEmpty == false ? title : nil, authors: authors)
    }

    /// Off the main actor: page graphics, OCR where the policy asks, then the analysis.
    static func analyze(_ inputs: [PageInput], url: URL, password: String?, options: AnalysisOptions, context: StepContext) throws -> [AnalysedPage] {
        var inputs = inputs
        let document = try PagePictures.open(url, password: password)
        let customWords = options.recognition == .always ? [] : Array(Set(inputs.flatMap { $0.words.map(\.text) }.filter { $0.count >= 4 && $0.allSatisfy(\.isLetter) }).prefix(2000))
        for index in inputs.indices {
            if context.isCancelled() { throw ConversionError.cancelled }
            context.report(StepProgress(fraction: 0.8 * Double(index) / Double(inputs.count), unit: "Page \(index + 1) of \(inputs.count)"))
            guard let page = document.page(at: inputs[index].index + 1) else { throw ConversionError.damaged("pdf") }
            inputs[index].graphics = PageGraphicsScanner.scan(page)
            let needsOCR: Bool
            switch options.recognition {
            case .never: needsOCR = false
            case .always: needsOCR = true
            case .whenPageHasNoText: needsOCR = !inputs[index].words.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            }
            if needsOCR, let image = TextRecognizer.image(for: page) {
                let lines = try TextRecognizer.recognize(image, pageSize: inputs[index].size, rotation: inputs[index].rotation, languages: options.languages, customWords: customWords)
                inputs[index].words = TextRecognizer.words(from: lines)
                inputs[index].origin = .recognized
                inputs[index].graphics = .empty   // the scan's own image is the page, not a figure
            }
        }
        return LayoutAnalyzer.analyze(inputs, options: options)
    }
}

extension AnalysisOptions {
    /// The "Recognise text in scans" and "Join hyphenated words" style options of O-PDF-* profiles.
    init(_ options: OptionValues) {
        self.init(recognition: options["ocr"]?.bool ?? true ? .whenPageHasNoText : .never)
    }
}
