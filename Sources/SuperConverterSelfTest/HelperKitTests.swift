import AppKit
import CryptoKit
import SuperConverterCore
@testable import HelperKit

// HelperKit's checks (WP-H). Every helper here is a script in a temp folder that behaves like the tool; nothing is
// downloaded or installed, no app is opened. The real-helper case runs only with SUPERCONVERTER_REAL_HELPERS=1 and only
// uses what is already on this Mac.

private let root = FileManager.default.temporaryDirectory.appendingPathComponent("sc-helperkit-\(UUID().uuidString)", isDirectory: true)

private func folder(_ name: String) -> URL {
    let url = root.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func script(_ name: String, in dir: URL, _ body: String) -> URL {
    let url = dir.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// `Name.app` with `Contents/Info.plist` (a version) and, when `executable` is given, `Contents/MacOS/<executable>`.
@discardableResult
private func fakeApp(_ name: String, in dir: URL, executable: String?, version: String = "1.2", body: String = "exit 0") -> URL {
    let app = dir.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let plist: NSDictionary = ["CFBundleShortVersionString": version, "CFBundleIdentifier": "test.fake"]
    plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    if let executable { script(executable, in: app.appendingPathComponent("Contents/MacOS"), body) }
    return app
}

private func sha256(_ url: URL) -> String {
    SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
}

private func sh(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return (-1, "") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// A service over throwaway folders that finds only the paths it is told about.
@MainActor
private struct Rig {
    let service: HelperService
    let applications: URL, helpers: URL, record: URL, work: URL, profile: URL, cache: URL

    init(_ overrides: [HelperID: URL] = [:], fetch: HelperInstaller.Fetch? = nil, verify: HelperInstaller.VerifyApp? = nil, pins: [HelperPin] = [],
         osascript: URL? = nil, remove: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) {
        let base = folder("rig")
        applications = base.appendingPathComponent("Applications")
        helpers = base.appendingPathComponent("Helpers")
        record = base.appendingPathComponent("helpers.json")
        work = base.appendingPathComponent("work")
        profile = base.appendingPathComponent("lo-profile")
        cache = base.appendingPathComponent("tectonic-cache")
        for dir in [applications, helpers, work, profile, cache] { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let helpersFolder = helpers
        let helperFolder: @Sendable (HelperID, String) -> URL = { id, version in
            let url = helpersFolder.appendingPathComponent(id.rawValue).appendingPathComponent(version, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        var installer: HelperInstaller?
        if let fetch {
            installer = HelperInstaller(fetch: fetch, applicationsFolder: applications, helperFolder: helperFolder)
            if let verify { installer?.verifyApp = verify }
        }
        service = HelperService(
            override: { overrides[$0] }, applications: applications, recordFile: record, libreOfficeProfile: profile, tectonicCache: cache,
            helperFolder: helperFolder, installer: installer, pins: { id in pins.first { $0.helper == id } },
            osascript: osascript ?? URL(fileURLWithPath: "/usr/bin/osascript"), remove: remove, searchKnownPlaces: false)
    }

    func converter(_ id: EngineID) -> any Converter { service.converters().first { $0.id == id }! }

    func context(from: FormatID, to: FormatID, source: URL, options: OptionValues = OptionValues()) -> StepContext {
        StepContext(workFolder: work, source: source, sourceFormat: from, targetFormat: to, options: options)
    }

    func sourceFile(_ name: String, _ text: String = "source") -> URL {
        let url = work.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Runs one step and returns the file it produced.
    func convert(_ engine: EngineID, _ from: FormatID, _ to: FormatID, file name: String, options: OptionValues = OptionValues()) async throws -> URL {
        let source = sourceFile(name)
        let output = try await converter(engine).run(Step(engine, .format(from), .format(to)), input: .file(source),
                                                     context: context(from: from, to: to, source: source, options: options))
        guard case .file(let url) = output.value else { throw FakeError(message: "no file") }
        return url
    }
}

/// A case's async work, or nil when it threw or timed out.
@MainActor
private func done<T>(_ seconds: TimeInterval = 60, _ work: @escaping @MainActor () async throws -> T) -> T? {
    (try? complete(seconds, work)?.get())
}

@MainActor
private func finish(_ stream: AsyncStream<InstallProgress>) async -> [InstallProgress] {
    var events: [InstallProgress] = []
    for await event in stream { events.append(event) }
    return events
}

private func listenOnLoopback() -> (fd: Int32, port: UInt16)? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
    guard bound == 0, named == 0, listen(fd, 4) == 0 else { close(fd); return nil }
    return (fd, UInt16(bigEndian: address.sin_port))
}

private func gone(_ pid: pid_t, within seconds: Double = 15) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { if kill(pid, 0) != 0 { return true }; Thread.sleep(forTimeInterval: 0.05) }
    return kill(pid, 0) != 0
}

private let pandocAST = """
{"pandoc-api-version":[1,23,1],"meta":{"title":{"t":"MetaInlines","c":[{"t":"Str","c":"Report"}]},"author":{"t":"MetaList","c":[{"t":"MetaInlines","c":[{"t":"Str","c":"Ada"}]}]}},
"blocks":[
{"t":"Header","c":[1,["",[],[]],[{"t":"Str","c":"Intro"}]]},
{"t":"Para","c":[{"t":"Str","c":"Hello"},{"t":"Space"},{"t":"Emph","c":[{"t":"Str","c":"world"}]},{"t":"Note","c":[{"t":"Para","c":[{"t":"Str","c":"Footnote"}]}]}]},
{"t":"Para","c":[{"t":"Math","c":[{"t":"DisplayMath"},"E=mc^2"]}]},
{"t":"BulletList","c":[[{"t":"Plain","c":[{"t":"Str","c":"one"}]}],[{"t":"Plain","c":[{"t":"Str","c":"two"}]}]]},
{"t":"CodeBlock","c":[["",["python"],[]],"print(1)"]},
{"t":"RawBlock","c":["html","<b>"]},
{"t":"Table","c":[["",[],[]],[null,[]],[[{"t":"AlignRight"},{"t":"ColWidthDefault"}]],
 [["",[],[]],[[["",[],[]],[[["",[],[]],{"t":"AlignDefault"},1,1,[{"t":"Plain","c":[{"t":"Str","c":"H"}]}]]]]]],
 [[["",[],[]],0,[],[[["",[],[]],[[["",[],[]],{"t":"AlignDefault"},1,1,[{"t":"Plain","c":[{"t":"Str","c":"v"}]}]]]]]]],
 [["",[],[]],[]]]}
]}
"""

func registerHelperKitTests() {
    // MARK: Runner

    SelfTest.cases.append(("HelperKit.sandbox", {
        let dir = folder("sandbox")
        check(Sandbox.isEnforced, "sandbox-exec still denies writes outside the allowed folders on this macOS")

        // Environment: scrubbed, private HOME and TMPDIR under the work folder.
        setenv("SC_TEST_SECRET", "leak", 1)
        let envScript = script("env.sh", in: dir, "env")
        let env = complete(30) { try await ProcessRunner.run(ProcessSpec(executable: envScript, arguments: [], workFolder: dir.appendingPathComponent("w1"))) }
        let text = (try? env?.get().standardOutput) ?? ""
        unsetenv("SC_TEST_SECRET")
        check(!text.contains("SC_TEST_SECRET"), "the person’s environment doesn’t reach a helper")
        check(text.contains("HOME=\(dir.appendingPathComponent("w1").path)/.helper-"), "HOME is private, under the work folder")
        check(text.contains("TMPDIR=\(dir.appendingPathComponent("w1").path)/.helper-"), "TMPDIR is private, under the work folder")
        check(text.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), "PATH is the system's only")
        check(((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("w1").path)) ?? []).filter { $0.hasPrefix(".helper-") }.isEmpty,
              "the private folder is removed afterwards")

        // Writes: the work folder yes, anywhere else no.
        let outside = folder("outside")
        let writes = script("writes.sh", in: dir, "echo in > \"$PWD/inside\"; echo out > \"$1/outside\"; echo done")
        let w2 = dir.appendingPathComponent("w2")
        _ = complete(30) { try await ProcessRunner.run(ProcessSpec(executable: writes, arguments: [outside.path], workFolder: w2)) }
        check(FileManager.default.fileExists(atPath: w2.appendingPathComponent("inside").path), "a helper writes in the work folder")
        check(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("outside").path), "a helper can’t write outside it")

        // Network: denied for conversions, allowed only when the spec says so.
        if let (fd, port) = listenOnLoopback() {
            let connect = script("connect.sh", in: dir, "/usr/bin/nc -z 127.0.0.1 \"$1\" >/dev/null 2>&1; echo rc=$?")
            @MainActor func connected(network: Bool) -> String {
                let result = complete(30) {
                    try await ProcessRunner.run(ProcessSpec(executable: connect, arguments: [String(port)], workFolder: dir.appendingPathComponent("w3"), network: network))
                }
                return ((try? result?.get().standardOutput) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            check(connected(network: false) == "rc=1", "a conversion has no network")
            check(connected(network: true) == "rc=0", "an install step that must download can connect")
            close(fd)
        } else { check(false, "couldn’t open a local socket") }

        // Names: no DNS without network (a query carries data out too). Connecting to mDNSResponder's socket asks nothing.
        let resolver = script("resolver.sh", in: dir, "/usr/bin/nc -U /var/run/mDNSResponder < /dev/null >/dev/null 2>&1; echo rc=$?")
        @MainActor func reachedResolver(network: Bool) -> String {
            let result = complete(30) { try await ProcessRunner.run(ProcessSpec(executable: resolver, arguments: [], workFolder: dir.appendingPathComponent("w4"), network: network)) }
            return ((try? result?.get().standardOutput) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        check(reachedResolver(network: false) == "rc=1", "a conversion can’t look names up")
        check(reachedResolver(network: true) == "rc=0", "an install step that must download can")

        // LaunchServices: a command-line helper can't have a URL or an app opened outside its sandbox; an app helper (AppKit
        // needs it) can. The lookup asks LaunchServices where Finder is and opens nothing.
        let lookup = script("lookup.sh", in: dir, #"/usr/bin/osascript -l JavaScript -e 'ObjC.import("AppKit"); var u = $.NSWorkspace.sharedWorkspace.URLForApplicationWithBundleIdentifier("com.apple.finder"); u.isNil() ? "none" : "found"'"#)
        @MainActor func lookedUp(launchServices: Bool, sandbox: Bool = true) -> String {
            let result = complete(30) {
                try await ProcessRunner.run(ProcessSpec(executable: lookup, arguments: [], workFolder: dir.appendingPathComponent("w5"), launchServices: launchServices, sandbox: sandbox))
            }
            return ((try? result?.get().standardOutput) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if lookedUp(launchServices: true, sandbox: false) == "found" {
            check(lookedUp(launchServices: false) == "none", "a command-line helper can’t reach LaunchServices")
            check(lookedUp(launchServices: true) == "found", "an app helper can")
        } else { check(false, "LaunchServices finds Finder outside the sandbox") }

        // Time limit and cancellation stop exactly the process we started (and what it started), never others by name.
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["60"]
        try? bystander.run()
        let slow = script("slow.sh", in: dir, "sleep 40 &\necho $! > \"$1\"\nwait")
        let pidFile = dir.appendingPathComponent("child.pid")
        let started = Date()
        let timed = complete(30) { try await ProcessRunner.run(ProcessSpec(executable: slow, arguments: [pidFile.path], workFolder: dir.appendingPathComponent("w4"), writable: [dir], timeLimit: 1)) }
        if case .failure(let error)? = timed { check((error as? RunFailure) == .timedOut, "past its limit it fails as timed out (\(error))") }
        else { check(false, "a process past its time limit should fail") }
        check(Date().timeIntervalSince(started) < 10, "the limit is enforced promptly")
        if let child = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap({ pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            check(gone(child), "the helper’s child process was stopped too")
        } else { check(false, "the slow helper didn’t record its child") }
        check(bystander.isRunning, "an unrelated process of the same name is left alone")

        let cancelFile = dir.appendingPathComponent("cancel.pid")
        let cancelScript = script("cancel.sh", in: dir, "echo $$ > \"$1\"\nsleep 40")
        let cancelled = complete(30) { () -> RunFailure? in
            let task = Task { try await ProcessRunner.run(ProcessSpec(executable: cancelScript, arguments: [cancelFile.path], workFolder: dir.appendingPathComponent("w5"), writable: [dir])) }
            // Cancel once the helper is really running (its pid is written), however loaded the machine is.
            for _ in 0..<400 where !FileManager.default.fileExists(atPath: cancelFile.path) { try await Task.sleep(nanoseconds: 50_000_000) }
            task.cancel()
            do { _ = try await task.value; return nil } catch { return error as? RunFailure }
        }
        check((try? cancelled?.get()) == .cancelled, "cancelling the task stops the process")
        if let pid = (try? String(contentsOf: cancelFile, encoding: .utf8)).flatMap({ pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
            check(gone(pid), "the cancelled helper is gone")
        }
        bystander.terminate()
        bystander.waitUntilExit()
    }))

    // MARK: Detection

    SelfTest.cases.append(("HelperKit.detection", {
        let dir = folder("detect")
        // Homebrew: a link into Cellar gives the version from the folder name; apps give it from Info.plist.
        let cellar = dir.appendingPathComponent("Cellar/pandoc/3.8.1/bin")
        let pandoc = script("pandoc", in: cellar, "echo pandoc 3.8.1")
        let link = dir.appendingPathComponent("bin/pandoc")
        try? FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: pandoc)
        let office = fakeApp("LibreOffice.app", in: dir, executable: "soffice", version: "25.8")
        let gs = script("gs", in: dir.appendingPathComponent("gsbin"), "echo 10.04.0")
        let gplFFmpeg = script("ffmpeg", in: dir.appendingPathComponent("gpl"), "echo 'ffmpeg version 8.0.1'; echo 'configuration: --enable-gpl --enable-libx264'")
        let plainFFmpeg = script("ffmpeg", in: dir.appendingPathComponent("plain"), "echo 'ffmpeg version 8.0.1'; echo 'configuration: --disable-gpl'")
        let rig = Rig([.pandoc: link, .libreoffice: office, .ghostscript: gs, .ffmpegGPL: gplFFmpeg, .calibre: dir.appendingPathComponent("nothing.app")])

        if case .installed(let version, let location, _) = rig.service.status(of: .pandoc) {
            check(version == "3.8.1", "Homebrew's folder name gives the version (\(version ?? "nil"))")
            check(location.lastPathComponent == "pandoc", "the tool is where the link points from")
        } else { check(false, "Pandoc is found through its Homebrew link") }
        if case .installed(let version, let location, _) = rig.service.status(of: .libreoffice) {
            check(version == "25.8" && location == office, "an app reports its Info.plist version and its bundle")
        } else { check(false, "LibreOffice.app is found") }
        check(rig.service.status(of: .calibre) == .notInstalled, "a path with nothing there is not an installation")
        check(rig.service.status(of: .rar) == .notInstalled && rig.service.status(of: .sfark) == .notInstalled, "what isn’t there is not installed")
        check(rig.service.status(of: .ghostscript).isReady, "Ghostscript is found where Homebrew puts it")
        check(rig.service.status(of: .ffmpegGPL) == .notInstalled || rig.service.status(of: .ffmpegGPL).isReady, "FFmpeg waits for its probe")

        _ = complete(60) { await rig.service.settled() }
        if case .installed(let version, _, _) = rig.service.status(of: .ghostscript) {
            check(version == "10.04.0", "a --version probe fills in what the path couldn’t (\(version ?? "nil"))")
        } else { check(false, "Ghostscript stays installed after the probe") }
        if case .installed(_, _, let size) = rig.service.status(of: .libreoffice) { check((size ?? 0) > 0, "the size on disk of an app is measured") }
        check(rig.service.status(of: .ffmpegGPL).isReady, "an FFmpeg built with --enable-gpl counts")

        let plainRig = Rig([.ffmpegGPL: plainFFmpeg])
        _ = complete(60) { await plainRig.service.settled() }
        if case .unusable(let why) = plainRig.service.status(of: .ffmpegGPL) { check(why.contains("GPL"), "an FFmpeg without GPL encoders says why") }
        else { check(false, "a GPL-less FFmpeg is unusable, not installed") }

        // A change in what's on disk is found by "Look again" and published.
        let later = dir.appendingPathComponent("later/rar")
        var changed: [HelperID] = []
        let late = Rig([.rar: later])
        let stream = late.service.statusChanges
        let listener = Task { @MainActor in for await id in stream { changed.append(id); if id == .rar { break } } }
        script("rar", in: later.deletingLastPathComponent(), "echo RAR 7.01")
        late.service.lookAgain()
        _ = complete(10) { await listener.value }
        check(changed.contains(.rar) && late.service.status(of: .rar).isReady, "Look again finds a helper installed since launch and says so")

        // The Settings override wins over our own install.
        let ours = dir.appendingPathComponent("ours/tectonic")
        script("tectonic", in: ours.deletingLastPathComponent(), "echo tectonic 0.17.0")
        let mine = script("tectonic", in: dir.appendingPathComponent("mine"), "echo tectonic 9.9.9")
        let json = #"{"tectonic":{"version":"0.17.0","path":"\#(ours.path)","installedAt":"2026-10-22T00:00:00Z"}}"#
        let both = Rig([.tectonic: mine])
        try? json.write(to: both.record, atomically: true, encoding: .utf8)
        both.service.lookAgain()
        if case .installed(_, let location, _) = both.service.status(of: .tectonic) { check(location == mine, "the path set in Settings comes first") }
        let recorded = Rig()
        try? json.write(to: recorded.record, atomically: true, encoding: .utf8)
        recorded.service.lookAgain()
        if case .installed(let version, let location, _) = recorded.service.status(of: .tectonic) { check(location == ours && version == "0.17.0", "our own install is found through helpers.json") }
        else { check(false, "an install listed in helpers.json is found") }

        // "Get…" for what isn't one click (formats §2.9).
        check(HelperService.getAction(for: .ghostscript) == .homebrew(formula: "ghostscript", command: "brew install ghostscript"), "Ghostscript: brew install ghostscript")
        check(HelperService.getAction(for: .djvulibre) == .homebrew(formula: "djvulibre", command: "brew install djvulibre"), "DjVuLibre: brew install djvulibre")
        check(HelperService.getAction(for: .libredwg) == .homebrew(formula: "libredwg", command: "brew install libredwg"), "LibreDWG: brew install libredwg")
        check(HelperService.getAction(for: .ffmpegGPL) == .homebrew(formula: "ffmpeg", command: "brew install ffmpeg"), "FFmpeg: brew install ffmpeg")
        check(HelperService.getAction(for: .oda) == .openPage(URL(string: "https://www.opendesign.com/guestfiles/oda_file_converter")!), "ODA opens the vendor's page")
        check(HelperService.getAction(for: .rar) == .openPage(URL(string: "https://www.rarlab.com/download.htm")!), "RAR opens RARLAB's page")
        if case .openAppStore = HelperService.getAction(for: .iwork) {} else { check(false, "iWork opens the App Store") }
        if case .buildFromSource = HelperService.getAction(for: .sfark) {} else { check(false, "sfArk explains building") }
        check(HelperService.getAction(for: .msoffice) == .nothing, "Office is detect-only")
        for helper in HelperID.allCases {
            let oneClick = HelperService.getAction(for: helper) == .installHere
            check(oneClick == (HelperPins.pin(for: helper, arch: .arm64) != nil), "\(helper.rawValue): one click exactly when a release is pinned")
            if oneClick { check(HelperPins.pin(for: helper, arch: .x86_64) != nil, "\(helper.rawValue): pinned for both architectures") }
        }
        for pin in HelperPins.all {
            check(pin.url.scheme == "https", "\(pin.helper.rawValue) downloads over https")
            check(pin.sha256.count == 64 && pin.sha256.allSatisfy { "0123456789abcdef".contains($0) }, "\(pin.helper.rawValue) has a SHA-256")
            if case .appInDiskImage(_, let team) = pin.payload { check(team.count == 10, "\(pin.helper.rawValue) names its signing team") }
        }
    }))

    // MARK: Installer

    SelfTest.cases.append(("HelperKit.installCLI", {
        let dir = folder("install")
        // A Pandoc-shaped zip and a Tectonic-shaped tarball, served from disk.
        let zipSource = dir.appendingPathComponent("zsrc")
        script("pandoc", in: zipSource.appendingPathComponent("pandoc-3.12.1-arm64/bin"), "echo pandoc 3.12.1")
        let zip = dir.appendingPathComponent("pandoc-3.12.1-arm64-macOS.zip")
        let zipped = Process()
        zipped.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipped.arguments = ["-qr", zip.path, "pandoc-3.12.1-arm64"]
        zipped.currentDirectoryURL = zipSource
        try? zipped.run(); zipped.waitUntilExit()
        let tarSource = dir.appendingPathComponent("tsrc")
        script("tectonic", in: tarSource, "mkdir -p \"$TECTONIC_CACHE_DIR\"; echo warm > \"$TECTONIC_CACHE_DIR/warmed\"; echo tectonic 0.17.0")
        let tar = dir.appendingPathComponent("tectonic-0.17.0-aarch64-apple-darwin.tar.gz")
        _ = sh("/usr/bin/tar", ["-czf", tar.path, "-C", tarSource.path, "tectonic"])

        let pandocPin = HelperPin(helper: .pandoc, version: "3.12.1", arch: .arm64, url: zip, sha256: sha256(zip), payload: .zipBinary(binary: "pandoc-3.12.1-arm64/bin/pandoc"))
        let tectonicPin = HelperPin(helper: .tectonic, version: "0.17.0", arch: .arm64, url: tar, sha256: sha256(tar), payload: .tarGzBinary(binary: "tectonic"))
        let badPin = HelperPin(helper: .pandoc, version: "3.12.1", arch: .arm64, url: zip, sha256: String(repeating: "0", count: 64), payload: .zipBinary(binary: "pandoc-3.12.1-arm64/bin/pandoc"))
        let fetch: HelperInstaller.Fetch = { url, destination, progress in
            progress(0.5)
            try FileManager.default.copyItem(at: url, to: destination)
            progress(1)
        }

        // A wrong SHA-256 is thrown away: nothing installed, nothing recorded.
        let bad = Rig(fetch: fetch, pins: [badPin])
        let badEvents = done(60) { await finish(bad.service.install(.pandoc)) } ?? []
        if case .failed(let why)? = badEvents.last { check(why.contains("checksum"), "a bad checksum says so (\(why))") } else { check(false, "a bad checksum fails the install") }
        check(!FileManager.default.fileExists(atPath: bad.helpers.appendingPathComponent("pandoc").path), "nothing was unpacked")
        check(!FileManager.default.fileExists(atPath: bad.record.path), "nothing was recorded")
        check(bad.service.status(of: .pandoc) == .notInstalled, "status stays not installed")

        // Pandoc: download, verify, unpack, record, run, remove.
        let removed = Box<[URL]>([])
        let rig = Rig(fetch: fetch, pins: [pandocPin, tectonicPin], remove: { removed.value.append($0); try FileManager.default.removeItem(at: $0) })
        let fractions = Box<[Double]>([])
        let changes = rig.service.statusChanges
        let watcher = Task { @MainActor in
            for await id in changes where id == .pandoc { if case .installing(let f) = rig.service.status(of: .pandoc) { fractions.value.append(f) } }
        }
        let events = done(60) { await finish(rig.service.install(.pandoc)) } ?? []
        watcher.cancel()
        check(events.contains { if case .downloading = $0 { true } else { false } }, "the download reports progress")
        check(events.contains { if case .verifying = $0 { true } else { false } } && events.contains { if case .unpacking = $0 { true } else { false } }, "then verifying and unpacking")
        if case .finished(let status)? = events.last, case .installed(let version, let location, _) = status {
            check(version == "3.12.1" && location.path.hasSuffix("/pandoc/3.12.1/pandoc"), "unpacked to Helpers/<id>/<version>/ (\(location.path))")
        } else { check(false, "the install finishes installed (\(String(describing: events.last)))") }
        check(!fractions.value.isEmpty, "the status is installing(fraction) while it runs")
        let json = (try? String(contentsOf: rig.record, encoding: .utf8)) ?? ""
        check(json.contains("\"pandoc\"") && json.contains("3.12.1"), "helpers.json records the install")
        let ran = done(30) { try await rig.service.run(HelperInvocation(helper: .pandoc, arguments: ["--version"], workFolder: rig.work)) }
        check(ran?.standardOutput.contains("pandoc 3.12.1") == true, "the installed helper runs through the runner")
        check(rig.service.status(of: .pandoc).isReady, "status is installed")
        let busy = done(10) { await finish(rig.service.install(.ghostscript)) } ?? []
        if case .failed? = busy.last {} else { check(false, "Ghostscript can't be installed from here") }

        // Remove deletes exactly what we installed, and nothing else.
        check(removed.value.isEmpty, "nothing removed yet")
        do { try rig.service.remove(.pandoc) } catch { check(false, "remove failed: \(error)") }
        check(removed.value.map(\.path) == [rig.helpers.appendingPathComponent("pandoc").path], "the helper's folder is removed (\(removed.value.map(\.path)))")
        check(rig.service.status(of: .pandoc) == .notInstalled, "status is not installed again")
        check(!((try? String(contentsOf: rig.record, encoding: .utf8)) ?? "").contains("pandoc"), "the record is gone")
        do { try rig.service.remove(.pandoc); check(false, "removing what we never installed should fail") }
        catch { check((error as? HelperError) == .notInstalledByUs(.pandoc), "a helper that isn’t ours isn’t removed (\(error))") }

        // Tectonic: the install warms the cache with network allowed.
        let tex = Rig(fetch: fetch, pins: [tectonicPin])
        let texEvents = done(300) { await finish(tex.service.install(.tectonic)) } ?? []
        if case .finished? = texEvents.last {} else { check(false, "Tectonic installs (\(String(describing: texEvents.last)))") }
        check(FileManager.default.fileExists(atPath: tex.cache.appendingPathComponent("warmed").path), "the install ran a warm-up that filled the cache")
    }))

    SelfTest.cases.append(("HelperKit.installApp", {
        let dir = folder("installapp")
        let source = dir.appendingPathComponent("dmgsrc")
        fakeApp("Fake.app", in: source, executable: "soffice", version: "9.9")
        let dmg = dir.appendingPathComponent("Fake.dmg")
        let made = sh("/usr/bin/hdiutil", ["create", "-quiet", "-volname", "SCFakeVolume", "-srcfolder", source.path, "-format", "UDZO", "-ov", dmg.path])
        check(made.status == 0, "hdiutil create: \(made.output)")
        let pin = HelperPin(helper: .libreoffice, version: "9.9", arch: .arm64, url: dmg, sha256: sha256(dmg), payload: .appInDiskImage(app: "Fake.app", teamID: "ABCDE12345"))
        let asked = Box<[String]>([])
        let fetch: HelperInstaller.Fetch = { url, destination, _ in try FileManager.default.copyItem(at: url, to: destination) }

        // A copy that fails its signature check is never made visible.
        let refusing = Rig(fetch: fetch, verify: { _, team in asked.value.append(team); throw HelperInstallError.badSignature("test") }, pins: [pin])
        let applications = refusing.applications
        let refused = done(300) { await finish(refusing.service.install(.libreoffice)) } ?? []
        if case .failed(let why)? = refused.last { check(why.contains("isn’t signed"), "an unsigned app is refused (\(why))") } else { check(false, "a failed signature check fails the install") }
        check(asked.value == ["ABCDE12345"], "the publisher's team is what's checked")
        check(((try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []).isEmpty, "nothing, not even a staging copy, is left in the applications folder")
        check(!sh("/usr/bin/hdiutil", ["info"]).output.contains("SCFakeVolume"), "the disk image is unmounted")
        check(refusing.service.status(of: .libreoffice) == .notInstalled, "still not installed")

        // The real check rejects an app that isn't signed by that team.
        let unsigned = fakeApp("Unsigned.app", in: dir, executable: "x")
        do { try HelperInstaller.verifySignatureAndNotarisation(unsigned, "ABCDE12345"); check(false, "an unsigned app must not pass") }
        catch { check(error is HelperInstallError, "an unsigned app doesn’t pass the real check") }
        // …and accepts a pristine Developer ID app from its own team (any installed one, read-only; nothing is launched).
        for name in ["Obsidian", "Discord", "Spotify", "Notion", "Postman", "Google Chrome"] {
            let candidate = URL(fileURLWithPath: "/Applications/\(name).app")
            guard sh("/usr/bin/codesign", ["--verify", "--deep", "--strict", candidate.path]).status == 0,
                  let line = sh("/usr/bin/codesign", ["-dv", candidate.path]).output.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else { continue }
            let team = String(line.dropFirst("TeamIdentifier=".count))
            do { try HelperInstaller.verifySignatureAndNotarisation(candidate, team) } catch { check(false, "\(name) passes its own team's pin: \(error)") }
            do { try HelperInstaller.verifySignatureAndNotarisation(candidate, "ZZZZZZZZZZ"); check(false, "another team's pin must not pass") } catch {}
            break
        }

        // Passing, the app is copied to the applications folder, recorded, detected and removable.
        let removed = Box<[URL]>([])
        let accepting = Rig(fetch: fetch, verify: { _, _ in }, pins: [pin], remove: { removed.value.append($0); try FileManager.default.removeItem(at: $0) })
        let events = done(300) { await finish(accepting.service.install(.libreoffice)) } ?? []
        if case .finished(let status)? = events.last, case .installed(let version, let location, _) = status {
            check(version == "9.9" && location == accepting.applications.appendingPathComponent("Fake.app"), "the app is in the applications folder (\(location.path))")
        } else { check(false, "the app install finishes (\(String(describing: events.last)))") }
        check(((try? FileManager.default.contentsOfDirectory(atPath: accepting.applications.path)) ?? []) == ["Fake.app"], "only the app is there")
        do { try accepting.service.remove(.libreoffice) } catch { check(false, "remove: \(error)") }
        check(removed.value.map(\.path) == [accepting.applications.appendingPathComponent("Fake.app").path], "remove takes exactly the app we copied")
        check(accepting.service.status(of: .libreoffice) == .notInstalled, "and it's gone")
    }))

    // MARK: Converters

    SelfTest.cases.append(("HelperKit.libreOffice", {
        let dir = folder("lo")
        let app = fakeApp("LibreOffice.app", in: dir, executable: "soffice", body: """
            out=""; prev=""; fmt=""
            for a in "$@"; do
              [ "$prev" = "--outdir" ] && out="$a"
              [ "$prev" = "--convert-to" ] && fmt="$a"
              prev="$a"; last="$a"
            done
            base=$(basename "$last"); base="${base%.*}"
            echo "$@" > "$out/args"
            perl -MTime::HiRes=time -e 'printf "%.3f", time' > "$out/start"
            sleep 0.4
            echo converted > "$out/$base.${fmt%%:*}"
            perl -MTime::HiRes=time -e 'printf "%.3f", time' > "$out/end"
            """)
        let rig = Rig([.libreoffice: app])
        check(rig.converter(.libreOffice).availability() == .available, "LibreOffice is available when found")
        let none = Rig()
        check(none.converter(.libreOffice).availability() == .needsHelper(.libreoffice), "and asks for the helper when not")
        let missing = complete(30) { try await none.convert(.libreOffice, "doc", "pdf", file: "a.doc") }
        if case .failure(let error)? = missing { check((error as? ConversionError) == .helperMissing(.libreoffice), "a run without it says which helper is missing") } else { check(false, "a run without LibreOffice must fail") }

        // Two jobs at once run one after the other (one process per profile).
        let results = complete(60) { () -> [URL] in
            async let first = rig.convert(.libreOffice, "doc", "pdf", file: "a.doc")
            async let second = rig.convert(.libreOffice, "wpd", "docx", file: "b.wpd")
            return try await [first, second]
        }
        guard let outputs = try? results?.get(), outputs.count == 2 else { check(false, "both LibreOffice runs finish"); return }
        check(outputs[0].pathExtension == "pdf" && outputs[1].pathExtension == "docx", "each run's output has its target extension")
        func stamp(_ out: URL, _ name: String) -> Double { Double((try? String(contentsOf: out.deletingLastPathComponent().appendingPathComponent(name), encoding: .utf8)) ?? "") ?? 0 }
        let a = (stamp(outputs[0], "start"), stamp(outputs[0], "end")), b = (stamp(outputs[1], "start"), stamp(outputs[1], "end"))
        check(a.0 > 0 && b.0 > 0 && (a.1 <= b.0 || b.1 <= a.0), "LibreOffice runs one job at a time")
        let args = (try? String(contentsOf: outputs[0].deletingLastPathComponent().appendingPathComponent("args"), encoding: .utf8)) ?? ""
        for flag in ["--headless", "--norestore", "--nologo", "--nolockcheck", "--convert-to pdf", "-env:UserInstallation=file://"] {
            check(args.contains(flag), "the command line has \(flag)")
        }
        check(args.contains(rig.profile.lastPathComponent), "the private profile is used")
        check(FileManager.default.fileExists(atPath: rig.profile.appendingPathComponent("user/registrymodifications.xcu").path), "the profile has the update check and first-run tasks switched off")
        check(((try? String(contentsOf: rig.profile.appendingPathComponent("user/registrymodifications.xcu"), encoding: .utf8)) ?? "").contains("AutoCheckEnabled"), "…including the update check")
    }))

    SelfTest.cases.append(("HelperKit.ebooksAndText", {
        let dir = folder("books")
        // calibre
        let calibre = fakeApp("calibre.app", in: dir, executable: "ebook-convert", body: "echo \"$CALIBRE_CONFIG_DIRECTORY\" > \"$(dirname \"$2\")/env\"; cp \"$1\" \"$2\"")
        let rig = Rig([.calibre: calibre])
        let epub = complete(60) { try await rig.convert(.calibre, "mobi", "epub", file: "book.mobi") }
        if let url = try? epub?.get() {
            check(url.lastPathComponent == "book.epub" && FileManager.default.fileExists(atPath: url.path), "calibre writes <name>.<target>")
            check(((try? String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("env"), encoding: .utf8)) ?? "").contains("/.calibre/config"), "calibre's config stays private")
        } else { check(false, "calibre converts") }
        // calibre picks its reader by extension and runs a `.recipe` as Python: a file that is really a MOBI reaches it as
        // `.mobi` whatever it is called, as a copy in the work folder, with nothing in its name a tool could misread.
        let named = fakeApp("calibre.app", in: dir.appendingPathComponent("named"), executable: "ebook-convert",
                            body: "printf '%s' \"$1\" > \"$(dirname \"$2\")/input-name\"; cp \"$1\" \"$2\"")
        let nrig = Rig([.calibre: named])
        let recipe = complete(60) { try await nrig.convert(.calibre, "mobi", "epub", file: "-o 50%d\nbook.recipe") }
        if let url = try? recipe?.get() {
            let seen = (try? String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("input-name"), encoding: .utf8)) ?? ""
            check(seen.hasSuffix("/_o 50_d_book.mobi"), "the helper reads the file as what it really is, under a safe name (\(seen))")
            check(seen.hasPrefix(nrig.work.path + "/"), "a copy in the work folder")
        } else { check(false, "a misnamed book still converts (\(String(describing: recipe)))") }
        check(HelperRuntime.safeName("Report") == "Report" && HelperRuntime.safeName("..hidden") == "_.hidden" && HelperRuntime.safeName("") == "input"
              && HelperRuntime.safeName("a\u{202E}b:c") == "a_b_c", "safe names keep the person's words")

        // Pandoc → DocModel
        let ast = dir.appendingPathComponent("pbin/ast.json")
        try? FileManager.default.createDirectory(at: ast.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? pandocAST.write(to: ast, atomically: true, encoding: .utf8)
        let pandoc = script("pandoc", in: ast.deletingLastPathComponent(), "echo \"$@\" > \"$PWD/pandoc.args\"\nwhile [ $# -gt 0 ]; do [ \"$1\" = \"-o\" ] && out=\"$2\"; shift; done\ncat \"$(dirname \"$0\")/ast.json\" > \"$out\"")
        let prig = Rig([.pandoc: pandoc])
        let source = prig.sourceFile("doc.rst")
        let parsed = complete(60) {
            try await prig.converter(.pandoc).run(Step(.pandoc, "rst", .docModel), input: .file(source), context: prig.context(from: "rst", to: "docx", source: source))
        }
        if let output = try? parsed?.get(), case .doc(let model) = output.value {
            check(model.metadata.title == "Report" && model.metadata.authors == ["Ada"], "title and author come from the AST's metadata")
            check(model.blocks.count == 7, "every block maps (\(model.blocks.count))")
            if case .heading(let level, let text) = model.blocks[0] { check(level == 1 && text == [.text("Intro")], "a heading") } else { check(false, "heading first") }
            if case .paragraph(let text, _) = model.blocks[1] { check(text == [.text("Hello"), .text(" "), .emphasis([.text("world")]), .footnoteReference(id: "1")], "inline styles and the note reference") } else { check(false, "paragraph") }
            if case .math(let tex, let display) = model.blocks[2] { check(tex == "E=mc^2" && display, "display math becomes a math block") } else { check(false, "math") }
            if case .list(let ordered, _, let items) = model.blocks[3] { check(!ordered && items.count == 2, "a bullet list") } else { check(false, "list") }
            if case .code(let language, let text) = model.blocks[4] { check(language == "python" && text == "print(1)", "code with its language") } else { check(false, "code") }
            if case .table(let table) = model.blocks[5] {
                check(table.rows.count == 2 && table.rows[0][0].isHeader && !table.rows[1][0].isHeader && table.alignments == [.end], "a table with its header row and alignment")
            } else { check(false, "table") }
            if case .footnote(let id, _) = model.blocks[6] { check(id == "1", "the footnote follows") } else { check(false, "footnote") }
            check(output.lossNotes.first?.detail.contains("raw blocks") == true, "what the model has no place for is reported, not dropped silently")
        } else { check(false, "Pandoc's AST converts to a DocModel") }
        let pandocArgs = (try? String(contentsOf: prig.work.appendingPathComponent("pandoc.args"), encoding: .utf8)) ?? ""
        check(pandocArgs.contains("-f rst -t json -o"), "Pandoc reads rst as rst and writes its JSON AST (\(pandocArgs))")
        try? "not json".write(to: ast, atomically: true, encoding: .utf8)
        let broken = complete(60) { try await prig.converter(.pandoc).run(Step(.pandoc, "rst", .docModel), input: .file(source), context: prig.context(from: "rst", to: "docx", source: source)) }
        if case .failure(let error)? = broken { check((error as? ConversionError) == .damaged("rst"), "unreadable output is a damaged file, not a crash") } else { check(false, "bad JSON should fail") }

        // Tectonic: offline from the cache; MacTeX's latexmk when that's what was found.
        let tectonic = script("tectonic", in: dir.appendingPathComponent("tbin"), "echo \"$@\" > \"$PWD/tectonic.args\"\necho \"$TECTONIC_CACHE_DIR\" > \"$PWD/tectonic.cache\"\nwhile [ $# -gt 0 ]; do [ \"$1\" = \"--outdir\" ] && out=\"$2\"; last=\"$1\"; shift; done\nb=$(basename \"$last\" .tex); echo pdf > \"$out/$b.pdf\"")
        let trig = Rig([.tectonic: tectonic])
        let pdf = complete(60) { try await trig.convert(.tectonic, "tex", "pdf", file: "paper.tex") }
        if let url = try? pdf?.get() {
            let targs = (try? String(contentsOf: trig.work.appendingPathComponent("tectonic.args"), encoding: .utf8)) ?? ""
            check(url.lastPathComponent == "paper.pdf", "Tectonic's PDF")
            check(targs.contains("-X compile --only-cached --untrusted --outdir"), "offline, from the warmed cache (\(targs))")
            check((try? String(contentsOf: trig.work.appendingPathComponent("tectonic.cache"), encoding: .utf8))?.contains(trig.cache.path) == true, "with the private cache")
        } else { check(false, "Tectonic converts") }
        let latexmk = script("latexmk", in: dir.appendingPathComponent("texbin"), "echo \"$@\" > \"$PWD/latexmk.args\"\nfor a in \"$@\"; do case \"$a\" in -outdir=*) out=\"${a#-outdir=}\";; esac; last=\"$a\"; done\nb=$(basename \"$last\" .tex); echo pdf > \"$out/$b.pdf\"")
        let mrig = Rig([.tectonic: latexmk])
        let viaMac = complete(60) { try await mrig.convert(.tectonic, "tex", "pdf", file: "paper.tex") }
        check((try? viaMac?.get())?.lastPathComponent == "paper.pdf", "MacTeX's latexmk is used when it's what was found")
        check(((try? String(contentsOf: mrig.work.appendingPathComponent("latexmk.args"), encoding: .utf8)) ?? "").contains("-no-shell-escape"), "…without shell escape")
    }))

    SelfTest.cases.append(("HelperKit.fileTools", {
        let dir = folder("tools")
        // Ghostscript
        let gs = script("gs", in: dir.appendingPathComponent("gs"), "echo \"$@\" > \"$PWD/gs.args\"\nfor a in \"$@\"; do case \"$a\" in -sOutputFile=*) out=\"${a#-sOutputFile=}\";; esac; done\necho out > \"$out\"")
        let grig = Rig([.ghostscript: gs])
        for (from, to, device) in [("eps", "pdf", "pdfwrite"), ("ps", "eps", "eps2write"), ("eps", "ps", "ps2write"), ("ai", "pdf", "pdfwrite")] as [(String, String, String)] {
            let out = complete(60) { try await grig.convert(.ghostscript, FormatID(from), FormatID(to), file: "pic.\(from)") }
            let args = (try? String(contentsOf: grig.work.appendingPathComponent("gs.args"), encoding: .utf8)) ?? ""
            check((try? out?.get())?.lastPathComponent == "pic.\(to)", "\(from) → \(to) writes pic.\(to)")
            check(args.contains("-dSAFER") && args.contains("-dBATCH") && args.contains("-dNOPAUSE") && args.contains("-sDEVICE=\(device)"), "\(from) → \(to) uses \(device) with -dSAFER (\(args))")
            check(args.contains("-dEPSCrop") == (from == "eps" && to == "pdf"), "\(from) → \(to): EPSCrop only for EPS → PDF")
        }
        // DjVuLibre, sfArk
        let ddjvu = script("ddjvu", in: dir.appendingPathComponent("dj"), "[ \"$1\" = \"-format=pdf\" ] && echo pdf > \"$3\"")
        let djvu = complete(60) { try await Rig([.djvulibre: ddjvu]).convert(.djvuLibre, "djvu", "pdf", file: "scan.djvu") }
        check((try? djvu?.get())?.lastPathComponent == "scan.pdf", "ddjvu -format=pdf in out")
        let sfark = script("sfarkxtc", in: dir.appendingPathComponent("sf"), "echo sf2 > \"$2\"")
        let sf = complete(60) { try await Rig([.sfark: sfark]).convert(.sfArk, "sfark", "sf2", file: "bank.sfark") }
        check((try? sf?.get())?.lastPathComponent == "bank.sf2", "sfarkxtc in out.sf2")
        // A tool that fails or hangs is reported as such.
        let failing = script("sfarkxtc", in: dir.appendingPathComponent("fail"), "echo 'bad header' >&2; exit 3")
        let failed = complete(60) { try await Rig([.sfark: failing]).convert(.sfArk, "sfark", "sf2", file: "bank.sfark") }
        if case .failure(let error)? = failed { check((error as? ConversionError) == .failed("sfArk tool stopped: bad header"), "a failing tool's own words are kept (\(error))") } else { check(false, "exit 3 should fail") }
        // FFmpeg with GPL encoders
        let gpl = script("ffmpeg", in: dir.appendingPathComponent("ff"), "case \"$1\" in -version) echo 'configuration: --enable-gpl';; *) echo \"$@\" > \"$PWD/ffmpeg.args\"; for a in \"$@\"; do out=\"$a\"; done; echo cavs > \"$out\";; esac")
        let ffrig = Rig([.ffmpegGPL: gpl])
        _ = complete(60) { await ffrig.service.settled() }
        check(ffrig.converter(.ffmpegGPL).availability() == .available, "FFmpeg with --enable-gpl is available")
        let cavs = complete(60) { try await ffrig.convert(.ffmpegGPL, "mp4", "cavs", file: "clip.mp4") }
        check((try? cavs?.get())?.lastPathComponent == "clip.cavs", "CAVS output")
        check(((try? String(contentsOf: ffrig.work.appendingPathComponent("ffmpeg.args"), encoding: .utf8)) ?? "").contains("-c:v libxavs"), "through libxavs")
        let lgpl = script("ffmpeg", in: dir.appendingPathComponent("lgpl"), "echo 'configuration: --disable-gpl'")
        let lrig = Rig([.ffmpegGPL: lgpl])
        _ = complete(60) { await lrig.service.settled() }
        check(lrig.converter(.ffmpegGPL).availability() == .needsHelper(.ffmpegGPL), "an FFmpeg without GPL encoders still asks for the helper")
        // RAR
        let rar = script("rar", in: dir.appendingPathComponent("rar"), "echo \"$@\" > \"$PWD/rar.args\"\necho \"$PWD\" > \"$PWD/rar.cwd\"\nfor a in \"$@\"; do case \"$a\" in *.rar) out=\"$a\";; esac; done\necho rar > \"$out\"")
        let rrig = Rig([.rar: rar])
        let tree = folder("tree")
        try? "a".write(to: tree.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? FileManager.default.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try? "b".write(to: tree.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        let archive = ArchiveTree(entries: [ArchiveTree.Entry(path: "a.txt", kind: .file, size: 1, extracted: tree.appendingPathComponent("a.txt")),
                                            ArchiveTree.Entry(path: "sub", kind: .directory),
                                            ArchiveTree.Entry(path: "sub/b.txt", kind: .file, size: 1, extracted: tree.appendingPathComponent("sub/b.txt"))], root: tree)
        let source = rrig.sourceFile("bundle.7z")
        let packed = complete(60) {
            try await rrig.converter(.rar).run(Step(.rar, .archiveTree, "rar"), input: .archive(archive),
                                               context: rrig.context(from: "7z", to: "rar", source: source, options: OptionValues(["compression": "smallest"])))
        }
        if case .file(let url)? = (try? packed?.get())?.value {
            let args = (try? String(contentsOf: tree.appendingPathComponent("rar.args"), encoding: .utf8)) ?? ""
            check(url.lastPathComponent == "bundle.rar", "RAR names the archive after the source")
            check(args.contains("a -ma5 -m5") && args.contains("a.txt") && args.contains("sub/b.txt"), "rar a -ma5 with the tree's paths (\(args))")
            let cwd = ((try? String(contentsOf: tree.appendingPathComponent("rar.cwd"), encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            check(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == tree.resolvingSymlinksInPath(), "run inside the extracted tree")
        } else { check(false, "RAR packs the tree") }
    }))

    SelfTest.cases.append(("HelperKit.dwg", {
        let dir = folder("dwg")
        let oda = fakeApp("ODAFileConverter.app", in: dir, executable: "ODAFileConverter", body: """
            ext=$(echo "$4" | tr A-Z a-z)
            for f in "$1"/*; do b=$(basename "$f"); b="${b%.*}"; echo oda > "$2/$b.$ext"; done
            echo "$@ $QT_QPA_PLATFORM" > "$2/args"
            """)
        let orig = Rig([.oda: oda])
        for (from, to) in [("dwg", "dxf"), ("dxf", "dwg"), ("dwg", "dwg")] {
            let out = complete(60) { try await orig.convert(.dwgConverter, FormatID(from), FormatID(to), file: "plan.\(from)") }
            if let url = try? out?.get() {
                let args = (try? String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("args"), encoding: .utf8)) ?? ""
                check(url.lastPathComponent == "plan.\(to)", "ODA \(from) → \(to)")
                check(args.contains("ACAD2018 \(to.uppercased()) 0 1 *.\(from.uppercased()) offscreen"), "ODA arguments and no GUI (\(args))")
            } else { check(false, "ODA converts \(from) → \(to)") }
        }
        // LibreDWG when ODA is absent.
        let bin = dir.appendingPathComponent("brew")
        script("dwg2dxf", in: bin, "echo \"$@\" >> \"$PWD/dwg.log\"\nwhile [ $# -gt 0 ]; do [ \"$1\" = \"-o\" ] && out=\"$2\"; shift; done\necho dxf > \"$out\"")
        script("dxf2dwg", in: bin, "echo \"$@\" >> \"$PWD/dwg.log\"\nwhile [ $# -gt 0 ]; do [ \"$1\" = \"-o\" ] && out=\"$2\"; shift; done\necho dwg > \"$out\"")
        let lrig = Rig([.libredwg: bin.appendingPathComponent("dwg2dxf")])
        check(lrig.converter(.dwgConverter).availability() == .available, "LibreDWG alone makes DWG available")
        for (from, to) in [("dwg", "dxf"), ("dxf", "dwg"), ("dwg", "dwg")] {
            let out = complete(60) { try await lrig.convert(.dwgConverter, FormatID(from), FormatID(to), file: "plan.\(from)") }
            check((try? out?.get())?.lastPathComponent == "plan.\(to)", "LibreDWG \(from) → \(to)")
        }
        let log = (try? String(contentsOf: lrig.work.appendingPathComponent("dwg.log"), encoding: .utf8)) ?? ""
        check(log.contains("-y -o"), "LibreDWG runs non-interactively (-y)")
        check(Rig().converter(.dwgConverter).availability() == .needsHelper(.oda), "with neither, the card offers ODA")
    }))

    SelfTest.cases.append(("HelperKit.iWork", {
        let dir = folder("iwork")
        let osascript = script("osascript", in: dir.appendingPathComponent("bin"), """
            script="$2"
            printf '%s' "$script" > "$(dirname "$0")/last"
            out=$(printf '%s' "$script" | grep -o 'POSIX file "[^"]*"' | sed -n 2p | sed 's/POSIX file "//; s/"$//')
            case "$script" in
              *"slide images"*) mkdir -p "$out"; for i in 1 2 3; do echo img > "$out/Slide $i.png"; done ;;
              *) echo exported > "$out" ;;
            esac
            """)
        let apps = dir.appendingPathComponent("apps")
        let pages = fakeApp("Pages.app", in: apps, executable: nil)
        let rig = Rig([.iwork: pages], osascript: osascript)
        func lastScript() -> String { (try? String(contentsOf: osascript.deletingLastPathComponent().appendingPathComponent("last"), encoding: .utf8)) ?? "" }
        check(rig.converter(.pages).availability() == .available, "Pages found")
        check(rig.converter(.keynote).availability() == .needsHelper(.iwork) && rig.converter(.numbers).availability() == .needsHelper(.iwork), "Keynote and Numbers not found (“Pages found”, “Get Numbers…”)")
        check(rig.service.foundApps(of: .iwork) == [pages], "which apps were found is reported")
        let pdf = complete(60) { try await rig.convert(.pages, "pages", "pdf", file: "Essay.pages") }
        check((try? pdf?.get())?.lastPathComponent == "Essay.pdf", "Pages → PDF")
        let script1 = lastScript()
        check(script1.contains("application id \"com.apple.iWork.Pages\"") && script1.contains("export theDocument to POSIX file") && script1.contains("as PDF"), "exports through Pages' dictionary")
        check(script1.contains("set wasRunning to application id \"com.apple.iWork.Pages\" is running") && script1.contains("if not wasRunning then quit"), "quits the app only if this run launched it")
        check(script1.contains("close theDocument saving no"), "never saves the original")
        for (to, phrase) in [("docx", "as Microsoft Word"), ("epub", "as EPUB"), ("txt", "as unformatted text")] {
            _ = complete(60) { try await rig.convert(.pages, "pages", FormatID(to), file: "Essay.pages") }
            check(lastScript().contains(phrase), "Pages → \(to): \(phrase)")
        }
        _ = complete(60) { try await rig.convert(.pages, "docx", "pages", file: "Essay.docx") }
        check(lastScript().contains("save theDocument in POSIX file"), "DOCX → Pages saves in Pages' own format")
        _ = complete(60) { try await rig.convert(.numbers, "numbers", "xlsx", file: "Sheet.numbers") }
        check(lastScript().contains("as Microsoft Excel") && lastScript().contains("com.apple.iWork.Numbers"), "Numbers → XLSX")
        let keynote = Rig([.iwork: fakeApp("Keynote.app", in: apps, executable: nil)], osascript: osascript)
        _ = complete(60) { try await keynote.convert(.keynote, "key", "pptx", file: "Deck.key") }
        check(lastScript().contains("as Microsoft PowerPoint"), "Keynote → PPTX")
        let slides = complete(60) { try await keynote.convert(.keynote, "key", "png", file: "Deck.key") }
        if let first = try? slides?.get() {
            check(first.lastPathComponent == "Deck – slide 1.png", "slides are named “<name> – slide N” (\(first.lastPathComponent))")
            check(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().appendingPathComponent("Deck – slide 3.png").path), "one picture per slide")
            check(lastScript().contains("slide images") && lastScript().contains("image format:PNG"), "Keynote exports slide images")
        } else { check(false, "Keynote → PNG") }
        let unsupported = complete(60) { try await rig.convert(.pages, "pages", "mp3", file: "Essay.pages") }
        if case .failure(let error)? = unsupported { check((error as? ConversionError) == .unsupportedPair(from: "pages", to: "mp3"), "a pair the app can't do is refused") } else { check(false, "Pages → MP3 must fail") }
        // The permission prompt: denial is explained, not a bare failure.
        let denied = script("osascript", in: dir.appendingPathComponent("deny"), "echo 'Not authorized to send Apple events (-1743)' >&2; exit 1")
        let drig = Rig([.iwork: pages], osascript: denied)
        let refusal = complete(60) { try await drig.convert(.pages, "pages", "pdf", file: "Essay.pages") }
        if case .failure(let error)? = refusal, case ConversionError.failed(let why) = error { check(why.contains("Automation"), "a refused Automation permission says where to allow it") } else { check(false, "denied Apple Events should fail") }
        // The service's own automate.
        let echo = script("osascript", in: dir.appendingPathComponent("echo"), "printf 'ok %s\\n' \"$2\"")
        let arig = Rig([.iwork: pages], osascript: echo)
        let said = complete(30) { try await arig.service.automate(app: .iwork, script: "return 1") }
        check((try? said?.get()) == "ok return 1", "automate returns the script's result")
        let nothing = complete(30) { try await Rig().service.automate(app: .iwork, script: "return 1") }
        if case .failure(let error)? = nothing { check((error as? ConversionError) == .helperMissing(.iwork), "automating an app that isn't there says so") } else { check(false, "automate without the app must fail") }
    }))

    // MARK: Registration

    SelfTest.cases.append(("HelperKit.installs", {
        let before = Services.converters
        Services.converters = ConverterList()
        defer { Services.converters = before }
        HelperKitModule.install()
        check(Services.helpers is HelperService, "install() provides Services.helpers")
        // The macOS commands run through the same runner as the bundled tools, from /usr/bin only.
        for tool in [BundledTool.hdiutil, .pluginkit] {
            check(Services.tools.location(of: tool)?.path == "/usr/bin/" + tool.rawValue, "Services.tools finds \(tool.rawValue) in /usr/bin")
        }
        check(BundledTools.name(of: .pluginkit) == "pluginkit", "a failed pluginkit run says “pluginkit”")
        // A read of an id nobody has: it changes nothing, and pkd answers it only outside the sandbox profile.
        let work = folder("pluginkit")
        let listing = complete(15) {
            try await Services.tools.run(ToolInvocation(tool: .pluginkit, arguments: ["-m", "-i", SuperConverterPaths.bundleID + ".selftest.none"], workFolder: work))
        }
        if case .success(let result)? = listing {
            check(result.exitCode == 0 && result.standardOutput.isEmpty, "pluginkit runs through Services.tools and lists nothing for an unknown id: \(result.standardError)")
        } else {
            check(false, "pluginkit runs through Services.tools")
        }
        let registered = Set(Services.converters.converters.map(\.id))
        let expected = Set(EngineID.allCases.filter { $0.info.module == .helperKit })
        check(registered == expected, "a converter for every engine HelperKit owns, and no other (\(registered.symmetricDifference(expected).map(\.rawValue)))")
        var steps = Set<Step>()
        for route in FormatMatrix.routes {
            for chain in [route.builtin, route.helper] + route.alternates.map({ Optional($0.steps) }) { steps.formUnion(chain ?? []) }
        }
        let used = Set(steps.map(\.engine))
        check(expected.isSubset(of: used), "every helper-run engine is used by a route (\(expected.subtracting(used).map(\.rawValue)))")
        for step in steps where expected.contains(step.engine) {
            check(Services.converters.converter(for: step.engine)?.handles(step) == true, "\(step) is handled by its converter")
        }
        for converter in Services.converters.converters {
            let helpers = converter.id.helpers
            check(!helpers.isEmpty, "\(converter.id.rawValue) names the helper it needs")
            if case .needsHelper(let helper) = converter.availability() { check(helpers.contains(helper), "\(converter.id.rawValue) asks for one of its own helpers") }
        }
    }))

    // MARK: Real helpers (opt-in)

    SelfTest.cases.append(("HelperKit.realHelpers", {
        guard ProcessInfo.processInfo.environment["SUPERCONVERTER_REAL_HELPERS"] == "1" else { return }
        let service = HelperService()
        _ = complete(120) { await service.settled() }
        let appsBefore = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let work = folder("real")
        var did = false
        if service.status(of: .libreoffice).isReady {
            did = true
            let source = work.appendingPathComponent("note.txt")
            try? "Hello from Super Converter.\n".write(to: source, atomically: true, encoding: .utf8)
            let converter = service.converters().first { $0.id == .libreOffice }!
            let context = StepContext(workFolder: work, source: source, sourceFormat: "txt", targetFormat: "pdf")
            let out = complete(180) { try await converter.run(Step(.libreOffice, "txt", "pdf"), input: .file(source), context: context) }
            if case .file(let url)? = (try? out?.get())?.value {
                check((try? Data(contentsOf: url))?.prefix(4) == Data("%PDF".utf8), "the real LibreOffice wrote a PDF")
            } else { check(false, "real LibreOffice conversion: \(String(describing: out))") }
        }
        if service.status(of: .pandoc).isReady {
            did = true
            let source = work.appendingPathComponent("note.rst")
            try? "Title\n=====\n\nSome *text* and a list:\n\n- one\n- two\n".write(to: source, atomically: true, encoding: .utf8)
            let converter = service.converters().first { $0.id == .pandoc }!
            let context = StepContext(workFolder: work, source: source, sourceFormat: "rst", targetFormat: "docx")
            let out = complete(60) { try await converter.run(Step(.pandoc, "rst", .docModel), input: .file(source), context: context) }
            if case .doc(let model)? = (try? out?.get())?.value { check(model.blocks.count >= 2, "real Pandoc's AST maps (\(model.blocks.count) blocks)") }
            else { check(false, "real Pandoc conversion: \(String(describing: out))") }
        }
        Thread.sleep(forTimeInterval: 1)
        check(ProcessRunner.descendants(of: getpid()).isEmpty, "no helper process is left running")
        let newApps = NSWorkspace.shared.runningApplications.filter { !appsBefore.contains($0.processIdentifier) && $0.processIdentifier != getpid() }
        check(newApps.isEmpty, "no GUI app or Dock icon appeared (\(newApps.map { $0.localizedName ?? "?" }))")
        print(did ? "  (ran against the helpers installed on this Mac)" : "  (no helper installed here to run against)")
    }))

    SelfTest.cases.append(("HelperKit.cleanup", {
        try? FileManager.default.removeItem(at: root)
    }))
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
