import CoreGraphics
import Foundation
import PDFKit
import RenderKit
import SuperConverterCore

/// `PDFOps` (formats §3): PDF → PDF. Page selection, split into one file per page, passwords and permissions (PDFKit's write
/// options), a PDF watermark above or below the pages, PDF/A-2b through RenderKit with a check afterwards, smaller pictures,
/// metadata removal. PDFKit objects are created and used inside one task and never cross threads.
public struct PDFOpsConverter: Converter {
    public let id: EngineID = .pdfOps
    public var handles: [StepPattern] { [StepPattern(from: .formats(["pdf"]), to: .formats(["pdf"]))] }
    public init() {}
    public func availability() -> EngineAvailability { .available }

    public func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        guard case .file(let url) = input else { throw ConversionError.failed("This step reads a PDF file.") }
        let settings = PDFOpsSettings(context.options)
        return try await Task.detached(priority: .userInitiated) {
            try Self.process(url, settings: settings, context: context)
        }.value
    }

    static func process(_ url: URL, settings: PDFOpsSettings, context: StepContext) throws -> StepOutput {
        guard let source = PDFDocument(url: url) else { throw ConversionError.damaged("pdf") }
        let wasEncrypted = source.isEncrypted
        if source.isLocked {
            guard let password = settings.openPassword, !password.isEmpty, source.unlock(withPassword: password) else { throw ConversionError.passwordRequired("pdf") }
        }
        let indices = PageSelection.indices(settings.pages, pageCount: source.pageCount)
        guard !indices.isEmpty else { throw ConversionError.failed("None of those pages are in this file.") }
        if settings.pdfA && settings.encryption == .encrypt { throw ConversionError.impossiblePair(reason: "PDF/A files can’t have a password.") }

        var lossNotes: [LossNote] = [], warnings: [String] = []
        let stem = (context.source.lastPathComponent as NSString).deletingPathExtension
        let groups = settings.splitPages ? indices.map { [$0] } : [indices]
        let folder = settings.splitPages && groups.count > 1 ? context.workFolder.appendingPathComponent("\(stem) pages", isDirectory: true) : context.workFolder
        if folder != context.workFolder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var written: [URL] = []

        for (n, group) in groups.enumerated() {
            if context.isCancelled() { for file in written { try? FileManager.default.removeItem(at: file) }; throw ConversionError.cancelled }
            context.report(StepProgress(fraction: Double(n) / Double(groups.count), unit: groups.count > 1 ? "File \(n + 1) of \(groups.count)" : nil))
            let name = groups.count > 1 ? "\(stem)-page-\(group[0] + 1).pdf" : "\(stem).pdf"
            let destination = folder.appendingPathComponent(name)
            var current: URL
            var temporary: [URL] = []
            defer { for file in temporary { try? FileManager.default.removeItem(at: file) } }

            // 1. The pages.
            let reuseSource = !wasEncrypted && group == Array(0..<source.pageCount)
            if reuseSource {
                current = url
            } else {
                // PDFKit writes a once-encrypted document encrypted again, so its pages are copied into a new one.
                let part = PDFDocument()
                for (i, index) in group.enumerated() { if let page = source.page(at: index)?.copy() as? PDFPage { part.insert(page, at: i) } }
                current = context.workFolder.appendingPathComponent("stage-\(UUID().uuidString).pdf")
                temporary.append(current)
                guard part.write(to: current) else { throw ConversionError.failed("The pages couldn’t be written.") }
            }
            // 2. Watermark.
            if let stamp = settings.watermark {
                let next = context.workFolder.appendingPathComponent("stage-\(UUID().uuidString).pdf")
                temporary.append(next)
                try Self.watermark(current, password: settings.openPassword, with: stamp, below: settings.watermarkBelow, to: next)
                current = next
                lossNotes.append(LossNote(.otherLoss, detail: "Links and bookmarks aren’t kept when a watermark is added"))
            }
            // 3. PDF/A, then 4. the final write with passwords and size options.
            if settings.pdfA {
                try PDFOutput.writePDFA(current, password: settings.openPassword, to: destination)
                let problems = PDFAVerifier.verify(try PDFPages.open(destination))
                warnings += problems.map(\.message)
            } else {
                guard let output = PDFDocument(url: current) else { throw ConversionError.damaged("pdf") }
                if output.isLocked { output.unlock(withPassword: settings.openPassword ?? "") }
                if settings.removeMetadata { output.documentAttributes = [:] }
                var options = settings.writeOptions(reopenWith: wasEncrypted ? settings.openPassword : nil)
                options[.saveImagesAsJPEGOption] = settings.makeSmaller != nil ? true : nil
                options[.optimizeImagesForScreenOption] = settings.makeSmaller == 150 ? true : nil
                guard output.write(to: destination, withOptions: options.compactMapValues { $0 }) else { throw ConversionError.failed("The PDF couldn’t be written.") }
            }
            written.append(destination)
        }
        if wasEncrypted && settings.encryption == .remove { lossNotes.append(LossNote(.encryptionRemoved)) }
        context.report(StepProgress(fraction: 1))
        return StepOutput(.file(groups.count > 1 && settings.splitPages ? folder : written[0]), lossNotes: lossNotes, warnings: warnings)
    }

    /// Draws every page of `source`, with the first page of `stamp` fitted over it (or under it).
    static func watermark(_ source: URL, password: String?, with stamp: URL, below: Bool, to destination: URL) throws {
        let document = try PDFPages.open(source, password: password)
        let mark = try PDFPages.open(stamp)
        guard let markPage = mark.page(at: 1) else { throw ConversionError.damaged("pdf") }
        var info = PDFPages.metadata(document)
        info[kCGPDFContextCreator] = info[kCGPDFContextCreator] ?? "Super Converter"
        let pages = try (0..<document.numberOfPages).map { index -> PDFWriter.Page in
            let page = try PDFPages.page(document, at: index)
            let size = PDFPages.displayedSize(page)
            return PDFWriter.Page(size: size) { context in
                let rect = CGRect(origin: .zero, size: size)
                if below { PDFPages.draw(markPage, in: context, fitting: rect) }
                PDFPages.draw(page, in: context, fitting: rect)
                if !below { PDFPages.draw(markPage, in: context, fitting: rect) }
            }
        }
        try PDFWriter.write(to: destination, info: info, pages: pages)
    }
}

