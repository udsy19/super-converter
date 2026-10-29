import AppKit
import Combine
import SuperConverterCore

enum WindowPhase: Equatable { case empty, ready, converting, finished }

/// What is hovering over the window (ux §5.2): the count and the by-kind line.
struct DragSummary: Equatable {
    var count: Int
    var kinds: [(FormatCategory, Int)]

    static func == (a: DragSummary, b: DragSummary) -> Bool {
        a.count == b.count && a.kinds.map(\.0) == b.kinds.map(\.0) && a.kinds.map(\.1) == b.kinds.map(\.1)
    }

    var headline: String { Strings.Window.dragHeadline(count) }
    var line: String { kinds.isEmpty ? "You’ll pick what each becomes next." : Strings.Window.dragLine(kinds) }

    init(urls: [URL]) {
        count = urls.count
        var counts: [FormatCategory: Int] = [:]
        for url in urls { if let c = FormatCatalog.format(forFileName: url.lastPathComponent)?.category { counts[c, default: 0] += 1 } }
        kinds = FormatCategory.allCases.compactMap { c in counts[c].map { (c, $0) } }
    }

    init(count: Int, kinds: [(FormatCategory, Int)]) { self.count = count; self.kinds = kinds }
}

/// The options sheet being shown, and the cards it edits.
struct OptionsSession: Identifiable {
    let id = UUID()
    let model: OptionsModel
    let cards: [FileCard]
}

enum SortKey: String, CaseIterable { case name, kind, size, status }

/// The main window's state and rules: files in, targets, options, the conversion run, results (ux §5).
@MainActor
final class WindowViewModel: ObservableObject {
    @Published private(set) var cards: [FileCard] = []
    @Published var selection: Set<UUID> = []
    @Published var drag: DragSummary?
    /// The card whose format picker is open.
    @Published var pickerFor: UUID?
    @Published var options: OptionsSession?
    @Published var sortKey: SortKey?
    @Published var sortAscending = true
    /// A grid column count the grid reports, so arrows move by rows.
    var columns = 4
    /// Each visible card's thumbnail frame in the window's content, for Quick Look's zoom.
    var thumbnailFrames: [UUID: CGRect] = [:]
    /// Cards spring in when added and the drop-zone border turns (ux §3.6); snapshots turn this off.
    var animates = true
    @Published private(set) var viewMode: ViewMode = Defaults[.viewMode]
    private var forcedGrid = false

