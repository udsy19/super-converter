import Foundation
import SuperConverterCore

/// One finished conversion in the panel's "Recently converted" list.
struct RecentConversion: Codable, Equatable, Identifiable {
    var id = UUID()
    /// The file that was converted ("Invoice 0412.docx"), and its format: "from DOCX".
    var sourceName: String
    var sourceFormat: FormatID
    /// The first file written ("Invoice 0412.pdf"); the row's name and what Show in Finder reveals.
    var output: URL
    var date: Date

    var name: String { output.lastPathComponent }
}

/// The last ten conversions, kept in `recent.json` next to the other app data (ARCHITECTURE §8).
struct RecentList {
    static let limit = 10
    var file: URL = SuperConverterPaths.recent

    func load() -> [RecentConversion] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RecentConversion].self, from: data)) ?? []
    }

    /// Adds the newest first and drops everything past ten; returns the new list.
    @discardableResult
    func add(_ new: [RecentConversion]) -> [RecentConversion] {
        let list = Array((new.reversed() + load()).prefix(Self.limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(list) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return list
    }

    /// "2 min ago", "10 min ago", "yesterday": the row's second line after "from DOCX · ".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
