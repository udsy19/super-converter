// Adapted from Super PDF Sources/ConvertKit/Helpers/LibreOffice.swift (commit 058469b): the process runner (time limit, an
// exact process id stopped on timeout or cancellation). Added: scrubbed environment, private HOME and TMPDIR, `nice`, a
// `sandbox-exec` profile that denies network and writes outside the work folder (ARCHITECTURE §7), process-tree stop.

import Darwin
import Foundation
import SuperConverterCore

/// One helper process: where it runs, what it may write, how long it may take.
struct ProcessSpec {
    var executable: URL
    var arguments: [String]
    /// The working directory and the only place the process may write (besides `writable`, its private HOME and TMPDIR).
    var workFolder: URL
    var writable: [URL] = []
    /// Added to the scrubbed environment.
    var environment: [String: String] = [:]
    /// Directories added to PATH after the system ones (a helper that starts its siblings).
    var searchPath: [URL] = []
    /// Extra `file-write*` filters in the profile's own syntax, for the one thing a tool insists on creating outside.
    var extraWriteFilters: [String] = []
    var timeLimit: TimeInterval?
    /// True only for an install step that must download (Tectonic's warm-up); every conversion runs without.
    var network = false
    /// True for helpers that are apps (LibreOffice, calibre): AppKit checks in with LaunchServices and stops without it.
    /// Command-line tools get no LaunchServices, so nothing they run can open a URL or an app outside the sandbox.
    var launchServices = false
    var sandbox = true
    var niceness = 10
    /// Written to standard input and closed; nil means no input at all.
    var standardInput: Data?
    /// How much of standard output is kept.
    var outputLimit = 256_000
}

enum RunFailure: Error, Equatable {
    case timedOut
    case cancelled
    case couldNotStart(String)
}

enum ProcessRunner {
    /// Runs `spec` to completion or its time limit. A process past its limit, or one whose task was cancelled, is stopped
    /// by its own process id and those of its descendants — never by name.
    static func run(_ spec: ProcessSpec) async throws -> HelperRunResult {
        let fm = FileManager.default
        try fm.createDirectory(at: spec.workFolder, withIntermediateDirectories: true)
        let home = spec.workFolder.appendingPathComponent(".helper-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let tmp = home.appendingPathComponent("tmp", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        let sandboxed = spec.sandbox && Sandbox.isEnforced
        var args = ["-n", String(spec.niceness)]
        if sandboxed {
            let profile = Sandbox.profile(writable: [spec.workFolder, home] + spec.writable, network: spec.network,
                                          launchServices: spec.launchServices, extra: spec.extraWriteFilters)
            args += ["/usr/bin/sandbox-exec", "-p", profile]
        }
        args += [spec.executable.path] + spec.arguments

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = args
        process.currentDirectoryURL = spec.workFolder
        process.environment = environment(spec, home: home, tmp: tmp)
        let out = Pipe(), err = Pipe(), input = spec.standardInput.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let stdout = Collector(out.fileHandleForReading, limit: spec.outputLimit), stderr = Collector(err.fileHandleForReading)
        let state = RunState()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in
                    state.finish()
                    stdout.waitForEnd(); stderr.waitForEnd()
                    continuation.resume()
                }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: RunFailure.couldNotStart(error.localizedDescription))
                    return
                }
                let pid = process.processIdentifier
                state.started(pid)
                if let input, let data = spec.standardInput {
                    // A tool that exits without reading its input must not stop the run (no SIGPIPE; the write end is closed
                    // either way). The input is small (a password), well under a pipe's buffer.
                    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                    try? input.fileHandleForWriting.write(contentsOf: data)
                    try? input.fileHandleForWriting.close()
                }
                if let limit = spec.timeLimit {
                    DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                        guard !state.isFinished else { return }
                        state.timedOut = true
                        stopTree(pid, state: state)
                    }
                }
            }
        } onCancel: {
            state.cancelled = true
            if let pid = state.pid, !state.isFinished { stopTree(pid, state: state) }
        }
        if state.timedOut { throw RunFailure.timedOut }
        if state.cancelled { throw RunFailure.cancelled }
        return HelperRunResult(exitCode: process.terminationStatus, standardOutput: stdout.text, standardError: stderr.text)
    }

    /// The scrubbed environment: system PATH, a private HOME and TMPDIR, UTF-8, and what the caller added. Nothing of the
    /// person's own environment (tokens, proxies, `DYLD_*`) reaches a helper.
    private static func environment(_ spec: ProcessSpec, home: URL, tmp: URL) -> [String: String] {
        var path = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        path += spec.searchPath.map(\.path)
        var env = ["PATH": path.joined(separator: ":"), "HOME": home.path, "TMPDIR": tmp.path + "/", "LANG": "en_US.UTF-8",
                   "LC_ALL": "en_US.UTF-8"]
        for (key, value) in spec.environment { env[key] = value }
        return env
    }

    /// SIGTERM to `pid` and its descendants, then SIGKILL two seconds later to whichever of those exact ids still run.
    private static func stopTree(_ pid: pid_t, state: RunState) {
        guard pid > 0 else { return }
        let victims = descendants(of: pid).reversed() + [pid]
        for victim in victims { kill(victim, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            for victim in victims where kill(victim, 0) == 0 { kill(victim, SIGKILL) }
        }
    }

    /// Every process below `pid` (children first found first), from the kernel's process table.
    static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var queue = [pid]
        while let next = queue.popLast() {
            // The call returns how many ids it stored (the sizing call with a nil buffer is not exact).
            var children = [pid_t](repeating: 0, count: 1024)
            let count = proc_listchildpids(next, &children, Int32(children.count * MemoryLayout<pid_t>.size))
            guard count > 0 else { continue }
            for child in children.prefix(Int(count)) where child > 0 && !found.contains(child) {
                found.append(child); queue.append(child)
            }
        }
        return found
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private var _pid: pid_t?, _finished = false, _timedOut = false, _cancelled = false
        var pid: pid_t? { lock.withLock { _pid } }
        var isFinished: Bool { lock.withLock { _finished } }
        var timedOut: Bool { get { lock.withLock { _timedOut } } set { lock.withLock { _timedOut = newValue } } }
        var cancelled: Bool { get { lock.withLock { _cancelled } } set { lock.withLock { _cancelled = newValue } } }
        func started(_ pid: pid_t) { lock.withLock { _pid = pid } }
        func finish() { lock.withLock { _finished = true } }
    }

    /// Reads one pipe as it fills (kept to `limit` bytes, 256 KB by default) and notes its end, so a chatty helper never
    /// blocks on a full pipe.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let ended = DispatchSemaphore(value: 0)
        init(_ handle: FileHandle, limit: Int = 256_000) {
            handle.readabilityHandler = { [self] h in
                let chunk = h.availableData
                if chunk.isEmpty { h.readabilityHandler = nil; ended.signal(); return }
                lock.withLock { if data.count < limit { data.append(chunk) } }
            }
        }
        /// A descendant that keeps the pipe open must not hold the run up: wait briefly for the end of the stream.
        func waitForEnd() { _ = ended.wait(timeout: .now() + 0.5) }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}