    let actions: FileActions
    private var cardChanges: [UUID: AnyCancellable] = [:]
    private var jobs: [JobID: UUID] = [:]
    private var batch: [UUID] = []
    private var batchStart: Date?
    private var listener: Task<Void, Never>?
    private var installing = Set<HelperID>()
    /// Called when a batch finishes: (ok, total, took). The window controller posts the notification.
    var onBatchFinished: ((_ summary: String, _ detail: String, _ took: TimeInterval) -> Void)?
    /// Called with VoiceOver announcements.
    var announce: (String) -> Void = { message in
        guard let window = NSApp?.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    init(actions: FileActions? = nil) { self.actions = actions ?? SystemFileActions() }

    deinit { listener?.cancel() }

    // MARK: Derived state

    var phase: WindowPhase {
        if cards.isEmpty { return .empty }
        if cards.contains(where: { $0.state.isActive }) { return .converting }
        if cards.contains(where: { $0.state == .ready && $0.source != nil }) { return .ready }
        if cards.contains(where: { $0.state.isFinished }) { return .finished }
        return .ready
    }

    var hasWork: Bool { phase == .converting }

    var totalBytes: Int64 { cards.reduce(0) { $0 + $1.sizeBytes } }

    /// "8 files · 1.7 GB" · "Converting 2 of 8" · "7 of 8 converted" (ux §7.1).
    var subtitle: String? {
        switch phase {
        case .empty: nil
        case .ready: Strings.Window.subtitle(files: cards.count, bytes: totalBytes)
        case .converting: Strings.Window.subtitleConverting(done: finishedInBatch, of: batchCards.count)
        case .finished: Strings.Window.subtitleConverted(done: doneInBatch, of: batchCards.count)
        }
    }

    var batchCards: [FileCard] { cards.filter { batch.contains($0.id) } }
    var doneInBatch: Int { batchCards.filter { if case .done = $0.state { true } else { false } }.count }
    var finishedInBatch: Int { batchCards.filter { $0.state.isFinished }.count }
    var failedInBatch: Int { batchCards.filter { if case .failed = $0.state { true } else { false } }.count }

    var readyCards: [FileCard] { cards.filter { $0.state == .ready && $0.target != nil && $0.unavailableMessage == nil } }

    var convertTitle: String { Strings.Window.convertButton(files: readyCards.count) }

    /// The Convert button's fill (ux §3.4 item 4): the batch's target categories in card order.
    var buttonCategories: [FormatCategory] {
        var seen: [FormatCategory] = []
        for card in readyCards { if !seen.contains(card.targetCategory) { seen.append(card.targetCategory) } }
        return seen
    }

    /// 0…1 over the whole batch.
    var overallFraction: Double {
        let all = batchCards
        guard !all.isEmpty else { return 0 }
        let sum = all.reduce(0.0) { partial, card in
            switch card.state {
            case .done, .failed: partial + 1
            case .converting(let p): partial + (p.fraction ?? 0)
            default: partial
            }
        }
        return sum / Double(all.count)
    }

    var activeCount: Int { cards.filter { $0.state.isActive }.count }

    /// "About 1 minute left · the video takes longest".
    var convertingDetail: String {
        var longest: (seconds: Double, card: FileCard)?
        for card in cards { if case .converting(let p) = card.state, let s = p.secondsLeft, s > (longest?.seconds ?? 0) { longest = (s, card) } }
        guard let longest else { return "Preparing…" }
        let time = Formatting.timeLeft(longest.seconds)
        let head = time.prefix(1).uppercased() + time.dropFirst()
        return longest.card.sourceCategory == .video ? head + " · the video takes longest" : String(head)
    }

    var finishedTitle: String { Strings.ActionBar.done(ok: doneInBatch, of: batchCards.count) }

    var finishedDetail: String {
        var old: Int64 = 0, new: Int64 = 0
        for card in batchCards {
            if case .done(let result) = card.state {
                old += result.inputBytes > 0 ? result.inputBytes : card.sizeBytes
                new += result.outputBytes > 0 ? result.outputBytes : result.outputs.reduce(0) { $0 + Self.size(of: $1) }
            }
        }
        return Strings.ActionBar.doneDetail(old: old, new: new, place: Self.placeText(Defaults[.outputPlace]), needAttention: failedInBatch)
    }

    static func placeText(_ place: OutputPlace) -> String {
        switch place {
        case .nextToOriginal: "next to the originals"
        case .downloads: "in Downloads"
        case .folder(let url): "in \(Strings.quoted(url.lastPathComponent))"
        }
    }

    static func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
        return Int64(values?.totalFileSize ?? values?.fileSize ?? 0)
    }

    var doneOutputs: [URL] { cards.flatMap { card -> [URL] in if case .done(let r) = card.state { r.outputs } else { [] } } }

