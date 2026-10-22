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
