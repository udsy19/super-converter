import Foundation

/// A font as outlines and tables (formats §3.2): FontKit reads SFNT/WOFF/WOFF2/EOT/SVG fonts into it and writes them back,
/// converting between quadratic (TrueType) and cubic (CFF) outlines.
public struct FontModel: Hashable, Codable, Sendable {
    public enum OutlineKind: String, Codable, Sendable { case quadratic, cubic }

    public struct Contour: Hashable, Codable, Sendable {
        /// Points in font units; `onCurve` false marks control points.
        public var points: [Point]
        public struct Point: Hashable, Codable, Sendable {
            public var x: Double, y: Double
            public var onCurve: Bool
            public init(_ x: Double, _ y: Double, onCurve: Bool = true) { self.x = x; self.y = y; self.onCurve = onCurve }
        }
        public init(points: [Point]) { self.points = points }
    }

    public struct Glyph: Hashable, Codable, Sendable {
        public var name: String
        public var advance: Int
        public var contours: [Contour]
        public init(name: String, advance: Int, contours: [Contour] = []) {
            self.name = name; self.advance = advance; self.contours = contours
        }
    }

    public var familyName: String
    public var styleName: String
    public var unitsPerEm: Int
    public var ascent: Int
    public var descent: Int
    public var outlineKind: OutlineKind
    public var glyphs: [Glyph]
    /// Unicode → glyph index.
    public var characterMap: [UInt32: Int]
    /// Tables carried through unchanged by their four-character tag (name, OS/2, kern, GPOS…).
    public var tables: [String: Data]

    public init(familyName: String, styleName: String = "Regular", unitsPerEm: Int = 1000, ascent: Int = 800, descent: Int = -200,
                outlineKind: OutlineKind = .quadratic, glyphs: [Glyph] = [], characterMap: [UInt32: Int] = [:],
                tables: [String: Data] = [:]) {
        self.familyName = familyName; self.styleName = styleName; self.unitsPerEm = unitsPerEm; self.ascent = ascent
        self.descent = descent; self.outlineKind = outlineKind; self.glyphs = glyphs; self.characterMap = characterMap
        self.tables = tables
    }
}
