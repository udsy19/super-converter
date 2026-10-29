import Foundation
import SuperConverterCore

/// `Services.tools`: finds the executables bundled with the app (ARCHITECTURE §7: `7zz`, `ffmpeg`, `ffprobe` in
/// `Contents/Helpers/`, code-signed with the app) and the macOS commands `hdiutil` and `pluginkit` (in `/usr/bin`), and runs
/// them through the same runner as the helpers.
/// Bundled tools get no network arguments, and the no-network profile applies all the same (`hdiutil` attaches under it
/// when the mount folder is among the writable places; `pluginkit` is the one exception, see `run`).
public struct BundledTools: ToolRunning {
    /// Folders searched in order: the app's `Contents/Helpers/`, `SUPERCONVERTER_TOOLS_DIR`, then the checkout's
    /// `Vendor/Tools/` (development builds, `swift run`; scripts/fetch-vendor.sh fills it).
    let folders: [URL]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        var folders: [URL] = []
        if let executable = Bundle.main.executableURL {
            folders.append(executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers", isDirectory: true))
        }
        if let dir = environment["SUPERCONVERTER_TOOLS_DIR"], !dir.isEmpty { folders.append(URL(fileURLWithPath: dir, isDirectory: true)) }
        // Sources/HelperKit/BundledTools.swift → the package root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        folders.append(root.appendingPathComponent("Vendor/Tools", isDirectory: true))
        self.folders = folders
    }

    public func location(of tool: BundledTool) -> URL? {
        if tool == .hdiutil || tool == .pluginkit {
            let url = URL(fileURLWithPath: "/usr/bin/" + tool.rawValue)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return folders.map { $0.appendingPathComponent(tool.rawValue) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func run(_ invocation: ToolInvocation) async throws -> HelperRunResult {
        let name = Self.name(of: invocation.tool)
        guard let executable = location(of: invocation.tool) else { throw ConversionError.failed("\(name) isn’t part of this build.") }
        var spec = ProcessSpec(executable: executable, arguments: invocation.arguments, workFolder: invocation.workFolder,
                               writable: invocation.writable, timeLimit: invocation.timeLimit,
                               standardInput: invocation.standardInput, outputLimit: invocation.outputLimit)
        // pkd answers no sandboxed client ("unauthorized discovery flag"), and pluginkit itself only asks pkd: it writes
        // no file and opens no connection, so it alone runs outside the profile (still scrubbed, niced and time-limited).
        spec.sandbox = invocation.tool != .pluginkit
        do { return try await ProcessRunner.run(spec) }
        catch RunFailure.timedOut { throw ConversionError.failed("\(name) took too long and was stopped.") }
        catch RunFailure.cancelled { throw ConversionError.cancelled }
        catch RunFailure.couldNotStart(let why) { throw ConversionError.failed("\(name) couldn’t start: \(why)") }
    }

    static func name(of tool: BundledTool) -> String {
        switch tool {
        case .sevenZip: "7-Zip"
        case .ffmpeg: "FFmpeg"
        case .ffprobe: "FFprobe"
        case .hdiutil: "hdiutil"
        case .pluginkit: "pluginkit"
        }
    }
}
