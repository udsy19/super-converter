// The Finder Quick Actions (ux §5.10). One executable serves six app extensions that scripts/build-app.sh packages in
// Contents/PlugIns, each with its own Info.plist (Plists/, written from `QuickAction.infoPlist`) naming its action. Linked
// with `NSExtensionMain` as its entry point, it runs sandboxed in its own process: it reads nothing, it only hands the
// selected files to the app as a `superconverter://` link (`QuickActionLink`), and the app converts them in the background
// with a notification, or adds them to its window.
import AppKit
import MenuBarKit
import SuperConverterCore
import UniformTypeIdentifiers

@objc(QuickActionRequestHandler)
final class QuickActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        guard let action = QuickAction(bundleInfo: Bundle.main.infoDictionary) else {
            context.cancelRequest(withError: CocoaError(.featureUnsupported))
            return
        }
        let attachments = context.inputItems.compactMap { $0 as? NSExtensionItem }.flatMap { $0.attachments ?? [] }
        let collected = Collected()
        let group = DispatchGroup()
        for (index, attachment) in attachments.enumerated() where attachment.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            attachment.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                if let url, url.isFileURL { collected.add(url, at: index) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if action.handOff(collected.files, using: SystemURLOpener()) {
                context.completeRequest(returningItems: nil)
            } else {
                context.cancelRequest(withError: CocoaError(.fileReadNoSuchFile))
            }
        }
    }
}

/// The selected files, in Finder's order, gathered from callbacks on any queue.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var byIndex: [Int: URL] = [:]

    func add(_ url: URL, at index: Int) { lock.withLock { byIndex[index] = url } }
    var files: [URL] { lock.withLock { byIndex.keys.sorted().compactMap { byIndex[$0] } } }
}