/// The O-PDF-PDF options.
struct PDFOpsSettings {
    enum Encryption: String { case unchanged, remove, encrypt }

    var pages: String?
    var splitPages: Bool
    var openPassword: String?
    var encryption: Encryption
    var setPassword: String?
    var setOwnerPassword: String?
    var allowPrint: String
    var allowModify: String
    var allowExtract: Bool
    var allowAccessibility: Bool
    var watermark: URL?
    var watermarkBelow: Bool
    var pdfA: Bool
    var makeSmaller: Int?
    var removeMetadata: Bool

    init(_ o: OptionValues) {
        pages = o["pages"]?.string
        splitPages = o["splitPages"]?.bool ?? false
        openPassword = o["password"]?.string
        encryption = Encryption(rawValue: o["encryption"]?.string ?? "") ?? .unchanged
        setPassword = o["setPassword"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        setOwnerPassword = o["setOwnerPassword"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        allowPrint = o["allowPrint"]?.string ?? "full"
        allowModify = o["allowModify"]?.string ?? "all"
        allowExtract = o["allowExtract"]?.bool ?? true
        allowAccessibility = o["allowAccessibility"]?.bool ?? true
        watermark = o["watermarkImage"]?.string.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        watermarkBelow = o["watermarkLayer"]?.string == "below"
        pdfA = o["pdfA"]?.bool ?? false
        makeSmaller = Int(o["makeSmaller"]?.string ?? "")
        removeMetadata = o["removeMetadata"]?.bool ?? false
    }

    var restrictsPermissions: Bool { allowPrint != "full" || allowModify != "all" || !allowExtract || !allowAccessibility }

    func writeOptions(reopenWith password: String?) -> [PDFDocumentWriteOption: Any?] {
        var options: [PDFDocumentWriteOption: Any?] = [:]
        let userPassword: String?
        switch encryption {
        case .remove: userPassword = nil
        case .encrypt: userPassword = setPassword
        case .unchanged: userPassword = password
        }
        guard let userPassword else { return options }
        options[.userPasswordOption] = userPassword
        // Without an owner password, restricted files get a private one, so the restrictions hold for anyone opening the file.
        options[.ownerPasswordOption] = setOwnerPassword ?? (restrictsPermissions ? UUID().uuidString : userPassword)
        // PDFAccessPermissions bits: 1 low print, 2 high print, 4 changes, 8 assembly, 16 copying, 32 accessibility, 64 commenting, 128 forms.
        var permissions = 0
        if allowPrint != "none" { permissions |= 1 }
        if allowPrint == "full" { permissions |= 2 }
        switch allowModify {
        case "all": permissions |= 4 | 8 | 64 | 128
        case "annotate": permissions |= 64
        case "form": permissions |= 64 | 128
        case "assembly": permissions |= 8
        default: break
        }
        if allowExtract { permissions |= 16 }
        if allowAccessibility { permissions |= 32 }
        options[.accessPermissionsOption] = permissions
        return options
    }
}
