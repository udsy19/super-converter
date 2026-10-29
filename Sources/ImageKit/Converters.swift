import Foundation
import SuperConverterCore

// ImageKit's converters, one per engine id it owns (`EngineID.info.module == .imageKit`), covering every step of the
// image routes in formats §6.2 and the image ends of other categories' routes.

private func requireFile(_ input: StepValue, _ step: Step) throws -> URL {
    guard case .file(let url) = input else { throw ConversionError.failed("Expected a file for \(step).") }
    return url
}

private func requireImage(_ input: StepValue, _ step: Step) throws -> ImageAsset {
    guard case .image(let asset) = input else { throw ConversionError.failed("Expected a picture for \(step).") }
    return asset
}

private func format(_ endpoint: StepEndpoint) -> FormatID? {
    if case .format(let f) = endpoint { return f }
    return nil
}

/// Writes the step's target with ImageKit's writers.
private func encode(_ asset: ImageAsset, step: Step, context: StepContext) throws -> StepOutput {
    guard let target = format(step.to) else { throw ConversionError.failed("No target format for \(step).") }
    if context.isCancelled() { throw ConversionError.cancelled }
    let url = try ImageWriter(kind: TargetKind(target), format: target, settings: ImageSettings(context.options), context: context).write(asset)
    return StepOutput(.file(url))
}

/// `ImageIO`: decoding every ImageIO format into an `ImageAsset`, and writing JPEG, PNG, TIFF, HEIC, GIF, BMP, PSD, ICO
/// and ICNS (some through ImageKit's own writers where ImageIO falls short: `BitmapWriters`, `GIFEncoder`, `PSDCodec`).
struct ImageIOConverter: Converter {
    static let readable: Set<FormatID> = ["avif", "bmp", "gif", "heic", "heif", "icns", "ico", "jfif", "jpeg", "jpg", "png", "ppm",
                                          "psd", "tga", "tif", "tiff", "webp"]
    static let writable: Set<FormatID> = ["bmp", "gif", "heic", "heif", "icns", "ico", "jpg", "jpeg", "jfif", "png", "psd", "tiff", "tif"]

    var id: EngineID { .imageIO }
    var handles: [StepPattern] {
        [StepPattern(from: .formats(Self.readable), to: .model(.imageAsset)),
         StepPattern(from: .model(.imageAsset), to: .formats(Self.writable))]
    }

    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        guard step.to == .imageAsset else { return try encode(try requireImage(input, step), step: step, context: context) }
        let url = try requireFile(input, step)
        let sourceFormat = format(step.from) ?? context.sourceFormat
        let asset = try ImageIODecoder.decode(url, format: sourceFormat, settings: ImageSettings(context.options),
                                              workFolder: context.workFolder, isCancelled: context.isCancelled)
        var notes: [LossNote] = []
        if sourceFormat == "psd", let layers = PSDCodec.layerCount(url), layers > 1 { notes.append(LossNote(.layersFlattened)) }
        return StepOutput(.image(asset), lossNotes: notes)
    }
}

/// `ImagePipeline`: the pixel work between decode and encode (quality §2.1–§2.4).
struct ImagePipelineConverter: Converter {
    var id: EngineID { .imagePipeline }
    var handles: [StepPattern] { [StepPattern(from: .model(.imageAsset), to: .model(.imageAsset))] }
    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let pipeline = ImagePipeline(settings: ImageSettings(context.options), traits: TargetTraits(context.targetFormat),
                                     sourceFormat: context.sourceFormat, workFolder: context.workFolder, isCancelled: context.isCancelled)
        let (out, notes) = try pipeline.run(try requireImage(input, step))
        return StepOutput(.image(out), lossNotes: notes)
    }
}

/// `CIRAWFilter`: camera RAW development (quality §2.5).
struct CIRAWConverter: Converter {
    static let formats: Set<FormatID> = ["3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "mos", "mrw", "nef", "orf", "pef",
                                         "raf", "raw", "rw2"]
    var id: EngineID { .ciRAWFilter }
    var handles: [StepPattern] { [StepPattern(from: .formats(Self.formats), to: .model(.imageAsset))] }
    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let asset = try RAWDeveloper.develop(try requireFile(input, step), format: format(step.from) ?? context.sourceFormat,
                                             settings: ImageSettings(context.options), target: TargetTraits(context.targetFormat),
                                             workFolder: context.workFolder)
        return StepOutput(.image(asset))
    }
}

/// `LibRaw`: Sigma X3F (formats §3.3).
struct LibRawConverter: Converter {
    var id: EngineID { .libRaw }
    var handles: [StepPattern] { [StepPattern(from: .formats(["x3f"]), to: .model(.imageAsset))] }
    func availability() -> EngineAvailability {
        LibRawDeveloper.isAvailable ? .available : .unavailable("Sigma RAW support isn’t included in this copy of the app.")
    }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let asset = try LibRawDeveloper.develop(try requireFile(input, step), format: "x3f", settings: ImageSettings(context.options),
                                                target: TargetTraits(context.targetFormat), workFolder: context.workFolder)
        return StepOutput(.image(asset))
    }
}

/// `ImageCodecs`: own decoders for PSB and GIMP XCF (formats §3.2).
struct ImageCodecsConverter: Converter {
    var id: EngineID { .imageCodecs }
    var handles: [StepPattern] { [StepPattern(from: .formats(["psb", "xcf"]), to: .model(.imageAsset))] }
    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let data = try Data(contentsOf: try requireFile(input, step), options: .mappedIfSafe)
        let raster: Raster, dpi: Double, layers: Int
        var xmp: Data?
        if format(step.from) == "xcf" {
            let decoded = try XCFDecoder.decode(data)
            (raster, dpi, layers) = (decoded.raster, decoded.dpi, decoded.visibleLayers)
        } else {
            let decoded = try PSDCodec.decode(data)
            (raster, dpi, layers, xmp) = (decoded.raster, decoded.dpi, decoded.layerCount, decoded.xmp)
        }
        let frame = try FrameIO.frame(from: raster, depth: raster.sourceDepth, folder: context.workFolder)
        let metadata = ImageMetadata(exif: Metadata.plist(["DPIWidth": dpi, "DPIHeight": dpi]), xmp: xmp)
        return StepOutput(.image(ImageAsset(frames: [frame], metadata: metadata)), lossNotes: layers > 1 ? [LossNote(.layersFlattened)] : [])
    }
}

/// `AVIFEncoder`: ImageIO when this Mac writes AVIF, else libavif + SVT-AV1 (formats §3.2).
struct AVIFEncoderConverter: Converter {
    var id: EngineID { .avifEncoder }
    var handles: [StepPattern] { [StepPattern(from: .model(.imageAsset), to: .formats(["avif"]))] }
    func availability() -> EngineAvailability {
        ImageIOSupport.writesAVIF || AVIFWriter.isAvailable ? .available : .unavailable("AVIF can’t be written on this Mac.")
    }
    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        try encode(try requireImage(input, step), step: step, context: context)
    }
}

/// `libwebp`: WebP stills and animations (formats §3.3).
struct WebPConverter: Converter {
    var id: EngineID { .libwebp }
    var handles: [StepPattern] { [StepPattern(from: .model(.imageAsset), to: .formats(["webp"]))] }
    func availability() -> EngineAvailability {
        WebPWriter.isAvailable ? .available : .unavailable("WebP support isn’t included in this copy of the app.")
    }
    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        try encode(try requireImage(input, step), step: step, context: context)
    }
}
