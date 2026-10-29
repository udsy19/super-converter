import SuperConverterCore

/// ArchiveKit: ArchiveTree over libarchive and 7zz, own decoders, extraction safety (ARCHITECTURE §3). An engine: it carries
/// no app policy and registers its converters in `install()`.
public enum ArchiveKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2). HelperKit installs
    /// first and leaves its runner in `Services.tools`, through which 7zz and hdiutil run (ARCHITECTURE §7).
    @MainActor public static func install() {
        let tools: (any ToolRunning)? = Services.tools
        for engine in ArchiveConverter.engines { Services.converters.register(ArchiveConverter(engine, tools: tools)) }
    }
}
