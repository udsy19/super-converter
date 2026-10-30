import AppKit
import Foundation
import SuperConverterCore

/// One DocKit engine as a `Converter`: the engine id the matrix uses, the (from, to) kinds it handles, and what it does. The
/// engines are small and share this shape, so a table of them (`DocKitConverters.all`) replaces twenty one-off types.
struct DocConverter: Converter {
    let id: EngineID
    let handles: [StepPattern]
    let body: @Sendable (Step, StepValue, StepContext) async throws -> StepOutput

    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        if context.isCancelled() { throw ConversionError.cancelled }
        do {
            let output = try await body(step, input, context)
            if context.isCancelled() { throw ConversionError.cancelled }
            return output
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.failed("The file couldn’t be converted: \(error.localizedDescription)")
        }
    }
}

enum DocKitConverters {
    private static func formats(_ ids: FormatID...) -> StepPattern.End { .formats(Set(ids)) }
    private static let doc = StepPattern.End.model(.docModel)

    /// The file a step reads: its input value, or the dropped file for the first step.
    private static func file(_ input: StepValue, _ context: StepContext) throws -> URL {
        if case .file(let url) = input { return url }
        throw ConversionError.failed("This step needs a file.")
    }

    /// The main thread's stack size, for `onLargeStack`.
    static let largeStack = 8 << 20

