import Foundation

/// A slide deck: slides of positioned shapes, notes and a theme (formats §3.2: text, pictures, shapes, themes, backgrounds;
/// no animations). OfficeKit's PPTX reader, renderer and writer share it.
public struct Deck: Hashable, Codable, Sendable {
    public var size: VectorSize
    public var slides: [Slide]
    public var theme: DeckTheme
    public init(size: VectorSize, slides: [Slide], theme: DeckTheme = DeckTheme()) {
        self.size = size; self.slides = slides; self.theme = theme
    }
}

public struct DeckTheme: Hashable, Codable, Sendable {
    public var headingFont: String
    public var bodyFont: String
    /// "#RRGGBB" accent colours 1–6.
    public var accents: [String]
    public init(headingFont: String = "Calibri Light", bodyFont: String = "Calibri", accents: [String] = []) {
        self.headingFont = headingFont; self.bodyFont = bodyFont; self.accents = accents
    }
}

public struct Slide: Hashable, Codable, Sendable {
    public var title: String?
    public var shapes: [SlideShape]
    public var background: VectorColour?
    public var notes: String?
    public var isHidden: Bool
    public init(title: String? = nil, shapes: [SlideShape] = [], background: VectorColour? = nil, notes: String? = nil,
                isHidden: Bool = false) {
        self.title = title; self.shapes = shapes; self.background = background; self.notes = notes; self.isHidden = isHidden
    }
}

public struct SlideShape: Hashable, Codable, Sendable {
    public enum Content: Hashable, Codable, Sendable {
        case text([DocBlock])
        case picture(ImageAsset)
        case vector([VectorNode])
    }

    /// Points, origin at the slide's top left, y down (as PowerPoint places shapes; unlike `LayoutDocument`'s y-up page boxes).
    /// A `.vector` shape's nodes are in points relative to the top left of this box.
    public var box: LayoutBox
    /// Degrees clockwise.
    public var rotation: Double
    public var content: Content
    public init(box: LayoutBox, rotation: Double = 0, content: Content) {
        self.box = box; self.rotation = rotation; self.content = content
    }
}
