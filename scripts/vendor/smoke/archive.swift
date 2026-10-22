// Links Archive.xcframework (libarchive + liblzma + zstd + lz4, system zlib/bzip2/iconv) and writes then reads back
// archives in memory: ZIP (deflate), ZIP with AES-256, 7z, and tar with gzip, bzip2, xz, zstd and lz4.
import Archive
import Foundation

func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok { fputs("FAIL: \(message())\n", stderr); exit(1) }
}

// libarchive converts entry names through the C locale; a process that handles Unicode names must run in a UTF-8 one.
setlocale(LC_ALL, "en_US.UTF-8")

let payloads: [(String, [UInt8])] = [
    ("readme.txt", Array("Super Converter archive smoke test\n".utf8)),
    ("data/ramp.bin", (0..<20_000).map { UInt8(truncatingIfNeeded: $0 / 3) }),
    ("\u{65e5}\u{672c}\u{8a9e}/caf\u{e9}.txt", Array("unicode names\n".utf8)),
]

func write(_ name: String, passphrase: String? = nil, configure: (OpaquePointer) -> Void) -> [UInt8] {
    let a = archive_write_new()!
    configure(a)
    if let passphrase { check(archive_write_set_passphrase(a, passphrase) == 0, "\(name): passphrase") }
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    var used = 0
    check(archive_write_open_memory(a, &buffer, buffer.count, &used) == 0, "\(name): open for writing")
    for (path, bytes) in payloads {
        let entry = archive_entry_new()!
        archive_entry_set_pathname_utf8(entry, path)
        archive_entry_set_size(entry, Int64(bytes.count))
        archive_entry_set_filetype(entry, 0o100000)
        archive_entry_set_perm(entry, 0o644)
        check(archive_write_header(a, entry) == 0, "\(name): header \(path): \(String(cString: archive_error_string(a)))")
        check(archive_write_data(a, bytes, bytes.count) == bytes.count, "\(name): data \(path)")
        archive_entry_free(entry)
    }
    check(archive_write_close(a) == 0, "\(name): close")
    archive_write_free(a)
    return Array(buffer[0..<used])
}

func verify(_ name: String, _ archive: [UInt8], passphrase: String? = nil) {
    let a = archive_read_new()!
    archive_read_support_filter_all(a)
    archive_read_support_format_all(a)
    if let passphrase { archive_read_add_passphrase(a, passphrase) }
    check(archive_read_open_memory(a, archive, archive.count) == 0, "\(name): open for reading")
    var seen = 0
    var entry: OpaquePointer?
    while archive_read_next_header(a, &entry) == 0 {
        let path = String(cString: archive_entry_pathname_utf8(entry))
        guard let expected = payloads.first(where: { $0.0 == path }) else { check(false, "\(name): unexpected entry \(path)"); return }
        var bytes = [UInt8](repeating: 0, count: expected.1.count + 16)
        let n = archive_read_data(a, &bytes, bytes.count)
        check(n == expected.1.count && Array(bytes[0..<n]) == expected.1, "\(name): contents of \(path) (read \(n))")
        seen += 1
    }
    check(seen == payloads.count, "\(name): \(seen) of \(payloads.count) entries")
    archive_read_free(a)
}

var report = [String]()
func roundTrip(_ name: String, passphrase: String? = nil, configure: @escaping (OpaquePointer) -> Void) {
    let bytes = write(name, passphrase: passphrase, configure: configure)
    verify(name, bytes, passphrase: passphrase)
    report.append("\(name) \(bytes.count)")
}

roundTrip("zip") { archive_write_set_format_zip($0); _ = archive_write_set_options($0, "zip:compression=deflate") }
roundTrip("zip-aes256", passphrase: "s3cret") { archive_write_set_format_zip($0); _ = archive_write_set_options($0, "zip:encryption=aes256") }
roundTrip("7z") { archive_write_set_format_7zip($0) }
roundTrip("tar.gz") { archive_write_set_format_pax_restricted($0); archive_write_add_filter_gzip($0) }
roundTrip("tar.bz2") { archive_write_set_format_pax_restricted($0); archive_write_add_filter_bzip2($0) }
roundTrip("tar.xz") { archive_write_set_format_pax_restricted($0); archive_write_add_filter_xz($0) }
roundTrip("tar.zst") { archive_write_set_format_pax_restricted($0); archive_write_add_filter_zstd($0) }
roundTrip("tar.lz4") { archive_write_set_format_pax_restricted($0); archive_write_add_filter_lz4($0) }

print("libarchive \(String(cString: archive_version_details())): round trips OK (bytes: \(report.joined(separator: ", ")))")
