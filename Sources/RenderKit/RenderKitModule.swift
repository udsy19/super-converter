import SuperConverterCore

/// RenderKit: PDF page rasterising, vector rasterising, PDF/A writer and verifier, ColorSync output (copied from Super PDF)
/// (ARCHITECTURE §3). An engine: it carries no app policy and registers its converters in `install()`.
public enum RenderKitModule {
    public static func converters() -> [any Converter] { [RenderKitConverter()] }

    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {
        for converter in converters() { Services.converters.register(converter) }
    }
}