    // MARK: View mode and sorting

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
        forcedGrid = mode == .grid
        Defaults[.viewMode] = mode
    }

    func usesList(width: CGFloat) -> Bool {
        viewMode == .list || width < SCMetrics.Grid.listBelowWidth || (cards.count > SCMetrics.Grid.listAboveCount && !forcedGrid)
    }

    var displayCards: [FileCard] {
        guard let sortKey else { return cards }
        let sorted = cards.sorted { a, b in
            switch sortKey {
            case .name: a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .kind: (a.source?.rawValue ?? "") < (b.source?.rawValue ?? "")
            case .size: a.sizeBytes < b.sizeBytes
            case .status: statusRank(a) < statusRank(b)
            }
        }
        return sortAscending ? sorted : sorted.reversed()
    }

    private func statusRank(_ card: FileCard) -> Int {
        switch card.state {
        case .failed: 0
        case .unreadable: 1
        case .ready: 2
        case .waitingForHelper: 3
        case .queued: 4
        case .converting: 5
        case .done: 6
        }
    }

    func sort(by key: SortKey) {
        if sortKey == key { sortAscending.toggle() } else { sortKey = key; sortAscending = true }
    }

    // MARK: Adding files

    /// Adds files (dropped, opened, from a Quick Action), expanding folders one level, with an optional preset target.
    func add(_ urls: [URL], target preset: FormatID? = nil) {
        var added: [FileCard] = []
        for url in expand(urls) where !cards.contains(where: { $0.url == url && !$0.state.isFinished }) {
            added.append(makeCard(url, preset: preset))
        }
        guard !added.isEmpty else { return }
        for (index, card) in added.enumerated() { appearIndex[card.id] = index }
        for card in added { cardChanges[card.id] = card.objectWillChange.sink { [weak self] in self?.objectWillChange.send() } }
        cards += added
        for card in added { loadDetails(card) }
    }

    /// A file whose conversion elsewhere stopped on a problem the person answers here (`WindowPresenting.showProblem`, from
    /// a background conversion's notification): its card keeps that conversion's target and options and shows the problem
    /// with its fix (ux §7.2).
    func showProblem(_ url: URL, target: FormatID, options: OptionValues, problem: ConversionError) {
        add([url], target: target)
        guard let card = cards.last(where: { $0.url == url }), card.source != nil, !card.state.isActive else { return }
        card.target = target
        card.options = options
        replan(card)
        card.state = .failed(problem)
    }

    /// The position of a newly added card in its drop, for the staggered appearance (ux §3.6).
    private(set) var appearIndex: [UUID: Int] = [:]

    private func makeCard(_ url: URL, preset: FormatID?) -> FileCard {
        let sniff = (try? Services.sniffer.sniff(url)) ?? SniffResult(format: nil, claimed: nil, sizeBytes: Self.size(of: url))
        let size = sniff.sizeBytes > 0 ? sniff.sizeBytes : Self.size(of: url)
        let card = FileCard(url: url, sizeBytes: size, source: sniff.format, mismatch: sniff.mismatch ? sniff.format : nil)
        guard let source = sniff.format else { card.state = .unreadable; return card }
        let traits = FileFacts.traits(url, format: source)
        let target: FormatID? = {
            if let preset, FormatMatrix.route(from: source, to: preset)?.isOffered == true { return preset }
            return DefaultTargets.target(for: source, traits: traits, remembered: Defaults[.target(for: source)])
        }()
        card.target = target
        if let target { card.options = Defaults[.savedOptions(for: target)] ?? OptionValues() }
        replan(card)
        return card
    }

    private func loadDetails(_ card: FileCard) {
        let url = card.url, source = card.source
        Task { [weak card] in
            let facts = await FileFacts.read(url, format: source)
            if !facts.isEmpty { card?.facts = facts }
        }
        if let thumbnails = Services.thumbnails {
            Task { [weak card] in
                let image = await thumbnails.thumbnail(for: url, size: SCMetrics.Card.thumbnailFit, scale: 2)
                card?.thumbnail = image
            }
        }
    }

    func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            guard Self.isFolder(url) else { result.append(url); continue }
            let top = Self.contents(of: url)
            let files = top.filter { !Self.isFolder($0) }
            let deep = top.filter(Self.isFolder).flatMap(Self.allFiles)
            result += files
            if !deep.isEmpty, files.count + deep.count > 200, actions.includeSubfolders(folder: url.lastPathComponent, fileCount: files.count + deep.count) {
                result += deep
            }
        }
        return result
    }

    private static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    private static func contents(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                       options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func allFiles(in folder: URL) -> [URL] {
        contents(of: folder).flatMap { isFolder($0) ? allFiles(in: $0) : [$0] }
    }

    // MARK: Targets

    func replan(_ card: FileCard) {
        guard let request = card.request else { return }
        let plan = Services.planner.plan(for: request)
        card.route = plan.choice
        card.optionProfile = plan.optionProfile
        card.betterWithHelper = plan.betterWithHelper
        card.availableLooks = plan.availableLooks
    }

    func pickerTargets(for card: FileCard) -> [PickerTarget] {
        guard let source = card.source else { return [] }
        return Services.planner.targets(for: source).map { PickerTarget(format: $0.format, choice: $0.choice) }
    }

    func pickerModel(for card: FileCard) -> FormatPickerModel? {
        guard let source = card.source else { return nil }
        return FormatPickerModel(source: source, current: card.target, targets: pickerTargets(for: card), remember: Defaults[.rememberFormatChoices])
    }

    /// The cards a picker choice on `card` applies to: the whole selection when the card is part of a multi-selection.
    func affected(by card: FileCard) -> [FileCard] {
        selection.contains(card.id) && selection.count > 1 ? cards.filter { selection.contains($0.id) && $0.isEditable } : [card]
    }

    /// Picks a target from the picker (ux §5.4); `remember` is the "from now on" checkbox.
    func pick(_ format: FormatID, remember: Bool, for card: FileCard) {
        setTarget(format, for: affected(by: card))
        if remember, Defaults[.rememberFormatChoices], let source = card.source { Defaults[.target(for: source)] = format }
        pickerFor = nil
    }

    func setTarget(_ format: FormatID, for list: [FileCard]) {
        for card in list {
            guard let source = card.source, FormatMatrix.route(from: source, to: format)?.isOffered == true, card.isEditable else { continue }
            card.target = format
            card.options = Defaults[.savedOptions(for: format)] ?? OptionValues()
            card.look = nil
            card.preferHelper = nil
            if case .failed = card.state { card.state = .ready }
            replan(card)
        }
    }

    /// "Set all to": targets every editable card can become (ux §5.3).
    var commonTargets: [FormatID] {
        let lists = editableCards.map { Set(pickerTargets(for: $0).filter(\.isAvailable).map(\.format)) }
        guard var common = lists.first else { return [] }
        for list in lists.dropFirst() { common.formIntersection(list) }
        return common.sorted()
    }

    /// Per-category groups when there is no common target ("Images to JPG, documents to PDF").
    var targetGroups: [(category: FormatCategory, targets: [FormatID])] {
        FormatCategory.allCases.compactMap { category in
            let inCategory = editableCards.filter { $0.sourceCategory == category }
            let lists = inCategory.map { Set(pickerTargets(for: $0).filter(\.isAvailable).map(\.format)) }
            guard var common = lists.first else { return nil }
            for list in lists.dropFirst() { common.formIntersection(list) }
            return common.isEmpty ? nil : (category, common.sorted())
        }
    }

    var editableCards: [FileCard] { cards.filter { $0.isEditable && $0.state == .ready } }

    /// The target every card shares, shown in the popup instead of "Choose a format".
    var sharedTarget: FormatID? {
        let targets = Set(editableCards.compactMap(\.target))
        return targets.count == 1 && targets.first.map({ t in editableCards.allSatisfy { $0.target == t } }) == true ? targets.first : nil
    }

    func setAll(_ format: FormatID, category: FormatCategory? = nil) {
        setTarget(format, for: editableCards.filter { category == nil || $0.sourceCategory == category })
    }

    // MARK: Options

    func openOptions(for card: FileCard) {
        guard let source = card.source, let target = card.target, let id = card.optionProfile, let profile = OptionProfiles.profile(id) else { return }
        let group = affected(by: card).filter { $0.source == source && $0.target == target }
        let list = group.isEmpty ? [card] : group
        let subtitle = Self.subtitle(for: list)
        var pixels: (Int, Int)?
        if let fact = card.facts.first, let parts = Optional(fact.components(separatedBy: " × ")), parts.count == 2,
           let w = Int(parts[0]), let h = Int(parts[1]) { pixels = (w, h) }
        let model = OptionsModel(source: source, target: target, profile: profile, values: card.options, look: card.look,
                                 looks: card.availableLooks, subtitle: subtitle, pixels: pixels)
        options = OptionsSession(model: model, cards: list)
    }

    /// "Beach at golden hour.heic and 1 more photo".
    static func subtitle(for list: [FileCard]) -> String {
        guard let first = list.first else { return "" }
        guard list.count > 1 else { return first.name }
        return "\(first.name) and \(list.count - 1) more \(first.sourceCategory.noun(count: list.count - 1))"
    }

    func applyOptions() {
        guard let session = options else { return }
        for card in session.cards {
            card.options = session.model.values
            card.look = session.model.look
            replan(card)
        }
        if session.model.useForEvery { Defaults[.savedOptions(for: session.model.target)] = session.model.values.isEmpty ? nil : session.model.values }
        options = nil
    }

    func cancelOptions() { options = nil }

    // MARK: Selection and removal

    func click(_ card: FileCard, extend: Bool, range: Bool) {
        if range, let anchor = cards.firstIndex(where: { selection.contains($0.id) }), let index = cards.firstIndex(where: { $0.id == card.id }) {
            let slice = cards[min(anchor, index)...max(anchor, index)]
            selection.formUnion(slice.map(\.id))
        } else if extend {
            if selection.contains(card.id) { selection.remove(card.id) } else { selection.insert(card.id) }
        } else {
            selection = [card.id]
        }
    }

    func selectAll() { selection = Set(cards.map(\.id)) }

    var selectedCards: [FileCard] { cards.filter { selection.contains($0.id) } }

    /// Moves the selection by a step (arrows); vertical steps are a row of `columns`.
    func moveSelection(_ step: Int) {
        let order = displayCards
        guard !order.isEmpty else { return }
        guard let last = order.lastIndex(where: { selection.contains($0.id) }) else { selection = [order[0].id]; return }
        selection = [order[min(max(last + step, 0), order.count - 1)].id]
    }

    func remove(_ list: [FileCard]) {
        for card in list {
            if card.state.isActive, let job = card.jobID { Services.queue.cancel(job) }
            if let job = card.jobID { jobs[job] = nil }
            cardChanges[card.id] = nil
            selection.remove(card.id)
        }
        let ids = Set(list.map(\.id))
        cards.removeAll { ids.contains($0.id) }
        batch.removeAll { ids.contains($0) }
    }

    func removeSelected() { remove(selectedCards) }

    /// The trash button: removes everything (asking first while files are converting).
    func clear() {
        if activeCount > 0, !actions.confirmStop(count: activeCount) { return }
        remove(cards)
    }

    /// "Convert more": clears finished cards.
    func convertMore() { remove(cards.filter { $0.state.isFinished }) }

    // MARK: Converting

    func convert(_ subset: [FileCard]? = nil) {
        startListening()
        let place = Defaults[.outputPlace]
        var started = false
        for card in subset ?? cards where card.state == .ready {
            guard let request = card.request else { continue }
            let plan = Services.planner.plan(for: request)
            card.route = plan.choice
            started = true
            if !batch.contains(card.id) { batch.append(card.id) }
            switch plan.choice {
            case .unavailable: continue
            case .helper(_, _, let missing) where !missing.isEmpty: card.state = .waitingForHelper(missing[0])
            default: enqueue(card, plan, place)
            }
        }
        if started, batchStart == nil { batchStart = Date() }
        objectWillChange.send()
    }

    private func enqueue(_ card: FileCard, _ plan: ConversionPlan, _ place: OutputPlace) {
        let job = Services.queue.enqueue(plan, into: place)
        card.jobID = job
        card.announcedStep = 0
        jobs[job] = card.id
        card.state = .queued
    }

    /// Stops every running job; partial output is deleted by the queue (ux §5.6).
    func stop() {
        for card in cards where card.state.isActive {
            if let job = card.jobID { Services.queue.cancel(job) }
            card.state = .ready
            card.jobID = nil
        }
        finishBatchIfDone()
    }

    private func startListening() {
        guard listener == nil, let queue = Services.queue else { return }
        let events = queue.events
        listener = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
    }

    func handle(_ event: JobEvent) {
        func card(_ id: JobID) -> FileCard? { jobs[id].flatMap { uuid in cards.first { $0.id == uuid } } }
        switch event {
        case .queued: break
        case .waitingForHelper(let id, let helper): card(id)?.state = .waitingForHelper(helper)
        case .started(let id): card(id)?.state = .converting(JobProgress(fraction: nil))
        case .progress(let id, let progress):
            guard let c = card(id) else { break }
            c.state = .converting(progress)
            if let f = progress.fraction, Int(f * 4) > c.announcedStep {
                c.announcedStep = Int(f * 4)
                announce("\(c.displayName), \(min(c.announcedStep * 25, 100)) percent")
            }
        case .finished(let id, let result):
            guard let c = card(id) else { break }
            c.state = .done(result)
            c.helperInstall = nil
            announce("\(c.displayName) converted")
            loadResultThumbnail(c, result)
        case .failed(let id, let error):
            guard let c = card(id) else { break }
            c.state = error == .cancelled ? .ready : .failed(error)
            if error != .cancelled { announce("\(c.displayName) didn’t convert. \(Strings.problem(error).message)") }
        case .cancelled(let id):
            if let c = card(id) { c.state = .ready; c.jobID = nil }
        }
        finishBatchIfDone()
    }

    private func loadResultThumbnail(_ card: FileCard, _ result: ConversionResult) {
        guard let output = result.outputs.first, let thumbnails = Services.thumbnails else { return }
        Task { [weak card] in card?.resultThumbnail = await thumbnails.thumbnail(for: output, size: SCMetrics.Card.thumbnailFit, scale: 2) }
    }

    private func finishBatchIfDone() {
        guard let start = batchStart, !cards.contains(where: { $0.state.isActive }), cards.contains(where: { $0.state.isFinished }) else {
            if batchStart != nil, !cards.contains(where: { $0.state.isActive }), !cards.contains(where: { $0.state.isFinished }) { batchStart = nil }
            return
        }
        batchStart = nil
        onBatchFinished?(finishedTitle, finishedDetail, Date().timeIntervalSince(start))
        objectWillChange.send()
    }

    // MARK: Fixes (ux §7.2) and helpers

    func perform(_ fix: ConversionError.Fix, for card: FileCard) {
        switch fix {
        case .enterPassword:
            guard let password = actions.askPassword(for: card.name) else { return }
            card.options["password"] = .string(password)
            card.state = .ready
            replan(card)
        case .tryWithLibreOffice:
            card.preferHelper = true
            card.state = .ready
            convert([card])
        case .install, .get:
            installHelper(for: card)
        case .tryAgain:
            card.state = .ready
            convert([card])
        case .extractAnyway:
            // The question names the option that goes ahead (quality §8: a decompression bomb asks first).
            guard case .failed(.needsConfirmation(_, _, let option)) = card.state else { return }
            card.options[option] = .bool(true)
            card.state = .ready
            convert([card])
        case .showInFinder:
            actions.reveal([card.url])
        case .chooseAnotherFolder:
            guard let folder = actions.chooseFolder() else { return }
            Defaults[.outputPlace] = .folder(folder)
            card.state = .ready
            convert([card])
        }
    }

    /// The helper a card is blocked on, from its route or its state.
    func blockingHelper(of card: FileCard) -> HelperID? {
        if case .waitingForHelper(let h) = card.state { return h }
        if case .failed(.helperMissing(let h)) = card.state { return h }
        if case .done = card.state { return card.betterWithHelper }
        return card.missingHelpers.first
    }

    var libreOfficeReady: Bool { Services.helpers?.status(of: .libreoffice).isReady == true }

    func cancel(_ card: FileCard) {
        if let job = card.jobID { Services.queue.cancel(job) }
    }

    /// "Make it look like the original — Install LibreOffice" on a done card: installs, then the card is ready to run again
    /// with the helper route.
    func installBetterLook(_ card: FileCard) { installHelper(for: card) }

    func installHelper(for card: FileCard) {
        guard let helper = blockingHelper(of: card) else { return }
        guard case .oneClick = HelperCatalog.info(helper).install else { actions.get(helper); return }
        guard installing.insert(helper).inserted, let helpers = Services.helpers else { return }
        let stream = helpers.install(helper)
        for c in cards where blockingHelper(of: c) == helper { c.helperInstall = 0 }
        Task { [weak self] in
            for await progress in stream { self?.helperProgress(helper, progress) }
        }
    }

    private func helperProgress(_ helper: HelperID, _ progress: InstallProgress) {
        let affected = cards.filter { blockingHelper(of: $0) == helper || $0.helperInstall != nil && $0.missingHelpers.contains(helper) }
        switch progress {
        case .downloading(let f): for c in affected { c.helperInstall = min(f, 0.99) }
        case .verifying, .unpacking: for c in affected { c.helperInstall = 0.99 }
        case .finished(let status):
            installing.remove(helper)
            for c in affected {
                c.helperInstall = nil
                let wasWaiting: Bool = { if case .waitingForHelper = c.state { true } else { false } }()
                if status.isReady, case .done = c.state, c.betterWithHelper == helper {
                    c.betterWithHelper = nil
                    c.preferHelper = true
                    c.state = .ready
                    replan(c)
                } else if status.isReady {
                    if case .failed = c.state { c.state = .ready }
                    if wasWaiting { c.state = .ready }
                    replan(c)
                    if wasWaiting { convert([c]) }
                }
            }
        case .failed(let message):
            installing.remove(helper)
            for c in affected {
                c.helperInstall = nil
                c.state = .failed(.failed(message))
            }
        }
    }

    // MARK: Results

    func revealResults() { actions.reveal(doneOutputs) }

    /// The Done card's Quick Look button: selects the card and opens the panel (Space toggles it, `toggleQuickLook`).
    func quickLook(_ card: FileCard) {
        selection = [card.id]
        actions.setQuickLook(true)
    }

    func toggleQuickLook() {
        guard actions.quickLookShown || !selection.isEmpty else { return }
        actions.setQuickLook(!actions.quickLookShown)
    }

    /// The files a card previews: its results once done (every file inside a "name (FORMAT)" folder), else its source.
    func previewFiles(for card: FileCard) -> [URL] {
        guard case .done(let result) = card.state, !result.outputs.isEmpty else { return [card.url] }
        return result.outputs.flatMap { output -> [URL] in
            guard Self.isFolder(output) else { return [output] }
            return Self.contents(of: output).filter { !Self.isFolder($0) }
        }
    }

    func chooseFiles(filter: FormatID? = nil, target: FormatID? = nil) {
        let urls = actions.chooseFiles(filter: filter)
        if !urls.isEmpty { add(urls, target: target) }
    }

    func chooseOutputFolder() {
        if let folder = actions.chooseFolder() { Defaults[.outputPlace] = .folder(folder); objectWillChange.send() }
    }

    func setOutputPlace(_ place: OutputPlace) { Defaults[.outputPlace] = place; objectWillChange.send() }

    /// Opens a finished card's file in its default app (double-click).
    func open(_ card: FileCard) {
        if case .done(let result) = card.state, let output = result.outputs.first { actions.open(output) }
    }
}

extension WindowViewModel: QuickLookSource {
    var previewEntries: [PreviewEntry] {
        displayCards.filter { selection.contains($0.id) }.flatMap { card in previewFiles(for: card).map { PreviewEntry(url: $0, cardID: card.id) } }
    }

    var previewStartIndex: Int {
        let selected = displayCards.filter { selection.contains($0.id) }
        guard let primary = selected.last else { return 0 }
        return selected.prefix { $0.id != primary.id }.reduce(0) { $0 + previewFiles(for: $1).count }
    }

    var arrowsMoveSelection: Bool { selection.count <= 1 }
    var gridColumns: Int { columns }
    func thumbnailFrame(of card: UUID) -> CGRect? { thumbnailFrames[card] }

    func transitionImage(of card: UUID) -> NSImage? {
        guard let card = cards.first(where: { $0.id == card }) else { return nil }
        return card.resultThumbnail ?? card.thumbnail
    }
}
