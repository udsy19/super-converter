import SuperConverterCore

/// TypesetKit: DocModel, Workbook and Publication to PDF with the LaTeX look (ARCHITECTURE §3). An engine: it carries no
/// app policy and registers its converter in `install()`.
public enum TypesetKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {
        Services.converters.register(TypesetConverter(fonts: FontLibrary.bundled()))
    }
}
