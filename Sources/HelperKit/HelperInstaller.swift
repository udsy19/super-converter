// Adapted from Super Flow Sources/UpdateKit/UpdateInstaller.swift (c1edfc4) by way of Sources/UpdateKit/UpdateInstaller.swift:
// streamed download, SHA-256 check, disk-image mount, signature check. Changed: pinned third-party releases instead of the
// app's own updates, zip and tar payloads for command-line helpers, copy into ~/Applications or Application Support.

import CryptoKit
import Foundation
import Security
import SuperConverterCore

enum HelperInstallError: Error, LocalizedError, Equatable {
    case noPin(HelperID)
    case http(Int)
    case checksumMismatch
    case badSignature(String)
    case notNotarised
    case payloadMissing(String)
    case tool(String)
    case notEnoughSpace(needed: Int64)

    var errorDescription: String? {
        switch self {
        case .noPin(let h): "There is no download for \(HelperCatalog.info(h).name) on this Mac."
        case .http(let code): "The download failed (server answered \(code))."
        case .checksumMismatch: "The download didn’t match its checksum, so it was thrown away."
        case .badSignature(let why): "The download isn’t signed by its publisher (\(why)), so it wasn’t installed."
        case .notNotarised: "Apple doesn’t vouch for this download, so it wasn’t installed."
        case .payloadMissing(let what): "The download didn’t contain \(what)."
        case .tool(let why): why
        case .notEnoughSpace(let needed): "There isn’t enough space (\(Formatting.bytes(needed)) needed)."
        }
    }
}

/// What one install produced.
struct InstalledHelper: Sendable {
    var version: String
    /// The executable (command-line helper) or the app copied to the applications folder.
    var path: URL
}

struct HelperInstaller: Sendable {
    typealias Fetch = @Sendable (_ url: URL, _ destination: URL, _ progress: @Sendable (Double) -> Void) async throws -> Void
    typealias VerifyApp = @Sendable (_ app: URL, _ teamID: String) throws -> Void

    var fetch: Fetch = HelperInstaller.download
    var verifyApp: VerifyApp = HelperInstaller.verifySignatureAndNotarisation
    /// Where apps go (`~/Applications`: no administrator password, visible like any app).
    var applicationsFolder: URL
    /// Where command-line helpers unpack: `Helpers/<id>/<version>/`.
    var helperFolder: @Sendable (HelperID, String) -> URL

    func install(_ pin: HelperPin, progress: @escaping @Sendable (InstallProgress) -> Void) async throws -> InstalledHelper {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("superconverter-helper-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let file = work.appendingPathComponent(pin.url.lastPathComponent)
        progress(.downloading(fraction: 0))
        try await fetch(pin.url, file) { progress(.downloading(fraction: $0)) }
        progress(.verifying)
        try Self.verifyChecksum(of: file, expected: pin.sha256)

        switch pin.payload {
        case .appInDiskImage(let appName, let teamID):
            progress(.unpacking)
            return InstalledHelper(version: pin.version, path: try installApp(from: file, named: appName, teamID: teamID, work: work))
        case .zipBinary(let binary):
            progress(.unpacking)
            return InstalledHelper(version: pin.version, path: try installTool(pin, binary: binary, work: work) {
                try Self.run("/usr/bin/ditto", ["-x", "-k", file.path, $0.path])
            })
        case .tarGzBinary(let binary):
            progress(.unpacking)
            return InstalledHelper(version: pin.version, path: try installTool(pin, binary: binary, work: work) {
                try Self.run("/usr/bin/tar", ["-xzf", file.path, "-C", $0.path])
            })
        }
    }

    // MARK: - Apps

    /// Mount read-only, copy to a hidden staging name in the applications folder, verify the *copy*, then move it into place.
    /// An older copy already at the destination goes to the Trash.
    private func installApp(from image: URL, named appName: String, teamID: String, work: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: applicationsFolder, withIntermediateDirectories: true)
        let volume = try Self.attach(image)
        defer { Self.detach(volume) }
        let source = volume.appendingPathComponent(appName, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { throw HelperInstallError.payloadMissing(appName) }
        let size = (try? Self.directorySize(source)) ?? 0
        guard SuperConverterPaths.freeSpace(at: applicationsFolder) > size * 2 else { throw HelperInstallError.notEnoughSpace(needed: size * 2) }

        let staged = applicationsFolder.appendingPathComponent(".\(appName).installing", isDirectory: true)
        try? fm.removeItem(at: staged)
        do {
            try Self.run("/usr/bin/ditto", [source.path, staged.path])
            try verifyApp(staged, teamID)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        let destination = applicationsFolder.appendingPathComponent(appName, isDirectory: true)
        if fm.fileExists(atPath: destination.path) { try fm.trashItem(at: destination, resultingItemURL: nil) }
        try fm.moveItem(at: staged, to: destination)
        return destination
    }

    /// A Developer ID signature of the publisher's team, intact (strict, every architecture, nested code), and Apple's
    /// notarisation (the Gatekeeper assessment) — checked on the staged copy before it becomes visible.
    static let verifySignatureAndNotarisation: VerifyApp = { app, teamID in
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { throw HelperInstallError.badSignature("unreadable") }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw HelperInstallError.badSignature("bad requirement")
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { throw HelperInstallError.badSignature("damaged") }
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw HelperInstallError.badSignature("another publisher") }
        do { try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) } catch { throw HelperInstallError.notNotarised }
    }

