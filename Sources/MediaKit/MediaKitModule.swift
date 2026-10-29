import SuperConverterCore

/// MediaKit: probing, AVFoundation pipelines, the FFmpeg adapter, animation, the SoundFont reader (ARCHITECTURE §3). An engine:
/// it carries no app policy and registers its converters in `install()`.
public enum MediaKitModule {
    /// The converters for AVFoundation, FFmpeg and SoundFontReader. `tools` runs the bundled `ffmpeg`/`ffprobe` (HelperKit's
    /// `Services.tools`); without it the FFmpeg engine reports itself unavailable and AVFoundation works alone.
    public static func converters(tools: (any ToolRunning)?) -> [any Converter] {
        let media = MediaTools(runner: tools)
        return [AVFoundationConverter(tools: media), FFmpegConverter(tools: media), SoundFontConverter(tools: media)]
    }

    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2: after HelperKit).
    @MainActor public static func install() {
        for converter in converters(tools: Services.tools) { Services.converters.register(converter) }
    }
}
