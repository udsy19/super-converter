import SuperConverterCore

/// ImageKit: Core Image / vImage / ColorSync pipeline, RAW development, encoders, PSB/XCF/PPM codecs, icon sets (ARCHITECTURE §3). A engine: it carries no app policy and registers its converters in `install()`.
public enum ImageKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
