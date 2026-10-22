import Foundation

/// Where results go (ux §5.11, §6.3).
public enum OutputPlace: Hashable, Codable, Sendable {
    case nextToOriginal
    case downloads
    case folder(URL)
}

/// What to do when a file of that name exists (Settings › General).
public enum CollisionPolicy: String, Codable, CaseIterable, Sendable {
    /// "Report 2.pdf" (Finder's style).
    case addNumber
    /// Replaces the earlier result, never the source itself.
    case replace
    case ask
}

/// A file about to be written.
public struct OutputTarget: Hashable, Sendable {
    /// The final URL (a single file) or folder (several files) the result will be moved to.
    public var url: URL
    public var isFolder: Bool
    /// True when the chosen folder was not writable and Downloads was used instead (the card says so).
    public var fellBackToDownloads: Bool
    public init(url: URL, isFolder: Bool = false, fellBackToDownloads: Bool = false) {
        self.url = url; self.isFolder = isFolder; self.fellBackToDownloads = fellBackToDownloads
    }
}

/// ConvertKit's output rules: same name, new extension, in the chosen place; collisions add " 2", " 3"; multi-file results
/// go into a folder "<name> (<FORMAT>)" with "<name> – page 1.png" style names; creation and modification dates are
/// copied from the source; partial files are written into a work folder and moved into place when complete.
@MainActor
public protocol OutputPolicy: AnyObject {
    func target(for source: URL, format: FormatID, place: OutputPlace, multipleFiles: Bool) throws -> OutputTarget
    /// "Report – page 3.png": the n-th file of a multi-file result.
    func partName(base: String, kind: String, index: Int, format: FormatID) -> String
    /// Moves the finished files into place and copies the dates; returns the final URLs.
    func place(_ results: [URL], for source: URL, into target: OutputTarget) throws -> [URL]
}
