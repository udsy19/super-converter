import SuperConverterCore

/// XPSKit: XPS, OpenXPS and DWFx reader, XPS writer (ARCHITECTURE §3). A engine: it carries no app policy and registers its converters in `install()`.
public enum XPSKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
