import SuperConverterCore

/// UpdateKit: GitHub Releases updater (copied from Super Flow) (ARCHITECTURE §3). A engine: it carries no app policy and registers its converters in `install()`.
public enum UpdateKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
