import Foundation

/// The contents of an archive: a tree of entries, extracted into the job's work folder (ARCHITECTURE §6: archive
/// contents are always files). ArchiveKit reads every format into it and writes the target formats from it.
public struct ArchiveTree: Hashable, Codable, Sendable {
    public struct Entry: Hashable, Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case file, directory, symlink }

        /// Path inside the archive, "/"-separated, no leading slash, no "..".
        public var path: String
        public var kind: Kind
        public var size: Int64
        public var modified: Date?
        public var permissions: Int
        /// The extracted file in the work folder (files only).
        public var extracted: URL?
        /// Link target (symlinks only).
        public var linkTarget: String?

        public init(path: String, kind: Kind, size: Int64 = 0, modified: Date? = nil, permissions: Int = 0o644,
                    extracted: URL? = nil, linkTarget: String? = nil) {
            self.path = path; self.kind = kind; self.size = size; self.modified = modified; self.permissions = permissions
            self.extracted = extracted; self.linkTarget = linkTarget
        }
    }

    public var entries: [Entry]
    /// The work folder the entries were extracted into.
    public var root: URL?
    /// True when the archive asked for a password.
    public var wasEncrypted: Bool
    /// "CP437", "Shift-JIS": the file-name encoding detected for old archives.
    public var nameEncoding: String?

    public init(entries: [Entry] = [], root: URL? = nil, wasEncrypted: Bool = false, nameEncoding: String? = nil) {
        self.entries = entries; self.root = root; self.wasEncrypted = wasEncrypted; self.nameEncoding = nameEncoding
    }

    public var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
}
