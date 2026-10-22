import Foundation

/// Vector graphics: pages of drawing nodes in points (1/72 in), y up. VectorKit reads PDF, SVG, EMF, WMF into it and writes
/// them back out; RenderKit rasterises it; CADKit plots into it.
public struct VectorDocument: Hashable, Codable, Sendable {
    public var pages: [VectorPage]
    public var title: String?

    public init(pages: [VectorPage], title: String? = nil) { self.pages = pages; self.title = title }
}

public struct VectorPage: Hashable, Codable, Sendable {
    public var size: VectorSize
    public var background: VectorColour?
    public var nodes: [VectorNode]

    public init(size: VectorSize, background: VectorColour? = nil, nodes: [VectorNode] = []) {
        self.size = size; self.background = background; self.nodes = nodes
    }
}

public struct VectorSize: Hashable, Codable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

public struct VectorPoint: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// 2×3 affine transform [a b c d tx ty].
public struct VectorTransform: Hashable, Codable, Sendable {
    public var a = 1.0, b = 0.0, c = 0.0, d = 1.0, tx = 0.0, ty = 0.0
    public static let identity = VectorTransform()
    public init() {}
    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }
}

public struct VectorColour: Hashable, Codable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    /// ICC profile name or "sRGB" when the source declared one.
    public var space: String
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1, space: String = "sRGB") {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha; self.space = space
    }
}

public enum PathSegment: Hashable, Codable, Sendable {
    case move(VectorPoint)
    case line(VectorPoint)
    case cubic(VectorPoint, VectorPoint, VectorPoint)
    case quad(VectorPoint, VectorPoint)
    case close
}

public struct GradientStop: Hashable, Codable, Sendable {
    public var offset: Double
    public var colour: VectorColour
    public init(offset: Double, colour: VectorColour) { self.offset = offset; self.colour = colour }
}

public enum VectorPaint: Hashable, Codable, Sendable {
    case solid(VectorColour)
    case linear(from: VectorPoint, to: VectorPoint, stops: [GradientStop])
    case radial(centre: VectorPoint, radius: Double, stops: [GradientStop])
    /// A tiling pattern or mesh the reader could not express; written rasterised, with a loss note.
    case rasterised(ImageAsset)
}

public struct VectorStroke: Hashable, Codable, Sendable {
    public var paint: VectorPaint
    public var width: Double
    public var dash: [Double]
    public var round: Bool
    public init(paint: VectorPaint, width: Double, dash: [Double] = [], round: Bool = false) {
        self.paint = paint; self.width = width; self.dash = dash; self.round = round
    }
}

public struct VectorTextRun: Hashable, Codable, Sendable {
    public var text: String
    public var fontName: String
    public var size: Double
    public var origin: VectorPoint
    public var fill: VectorPaint
    /// Embedded font program (subset), when the source had one.
    public var fontData: Data?
    public init(text: String, fontName: String, size: Double, origin: VectorPoint, fill: VectorPaint, fontData: Data? = nil) {
        self.text = text; self.fontName = fontName; self.size = size; self.origin = origin; self.fill = fill; self.fontData = fontData
    }
}

public indirect enum VectorNode: Hashable, Codable, Sendable {
    case path([PathSegment], fill: VectorPaint?, stroke: VectorStroke?)
    case text(VectorTextRun)
    case image(ImageAsset, transform: VectorTransform)
    /// A group with a transform, an optional clip path and an opacity.
    case group([VectorNode], transform: VectorTransform, clip: [PathSegment]?, opacity: Double)
}
