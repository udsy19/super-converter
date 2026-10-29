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
    /// converts them in the background and notifies.
    @MainActor public static func handle(_ link: QuickActionLink) {
        switch link.verb {
        case .open:
            Services.window?.add(link.files, target: nil)
            Services.window?.show()
        case .convert:
            background.convert(link.files, target: link.target)
        }
    }

    /// Handles a `superconverter://open` or `superconverter://convert` URL; false for anything else.
    @MainActor @discardableResult public static func handle(_ url: URL) -> Bool {
        guard let link = QuickActionLink(url) else { return false }
        handle(link)
        return true
    }

    /// The object for `NSApp.servicesProvider` (the entries are `QuickAction.servicesEntries` in the app's Info.plist).
    @MainActor public static func servicesProvider() -> NSObject {
        ServicesProvider(dispatch: { handle($0) })
    }
}
