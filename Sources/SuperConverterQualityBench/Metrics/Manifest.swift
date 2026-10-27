import CryptoKit
import Foundation

/// Content hashing and manifests (quality §8 "Content manifest": path, size, SHA-256, symlink targets, empty folders,
/// permissions, mtime).
enum Manifest {
    enum Kind: String, Codable { case file, directory, symlink }

    struct Entry: Codable, Equatable {
        var path: String
        var kind: Kind
        var size: Int64
        /// Hex SHA-256 of a file's bytes; nil for folders and links.
        var sha256: String?
        var symlinkTarget: String?
        /// POSIX permission bits (octal digits, e.g. 644).
        var permissions: Int
        /// Seconds since 1970.
        var modified: Double
    }

    static func sha256(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    /// Streams the file through SHA-256, one megabyte at a time.
    static func sha256(ofFile url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }

    /// Every item under `root`, sorted by path; links are recorded, not followed.
    static func entries(of root: URL) -> [Entry] {
        let fm = FileManager.default
        let base = root.standardizedFileURL.path
        guard let walker = fm.enumerator(atPath: base) else { return [] }
        var out: [Entry] = []
        for case let relative as String in walker {
            let full = (base as NSString).appendingPathComponent(relative)
            guard let attributes = try? fm.attributesOfItem(atPath: full) else { continue }
            let type = attributes[.type] as? FileAttributeType
            let kind: Kind = type == .typeSymbolicLink ? .symlink : type == .typeDirectory ? .directory : .file
            out.append(Entry(path: relative, kind: kind, size: kind == .file ? (attributes[.size] as? Int64 ?? 0) : 0,
                             sha256: kind == .file ? sha256(ofFile: URL(fileURLWithPath: full)) : nil,
                             symlinkTarget: kind == .symlink ? try? fm.destinationOfSymbolicLink(atPath: full) : nil,
                             permissions: Int(String((attributes[.posixPermissions] as? Int) ?? 0, radix: 8)) ?? 0,
                             modified: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// One hash for a whole manifest. Modification times are left out unless asked for (formats store them with different
    /// precision: ZIP's DOS time is 2 seconds); permissions are left out unless both formats hold them.
    static func digest(_ entries: [Entry], includeModified: Bool = false, includePermissions: Bool = false) -> String {
        var text = ""
        for e in entries {
            text += "\(e.kind.rawValue)\t\(e.path)\t\(e.size)\t\(e.sha256 ?? "-")\t\(e.symlinkTarget ?? "-")"
            if includePermissions { text += "\t\(e.permissions)" }
            if includeModified { text += "\t\(Int(e.modified))" }
            text += "\n"
        }
        return sha256(Data(text.utf8))
    }

    /// Paths that differ between two manifests (missing, extra, or changed content/link/kind), for a failure message.
    static func differences(_ expected: [Entry], _ actual: [Entry]) -> [String] {
        let want = Dictionary(uniqueKeysWithValues: expected.map { ($0.path, $0) })
        let got = Dictionary(uniqueKeysWithValues: actual.map { ($0.path, $0) })
        var out: [String] = []
        for (path, e) in want.sorted(by: { $0.key < $1.key }) {
            guard let g = got[path] else { out.append("missing \(path)"); continue }
            if g.kind != e.kind || g.size != e.size || g.sha256 != e.sha256 || g.symlinkTarget != e.symlinkTarget { out.append("changed \(path)") }
        }
        for path in got.keys.sorted() where want[path] == nil { out.append("extra \(path)") }
        return out
    }
}
