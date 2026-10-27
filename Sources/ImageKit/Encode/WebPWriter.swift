import Foundation
import SuperConverterCore
#if canImport(WebP)
import WebP
#endif

/// WebP through libwebp (formats §3.3, quality §2.3): photos lossy at quality 90 with sharp YUV and method 6, graphics
/// lossless (method 6, `exact` off); animations through the animation encoder; ICC, EXIF and XMP as RIFF chunks.
enum WebPWriter {
    struct Frame { var width: Int; var height: Int; var rgba: [UInt8]; var delay: TimeInterval? }

    static var isAvailable: Bool {
        #if canImport(WebP)
        return true
        #else
        return false
        #endif
    }

    static func encode(_ frames: [Frame], lossless: Bool, quality: Int, loopCount: Int, icc: Data?, exif: Data?, xmp: Data?) throws -> Data {
        #if canImport(WebP)
        guard let first = frames.first else { throw ConversionError.failed("There’s nothing to save.") }
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else { throw ConversionError.failed("WebP couldn’t start.") }
        config.method = 6
        if lossless {
            config.lossless = 1
            config.exact = 0
            config.quality = 75
        } else {
            config.quality = Float(quality)
            config.use_sharp_yuv = 1
        }
        var bitstream = frames.count == 1 ? try still(first, config: &config) : try animation(frames, config: config, loopCount: loopCount)
        if icc != nil || exif != nil || xmp != nil { bitstream = try addChunks(bitstream, icc: icc, exif: exif, xmp: xmp) }
        return bitstream
        #else
        throw ConversionError.failed("WebP isn’t available in this build.")
        #endif
    }

    #if canImport(WebP)
    private static func picture(_ frame: Frame) throws -> WebPPicture {
        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw ConversionError.failed("WebP couldn’t start.") }
        picture.width = Int32(frame.width); picture.height = Int32(frame.height); picture.use_argb = 1
        guard WebPPictureImportRGBA(&picture, frame.rgba, Int32(frame.width * 4)) != 0 else {
            WebPPictureFree(&picture)
            throw ConversionError.failed("The picture is too large for WebP.")
        }
        return picture
    }

    private static func still(_ frame: Frame, config: inout WebPConfig) throws -> Data {
        var picture = try picture(frame)
        defer { WebPPictureFree(&picture) }
        var writer = WebPMemoryWriter()
        WebPMemoryWriterInit(&writer)
        defer { WebPMemoryWriterClear(&writer) }
        picture.writer = WebPMemoryWrite
        let ok = withUnsafeMutablePointer(to: &writer) { pointer -> Int32 in
            picture.custom_ptr = UnsafeMutableRawPointer(pointer)
            return WebPEncode(&config, &picture)
        }
        guard ok != 0, let mem = writer.mem else { throw ConversionError.failed("WebP couldn’t encode the picture (\(picture.error_code.rawValue)).") }
        return Data(bytes: mem, count: writer.size)
    }

    private static func animation(_ frames: [Frame], config: WebPConfig, loopCount: Int) throws -> Data {
        var options = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&options) != 0 else { throw ConversionError.failed("WebP couldn’t start.") }
        options.anim_params.loop_count = Int32(loopCount)
        guard let encoder = WebPAnimEncoderNew(Int32(frames[0].width), Int32(frames[0].height), &options) else {
            throw ConversionError.failed("WebP couldn’t start.")
        }
        defer { WebPAnimEncoderDelete(encoder) }
        var config = config
        var timestamp = 0.0
        for frame in frames {
            var picture = try picture(frame)
            defer { WebPPictureFree(&picture) }
            guard WebPAnimEncoderAdd(encoder, &picture, Int32((timestamp * 1000).rounded()), &config) != 0 else {
                throw ConversionError.failed("WebP couldn’t encode a frame.")
            }
            timestamp += frame.delay ?? 0.1
        }
        guard WebPAnimEncoderAdd(encoder, nil, Int32((timestamp * 1000).rounded()), nil) != 0 else { throw ConversionError.failed("WebP couldn’t finish.") }
        var data = WebPData()
        WebPDataInit(&data)
        defer { WebPDataClear(&data) }
        guard WebPAnimEncoderAssemble(encoder, &data) != 0, let bytes = data.bytes else { throw ConversionError.failed("WebP couldn’t finish.") }
        return Data(bytes: bytes, count: data.size)
    }

    private static func addChunks(_ bitstream: Data, icc: Data?, exif: Data?, xmp: Data?) throws -> Data {
        try bitstream.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            var input = WebPData(bytes: raw.bindMemory(to: UInt8.self).baseAddress, size: raw.count)
            guard let mux = WebPMuxCreate(&input, 1) else { throw ConversionError.failed("WebP couldn’t add the colour profile.") }
            defer { WebPMuxDelete(mux) }
            for (fourcc, payload) in [("ICCP", icc), ("EXIF", exif), ("XMP ", xmp)] {
                guard let payload else { continue }
                let status = payload.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> WebPMuxError in
                    var chunk = WebPData(bytes: p.bindMemory(to: UInt8.self).baseAddress, size: p.count)
                    return WebPMuxSetChunk(mux, fourcc, &chunk, 1)
                }
                guard status == WEBP_MUX_OK else { throw ConversionError.failed("WebP couldn’t add the photo details.") }
            }
            var output = WebPData()
            WebPDataInit(&output)
            defer { WebPDataClear(&output) }
            guard WebPMuxAssemble(mux, &output) == WEBP_MUX_OK, let bytes = output.bytes else { throw ConversionError.failed("WebP couldn’t finish.") }
            return Data(bytes: bytes, count: output.size)
        }
    }
    #endif
}
