import AppKit
import SuperConverterCore

/// The Services menu entries (ux §5.10): Finder's Services › "Convert to JPG" and the rest. The app target sets it as
/// `NSApp.servicesProvider` and lists `QuickAction.servicesEntries` under `NSServices` in its Info.plist (scripts/build-app.sh).
/// Each message reads the file URLs from the pasteboard and runs the same link a Quick Action extension hands over.
public final class ServicesProvider: NSObject {
    private let dispatch: @MainActor (QuickActionLink) -> Void

    /// `dispatch` runs the link; the app uses `MenuBarKitModule.handle`.
    public init(dispatch: @escaping @MainActor (QuickActionLink) -> Void) { self.dispatch = dispatch }

    /// The files on a Services pasteboard.
    static func files(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    func perform(_ action: QuickAction, _ pasteboard: NSPasteboard, _ error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let files = Self.files(on: pasteboard)
        guard !files.isEmpty else { error.pointee = "No files were selected."; return }
        let link = QuickActionLink(action, files: files)
        Task { @MainActor in dispatch(link) }
    }

    @objc func convertWithSuperConverter(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        perform(.convertWith, pasteboard, error)
    }
    @objc func convertToJPG(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        perform(.toJPG, pasteboard, error)
    }
    @objc func convertToPNG(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        perform(.toPNG, pasteboard, error)
    }
    @objc func convertToPDF(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        perform(.toPDF, pasteboard, error)
    }
    @objc func convertToMP4(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        perform(.toMP4, pasteboard, error)
    }
    @objc func convertToMP3(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        perform(.toMP3, pasteboard, error)
    }
}
