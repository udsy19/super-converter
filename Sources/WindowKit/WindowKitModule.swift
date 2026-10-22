import SuperConverterCore

/// WindowKit: the main window (ux §4–§5.8) (ARCHITECTURE §3). A feature module: it talks to the others through `Services`.
public enum WindowKitModule {
    /// Assigns this module's services in `Services` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {
        Services.window = MainWindowController()
    }
}
