import AppKit
import SuperConverterCore
@preconcurrency import UserNotifications

/// Posts the notifications of a background conversion: "Done", and the questions a conversion stopped on.
@MainActor
protocol BatchNotifying: AnyObject {
    /// `reveal` is the first file written: the notification's Show action opens its folder in Finder.
    func post(title: String, body: String, reveal: URL?)
    /// The file's name and the question; clicking it opens the file's card in the window, which asks it (ux §7.2).
    func ask(_ question: PendingProblem)
}

/// A background conversion that stopped on a question (`ConversionError.needsConfirmation`): what the notification hands
/// to the window (`WindowPresenting.showProblem`) when it is clicked.
struct PendingProblem: Equatable {
    var url: URL
    var target: FormatID
    var options: OptionValues
    var problem: ConversionError

    var title: String { Strings.quoted(url.lastPathComponent) }
    var body: String { Strings.problem(problem).message }

    /// Opens the card in the window.
    @MainActor func open() {
        Services.window?.showProblem(url, target: target, options: options, problem: problem)
    }
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

    /// Questions waiting for a click, by notification id. They live as long as the app; after a relaunch a click adds the
    /// file to the window plainly.
    static var questions: [String: PendingProblem] = [:]

    func ask(_ question: PendingProblem) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let id = UUID().uuidString
        Self.questions[id] = question
        let center = UNUserNotificationCenter.current()
        let category = "convert.question"
        center.setNotificationCategories([UNNotificationCategory(
            identifier: category, actions: [UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])],
            intentIdentifiers: [])])
        let title = question.title, body = question.body, file = question.url.path, target = question.target.rawValue
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            content.userInfo = ["question": id, "file": file, "to": target]
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
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
        let info = response.notification.request.content.userInfo
        if let id = info["question"] as? String, let file = info["file"] as? String {
            let target = (info["to"] as? String).map { FormatID($0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let question = SystemNotifier.questions.removeValue(forKey: id) { question.open() }
                    else { Services.window?.add([URL(fileURLWithPath: file)], target: target); Services.window?.show() }
                }
            }
        } else if let path = info["path"] as? String {
            let url = URL(fileURLWithPath: path)
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        completionHandler()
    }
}
