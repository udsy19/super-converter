// Links WebP.xcframework and round-trips pixels: lossless still (exact), lossy still with sharp YUV (size and rough
// colour), and a two-frame animation through the mux/demux libraries.
import Foundation
import WebP

func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok { fputs("FAIL: \(message())\n", stderr); exit(1) }
}

let width = 32, height = 24
var rgba = [UInt8](repeating: 255, count: width * height * 4)
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        rgba[i] = UInt8(x * 255 / (width - 1)); rgba[i + 1] = UInt8(y * 255 / (height - 1)); rgba[i + 2] = 96
    }
}

// Lossless still: byte-exact round trip.
var encoded: UnsafeMutablePointer<UInt8>? = nil
let encodedSize = WebPEncodeLosslessRGBA(rgba, Int32(width), Int32(height), Int32(width * 4), &encoded)
check(encodedSize > 0 && encoded != nil, "lossless encode")
var dw: Int32 = 0, dh: Int32 = 0
let decoded = WebPDecodeRGBA(encoded, encodedSize, &dw, &dh)
check(decoded != nil && Int(dw) == width && Int(dh) == height, "lossless decode size \(dw)x\(dh)")
check(memcmp(decoded, rgba, rgba.count) == 0, "lossless pixels differ")
WebPFree(decoded)
WebPFree(encoded)

// Lossy still with sharp YUV (libsharpyuv): decodes to the same size, colours near the original.
var config = WebPConfig()
check(WebPConfigInit(&config) != 0, "WebPConfigInit")
config.quality = 90
config.use_sharp_yuv = 1
var picture = WebPPicture()
check(WebPPictureInit(&picture) != 0, "WebPPictureInit")
picture.width = Int32(width); picture.height = Int32(height); picture.use_argb = 1
check(WebPPictureImportRGBA(&picture, rgba, Int32(width * 4)) != 0, "import")
var writer = WebPMemoryWriter()
WebPMemoryWriterInit(&writer)
picture.writer = WebPMemoryWrite
withUnsafeMutablePointer(to: &writer) { picture.custom_ptr = UnsafeMutableRawPointer($0) }
check(WebPEncode(&config, &picture) != 0, "lossy encode (error \(picture.error_code.rawValue))")
WebPPictureFree(&picture)
let lossy = WebPDecodeRGBA(writer.mem, writer.size, &dw, &dh)
check(lossy != nil && Int(dw) == width && Int(dh) == height, "lossy decode")
let mid = ((height / 2) * width + width / 2) * 4
check(abs(Int(lossy![mid]) - Int(rgba[mid])) < 24 && abs(Int(lossy![mid + 2]) - 96) < 24, "lossy colour drift")
WebPFree(lossy)
WebPMemoryWriterClear(&writer)

// Two-frame animation: assemble with the mux library, read back with the demux library.
var animOptions = WebPAnimEncoderOptions()
check(WebPAnimEncoderOptionsInit(&animOptions) != 0, "anim options")
let encoder = WebPAnimEncoderNew(Int32(width), Int32(height), &animOptions)
check(encoder != nil, "anim encoder")
var frameConfig = WebPConfig()
_ = WebPConfigInit(&frameConfig)
frameConfig.lossless = 1
for frame in 0..<2 {
    var pic = WebPPicture()
    _ = WebPPictureInit(&pic)
    pic.width = Int32(width); pic.height = Int32(height); pic.use_argb = 1
    var pixels = rgba
    for i in stride(from: 0, to: pixels.count, by: 4) where frame == 1 { pixels[i] = 255 - pixels[i] }
    check(WebPPictureImportRGBA(&pic, pixels, Int32(width * 4)) != 0, "frame import")
    check(WebPAnimEncoderAdd(encoder, &pic, Int32(frame * 100), &frameConfig) != 0, "frame add")
    WebPPictureFree(&pic)
}
check(WebPAnimEncoderAdd(encoder, nil, 200, nil) != 0, "anim flush")
var assembled = WebPData()
WebPDataInit(&assembled)
check(WebPAnimEncoderAssemble(encoder, &assembled) != 0, "anim assemble")
WebPAnimEncoderDelete(encoder)
var decoderOptions = WebPAnimDecoderOptions()
check(WebPAnimDecoderOptionsInit(&decoderOptions) != 0, "anim decoder options")
let animDecoder = WebPAnimDecoderNew(&assembled, &decoderOptions)
check(animDecoder != nil, "anim decoder")
var info = WebPAnimInfo()
check(WebPAnimDecoderGetInfo(animDecoder, &info) != 0, "anim info")
check(info.frame_count == 2 && Int(info.canvas_width) == width, "anim frames \(info.frame_count)")
var frames = 0
while WebPAnimDecoderHasMoreFrames(animDecoder) != 0 {
    var buffer: UnsafeMutablePointer<UInt8>? = nil
    var timestamp: Int32 = 0
    check(WebPAnimDecoderGetNext(animDecoder, &buffer, &timestamp) != 0, "anim frame")
    frames += 1
}
check(frames == 2, "decoded \(frames) frames")
WebPAnimDecoderDelete(animDecoder)
WebPDataClear(&assembled)

print("WebP \(String(WebPGetDecoderVersion(), radix: 16)): lossless exact, lossy+sharpyuv, 2-frame animation OK")
