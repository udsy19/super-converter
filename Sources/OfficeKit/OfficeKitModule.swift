import SuperConverterCore

/// OfficeKit: Workbook, Deck, ODF drawing pictures, Zip/XML/OOXML support (ARCHITECTURE §3). An engine: it carries no app policy and registers its converters in `install()`.
public enum OfficeKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {
        for converter in OfficeConverters.all { Services.converters.register(converter) }
    }
}
