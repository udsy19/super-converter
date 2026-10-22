import AppKit
import SuperConverterCore

/// Everything the window does to the outside world, behind one seam so tests inject a recorder and never open an app, a
/// URL or a panel (self-test rules). The default implementation is the real thing.
@MainActor
protocol FileActions: AnyObject {
    func reveal(_ urls: [URL])
    func open(_ url: URL)
    func quickLook(_ urls: [URL])
    /// The file chooser (`⌘O`, Choose Files…), filtered to a source format when a popular pair asked for it.
    func chooseFiles(filter: FormatID?) -> [URL]
    func chooseFolder() -> URL?
    /// "Get…" for helpers that are not one-click (vendor page, App Store, Homebrew, build from source).
    func get(_ helper: HelperID)
    /// "Include subfolders?" for a dropped folder with more than 200 files inside.
    func includeSubfolders(folder: String, fileCount: Int) -> Bool
    func confirmStop(count: Int) -> Bool
    /// "Enter Password…" for a protected source; nil when cancelled.
    func askPassword(for name: String) -> String?
}

@MainActor
final class SystemFileActions: NSObject, FileActions {
    func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func quickLook(_ urls: [URL]) { QuickLook.shared.show(urls) }

    func chooseFiles(filter: FormatID?) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if let filter, let format = FormatCatalog.format(filter) {
            let types = format.utTypes
            if !types.isEmpty { panel.allowedContentTypes = types }
        }
        return panel.runModal() == .OK ? panel.urls : []
    }

    func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func get(_ helper: HelperID) {
        let info = HelperCatalog.info(helper)
        switch info.install {
        case .oneClick(let page), .vendorPage(let page), .appStore(let page):
            NSWorkspace.shared.open(page)
        case .homebrew(let formula):
            explain("Install \(info.name) with Homebrew", "Run “brew install \(formula)” in Terminal, then choose Look again in Settings › Helpers.")
        case .buildFromSource(let project):
            explain("Build \(info.name) from source", "It is built from \(project.absoluteString). Once it is installed, choose Look again in Settings › Helpers.")
        case .detectOnly:
            explain("\(info.name) is detected, not installed", "Install \(info.name) from its vendor and Super Converter will use it.")
        }
    }

    private func explain(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    func includeSubfolders(folder: String, fileCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Include subfolders?"
        alert.informativeText = "\(Strings.quoted(folder)) holds \(fileCount) files in its subfolders."
        alert.addButton(withTitle: "Include Subfolders")
        alert.addButton(withTitle: "Top Level Only")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func askPassword(for name: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Enter the password for \(Strings.quoted(name))"
        alert.informativeText = "The password is used for this conversion only."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn && !field.stringValue.isEmpty ? field.stringValue : nil
    }

    func confirmStop(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop converting \(Formatting.count(count, "file", "files"))?"
        alert.informativeText = "Files that are not finished are deleted; the originals are not touched."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Keep Converting")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
