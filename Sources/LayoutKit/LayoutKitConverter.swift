import Foundation
import SuperConverterCore

/// `LayoutKit` steps (formats §6): a PDF's words, lines, paragraphs, columns, headings, lists, tables, figures and reading order
/// (with Vision OCR on scans) become a `LayoutDocument`, `DocModel`, `Workbook`, `Deck` or `Publication`, or plain text. The
/// writers for those models belong to DocKit, OfficeKit and EbookKit.
public struct LayoutKitConverter: Converter {
    public let id: EngineID = .layoutKit

    public var handles: [StepPattern] {
        let pdf = StepPattern.End.formats(["pdf"])
        return [ModelKind.layoutDocument, .docModel, .workbook, .deck, .publication].map { StepPattern(from: pdf, to: .model($0)) }
            + [StepPattern(from: pdf, to: .formats(["txt"]))]
    }

    public init() {}

    public func availability() -> EngineAvailability { .available }

    public func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        guard case .file(let url) = input else { throw ConversionError.failed("This step reads a PDF file.") }
        var analysisOptions = AnalysisOptions(context.options)
        // The LayoutDocument keeps running headers and footers (as header and footer blocks); every other form drops them.
        analysisOptions.excludeHeadersAndFooters = step.to != .layoutDocument
        let analysis = try await PDFAnalyzer.analyze(url, password: context.options["password"]?.string,
                                                      pages: context.options["pages"]?.string, options: analysisOptions, context: context)
        if context.isCancelled() { throw ConversionError.cancelled }
        context.report(StepProgress(fraction: 0.9, unit: "Building the result"))
        var warnings: [String] = []
        if analysis.pages.contains(where: { $0.origin == .recognized }) {
            warnings.append("Some pages were scans; their text was recognised and may contain mistakes.")
        }
        let buildOptions = BuildOptions(context.options)
        switch step.to {
        case .model(.layoutDocument):
            return StepOutput(.layout(try CoreLayout.document(analysis)), warnings: warnings)
        case .model(.docModel):
            var builder = try DocModelBuilder(analysis: analysis, options: buildOptions)
            return StepOutput(.doc(builder.build()), warnings: warnings)
        case .model(.workbook):
            return StepOutput(.workbook(WorkbookBuilder.build(analysis, options: context.options)), warnings: warnings)
        case .model(.deck):
            var builder = DeckBuilder(analysis: analysis, options: context.options)
            let deck = try builder.build()
            return StepOutput(.deck(deck), lossNotes: builder.lossNotes, warnings: warnings)
        case .model(.publication):
            var builder = try DocModelBuilder(analysis: analysis, options: buildOptions)
            return StepOutput(.publication(try PublicationBuilder.build(builder.build(), analysis: analysis)), warnings: warnings)
        case .format:
            let text = TextExporter.text(analysis, asOnPage: context.options["layout"]?.string == "page")
            let stem = (context.source.lastPathComponent as NSString).deletingPathExtension
            let out = context.workFolder.appendingPathComponent("\(stem).txt")
            try Data(text.utf8).write(to: out, options: .atomic)
            return StepOutput(.file(out), warnings: warnings)
        default:
            throw ConversionError.unsupportedPair(from: context.sourceFormat, to: context.targetFormat)
        }
    }
}
