import AppKit
import SuperConverterCore
import UserNotifications

/// MenuBarKit: the status item, drop target and panel (ux §5.9), and everything that converts without the main window:
/// the Finder Quick Actions' logic, the Services entries and background conversions with notifications (ux §5.10)
/// (ARCHITECTURE §3). A feature module: it talks to the others through `Services`.
public enum MenuBarKitModule {
    /// Runs conversions that have no window: Quick Actions, Services, `superconverter://convert` and the panel.
    @MainActor static let background = BackgroundConverter()
    @MainActor private static var notificationRouter: NotificationRouter?

    /// Assigns this module's services in `Services` (ARCHITECTURE §9, launch step 2). The status item appears when the app
    /// calls `Services.menuBar.install()` (after launch), not here.
    @MainActor public static func install() {
        Services.menuBar = MenuBarController(converter: background)
        if Bundle.main.bundleURL.pathExtension == "app" {
            notificationRouter = NotificationRouter()
            UNUserNotificationCenter.current().delegate = notificationRouter
        }
    }

    /// Switches the Quick Actions as ux §5.10 has them at first launch (JPG, PNG and PDF on; MP4 and MP3 off), once,
    /// leaving any the person already chose. The app calls it after registering its bundle with LaunchServices, and never
    /// from a test build: the switches are the Mac's, not the build's.
    @MainActor public static func electQuickActionsAtFirstLaunch() {
        guard let switches = QuickActionSwitches.current else { return }
        Task { await switches.electAtFirstLaunch() }
    }

    /// Runs a link from a Quick Action, a Service or `superconverter://`: `open` adds the files to the window, `convert`
    /// converts them in the background and notifies — when the link comes from this app. A `convert` link from anywhere
    /// else fills the window with the files and the target instead and waits for the person; such a link brings files
    /// only, never folders, so a web page can't make the window read a whole folder.
    @MainActor public static func handle(_ link: QuickActionLink, from origin: LinkOrigin) {
        if Distribution.isAppStore, !grantAccess(to: link.files) { return }
        switch (link.verb, origin) {
        case (.convert, .thisApp):
            background.convert(link.files, target: link.target)
        case (.open, .thisApp):
            Services.window?.add(link.files, target: nil)
            Services.window?.show()
        case (_, .elsewhere):
            let files = link.files.filter { url in
                var isFolder: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && !isFolder.boolValue
            }
            guard !files.isEmpty else { return }
            Services.window?.add(files, target: link.verb == .convert ? link.target : nil)
            Services.window?.show()
        }
    }

    /// Store edition: a Quick Action hands over paths, and the App Sandbox lets the app read only what the person chose. When
    /// the files can't be read, an open panel at their folder asks once for it; the folder is remembered (FolderAccess),
    /// so later Quick Actions there convert straight away, and results can go next to the originals.
    @MainActor static func grantAccess(to files: [URL]) -> Bool {
        if FolderAccess.canRead(files) { return true }
        let folders = Set(files.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: folders.count == 1 ? folders.first! : NSOpenPanel.commonFolder(of: Array(folders)), isDirectory: true)
        panel.prompt = "Allow"
        panel.message = "Super Converter needs your permission to open the files in this folder and save next to them."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let folder = panel.url else { return false }
        FolderAccess.remember(folder)
        return FolderAccess.canRead(files)
    }

    /// Handles a `superconverter://open` or `superconverter://convert` URL; false for anything else.
    @MainActor @discardableResult public static func handle(_ url: URL, from origin: LinkOrigin) -> Bool {
        guard let link = QuickActionLink(url) else { return false }
        handle(link, from: origin)
        return true
    }

    /// The object for `NSApp.servicesProvider` (the entries are `QuickAction.servicesEntries` in the app's Info.plist).
    @MainActor public static func servicesProvider() -> NSObject {
        ServicesProvider(dispatch: { handle($0, from: .thisApp) })
    }
}

private extension NSOpenPanel {
    /// The deepest folder that holds every one of `paths`.
    static func commonFolder(of paths: [String]) -> String {
        let parts = paths.map { $0.split(separator: "/") }
        var common: [Substring] = []
        for (i, part) in (parts.first ?? []).enumerated() where parts.allSatisfy({ $0.count > i && $0[i] == part }) {
            guard common.count == i else { break }
            common.append(part)
        }
        return "/" + common.joined(separator: "/")
    }
}
