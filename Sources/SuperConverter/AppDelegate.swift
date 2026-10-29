import AppKit
import CoreServices
import SuperConverterCore
import UpdateKit
import HelperKit
import ConvertKit
import WindowKit
import MenuBarKit
import SettingsKit
import ImageKit
import VectorKit
import XPSKit
import VectorizeKit
import CADKit
import DocKit
import TypesetKit
import MathKit
import LayoutKit
import RenderKit
import OfficeKit
import EbookKit
import ArchiveKit
import MediaKit
import FontKit

/// The launch sequence (ARCHITECTURE §9) and the app-level answers AppKit asks for: files and links opened from outside,
/// reopening from the Dock, quitting while converting. Everything else lives in the modules, reached through `Services`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A throwaway data folder or defaults suite (`SUPERCONVERTER_DATA_DIR` / `SUPERCONVERTER_DEFAULTS_SUITE`, tests): no
    /// updater and no LaunchServices registration, so a test build never becomes the Mac's Open With or Quick Action app.
    private var isThrowaway = false
    /// Files and links that arrive before launch finishes wait here (step 4 opens them), each with who sent it.
    private var pending: [(url: URL, origin: LinkOrigin)] = []
    private var isLaunched = false
    /// Something was opened from outside, so the empty window isn't shown on its own.
    private var openedFromOutside = false
    /// `NSApp.servicesProvider` is not retained by AppKit.
    private var servicesProvider: NSObject?

    // MARK: Launch

    /// Steps 1–3: Core bootstrap, the modules in order, the updater, the main menu and the Services provider.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 1. Core bootstrap.
        isThrowaway = CoreBootstrap.configure()
        SuperConverterPaths.ensure(SuperConverterPaths.support)

        // 2. Modules in order: HelperKit, every engine, then the feature modules (ConvertKit checks the matrix against
        // every engine's converters, computes availability and sweeps the work folders of jobs whose process is gone).
        HelperKitModule.install()
        ImageKitModule.install()
        RenderKitModule.install()
        VectorKitModule.install()
        XPSKitModule.install()
        VectorizeKitModule.install()
        CADKitModule.install()
        DocKitModule.install()
        MathKitModule.install()
        TypesetKitModule.install()
        LayoutKitModule.install()
        OfficeKitModule.install()
        EbookKitModule.install(extractor: ArchiveKitModule.extractor())
        ArchiveKitModule.install()
        MediaKitModule.install()
        FontKitModule.install()
        UpdateKitModule.install()
        ConvertKitModule.install()
        WindowKitModule.install()
        MenuBarKitModule.install()
        SettingsKitModule.install()

        // 3. The app target's own: the updater, the menus, the Services entries (Info.plist `NSServices`).
        Services.updates = Self.makeUpdater()
        NSApp.mainMenu = MainMenu.make()
        servicesProvider = MenuBarKitModule.servicesProvider()
        NSApp.servicesProvider = servicesProvider
        NSApp.setActivationPolicy(.regular)
    }

    /// Step 3 continued and step 4: Services and LaunchServices registration, the menu-bar item, the files and links passed
    /// in (or the empty window), then the updater.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
        Log.app.info("Super Converter \(version, privacy: .public) launched")
        NSUpdateDynamicServices()
        if !isThrowaway, Bundle.main.bundleURL.pathExtension == "app" {
            // Registers the document types (Open With for every input format), the URL scheme and the Quick Action
            // extensions in Contents/PlugIns, so Finder finds them without a Spotlight pass.
            LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        }
        Services.menuBar.install()

        isLaunched = true
        let waiting = pending
        pending = []
        if !waiting.isEmpty { open(waiting) }
        // Links from a cold launch (a Quick Action's `superconverter://convert`) arrive just after this; the empty window
        // shows only when nothing came.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                if !self.openedFromOutside { Services.window.show() }
            }
        }
        if !isThrowaway { Services.updates.start() }
    }

    // MARK: Files and links (Finder's Open and Open With, the Dock icon, Quick Actions, `superconverter://`)

    /// Who sent the links is read from the Apple Event being handled, so it is known before they wait for launch to finish.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedFromOutside = true
        let origin = LinkOrigin.of(NSAppleEventManager.shared().currentAppleEvent,
                                   plugIns: Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns", isDirectory: true))
        let arrived = urls.map { (url: $0, origin: origin) }
        guard isLaunched else { pending += arrived; return }
        open(arrived)
    }

    /// Links are followed in order (`superconverter://open` adds files to the window, `superconverter://convert?file=…&to=jpg`
    /// from a Quick Action converts in the background and notifies, from anywhere else fills the window: MenuBarKit's), then
    /// the files become cards in the window together.
    private func open(_ urls: [(url: URL, origin: LinkOrigin)]) {
        for (url, origin) in urls where !url.isFileURL {
            if !MenuBarKitModule.handle(url, from: origin) { Log.app.error("Ignored a link it doesn't know: \(url.absoluteString, privacy: .private)") }
        }
        let files = urls.map(\.url).filter(\.isFileURL)
        if !files.isEmpty { Services.window.add(files, target: nil) }
    }

    // MARK: Windows and quitting

    /// The window can close while conversions continue (ux §6.5 ⌘W); the menu-bar item stays.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A Dock click with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Services.window.show() }
        return true
    }

    /// "Stop converting 3 files?" (ux §6.4).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (Services.window as? MainWindowController)?.confirmTermination() == false ? .terminateCancel : .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: App-level menu commands (the end of the responder chain)

    /// ⌘O with the window closed: the window opens and asks for files.
    @objc func addFiles(_ sender: Any?) {
        Services.window.show()
        (Services.window as? MainWindowController)?.addFiles(sender)
    }

    @objc func showMainWindow(_ sender: Any?) { Services.window.show() }

    @objc func showSettings(_ sender: Any?) { Services.settings.show(pane: nil) }

    /// Version, licences and the privacy statement live in Settings › About (ux §5.11).
    @objc func showAbout(_ sender: Any?) { Services.settings.show(pane: .about) }

    /// The status shows in Settings › About, next to the automatic-updates switch.
    @objc func checkForUpdates(_ sender: Any?) {
        Services.updates.checkNow()
        Services.settings.show(pane: .about)
    }

    @objc func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(SuperConverterPaths.repository.appendingPathComponent("blob/main/README.md"))
    }

    // MARK: The engine the app target owns

    /// UpdateKit on this repository's releases. Automatic checks follow Settings › General "Check for updates"; "Check for
    /// Updates…" always checks. A staged update goes in when the app quits, or sooner when it is idle: in the background,
    /// nothing converting, no files waiting in the window and nothing asking a question.
    private static func makeUpdater() -> Updater {
        Updater(app: UpdateIdentity(bundleID: SuperConverterPaths.bundleID, appName: "\(SuperConverterPaths.appName).app",
                                    displayName: SuperConverterPaths.appName, repository: "udsy19/super-converter",
                                    assetBase: SuperConverterPaths.updateAssetBase, feedOverride: "SUPERCONVERTER_UPDATE_FEED"),
                stateFile: SuperConverterPaths.updateState,
                enabled: { Defaults[.checkForUpdates] },
                enabledChanges: Defaults.publisher(.checkForUpdates).dropFirst().map { _ in () }.eraseToAnyPublisher(),
                canInstallNow: {
                    !NSApp.isActive && NSApp.modalWindow == nil && Services.queue.activeCount == 0 && !Services.window.hasWork
                })
    }
}
