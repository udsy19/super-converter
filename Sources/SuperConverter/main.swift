import AppKit

// The app target (ARCHITECTURE §3, §9): launch sequence, module wiring, menus, Dock tile, Open With, Services, URL routes
// and `Services.updates`. WP-R fills it in; this skeleton installs the modules in the documented order and runs.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = AppDelegate()   // NSApplication holds its delegate weakly; `run()` keeps this scope alive
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
