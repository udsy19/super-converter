import AppKit
import SuperConverterCore
import ConvertKit

// ConvertKit's checks (WP-P): planning over the generated matrix, the queue (limits, cancellation, progress, errors), output
// naming, the sniffer, thumbnails, work folders, coverage and the sconv command. Engines are fakes that write real files into
// the job's work folder; the real engines plug in through the same registry as they land.

// MARK: Fakes

/// Counts converters running at once.
private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private(set) var maxRunning = 0
    private(set) var steps: [Step] = []
    private(set) var contexts: [StepContext] = []

    func enter(_ step: Step, _ context: StepContext) {
        lock.lock(); defer { lock.unlock() }
        running += 1; maxRunning = max(maxRunning, running); steps.append(step); contexts.append(context)
    }
    func leave() { lock.lock(); running -= 1; lock.unlock() }
}

/// A one-way switch for tests that hold a converter until the test says go.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
    func release() { lock.lock(); open = true; lock.unlock() }
}

private typealias Behavior = @Sendable (Step, StepValue, StepContext) async throws -> StepOutput

private func everyPattern() -> [StepPattern] {
    let ends: [StepPattern.End] = [.anyFile] + ModelKind.allCases.map { .model($0) }
    return ends.flatMap { from in ends.map { StepPattern(from: from, to: $0) } }
}

/// An engine that handles every step and runs `behavior`.
private final class ScriptedConverter: Converter, @unchecked Sendable {
    let id: EngineID
    let handles = everyPattern()
    var available: EngineAvailability = .available
    let behavior: Behavior
    init(_ id: EngineID, _ behavior: @escaping Behavior) { self.id = id; self.behavior = behavior }
    func availability() -> EngineAvailability { available }
    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        try await behavior(step, input, context)
    }
}

/// Writes the step's file into the work folder (the target's name on the last step), after `delay` seconds.
private func writing(_ probe: Probe, delay: Double = 0, lossNotes: [LossNote] = []) -> Behavior {
    { step, _, context in
        probe.enter(step, context); defer { probe.leave() }
        context.report(StepProgress(fraction: 0.5, unit: "Page 1 of 2"))
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        let base = context.source.deletingPathExtension().lastPathComponent
        let name = context.isFinalStep ? "\(base).\(context.targetFormat)" : "\(step.engine.rawValue)-\(UUID().uuidString).bin"
        let url = context.workFolder.appendingPathComponent(name)
        try Data("converted by \(step.engine)".utf8).write(to: url)
        return StepOutput(.file(url), lossNotes: lossNotes)
    }
}

@MainActor
private func registry(_ behavior: @escaping Behavior, engines: [EngineID] = EngineID.allCases) -> ConverterList {
    let list = ConverterList()
    for engine in engines { list.register(ScriptedConverter(engine, behavior)) }
    return list
}

private func tempFolder(_ name: String) -> URL {
    let url = scratch.appendingPathComponent("ck-\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to folder: URL, _ name: String) -> URL {
    let url = folder.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? Data(text.utf8).write(to: url)
    return url
}

private let terminal: (JobEvent) -> JobID? = {
    switch $0 {
    case .finished(let id, _), .failed(let id, _), .cancelled(let id): id
    default: nil
    }
}

@MainActor
private struct Stack {
    var helpers = FakeHelpers()
    var registry: ConverterList
    var planner: Planner
    var output: OutputRules
    var queue: JobQueue
    var downloads: URL

    init(_ behavior: @escaping Behavior, limits: ConcurrencyLimits = ConcurrencyLimits(), policy: CollisionPolicy = .addNumber,
         helperChanges: AsyncStream<HelperID>? = nil, engines: [EngineID] = EngineID.allCases) {
        registry = ConverterSetup.make(behavior, engines)
        let helpers = self.helpers
        planner = Planner(registry: registry, helperReady: { helpers.status(of: $0).isReady })
        downloads = tempFolder("downloads")
        output = OutputRules(collisionPolicy: { policy }, downloads: downloads)
        queue = JobQueue(registry: registry, output: output, limits: limits, helperStatus: { helpers.status(of: $0) },
                         helperChanges: helperChanges)
    }
}

private enum ConverterSetup {
    @MainActor static func make(_ behavior: @escaping Behavior, _ engines: [EngineID]) -> ConverterList { registry(behavior, engines: engines) }
}

/// Plans `source` → `target` and runs it to its end; returns every event of the run.
@MainActor
private func run(_ stack: Stack, _ source: URL, _ from: FormatID, _ to: FormatID, place: OutputPlace = .nextToOriginal,
                 look: DocumentLook? = nil) -> [JobEvent] {
    let result = complete(30) {
        let events = stack.queue.events
        let plan = stack.planner.plan(for: ConversionRequest(source: source, sourceFormat: from, target: to, look: look))
        let id = stack.queue.enqueue(plan, into: place)
        var log: [JobEvent] = []
        for await event in events {
            log.append(event)
            if terminal(event) == id { break }
        }
        return log
    }
    return (try? result?.get()) ?? []
}

private func jobFolders() -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: SuperConverterPaths.jobs.path)) ?? [])
}

private func isFinished(_ event: JobEvent) -> ConversionResult? { if case .finished(_, let r) = event { r } else { nil } }
private func failure(_ events: [JobEvent]) -> ConversionError? { events.compactMap { if case .failed(_, let e) = $0 { e } else { nil } }.first }

private func routes(_ matching: (Route) -> Bool) -> Route? { FormatMatrix.offered.first(where: matching) }

// MARK: Registration

