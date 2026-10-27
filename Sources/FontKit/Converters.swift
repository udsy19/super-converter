import Foundation
import SuperConverterCore

/// A reader engine: a font file → `FontModel`.
struct FontReaderConverter: Converter {
    let id: EngineID
    let formats: Set<FormatID>
    let read: @Sendable ([UInt8]) throws -> (FontModel, [LossNote])

    var handles: [StepPattern] { [StepPattern(from: .formats(formats), to: .model(.fontModel))] }
    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        guard case .file(let url) = input else { throw ConversionError.failed("This step reads a file.") }
        if context.isCancelled() { throw ConversionError.cancelled }
        do {
            let (model, notes) = try read(Array(try Data(contentsOf: url)))
            context.report(StepProgress(fraction: 1, unit: "Reading the font"))
            return StepOutput(.font(model), lossNotes: notes)
        } catch let error as FontError {
            throw error.conversionError(sourceFormat: context.sourceFormat)
        }
    }
}

/// A writer engine: `FontModel` → one font file in the work folder.
struct FontWriterConverter: Converter {
    let id: EngineID
    let format: FormatID
    /// Outline kind the file needs; the model is converted first when it differs.
    let outlines: FontModel.OutlineKind?
    let write: @Sendable (FontModel, FontOptions) throws -> [UInt8]

    var handles: [StepPattern] { [StepPattern(from: .model(.fontModel), to: .formats([format]))] }
    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        guard case .font(var model) = input else { throw ConversionError.failed("This step writes a font.") }
        if context.isCancelled() { throw ConversionError.cancelled }
        let options = FontOptions(context.options)
        var notes: [LossNote] = []
        do {
            let (subset, subsetNotes) = options.apply(to: model)
            model = subset; notes += subsetNotes
            if outlines == .cubic { model = OutlineConversion.cubic(model) }
            if outlines == .quadratic { model = OutlineConversion.quadratic(model, toleranceUnits: options.toleranceUnits(for: model)) }
            context.report(StepProgress(fraction: 0.5, unit: "Writing the font"))
            if context.isCancelled() { throw ConversionError.cancelled }
            let bytes = try write(model, options)
            let stem = (context.source.lastPathComponent as NSString).deletingPathExtension
            let url = Self.freeName(stem: stem, ext: format.rawValue, in: context.workFolder)
            try Data(bytes).write(to: url)
            context.report(StepProgress(fraction: 1, unit: "Writing the font"))
            return StepOutput(.file(url), lossNotes: notes)
        } catch let error as FontError {
            throw error.conversionError(sourceFormat: context.sourceFormat)
        }
    }

    static func freeName(stem: String, ext: String, in folder: URL) -> URL {
        var url = folder.appendingPathComponent("\(stem).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = folder.appendingPathComponent("\(stem)-\(n).\(ext)"); n += 1 }
        return url
    }
}

extension FontError {
    func conversionError(sourceFormat: FormatID) -> ConversionError {
        switch self {
        case .damaged: .damaged(sourceFormat)
        case .unsupported(let message): .failed(message)
        }
    }
}
