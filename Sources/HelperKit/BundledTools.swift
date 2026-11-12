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
            // Store edition: the App Sandbox denies hdiutil's attach (mach-lookup com.apple.system.hdiejectd.xpc,
            // sysctl-write vfs.generic.noremotehang) and pkd answers no sandboxed client ("unauthorized discovery
            // flag"); disk images go through 7-Zip and the Quick Action switches through System Settings.
            if Distribution.isAppStore { return nil }
            let url = URL(fileURLWithPath: "/usr/bin/" + tool.rawValue)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return folders.map { $0.appendingPathComponent(tool.rawValue) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func run(_ invocation: ToolInvocation) async throws -> HelperRunResult {
        let name = Self.name(of: invocation.tool)
        guard let executable = location(of: invocation.tool) else { throw ConversionError.failed("\(name) isn’t part of this build.") }
        var spec = ProcessSpec(executable: executable, arguments: Self.staged(invocation.arguments, in: invocation.workFolder), workFolder: invocation.workFolder,
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

    /// Store edition: every input file the person granted (outside the container) is cloned into the job's work folder and
    /// the tool gets the clone, so a bundled tool reads only container files and writes only into the work folder; the app
    /// itself moves results to the chosen place (OutputRules). The App Sandbox's per-file grants belong to the app (an
    /// open panel, a drop, a bookmark), and Apple documents no promise that a child sees them (docs/app-store/architecture.md
    /// records the experiment). On APFS the clone costs no space. The direct edition passes arguments unchanged.
    static func staged(_ arguments: [String], in workFolder: URL) -> [String] {
        #if APP_STORE
        let fm = FileManager.default
        let container = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
        let bundle = Bundle.main.bundleURL.standardizedFileURL.path + "/"
        var folder: URL?
        return arguments.map { argument in
            guard argument.hasPrefix("/") else { return argument }
            let path = URL(fileURLWithPath: argument).standardizedFileURL.path
            var isDirectory: ObjCBool = false
            guard !path.hasPrefix(container), !path.hasPrefix(bundle), !path.hasPrefix("/dev/"),
                  fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return argument }
            do {
                let place = try folder ?? {
                    let made = workFolder.appendingPathComponent(".stage-\(UUID().uuidString.prefix(8))", isDirectory: true)
                    try fm.createDirectory(at: made, withIntermediateDirectories: true)
                    folder = made
                    return made
                }()
                let copy = place.appendingPathComponent("\(UUID().uuidString.prefix(4))-" + (path as NSString).lastPathComponent)
                try fm.copyItem(atPath: path, toPath: copy.path)   // a clone on APFS
                return copy.path
            } catch { return argument }
        }
        #else
        return arguments
        #endif
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
