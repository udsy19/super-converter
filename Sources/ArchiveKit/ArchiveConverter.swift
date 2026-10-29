import Foundation
import SuperConverterCore

/// One archive engine of `format-matrix.json` (libarchive, 7zz, hdiutil, unalz, ACEKit, ARCKit, LZOKit, RZipKit and the
/// ArchiveKit writer for SoundFont ZIPs) as a `Converter`. What it handles is read from the matrix itself, so the two
/// cannot drift apart: a step that reads a format into an `ArchiveTree`, or writes a tree as a format.
final class ArchiveConverter: Converter {
    let id: EngineID
    let handles: [StepPattern]
    /// HelperKit's runner for 7zz and hdiutil (`Services.tools`); nil leaves those two unavailable.
    let tools: (any ToolRunning)?

    /// The archive engines this module registers (`EngineID.info.module == .archiveKit`).
    static let engines: [EngineID] = EngineID.allCases.filter { $0.info.module == .archiveKit }

    init(_ id: EngineID, tools: (any ToolRunning)?) {
        self.id = id
        self.tools = tools
        var reads = Set<FormatID>(), writes = Set<FormatID>()
        for route in FormatMatrix.routes {
            for step in (route.builtin ?? []) + (route.helper ?? []) + route.alternates.flatMap(\.steps) where step.engine == id {
                if case .format(let format) = step.from, step.to == .archiveTree { reads.insert(format) }
                if step.from == .archiveTree, case .format(let format) = step.to { writes.insert(format) }
            }
        }
        var patterns: [StepPattern] = []
        if !reads.isEmpty { patterns.append(StepPattern(from: .formats(reads), to: .model(.archiveTree))) }
        if !writes.isEmpty { patterns.append(StepPattern(from: .model(.archiveTree), to: .formats(writes))) }
        handles = patterns
    }

    func availability() -> EngineAvailability {
        switch id {
        case .sevenZip: SevenZip.isAvailable(tools) ? .available : .unavailable("7-Zip isn’t part of this build.")
        case .hdiutil: DiskImageReader.isAvailable(tools) ? .available : .unavailable("Disk images can’t be opened on this Mac.")
        default: .available
        }
    }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        do {
            if case .model(.archiveTree) = step.to {
                guard case .file(let url) = input, case .format(let format) = step.from else { throw ConversionError.failed("This step needs an archive file.") }
                return try await read(url, format: format, context: context)
            }
            guard case .archive(let tree) = input, case .format(let format) = step.to else { throw ConversionError.failed("This step needs the unpacked archive.") }
            return try await write(tree, format: format, context: context)
        } catch let error as ArchiveError {
            let format: FormatID
            if case .format(let f) = step.from { format = f } else { format = context.sourceFormat }
            throw error.conversionError(for: format)
        }
    }

    // MARK: Steps

    private func read(_ url: URL, format: FormatID, context: StepContext) async throws -> StepOutput {
        let options = context.options
        let request = ArchiveReadRequest(
            source: url, format: format, root: context.workFolder.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true),
            password: options["password"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            nameEncoding: NameEncoding(option: options["nameEncoding"]?.string),
            unpackPayload: options["unpackPayload"]?.bool ?? true, tools: tools,
            report: context.report, isCancelled: context.isCancelled)
        let tree = try await Archives.read(request, engine: id)
        return StepOutput(.archive(tree), lossNotes: request.diagnostics.lossNotes)
    }

    private func write(_ tree: ArchiveTree, format: FormatID, context: StepContext) async throws -> StepOutput {
        let options = context.options
        let password = options["newPassword"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let keepMacExtras = options["keepMacExtras"]?.bool ?? false
        let splitMegabytes = options["split"]?.string.flatMap(Int64.init) ?? options["split"]?.int.map(Int64.init)
        let request = ArchiveWriteRequest(
            tree: tree, format: format,
            destination: context.workFolder.appendingPathComponent(outputName(for: context.source, format: format)),
            compression: ArchiveWriteRequest.Compression(rawValue: options["compression"]?.string ?? "") ?? .normal,
            password: password, compatibleZip: options["compatibleZip"]?.bool ?? false, keepMacExtras: keepMacExtras,
            splitBytes: splitMegabytes.map { $0 << 20 }, workFolder: context.workFolder, tools: tools,
            report: context.report, isCancelled: context.isCancelled)

        var notes: [LossNote] = []
        if tree.wasEncrypted && password == nil { notes.append(LossNote(.encryptionRemoved)) }
        let extras = keepMacExtras ? 0 : tree.entries.filter { ArchivePath.isMacExtra($0.path) }.count
        if extras > 0 {
            notes.append(LossNote(.otherLoss, detail: Formatting.count(extras, "Mac system file (._ files, .DS_Store) was left out", "Mac system files (._ files, .DS_Store) were left out")))
        }
        let output = try await Archives.write(request)
        return StepOutput(.file(output), lossNotes: notes)
    }

    /// `photos.tar.gz` → `photos.zip`: the source name without its archive extension, plus the target's.
    private func outputName(for source: URL, format: FormatID) -> String {
        var name = source.lastPathComponent
        let lower = name.lowercased()
        let known = FormatCatalog.all.filter { $0.category == .archive }.map(\.id.rawValue).sorted { $0.count > $1.count }
        if let ext = known.first(where: { lower.hasSuffix("." + $0) && lower.count > $0.count + 1 }) {
            name = String(name.dropLast(ext.count + 1))
        } else if !source.pathExtension.isEmpty, name.count > source.pathExtension.count + 1 {
            name = String(name.dropLast(source.pathExtension.count + 1))
        }
        return name + "." + format.rawValue
    }
}
