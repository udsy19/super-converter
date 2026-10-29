import Foundation
import SuperConverterCore
#if canImport(AVIF)
import AVIF
#endif

/// AVIF through libavif + SVT-AV1 when this Mac's ImageIO cannot write AVIF (formats §3.2 `AVIFEncoder`): quality 80,
/// 10-bit for sources above 8 bits, speed 6; sRGB, Display P3 and BT.2020 as nclx code points, any other profile as ICC
/// (quality §2.2). The bundled SVT-AV1 encodes 4:2:0 only, so 4:4:4 and lossless need ImageIO's encoder.
enum AVIFWriter {
    static var isAvailable: Bool {
        #if canImport(AVIF)
        return true
        #else
        return false
        #endif
    }

    /// `rgba` holds RGBA samples scaled to `depth` (8 or 16 bits), straight alpha.
    static func encode(width: Int, height: Int, rgba: [UInt16], depth: Int, alpha: Bool, quality: Int, space: ColourSpace,
                       exif: Data?, xmp: Data?) throws -> Data {
        #if canImport(AVIF)
        guard let image = avifImageCreate(UInt32(width), UInt32(height), depth > 8 ? 10 : 8, AVIF_PIXEL_FORMAT_YUV420) else {
            throw ConversionError.failed("AVIF couldn’t start.")
        }
        defer { avifImageDestroy(image) }
        image.pointee.yuvRange = AVIF_RANGE_FULL
        if let known = KnownProfile.identify(space) {
            let n = known.nclx
            image.pointee.colorPrimaries = avifColorPrimaries(n.primaries)
            image.pointee.transferCharacteristics = avifTransferCharacteristics(n.transfer)
            image.pointee.matrixCoefficients = avifMatrixCoefficients(n.matrix)
        } else {
            image.pointee.colorPrimaries = avifColorPrimaries(2)          // unspecified: the ICC profile says it
            image.pointee.transferCharacteristics = avifTransferCharacteristics(2)
            image.pointee.matrixCoefficients = avifMatrixCoefficients(6)
            let status = space.icc.withUnsafeBytes { avifImageSetProfileICC(image, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
            guard status == AVIF_RESULT_OK else { throw ConversionError.failed("AVIF couldn’t keep the colour profile.") }
        }
        if let exif { _ = exif.withUnsafeBytes { avifImageSetMetadataExif(image, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) } }
        if let xmp { _ = xmp.withUnsafeBytes { avifImageSetMetadataXMP(image, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) } }

        var rgb = avifRGBImage()
        avifRGBImageSetDefaults(&rgb, image)
        rgb.depth = depth > 8 ? 16 : 8
        rgb.format = AVIF_RGB_FORMAT_RGBA
        rgb.ignoreAlpha = alpha ? AVIF_FALSE : AVIF_TRUE
        guard avifRGBImageAllocatePixels(&rgb) == AVIF_RESULT_OK else { throw ConversionError.failed("AVIF couldn’t start.") }
        defer { avifRGBImageFreePixels(&rgb) }
        for y in 0..<height {
            let row = rgb.pixels + y * Int(rgb.rowBytes)
            if depth > 8 {
                let p = UnsafeMutableRawPointer(row).assumingMemoryBound(to: UInt16.self)
                for x in 0..<(width * 4) { p[x] = rgba[y * width * 4 + x] }
            } else {
                for x in 0..<(width * 4) { row[x] = UInt8(rgba[y * width * 4 + x]) }
            }
        }
        guard avifImageRGBToYUV(image, &rgb) == AVIF_RESULT_OK else { throw ConversionError.failed("AVIF couldn’t convert the colours.") }

        guard let encoder = avifEncoderCreate() else { throw ConversionError.failed("AVIF couldn’t start.") }
        defer { avifEncoderDestroy(encoder) }
        encoder.pointee.codecChoice = AVIF_CODEC_CHOICE_SVT
        encoder.pointee.speed = 6
        encoder.pointee.quality = Int32(quality)
        encoder.pointee.qualityAlpha = Int32(max(quality, 90))
        encoder.pointee.maxThreads = Int32(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        var output = avifRWData()
        defer { avifRWDataFree(&output) }
        let result = avifEncoderWrite(encoder, image, &output)
        guard result == AVIF_RESULT_OK, let data = output.data else {
            throw ConversionError.failed("AVIF couldn’t encode the picture (\(String(cString: avifResultToString(result)))).")
        }
        return Data(bytes: data, count: output.size)
        #else
        throw ConversionError.failed("AVIF isn’t available in this build.")
        #endif
    }
}
