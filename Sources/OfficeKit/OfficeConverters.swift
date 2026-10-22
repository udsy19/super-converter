import Foundation
import SuperConverterCore

// OfficeKit's converters (ARCHITECTURE §4, §6): one per engine id `format-matrix.json` names for this module. Each is data
// (the kinds of step it handles) plus a body that reads its input, does the work and returns a model or a file in the
// job's work folder. None needs a helper: the LibreOffice and Numbers routes around them belong to HelperKit.

struct OfficeConverter: Converter {
    let id: EngineID
    let handles: [StepPattern]
    let body: @Sendable (Step, StepValue, StepContext) throws -> StepOutput

    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        if context.isCancelled() { throw ConversionError.cancelled }
        return try body(step, input, context)
    }
}

enum OfficeConverters {
    private static func file(_ formats: FormatID...) -> StepPattern.End { .formats(Set(formats)) }

    static let all: [OfficeConverter] = [
        OfficeConverter(id: .csvReader, handles: [StepPattern(from: .formats(["csv"]), to: .model(.workbook))]) { step, input, context in
            let data = try readData(input)
            return StepOutput(.workbook(CSVReader.read(data, sheetName: sheetName(context.source))))
        },
        OfficeConverter(id: .csvWriter, handles: [StepPattern(from: .model(.workbook), to: .formats(["csv"]))]) { step, input, context in
            let workbook = try select(try workbook(input), context)
            return try writeCSV(workbook, context)
        },
        OfficeConverter(id: .xlsxReader, handles: [StepPattern(from: file("xlsx", "xlsm"), to: .model(.workbook))]) { step, input, context in
            let result = try XLSXReader.read(try fileURL(input))
            return StepOutput(.workbook(result.workbook), lossNotes: result.lossNotes, warnings: result.warnings)
        },
        OfficeConverter(id: .xlsxWriter, handles: [StepPattern(from: .model(.workbook), to: .formats(["xlsx"]))]) { step, input, context in
            let workbook = try select(try workbook(input), context)
            let keep = keepsFormulas(context)
            var workbookToWrite = workbook
            if workbook.title == nil { workbookToWrite.title = sheetName(context.source) }
            let url = try output(context, "xlsx")
            try XLSXWriter.write(workbookToWrite, keepFormulas: keep).write(to: url, options: .atomic)
            return StepOutput(.file(url), lossNotes: formulaLoss(workbook, keep: keep))
        },
        OfficeConverter(id: .odsReader, handles: [StepPattern(from: .formats(["ods"]), to: .model(.workbook))]) { step, input, context in
            let result = try ODSReader.read(try fileURL(input))
            return StepOutput(.workbook(result.workbook), lossNotes: result.lossNotes, warnings: result.warnings)
        },
        OfficeConverter(id: .odsWriter, handles: [StepPattern(from: .model(.workbook), to: .formats(["ods"]))]) { step, input, context in
            let workbook = try select(try workbook(input), context)
            let keep = keepsFormulas(context)
            let url = try output(context, "ods")
            try ODSWriter.write(workbook, keepFormulas: keep).write(to: url, options: .atomic)
            return StepOutput(.file(url), lossNotes: formulaLoss(workbook, keep: keep))
        },
        OfficeConverter(id: .xlsReader, handles: [StepPattern(from: .formats(["xls"]), to: .model(.workbook))]) { step, input, context in
            let result = try XLSReader.read(try fileURL(input))
            return StepOutput(.workbook(result.workbook), lossNotes: result.lossNotes, warnings: result.warnings)
        },
        OfficeConverter(id: .slideReader, handles: [StepPattern(from: file("pptx", "ppsx", "pptm"), to: .model(.docModel))]) { step, input, context in
            let result = try PPTXReader.read(try fileURL(input))
            let notes = context.options["notes"]?.string == "notesPages"
            let hidden = context.options["hiddenSlides"]?.bool ?? false
            return StepOutput(.doc(PPTXReader.docModel(result.deck, title: result.title, includeNotes: notes, includeHidden: hidden)),
                              lossNotes: result.lossNotes)
        },
        OfficeConverter(id: .slideRenderer, handles: [StepPattern(from: file("pptx", "potx", "ppsx", "pptm"), to: .formats(["pdf"]))]) { step, input, context in
            let deck = try SlideDeck(url: try fileURL(input))
            let url = try output(context, "pdf")
            let notes = try SlideRenderer(deck: deck).write(
                to: url, includeHidden: context.options["hiddenSlides"]?.bool ?? false,
                slideNumbers: PageRange.parse(context.options["pages"]?.string), isCancelled: context.isCancelled,
                progress: { context.report(StepProgress(fraction: Double($0) / Double(max($1, 1)), unit: "Slide \($0) of \($1)")) })
            return StepOutput(.file(url), lossNotes: notes)
        },
        OfficeConverter(id: .pptxWriter, handles: [StepPattern(from: .model(.deck), to: .formats(["pptx"]))]) { step, input, context in
            guard case .deck(let deck) = input else { throw ConversionError.impossiblePair(reason: "The slides weren’t handed over.") }
            let url = try output(context, "pptx")
            try PPTXWriter.write(deck, title: sheetName(context.source)).write(to: url, options: .atomic)
            return StepOutput(.file(url))
        },
        OfficeConverter(id: .odfReader, handles: [StepPattern(from: .formats(["odd"]), to: .model(.imageAsset))]) { step, input, context in
            let result = try ODFPicture.read(try fileURL(input))
            return StepOutput(.image(result.image), lossNotes: result.lossNotes)
        },
        OfficeConverter(id: .odfWriter, handles: [StepPattern(from: .model(.imageAsset), to: .formats(["odd"]))]) { step, input, context in
            guard case .image(let image) = input else { throw ConversionError.impossiblePair(reason: "The picture wasn’t handed over.") }
            let url = try output(context, "odd")
            try ODFPicture.write(image, title: sheetName(context.source)).write(to: url, options: .atomic)
            return StepOutput(.file(url), lossNotes: image.frames.count > 1 ? [LossNote(.animationDropped)] : [])
        },
        OfficeConverter(id: .ooxmlRepackage, handles: [StepPattern(from: file("docm", "dotx", "potx", "ppsx", "pptm", "xlsm"), to: file("docx", "pptx", "xlsx"))]) { step, input, context in
            let source = try fileURL(input)
            let data: Data
            do { data = try Data(contentsOf: source, options: .mappedIfSafe) } catch { throw ConversionError.damaged(context.sourceFormat) }
            let result = try OOXMLRepackage.repackage(data)
            guard case .format(let target) = step.to else { throw ConversionError.impossiblePair(reason: "A file was expected here.") }
            let url = try output(context, target.rawValue)
            try result.data.write(to: url, options: .atomic)
            return StepOutput(.file(url), lossNotes: result.removedMacros ? [LossNote(.macrosDropped)] : [])
        },
    ]

