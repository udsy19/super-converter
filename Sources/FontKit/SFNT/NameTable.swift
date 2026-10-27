import Foundation

/// The `name` table: decoding the strings a font carries, and writing a minimal one.
enum NameTable {
    /// name ID → string, preferring Windows (UTF-16BE), then Unicode, then Macintosh Roman records.
    static func strings(_ d: [UInt8]) -> [Int: String] {
        guard let count = try? d.be16(2), let base = try? d.be16(4) else { return [:] }
        var best: [Int: (rank: Int, text: String)] = [:]
        for i in 0..<count {
            let r = 6 + i * 12
            guard let platform = try? d.be16(r), let encoding = try? d.be16(r + 2), let id = try? d.be16(r + 6),
                  let length = try? d.be16(r + 8), let offset = try? d.be16(r + 10),
                  let raw = try? d.slice(base + offset, length) else { continue }
            let text: String?
            let rank: Int
            switch platform {
            case 3: text = String(data: Data(raw), encoding: .utf16BigEndian); rank = encoding == 1 || encoding == 10 ? 0 : 2
            case 0: text = String(data: Data(raw), encoding: .utf16BigEndian); rank = 1
            case 1: text = String(data: Data(raw), encoding: .macOSRoman); rank = 3
            default: continue
            }
            guard let text, !text.isEmpty else { continue }
            if best[id] == nil || rank < best[id]!.rank { best[id] = (rank, text) }
        }
        return best.mapValues(\.text)
    }

    /// A format 0 table with one Windows record per entry.
    static func build(_ entries: [Int: String]) -> [UInt8] {
        let sorted = entries.sorted { $0.key < $1.key }
        var w = ByteWriter()
        w.u16(0); w.u16(sorted.count); w.u16(6 + sorted.count * 12)
        var offset = 0
        var storage: [UInt8] = []
        for (id, text) in sorted {
            let utf16 = text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            w.u16(3); w.u16(1); w.u16(0x409); w.u16(id); w.u16(utf16.count); w.u16(offset)
            storage += utf16
            offset += utf16.count
        }
        w.append(storage)
        return w.bytes
    }
}
