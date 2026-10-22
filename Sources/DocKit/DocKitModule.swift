import SuperConverterCore

/// DocKit: DocModel readers and writers, and the WebKit print and snapshot engines (ARCHITECTURE §3). An engine: it carries no
/// app policy and registers its converters in `install()`. DocModel → PDF is TypesetKit's step (`Step(.typesetKit, .docModel,
/// "pdf")`); DocKit only produces and consumes the `DocModel` it takes.
public enum DocKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {
        for converter in DocKitConverters.all { Services.converters.register(converter) }
    }
}
