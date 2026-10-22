import Compression
import Foundation

/// The little of a ZIP file the sniffer needs (ux §6.2): the entry names from the central directory and the text of a few
/// small entries (`mimetype`, `[Content_Types].xml`). Entries are stored or deflated; ZIP64 archives report no entries.
struct ZipDirectory {
    private let data: Data
    private var entries: [String: (offset: Int, compressed: Int, size: Int, method: UInt16)] = [:]

    var names: Set<String> { Set(entries.keys) }

    /// Reads the directory of the ZIP at `url`; nil when it has none (not a ZIP, or damaged).
    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 22 else { return nil }
        self.data = data
        func u16(_ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }

        // The end-of-central-directory record sits in the last 64 KB + 22 bytes.
        var eocd = -1
        var at = data.count - 22
        while at >= max(0, data.count - 22 - 65_535) {
            if u32(at) == 0x0605_4B50 { eocd = at; break }
            at -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        var position = u32(eocd + 16)
        for _ in 0..<count {
            guard position + 46 <= data.count, u32(position) == 0x0201_4B50 else { break }
            let method = UInt16(u16(position + 10))
            let compressed = u32(position + 20), size = u32(position + 24)
            let nameLength = u16(position + 28), extra = u16(position + 30), comment = u16(position + 32)
            let local = u32(position + 42)
            guard position + 46 + nameLength <= data.count else { break }
            let nameBytes = data.subdata(in: (data.startIndex + position + 46)..<(data.startIndex + position + 46 + nameLength))
            if let name = String(data: nameBytes, encoding: .utf8) {
                entries[name] = (local, compressed, size, method)
            }
            position += 46 + nameLength + extra + comment
        }
        if entries.isEmpty { return nil }
    }

    /// The text of a small entry (at most 1 MB), or nil when it is missing or cannot be read.
    func text(of name: String) -> String? {
        guard let entry = entries[name], entry.size <= 1_048_576, entry.offset + 30 <= data.count else { return nil }
        func u16(_ at: Int) -> Int { Int(data[data.startIndex + at]) | Int(data[data.startIndex + at + 1]) << 8 }
        let start = entry.offset + 30 + u16(entry.offset + 26) + u16(entry.offset + 28)
        guard start + entry.compressed <= data.count else { return nil }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressed))
        switch entry.method {
        case 0:
            return String(data: raw, encoding: .utf8)
        case 8:
            var output = [UInt8](repeating: 0, count: max(entry.size, 1))
            let written = raw.withUnsafeBytes { source in
                compression_decode_buffer(&output, output.count, source.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
            return written > 0 ? String(bytes: output.prefix(written), encoding: .utf8) : nil
        default:
            return nil
        }
    }
}
