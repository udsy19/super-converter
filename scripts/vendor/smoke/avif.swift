// Links AVIF.xcframework and round-trips an image with the two bundled codecs: SVT-AV1 encodes, dav1d decodes.
import Foundation
import AVIF

func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok { fputs("FAIL: \(message())\n", stderr); exit(1) }
}

check(avifCodecName(AVIF_CODEC_CHOICE_SVT, avifCodecFlags(AVIF_CODEC_FLAG_CAN_ENCODE.rawValue)) != nil, "SVT-AV1 encoder missing")
check(avifCodecName(AVIF_CODEC_CHOICE_DAV1D, avifCodecFlags(AVIF_CODEC_FLAG_CAN_DECODE.rawValue)) != nil, "dav1d decoder missing")

let width: UInt32 = 64, height: UInt32 = 48
var source = avifRGBImage()
let image = avifImageCreate(width, height, 8, AVIF_PIXEL_FORMAT_YUV420)!
avifRGBImageSetDefaults(&source, image)
source.format = AVIF_RGB_FORMAT_RGBA
check(avifRGBImageAllocatePixels(&source) == AVIF_RESULT_OK, "allocate")
for y in 0..<Int(height) {
    for x in 0..<Int(width) {
        let p = source.pixels + y * Int(source.rowBytes) + x * 4
        p[0] = UInt8(x * 255 / Int(width - 1)); p[1] = UInt8(y * 255 / Int(height - 1)); p[2] = 128; p[3] = 255
    }
}
check(avifImageRGBToYUV(image, &source) == AVIF_RESULT_OK, "RGB to YUV")

let encoder = avifEncoderCreate()!
encoder.pointee.codecChoice = AVIF_CODEC_CHOICE_SVT
encoder.pointee.speed = 10
encoder.pointee.quality = 90
encoder.pointee.qualityAlpha = 90
check(avifEncoderAddImage(encoder, image, 1, avifAddImageFlags(AVIF_ADD_IMAGE_FLAG_SINGLE.rawValue)) == AVIF_RESULT_OK, "add image")
var output = avifRWData()
let finish = avifEncoderFinish(encoder, &output)
check(finish == AVIF_RESULT_OK, "SVT-AV1 encode: \(String(cString: avifResultToString(finish)))")
check(output.size > 100 && output.size < 20_000, "AVIF size \(output.size)")

let decoder = avifDecoderCreate()!
decoder.pointee.codecChoice = AVIF_CODEC_CHOICE_DAV1D
check(avifDecoderSetIOMemory(decoder, output.data, output.size) == AVIF_RESULT_OK, "io")
check(avifDecoderParse(decoder) == AVIF_RESULT_OK, "parse")
check(avifDecoderNextImage(decoder) == AVIF_RESULT_OK, "dav1d decode")
check(decoder.pointee.image.pointee.width == width && decoder.pointee.image.pointee.height == height, "decoded size")
var decoded = avifRGBImage()
avifRGBImageSetDefaults(&decoded, decoder.pointee.image)
decoded.format = AVIF_RGB_FORMAT_RGBA
check(avifRGBImageAllocatePixels(&decoded) == AVIF_RESULT_OK, "allocate decoded")
check(avifImageYUVToRGB(decoder.pointee.image, &decoded) == AVIF_RESULT_OK, "YUV to RGB")
var squared = 0.0
for y in 0..<Int(height) {
    for x in 0..<Int(width) {
        for c in 0..<3 {
            let d = Double(source.pixels[y * Int(source.rowBytes) + x * 4 + c]) - Double(decoded.pixels[y * Int(decoded.rowBytes) + x * 4 + c])
            squared += d * d
        }
    }
}
let psnr = 10 * log10(255.0 * 255.0 / (squared / Double(width * height * 3)))
check(psnr > 30, "PSNR \(psnr) dB")
var versions = [CChar](repeating: 0, count: 256)
avifCodecVersions(&versions)
print("libavif \(String(cString: avifVersion())) (\(String(cString: versions))): SVT-AV1 encode, dav1d decode, \(output.size) bytes, PSNR \(Int(psnr)) dB OK")
avifRGBImageFreePixels(&source); avifRGBImageFreePixels(&decoded)
avifImageDestroy(image); avifEncoderDestroy(encoder); avifDecoderDestroy(decoder); avifRWDataFree(&output)
