import Foundation
import SuperConverterCore

/// `SoundFontReader` (formats §3.2, O-SF2): SF2 → one WAV (or FLAC, through the bundled FFmpeg) per sample with an SFZ map
/// per preset, as a folder (several files go into a "name (FORMAT)" folder, ux §6.3) or, for ZIP, as an `ArchiveTree` that
/// ArchiveKit packs.
struct SoundFontConverter: Converter {
    let tools: MediaTools
    var id: EngineID { .soundFontReader }

    var handles: [StepPattern] {
        [StepPattern(from: .formats(["sf2"]), to: .formats(["wav", "flac", "sfz"])),
         StepPattern(from: .formats(["sf2"]), to: .model(.archiveTree))]
    }

    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        guard case .file(let url) = input else { throw ConversionError.impossiblePair(reason: "A SoundFont file was expected here.") }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.damaged("sf2") }
        let font = try SoundFont.read(data)
        let o = context.options
        var writer = SFZWriter(font: font)
        writer.folderPerPreset = o["folders"]?.bool ?? true
        let sampleFormat = o["sampleFormat"]?.string == "flac" ? "flac" : "wav"
        let base = context.source.deletingPathExtension().lastPathComponent
        let root = context.workFolder.appendingPathComponent("sf2-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let folder = root.appendingPathComponent(base, isDirectory: true)
        context.report(StepProgress(fraction: nil, unit: "\(font.samples.count) samples"))
        func write() async throws -> SFZWriter.Result {
            try await writer.write(into: folder, tools: tools, workFolder: context.workFolder, isCancelled: context.isCancelled)
        }
        switch step.to {
        case .model(.archiveTree):
            writer.sampleFormat = sampleFormat
            writer.writeMap = o["sfzMap"]?.bool ?? true
            return StepOutput(.archive(Self.tree(try await write(), root: root)))
        case .format("sfz"):
            writer.sampleFormat = sampleFormat
            writer.writeMap = true
            return StepOutput(.file(try await write().folder))
        case .format(let target):
            writer.sampleFormat = target.rawValue
            writer.writeMap = false
            return StepOutput(.file(try await write().folder))
        default:
            throw ConversionError.unsupportedPair(from: context.sourceFormat, to: context.targetFormat)
        }
    }

    /// The written folder as archive entries (folders first), paths relative to `root`.
    static func tree(_ result: SFZWriter.Result, root: URL) -> ArchiveTree {
        var entries: [ArchiveTree.Entry] = []
        var dirs = Set<String>()
        let rootPath = root.standardizedFileURL.path + "/"
        for file in result.files.sorted(by: { $0.path < $1.path }) {
            let path = String(file.standardizedFileURL.path.dropFirst(rootPath.count))
            var parts = path.split(separator: "/").dropLast().map(String.init)
            var prefix = ""
            while !parts.isEmpty {
                prefix += (prefix.isEmpty ? "" : "/") + parts.removeFirst()
                if dirs.insert(prefix).inserted { entries.append(ArchiveTree.Entry(path: prefix, kind: .directory, permissions: 0o755)) }
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
            entries.append(ArchiveTree.Entry(path: path, kind: .file, size: size, modified: Date(), extracted: file))
        }
        return ArchiveTree(entries: entries, root: root)
    }
}