    /// Runs a reader or writer on a thread of its own with the main thread's stack. Documents nest (quotes, lists, tables,
    /// maths, XML elements) and the readers and writers recurse once per level, up to their depth limits; the job runner's
    /// worker threads have a 512 KB stack, which those limits overflow, so a damaged or merely deep file would crash the app.
    static func onLargeStack<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { continuation.resume(with: Result(catching: work)) }
            thread.stackSize = largeStack
            thread.start()
        }
    }

    /// Where a writer puts its output: the work folder, named after the source.
    static func output(_ context: StepContext, _ step: Step) -> URL {
        let base = context.source.deletingPathExtension().lastPathComponent
        let ext: String
        if case .format(let f) = step.to { ext = f.rawValue } else { ext = context.targetFormat.rawValue }
        return context.workFolder.appendingPathComponent(base + "." + ext)
    }

    private static func reader(_ id: EngineID, _ from: [FormatID], _ read: @escaping @Sendable (URL, DocReadOptions) throws -> DocReadResult) -> DocConverter {
        DocConverter(id: id, handles: [StepPattern(from: .formats(Set(from)), to: doc)]) { _, input, context in
            let url = try file(input, context), options = DocReadOptions(context.options)
            return try await onLargeStack {
                let result = try read(url, options)
                return StepOutput(.doc(result.model), lossNotes: result.lossNotes)
            }
        }
    }

    private static func textWriter(_ id: EngineID, _ to: FormatID, _ write: @escaping @Sendable (DocModel, DocWriteOptions, URL) throws -> [LossNote]) -> DocConverter {
        DocConverter(id: id, handles: [StepPattern(from: doc, to: .formats([to]))]) { step, input, context in
            guard case .doc(let model) = input else { throw ConversionError.failed("This step needs a document.") }
            let url = output(context, step), options = DocWriteOptions(context.options)
            do {
                return try await onLargeStack { StepOutput(.file(url), lossNotes: try write(model, options, url)) }
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        }
    }

    static let all: [DocConverter] = [
        reader(.docxReader, ["docx", "docm", "dotx"]) { try DOCXReader.read($0, options: $1) },
        reader(.odtReader, ["odt"]) { try ODTReader.read($0, options: $1) },
        reader(.markdownReader, ["md"]) { try MarkdownReader.read($0, options: $1) },
        reader(.plainTextReader, ["txt"]) { try PlainTextReader.read($0, options: $1) },
        reader(.abiWordReader, ["abw", "zabw"]) { try AbiWordReader.read($0, options: $1) },
        reader(.hwpReader, ["hwp"]) { try HWPReader.read($0, options: $1) },
        reader(.hwpxReader, ["hwpx"]) { try HWPXReader.read($0, options: $1) },

        // HTML is a document, or the single chapter of a publication (HTML → e-book).
        DocConverter(id: .htmlReader, handles: [StepPattern(from: formats("html", "htm"), to: doc),
                                                StepPattern(from: formats("html", "htm"), to: .model(.publication))]) { step, input, context in
            let url = try file(input, context), options = DocReadOptions(context.options), toPublication = step.to == .publication
            return try await onLargeStack {
                let result = try HTMLReader.read(url, options: options)
                return StepOutput(toPublication ? .publication(publication(result.model)) : .doc(result.model), lossNotes: result.lossNotes)
            }
        },

        // E-mail is a document, or its attachments as an archive tree (EML → ZIP).
        DocConverter(id: .mailReader, handles: [StepPattern(from: formats("eml"), to: doc), StepPattern(from: formats("eml"), to: .model(.archiveTree))]) { step, input, context in
            let url = try file(input, context), options = DocReadOptions(context.options)
            if step.to == .archiveTree {
                let folder = context.workFolder.appendingPathComponent("attachments", isDirectory: true)
                return try await onLargeStack { StepOutput(.archive(try MailReader.attachments(url, into: folder))) }
            }
            return try await onLargeStack {
                let result = try MailReader.read(url, options: options)
                return StepOutput(.doc(result.model), lossNotes: result.lossNotes)
            }
        },

        // RTF and Word 97 through TextKit (main thread).
        DocConverter(id: .textKitImport, handles: [StepPattern(from: formats("rtf", "doc", "dot"), to: doc)]) { step, input, context in
            let url = try file(input, context)
            let format: FormatID = { if case .format(let f) = step.from { f } else { context.sourceFormat } }()
            let result = try await MainActor.run { try TextKitImport.read(url, format: format) }
            return StepOutput(.doc(result.model), lossNotes: result.lossNotes)
        },
        DocConverter(id: .textKitExport, handles: [StepPattern(from: doc, to: formats("rtf", "doc"))]) { step, input, context in
            guard case .doc(let model) = input else { throw ConversionError.failed("This step needs a document.") }
            let url = output(context, step)
            let format = context.targetFormat
            do {
                let notes = try await MainActor.run { try TextKitExport.write(model, format: format, to: url) }
                return StepOutput(.file(url), lossNotes: notes)
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        },

        textWriter(.docxWriter, "docx") { model, _, url in try DOCXWriter.write(model, to: url) },
        textWriter(.odtWriter, "odt") { model, _, url in try ODTWriter.write(model, to: url) },
        textWriter(.markdownWriter, "md") { try MarkdownWriter.write($0, options: $1, to: $2) },
        textWriter(.rstWriter, "rst") { try RSTWriter.write($0, options: $1, to: $2) },
        textWriter(.latexWriter, "tex") { try LaTeXWriter.write($0, options: $1, to: $2) },
        textWriter(.textWriter, "txt") { try TextWriter.write($0, options: $1, to: $2) },

        // HTML out of documents, PDF layouts, slides and spreadsheets.
        DocConverter(id: .htmlWriter, handles: [StepPattern(from: doc, to: formats("html")), StepPattern(from: .model(.layoutDocument), to: formats("html")),
                                                StepPattern(from: .model(.vectorDocument), to: formats("html")), StepPattern(from: .model(.workbook), to: formats("html"))]) { step, input, context in
            let options = DocWriteOptions(context.options)
            let url = output(context, step)
            let folder = url.deletingPathExtension().lastPathComponent + " files"
            let title = context.source.deletingPathExtension().lastPathComponent, positioned = context.options["mode"]?.string == "positioned"
            return try await onLargeStack {
                let rendered: HTMLWriter.Output
                switch input {
                case .doc(let model): rendered = HTMLWriter.render(model, embedImages: options.embedImages, filesFolder: folder)
                case .layout(let layout):
                    rendered = positioned ? HTMLSources.positioned(layout, title: title)
                                          : HTMLSources.reflowed(layout, title: title, embedImages: options.embedImages, filesFolder: folder)
                case .vector(let vector): rendered = HTMLSources.slides(vector)
                case .workbook(let workbook): rendered = HTMLSources.workbook(workbook)
                default: throw ConversionError.failed("This step needs a document.")
                }
                do { try HTMLWriter.writeOutput(rendered, options: options, to: url) } catch { try? FileManager.default.removeItem(at: url); throw error }
                return StepOutput(.file(url), lossNotes: rendered.lossNotes)
            }
        },

        // HTML as a web page.
        DocConverter(id: .webKitPrint, handles: [StepPattern(from: formats("html", "htm"), to: formats("pdf"))]) { step, input, context in
            let page = try file(input, context)
            let url = output(context, step)
            let options = WebKitRender.PrintOptions(context.options)
            let cancelled = context.isCancelled
            do { try await WebKitRender.printPDF(page, options: options, to: url, isCancelled: cancelled) } catch { try? FileManager.default.removeItem(at: url); throw error }
            return StepOutput(.file(url))
        },
        DocConverter(id: .webKitSnapshot, handles: [StepPattern(from: formats("html", "htm"), to: formats("png", "jpg"))]) { step, input, context in
            let page = try file(input, context)
            let url = output(context, step)
            let options = WebKitRender.SnapshotOptions(context.options)
            let format = context.targetFormat
            let cancelled = context.isCancelled
            do { try await WebKitRender.snapshot(page, options: options, format: format, to: url, isCancelled: cancelled) } catch { try? FileManager.default.removeItem(at: url); throw error }
            return StepOutput(.file(url))
        },
    ]

    /// A single-chapter publication: the document is the only spine item and its headings are the contents.
    static func publication(_ model: DocModel) -> Publication {
        let headings = model.blocks.compactMap { block -> (Int, String)? in
            if case .heading(let level, let text) = block { (level, Inlines.plain(text)) } else { nil }
        }
        let top = headings.map(\.0).min() ?? 1
        let contents = headings.filter { $0.0 == top }.map { ContentsEntry(title: $0.1, itemID: "content") }
        return Publication(metadata: model.metadata, spine: [PublicationItem(id: "content", title: model.metadata.title, content: .document(model))], contents: contents)
    }
}
