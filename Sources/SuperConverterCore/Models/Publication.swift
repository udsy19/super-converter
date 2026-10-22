import Foundation

/// An e-book (formats §3.2): spine, table of contents, metadata, cover and resources. EbookKit's readers produce it and its
/// EPUB/OEB writers consume it; comics are fixed-layout publications.
public struct Publication: Hashable, Codable, Sendable {
    public enum Layout: String, Codable, Sendable { case reflowable, fixed }
    public enum Direction: String, Codable, Sendable { case leftToRight, rightToLeft }

    public var metadata: DocMetadata
    public var layout: Layout
    public var direction: Direction
    /// Reading order of the content documents.
    public var spine: [PublicationItem]
    public var contents: [ContentsEntry]
    /// Id of the cover item in `resources`, when there is one.
    public var cover: String?
    /// Every other part by id: pictures, fonts, styles.
    public var resources: [String: PublicationResource]

    public init(metadata: DocMetadata = DocMetadata(), layout: Layout = .reflowable, direction: Direction = .leftToRight,
                spine: [PublicationItem] = [], contents: [ContentsEntry] = [], cover: String? = nil,
                resources: [String: PublicationResource] = [:]) {
        self.metadata = metadata; self.layout = layout; self.direction = direction; self.spine = spine
        self.contents = contents; self.cover = cover; self.resources = resources
    }
}

public struct PublicationItem: Hashable, Codable, Sendable {
    public var id: String
    public var title: String?
    /// The content as a document (text books), or a page picture resource id (comics).
    public var content: Content
    public enum Content: Hashable, Codable, Sendable {
        case document(DocModel)
        case page(resource: String)
    }
    public init(id: String, title: String? = nil, content: Content) { self.id = id; self.title = title; self.content = content }
}

public struct PublicationResource: Hashable, Codable, Sendable {
    public var mediaType: String
    public var data: Data
    public init(mediaType: String, data: Data) { self.mediaType = mediaType; self.data = data }
}

public struct ContentsEntry: Hashable, Codable, Sendable {
    public var title: String
    public var itemID: String
    public var children: [ContentsEntry]
    public init(title: String, itemID: String, children: [ContentsEntry] = []) {
        self.title = title; self.itemID = itemID; self.children = children
    }
}
