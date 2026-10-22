// Adapted from Super PDF Sources/ConvertKit/Helpers/HelperService.swift (commit 058469b): detection that only looks at the
// file system, a change stream, nothing launched. Added: the one-click installer, remove, the runner and app automation.

import Foundation
import SuperConverterCore

enum HelperError: Error, LocalizedError, Equatable {
    /// Found where Homebrew or the person put it, not installed by us: nothing here to remove.
    case notInstalledByUs(HelperID)
    case alreadyInstalling(HelperID)
    case notOneClick(HelperID)
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalledByUs(let h): "\(HelperCatalog.info(h).name) wasn’t installed by Super Converter, so it stays where it is."
        case .alreadyInstalling(let h): "\(HelperCatalog.info(h).name) is already being installed."
        case .notOneClick(let h): "\(HelperCatalog.info(h).name) can’t be installed from here."
        case .scriptFailed(let why): why
        }
    }
}

/// What "Get…" does for a helper that is not installed by one click (formats §2.9, §4).
public enum HelperGetAction: Equatable, Sendable {
    /// The Install button.
    case installHere
    /// Opens the vendor's page (ODA File Converter, RARLAB).
    case openPage(URL)
    /// Opens the App Store page (Pages, Numbers, Keynote).
    case openAppStore(URL)
    /// Explains `brew install <formula>`; the app never runs Homebrew itself.
    case homebrew(formula: String, command: String)
    /// Explains building it from source.
    case buildFromSource(URL)
    /// Detected only (Microsoft Office).
    case nothing
}

/// `Services.helpers`: finds every helper in the catalog, installs the upstream ones, runs them (ARCHITECTURE §7).
@MainActor
public final class HelperService: HelperManaging {
    private let runtime: HelperRuntime
    private let installer: HelperInstaller
    private let store: RecordStore
    private let pinFor: @Sendable (HelperID) -> HelperPin?
    private let removeItem: @Sendable (URL) throws -> Void
    private let removeCache: @Sendable () -> Void

    private var installing: [HelperID: Double] = [:]
    private var sizes: [HelperID: Int64] = [:]
    private var subscribers: [UUID: AsyncStream<HelperID>.Continuation] = [:]
    private var probe: Task<Void, Never>?
    private var probeGeneration = 0

    /// - Parameters:
    ///   - override: the path set in Settings › Helpers, by helper (the app target reads it from Defaults).
    public convenience init(override: @escaping @Sendable (HelperID) -> URL? = { _ in nil }) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(override: override, applications: home.appendingPathComponent("Applications", isDirectory: true),
                  recordFile: SuperConverterPaths.helpersRecord, libreOfficeProfile: SuperConverterPaths.libreOfficeProfile,
                  tectonicCache: SuperConverterPaths.tectonicCache, helperFolder: { SuperConverterPaths.helper($0, version: $1) },
                  installer: nil, pins: { HelperPins.pin(for: $0) }, osascript: URL(fileURLWithPath: "/usr/bin/osascript"),
                  remove: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
    }

    init(override: @escaping @Sendable (HelperID) -> URL?, applications: URL, recordFile: URL, libreOfficeProfile: URL,
         tectonicCache: URL, helperFolder: @escaping @Sendable (HelperID, String) -> URL, installer: HelperInstaller?,
         pins: @escaping @Sendable (HelperID) -> HelperPin?, osascript: URL, remove: @escaping @Sendable (URL) throws -> Void,
         searchKnownPlaces: Bool = true) {
        let store = RecordStore(file: recordFile)
        self.store = store
        var detector = HelperDetector(override: override, records: { store.read() })
        detector.searchKnownPlaces = searchKnownPlaces
        runtime = HelperRuntime(detector: detector,
                                libreOfficeProfile: libreOfficeProfile, tectonicCache: tectonicCache, osascript: osascript)
        self.installer = installer ?? HelperInstaller(applicationsFolder: applications, helperFolder: helperFolder)
        pinFor = pins
        removeItem = remove
        removeCache = { try? FileManager.default.removeItem(at: tectonicCache); SuperConverterPaths.ensure(tectonicCache) }
        runtime.refresh()
        startProbe()
    }

    deinit { probe?.cancel() }

    // MARK: Converters

    /// Registers every helper-run engine's converter (ARCHITECTURE §4: helper-run engines belong to HelperKit).
    func converters() -> [any Converter] {
        [LibreOfficeConverter(runtime: runtime), CalibreConverter(runtime: runtime), PandocConverter(runtime: runtime),
         TectonicConverter(runtime: runtime), GhostscriptConverter(runtime: runtime), DjVuLibreConverter(runtime: runtime),
         DWGConverter(runtime: runtime), FFmpegGPLConverter(runtime: runtime), RARConverter(runtime: runtime),
         SfArkConverter(runtime: runtime), IWorkConverter(runtime: runtime, app: .pages), IWorkConverter(runtime: runtime, app: .numbers),
         IWorkConverter(runtime: runtime, app: .keynote)]
    }

