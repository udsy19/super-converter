import Foundation

/// The eleven kinds of file (formats §1). The order is the catalog's and the order the picker groups them in.
public enum FormatCategory: String, CaseIterable, Codable, Sendable {
    case document, image, video, audio, spreadsheet, presentation, ebook, archive, vector, cad, font

    /// Plural title for section heads and the Formats pane ("Documents", "Slides").
    public var title: String {
        switch self {
        case .document: "Documents"
        case .image: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .spreadsheet: "Spreadsheets"
        case .presentation: "Slides"
        case .ebook: "E-books"
        case .archive: "Archives"
        case .vector: "Vector"
        case .cad: "CAD"
        case .font: "Fonts"
        }
    }

    /// The noun for a count ("2 photos and a video"): the drag-over summary (ux §5.2).
    public func noun(count: Int) -> String {
        let one: String, many: String
        switch self {
        case .document: (one, many) = ("document", "documents")
        case .image: (one, many) = ("photo", "photos")
        case .video: (one, many) = ("video", "videos")
        case .audio: (one, many) = ("audio file", "audio files")
        case .spreadsheet: (one, many) = ("spreadsheet", "spreadsheets")
        case .presentation: (one, many) = ("presentation", "presentations")
        case .ebook: (one, many) = ("e-book", "e-books")
        case .archive: (one, many) = ("archive", "archives")
        case .vector: (one, many) = ("drawing", "drawings")
        case .cad: (one, many) = ("CAD drawing", "CAD drawings")
        case .font: (one, many) = ("font", "fonts")
        }
        return count == 1 ? one : many
    }
}
