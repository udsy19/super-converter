import AppKit

// The app target (ARCHITECTURE §3, §9): launch sequence, module wiring, menus, Dock, Open With, Services, URL routes and
// `Services.updates`. AppDelegate.swift holds the launch sequence and where opened files and links go,
// MainMenu.swift the menus.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()   // NSApplication holds its delegate weakly; `run()` keeps this scope alive
    application.delegate = delegate
    application.run()
}
