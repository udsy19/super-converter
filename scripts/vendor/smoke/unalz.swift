// Links UnALZ.xcframework (unalz + C shim): reads an ALZ archive with a stored and a deflated entry.
import Foundation
import UnALZ

func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok { fputs("FAIL: \(message())\n", stderr); exit(1) }
}

let path = CommandLine.arguments[1] + "/sample.alz"
var error: Int32 = 0
guard let archive = sc_alz_open(path, &error) else {
    check(false, "open: \(String(cString: sc_alz_error_string(error)))"); exit(1)
}
check(sc_alz_count(archive) == 2, "entry count \(sc_alz_count(archive))")

func extract(_ index: Int) -> (String, [UInt8]) {
    let name = String(cString: sc_alz_name(archive, index))
    var buffer = [UInt8](repeating: 0, count: Int(sc_alz_size(archive, index)))
    let status = sc_alz_extract(archive, index, &buffer, buffer.count)
    check(status == 0, "extract \(name): \(String(cString: sc_alz_error_string(status)))")
    return (name, buffer)
}

let (firstName, first) = extract(0)
check(firstName == "hello.txt" && String(decoding: first, as: UTF8.self) == "hello from the ALZ fixture\n", "stored entry")
let (secondName, second) = extract(1)
check(secondName == "deep/data.bin" && second == Array((0..<8).flatMap { _ in (0...255).map(UInt8.init) }), "deflated entry")
check(sc_alz_is_encrypted(archive, 0) == 0 && sc_alz_is_directory(archive, 0) == 0, "entry flags")
sc_alz_close(archive)
print("unalz: stored + deflated entries OK")
