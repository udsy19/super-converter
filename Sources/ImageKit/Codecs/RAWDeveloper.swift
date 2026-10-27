import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SuperConverterCore
#if canImport(LibRaw)
import LibRaw
#endif

/// Camera RAW (quality §2.5): `CIRAWFilter` with Apple's defaults (the look of Photos) — lens correction on, as-shot
/// white balance, boost 1 for "Apple" and 0 for "Neutral", noise reduction as tuned per camera — developed straight into
/// the target space (quality §2.2): Display P3 for HEIC, AVIF and 16-bit targets, sRGB for 8-bit ones, ProPhoto RGB or
/// any other profile when the person chose it. Output is 16-bit; the pipeline dithers it once for 8-bit targets.
enum RAWDeveloper {
    /// The space a RAW file is developed into for this target.
    static func developmentSpace(settings: ImageSettings, target: TargetTraits) -> ColourSpace {
        switch settings.profile {
        case .srgb: return .sRGB
        case .displayP3: return .displayP3
        case .adobeRGB: return .adobeRGB
        case .proPhoto: return .proPhoto
        case .custom(let url): if let icc = try? Data(contentsOf: url), let s = ColourSpace(icc: icc), s.model == .rgb { return s }
        default: break
        }
        if !target.holdsICC { return .sRGB }
        switch target.kind {
        case .heic, .avif: return .displayP3
        default: return target.maxDepth > 8 ? .displayP3 : .sRGB
        }
    }

    static func develop(_ url: URL, format: FormatID, settings: ImageSettings, target: TargetTraits, workFolder: URL) throws -> ImageAsset {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw ConversionError.failed("This camera’s RAW files can’t be read on this Mac.")
        }
        filter.boostAmount = settings.neutralLook ? 0 : 1
        if filter.isLensCorrectionSupported { filter.isLensCorrectionEnabled = settings.lensCorrection }
        filter.exposure = Float(settings.exposure)
        if case .kelvin(let k) = settings.whiteBalance { filter.neutralTemperature = Float(k) }
        if !settings.noiseReductionAuto {
            if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = 0 }
            if filter.isColorNoiseReductionSupported { filter.colorNoiseReductionAmount = 0 }
        }
        guard let image = filter.outputImage else { throw ConversionError.damaged(format) }
        let space = developmentSpace(settings: settings, target: target)
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        guard let cg = context.createCGImage(image, from: image.extent.integral, format: .RGBA16, colorSpace: space.cg),
              var raster = Raster(cgImage: cg, space: space) else { throw ConversionError.damaged(format) }
        raster.removeAlpha()
        var frame = try FrameIO.frame(from: raster, depth: 16, folder: workFolder)
        frame.orientation = 1   // CIRAWFilter applies the RAW's own orientation
        let metadata = CGImageSourceCreateWithURL(url as CFURL, nil).map { Metadata.capture($0, index: 0) } ?? ImageMetadata()
        return ImageAsset(frames: [frame], metadata: metadata)
    }
}

/// Sigma X3F through LibRaw with the X3F tools (formats §3.3; `libraw_r.dylib`, LGPL, dynamic): camera white balance,
/// 16-bit linear ProPhoto out of LibRaw, then ColorSync into the development space.
enum LibRawDeveloper {
    static var isAvailable: Bool {
        #if canImport(LibRaw)
        return libraw_capabilities() & LIBRAW_CAPS_X3FTOOLS.rawValue != 0
        #else
        return false
        #endif
    }

    static func develop(_ url: URL, format: FormatID, settings: ImageSettings, target: TargetTraits, workFolder: URL) throws -> ImageAsset {
        #if canImport(LibRaw)
        guard let processor = libraw_init(0) else { throw ConversionError.failed("The RAW decoder couldn’t start.") }
        defer { libraw_close(processor) }
        guard libraw_open_file(processor, url.path) == LIBRAW_SUCCESS.rawValue,
              libraw_unpack(processor) == LIBRAW_SUCCESS.rawValue else { throw ConversionError.damaged(format) }
        processor.pointee.params.use_camera_wb = 1
        processor.pointee.params.output_color = 4   // ProPhoto RGB primaries
        processor.pointee.params.output_bps = 16
        processor.pointee.params.gamm.0 = 1           // linear: labelled exactly below
        processor.pointee.params.gamm.1 = 1
        if settings.exposure != 0 {
            processor.pointee.params.exp_correc = 1
            processor.pointee.params.exp_shift = Float(pow(2, settings.exposure))
        }
        guard libraw_dcraw_process(processor) == LIBRAW_SUCCESS.rawValue else { throw ConversionError.damaged(format) }
        var status: Int32 = 0
        guard let processed = libraw_dcraw_make_mem_image(processor, &status), status == 0 else { throw ConversionError.damaged(format) }
        defer { libraw_dcraw_clear_mem(processed) }
        let w = Int(processed.pointee.width), h = Int(processed.pointee.height), colours = Int(processed.pointee.colors)
        guard processed.pointee.bits == 16, colours == 3 || colours == 1 else { throw ConversionError.damaged(format) }
        var values = [Float](repeating: 0, count: w * h * 3)
        withUnsafePointer(to: &processed.pointee.data) { start in
            let samples = UnsafeRawPointer(start).assumingMemoryBound(to: UInt16.self)
            for i in 0..<(w * h) {
                for c in 0..<3 { values[i * 3 + c] = Float(samples[i * colours + (colours == 1 ? 0 : c)]) / 65535 }
            }
        }
        guard let linearProPhoto = ColourSpace.proPhoto.linear else { throw ConversionError.failed("The colours couldn’t be converted.") }
        let space = RAWDeveloper.developmentSpace(settings: settings, target: target)
        guard let converted = ColourTransform.convert(values, pixelCount: w * h, from: linearProPhoto, to: space, intent: .perceptual) else {
            throw ConversionError.failed("The colours couldn’t be converted.")
        }
        var raster = Raster(width: w, height: h, space: space, hasAlpha: false, data: converted, sourceDepth: 16)
        raster.clamp()
        let frame = try FrameIO.frame(from: raster, depth: 16, folder: workFolder)
        let metadata = CGImageSourceCreateWithURL(url as CFURL, nil).map { Metadata.capture($0, index: 0) } ?? ImageMetadata()
        return ImageAsset(frames: [frame], metadata: metadata)
        #else
        throw ConversionError.failed("Sigma RAW isn’t available in this build.")
        #endif
    }
}
