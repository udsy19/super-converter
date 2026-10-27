import AppKit
import SuperConverterCore
@preconcurrency import UserNotifications

/// Posts the "Done" notification of a background conversion.
@MainActor
protocol BatchNotifying: AnyObject {
    /// `reveal` is the first file written: the notification's Show action opens its folder in Finder.
    func post(title: String, body: String, reveal: URL?)
}

/// The system notification. It needs an app bundle (a bare executable such as the self-test posts nothing).
@MainActor
final class SystemNotifier: BatchNotifying {
    func post(title: String, body: String, reveal: URL?) {
        if Defaults[.playSound] { NSSound(named: "Glass")?.play() }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let category = "convert.done"
        center.setNotificationCategories([UNNotificationCategory(
            identifier: category, actions: [UNNotificationAction(identifier: "show", title: "Show", options: [.foreground])],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            if let reveal { content.userInfo = ["path": reveal.path] }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Shows banners while the app is frontmost and reveals the file when a notification is clicked or its Show action is used.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        completionHandler()
    }
}
