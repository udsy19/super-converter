// The Finder Quick Actions (ux §5.10). One executable serves six app extensions that scripts/build-app.sh packages in
// Contents/PlugIns, each with its own Info.plist naming its action. Linked with `NSExtensionMain` as its entry point, it
// runs in its own process; WP-B hands the selected files to the app as a `superconverter://` link.
import AppKit
import SuperConverterCore

@objc(QuickActionRequestHandler)
final class QuickActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil)
    }
}
