import Compression
import Foundation

/// A small ZIP reader and writer for e-book containers (EPUB, HTMLZ, TXTZ, CBZ). Stored and deflated entries, ZIP64 sizes,
/// CRC-32 checked on read. Nothing is extracted to disk: readers pull entries into memory, so a hostile path never reaches
/// the file system (ARCHITECTURE §4, extraction safety belongs to ArchiveKit).
public enum ZipError: Error, Equatable, Sendable {
    case notAZip
    case corrupt(String)
    case encrypted
    case unsupportedMethod(Int)
    case tooLarge
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

public struct ZipArchive: Sendable {
    public struct Entry: Hashable, Sendable {
        public let name: String
        public let method: Int
        public let compressedSize: Int
        public let size: Int
        public let crc: UInt32
        let localOffset: Int
        let flags: Int
        public var isDirectory: Bool { name.hasSuffix("/") }
    }

    /// Largest single entry we inflate into memory.
    static let entryLimit = 1 << 31

    public let entries: [Entry]
    private let bytes: Data
    private let byName: [String: Int]
    private let byLowercasedName: [String: Int]

    public init(url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ZipError.notAZip }
        try self.init(data: data)
    }

    public init(data: Data) throws {
        let data = Data(data)   // zero-based indices
        bytes = data
        guard data.count >= 22 else { throw ZipError.notAZip }
        func u16(_ i: Int) -> Int { Int(data[i]) | Int(data[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        func u64(_ i: Int) -> Int { u32(i) | u32(i + 4) << 32 }

        var eocd = -1
        var i = data.count - 22
        let floor = max(0, data.count - 22 - 65_535)
        while i >= floor {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 5, data[i + 3] == 6 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        var count = u16(eocd + 10)
        var directorySize = u32(eocd + 12)
        var directoryOffset = u32(eocd + 16)
        if (count == 0xFFFF || directoryOffset == 0xFFFF_FFFF || directorySize == 0xFFFF_FFFF), eocd >= 20,
           u32(eocd - 20) == 0x0706_4B50 {
            let record = u64(eocd - 20 + 8)
            guard record >= 0, record + 56 <= data.count, u32(record) == 0x0606_4B50 else { throw ZipError.corrupt("ZIP64 directory") }
            count = u64(record + 32); directorySize = u64(record + 40); directoryOffset = u64(record + 48)
        }
        guard directoryOffset >= 0, directoryOffset + directorySize <= data.count else { throw ZipError.corrupt("directory") }

        var list: [Entry] = []
        var p = directoryOffset
        for _ in 0..<count {
            guard p + 46 <= data.count, u32(p) == 0x0201_4B50 else { throw ZipError.corrupt("directory entry") }
            let flags = u16(p + 8), method = u16(p + 10), crc = UInt32(truncatingIfNeeded: u32(p + 16))
            var compressed = u32(p + 20), size = u32(p + 24)
            let nameLength = u16(p + 28), extraLength = u16(p + 30), commentLength = u16(p + 32)
            var offset = u32(p + 42)
            guard p + 46 + nameLength + extraLength + commentLength <= data.count else { throw ZipError.corrupt("directory entry") }
            let nameBytes = data.subdata(in: p + 46..<p + 46 + nameLength)
            let name = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1) ?? ""
            var e = p + 46 + nameLength
            let extraEnd = e + extraLength
            while e + 4 <= extraEnd {
                let id = u16(e), length = u16(e + 2)
                if id == 1 {
                    var q = e + 4
                    if size == 0xFFFF_FFFF, q + 8 <= extraEnd { size = u64(q); q += 8 }
                    if compressed == 0xFFFF_FFFF, q + 8 <= extraEnd { compressed = u64(q); q += 8 }
                    if offset == 0xFFFF_FFFF, q + 8 <= extraEnd { offset = u64(q) }
                }
                e += 4 + length
            }
            list.append(Entry(name: name, method: method, compressedSize: compressed, size: size, crc: crc, localOffset: offset, flags: flags))
            p += 46 + nameLength + extraLength + commentLength
        }
        entries = list
        var exact: [String: Int] = [:], folded: [String: Int] = [:]
        for (index, entry) in list.enumerated() where !entry.isDirectory {
            if exact[entry.name] == nil { exact[entry.name] = index }
            if folded[entry.name.lowercased()] == nil { folded[entry.name.lowercased()] = index }
        }
        byName = exact; byLowercasedName = folded
    }

    public func entry(named name: String) -> Entry? {
        if let i = byName[name] { return entries[i] }
        if let i = byLowercasedName[name.lowercased()] { return entries[i] }
        return nil
    }

    public func contains(_ name: String) -> Bool { entry(named: name) != nil }

    /// The entry's bytes, or nil when there is no such entry.
    public func data(named name: String) throws -> Data? {
        guard let e = entry(named: name) else { return nil }
        return try data(for: e)
    }

    public func data(for entry: Entry) throws -> Data {
        if entry.flags & 1 != 0 { throw ZipError.encrypted }
        let b = bytes
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        let p = entry.localOffset
        guard p >= 0, p + 30 <= b.count, u16(p) == 0x4B50, u16(p + 2) == 0x0403 else { throw ZipError.corrupt(entry.name) }
        let start = p + 30 + u16(p + 26) + u16(p + 28)
        guard start >= 0, entry.compressedSize >= 0, start + entry.compressedSize <= b.count else { throw ZipError.corrupt(entry.name) }
        guard entry.size <= Self.entryLimit else { throw ZipError.tooLarge }
        let raw = b.subdata(in: start..<start + entry.compressedSize)
        let out: Data
        switch entry.method {
        case 0: out = raw
        case 8:
            if entry.size == 0 { out = Data() } else {
                guard let inflated = Self.inflate(raw, size: entry.size) else { throw ZipError.corrupt(entry.name) }
                out = inflated
            }
        default: throw ZipError.unsupportedMethod(entry.method)
        }
        guard out.count == entry.size, CRC32.checksum(out) == entry.crc else { throw ZipError.corrupt(entry.name) }
        return out
    }

    static func inflate(_ raw: Data, size: Int) -> Data? {
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { destination.deallocate() }
        let written = raw.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(destination, size, base, raw.count, nil, COMPRESSION_ZLIB)
        }
        return written == size ? Data(bytes: destination, count: size) : nil
    }
}

/// Writes a ZIP file entry by entry. `mimetype`-style entries are stored; others deflated unless they are already compressed
/// pictures.
public final class ZipWriter {
    private struct Written { var name: Data; var method: Int; var crc: UInt32; var compressed: Int; var size: Int; var offset: Int }

    private let handle: FileHandle
    private var written: [Written] = []
    private var position = 0
    private let stamp: (time: Int, date: Int)

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: Date())
        let year = max(1980, c.year ?? 1980)
        stamp = (((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2),
                 ((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
    }

    /// Adds an entry. `compress: nil` chooses by the file name.
    public func add(_ name: String, _ data: Data, compress: Bool? = nil) throws {
        guard data.count < 0xFFFF_FFFF, position < 0xFFFF_FFFF else { throw ZipError.tooLarge }
        let shouldCompress = compress ?? !Self.alreadyCompressed(name)
        var method = 0
        var payload = data
        if shouldCompress, data.count > 32, let deflated = Self.deflate(data), deflated.count < data.count {
            method = 8; payload = deflated
        }
        let nameBytes = Data(name.utf8)
        var header = Data()
        header.le32(0x0403_4B50); header.le16(20); header.le16(0x0800); header.le16(method)
        header.le16(stamp.time); header.le16(stamp.date)
        let crc = CRC32.checksum(data)
        header.le32(crc); header.le32(UInt32(payload.count)); header.le32(UInt32(data.count))
        header.le16(nameBytes.count); header.le16(0)
        header.append(nameBytes)
        let entry = Written(name: nameBytes, method: method, crc: crc, compressed: payload.count, size: data.count, offset: position)
        try handle.write(contentsOf: header)
        try handle.write(contentsOf: payload)
        position += header.count + payload.count
        written.append(entry)
    }

    public func finish() throws {
        let directoryStart = position
        var directory = Data()
        for e in written {
            directory.le32(0x0201_4B50); directory.le16(20); directory.le16(20); directory.le16(0x0800); directory.le16(e.method)
            directory.le16(stamp.time); directory.le16(stamp.date)
            directory.le32(e.crc); directory.le32(UInt32(e.compressed)); directory.le32(UInt32(e.size))
            directory.le16(e.name.count); directory.le16(0); directory.le16(0); directory.le16(0); directory.le16(0)
            directory.le32(0); directory.le32(UInt32(e.offset))
            directory.append(e.name)
        }
        var end = Data()
        end.le32(0x0605_4B50); end.le16(0); end.le16(0)
        end.le16(written.count); end.le16(written.count)
        end.le32(UInt32(directory.count)); end.le32(UInt32(directoryStart)); end.le16(0)
        try handle.write(contentsOf: directory)
        try handle.write(contentsOf: end)
        try handle.close()
    }

    func abandon() { try? handle.close() }

    static func alreadyCompressed(_ name: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "avif", "jp2", "woff", "woff2", "mp3", "mp4", "m4a", "ogg", "zip"]
            .contains((name as NSString).pathExtension.lowercased()) || name == "mimetype"
    }

    static func deflate(_ data: Data) -> Data? {
        let capacity = data.count + data.count / 8 + 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let size = data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
            guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        return size > 0 ? Data(bytes: destination, count: size) : nil
    }
}

extension Data {
    mutating func le16(_ v: Int) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    mutating func le32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
}
