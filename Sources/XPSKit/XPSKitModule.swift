import SuperConverterCore
import VectorKit

/// XPSKit: XPS, OpenXPS and DWFx reader, XPS writer (ARCHITECTURE §3). An engine: it carries no app policy and registers its converters in `install()`.
public enum XPSKitModule {
    static let converters: [VectorConverter] = [
        ConverterSupport.reader(.xpsKit, from: ["xps", "oxps", "dwfx"]) { url in try XPSReader.read(url) },
        ConverterSupport.writer(.xpsWriter, to: "xps", singlePage: false) { doc, options in try XPSWriter.write(doc, options: options) },
    ]

    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {
        for converter in converters { Services.converters.register(converter) }
    }
}
