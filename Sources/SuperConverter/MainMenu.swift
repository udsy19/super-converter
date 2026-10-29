import AppKit
import SuperConverterCore

/// The main menu with ux §6.5's shortcuts. Every item sends its action up the responder chain: the window's commands reach
/// WindowKit's `MainWindowController` while its window is key, app commands end at `AppDelegate`, and the rest are
/// AppKit's own (text editing in the search field, window commands). Space, ⌫, T, ⌥⌘O and the arrows belong to the cards.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        let app = NSMenu(title: Strings.appName)
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        add(app, [
            item("About \(Strings.appName)", "showAbout:"),
            item("Check for Updates…", "checkForUpdates:"),
            .separator(),
            item("Settings…", "showSettings:", ","),
            .separator(),
            submenu(services),
            .separator(),
            item("Hide \(Strings.appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit \(Strings.appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let file = NSMenu(title: "File")
        add(file, [
            item("Add Files…", "addFiles:", "o"),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w"),
        ])
        let edit = NSMenu(title: "Edit")
        add(edit, [
            item("Undo", "undo:", "z"),
            item("Redo", "redo:", "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let convert = NSMenu(title: "Convert")
        add(convert, [
            item("Convert", "convertAll:", "\r"),
            item("Stop", "stopConverting:", "."),
            .separator(),
            item("Show Results in Finder", "revealResults:", "r", [.command, .shift]),
        ])
        let view = NSMenu(title: "View")
        add(view, [
            item("as Grid", "showGridView:", "1"),
            item("as List", "showListView:", "2"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let window = NSMenu(title: "Window")
        NSApp.windowsMenu = window
        add(window, [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item(Strings.appName, "showMainWindow:"),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        let help = NSMenu(title: "Help")
        NSApp.helpMenu = help
        add(help, [item("\(Strings.appName) Help", "showHelp:")])
        add(main, [app, file, edit, convert, view, window, help].map(submenu))
        return main
    }

    private static func add(_ menu: NSMenu, _ items: [NSMenuItem]) {
        for item in items { menu.addItem(item) }
    }

    private static func item(_ title: String, _ action: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        item(title, Selector(action), key, modifiers)
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
