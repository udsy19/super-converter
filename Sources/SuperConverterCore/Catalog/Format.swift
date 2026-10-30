import Foundation
import UniformTypeIdentifiers

/// A format's identity: its lower-case extension without the dot ("jpg", "tar.gz"). Extensions that are the same format
/// (JPG/JPEG/JFIF, ...) are separate ids that share a `Format.family`; the output keeps the extension the person picked.
public struct FormatID: RawRepresentable, Hashable, Codable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static func < (a: FormatID, b: FormatID) -> Bool { a.rawValue < b.rawValue }
    public var description: String { rawValue }
    /// "JPG", "TAR.GZ": how pills show it (ux §1.1).
    public var pill: String { rawValue.uppercased() }
}

/// What the generated catalog holds for one format.
struct FormatSeed {
    var id: FormatID
    var category: FormatCategory
    var name: String
    var outputOnly: Bool

    init(_ id: FormatID, _ category: FormatCategory, _ name: String, outputOnly: Bool = false) {
        self.id = id; self.category = category; self.name = name; self.outputOnly = outputOnly
    }
}

/// Hand-written facts about a format: system type identifiers, MIME types, search synonyms, family.
struct FormatDetail {
    var uti: [String] = []
    var mime: [String] = []
    var synonyms: [String] = []
    /// The canonical member when several extensions are one format.
    var family: FormatID?
}

/// One of the 212 catalog formats (or an output-only format such as SFZ).
public struct Format: Hashable, Sendable, Identifiable {
    public let id: FormatID
    public let category: FormatCategory
    /// Plain-language name ("Word document").
    public let name: String
    /// Uniform Type Identifiers, most specific first; empty when macOS declares none (then `UTType(filenameExtension:)` decides).
    public let utTypeIdentifiers: [String]
    public let mimeTypes: [String]
    /// Words the picker's search matches besides the extension and name ("word", "kindle", "transparent").
    public let synonyms: [String]
    /// The canonical member of the group of extensions that are one format (JPEG → JPG); `id` when alone.
    public let family: FormatID
    /// True for formats that exist only as targets (SFZ).
    public let isOutputOnly: Bool

    public var utTypes: [UTType] { utTypeIdentifiers.compactMap(UTType.init) }
    /// "JPG", "DOCX": the pill label.
    public var pill: String { id.pill }
}

/// All formats, by id and by category (formats §1): 212 catalog formats plus the output-only ones.
public enum FormatCatalog {
    public static let all: [Format] = seeds.map { seed in
        let detail = details[seed.id.rawValue] ?? FormatDetail()
        return Format(id: seed.id, category: seed.category, name: seed.name, utTypeIdentifiers: detail.uti,
                      mimeTypes: detail.mime, synonyms: detail.synonyms, family: detail.family ?? seed.id,
                      isOutputOnly: seed.outputOnly)
    }

    /// The 212 formats CloudConvert lists (the ones a person can drop).
    public static let inputs: [Format] = all.filter { !$0.isOutputOnly }

    /// Type identifiers the catalog uses that macOS itself doesn't declare: other apps do (VLC, Keka, The Unarchiver), so
    /// a clean Mac may not know them. The app imports these under their own names (Info.plist), so Open With and drops
    /// work either way; every other identifier is declared by macOS (CI's clean runner checks).
    public static let appDeclaredTypes: Set<String> = ["org.matroska.mkv", "org.xiph.ogg-video", "com.rarlab.rar-archive"]

    private static let byID: [FormatID: Format] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func format(_ id: FormatID) -> Format? { byID[id] }

    public static func formats(in category: FormatCategory) -> [Format] { all.filter { $0.category == category } }

    /// The format with this file extension ("JPG", "tar.gz"), case-insensitive.
    public static func format(forExtension ext: String) -> Format? {
        byID[FormatID(ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))]
    }

    /// The format of a file by name: the longest known extension wins ("archive.tar.gz" is TAR.GZ, not GZ).
    public static func format(forFileName name: String) -> Format? {
        let parts = name.lowercased().split(separator: ".").map(String.init)
        guard parts.count > 1 else { return nil }
        if parts.count > 2, let compound = byID[FormatID(parts.suffix(2).joined(separator: "."))] { return compound }
        return byID[FormatID(parts[parts.count - 1])]
    }

    /// True when both extensions are one format (JPG and JPEG).
    public static func isSameFormat(_ a: FormatID, _ b: FormatID) -> Bool {
        (byID[a]?.family ?? a) == (byID[b]?.family ?? b)
    }
}
