import Foundation

/// What the sniffer found out about a file (ux §6.2): content first, extension second.
public struct SniffResult: Hashable, Sendable {
    /// The detected format; nil when nothing in the catalog matches.
    public var format: FormatID?
    /// The format the extension claims, when the file has a known extension.
    public var claimed: FormatID?
    public var sizeBytes: Int64

    public init(format: FormatID?, claimed: FormatID?, sizeBytes: Int64 = 0) {
        self.format = format; self.claimed = claimed; self.sizeBytes = sizeBytes
    }

    /// "This is a PNG file": the file's content differs from its extension.
    public var mismatch: Bool {
        guard let format, let claimed else { return false }
        return !FormatCatalog.isSameFormat(format, claimed)
    }
}

@MainActor
public protocol FormatSniffing: AnyObject {
    func sniff(_ url: URL) throws -> SniffResult
}
