import Darwin
import Foundation
import SuperConverterCore

/// ux §6.3: same name, new extension, in the chosen place (next to the original; Downloads when that folder isn't
/// writable); collisions add " 2", " 3" and nothing is ever overwritten (the "Replace" setting never replaces the source
/// itself); several files go into a folder "<name> (<FORMAT>)"; creation and modification dates come from the source;
/// results appear under their final name only when complete.
@MainActor
public final class OutputRules: OutputPolicy {
    private let collisionPolicy: () -> CollisionPolicy
    private let downloads: URL
    private let fileManager = FileManager.default

    public init(collisionPolicy: @escaping () -> CollisionPolicy = { Defaults[.collisionPolicy] },
                downloads: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]) {
        self.collisionPolicy = collisionPolicy
        self.downloads = downloads
    }

    // MARK: OutputPolicy

    public func target(for source: URL, format: FormatID, place: OutputPlace, multipleFiles: Bool) throws -> OutputTarget {
        var folder = Self.folder(for: place, source: source, downloads: downloads)
        var fellBack = false
        if !isWritable(folder, create: { if case .folder = place { true } else { false } }()) {
            guard !Self.sameFolder(folder, downloads), isWritable(downloads, create: false) else {
                throw ConversionError.folderNotWritable(name: folder.lastPathComponent)
            }
            folder = downloads
            fellBack = true
        }
        let base = Self.baseName(of: source)
        let name = multipleFiles ? "\(base) (\(format.pill))" : "\(base).\(format.rawValue)"
        let url = available(folder.appendingPathComponent(name, isDirectory: multipleFiles), isFolder: multipleFiles, source: source)
        return OutputTarget(url: url, isFolder: multipleFiles, fellBackToDownloads: fellBack)
    }

    public func partName(base: String, kind: String, index: Int, format: FormatID) -> String {
        "\(base) – \(kind) \(index).\(format.rawValue)"
    }

    public func place(_ results: [URL], for source: URL, into target: OutputTarget) throws -> [URL] {
        let dates = try? fileManager.attributesOfItem(atPath: source.path)
        let hidden = target.url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        do {
            if target.isFolder {
                try fileManager.createDirectory(at: hidden, withIntermediateDirectories: false)
                for file in results {
                    let destination = hidden.appendingPathComponent(file.lastPathComponent)
                    try fileManager.moveItem(at: file, to: destination)
                    Self.copyDates(dates, to: destination)
                }
            } else {
                guard results.count == 1, let file = results.first else { throw ConversionError.failed("A single file was expected") }
                try fileManager.moveItem(at: file, to: hidden)
                Self.copyDates(dates, to: hidden)
            }
            let final = try publish(hidden, as: target.url, source: source)
            let placed = target.isFolder
                ? (try fileManager.contentsOfDirectory(atPath: final.path)
                    .filter { !$0.hasPrefix(".") }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    .map { final.appendingPathComponent($0) })
                : [final]
            if target.isFolder { Self.copyDates(dates, to: final) }   // after the files went in: adding them touched the folder
            return placed
        } catch {
            try? fileManager.removeItem(at: hidden)
            throw Self.map(error, folder: target.url.deletingLastPathComponent())
        }
    }

    // MARK: Names

    /// "Report" for `Report.docx`, "archive" for `archive.tar.gz` (the longest known extension goes).
    static func baseName(of source: URL) -> String {
        let name = source.lastPathComponent
        if let format = FormatCatalog.format(forFileName: name), name.lowercased().hasSuffix("." + format.id.rawValue) {
            return String(name.dropLast(format.id.rawValue.count + 1))
        }
        return source.deletingPathExtension().lastPathComponent
    }

    private static func folder(for place: OutputPlace, source: URL, downloads: URL) -> URL {
        switch place {
        case .nextToOriginal: source.deletingLastPathComponent()
        case .downloads: downloads
        case .folder(let url): url
        }
    }

    private static func sameFolder(_ a: URL, _ b: URL) -> Bool { a.standardizedFileURL.path == b.standardizedFileURL.path }

    /// "Report 2.pdf", "Report 3.pdf" (Finder's style); "Report (PDF) 2" for folders.
    private static func numbered(_ url: URL, _ n: Int, isFolder: Bool) -> URL {
        let ext = isFolder ? "" : url.pathExtension
        let stem = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let name = "\(stem) \(n)" + (ext.isEmpty ? "" : "." + ext)
        return url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: isFolder)
    }

    /// The first name that is free, or (policy "Replace") the wanted name unless it is the source itself.
    private func available(_ wanted: URL, isFolder: Bool, source: URL) -> URL {
        let isSource = { (url: URL) in Self.sameFolder(url, source) }
        if collisionPolicy() == .replace, !isSource(wanted) { return wanted }
        var candidate = wanted
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) || isSource(candidate) {
            candidate = Self.numbered(wanted, n, isFolder: isFolder)
            n += 1
        }
        return candidate
    }

    // MARK: Writing

    private func isWritable(_ folder: URL, create: Bool) -> Bool {
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) {
            guard create else { return false }
            return (try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        }
        return isDirectory.boolValue && fileManager.isWritableFile(atPath: folder.path)
    }

    /// Renames the finished (hidden) result to its final name. A name taken since `target` was asked is never overwritten:
    /// "Add a number" tries the next one; "Replace" swaps the earlier result atomically.
    private func publish(_ hidden: URL, as wanted: URL, source: URL) throws -> URL {
        let isFolder = (try? hidden.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if collisionPolicy() == .replace, !Self.sameFolder(wanted, source), fileManager.fileExists(atPath: wanted.path) {
            _ = try fileManager.replaceItemAt(wanted, withItemAt: hidden)
            return wanted
        }
        var candidate = wanted
        var n = 2
        while true {
            if !Self.sameFolder(candidate, source) {
                if renamex_np(hidden.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
                if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
            candidate = Self.numbered(wanted, n, isFolder: isFolder)
            n += 1
        }
    }

    private static func copyDates(_ attributes: [FileAttributeKey: Any]?, to url: URL) {
        var wanted: [FileAttributeKey: Any] = [:]
        if let created = attributes?[.creationDate] { wanted[.creationDate] = created }
        if let modified = attributes?[.modificationDate] { wanted[.modificationDate] = modified }
        if !wanted.isEmpty { try? FileManager.default.setAttributes(wanted, ofItemAtPath: url.path) }
    }

    private static func map(_ error: Error, folder: URL) -> Error {
        if error is ConversionError { return error }
        switch (error as? POSIXError)?.code {
        case .EACCES?, .EPERM?, .EROFS?: return ConversionError.folderNotWritable(name: folder.lastPathComponent)
        case .ENOSPC?: return ConversionError.notEnoughSpace(volume: volumeName(of: folder), needed: 0)
        default: break
        }
        switch (error as? CocoaError)?.code {
        case .fileWriteNoPermission, .fileWriteVolumeReadOnly: return ConversionError.folderNotWritable(name: folder.lastPathComponent)
        case .fileWriteOutOfSpace: return ConversionError.notEnoughSpace(volume: volumeName(of: folder), needed: 0)
        default: return error
        }
    }

    /// "Macintosh HD": the name of the volume that holds `url`.
    nonisolated static func volumeName(of url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
    }
}