    // MARK: HelperManaging

    public func status(of helper: HelperID) -> HelperStatus {
        if let fraction = installing[helper] { return .installing(fraction: fraction) }
        if let location = runtime.location(of: helper) {
            return .installed(version: location.version, location: location.bundle ?? location.executable, sizeOnDisk: sizes[helper])
        }
        if let reason = runtime.blockedReason(of: helper) { return .unusable(reason) }
        return .notInstalled
    }

    /// The apps of an iWork or Office helper that are present, for "Pages and Keynote found".
    public func foundApps(of helper: HelperID) -> [URL] { runtime.detector.apps(of: helper) }

    public func lookAgain() {
        let before = HelperID.allCases.map { status(of: $0) }
        runtime.refresh()
        notifyChanges(since: before)
        startProbe()
    }

    public var statusChanges: AsyncStream<HelperID> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[id] = nil } }
        }
    }

    public func install(_ helper: HelperID) -> AsyncStream<InstallProgress> {
        AsyncStream { continuation in
            guard case .oneClick = HelperCatalog.info(helper).install, let pin = pinFor(helper) else {
                continuation.yield(.failed(HelperError.notOneClick(helper).localizedDescription)); continuation.finish(); return
            }
            guard installing[helper] == nil else {
                continuation.yield(.failed(HelperError.alreadyInstalling(helper).localizedDescription)); continuation.finish(); return
            }
            setInstalling(helper, 0)
            let task = Task { @MainActor in
                do {
                    let installed = try await installer.install(pin) { progress in
                        continuation.yield(progress)
                        if case .downloading(let fraction) = progress { Task { @MainActor in self.setFraction(helper, fraction) } }
                    }
                    store.write(helper, InstalledRecord(version: installed.version, path: installed.path.path, installedAt: Date()))
                    if helper == .tectonic { continuation.yield(.unpacking); try await warmUpTectonic(installed.path) }
                    finishInstalling(helper)
                    continuation.yield(.finished(status(of: helper)))
                } catch {
                    finishInstalling(helper)
                    continuation.yield(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func remove(_ helper: HelperID) throws {
        guard let record = store.read()[helper] else { throw HelperError.notInstalledByUs(helper) }
        let before = HelperID.allCases.map { status(of: $0) }
        let target = URL(fileURLWithPath: record.path)
        if HelperCatalog.info(helper).isApp { try removeItem(target) }
        else { try removeItem(target.deletingLastPathComponent().deletingLastPathComponent()) }
        if helper == .tectonic { removeCache() }
        store.remove(helper)
        sizes[helper] = nil
        runtime.refresh()
        notifyChanges(since: before)
    }

    public func run(_ invocation: HelperInvocation) async throws -> HelperRunResult {
        guard let location = runtime.location(of: invocation.helper) else { throw ConversionError.helperMissing(invocation.helper) }
        return try await runtime.run(invocation.helper, location.executable, invocation.arguments, workFolder: invocation.workFolder,
                                     timeLimit: invocation.timeLimit)
    }

    public func automate(app: HelperID, script: String) async throws -> String {
        guard runtime.location(of: app) != nil else { throw ConversionError.helperMissing(app) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("superconverter-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await runtime.run(app, runtime.osascript, ["-e", script], workFolder: folder, timeLimit: IWorkConverter.timeLimit, sandbox: false)
        guard result.exitCode == 0 else { throw HelperError.scriptFailed(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: "Get…"

    public nonisolated static func getAction(for helper: HelperID) -> HelperGetAction {
        switch HelperCatalog.info(helper).install {
        case .oneClick: .installHere
        case .vendorPage(let url): .openPage(url)
        case .appStore(let url): .openAppStore(url)
        case .homebrew(let formula): .homebrew(formula: formula, command: "brew install \(formula)")
        case .buildFromSource(let url): .buildFromSource(url)
        case .detectOnly: .nothing
        }
    }

    // MARK: Changes and the background pass

    private func setInstalling(_ helper: HelperID, _ fraction: Double) { installing[helper] = fraction; emit(helper) }
    private func setFraction(_ helper: HelperID, _ fraction: Double) {
        guard installing[helper] != nil else { return }
        installing[helper] = fraction
        emit(helper)
    }
    private func finishInstalling(_ helper: HelperID) {
        installing[helper] = nil
        runtime.refresh()
        emit(helper)
        startProbe()
    }

    private func emit(_ helper: HelperID) { for continuation in subscribers.values { continuation.yield(helper) } }

    private func notifyChanges(since before: [HelperStatus]) {
        for (helper, old) in zip(HelperID.allCases, before) where status(of: helper) != old { emit(helper) }
    }

    /// Versions that the file system couldn't give, sizes on disk, and whether an FFmpeg has GPL encoders: this launches the
    /// tools with `--version` (sandboxed, 8 s), so it runs in the background, and the planner hears about every change.
    private func startProbe() {
        probe?.cancel()
        probeGeneration += 1
        let generation = probeGeneration
        let runtime = runtime
        let found = HelperID.allCases.compactMap { runtime.foundLocation(of: $0) }
        probe = Task.detached { [weak self] in
            for location in found {
                if Task.isCancelled { return }
                let helper = location.helper
                var version = location.version, reason: String?
                if location.bundle == nil, version == nil || helper == .ffmpegGPL, let output = await Self.probeOutput(helper, location.executable, runtime) {
                    version = version ?? HelperDetector.parseVersion(output)
                    if helper == .ffmpegGPL, !output.contains("--enable-gpl") { reason = "This FFmpeg was built without GPL encoders." }
                }
                let size = location.bundle.flatMap { Self.diskSize($0) } ?? (location.installedByUs ? Self.diskSize(location.executable) : nil)
                await self?.apply(helper, version: version, size: size, blockedReason: reason)
            }
            await self?.probeFinished(generation)
        }
    }

    private func apply(_ helper: HelperID, version: String?, size: Int64?, blockedReason: String?) {
        let before = status(of: helper)
        if let version { runtime.setVersion(version, for: helper) }
        runtime.setBlocked(blockedReason, for: helper)
        sizes[helper] = size
        if status(of: helper) != before { emit(helper) }
    }

    private func probeFinished(_ generation: Int) { if generation == probeGeneration { probe = nil } }

    /// Resolves when the background pass has finished (the self-test waits on it).
    func settled() async { await probe?.value }

    private nonisolated static func probeOutput(_ helper: HelperID, _ tool: URL, _ runtime: HelperRuntime) async -> String? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("superconverter-probe-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: folder) }
        let argument = [HelperID.ffmpegGPL: "-version", .djvulibre: "--help", .rar: "--help"][helper] ?? "--version"
        guard let result = try? await runtime.run(helper, tool, [argument], workFolder: folder, timeLimit: 8) else { return nil }
        return result.standardOutput + "\n" + result.standardError
    }

    private nonisolated static func diskSize(_ url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        if (try? url.resourceValues(forKeys: keys))?.isDirectory != true {
            return (try? url.resourceValues(forKeys: keys))?.totalFileAllocatedSize.map(Int64.init)
        }
        var total: Int64 = 0
        for case let file as URL in FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) ?? NSEnumerator() {
            total += Int64((try? file.resourceValues(forKeys: keys))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Compiles one document with network so Tectonic's common packages are cached; conversions then run with `--only-cached`.
    private func warmUpTectonic(_ tool: URL) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("superconverter-warmup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("warmup.tex")
        try TectonicConverter.warmUpDocument.write(to: document, atomically: true, encoding: .utf8)
        let cache = runtime.tectonicCache
        let result = try await runtime.run(.tectonic, tool, ["-X", "compile", "--outdir", folder.path, document.path], workFolder: folder,
                                           writable: [cache], environment: ["TECTONIC_CACHE_DIR": cache.path], timeLimit: 600, network: true)
        guard result.exitCode == 0 else {
            throw HelperError.scriptFailed("Tectonic couldn’t fetch its LaTeX packages. Check your connection and try again.")
        }
    }
}

/// `helpers.json`: what the one-click installer put on this Mac (ARCHITECTURE §8).
final class RecordStore: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    init(file: URL) { self.file = file }

    func read() -> [HelperID: InstalledRecord] {
        lock.withLock {
            guard let data = try? Data(contentsOf: file), let raw = try? decoder.decode([String: InstalledRecord].self, from: data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in HelperID(rawValue: key).map { ($0, value) } })
        }
    }

    func write(_ helper: HelperID, _ record: InstalledRecord) { update { $0[helper.rawValue] = record } }
    func remove(_ helper: HelperID) { update { $0[helper.rawValue] = nil } }

    private func update(_ change: (inout [String: InstalledRecord]) -> Void) {
        lock.withLock {
            var raw = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([String: InstalledRecord].self, from: $0) } ?? [:]
            change(&raw)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? encoder.encode(raw) { try? data.write(to: file, options: .atomic) }
        }
    }

    private var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
