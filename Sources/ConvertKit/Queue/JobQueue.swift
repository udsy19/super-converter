import Foundation
import SuperConverterCore

/// ConvertKit's job queue (ux §6.4, ARCHITECTURE §4): jobs start in the order they were added, as many at once as their
/// concurrency classes allow (so a small image starts alongside a long video), each in its own work folder. Cancelling
/// deletes partial output. Sleep is prevented while anything runs.
///
/// Subscribe to `events` before enqueueing: a subscription sees what happens after it is made.
@MainActor
public final class JobQueue: JobQueueing {
    private enum State { case pending, running, ended }

    private struct Job {
        let id: JobID
        let plan: ConversionPlan
        let place: OutputPlace
        let classes: [ConcurrencyClass]
        var state = State.pending
        var announcedWaiting = false
        let cancel = CancelFlag()
        var task: Task<Void, Never>?
    }

    private let registry: ConverterRegistry
    private let output: OutputPolicy
    private let helperStatus: (HelperID) -> HelperStatus
    private let limits: ConcurrencyLimits

    private var jobs: [JobID: Job] = [:]
    private var order: [JobID] = []
    private var running: [ConcurrencyClass: Int] = [:]
    private var subscribers: [UUID: AsyncStream<JobEvent>.Continuation] = [:]
    private var activity: NSObjectProtocol?
    private var statusTask: Task<Void, Never>?

    /// - Parameter helperChanges: fires when a helper's status changes (jobs waiting for an installing helper go on).
    public init(registry: ConverterRegistry, output: OutputPolicy, limits: ConcurrencyLimits = ConcurrencyLimits(),
                helperStatus: @escaping (HelperID) -> HelperStatus, helperChanges: AsyncStream<HelperID>? = nil) {
        self.registry = registry; self.output = output; self.limits = limits; self.helperStatus = helperStatus
        if let helperChanges {
            statusTask = Task { @MainActor [weak self] in
                for await _ in helperChanges { self?.schedule() }
            }
        }
    }

    deinit { statusTask?.cancel() }

    // MARK: JobQueueing

    public var events: AsyncStream<JobEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { @MainActor in self?.subscribers[id] = nil } }
        }
    }

    public var activeCount: Int { jobs.values.filter { $0.state != .ended }.count }

    public func enqueue(_ plan: ConversionPlan, into place: OutputPlace) -> JobID {
        let id = JobID()
        jobs[id] = Job(id: id, plan: plan, place: place, classes: Self.classes(for: plan, helperStatus: helperStatus))
        order.append(id)
        beginActivity()
        emit(.queued(id))
        schedule()
        return id
    }

    public func cancel(_ job: JobID) {
        guard var entry = jobs[job], entry.state != .ended else { return }
        entry.cancel.cancel()
        if entry.state == .pending {
            entry.state = .ended
            jobs[job] = entry
            emit(.cancelled(job))
            retire(job)
            schedule()
        } else {
            entry.task?.cancel()   // the runner unwinds, deletes the work folder and reports `.cancelled`
        }
    }

    public func cancelAll() { order.forEach(cancel) }

    // MARK: Scheduling

    /// The classes a job occupies: its kind of work, and one slot per helper it runs through.
    static func classes(for plan: ConversionPlan, helperStatus: (HelperID) -> HelperStatus) -> [ConcurrencyClass] {
        var classes = [ConcurrencyLimits.concurrencyClass(from: plan.request.sourceFormat, to: plan.request.target)]
        if case .helper(let steps, _, _) = plan.choice {
            for step in steps {
                let candidates = step.engine.helpers
                guard let helper = candidates.first(where: { helperStatus($0).isReady }) ?? candidates.first else { continue }
                if !classes.contains(.helper(helper)) { classes.append(.helper(helper)) }
            }
        }
        return classes
    }

    private func schedule() {
        for id in order {
            guard var job = jobs[id], job.state == .pending else { continue }
            switch readiness(of: job.plan) {
            case .fail(let error):
                job.state = .ended
                jobs[id] = job
                emit(.failed(id, error))
                retire(id)
            case .waiting(let helper):
                if !job.announcedWaiting {
                    job.announcedWaiting = true
                    jobs[id] = job
                    emit(.waitingForHelper(id, helper))
                }
            case .go:
                let classes = job.classes
                guard classes.allSatisfy({ (running[$0] ?? 0) < limits.limit(for: $0) }) else { continue }
                classes.forEach { running[$0, default: 0] += 1 }
                job.state = .running
                jobs[id] = job
                emit(.started(id))
                start(id)
            }
        }
        endActivityIfIdle()
    }

    private enum Readiness { case go, waiting(HelperID), fail(ConversionError) }

    private func readiness(of plan: ConversionPlan) -> Readiness {
        switch plan.choice {
        case .unavailable(let reason):
            switch reason {
            case .notOffered(let note):
                return .fail(note.isEmpty
                    ? .unsupportedPair(from: plan.request.sourceFormat, to: plan.request.target) : .impossiblePair(reason: note))
            case .engineUnavailable(_, let why): return .fail(.failed(why))
            }
        case .builtin:
            return .go
        case .helper(_, _, let missing):
            for helper in missing {
                switch helperStatus(helper) {
                case .installed: continue
                case .installing: return .waiting(helper)
                case .notInstalled, .unusable: return .fail(.helperMissing(helper))
                }
            }
            return .go
        }
    }

    private func start(_ id: JobID) {
        guard let job = jobs[id] else { return }
        let steps = job.plan.choice.steps.compactMap { step in registry.converter(for: step.engine).map { (step: step, converter: $0) } }
        guard steps.count == job.plan.choice.steps.count else {
            finish(id, .failed(.unsupportedPair(from: job.plan.request.sourceFormat, to: job.plan.request.target)))
            return
        }
        let meter = ProgressMeter(steps: steps.count) { [weak self] progress in
            Task { @MainActor in self?.progress(id, progress) }
        }
        let runner = JobRunner(id: id, plan: job.plan, place: job.place, steps: steps, output: output, cancel: job.cancel, meter: meter)
        jobs[id]?.task = Task.detached { [weak self] in
            let outcome = await runner.run()
            await self?.finish(id, outcome)
        }
    }

    private func progress(_ id: JobID, _ progress: JobProgress) {
        guard jobs[id]?.state == .running else { return }
        emit(.progress(id, progress))
    }

    private func finish(_ id: JobID, _ outcome: JobOutcome) {
        guard var job = jobs[id], job.state == .running else { return }
        job.state = .ended
        jobs[id] = job
        job.classes.forEach { running[$0, default: 1] -= 1 }
        switch outcome {
        case .finished(let result): emit(.finished(id, result))
        case .failed(let error): emit(.failed(id, error))
        case .cancelled: emit(.cancelled(id))
        }
        retire(id)
        schedule()
    }

    /// Forgets an ended job (its events have been sent).
    private func retire(_ id: JobID) {
        jobs[id] = nil
        order.removeAll { $0 == id }
    }

    // MARK: Events and sleep

    private func emit(_ event: JobEvent) { subscribers.values.forEach { $0.yield(event) } }

    private func beginActivity() {
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Converting files")
        }
    }

    private func endActivityIfIdle() {
        if activeCount == 0, let token = activity {
            ProcessInfo.processInfo.endActivity(token)
            activity = nil
        }
    }
}