func registerConvertKitTests() {
    func add(_ name: String, _ body: @escaping @MainActor () -> Void) { SelfTest.cases.append(("ConvertKit.\(name)", body)) }

    // MARK: Planning

    add("planner.everyOfferedPairHasContiguousSteps") {
        let planner = Planner(registry: registry(writing(Probe())), helperReady: { _ in true })
        var unplanned = 0
        for route in FormatMatrix.offered {
            let plan = planner.plan(for: ConversionRequest(source: URL(fileURLWithPath: "/x"), sourceFormat: route.from, target: route.to))
            let steps = plan.choice.steps
            if steps.isEmpty { unplanned += 1; check(false, "\(route.from)→\(route.to) has no plan"); continue }
            for pair in zip(steps, steps.dropFirst()) { check(pair.0.to == pair.1.from, "\(route.from)→\(route.to): \(pair.0) then \(pair.1)") }
            if case .format(let first) = steps.first!.from { check(FormatCatalog.isSameFormat(first, route.from), "\(route.from)→\(route.to) starts at \(first)") }
            if case .format(let last) = steps.last!.to { check(FormatCatalog.isSameFormat(last, route.to), "\(route.from)→\(route.to) ends at \(last)") }
            check(OptionProfiles.profile(plan.optionProfile) != nil, "\(route.from)→\(route.to) profile \(plan.optionProfile)")
        }
        check(unplanned == 0, "\(unplanned) pairs without a plan")
    }

    add("planner.everyCategoryHasBuiltInAndMultiStepRoutes") {
        let planner = Planner(registry: registry(writing(Probe())), helperReady: { _ in false })
        for category in FormatCategory.allCases {
            let sources = FormatCatalog.inputs.filter { $0.category == category }
            check(sources.contains { !planner.targets(for: $0.id).isEmpty }, "\(category) offers targets")
            let builtIn = sources.flatMap { planner.targets(for: $0.id) }.contains { if case .builtin = $0.choice { true } else { false } }
            check(builtIn, "\(category) converts with nothing installed")
        }
        let chain = routes { ($0.builtin?.count ?? 0) >= 3 }!
        let plan = planner.plan(for: ConversionRequest(source: URL(fileURLWithPath: "/x"), sourceFormat: chain.from, target: chain.to))
        check(plan.choice == .builtin(steps: chain.builtin!), "multi-step route planned through its intermediate models")
        check(chain.builtin!.contains { $0.from.isModel || $0.to.isModel }, "route goes through a model")
    }

    add("planner.nothingRegisteredMeansUnavailable") {
        let planner = Planner(registry: ConverterList(), helperReady: { _ in true })
        let plan = planner.plan(for: ConversionRequest(source: URL(fileURLWithPath: "/x"), sourceFormat: "png", target: "jpg"))
        guard case .unavailable(.engineUnavailable) = plan.choice else { check(false, "got \(plan.choice)"); return }
        check(planner.targets(for: "png").allSatisfy { if case .unavailable = $0.choice { true } else { false } }, "every target unavailable")
    }

    add("planner.engineAvailabilityIsCachedUntilRefresh") {
        let list = registry(writing(Probe()))
        let planner = Planner(registry: list, helperReady: { _ in true })
        let request = ConversionRequest(source: URL(fileURLWithPath: "/x"), sourceFormat: "png", target: "jpg")
        let engine = FormatMatrix.route(from: "png", to: "jpg")!.builtin!.first!.engine
        (list.converter(for: engine) as! ScriptedConverter).available = .unavailable("Needs macOS 15")
        check(planner.plan(for: request).choice.steps.isEmpty == false, "still planned before refresh")
        planner.refresh()
        check(planner.plan(for: request).choice == .unavailable(reason: .engineUnavailable(engine, "Needs macOS 15")), "unavailable after refresh")
    }

    add("planner.notOfferedAndUnknownPairs") {
        let planner = Planner(registry: registry(writing(Probe())), helperReady: { _ in true })
        let blocked = FormatMatrix.routes.first { !$0.isOffered }!
        let plan = planner.plan(for: ConversionRequest(source: URL(fileURLWithPath: "/x"), sourceFormat: blocked.from, target: blocked.to))
        check(plan.choice == .unavailable(reason: .notOffered(blocked.note)), "not offered carries the matrix note")
        let unknown = planner.plan(for: ConversionRequest(source: URL(fileURLWithPath: "/x"), sourceFormat: "ttf", target: "mp4"))
        if case .unavailable(.notOffered(let why)) = unknown.choice { check(!why.isEmpty, "says why") } else { check(false, "ttf→mp4 should not plan") }
    }

    add("planner.helperRoutesAndPreference") {
        let helpers = FakeHelpers()
        let planner = Planner(registry: registry(writing(Probe())), helperReady: { helpers.status(of: $0).isReady })
        let source = URL(fileURLWithPath: "/x")

        // A pair only a helper can do: "Needs LibreOffice" until it is installed.
        let only = routes { $0.builtin == nil && $0.helper != nil && $0.helpers == [.libreoffice] }!
        let request = ConversionRequest(source: source, sourceFormat: only.from, target: only.to)
        guard case .helper(_, let needed, let missing) = planner.plan(for: request).choice else { check(false, "helper route expected"); return }
        check(needed == [.libreoffice] && missing == [.libreoffice], "missing LibreOffice")
        helpers.statuses[.libreoffice] = .installed(version: "1", location: source, sizeOnDisk: nil)
        guard case .helper(_, _, let after) = planner.plan(for: request).choice else { check(false, "still a helper route"); return }
        check(after.isEmpty, "nothing missing once installed")

        // A built-in pair the helper does better: built in without it, helper with it, override either way.
        helpers.statuses = [:]
        let optional = routes { $0.builtin != nil && $0.helper != nil && $0.prefer == .helper && $0.helpers == [.libreoffice] }!
        let pair = ConversionRequest(source: source, sourceFormat: optional.from, target: optional.to)
        let without = planner.plan(for: pair)
        check(without.choice == .builtin(steps: optional.builtin!) && without.betterWithHelper == .libreoffice, "built in, offers the helper")
        helpers.statuses[.libreoffice] = .installed(version: "1", location: source, sizeOnDisk: nil)
        check(planner.plan(for: pair).choice == .helper(steps: optional.helper!, helpers: [.libreoffice], missing: []), "helper preferred when present")
        var builtinPair = pair; builtinPair.preferHelper = false
        check(planner.plan(for: builtinPair).choice == .builtin(steps: optional.builtin!), "preferHelper false keeps built in")
        var original = pair; original.look = .original
        check(planner.plan(for: original).choice.steps == optional.helper!, "Look: Original uses the helper")
        var written = pair; written.look = .asWritten
        check(planner.plan(for: written).choice.steps == optional.builtin!, "Look: As written stays built in")
    }

    add("planner.latexLookIsAnAlternate") {
        let planner = Planner(registry: registry(writing(Probe())), helperReady: { _ in false })
        let route = routes { $0.alternates.contains { $0.look == .latex && $0.via == .builtin } && $0.builtin != nil }!
        let alternate = route.alternates.first { $0.look == .latex && $0.via == .builtin }!
        var request = ConversionRequest(source: URL(fileURLWithPath: "/x"), sourceFormat: route.from, target: route.to)
        let normal = planner.plan(for: request)
        check(normal.availableLooks.contains(.latex) && normal.availableLooks.contains(.asWritten), "looks offered: \(normal.availableLooks)")
        request.look = .latex
        let latex = planner.plan(for: request)
        check(latex.choice == .builtin(steps: alternate.steps), "LaTeX look follows the alternate")
        check(planner.plan(for: ConversionRequest(source: URL(fileURLWithPath: "/x"), sourceFormat: "png", target: "jpg")).availableLooks.isEmpty, "no looks for an image")
    }

    add("planner.familyMembersShareRoutes") {
        let planner = Planner(registry: registry(writing(Probe())), helperReady: { _ in true })
        for family in ["jpeg", "jfif"] where FormatCatalog.format(FormatID(family)) != nil {
            check(!planner.targets(for: FormatID(family)).isEmpty, "\(family) has targets")
            let plan = planner.plan(for: ConversionRequest(source: URL(fileURLWithPath: "/x"), sourceFormat: FormatID(family), target: "png"))
            check(!plan.choice.steps.isEmpty, "\(family)→png plans")
        }
    }

    // MARK: Coverage

    add("coverage.reportsMissingUnusedAndUnhandled") {
        let full = Coverage.verify(registry(writing(Probe())).converters)
        check(full.missingEngines.isEmpty && full.unhandledSteps.isEmpty, "a converter per engine covers the matrix")
        check(full.unusedConverters.count == EngineID.allCases.count - FormatMatrix.offered.reduce(into: Set<EngineID>()) { $0.formUnion($1.engines) }.count,
              "unused engines are named")

        let none = Coverage.verify([])
        check(!none.missingEngines.isEmpty && !none.isComplete, "an empty registry misses engines")

        let engine = FormatMatrix.route(from: "png", to: "jpg")!.builtin!.first!.engine
        final class Picky: Converter, @unchecked Sendable {
            let id: EngineID
            let handles: [StepPattern] = [StepPattern(from: .formats(["zzz"]), to: .formats(["zzz"]))]
            init(_ id: EngineID) { self.id = id }
            func availability() -> EngineAvailability { .available }
            func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput { StepOutput(input) }
        }
        let picky = Coverage.verify([Picky(engine)])
        check(!picky.unhandledSteps.isEmpty && !picky.missingEngines.contains(engine), "a converter that handles nothing it is routed")
    }

    add("install.wiresServicesAndReportsCoverage") {
        let saved = (Services.planner, Services.queue, Services.sniffer, Services.output, Services.thumbnails, Services.converters)
        defer { (Services.planner, Services.queue, Services.sniffer, Services.output, Services.thumbnails, Services.converters) = saved }
        Services.converters = ConverterList()
        ConvertKitModule.install()
        check(Services.planner is Planner && Services.queue is JobQueue && Services.sniffer is FormatSniffer, "services installed")
        check(Services.output is OutputRules && Services.thumbnails is ThumbnailService, "output and thumbnails installed")
        check(!ConvertKitModule.coverage.missingEngines.isEmpty, "coverage is recorded")
    }

    // MARK: Queue

    add("queue.convertsAndPlacesNextToTheOriginal") {
        let foldersBefore = jobFolders()
        let folder = tempFolder("basic")
        let source = write("pixels", to: folder, "Photo.png")
        let created = Date(timeIntervalSince1970: 1_000_000_000)
        try? FileManager.default.setAttributes([.creationDate: created, .modificationDate: created], ofItemAtPath: source.path)
        let probe = Probe()
        let stack = Stack(writing(probe, lossNotes: [LossNote(.metadataDropped)]))
        let events = run(stack, source, "png", "jpg")
        guard let result = events.compactMap(isFinished).first else { check(false, "no result: \(events)"); return }
        check(result.outputs == [folder.appendingPathComponent("Photo.jpg")], "named like the original: \(result.outputs)")
        check(FileManager.default.fileExists(atPath: result.outputs[0].path) && FileManager.default.fileExists(atPath: source.path), "output made, source kept")
        let attributes = try? FileManager.default.attributesOfItem(atPath: result.outputs[0].path)
        check((attributes?[.modificationDate] as? Date) == created && (attributes?[.creationDate] as? Date) == created, "dates copied from the source")
        check(result.lossNotes == [LossNote(.metadataDropped)], "loss notes surface once across steps")
        check(result.inputBytes == 6 && result.outputBytes > 0, "sizes reported")
        check(probe.steps == FormatMatrix.route(from: "png", to: "jpg")!.builtin!, "the route’s steps ran in order")
        check(probe.contexts.last?.isFinalStep == true && probe.contexts.first?.isFinalStep == (probe.contexts.count == 1), "final step flagged")
        check(events.contains { if case .started = $0 { true } else { false } } && events.contains { if case .queued = $0 { true } else { false } }, "queued and started")
        let progress = events.compactMap { if case .progress(_, let p) = $0 { p } else { nil } }
        check(progress.contains { $0.unit == "Page 1 of 2" && $0.fraction != nil }, "progress carries the unit")
        check(progress.allSatisfy { ($0.fraction ?? 0) <= 1 }, "fraction stays within 0…1")
        check(jobFolders().isSubset(of: foldersBefore), "work folder removed")
        check(stack.queue.activeCount == 0, "queue idle")
    }

    add("queue.neverOverwritesWhenConvertingTwice") {
        let folder = tempFolder("twice")
        let source = write("a", to: folder, "Report.docx")
        let stack = Stack(writing(Probe()))
        let first = run(stack, source, "docx", "pdf").compactMap(isFinished).first?.outputs
        let second = run(stack, source, "docx", "pdf").compactMap(isFinished).first?.outputs
        check(first == [folder.appendingPathComponent("Report.pdf")] && second == [folder.appendingPathComponent("Report 2.pdf")], "second run is “Report 2.pdf”: \(String(describing: second))")
    }

    add("queue.multiFileResultGoesIntoAFolder") {
        let folder = tempFolder("pages")
        let source = write("a", to: folder, "Deck.pdf")
        let pages: Behavior = { _, _, context in
            let out = context.workFolder.appendingPathComponent("pages", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for n in 1...3 { try Data("p\(n)".utf8).write(to: out.appendingPathComponent("Deck – page \(n).png")) }
            return StepOutput(.file(out))
        }
        let stack = Stack(pages)
        let result = run(stack, source, "pdf", "png").compactMap(isFinished).first
        let target = folder.appendingPathComponent("Deck (PNG)")
        check(result?.outputs.map(\.lastPathComponent) == ["Deck – page 1.png", "Deck – page 2.png", "Deck – page 3.png"], "files: \(String(describing: result?.outputs))")
        check(result?.outputs.allSatisfy { $0.deletingLastPathComponent().path == target.path } == true, "inside “Deck (PNG)”: \(String(describing: result?.outputs.first)) vs \(target.path)")
    }

    add("queue.limitsConcurrencyPerClass") {
        let folder = tempFolder("limits")
        let limits = ConcurrencyLimits(video: 1, audio: 3, image: 2, document: 2, archive: 2, perHelper: 1)
        @MainActor func maxConcurrent(category: FormatCategory, jobs: Int) -> Int {
            let probe = Probe()
            let stack = Stack(writing(probe, delay: 0.15), limits: limits)
            let route = routes { FormatCatalog.format($0.from)?.category == category && FormatCatalog.format($0.to)?.category == category && $0.builtin?.count == 1 }
                ?? routes { FormatCatalog.format($0.from)?.category == category && FormatCatalog.format($0.to)?.category == category && $0.builtin != nil }!
            let sources = (0..<jobs).map { write("x", to: folder, "\(category.rawValue)\($0).\(route.from)") }
            let result = complete(60) {
                let events = stack.queue.events
                var pending = Set<JobID>()
                for source in sources {
                    let plan = stack.planner.plan(for: ConversionRequest(source: source, sourceFormat: route.from, target: route.to))
                    pending.insert(stack.queue.enqueue(plan, into: .nextToOriginal))
                }
                for await event in events { if let id = terminal(event) { pending.remove(id) }; if pending.isEmpty { break } }
            }
            check(result != nil, "\(category) batch finished")
            return probe.maxRunning
        }
        check(maxConcurrent(category: .video, jobs: 3) == 1, "video encodes one at a time")
        check(maxConcurrent(category: .audio, jobs: 6) == 3, "audio up to its limit")
        check(maxConcurrent(category: .archive, jobs: 5) == 2, "archives two at a time")
    }

    add("queue.smallFilesStartAlongsideALongVideo") {
        let folder = tempFolder("alongside")
        let gate = Latch()
        let slow: Behavior = { step, input, context in
            if context.targetFormat == "mp4" {
                while !context.isCancelled() && !gate.isOpen { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            return try await writing(Probe())(step, input, context)
        }
        let stack = Stack(slow, limits: ConcurrencyLimits(video: 1, audio: 1, image: 1, document: 1, archive: 1, perHelper: 1))
        let videoSource = write("v", to: folder, "Clip.mov")
        let imageSource = write("i", to: folder, "Photo.png")
        let result = complete(30) { () -> [JobEvent] in
            let events = stack.queue.events
            _ = stack.queue.enqueue(stack.planner.plan(for: ConversionRequest(source: videoSource, sourceFormat: "mov", target: "mp4")), into: .nextToOriginal)
            let image = stack.queue.enqueue(stack.planner.plan(for: ConversionRequest(source: imageSource, sourceFormat: "png", target: "jpg")), into: .nextToOriginal)
            var log: [JobEvent] = []
            for await event in events {
                log.append(event)
                if terminal(event) == image { break }
            }
            gate.release()
            for await event in events { log.append(event); if case .finished = event, log.contains(where: { if case .finished(let id, _) = $0 { id != image } else { false } }) { break } }
            return log
        }
        let log = (try? result?.get()) ?? []
        let finished = log.compactMap { event -> JobID? in if case .finished(let id, _) = event { id } else { nil } }
        check(finished.count == 2, "both finished")
        let started = log.filter { if case .started = $0 { true } else { false } }.count
        check(started == 2, "the image started while the video ran")
    }

    add("queue.oneJobPerHelper") {
        let helperRoute = routes { $0.builtin == nil && $0.helper != nil && $0.helpers == [.libreoffice] && ($0.helper?.count ?? 0) == 1 }!
        let folder = tempFolder("helper")
        let probe = Probe()
        let stack = Stack(writing(probe, delay: 0.15), limits: ConcurrencyLimits(video: 1, audio: 4, image: 4, document: 4, archive: 2, perHelper: 1))
        stack.helpers.statuses[.libreoffice] = .installed(version: "1", location: folder, sizeOnDisk: nil)
        let sources = (0..<3).map { write("x", to: folder, "Doc\($0).\(helperRoute.from)") }
        let finished = complete(60) { () -> Int in
            let events = stack.queue.events
            var pending = Set<JobID>()
            for source in sources {
                pending.insert(stack.queue.enqueue(stack.planner.plan(for: ConversionRequest(source: source, sourceFormat: helperRoute.from, target: helperRoute.to)), into: .nextToOriginal))
            }
            var done = 0
            for await event in events { if let id = terminal(event) { pending.remove(id); done += 1 }; if pending.isEmpty { break } }
            return done
        }
        check((try? finished?.get()) == 3 && probe.maxRunning == 1, "LibreOffice jobs run one at a time (max \(probe.maxRunning))")
    }

    add("queue.cancellingARunningJobDeletesPartialOutput") {
        let foldersBefore = jobFolders()
        let folder = tempFolder("cancel")
        let source = write("a", to: folder, "Movie.mov")
        let started = Latch()
        let partial: Behavior = { step, _, context in
            try Data("half".utf8).write(to: context.workFolder.appendingPathComponent("partial.bin"))
            started.release()
            while !context.isCancelled() { try await Task.sleep(nanoseconds: 10_000_000) }
            throw ConversionError.cancelled
        }
        let stack = Stack(partial)
        let result = complete(30) { () -> [JobEvent] in
            let events = stack.queue.events
            let id = stack.queue.enqueue(stack.planner.plan(for: ConversionRequest(source: source, sourceFormat: "mov", target: "mp4")), into: .nextToOriginal)
            while !started.isOpen { try await Task.sleep(nanoseconds: 5_000_000) }
            stack.queue.cancel(id)
            var log: [JobEvent] = []
            for await event in events { log.append(event); if terminal(event) == id { break } }
            return log
        }
        let log = (try? result?.get()) ?? []
        check(log.contains { if case .cancelled = $0 { true } else { false } }, "cancelled event: \(log)")
        check(!log.contains { if case .finished = $0 { true } else { false } }, "nothing finished")
        check((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() == ["Movie.mov"], "no output, no partial file next to the original")
        check(jobFolders().isSubset(of: foldersBefore), "work folder deleted")
        check(stack.queue.activeCount == 0, "queue idle")
    }

    add("queue.cancellingQueuedJobsAndCancelAll") {
        let folder = tempFolder("cancelAll")
        let probe = Probe()
        let stack = Stack(writing(probe, delay: 0.4), limits: ConcurrencyLimits(video: 1, audio: 1, image: 1, document: 1, archive: 1, perHelper: 1))
        let sources = (0..<3).map { write("x", to: folder, "V\($0).mov") }
        let result = complete(30) { () -> [JobEvent] in
            let events = stack.queue.events
            let ids = sources.map { stack.queue.enqueue(stack.planner.plan(for: ConversionRequest(source: $0, sourceFormat: "mov", target: "mp4")), into: .nextToOriginal) }
            stack.queue.cancel(ids[1])   // waiting: never starts
            stack.queue.cancelAll()      // the running one, and the last
            var pending = Set(ids)
            var log: [JobEvent] = []
            for await event in events { log.append(event); if let id = terminal(event) { pending.remove(id) }; if pending.isEmpty { break } }
            return log
        }
        let log = (try? result?.get()) ?? []
        let cancelled = log.filter { if case .cancelled = $0 { true } else { false } }.count
        let started = log.filter { if case .started = $0 { true } else { false } }.count
        check(cancelled == 3 && started == 1, "three cancelled, only the first ever started (\(cancelled), \(started))")
        check((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.count == 3, "no outputs")
    }

    add("queue.surfacesErrors") {
        let foldersBefore = jobFolders()
        let folder = tempFolder("errors")
        @MainActor func outcome(_ throwing: @escaping @Sendable () throws -> Void, source name: String = "Locked.pdf") -> ConversionError? {
            let stack = Stack({ _, _, _ in try throwing(); return StepOutput(.file(URL(fileURLWithPath: "/dev/null"))) })
            return failure(run(stack, write("x", to: folder, name), "pdf", "docx"))
        }
        check(outcome({ throw ConversionError.passwordRequired("pdf") }) == .passwordRequired("pdf"), "password required passes through")
        check(outcome({ throw ConversionError.damaged("pdf") }) == .damaged("pdf"), "damaged passes through")
        check(outcome({ throw FakeError(message: "boom") }) != nil, "other errors become failures")
        if case .failed(let text)? = outcome({ throw FakeError(message: "boom") }) { check(!text.isEmpty, "with words") }

        let stack = Stack(writing(Probe()))
        let gone = failure(run(stack, folder.appendingPathComponent("missing.pdf"), "pdf", "docx"))
        check(gone != nil, "a missing source fails: \(String(describing: gone))")

        let notOffered = failure(run(stack, write("x", to: folder, "a.ttf"), "ttf", "mp4"))
        check(notOffered == .impossiblePair(reason: Strings.problem(.unsupportedPair(from: "ttf", to: "mp4")).message), "unsupported pair: \(String(describing: notOffered))")

        let blocked = FormatMatrix.routes.first { !$0.isOffered && !$0.note.isEmpty }!
        check(failure(run(stack, write("x", to: folder, "b.\(blocked.from)"), blocked.from, blocked.to)) == .impossiblePair(reason: blocked.note), "impossible pair says why")

        let helperRoute = routes { $0.builtin == nil && $0.helper != nil && $0.helpers == [.libreoffice] }!
        let missingHelper = failure(run(stack, write("x", to: folder, "c.\(helperRoute.from)"), helperRoute.from, helperRoute.to))
        check(missingHelper == .helperMissing(.libreoffice), "missing helper: \(String(describing: missingHelper))")
        check(jobFolders().isSubset(of: foldersBefore), "failed jobs leave no work folder")
    }

    add("queue.waitsForAnInstallingHelperThenRuns") {
        let helperRoute = routes { $0.builtin == nil && $0.helper != nil && $0.helpers == [.libreoffice] }!
        let folder = tempFolder("waiting")
        var nudge: AsyncStream<HelperID>.Continuation!
        let changes = AsyncStream<HelperID> { nudge = $0 }
        let stack = Stack(writing(Probe()), helperChanges: changes)
        stack.helpers.statuses[.libreoffice] = .installing(fraction: 0.4)
        let source = write("x", to: folder, "Doc.\(helperRoute.from)")
        let result = complete(30) { () -> [JobEvent] in
            let events = stack.queue.events
            let id = stack.queue.enqueue(stack.planner.plan(for: ConversionRequest(source: source, sourceFormat: helperRoute.from, target: helperRoute.to)), into: .nextToOriginal)
            var log: [JobEvent] = []
            for await event in events {
                log.append(event)
                if case .waitingForHelper = event {
                    stack.helpers.statuses[.libreoffice] = .installed(version: "1", location: folder, sizeOnDisk: nil)
                    nudge.yield(.libreoffice)
                }
                if terminal(event) == id { break }
            }
            return log
        }
        let log = (try? result?.get()) ?? []
        check(log.contains { if case .waitingForHelper(_, .libreoffice) = $0 { true } else { false } }, "announced the wait")
        check(log.contains { if case .finished = $0 { true } else { false } }, "ran once the helper was ready: \(log)")
    }

    // MARK: Output

    add("output.namingAndCollisions") {
        let folder = tempFolder("naming")
        let rules = OutputRules(collisionPolicy: { .addNumber }, downloads: tempFolder("dl"))
        let source = write("a", to: folder, "Report.docx")
        let first = try? rules.target(for: source, format: "pdf", place: .nextToOriginal, multipleFiles: false)
        check(first?.url == folder.appendingPathComponent("Report.pdf") && first?.isFolder == false, "same name, new extension")
        _ = write("old", to: folder, "Report.pdf"); _ = write("old", to: folder, "Report 2.pdf")
        check((try? rules.target(for: source, format: "pdf", place: .nextToOriginal, multipleFiles: false))?.url == folder.appendingPathComponent("Report 3.pdf"), "collisions add 2, 3")
        let several = try? rules.target(for: source, format: "png", place: .nextToOriginal, multipleFiles: true)
        check(several?.url.lastPathComponent == "Report (PNG)" && several?.isFolder == true, "several files go in “Report (PNG)”")
        try? FileManager.default.createDirectory(at: folder.appendingPathComponent("Report (PNG)"), withIntermediateDirectories: true)
        check((try? rules.target(for: source, format: "png", place: .nextToOriginal, multipleFiles: true))?.url.lastPathComponent == "Report (PNG) 2", "folders number too")
        check(rules.partName(base: "Report", kind: "page", index: 3, format: "png") == "Report – page 3.png", "part names use an en dash")
        let archive = write("a", to: folder, "backup.tar.gz")
        check((try? rules.target(for: archive, format: "zip", place: .nextToOriginal, multipleFiles: false))?.url.lastPathComponent == "backup.zip", "compound extensions go whole")
        let chosen = tempFolder("chosen")
        check((try? rules.target(for: source, format: "pdf", place: .folder(chosen), multipleFiles: false))?.url == chosen.appendingPathComponent("Report.pdf"), "chosen folder")
        let made = chosen.appendingPathComponent("new/deeper")
        check((try? rules.target(for: source, format: "pdf", place: .folder(made), multipleFiles: false)) != nil && FileManager.default.fileExists(atPath: made.path), "a missing chosen folder is created")
    }

    add("output.replaceNeverReplacesTheSource") {
        let folder = tempFolder("replace")
        let rules = OutputRules(collisionPolicy: { .replace }, downloads: tempFolder("dl"))
        let source = write("a", to: folder, "Photo.png")
        _ = write("old", to: folder, "Photo.jpg")
        check((try? rules.target(for: source, format: "jpg", place: .nextToOriginal, multipleFiles: false))?.url == folder.appendingPathComponent("Photo.jpg"), "replace reuses the earlier result’s name")
        check((try? rules.target(for: source, format: "png", place: .nextToOriginal, multipleFiles: false))?.url == folder.appendingPathComponent("Photo 2.png"), "but never the source itself")

        let work = tempFolder("work")
        let result = write("new", to: work, "Photo.jpg")
        let target = try? rules.target(for: source, format: "jpg", place: .nextToOriginal, multipleFiles: false)
        let placed = try? rules.place([result], for: source, into: target!)
        check(placed == [folder.appendingPathComponent("Photo.jpg")] && (try? String(contentsOf: placed![0])) == "new", "replace swaps the earlier result")
        check((try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.sorted() == ["Photo.jpg", "Photo.png"], "no stray partial files")
    }

    add("output.neverOverwritesWhenTheNameIsTakenMeanwhile") {
        let folder = tempFolder("race")
        let rules = OutputRules(collisionPolicy: { .addNumber }, downloads: tempFolder("dl"))
        let source = write("a", to: folder, "Doc.docx")
        let target = try! rules.target(for: source, format: "pdf", place: .nextToOriginal, multipleFiles: false)
        _ = write("someone else’s", to: folder, "Doc.pdf")   // appears after the name was chosen
        let work = tempFolder("work")
        let placed = try? rules.place([write("mine", to: work, "Doc.pdf")], for: source, into: target)
        check((try? String(contentsOf: folder.appendingPathComponent("Doc.pdf"))) == "someone else’s", "the other file is untouched")
        check(placed == [folder.appendingPathComponent("Doc 2.pdf")], "mine became “Doc 2.pdf”")
    }

    add("output.unwritableFolderFallsBackToDownloads") {
        let downloads = tempFolder("dl")
        let rules = OutputRules(collisionPolicy: { .addNumber }, downloads: downloads)
        let locked = tempFolder("locked")
        let source = write("a", to: locked, "Shared.docx")
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        if getuid() != 0 {
            let target = try? rules.target(for: source, format: "pdf", place: .nextToOriginal, multipleFiles: false)
            check(target?.fellBackToDownloads == true && target?.url == downloads.appendingPathComponent("Shared.pdf"), "Downloads instead, and it says so")
            try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: downloads.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloads.path) }
            do { _ = try rules.target(for: source, format: "pdf", place: .nextToOriginal, multipleFiles: false); check(false, "should not be writable") }
            catch { check((error as? ConversionError) == .folderNotWritable(name: locked.lastPathComponent), "nowhere to write: \(error)") }
        }
    }

    // MARK: Sniffer

    add("sniffer.contentBeatsExtension") {
        let folder = tempFolder("sniff")
        let sniffer = FormatSniffer()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
        let misnamed = folder.appendingPathComponent("photo.jpg")
        try? png.write(to: misnamed)
        let result = try? sniffer.sniff(misnamed)
        check(result?.format == "png" && result?.claimed == "jpg" && result?.mismatch == true, "a PNG named .jpg: \(String(describing: result))")

        let jpeg = folder.appendingPathComponent("photo.jpeg")
        try? Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0]).write(to: jpeg)
        let family = try? sniffer.sniff(jpeg)
        check(family?.format == "jpeg" && family?.mismatch == false, "JPEG is JPG: \(String(describing: family))")

        let text = write("just words", to: folder, "notes.txt")
        check((try? sniffer.sniff(text))?.format == "txt", "no signature: the extension decides")
        let mystery = write("???", to: folder, "mystery")
        check((try? sniffer.sniff(mystery))?.format == nil, "nothing to go on")
        let bm = write("BMW stands for…", to: folder, "bmw.txt")
        check((try? sniffer.sniff(bm))?.format == "txt", "a two-byte signature alone is not enough")
        check((try? sniffer.sniff(folder.appendingPathComponent("nope.png"))) == nil, "missing files throw")

        for (name, bytes, expected) in [("a.bin", Array("%PDF-1.7".utf8), "pdf"), ("b.bin", Array("fLaC".utf8) + [0, 0], "flac"),
                                         ("c.bin", Array("OggS".utf8), "ogg"), ("d.bin", [0x1A, 0x45, 0xDF, 0xA3], "mkv"),
                                         ("e.bin", [0, 0, 0, 0x18] + Array("ftypheic".utf8), "heic"),
                                         ("f.bin", Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVE".utf8), "wav"),
                                         ("g.bin", Array("<svg xmlns".utf8), "svg"), ("h.bin", Array("Rar!".utf8) + [0x1A, 0x07, 0], "rar")] as [(String, [UInt8], String)] {
            let url = folder.appendingPathComponent(name)
            try? Data(bytes).write(to: url)
            check((try? sniffer.sniff(url))?.format == FormatID(expected), "\(name) is \(expected)")
        }
    }

    add("sniffer.tellsZipContainersApart") {
        let folder = tempFolder("zips")
        let sniffer = FormatSniffer()
        @MainActor func sniff(_ entries: [(String, String)], as name: String) -> FormatID? {
            let url = folder.appendingPathComponent(name)
            try? TestZip.write(entries, to: url)
            return (try? sniffer.sniff(url))?.format
        }
        check(sniff([("[Content_Types].xml", "<Types>wordprocessingml.document.main+xml</Types>"), ("word/document.xml", "<w/>")], as: "a.zip") == "docx", "docx")
        check(sniff([("[Content_Types].xml", "<Types>macroEnabled.main+xml</Types>"), ("xl/workbook.xml", "<w/>")], as: "b.zip") == "xlsm", "xlsm by content type")
        check(sniff([("[Content_Types].xml", "<Types/>"), ("ppt/presentation.xml", "<w/>")], as: "c.zip") == "pptx", "pptx")
        check(sniff([("mimetype", "application/epub+zip"), ("META-INF/container.xml", "<c/>")], as: "d.zip") == "epub", "epub by mimetype")
        check(sniff([("mimetype", "application/vnd.oasis.opendocument.text"), ("content.xml", "<c/>")], as: "e.zip") == "odt", "odt")
        check(sniff([("mimetype", "application/vnd.oasis.opendocument.spreadsheet"), ("content.xml", "<c/>")], as: "f.zip") == "ods", "ods")
        check(sniff([("META-INF/MANIFEST.MF", "Manifest-Version: 1.0")], as: "g.zip") == "jar", "jar")
        check(sniff([("one.txt", "1"), ("two.txt", "2")], as: "h.docx") == "zip", "a plain zip named .docx is a zip")
        check(sniff([("1.jpg", "1"), ("2.jpg", "2")], as: "i.cbz") == "cbz", "a comic book zip stays cbz")
        check(sniff([("Index/Document.iwa", "x")], as: "j.zip") == "pages", "Pages")
    }

    // MARK: Thumbnails, work folders

    add("thumbnails.cacheByFileIdentity") {
        let folder = tempFolder("thumbs")
        let cache = tempFolder("thumbcache")
        let file = write("a", to: folder, "a.txt")
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let service = ThumbnailService(cacheFolder: { cache }, maxEntries: 2, generator: { _, size, _ in
            counter.n += 1
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let image = NSImage(size: size)
            image.addRepresentation(bitmap)
            return image
        })
        let result = complete(30) { () -> [Bool] in
            let first = await service.thumbnail(for: file, size: CGSize(width: 32, height: 32), scale: 1) != nil
            let second = await service.thumbnail(for: file, size: CGSize(width: 32, height: 32), scale: 1) != nil
            let afterFirst = counter.n
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 100)], ofItemAtPath: file.path)
            _ = await service.thumbnail(for: file, size: CGSize(width: 32, height: 32), scale: 1)
            return [first, second, afterFirst == 1, counter.n == 2]
        }
        check((try? result?.get()) == [true, true, true, true], "generated once, regenerated when the file changed: \(String(describing: try? result?.get())) \(counter.n)")
        _ = complete(30) { for n in 1...4 { _ = await service.thumbnail(for: file, size: CGSize(width: 8 * n, height: 8), scale: 1) } }
        check((try? FileManager.default.contentsOfDirectory(atPath: cache.path))?.count ?? 99 <= 2, "the cache is pruned")
        service.removeCache()
        check((try? FileManager.default.contentsOfDirectory(atPath: cache.path))?.isEmpty == true, "removeCache empties it")
    }

    add("workFolders.sweepRemovesOnlyAbandonedOnes") {
        let jobs = tempFolder("jobs")
        let abandoned = jobs.appendingPathComponent("dead", isDirectory: true)
        _ = write("", to: abandoned, ".lock"); _ = write("partial", to: abandoned, "x.bin")
        let live = jobs.appendingPathComponent("live", isDirectory: true)
        let lock = write("", to: live, ".lock")
        let descriptor = open(lock.path, O_RDWR)
        flock(descriptor, LOCK_EX | LOCK_NB)
        let removed = ConvertKitModule.sweepStaleWorkFolders(in: jobs)
        check(removed == 1 && !FileManager.default.fileExists(atPath: abandoned.path), "abandoned folder removed")
        check(FileManager.default.fileExists(atPath: live.path), "a running job’s folder stays")
        close(descriptor)
        check(ConvertKitModule.sweepStaleWorkFolders(in: jobs) == 1, "once its owner is gone it is swept")
    }

    // MARK: sconv

    add("sconv.parsesArguments") {
        let directory = URL(fileURLWithPath: "/work", isDirectory: true)
        let parsed = try? SconvCommand.parse(["a.heic", "--to", "JPG", "--option", "quality=90", "-O", "dpi=300", "--out=out", "b.heic", "--look", "latex"], currentDirectory: directory)
        check(parsed?.files.map(\.path) == ["/work/a.heic", "/work/b.heic"] && parsed?.to == "jpg", "files and target")
        check(parsed?.options.map { "\($0.key)=\($0.value)" } == ["quality=90", "dpi=300"] && parsed?.out?.path == "/work/out" && parsed?.look == .latex, "options, folder, look")
        check((try? SconvCommand.parse(["--bogus"])) == nil, "unknown flags are errors")
        check((try? SconvCommand.parse(["--to"])) == nil, "a flag without its value is an error")
        check((try? SconvCommand.parse(["--option", "novalue"])) == nil, "option needs key=value")
        check((try? SconvCommand.parse(["--", "--odd-name.png"], currentDirectory: directory))?.files.map(\.lastPathComponent) == ["--odd-name.png"], "-- ends flags")
        let profile = OptionProfiles.profile(FormatMatrix.route(from: "png", to: "jpg")!.options)!
        let quality = profile.options.first { if case .integer = $0.kind { true } else { false } }
        if let quality {
            check((try? SconvCommand.optionValue("90", for: quality)) == .int(90), "integer option")
            check((try? SconvCommand.optionValue("100000", for: quality)) == nil && (try? SconvCommand.optionValue("high", for: quality)) == nil, "out of range or not a number")
        }
        let toggle = OptionDefinition("flag", "Flag", .toggle, default: false)
        check((try? SconvCommand.optionValue("Yes", for: toggle)) == .bool(true) && (try? SconvCommand.optionValue("0", for: toggle)) == .bool(false), "toggles take yes/no")
    }

    add("sconv.convertsAndReports") {
        let folder = tempFolder("cli")
        let png = folder.appendingPathComponent("Shot.png")
        try? Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]).write(to: png)
        let stack = Stack(writing(Probe(), lossNotes: [LossNote(.transparencyFilled)]))
        let sniffer = FormatSniffer()
        @MainActor func sconv(_ arguments: [String]) -> (status: Int32, out: String, err: String) {
            var out = "", err = ""
            let status = complete(60) {
                await SconvCommand.run(arguments, planner: stack.planner, queue: stack.queue, sniffer: sniffer) { text, isError in
                    if isError { err += text } else { out += text }
                }
            }
            return (((try? status?.get()) ?? -1), out, err)
        }
        let outFolder = folder.appendingPathComponent("converted")
        let ok = sconv([png.path, "--to", "jpg", "--out", outFolder.path])
        check(ok.status == 0 && ok.out == outFolder.appendingPathComponent("Shot.jpg").path + "\n", "prints the output path: \(ok)")
        check(ok.err.contains("Transparency was filled with white"), "loss notes on stderr")
        let again = sconv([png.path, "--to", "jpg"])
        check(again.status == 0 && again.out == folder.appendingPathComponent("Shot.jpg").path + "\n", "next to the original by default")
        let second = sconv([png.path, "--to", "jpg"])
        check(second.out == folder.appendingPathComponent("Shot 2.jpg").path + "\n", "never overwrites: \(second.out)")

        check(sconv([]).status == 64 && sconv([png.path]).status == 64, "usage without a target")
        check(sconv([png.path, "--to", "jpg", "--option", "nonsense=1"]).status == 64, "unknown option key")
        let impossible = sconv([png.path, "--to", "mp4"])
        check(impossible.status == 1 && !impossible.err.isEmpty, "unsupported pair is a failure: \(impossible)")
        check(sconv([folder.appendingPathComponent("missing.png").path, "--to", "jpg"]).status == 1, "missing file")
        check(sconv(["--help"]).status == 0, "help")

        let targets = sconv([png.path, "--list-targets"])
        check(targets.status == 0 && targets.out.split(separator: "\n").contains { $0.hasPrefix("jpg\t") && $0.hasSuffix("built in") }, "lists targets: \(targets.out.prefix(120))")
        let options = sconv(["--from", "png", "--to", "jpg", "--list-options"])
        check(options.status == 0 && !options.out.isEmpty, "lists options")
    }

    add("sconv.asksBeforeABomb") {
        // An engine that asks first (quality §8: a decompression bomb) unless the option the question names is set.
        let folder = tempFolder("cli-bomb")
        let zip = folder.appendingPathComponent("Huge.zip")
        try? TestZip.write([("a.txt", "a")], to: zip)
        let question = ConversionError.needsConfirmation(question: "This archive expands over 1,000 times, past 10 GB, as a decompression bomb does. Extract it anyway?", proceed: .extractAnyway, option: "extractAnyway")
        let probe = Probe()
        let stack = Stack({ step, input, context in
            if context.options["extractAnyway"]?.bool != true { throw question }
            return try await writing(probe)(step, input, context)
        })
        @MainActor func sconv(_ arguments: [String]) -> (status: Int32, out: String, err: String) {
            var out = "", err = ""
            let status = complete(60) {
                await SconvCommand.run(arguments, planner: stack.planner, queue: stack.queue, sniffer: FormatSniffer()) { text, isError in
                    if isError { err += text } else { out += text }
                }
            }
            return (((try? status?.get()) ?? -1), out, err)
        }
        let asked = sconv([zip.path, "--to", "tar"])
        check(asked.status == 2 && asked.out.isEmpty, "a question is exit status 2, nothing written: \(asked)")
        check(asked.err == "Huge.zip: This archive expands over 1,000 times, past 10 GB, as a decompression bomb does. Extract it anyway? To go ahead, run again with --option extractAnyway=yes.\n",
              "it says what to pass: \(asked.err)")
        let agreed = sconv([zip.path, "--to", "tar", "--option", "extractAnyway=yes"])
        check(agreed.status == 0 && agreed.out == folder.appendingPathComponent("Huge.tar").path + "\n", "--option extractAnyway=yes goes ahead: \(agreed)")
    }
}

