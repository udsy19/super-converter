import AppKit
import Combine
import SuperConverterCore

/// The menu-bar panel's state and rules (ux §5.9): files dropped on the icon, their targets, the run, the recent list.
@MainActor
final class PanelModel: ObservableObject {
    enum Phase: Equatable { case idle, ready, converting, finished }

    @Published private(set) var items: [BatchItem] = []
    @Published private(set) var recents: [RecentConversion] = []
    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    @Published private(set) var place: OutputPlace = Defaults[.outputPlace]

    let converter: BackgroundConverter
    /// What the footer and the actions reach outside the panel with; the controller sets them, tests record them.
    var openApp: () -> Void = {}
    var openSettings: () -> Void = {}
    var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    var chooseFolder: () -> URL? = {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
    /// True while the panel is on screen; a run that ends with the panel closed posts a notification (ux §5.7).
    var isShown = false
    private var run: Task<Void, Never>?

    init(converter: BackgroundConverter) {
        self.converter = converter
        recents = converter.recents.load()
        converter.onRecentsChanged = { [weak self] in self?.refreshRecents() }
    }

    // MARK: Derived state

    var phase: Phase {
        if items.isEmpty { return .idle }
        if items.contains(where: { $0.state.isActive }) { return .converting }
        if items.contains(where: { $0.state == .ready }) { return .ready }
        return .finished
    }

    var readyItems: [BatchItem] { items.filter { $0.state == .ready && $0.target != nil } }

    /// "2 files dropped" · "Converting…" · "Done".
    var subtitle: String? {
        switch phase {
        case .idle: nil
        case .ready: "\(Formatting.count(items.count, "file", "files")) dropped"
        case .converting: Strings.Window.subtitleConverting(done: items.filter { $0.state.isFinished }.count, of: items.count)
        case .finished: Strings.Window.subtitleConverted(done: items.filter { if case .done = $0.state { true } else { false } }.count, of: items.count)
        }
    }

    var convertTitle: String { Strings.Window.convertButton(files: readyItems.count) }

    /// The Convert button's fill (ux §3.4 item 4): the batch's target categories in order.
    var buttonCategories: [FormatCategory] {
        var seen: [FormatCategory] = []
        for item in readyItems where !seen.contains(item.targetCategory) { seen.append(item.targetCategory) }
        return seen
    }

    /// "Saved next to the originals".
    var placeLine: String { "Saved \(place.phrase)" }

    // MARK: Files

    /// Adds dropped files (folders count for the files directly inside); a finished batch is replaced.
    func add(_ urls: [URL]) {
        if phase == .finished { items = [] }
        let files = urls.flatMap(Self.expand)
        let new = BatchRunner.prepare(files)
        items += new
        loadThumbnails(new.map(\.url))
        if Defaults[.convertOnMenuBarDrop] { convert() }
    }

    /// A folder becomes the files directly inside it, visible ones only; anything else stays as it is.
    static func expand(_ url: URL) -> [URL] {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true, !url.isPackage else { return [url] }
        let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])) ?? []
        return inside.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func remove(_ item: BatchItem) { items.removeAll { $0.id == item.id } }

    /// The targets the item's source can become, each as the picker would list it; unavailable pairs are left out.
    func targets(for item: BatchItem) -> [FormatID] {
        guard let source = item.source else { return [] }
        return Services.planner.targets(for: source).filter { if case .unavailable = $0.choice { false } else { true } }.map(\.format)
    }

    /// Changes one file's target and remembers the choice as the default for its format (ux §5.4).
    func setTarget(_ target: FormatID, for item: BatchItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].target = target
        items[i].options = Defaults[.savedOptions(for: target)] ?? OptionValues()
        if Defaults[.rememberFormatChoices], let source = item.source { Defaults[.target(for: source)] = target }
    }

    // MARK: Converting

    func convert() {
        guard phase == .ready, run == nil else { return }
        let batch = items
        let place = Defaults[.outputPlace]
        run = Task { @MainActor in
            let done = await BatchRunner.run(batch, place: place) { [weak self] changed in
                if let i = self?.items.firstIndex(where: { $0.id == changed.id }) { self?.items[i] = changed }
            }
            items = done
            converter.finish(done, place: place, notify: !isShown)
            loadThumbnails(done.flatMap { item -> [URL] in if case .done(let r) = item.state { r.outputs.prefix(1).map { $0 } } else { [] } })
            run = nil
        }
    }

    /// The task of the running batch, for tests to await.
    var running: Task<Void, Never>? { run }

    func setPlace(_ new: OutputPlace) {
        Defaults[.outputPlace] = new
        place = new
    }

    func chooseOutputFolder() {
        if let folder = chooseFolder() { setPlace(.folder(folder)) }
    }

    /// The panel closed: finished results are cleared so the next click starts empty.
    func panelClosed() {
        isShown = false
        if phase == .finished { items = [] }
    }

    func panelOpened() {
        isShown = true
        place = Defaults[.outputPlace]
        refreshRecents()
    }

    func refreshRecents() {
        recents = converter.recents.load()
        loadThumbnails(recents.map(\.output))
    }

    private func loadThumbnails(_ urls: [URL]) {
        guard let service = Services.thumbnails else { return }
        for url in urls where thumbnails[url] == nil {
            Task { @MainActor [weak self] in
                let size = CGSize(width: SCMetrics.MenuBarPanel.thumbnail, height: SCMetrics.MenuBarPanel.thumbnail)
                if let image = await service.thumbnail(for: url, size: size, scale: 2) { self?.thumbnails[url] = image }
            }
        }
    }
}

extension BatchItem.State {
    /// Queued, waiting or converting.
    var isActive: Bool {
        switch self {
        case .queued, .waiting, .converting: true
        default: false
        }
    }
}

private extension URL {
    var isPackage: Bool { (try? resourceValues(forKeys: [.isPackageKey]))?.isPackage == true }
}
