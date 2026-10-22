import SuperConverterCore

/// FontKit: SFNT, CFF, WOFF, WOFF2, EOT and SVG-font readers and writers (ARCHITECTURE §3). A engine: it carries no app policy and registers its converters in `install()`.
public enum FontKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
