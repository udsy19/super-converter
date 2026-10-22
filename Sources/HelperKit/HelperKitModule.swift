import SuperConverterCore

/// HelperKit: helper catalog runtime, detection, one-click installer, process runner, app automation (ARCHITECTURE §3). A engine: it carries no app policy and registers its converters in `install()`.
public enum HelperKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
