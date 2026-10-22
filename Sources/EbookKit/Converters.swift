import Foundation
import SuperConverterCore

/// A reader engine: one file format family → `Publication`.
struct PublicationReaderConverter: Converter {
    let id: EngineID
    let formats: Set<FormatID>
    let needsExtractor: Bool
    let extractor: ArchiveExtractor?
    let read: @Sendable (URL, StepContext, ArchiveExtractor?) async throws -> PublicationRead

    var handles: [StepPattern] { [StepPattern(from: .formats(formats), to: .model(.publication))] }

    func availability() -> EngineAvailability {
        needsExtractor && extractor == nil ? .unavailable("Needs the archive engine") : .available
    }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        guard case .file(let url) = input else { throw ConversionError.failed("This step reads a file.") }
        if context.isCancelled() { throw ConversionError.cancelled }
        let result = try await read(url, context, extractor)
        context.report(StepProgress(fraction: 1))
        return StepOutput(.publication(result.publication), lossNotes: result.lossNotes, warnings: result.warnings)
    }
}

/// EbookKit proper: the publication hub's own steps (Publication ↔ DocModel, EPUB and OEB writers).
struct EbookKitConverter: Converter {
    let id: EngineID = .ebookKit

    var handles: [StepPattern] {
        let targets = StepPattern.End.formats(["epub", "oeb"])
        return [
            StepPattern(from: .model(.publication), to: targets),
            StepPattern(from: .model(.publication), to: .model(.docModel)),
            StepPattern(from: .model(.docModel), to: targets),
        ]
    }

    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        if context.isCancelled() { throw ConversionError.cancelled }
        switch (input, step.to) {
        case (.publication(let publication), .model(.docModel)):
            let (doc, losses) = PublicationBuilder.document(from: publication)
            return StepOutput(.doc(doc), lossNotes: losses)
        case (.publication(let publication), .format(let format)):
            return try write(publication, as: format, context: context)
        case (.doc(let doc), .format(let format)):
            return try write(PublicationBuilder.publication(from: doc), as: format, context: context)
        default:
            throw ConversionError.unsupportedPair(from: context.sourceFormat, to: context.targetFormat)
        }
    }

    private func write(_ publication: Publication, as format: FormatID, context: StepContext) throws -> StepOutput {
        let options = PackageWriteOptions(options: context.options)
        let stem = (context.source.lastPathComponent as NSString).deletingPathExtension
        let url = Self.freeName(stem: stem, ext: format.rawValue, in: context.workFolder)
        let report: (Double) -> Void = { context.report(StepProgress(fraction: $0, unit: "Writing the book")) }
        let losses = format == "oeb"
            ? try OEBWriter.write(publication, to: url, options: options, isCancelled: context.isCancelled, report: report)
            : try EPUBWriter.write(publication, to: url, options: options, isCancelled: context.isCancelled, report: report)
        return StepOutput(.file(url), lossNotes: losses)
    }

    static func freeName(stem: String, ext: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(stem)-\(n).\(ext)"); n += 1 }
        return url
    }
}
