import AppKit
import Combine
import Quartz
import SuperConverterCore
import SwiftUI
import UserNotifications

/// The main window (ux §4): one window, remembered frame, a unified toolbar whose content is SwiftUI, files dropped
/// anywhere on it. Registered as `Services.window` by `WindowKitModule.install()`.
@MainActor
public final class MainWindowController: NSWindowController, NSWindowDelegate, WindowPresenting {
    let viewModel: WindowViewModel
    private var subscriptions: Set<AnyCancellable> = []
    private let dock = DockProgress()
    private lazy var quickLook = QuickLookController(source: viewModel)
    private weak var host: NSView?

    public init() { self.viewModel = WindowViewModel(); super.init(window: nil); build() }

    init(viewModel: WindowViewModel) { self.viewModel = viewModel; super.init(window: nil); build() }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let host = DropHostingView(rootView: MainView(vm: viewModel))
        host.onDrag = { [weak self] urls in self?.viewModel.drag = urls.map { DragSummary(urls: $0) } }
        host.onDrop = { [weak self] urls in self?.viewModel.add(urls); self?.viewModel.drag = nil }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SCMetrics.Window.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.title = Strings.appName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "SuperConverterToolbar")
        window.minSize = SCMetrics.Window.minimumSize
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.delegate = self
        window.setFrameAutosaveName("SuperConverterMainWindow")
        if !window.setFrameUsingName("SuperConverterMainWindow") { window.center() }
        self.window = window
        self.host = host
        quickLook.screenRect = { [weak self] rect in
            guard let host = self?.host, let window = host.window else { return .zero }
            return window.convertToScreen(host.convert(rect, to: nil))
        }
        viewModel.$selection.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.quickLook.refresh() }.store(in: &subscriptions)

        viewModel.onBatchFinished = { [weak self] title, detail, took in self?.batchFinished(title, detail, took) }
        viewModel.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateDock() }.store(in: &subscriptions)
    }

    // MARK: WindowPresenting

    public func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func add(_ urls: [URL], target: FormatID?) {
        viewModel.add(urls, target: target)
        show()
    }

    public func showProblem(_ url: URL, target: FormatID, options: OptionValues, problem: ConversionError) {
        viewModel.showProblem(url, target: target, options: options, problem: problem)
        show()
    }

    public var hasWork: Bool { viewModel.hasWork }

    /// The quit check (ux §6.4): "Stop converting 3 files?". True when the app may quit; running jobs are stopped.
    public func confirmTermination() -> Bool {
        guard viewModel.activeCount > 0 else { return true }
        guard viewModel.actions.confirmStop(count: viewModel.activeCount) else { return false }
        viewModel.stop()
        return true
    }

    // MARK: Responder-chain actions for the app's menus (ux §6.5)

    @objc public func addFiles(_ sender: Any?) { viewModel.chooseFiles() }
    @objc public func convertAll(_ sender: Any?) { viewModel.convert() }
    @objc public func stopConverting(_ sender: Any?) { viewModel.stop() }
    @objc public func revealResults(_ sender: Any?) { viewModel.revealResults() }
    @objc public func showGridView(_ sender: Any?) { viewModel.setViewMode(.grid) }
    @objc public func showListView(_ sender: Any?) { viewModel.setViewMode(.list) }

    // MARK: Quick Look (ux §5.7): the panel asks the responder chain for its controller

    public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.begin(panel) }
    public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { quickLook.end(panel) }

    // MARK: NSWindowDelegate

    /// Sheets drop from under the toolbar, as in the mockup (ux §3.5).
    public func window(_ window: NSWindow, willPositionSheet sheet: NSWindow, using rect: NSRect) -> NSRect {
        var placed = rect
        placed.origin.y = (window.contentView?.frame.height ?? rect.origin.y) - SCMetrics.Window.toolbarHeight
        return placed
    }

    // MARK: Dock and notifications (ux §5.6, §5.7)

    private func updateDock() {
        dock.update(active: viewModel.activeCount, fraction: viewModel.overallFraction)
    }

    private func batchFinished(_ title: String, _ detail: String, _ took: TimeInterval) {
        guard window?.isKeyWindow != true else { return }
        if Defaults[.notifyWhenDone], took > 10 {
            BatchNotifier.post(title: title, body: detail)
        } else if !Defaults[.notifyWhenDone] {
            NSSound(named: "Pop")?.play()
        }
        if Defaults[.playSound] { NSSound(named: "Glass")?.play() }
    }
}

/// The hosting view that accepts dropped files anywhere in the window (ux §5.2) and reports what hovers.
final class DropHostingView<Content: View>: NSHostingView<Content> {
    var onDrag: (([URL]?) -> Void)?
    var onDrop: (([URL]) -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) { fatalError("not used") }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        // A card dragged out of this window must not be added back to it.
        guard info.draggingSource == nil else { return [] }
        return (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let list = urls(sender)
        guard !list.isEmpty else { return [] }
        onDrag?(list)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { urls(sender).isEmpty ? [] : .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) { onDrag?(nil) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !urls(sender).isEmpty }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let list = urls(sender)
        onDrag?(nil)
        guard !list.isEmpty else { return false }
        onDrop?(list)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { onDrag?(nil) }
}

/// The Dock icon's progress bar and the count of files left (ux §5.6).
@MainActor
final class DockProgress {
    private let bar = NSProgressIndicator()
    private let tile = NSView()
    private var showing = false

    func update(active: Int, fraction: Double) {
        let dock = NSApp.dockTile
        guard active > 0 else {
            if showing { dock.contentView = nil; dock.badgeLabel = nil; dock.display(); showing = false }
            return
        }
        if !showing {
            let size = dock.size
            tile.frame = NSRect(origin: .zero, size: size)
            let icon = NSImageView(frame: tile.bounds)
            icon.image = NSApp.applicationIconImage
            bar.style = .bar
            bar.isIndeterminate = false
            bar.minValue = 0; bar.maxValue = 1
            bar.frame = NSRect(x: 6, y: 8, width: size.width - 12, height: 14)
            tile.subviews.forEach { $0.removeFromSuperview() }
            tile.addSubview(icon)
            tile.addSubview(bar)
            dock.contentView = tile
            showing = true
        }
        bar.doubleValue = fraction
        dock.badgeLabel = "\(active)"
        dock.display()
    }
}

/// "Done. 7 of 8 files converted" when the window is in the background (ux §5.7). Needs an app bundle; a bare executable
/// (the self-test, `swift run`) posts nothing.
enum BatchNotifier {
    static func post(title: String, body: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
