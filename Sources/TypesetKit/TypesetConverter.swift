import Foundation
import SuperConverterCore

/// TypesetKit's converter (engine id `TypesetKit`): DocModel, Publication and Workbook to PDF (formats §6).
public struct TypesetConverter: Converter {
    public let id: EngineID = .typesetKit
    public let handles: [StepPattern] = [
        StepPattern(from: .model(.docModel), to: .formats(["pdf"])),
        StepPattern(from: .model(.publication), to: .formats(["pdf"])),
        StepPattern(from: .model(.workbook), to: .formats(["pdf"])),
    ]
    let fonts: FontLibrary?

    public init(fonts: FontLibrary?) { self.fonts = fonts }

    public func availability() -> EngineAvailability {
        fonts == nil ? .unavailable("The typesetting fonts are missing from the app") : .available
    }

    public func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        guard let fonts else { throw ConversionError.failed("The typesetting fonts are missing from the app") }
        if context.isCancelled() { throw ConversionError.cancelled }
        let options = TypesetOptions(context.options, look: context.look)
        let name = context.source.deletingPathExtension().lastPathComponent
        let output = context.workFolder.appendingPathComponent(name.isEmpty ? "Document" : name).appendingPathExtension("pdf")
        let typesetter = Typesetter(fonts: fonts)
        let report = { (f: Double) in context.report(StepProgress(fraction: f)) }
        let result: TypesetResult
        switch input {
        case .doc(let doc): result = try typesetter.typeset(doc, options: options, to: output, progress: report)
        case .publication(let pub): result = try typesetter.typeset(pub, options: options, to: output, progress: report)
        case .workbook(let book): result = try typesetter.typeset(book, options: options, to: output, progress: report)
        default: throw ConversionError.unsupportedPair(from: context.sourceFormat, to: context.targetFormat)
        }
        if context.isCancelled() {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.cancelled
        }
        return StepOutput(.file(output), lossNotes: result.lossNotes, warnings: result.warnings)
    }
}
