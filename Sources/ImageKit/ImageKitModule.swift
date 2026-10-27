import SuperConverterCore

/// ImageKit: Core Image / vImage / ColorSync pipeline, RAW development, encoders, PSB/XCF/PPM codecs, icon sets
/// (ARCHITECTURE §3). An engine: it carries no app policy and registers its converters in `install()`.
public enum ImageKitModule {
    /// Every converter ImageKit owns, one per engine id whose `EngineID.info.module` is ImageKit.
    public static var converters: [any Converter] {
        [ImageIOConverter(), ImagePipelineConverter(), CIRAWConverter(), LibRawConverter(), ImageCodecsConverter(),
         AVIFEncoderConverter(), WebPConverter()]
    }

    /// Registers this module's converters with `Services.converters` (ARCHITECTURE §9, launch step 2).
    @MainActor public static func install() {
        for converter in converters { Services.converters.register(converter) }
    }
}
