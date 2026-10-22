import AppKit
import Combine
import Foundation
import SuperConverterCore

// In-memory stand-ins for every `Services` contract, owned with SuperConverterCore: a change to a contract updates its fake
// in the same change. Module tests install the fakes they need (or `installFakes()`), then their own service. Fakes
// record what they were asked and answer with canned values; none opens an app, a URL or the network.

/// Registers a fake for every slot.
@MainActor
func installFakes() {
    Services.converters = ConverterList()
    Services.planner = FakePlanner()
    Services.queue = FakeQueue()
    Services.sniffer = FakeSniffer()
    Services.output = FakeOutput()
    Services.thumbnails = FakeThumbnails()
    Services.helpers = FakeHelpers()
    Services.window = FakeWindow()
    Services.menuBar = FakeMenuBar()
    Services.settings = FakeSettings()
    Services.updates = FakeUpdates()
}

struct FakeError: Error, Equatable { var message = "fake failure" }

/// A converter that handles the patterns it is given and answers with a canned output; records its calls.
final class FakeConverter: Converter, @unchecked Sendable {
    let id: EngineID
    let handles: [StepPattern]
    var available: EngineAvailability = .available
    var output: StepOutput
    private(set) var steps: [Step] = []

    init(_ id: EngineID, handles: [StepPattern] = [StepPattern(from: .anyFile, to: .anyFile)],
         output: StepOutput = StepOutput(.file(URL(fileURLWithPath: "/dev/null")))) {
        self.id = id; self.handles = handles; self.output = output
    }

    func availability() -> EngineAvailability { available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        steps.append(step)
        context.report(StepProgress(fraction: 1, unit: nil))
        return output
    }
}

@MainActor
final class FakePlanner: Planning {
    var requests: [ConversionRequest] = []
    var choice: RouteChoice = .builtin(steps: [])

    func plan(for request: ConversionRequest) -> ConversionPlan {
        requests.append(request)
        return ConversionPlan(request: request, choice: choice, optionProfile: "—")
    }

    func targets(for source: FormatID) -> [(format: FormatID, choice: RouteChoice)] {
        FormatMatrix.targets(for: source).map { ($0, choice) }
    }
}

@MainActor
final class FakeQueue: JobQueueing {
    private(set) var enqueued: [(plan: ConversionPlan, place: OutputPlace)] = []
    private(set) var cancelled: [JobID] = []
    private var continuation: AsyncStream<JobEvent>.Continuation?
    let events: AsyncStream<JobEvent>

    init() {
        var captured: AsyncStream<JobEvent>.Continuation?
        events = AsyncStream { captured = $0 }
        continuation = captured
    }

    var activeCount: Int { enqueued.count - cancelled.count }

    func enqueue(_ plan: ConversionPlan, into place: OutputPlace) -> JobID {
        let id = JobID()
        enqueued.append((plan, place))
        continuation?.yield(.queued(id))
        return id
    }

    func cancel(_ job: JobID) { cancelled.append(job); continuation?.yield(.cancelled(job)) }
    func cancelAll() {}
}

@MainActor
final class FakeSniffer: FormatSniffing {
    var results: [URL: SniffResult] = [:]

    func sniff(_ url: URL) throws -> SniffResult {
        results[url] ?? SniffResult(format: FormatCatalog.format(forFileName: url.lastPathComponent)?.id,
                                    claimed: FormatCatalog.format(forFileName: url.lastPathComponent)?.id)
    }
}

@MainActor
final class FakeOutput: OutputPolicy {
    func target(for source: URL, format: FormatID, place: OutputPlace, multipleFiles: Bool) throws -> OutputTarget {
        OutputTarget(url: source.deletingPathExtension().appendingPathExtension(format.rawValue), isFolder: multipleFiles)
    }
    func partName(base: String, kind: String, index: Int, format: FormatID) -> String { "\(base) – \(kind) \(index).\(format)" }
    func place(_ results: [URL], for source: URL, into target: OutputTarget) throws -> [URL] { results }
}

@MainActor
final class FakeThumbnails: Thumbnailing {
    private(set) var requested: [URL] = []
    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? { requested.append(url); return nil }
    func removeCache() {}
}

@MainActor
final class FakeHelpers: HelperManaging {
    var statuses: [HelperID: HelperStatus] = [:]
    private(set) var installs: [HelperID] = []
    private(set) var invocations: [HelperInvocation] = []
    var runResult = HelperRunResult(exitCode: 0)
    let statusChanges = AsyncStream<HelperID> { _ in }

    func status(of helper: HelperID) -> HelperStatus { statuses[helper] ?? .notInstalled }

    func install(_ helper: HelperID) -> AsyncStream<InstallProgress> {
        installs.append(helper)
        let location = URL(fileURLWithPath: "/dev/null")
        statuses[helper] = .installed(version: "0", location: location, sizeOnDisk: nil)
        return AsyncStream { continuation in
            continuation.yield(.finished(.installed(version: "0", location: location, sizeOnDisk: nil)))
            continuation.finish()
        }
    }

    func remove(_ helper: HelperID) throws { statuses[helper] = .notInstalled }
    func lookAgain() {}
    func run(_ invocation: HelperInvocation) async throws -> HelperRunResult { invocations.append(invocation); return runResult }
    func automate(app: HelperID, script: String) async throws -> String { "" }
}

@MainActor
final class FakeWindow: WindowPresenting {
    private(set) var shown = 0
    private(set) var added: [(urls: [URL], target: FormatID?)] = []
    var hasWork: Bool { !added.isEmpty }
    func show() { shown += 1 }
    func add(_ urls: [URL], target: FormatID?) { added.append((urls, target)) }
}

@MainActor
final class FakeMenuBar: MenuBarPresenting {
    private(set) var visible = false
    private(set) var panels: [[URL]] = []
    func install() {}
    func setVisible(_ visible: Bool) { self.visible = visible }
    func showPanel(with urls: [URL]) { panels.append(urls) }
}

@MainActor
final class FakeSettings: SettingsPresenting {
    private(set) var shown: [SettingsPane?] = []
    func show(pane: SettingsPane?) { shown.append(pane) }
}

@MainActor
final class FakeUpdates: UpdateChecking {
    private let subject = CurrentValueSubject<UpdateStatus, Never>(.idle)
    private(set) var started = false
    private(set) var checks = 0
    var status: UpdateStatus { subject.value }
    var statusChanges: AnyPublisher<UpdateStatus, Never> { subject.eraseToAnyPublisher() }
    func start() { started = true }
    func checkNow() { checks += 1; subject.send(.upToDate(checkedAt: Date())) }
    func installNow() {}
}
