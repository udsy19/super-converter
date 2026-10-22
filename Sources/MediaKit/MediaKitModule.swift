import SuperConverterCore

/// MediaKit: probing, AVFoundation pipelines, the FFmpeg adapter, animation, the SoundFont reader (ARCHITECTURE §3). A engine: it carries no app policy and registers its converters in `install()`.
public enum MediaKitModule {
    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {}
}