/// `sandbox-exec` profiles (ARCHITECTURE §7). The tool is deprecated; `isEnforced` checks, once per launch, that it still
/// denies a write outside the allowed folders — if it ever does not, the environment and arguments are the only guard.
enum Sandbox {
    static func profile(writable: [URL], network: Bool, launchServices: Bool = false, extra: [String] = []) -> String {
        func quoted(_ url: URL) -> String {
            "\"" + realPath(url).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var lines = ["(version 1)", "(allow default)"]
        // IP traffic only: LibreOffice's launcher talks to its worker over a Unix-domain socket and fails without it.
        // Names are looked up through mDNSResponder's socket, so without network that goes too: a DNS query carries data out
        // as well as a connection does.
        if !network {
            lines += ["(deny network-outbound (remote ip))", "(deny network-inbound (local ip))", "(deny network-bind (local ip))",
                      "(deny network-outbound (remote unix-socket (path-literal \"/private/var/run/mDNSResponder\")))"]
        }
        // LaunchServices opens URLs and apps on a helper's behalf, outside its sandbox (a browser carries whatever the URL
        // holds), and finds the apps Apple Events go to.
        if !launchServices { lines.append("(deny mach-lookup" + launchServicesNames.map { " (global-name \"\($0)\")" }.joined() + ")") }
        lines.append("(deny file-write*)")
        lines.append("(allow file-write* (literal \"/dev/null\") (literal \"/dev/dtracehelper\") (regex #\"^/dev/(tty|fd/)\")"
                     + writable.map { " (subpath \(quoted($0)))" }.joined() + extra.map { " " + $0 }.joined() + ")")
        return lines.joined(separator: "\n")
    }

    static let launchServicesNames = ["com.apple.coreservices.launchservicesd", "com.apple.coreservices.quarantine-resolver",
                                      "com.apple.lsd.mapdb", "com.apple.lsd.open", "com.apple.lsd.modifydb"]

    /// The kernel's own spelling of a path (`/private/var/…`): a profile matches resolved paths, and Foundation's
    /// `resolvingSymlinksInPath` turns `/private/var` back into `/var`.
    static func realPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(url.path, &buffer).map { String(cString: $0) } ?? url.standardizedFileURL.path
    }

    static let isEnforced: Bool = {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("superconverter-sandbox-\(UUID().uuidString)", isDirectory: true)
        let inside = root.appendingPathComponent("in", isDirectory: true), outside = root.appendingPathComponent("out", isDirectory: true)
        guard (try? fm.createDirectory(at: inside, withIntermediateDirectories: true)) != nil,
              (try? fm.createDirectory(at: outside, withIntermediateDirectories: true)) != nil else { return false }
        defer { try? fm.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile(writable: [inside], network: false), "/bin/sh", "-c",
                             "echo x > \"$1/a\"; echo x > \"$2/b\"", "sh", inside.path, outside.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return fm.fileExists(atPath: inside.appendingPathComponent("a").path) && !fm.fileExists(atPath: outside.appendingPathComponent("b").path)
    }()
}
