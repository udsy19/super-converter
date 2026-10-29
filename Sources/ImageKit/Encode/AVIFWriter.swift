import Foundation
import SuperConverterCore
#if canImport(AVIF)
import AVIF
#endif

/// AVIF through libavif (formats §3.2 `AVIFEncoder`, §3.3): lossy pictures when this Mac's ImageIO cannot write AVIF, with
/// SVT-AV1 at quality 80, 10-bit for sources above 8 bits, speed 6; lossless pictures always (ImageIO refuses quality 1.0),
/// with libaom, since the bundled SVT-AV1 encodes 4:2:0 only: 8-bit 4:4:4 with the identity matrix, so the decoded RGB
/// samples are the source's bit for bit (quality §2.8). sRGB, Display P3 and BT.2020 as nclx code points, any other
/// profile as ICC (quality §2.2).
enum AVIFWriter {
    static var isAvailable: Bool {
        #if canImport(AVIF)
        return true
        #else
        return false
        #endif
    }

    /// `rgba` holds RGBA samples scaled to `depth` (8 or 16 bits), straight alpha.
    /// `lossless` needs 8-bit samples (`depth` 8); `quality` is then ignored.
    static func encode(width: Int, height: Int, rgba: [UInt16], depth: Int, alpha: Bool, quality: Int, lossless: Bool,
                       space: ColourSpace, exif: Data?, xmp: Data?) throws -> Data {
        #if canImport(AVIF)
        let format = lossless ? AVIF_PIXEL_FORMAT_YUV444 : AVIF_PIXEL_FORMAT_YUV420
        guard let image = avifImageCreate(UInt32(width), UInt32(height), depth > 8 ? 10 : 8, format) else {
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
        // Identity (GBR) instead of a YCbCr matrix: lossless AV1 then carries the RGB samples themselves.
        if lossless { image.pointee.matrixCoefficients = avifMatrixCoefficients(AVIF_MATRIX_COEFFICIENTS_IDENTITY) }
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
        encoder.pointee.codecChoice = lossless ? AVIF_CODEC_CHOICE_AOM : AVIF_CODEC_CHOICE_SVT
        encoder.pointee.speed = 6
        encoder.pointee.quality = lossless ? Int32(AVIF_QUALITY_LOSSLESS) : Int32(quality)
        encoder.pointee.qualityAlpha = lossless ? Int32(AVIF_QUALITY_LOSSLESS) : Int32(max(quality, 90))
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
