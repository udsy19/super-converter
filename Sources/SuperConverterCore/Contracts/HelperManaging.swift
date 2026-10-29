import Foundation

public enum HelperStatus: Hashable, Sendable {
    case notInstalled
    case installed(version: String?, location: URL, sizeOnDisk: Int64?)
    case installing(fraction: Double)
    /// The helper is installed but cannot be used (damaged, wrong architecture), with the reason.
    case unusable(String)

    public var isReady: Bool { if case .installed = self { true } else { false } }
}

public enum InstallProgress: Sendable {
    case downloading(fraction: Double)
    case verifying
    case unpacking
    case finished(HelperStatus)
    case failed(String)
}

/// A command-line helper run (ARCHITECTURE §7): a scrubbed environment, a private TMPDIR, the work folder as the only
/// writable place, a time limit, `nice`, and no network.
public struct HelperInvocation: Hashable, Sendable {
    public var helper: HelperID
    public var arguments: [String]
    public var workFolder: URL
    public var timeLimit: TimeInterval?
    public init(helper: HelperID, arguments: [String], workFolder: URL, timeLimit: TimeInterval? = nil) {
        self.helper = helper; self.arguments = arguments; self.workFolder = workFolder; self.timeLimit = timeLimit
    }
}

public struct HelperRunResult: Hashable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
    public init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        self.exitCode = exitCode; self.standardOutput = standardOutput; self.standardError = standardError
    }
}

/// HelperKit's service. Helpers run only through here: never `Process` elsewhere.
@MainActor
public protocol HelperManaging: AnyObject {
    func status(of helper: HelperID) -> HelperStatus
    /// Downloads, verifies and unpacks a one-click helper; "Get…" helpers never come through here.
    func install(_ helper: HelperID) -> AsyncStream<InstallProgress>
    func remove(_ helper: HelperID) throws
    /// Looks for every helper again (Settings › Helpers › Look again).
    func lookAgain()
    /// Runs a command-line helper to completion or its time limit.
    func run(_ invocation: HelperInvocation) async throws -> HelperRunResult
    /// Drives an iWork or Office app with an AppleScript (after the person allowed automation).
    func automate(app: HelperID, script: String) async throws -> String
    /// Posts when any helper's status changes.
    var statusChanges: AsyncStream<HelperID> { get }
}

/// An executable that ships inside the app (formats §2.2: the LGPL `7zz`, `ffmpeg` and `ffprobe` in `Contents/Helpers/`,
/// `Vendor/Tools/` in a checkout) or a macOS command an engine drives (`hdiutil`). Engines run these only through
/// `Services.tools`, HelperKit's runner (ARCHITECTURE §7): never `Process` themselves.
public enum BundledTool: String, CaseIterable, Sendable {
    case sevenZip = "7zz", ffmpeg, ffprobe, hdiutil
}

/// One run of a bundled tool: the same scrubbed environment, private TMPDIR, `nice` and no-network profile as a helper.
public struct ToolInvocation: Sendable {
    public var tool: BundledTool
    public var arguments: [String]
    /// The working directory and a place the tool may write.
    public var workFolder: URL
    /// Other places the tool may write (an extraction folder, a mount point).
    public var writable: [URL]
    /// Written to the tool's standard input and closed (passwords go this way, never on the command line).
    public var standardInput: Data?
    public var timeLimit: TimeInterval?
    /// How much of standard output is kept (a long listing needs more than the default).
    public var outputLimit: Int

    public init(tool: BundledTool, arguments: [String], workFolder: URL, writable: [URL] = [], standardInput: Data? = nil,
                timeLimit: TimeInterval? = nil, outputLimit: Int = 256_000) {
        self.tool = tool; self.arguments = arguments; self.workFolder = workFolder; self.writable = writable
        self.standardInput = standardInput; self.timeLimit = timeLimit; self.outputLimit = outputLimit
    }
}

/// HelperKit's runner for bundled tools (`Services.tools`). It is `Sendable` and not tied to the main actor, so converters
/// keep it and use it from any task.
public protocol ToolRunning: Sendable {
    /// Where the tool is on this Mac, or nil when this build lacks it.
    func location(of tool: BundledTool) -> URL?
    /// Runs the tool to completion or its time limit; cancelling the calling task stops it.
    func run(_ invocation: ToolInvocation) async throws -> HelperRunResult
}
