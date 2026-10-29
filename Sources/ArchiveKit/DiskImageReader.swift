import Foundation
import SuperConverterCore

/// Apple disk images (DMG) through `hdiutil attach -readonly -nobrowse` (formats §3.1): mounted privately, copied out through
/// the same safety rules as any archive, and detached. The Finder never sees the volume. hdiutil runs through HelperKit's
/// runner (`Services.tools`) with the mount folder as its only writable place besides its scratch folder.
enum DiskImageReader {
    static func isAvailable(_ tools: (any ToolRunning)?) -> Bool { tools?.location(of: .hdiutil) != nil }

    static func read(_ request: ArchiveReadRequest) async throws -> ArchiveTree {
        let scratch = request.root.deletingLastPathComponent().appendingPathComponent(".dmg-\(UUID().uuidString)")
        let mounts = scratch.appendingPathComponent("mounts")
        try FileManager.default.createDirectory(at: mounts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // The password (if any) goes on standard input; without `-stdinpass` hdiutil would ask on a terminal.
        let attach = try await ToolCall.run(request.tools, .hdiutil, ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-noautofsck",
                                                                      "-mountrandom", mounts.path, "-stdinpass", "-plist", request.source.path],
                                            scratch: scratch.appendingPathComponent("tmp"), writable: [mounts],
                                            input: Data((request.password ?? "").utf8), timeLimit: 300, isCancelled: request.isCancelled)
        let volumes = mountPoints(in: Data(attach.standardOutput.utf8))
        do {
            guard attach.exitCode == 0 else {
                let text = attach.standardError + attach.standardOutput
                if text.contains("Authentication error") || text.contains("passphrase") { throw ArchiveError.passwordRequired }
                throw ArchiveError.unsupported("This disk image couldn’t be opened.")
            }
            guard !volumes.isEmpty else { throw ArchiveError.unsupported("This disk image has no volume to read.") }

            let extractor = try request.extractor()
            for (n, volume) in volumes.enumerated() {
                let prefix = volumes.count > 1 ? volume.lastPathComponent + "/" : ""
                request.report(StepProgress(fraction: Double(n) / Double(volumes.count), unit: nil))
                try copy(volume, prefix: prefix, into: extractor, request: request)
            }
            await detach(volumes, tools: request.tools, scratch: scratch, mounts: mounts)
            request.report(StepProgress(fraction: 1, unit: nil))
            return extractor.finish(wasEncrypted: request.password != nil)
        } catch {
            await detach(volumes, tools: request.tools, scratch: scratch, mounts: mounts)
            throw error
        }
    }

    private static func mountPoints(in plist: Data) -> [URL] {
        guard let object = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let entities = object["system-entities"] as? [[String: Any]] else { return [] }
        return entities.compactMap { ($0["mount-point"] as? String).map { URL(fileURLWithPath: $0) } }
    }

    /// Detaches every mounted volume, forcing when a polite detach fails. It runs in a task of its own, so a cancelled job
    /// still leaves nothing mounted.
    private static func detach(_ volumes: [URL], tools: (any ToolRunning)?, scratch: URL, mounts: URL) async {
        await Task.detached {
            for volume in volumes {
                for force in [false, true] {
                    let result = try? await ToolCall.run(tools, .hdiutil, ["detach", volume.path] + (force ? ["-force"] : []),
                                                         scratch: scratch.appendingPathComponent("tmp"), writable: [mounts], timeLimit: 60,
                                                         isCancelled: { false })
                    if result?.exitCode == 0 { break }
                }
            }
        }.value
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
