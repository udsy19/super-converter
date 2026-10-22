import SuperConverterCore

/// ArchiveKit: ArchiveTree over libarchive and 7zz, own decoders, extraction safety (ARCHITECTURE §3). A engine: it carries no app policy and registers its converters in `install()`.
public enum ArchiveKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
