import Foundation
import ImageIO
import SuperConverterCore

/// One file in a batch the menu-bar panel or a Quick Action converts.
struct BatchItem: Identifiable, Equatable {
    enum State: Equatable {
        case ready, unreadable, queued
        case waiting(HelperID)
        case converting(JobProgress)
        case done(ConversionResult)
        case failed(ConversionError)

        var isFinished: Bool {
            switch self {
            case .unreadable, .done, .failed: true
            default: false
            }
        }
    }

    let id = UUID()
    var url: URL
    var sizeBytes: Int64
    var source: FormatID?
    var target: FormatID?
    var options = OptionValues()
    var state = State.ready

    var name: String { url.lastPathComponent }
    var category: FormatCategory { source.flatMap { FormatCatalog.format($0)?.category } ?? .document }
    var targetCategory: FormatCategory { target.flatMap { FormatCatalog.format($0)?.category } ?? category }
}

/// Reads files into batch items and runs them through the planner and the queue (ARCHITECTURE §4, §6).
@MainActor
enum BatchRunner {
    /// Sniffs each file and gives it a target: `preset` when there is one (the planner says whether the pair runs), else the
    /// person's last choice or the default (ux §6.1). Files nothing can read stay in the batch as `.unreadable`; with a
    /// preset, files already in that format are left out (nothing to do).
    static func prepare(_ urls: [URL], preset: FormatID? = nil) -> [BatchItem] {
        urls.compactMap { url in
            let sniff = (try? Services.sniffer.sniff(url)) ?? SniffResult(format: nil, claimed: nil)
            var item = BatchItem(url: url, sizeBytes: sniff.sizeBytes, source: sniff.format)
            guard let source = sniff.format else { item.state = .unreadable; return item }
            if let preset {
                if FormatCatalog.isSameFormat(source, preset) { return nil }
                item.target = preset
            } else {
                item.target = DefaultTargets.target(for: source, traits: traits(url, source), remembered: Defaults[.target(for: source)])
            }
            if let target = item.target { item.options = Defaults[.savedOptions(for: target)] ?? OptionValues() }
            return item
        }
    }

    /// Facts from the header that change the default target: transparency and animation (ux §6.1).
    private static func traits(_ url: URL, _ format: FormatID) -> DefaultTargets.Traits {
        guard ["gif", "webp", "avif", "png"].contains(format.rawValue),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return .init() }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return .init(hasTransparency: props?[kCGImagePropertyHasAlpha] as? Bool ?? false, isAnimated: CGImageSourceGetCount(source) > 1)
    }

    /// Plans and enqueues every ready item, then follows the queue's events until each one has ended. Calls `onUpdate` with
    /// the changed item each time. Events of other jobs (the window's) are ignored.
    @discardableResult
    static func run(_ items: [BatchItem], place: OutputPlace, onUpdate: (BatchItem) -> Void = { _ in }) async -> [BatchItem] {
        var items = items
        let events = Services.queue.events   // subscribe first: a subscription sees what happens after it is made
        var index: [JobID: Int] = [:]
        for i in items.indices where items[i].state == .ready {
            guard let source = items[i].source, let target = items[i].target else {
                items[i].state = .failed(.notReadableYet); onUpdate(items[i]); continue
            }
            let request = ConversionRequest(source: items[i].url, sourceFormat: source, target: target, options: items[i].options)
            index[Services.queue.enqueue(Services.planner.plan(for: request), into: place)] = i
            items[i].state = .queued
            onUpdate(items[i])
        }
        var pending = index.count
        guard pending > 0 else { return items }
        for await event in events {
            guard let id = event.job, let i = index[id] else { continue }
            if apply(event, to: &items[i]) { pending -= 1 }
            onUpdate(items[i])
            if pending == 0 { break }
        }
        return items
    }

    /// Moves an item's state along with a queue event; true when the event ended the item.
    static func apply(_ event: JobEvent, to item: inout BatchItem) -> Bool {
        switch event {
        case .queued: item.state = .queued
        case .waitingForHelper(_, let helper): item.state = .waiting(helper)
        case .started: item.state = .converting(JobProgress(fraction: nil))
        case .progress(_, let progress): item.state = .converting(progress)
        case .finished(_, let result): item.state = .done(result)
        case .failed(_, let error): item.state = .failed(error)
        case .cancelled: item.state = .failed(.cancelled)
        }
        return item.state.isFinished
    }
}

extension JobEvent {
    var job: JobID? {
        switch self {
        case .queued(let id), .started(let id), .cancelled(let id): id
        case .waitingForHelper(let id, _), .progress(let id, _), .finished(let id, _): id
        case .failed(let id, _): id
        }
    }
}

/// What a finished batch says: the notification's words (ux §5.7, §7.1).
struct BatchSummary: Equatable {
    var items: [BatchItem]
    var place: OutputPlace

    var total: Int { items.count }
    var succeeded: [BatchItem] { items.filter { if case .done = $0.state { true } else { false } } }
    var failures: [(item: BatchItem, error: ConversionError)] {
        items.compactMap { item in
            switch item.state {
            case .failed(let error) where error != .cancelled: (item, error)
            case .unreadable: (item, .notReadableYet)
            default: nil
            }
        }
    }
    var firstOutput: URL? { succeeded.lazy.compactMap { if case .done(let r) = $0.state { r.outputs.first } else { nil } }.first }

    var title: String {
        succeeded.isEmpty ? Strings.Card.failedBadge : Strings.ActionBar.done(ok: succeeded.count, of: total)
    }

    var detail: String {
        if succeeded.isEmpty, let first = failures.first { return "\(Strings.quoted(first.item.name)): \(Strings.problem(first.error).message)" }
        var old: Int64 = 0, new: Int64 = 0
        for case .done(let result) in succeeded.map(\.state) { old += result.inputBytes; new += result.outputBytes }
        return Strings.ActionBar.doneDetail(old: old, new: new, place: place.phrase, needAttention: failures.count)
    }
}

extension OutputPlace {
    /// "next to the originals", "in Downloads", "in “Invoices”": where results went, mid-sentence.
    var phrase: String {
        switch self {
        case .nextToOriginal: "next to the originals"
        case .downloads: "in Downloads"
        case .folder(let url): "in \(Strings.quoted(url.lastPathComponent))"
        }
    }
}
