import Foundation
import SuperConverterCore
import UnALZ

/// ALZip archives through unalz (zlib licence, formats §3.3), whose C shim extracts one entry into a buffer.
enum UnALZReader {
    static func read(_ request: ArchiveReadRequest) throws -> ArchiveTree {
        try validateStructure(request.source)
        var code: Int32 = 0
        guard let alz = sc_alz_open(request.source.path, &code) else {
            throw ArchiveError.damaged(String(cString: sc_alz_error_string(code)))
        }
        defer { sc_alz_close(alz) }
        if let password = request.password { sc_alz_set_password(alz, password) }

        let extractor = try request.extractor(windowsSeparators: true)
        let count = sc_alz_count(alz)
        var wasEncrypted = false
        for index in 0..<count {
            if request.isCancelled() { throw ArchiveError.cancelled }
            request.report(StepProgress(fraction: Double(index) / Double(max(count, 1)), unit: "File \(index + 1) of \(count)"))
            guard let namePointer = sc_alz_name(alz, index) else { continue }
            let name = String(cString: namePointer)
            if sc_alz_is_directory(alz, index) != 0 { try extractor.directory(name); continue }

            let encrypted = sc_alz_is_encrypted(alz, index) != 0
            wasEncrypted = wasEncrypted || encrypted
            if encrypted && request.password == nil { throw ArchiveError.passwordRequired }
            let size = sc_alz_size(alz, index)
            guard size >= 0, size <= Int64(Int32.max) else { throw ArchiveError.unsupported("A file in this archive is larger than 2 GB, which the ALZ reader can’t unpack.") }
            guard let sink = try extractor.file(name, size: size) else { continue }
            do {
                var buffer = [UInt8](repeating: 0, count: Int(size))
                let status = buffer.withUnsafeMutableBufferPointer { sc_alz_extract(alz, index, $0.baseAddress, $0.count) }
                if status != 0 { throw encrypted ? ArchiveError.passwordRequired : ArchiveError.damaged(String(cString: sc_alz_error_string(status))) }
                try buffer.withUnsafeBytes { try sink.write($0) }
                try sink.close()
            } catch {
                sink.abort()
                throw error
            }
        }
        request.report(StepProgress(fraction: 1, unit: nil))
        return extractor.finish(wasEncrypted: wasEncrypted, nameEncoding: "CP949")
    }

    /// unalz reads past the end of a truncated archive (a NULL file handle inside `fread`), so the container is walked first
    /// the way unalz walks it: every header, name and data run must lie inside the file, and the file must end on a record
    /// boundary. Whatever fails here is damaged; whatever passes cannot send unalz past the end.
    static func validateStructure(_ url: URL) throws {
        let damaged = ArchiveError.damaged("This ALZ archive is damaged or cut short.")
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw ArchiveError.failed("The archive couldn’t be opened.") }
        defer { try? handle.close() }
        let size = Int64((try? handle.seekToEnd()) ?? 0)
        var position: Int64 = 0
        func read(_ count: Int) throws -> [UInt8] {
            guard count >= 0, position + Int64(count) <= size else { throw damaged }
            try handle.seek(toOffset: UInt64(position))
            guard let data = try handle.read(upToCount: count), data.count == count else { throw damaged }
            position += Int64(count)
            return [UInt8](data)
        }
        func le(_ bytes: ArraySlice<UInt8>) -> Int64 { bytes.reversed().reduce(0) { $0 << 8 | Int64($1) } }
        guard size >= 8 else { throw damaged }
        while position < size {
            switch le(try read(4)[...]) {
            case 0x015A_4C41: _ = try read(4)                                    // "ALZ\1" and one unknown word
            case 0x015A_4C43: _ = try read(12)                                   // "CLZ\1": the central directory head
            case 0x025A_4C43: break                                              // "CLZ\2": the end record
            case 0x015A_4C42:                                                    // "BLZ\1": a file
                let head = try read(9)                                           // name length, attribute, time, descriptor, unknown
                let nameLength = Int(le(head[0..<2])), descriptor = Int(head[7])
                let sizeBytes = descriptor / 0x10
                guard [0, 1, 2, 4, 8].contains(sizeBytes), nameLength > 0, nameLength < 0x8000 else { throw damaged }
                var compressed: Int64 = 0
                if sizeBytes > 0 {
                    _ = try read(6)                                              // method, unknown, CRC
                    compressed = le(try read(sizeBytes)[...])
                    _ = try read(sizeBytes)
                }
                _ = try read(nameLength)
                if descriptor & 1 != 0 { _ = try read(12) }                      // the password check bytes
                guard compressed >= 0, position + compressed <= size else { throw damaged }
                position += compressed
            default: throw damaged
            }
        }
    }
}
