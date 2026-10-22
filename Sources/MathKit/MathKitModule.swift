import SuperConverterCore

/// MathKit: MathJax in JavaScriptCore to SVG paths (ARCHITECTURE §3). A engine: it carries no app policy and registers its converters in `install()`.
public enum MathKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
