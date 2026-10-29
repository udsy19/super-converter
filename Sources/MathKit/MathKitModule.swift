import SuperConverterCore

/// MathKit: TeX math through MathJax in JavaScriptCore → vector paths (ARCHITECTURE §3, quality §3.4).
/// A library engine for TypesetKit: it has no route of its own in the format matrix, so it registers no converters.
public enum MathKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2): none.
    @MainActor public static func install() {}
}