    // MARK: - Command-line tools

    /// Unpack into a staging folder, find `binary`, move it to `Helpers/<id>/<version>/<name>`.
    private func installTool(_ pin: HelperPin, binary: String, work: URL, unpack: (URL) throws -> Void) throws -> URL {
        let fm = FileManager.default
        let staging = work.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try unpack(staging)
        let tool = staging.appendingPathComponent(binary)
        guard fm.isExecutableFile(atPath: tool.path) else { throw HelperInstallError.payloadMissing(tool.lastPathComponent) }
        let folder = helperFolder(pin.helper, pin.version)
        let destination = folder.appendingPathComponent(tool.lastPathComponent)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: tool, to: destination)
        // Downloaded through URLSession there is no quarantine flag; clear one anyway in case a fetcher set it.
        _ = try? Self.run("/usr/bin/xattr", ["-d", "com.apple.quarantine", destination.path])
        return destination
    }

    // MARK: - Download and checks

    /// Streams `url` to `destination` with URLSession (the only network code besides UpdateKit), reporting the fraction.
    static let download: Fetch = { url, destination, progress in
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("SuperConverter (helpers)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw HelperInstallError.http(http.statusCode) }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw HelperInstallError.tool("Couldn’t write the download.") }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        let expected = response.expectedContentLength
        var buffer = Data(), received: Int64 = 0, reported = -1.0
        buffer.reserveCapacity(1 << 20)
        for try await byte in bytes {
            buffer.append(byte)
            guard buffer.count >= 1 << 20 else { continue }
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            if expected > 0, Double(received) / Double(expected) - reported >= 0.01 {
                reported = Double(received) / Double(expected)
                progress(min(1, reported))
            }
        }
        try handle.write(contentsOf: buffer)
        progress(1)
    }

    static func verifyChecksum(of file: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == expected.lowercased() else { throw HelperInstallError.checksumMismatch }
    }

    private static func directorySize(_ folder: URL) throws -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        for case let url as URL in FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) ?? NSEnumerator() {
            total += Int64((try? url.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    static func attach(_ dmg: URL) throws -> URL {
        let output = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path])
        guard let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.lazy.compactMap({ $0["mount-point"] as? String }).first
        else { throw HelperInstallError.tool("The disk image has no volume.") }
        return URL(fileURLWithPath: mountPoint, isDirectory: true)
    }

    static func detach(_ volume: URL) {
        if (try? run("/usr/bin/hdiutil", ["detach", volume.path, "-quiet"])) == nil {
            _ = try? run("/usr/bin/hdiutil", ["detach", volume.path, "-force", "-quiet"])
        }
    }

    /// Runs a system tool to completion; returns its standard output or throws with its standard error.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let errors = ErrorBox()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async { errors.data = err.fileHandleForReading.readDataToEndOfFile(); drained.leave() }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HelperInstallError.tool("\((tool as NSString).lastPathComponent) \(arguments.first ?? "") failed: \(message)")
        }
        return output
    }

    private final class ErrorBox: @unchecked Sendable { var data = Data() }
}
