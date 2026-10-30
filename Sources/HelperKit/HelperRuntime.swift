import Foundation
import SuperConverterCore

/// What the converters share: where each helper is right now (HelperService refreshes it), how to run one, and the private
/// places (LibreOffice's profile, Tectonic's cache). Converters hold one of these; they never touch `Process`.
final class HelperRuntime: @unchecked Sendable {
    let detector: HelperDetector
    let libreOfficeProfile: URL
    let tectonicCache: URL
    /// `/usr/bin/osascript`; a fake in the self-test.
    let osascript: URL
    let libreOfficeGate = SingleFile()

    private let lock = NSLock()
    private var locations: [HelperID: HelperLocation] = [:]
    /// Helpers found but not usable, with the reason (an FFmpeg without GPL encoders).
    private var blocked: [HelperID: String] = [:]

    init(detector: HelperDetector, libreOfficeProfile: URL, tectonicCache: URL, osascript: URL = URL(fileURLWithPath: "/usr/bin/osascript")) {
        self.detector = detector
        self.libreOfficeProfile = libreOfficeProfile
        self.tectonicCache = tectonicCache
        self.osascript = osascript
    }

    // MARK: Where helpers are

    /// Detects every helper again (file system only).
    func refresh() {
        var found: [HelperID: HelperLocation] = [:]
        for helper in HelperID.allCases { if let location = detector.locate(helper) { found[helper] = location } }
        lock.withLock {
            locations = found
            blocked = blocked.filter { found[$0.key] != nil }
        }
    }

    func location(of helper: HelperID) -> HelperLocation? { lock.withLock { blocked[helper] == nil ? locations[helper] : nil } }
    func foundLocation(of helper: HelperID) -> HelperLocation? { lock.withLock { locations[helper] } }
    func blockedReason(of helper: HelperID) -> String? { lock.withLock { blocked[helper] } }
    func setVersion(_ version: String, for helper: HelperID) { lock.withLock { locations[helper]?.version = version } }
    func setBlocked(_ reason: String?, for helper: HelperID) { lock.withLock { blocked[helper] = reason } }

    func availability(_ helpers: [HelperID]) -> EngineAvailability {
        helpers.contains { location(of: $0) != nil } ? .available : .needsHelper(helpers[0])
    }

    // MARK: Running

    /// Runs `executable` for `helper` in `workFolder` and maps the ways it fails to the cases ux §7.2 words.
    func run(_ helper: HelperID, _ executable: URL, _ arguments: [String], workFolder: URL, writable: [URL] = [],
             environment: [String: String] = [:], searchPath: [URL] = [], extraWriteFilters: [String] = [], timeLimit: TimeInterval? = nil,
             network: Bool = false, sandbox: Bool = true) async throws -> HelperRunResult {
        let limit = timeLimit ?? HelperCatalog.info(helper).timeLimit
        let spec = ProcessSpec(executable: executable, arguments: arguments, workFolder: workFolder, writable: writable,
                               environment: environment, searchPath: searchPath, extraWriteFilters: extraWriteFilters, timeLimit: limit,
                               network: network, launchServices: HelperCatalog.info(helper).isApp, sandbox: sandbox)
        do { return try await ProcessRunner.run(spec) }
        catch RunFailure.timedOut { throw ConversionError.helperTimedOut(helper, seconds: Int(limit ?? 0)) }
        catch RunFailure.cancelled { throw ConversionError.cancelled }
        catch RunFailure.couldNotStart(let why) { throw ConversionError.failed("\(HelperCatalog.info(helper).name) couldn’t start: \(why)") }
    }

