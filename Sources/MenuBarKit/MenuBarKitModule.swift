import SuperConverterCore

/// MenuBarKit: the status item, drop target and panel (ux §5.9) (ARCHITECTURE §3). A feature module: it talks to the others through `Services`.
public enum MenuBarKitModule {
    /// Assigns this module's services in `Services` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
