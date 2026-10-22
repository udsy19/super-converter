import Foundation

/// A CAD drawing (formats §3.2): layers, blocks, entities and layouts in drawing units. CADKit reads DXF/DWF into it,
/// writes DXF from it and plots it into a `VectorDocument`.
public struct CADDrawing: Hashable, Codable, Sendable {
    public enum Unit: String, Codable, Sendable { case unitless, millimetres, centimetres, metres, inches, feet }

    public struct Layer: Hashable, Codable, Sendable {
        public var name: String
        /// AutoCAD colour index 1–255, or a true colour as 0xRRGGBB when `trueColour` is set.
        public var colourIndex: Int
        public var trueColour: Int?
        public var lineType: String
        public var lineWeight: Double?
        public var isVisible: Bool
        public init(name: String, colourIndex: Int = 7, trueColour: Int? = nil, lineType: String = "CONTINUOUS",
                    lineWeight: Double? = nil, isVisible: Bool = true) {
            self.name = name; self.colourIndex = colourIndex; self.trueColour = trueColour; self.lineType = lineType
            self.lineWeight = lineWeight; self.isVisible = isVisible
        }
    }

    public struct Point3: Hashable, Codable, Sendable {
        public var x: Double, y: Double, z: Double
        public init(_ x: Double, _ y: Double, _ z: Double = 0) { self.x = x; self.y = y; self.z = z }
    }

    /// A dash pattern in drawing units: positive = dash, negative = gap, zero = dot. Empty = continuous.
    public struct LineType: Hashable, Codable, Sendable {
        public var name: String
        public var pattern: [Double]
        public init(name: String, pattern: [Double] = []) { self.name = name; self.pattern = pattern }
    }

    /// A text style: the font file the drawing names (".ttf" or ".shx") and its fixed shape.
    public struct TextStyle: Hashable, Codable, Sendable {
        public var name: String
        public var font: String
        public var widthFactor: Double
        /// Oblique angle in degrees.
        public var oblique: Double
        public init(name: String, font: String = "", widthFactor: Double = 1, oblique: Double = 0) {
            self.name = name; self.font = font; self.widthFactor = widthFactor; self.oblique = oblique
        }
    }

    /// What an entity sets for itself instead of taking it from its layer (or, inside a block, from the INSERT).
    public struct Appearance: Hashable, Codable, Sendable {
        /// 0 = by block, 1–255 = AutoCAD colour index; nil = by layer.
        public var colourIndex: Int?
        public var trueColour: Int?
        /// nil = by layer.
        public var lineType: String?
        /// Millimetres; nil = by layer.
        public var lineWeight: Double?
        public var lineTypeScale: Double
        public init(colourIndex: Int? = nil, trueColour: Int? = nil, lineType: String? = nil, lineWeight: Double? = nil, lineTypeScale: Double = 1) {
            self.colourIndex = colourIndex; self.trueColour = trueColour; self.lineType = lineType
            self.lineWeight = lineWeight; self.lineTypeScale = lineTypeScale
        }
    }

    /// Where a text's insertion point sits on the text (DXF groups 72/73 and MTEXT's attachment point).
    public enum TextAlign: String, Codable, Sendable {
        case topLeft, topCentre, topRight, middleLeft, middleCentre, middleRight, bottomLeft, bottomCentre, bottomRight
        case baselineLeft, baselineCentre, baselineRight
    }

    /// One family of parallel hatch lines, already scaled and rotated as the DXF stores it: lines pass through
    /// `base + k × offset` along `angle` (degrees); `dashes` are positive dash / negative gap / zero dot (empty = solid line).
    public struct HatchLine: Hashable, Codable, Sendable {
        public var angle: Double
        public var base: Point3
        public var offset: Point3
        public var dashes: [Double]
        public init(angle: Double, base: Point3, offset: Point3, dashes: [Double] = []) {
            self.angle = angle; self.base = base; self.offset = offset; self.dashes = dashes
        }
    }

    public indirect enum Entity: Hashable, Codable, Sendable {
        case line(Point3, Point3, layer: String)
        case polyline([Point3], closed: Bool, bulges: [Double], layer: String)
        case circle(centre: Point3, radius: Double, layer: String)
        case arc(centre: Point3, radius: Double, startAngle: Double, endAngle: Double, layer: String)
        case ellipse(centre: Point3, majorAxis: Point3, ratio: Double, startParameter: Double, endParameter: Double, layer: String)
        case spline(degree: Int, controlPoints: [Point3], knots: [Double], weights: [Double], layer: String)
        /// Rotation in degrees. `widthFactor` multiplies the style's.
        case text(String, at: Point3, height: Double, rotation: Double, style: String, align: TextAlign = .baselineLeft,
                  widthFactor: Double = 1, layer: String)
        /// MTEXT with its formatting codes; `attachment` is DXF's 1–9 attachment point, `width` 0 for no wrapping.
        case multilineText(String, at: Point3, height: Double, width: Double, rotation: Double = 0, attachment: Int = 1,
                           style: String, layer: String)
        case insert(block: String, at: Point3, scale: Point3, rotation: Double, layer: String)
        case hatch(loops: [[Point3]], pattern: String, solid: Bool, patternLines: [HatchLine] = [], layer: String)
        case point(Point3, layer: String)
        case solid([Point3], layer: String)
        case image(path: String, at: Point3, size: VectorSize, layer: String)
        /// A paper-space window onto model space: `centre`/`width`/`height` on the sheet, `viewCentre`/`viewHeight` in model units.
        case viewport(centre: Point3, width: Double, height: Double, viewCentre: Point3, viewHeight: Double, layer: String)
        /// An entity with its own colour, linetype or lineweight.
        case styled(Entity, Appearance)
    }

    public struct Block: Hashable, Codable, Sendable {
        public var name: String
        public var base: Point3
        public var entities: [Entity]
        public init(name: String, base: Point3 = Point3(0, 0), entities: [Entity] = []) {
            self.name = name; self.base = base; self.entities = entities
        }
    }

    public struct Layout: Hashable, Codable, Sendable {
        public var name: String
        /// Millimetres.
        public var paperSize: VectorSize?
        public var entities: [Entity]
        public init(name: String, paperSize: VectorSize? = nil, entities: [Entity] = []) {
            self.name = name; self.paperSize = paperSize; self.entities = entities
        }
    }

    public var unit: Unit
    public var layers: [Layer]
    public var lineTypes: [LineType]
    public var textStyles: [TextStyle]
    /// The drawing's global linetype scale ($LTSCALE).
    public var lineTypeScale: Double
    public var blocks: [Block]
    public var modelSpace: [Entity]
    public var layouts: [Layout]
    /// The AutoCAD version the source was written in ("AC1027").
    public var sourceVersion: String?

    public init(unit: Unit = .unitless, layers: [Layer] = [], lineTypes: [LineType] = [], textStyles: [TextStyle] = [],
                lineTypeScale: Double = 1, blocks: [Block] = [], modelSpace: [Entity] = [],
                layouts: [Layout] = [], sourceVersion: String? = nil) {
        self.unit = unit; self.layers = layers; self.lineTypes = lineTypes; self.textStyles = textStyles
        self.lineTypeScale = lineTypeScale; self.blocks = blocks; self.modelSpace = modelSpace
        self.layouts = layouts; self.sourceVersion = sourceVersion
    }
}
