import SuperConverterCore

/// SettingsKit: the Settings window panes (ux §5.11) (ARCHITECTURE §3). A feature module: it talks to the others through `Services`.
public enum SettingsKitModule {
    /// Assigns this module's services in `Services` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
