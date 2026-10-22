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

    public indirect enum Entity: Hashable, Codable, Sendable {
        case line(Point3, Point3, layer: String)
        case polyline([Point3], closed: Bool, bulges: [Double], layer: String)
        case circle(centre: Point3, radius: Double, layer: String)
        case arc(centre: Point3, radius: Double, startAngle: Double, endAngle: Double, layer: String)
        case ellipse(centre: Point3, majorAxis: Point3, ratio: Double, startParameter: Double, endParameter: Double, layer: String)
        case spline(degree: Int, controlPoints: [Point3], knots: [Double], weights: [Double], layer: String)
        case text(String, at: Point3, height: Double, rotation: Double, style: String, layer: String)
        case multilineText(String, at: Point3, height: Double, width: Double, style: String, layer: String)
        case insert(block: String, at: Point3, scale: Point3, rotation: Double, layer: String)
        case hatch(loops: [[Point3]], pattern: String, solid: Bool, layer: String)
        case point(Point3, layer: String)
        case solid([Point3], layer: String)
        case image(path: String, at: Point3, size: VectorSize, layer: String)
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
        public var paperSize: VectorSize?
        public var entities: [Entity]
        public init(name: String, paperSize: VectorSize? = nil, entities: [Entity] = []) {
            self.name = name; self.paperSize = paperSize; self.entities = entities
        }
    }

    public var unit: Unit
    public var layers: [Layer]
    public var blocks: [Block]
    public var modelSpace: [Entity]
    public var layouts: [Layout]
    /// The AutoCAD version the source was written in ("AC1027").
    public var sourceVersion: String?

    public init(unit: Unit = .unitless, layers: [Layer] = [], blocks: [Block] = [], modelSpace: [Entity] = [],
                layouts: [Layout] = [], sourceVersion: String? = nil) {
        self.unit = unit; self.layers = layers; self.blocks = blocks; self.modelSpace = modelSpace
        self.layouts = layouts; self.sourceVersion = sourceVersion
    }
}