    /// `run`, then a non-zero exit becomes `ConversionError.failed` with the tool's own last line.
    @discardableResult
    func runChecked(_ helper: HelperID, _ executable: URL, _ arguments: [String], workFolder: URL, writable: [URL] = [],
                    environment: [String: String] = [:], searchPath: [URL] = [], extraWriteFilters: [String] = [],
                    timeLimit: TimeInterval? = nil, network: Bool = false, sandbox: Bool = true) async throws -> HelperRunResult {
        let result = try await run(helper, executable, arguments, workFolder: workFolder, writable: writable, environment: environment,
                                   searchPath: searchPath, extraWriteFilters: extraWriteFilters, timeLimit: timeLimit, network: network,
                                   sandbox: sandbox)
        guard result.exitCode == 0 else {
            let text = (result.standardError.isEmpty ? result.standardOutput : result.standardError)
                .split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit code \(result.exitCode)"
            throw ConversionError.failed("\(HelperCatalog.info(helper).name) stopped: \(text)")
        }
        return result
    }

    /// The executable of a helper that must be there; `helperMissing` otherwise.
    func requireExecutable(_ helper: HelperID) throws -> URL {
        guard let location = location(of: helper) else { throw ConversionError.helperMissing(helper) }
        return location.executable
    }

    // MARK: Steps

    /// The file a step reads: the previous step's output, or the dropped file.
    static func inputFile(_ input: StepValue, _ context: StepContext) throws -> URL {
        if case .file(let url) = input { return url }
        return context.source
    }

    /// The file a helper reads: a copy (a clone on APFS) of `inputFile` in `folder` (a fresh one in the work folder when
    /// nil), named after the person's file but with the extension of the format it really is and nothing in the name a tool
    /// could misread. Helpers pick their reader by extension, and some readers run code (calibre runs a `.recipe` as Python),
    /// so a file that is really a MOBI reaches calibre as `.mobi` whatever it is called; `%` (Ghostscript's page-number
    /// pattern), control characters and a leading `-` are replaced. TeX and Pandoc read the file where it is, for the files
    /// it includes; their reader is named on the command line.
    static func stagedInput(_ input: StepValue, _ step: Step, _ context: StepContext, in folder: URL? = nil) throws -> URL {
        let original = try inputFile(input, context)
        let format: FormatID
        if case .format(let from) = step.from { format = from } else { format = context.sourceFormat }
        let place = try folder ?? outputFolder(context, "in")
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let staged = place.appendingPathComponent(safeName(original.deletingPathExtension().lastPathComponent)).appendingPathExtension(format.rawValue)
        try FileManager.default.copyItem(at: original, to: staged)
        return staged
    }

    /// `name` with `%`, `/`, `:` and control characters replaced and no leading `-` or `.`; "input" when nothing is left.
    static func safeName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            let unsafe = scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format || "%/:".unicodeScalars.contains(scalar)
            scalars.append(unsafe ? "_" : scalar)
        }
        var safe = String(scalars)
        while let first = safe.first, first == "-" || first == "." { safe = "_" + safe.dropFirst() }
        return safe.isEmpty ? "input" : safe
    }

    /// A fresh folder under the job's work folder for one step's output, so a tool never overwrites its input.
    static func outputFolder(_ context: StepContext, _ name: String) throws -> URL {
        if context.isCancelled() { throw ConversionError.cancelled }
        let folder = context.workFolder.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `<folder>/<input name>.<target extension>`; the tool is told to write exactly there, or it is looked for.
    static func outputURL(in folder: URL, input: URL, extension ext: String) -> URL {
        folder.appendingPathComponent(input.deletingPathExtension().lastPathComponent).appendingPathExtension(ext)
    }

    /// The file a tool wrote: the expected one, else the only file in the folder with the right extension.
    static func produced(_ expected: URL, in folder: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: expected.path) { return expected }
        let ext = expected.pathExtension.lowercased()
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        if let match = files.first(where: { $0.pathExtension.lowercased() == ext }) { return match }
        throw ConversionError.failed("The helper finished but wrote nothing.")
    }

    /// One at a time (LibreOffice: one process per profile). Waiters resume in order.
    actor SingleFile {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func enter() async {
            if !busy { busy = true; return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func leave() { if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() } }
    }
}
