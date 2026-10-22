// Links LibRaw.xcframework (libraw_r.dylib, LGPL, dynamic): checks the build has the X3F tools, then develops a
// synthetic 16-bit Bayer DNG (sample.dng) and checks the pixels.
import Foundation
import LibRaw

func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok { fputs("FAIL: \(message())\n", stderr); exit(1) }
}

let version = String(cString: libraw_version())
check(version.hasPrefix("0.21"), "version \(version)")
check(libraw_capabilities() & LIBRAW_CAPS_X3FTOOLS.rawValue != 0, "built without the X3F tools")
var cameras = [String]()
for i in 0..<Int(libraw_cameraCount()) { cameras.append(String(cString: libraw_cameraList()[i]!)) }
check(cameras.contains { $0.hasPrefix("Sigma") && $0.contains("SD1") }, "Sigma Foveon cameras missing from the camera list")

guard let processor = libraw_init(0) else { check(false, "libraw_init"); exit(1) }
let path = CommandLine.arguments[1] + "/sample.dng"
let opened = libraw_open_file(processor, path)
check(opened == LIBRAW_SUCCESS.rawValue, "open DNG: \(String(cString: libraw_strerror(opened)))")
check(libraw_unpack(processor) == LIBRAW_SUCCESS.rawValue, "unpack")
check(processor.pointee.sizes.raw_width == 32 && processor.pointee.sizes.raw_height == 32, "raw size \(processor.pointee.sizes.raw_width)x\(processor.pointee.sizes.raw_height)")
check(processor.pointee.rawdata.raw_image != nil && processor.pointee.rawdata.raw_image[0] == 1000, "first raw sample \(processor.pointee.rawdata.raw_image?[0] ?? 0)")
check(libraw_dcraw_process(processor) == LIBRAW_SUCCESS.rawValue, "dcraw_process")
var status: Int32 = 0
let image = libraw_dcraw_make_mem_image(processor, &status)
check(image != nil && status == 0 && image!.pointee.width == 32 && image!.pointee.colors == 3, "developed image")
libraw_dcraw_clear_mem(image)
libraw_close(processor)
print("LibRaw \(version): X3F tools built in, \(cameras.count) cameras, synthetic DNG unpacked and developed OK")
