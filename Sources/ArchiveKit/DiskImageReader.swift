import Foundation
import SuperConverterCore

/// Apple disk images (DMG) through `hdiutil attach -readonly -nobrowse` (formats §3.1): mounted privately, copied out through
/// the same safety rules as any archive, and detached. The Finder never sees the volume.
enum DiskImageReader {
    private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    static var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: hdiutil.path) }

    static func read(_ request: ArchiveReadRequest) throws -> ArchiveTree {
        guard isAvailable else { throw ArchiveError.toolMissing("hdiutil") }
        let scratch = request.root.deletingLastPathComponent().appendingPathComponent(".dmg-\(UUID().uuidString)")
        let mounts = scratch.appendingPathComponent("mounts")
        try FileManager.default.createDirectory(at: mounts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // The password (if any) goes on standard input; without `-stdinpass` hdiutil would ask on a terminal.
        let attach = try ToolRunner.run(hdiutil, arguments: ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-noautofsck",
                                                             "-mountrandom", mounts.path, "-stdinpass", "-plist", request.source.path],
                                        standardInput: Data((request.password ?? "").utf8), timeLimit: 300, scratch: scratch.appendingPathComponent("tmp"),
                                        isCancelled: request.isCancelled)
        guard attach.status == 0 else {
            let text = attach.standardError + attach.text
            if text.contains("Authentication error") || text.contains("passphrase") { throw ArchiveError.passwordRequired }
            throw ArchiveError.unsupported("This disk image couldn’t be opened.")
        }
        let volumes = mountPoints(in: attach.standardOutput)
        defer { for volume in volumes { detach(volume, scratch: scratch) } }
        guard !volumes.isEmpty else { throw ArchiveError.unsupported("This disk image has no volume to read.") }

        let extractor = try request.extractor()
        for (n, volume) in volumes.enumerated() {
            let prefix = volumes.count > 1 ? volume.lastPathComponent + "/" : ""
            request.report(StepProgress(fraction: Double(n) / Double(volumes.count), unit: nil))
            try copy(volume, prefix: prefix, into: extractor, request: request)
        }
        request.report(StepProgress(fraction: 1, unit: nil))
        return extractor.finish(wasEncrypted: request.password != nil)
    }

    private static func mountPoints(in plist: Data) -> [URL] {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let entities = object["system-entities"] as? [[String: Any]] else { return [] }
        return entities.compactMap { ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0) } }
    }

    private static func detach(_ volume: URL, scratch: URL) {
        for force in [false, true] {
            let result = try? ToolRunner.run(hdiutil, arguments: ["detach", volume.path] + (force ? ["-force"] : []), timeLimit: 60,
                                             scratch: scratch.appendingPathComponent("tmp"))
            if result?.status == 0 { return }
        }
    }

    private static func copy(_ volume: URL, prefix: String, into extractor: SafeExtractor, request: ArchiveReadRequest) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = fm.enumerator(at: volume, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return }
        let base = volume.standardizedFileURL.path
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        for case let url as URL in walker {
            if request.isCancelled() { throw ArchiveError.cancelled }
            let relative = String(url.standardizedFileURL.path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if ArchivePath.isVolumeLitter(relative) { walker.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let mode = ((try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? 0o644
            let path = prefix + relative
            if values.isSymbolicLink == true {
                try extractor.symlink(path, target: (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "", modified: values.contentModificationDate)
            } else if values.isDirectory == true {
                try extractor.directory(path, modified: values.contentModificationDate, permissions: mode)
            } else if values.isRegularFile == true {
                guard let input = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? input.close() }
                guard let sink = try extractor.file(path, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate, permissions: mode) else { continue }
                do {
                    while true {
                        let n = buffer.withUnsafeMutableBytes { Darwin.read(input.fileDescriptor, $0.baseAddress, $0.count) }
                        if n <= 0 { break }
                        try buffer.withUnsafeBytes { try sink.write(UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
                    }
                    try sink.close()
                } catch {
                    sink.abort()
                    throw error
                }
            }
        }
    }
}
