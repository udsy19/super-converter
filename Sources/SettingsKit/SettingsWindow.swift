import AppKit
import Combine
import SuperConverterCore
import SwiftUI

/// What the panes reach outside themselves for: the services (looked up when used, so the app can register them in any order)
/// and the few system actions the self-test replaces (opening a page, choosing a folder).
@MainActor
final class SettingsContext {
    var helpers: () -> HelperManaging? = { Services.helpers }
    var updates: () -> UpdateChecking? = { Services.updates }
    /// MenuBarKit, which owns the Quick Actions and their switches.
    var menuBar: () -> MenuBarPresenting? = { Services.menuBar }
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var chooseFolder: () -> URL? = { SettingsContext.runPanel(folders: true, files: false) }
    /// A helper's own location: an app or a tool.
    var chooseLocation: () -> URL? = { SettingsContext.runPanel(folders: true, files: true) }
    /// Where the licence notices are read from; nil looks in the app bundle.
    var noticesURL: URL? = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md")
    var version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"

    private static func runPanel(folders: Bool, files: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = folders
        panel.canCreateDirectories = !files
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Which pane is showing.
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var pane: SettingsPane
    init(_ pane: SettingsPane = .general) { self.pane = pane }
}

/// The Settings window (ux §5.11): a row of icon tabs over the pane. Registered as `Services.settings`.
@MainActor
public final class SettingsWindowController: NSWindowController, SettingsPresenting {
    let selection = SettingsSelection()
    let context: SettingsContext
    private var subscriptions = Set<AnyCancellable>()

    public convenience init() { self.init(context: SettingsContext()) }

    init(context: SettingsContext) {
        self.context = context
        super.init(window: nil)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SCMetrics.Settings.size),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(selection: selection, context: context))
        window.setFrameAutosaveName("SuperConverterSettingsWindow")
        if !window.setFrameUsingName("SuperConverterSettingsWindow") { window.center() }
        self.window = window
        selection.$pane.sink { [weak window] pane in window?.title = pane.title }.store(in: &subscriptions)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    public func show(pane: SettingsPane?) {
        if let pane { selection.pane = pane }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