/// A minimal ZIP writer (stored entries) for the sniffer’s fixtures.
private enum TestZip {
    private static func le(_ value: Int, _ bytes: Int) -> Data { Data((0..<bytes).map { UInt8((value >> (8 * $0)) & 0xFF) }) }

    static func write(_ entries: [(String, String)], to url: URL) throws {
        var body = Data(), central = Data()
        for (name, text) in entries {
            let offset = body.count
            let content = Data(text.utf8), nameBytes = Data(name.utf8)
            let size = le(content.count, 4), nameLength = le(nameBytes.count, 2), zero2 = le(0, 2), zero4 = le(0, 4)
            for part in [le(0x0403_4B50, 4), le(20, 2), zero2, zero2, zero2, zero2, zero4, size, size, nameLength, zero2, nameBytes, content] { body.append(part) }
            for part in [le(0x0201_4B50, 4), le(20, 2), le(20, 2), zero2, zero2, zero2, zero2, zero4, size, size, nameLength,
                         zero2, zero2, zero2, zero2, zero4, le(offset, 4), nameBytes] { central.append(part) }
        }
        var end = Data()
        let count = le(entries.count, 2)
        for part in [le(0x0605_4B50, 4), le(0, 2), le(0, 2), count, count, le(central.count, 4), le(body.count, 4), le(0, 2)] { end.append(part) }
        try (body + central + end).write(to: url)
    }
}