    // MARK: Inputs and outputs

    private static func fileURL(_ input: StepValue) throws -> URL {
        guard case .file(let url) = input else { throw ConversionError.impossiblePair(reason: "A file was expected here.") }
        return url
    }

    private static func readData(_ input: StepValue) throws -> Data {
        let url = try fileURL(input)
        do { return try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.damaged(FormatID(url.pathExtension.lowercased())) }
    }

    private static func workbook(_ input: StepValue) throws -> Workbook {
        guard case .workbook(let workbook) = input else { throw ConversionError.impossiblePair(reason: "The spreadsheet wasn’t handed over.") }
        return workbook
    }

    /// The source's name without its extension: titles and sheet names.
    private static func sheetName(_ source: URL) -> String { source.deletingPathExtension().lastPathComponent }

    /// A new file in the work folder named after the source; an existing name gets a number.
    static func output(_ context: StepContext, _ pathExtension: String, suffix: String = "") throws -> URL {
        let stem = sheetName(context.source) + suffix
        var url = context.workFolder.appendingPathComponent(stem).appendingPathExtension(pathExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = context.workFolder.appendingPathComponent("\(stem) \(n)").appendingPathExtension(pathExtension)
            n += 1
        }
        return url
    }

    // MARK: Workbook options

    /// "Formulas: keep / values only" (O-SHEET-OUT); values only by default.
    private static func keepsFormulas(_ context: StepContext) -> Bool { context.options["formulas"]?.string == "keep" }

    private static func formulaLoss(_ workbook: Workbook, keep: Bool) -> [LossNote] {
        guard !keep, workbook.sheets.contains(where: { $0.rows.contains { $0.contains { $0.formula != nil } } }) else { return [] }
        return [LossNote(.otherLoss, detail: "Formulas were replaced by their values.")]
    }

    /// The "Sheets" option: "all", or sheet numbers and names ("1", "2-3", "Totals") separated by commas.
    private static func select(_ workbook: Workbook, _ context: StepContext) throws -> Workbook {
        guard let spec = context.options["sheet"]?.string?.trimmingCharacters(in: .whitespaces), !spec.isEmpty, spec.lowercased() != "all" else { return workbook }
        var chosen: [Int] = []
        for part in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if let index = workbook.sheets.firstIndex(where: { $0.name.caseInsensitiveCompare(part) == .orderedSame }) { chosen.append(index); continue }
            let bounds = part.split(separator: "-").compactMap { Int($0) }
            guard let low = bounds.first, bounds.count <= 2, low >= 1, (bounds.last ?? low) <= workbook.sheets.count, (bounds.last ?? low) >= low else {
                throw ConversionError.failed("There’s no sheet “\(part)” in this file.")
            }
            chosen += Array((low - 1)...((bounds.last ?? low) - 1))
        }
        var picked = workbook
        picked.sheets = chosen.reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }.map { workbook.sheets[$0] }
        return picked
    }

    private static func writeCSV(_ workbook: Workbook, _ context: StepContext) throws -> StepOutput {
        let options = CSVWriteOptions(context.options)
        let sheets = workbook.sheets.isEmpty ? [Sheet(name: "Sheet1")] : workbook.sheets
        if sheets.count == 1 || context.options["onePerSheet"]?.bool == false {
            // One file: the sheets one after another with a blank line between.
            let text = sheets.map { CSVWriter.text($0, options: options) }.joined(separator: "\r\n")
            let url = try output(context, "csv")
            try CSVWriter.encode(text, options.output).write(to: url, options: .atomic)
            return StepOutput(.file(url))
        }
        // One CSV per sheet, zipped.
        var zip = ZipWriter()
        let stem = sheetName(context.source)
        for (index, name) in XLSXWriter.sheetNames(sheets.map(\.name)).enumerated() {
            let safe = name.replacingOccurrences(of: "/", with: "-")
            zip.add("\(stem) - \(safe).csv", CSVWriter.data(sheets[index], options: options))
        }
        let url = try output(context, "zip")
        try zip.finish().write(to: url, options: .atomic)
        return StepOutput(.file(url), warnings: ["Each sheet is its own CSV file, in a ZIP."])
    }
}

/// "1-3,5" → {1, 2, 3, 5}; nil for an empty or unreadable range (every page).
enum PageRange {
    static func parse(_ text: String?) -> Set<Int>? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var pages: Set<Int> = []
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let low = bounds.first, low >= 1, bounds.count <= 2, (bounds.last ?? low) >= low, (bounds.last ?? low) < 100_000 else { return nil }
            pages.formUnion(low...(bounds.last ?? low))
        }
        return pages
    }
}
