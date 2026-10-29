import Foundation
import SuperConverterCore

/// An engine adapter for one engine id: data (what it handles) plus a body. VectorKit and XPSKit register these.
public struct VectorConverter: Converter {
    public let id: EngineID
    public let handles: [StepPattern]
    let body: @Sendable (Step, StepValue, StepContext) throws -> StepOutput

    public init(id: EngineID, handles: [StepPattern], body: @escaping @Sendable (Step, StepValue, StepContext) throws -> StepOutput) {
        self.id = id; self.handles = handles; self.body = body
    }

    public func availability() -> EngineAvailability { .available }

    public func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        if context.isCancelled() { throw ConversionError.cancelled }
        return try body(step, input, context)
    }
}

/// The small things every vector converter does with a step's input and output.
public enum ConverterSupport {
    public static func fileURL(_ input: StepValue) throws -> URL {
        guard case .file(let url) = input else { throw ConversionError.impossiblePair(reason: "A file was expected here.") }
        return url
    }

    public static func readData(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.damaged(FormatID(url.pathExtension.lowercased())) }
    }

    public static func vector(_ input: StepValue) throws -> VectorDocument {
        guard case .vector(let document) = input else { throw ConversionError.impossiblePair(reason: "The drawing wasn’t handed over.") }
        return document
    }

    /// A new file in the work folder named after the source; an existing name gets a number.
    public static func output(_ context: StepContext, _ pathExtension: String) -> URL {
        let stem = context.source.deletingPathExtension().lastPathComponent
        var url = context.workFolder.appendingPathComponent(stem).appendingPathExtension(pathExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = context.workFolder.appendingPathComponent("\(stem) \(n)").appendingPathExtension(pathExtension)
            n += 1
        }
        return url
    }

    /// Reader step: file in, model out.
    public static func reader(_ id: EngineID, from formats: Set<FormatID>, read: @escaping @Sendable (URL) throws -> VectorReadResult) -> VectorConverter {
        VectorConverter(id: id, handles: [StepPattern(from: .formats(formats), to: .model(.vectorDocument))]) { _, input, _ in
            let result = try read(try fileURL(input))
            return StepOutput(.vector(result.document), lossNotes: result.lossNotes, warnings: result.warnings)
        }
    }

    /// Writer step: model in, one file out (see `writeVector`).
    public static func writer(_ id: EngineID, to format: FormatID, singlePage: Bool, textAsOutlinesDefault: Bool = false,
                              write: @escaping @Sendable (VectorDocument, VectorWriteOptions) throws -> VectorWriteResult) -> VectorConverter {
        VectorConverter(id: id, handles: [StepPattern(from: .model(.vectorDocument), to: .formats([format]))]) { _, input, context in
            try writeVector(input, context, to: format, singlePage: singlePage, textAsOutlinesDefault: textAsOutlinesDefault, write: write)
        }
    }

    /// The vector half of a writer step: the O-VEC page selection, then the write. `singlePage` formats write the first
    /// selected page and say so.
    public static func writeVector(_ input: StepValue, _ context: StepContext, to format: FormatID, singlePage: Bool, textAsOutlinesDefault: Bool = false,
                                   write: (VectorDocument, VectorWriteOptions) throws -> VectorWriteResult) throws -> StepOutput {
        var document = try vector(input)
        let options = VectorWriteOptions(context.options, title: context.source.deletingPathExtension().lastPathComponent,
                                         textAsOutlinesDefault: textAsOutlinesDefault)
        document = document.selecting(options.pages)
        var notes: [LossNote] = []
        if singlePage, document.pages.count > 1 {
            notes.append(LossNote(.otherLoss, detail: "\(format.rawValue.uppercased()) holds one page; page 1 of \(document.pages.count) was written. Pick pages to choose another."))
            document.pages = [document.pages[0]]
        }
        if document.pages.isEmpty { throw ConversionError.failed("There are no pages to write.") }
        let result = try write(document, options)
        return StepOutput(.file(try save(result.data, context, format.rawValue)), lossNotes: notes + result.lossNotes)
    }

    /// Writes a step's bytes to a new file in the work folder.
    public static func save(_ data: Data, _ context: StepContext, _ pathExtension: String) throws -> URL {
        let url = output(context, pathExtension)
        do { try data.write(to: url, options: .atomic) } catch { throw ConversionError.folderNotWritable(name: context.workFolder.lastPathComponent) }
        return url
    }
}
