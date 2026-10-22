import SuperConverterCore

/// LayoutKit: PDF to LayoutDocument, DocModel, Workbook, Deck, Publication and text (copied from Super PDF) (ARCHITECTURE §3).
/// An engine: it carries no app policy and registers its converters in `install()`.
public enum LayoutKitModule {
    public static func converters() -> [any Converter] { [LayoutKitConverter()] }

    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {
        for converter in converters() { Services.converters.register(converter) }
    }
}
