// Links WOFF2.xcframework (google/woff2 + Brotli + C shim): TrueType -> WOFF2 -> TrueType with a system font.
import Foundation
import WOFF2

func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok { fputs("FAIL: \(message())\n", stderr); exit(1) }
}

let candidates = ["/System/Library/Fonts/Supplemental/Arial.ttf", "/System/Library/Fonts/Supplemental/Georgia.ttf",
                  "/System/Library/Fonts/Supplemental/Courier New.ttf", "/Library/Fonts/Arial Unicode.ttf"]
guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
      let font = FileManager.default.contents(atPath: path) else { check(false, "no system TrueType font found"); exit(1) }
let sfnt = [UInt8](font)
check(sfnt.count > 10_000, "font too small")

var packed: UnsafeMutablePointer<UInt8>? = nil
var packedLength = 0
check(sc_woff2_encode(sfnt, sfnt.count, 9, 1, &packed, &packedLength) == 0, "encode")
check(packedLength < sfnt.count && packedLength > 100, "WOFF2 \(packedLength) bytes from \(sfnt.count)")
check(memcmp(packed, "wOF2", 4) == 0, "WOFF2 signature")

var restored: UnsafeMutablePointer<UInt8>? = nil
var restoredLength = 0
check(sc_woff2_decode(packed, packedLength, &restored, &restoredLength) == 0, "decode")
check(restoredLength > 0 && memcmp(restored, "\0\u{1}\0\0", 4) == 0 || memcmp(restored, "true", 4) == 0 || memcmp(restored, "OTTO", 4) == 0, "SFNT signature")
// The decoder rebuilds glyf/loca (the encoder transforms them), so tables are compared where the format promises
// identical bytes: the glyph count (maxp) and the character map (cmap). A second pass must be a fixed point.
func tableData(_ bytes: UnsafePointer<UInt8>, _ length: Int, _ tag: String) -> [UInt8]? {
    let count = Int(bytes[4]) << 8 | Int(bytes[5])
    for i in 0..<count {
        let entry = 12 + i * 16
        let name = String(bytes: UnsafeBufferPointer(start: bytes + entry, count: 4), encoding: .ascii)
        guard name == tag else { continue }
        let offset = (0..<4).reduce(0) { $0 << 8 | Int(bytes[entry + 8 + $1]) }
        let size = (0..<4).reduce(0) { $0 << 8 | Int(bytes[entry + 12 + $1]) }
        return Array(UnsafeBufferPointer(start: bytes + offset, count: min(size, length - offset)))
    }
    return nil
}
for tag in ["maxp", "cmap", "head"] {
    let original = sfnt.withUnsafeBufferPointer { tableData($0.baseAddress!, sfnt.count, tag) }
    let rebuilt = tableData(restored!, restoredLength, tag)
    check(original != nil && original!.count == rebuilt?.count, "\(tag) table size")
    if tag != "head" { check(original == rebuilt, "\(tag) table differs after the round trip") }
}
var again: UnsafeMutablePointer<UInt8>? = nil
var againLength = 0
check(sc_woff2_encode(restored, restoredLength, 9, 1, &again, &againLength) == 0, "second encode")
var fixed: UnsafeMutablePointer<UInt8>? = nil
var fixedLength = 0
check(sc_woff2_decode(again, againLength, &fixed, &fixedLength) == 0, "second decode")
check(fixedLength == restoredLength && memcmp(fixed, restored, restoredLength) == 0, "decode(encode(decoded)) is not a fixed point")
sc_woff2_free(again)
sc_woff2_free(fixed)
sc_woff2_free(packed)
sc_woff2_free(restored)
print("woff2 \((path as NSString).lastPathComponent): \(sfnt.count) -> \(packedLength) bytes -> \(restoredLength), maxp and cmap identical, second pass stable OK")
