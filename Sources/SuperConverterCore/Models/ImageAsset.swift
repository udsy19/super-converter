import Foundation

/// A raster image: one or more frames (animation, multi-page TIFF, ICO sizes) with their colour and metadata.
/// ImageKit decodes into it and encodes from it; RenderKit produces it from pages; the pipeline operates on it.
public struct ImageAsset: Hashable, Codable, Sendable {
    public var frames: [ImageFrame]
    public var metadata: ImageMetadata
    /// Animation loop count (0 = forever); nil for stills.
    public var loopCount: Int?

    public init(frames: [ImageFrame], metadata: ImageMetadata = ImageMetadata(), loopCount: Int? = nil) {
        self.frames = frames; self.metadata = metadata; self.loopCount = loopCount
    }

    public var isAnimated: Bool { frames.count > 1 && frames.contains { $0.delay != nil } }
    public var hasAlpha: Bool { frames.contains { $0.hasAlpha } }
}

public struct ImageFrame: Hashable, Codable, Sendable {
    public enum Pixels: Hashable, Codable, Sendable {
        /// Un-premultiplied RGBA, 16-bit float per channel, in the frame's own colour space (quality §2.1).
        case rgbaHalf(Data, bytesPerRow: Int)
        /// 8-bit RGBA, un-premultiplied.
        case rgba8(Data, bytesPerRow: Int)
        /// Decoded lazily from a file in the work folder (large sources, frames of long animations).
        case file(URL)
    }

    public var width: Int
    public var height: Int
    public var pixels: Pixels
    public var hasAlpha: Bool
    /// The embedded ICC profile, byte for byte; nil when untagged (quality §2.2 says what untagged means).
    public var iccProfile: Data?
    /// Colour model of the source ("RGB", "Gray", "CMYK", "Lab").
    public var colourModel: String
    public var bitsPerComponent: Int
    /// Frame delay in seconds for animations.
    public var delay: TimeInterval?
    /// EXIF orientation 1–8 still to be applied; 1 once applied.
    public var orientation: Int

    public init(width: Int, height: Int, pixels: Pixels, hasAlpha: Bool, iccProfile: Data? = nil, colourModel: String = "RGB",
                bitsPerComponent: Int = 8, delay: TimeInterval? = nil, orientation: Int = 1) {
        self.width = width; self.height = height; self.pixels = pixels; self.hasAlpha = hasAlpha
        self.iccProfile = iccProfile; self.colourModel = colourModel; self.bitsPerComponent = bitsPerComponent
        self.delay = delay; self.orientation = orientation
    }
}

/// Photo details (EXIF, IPTC, XMP, GPS) kept as the source wrote them, so they can be copied or stripped (quality §2.6).
public struct ImageMetadata: Hashable, Codable, Sendable {
    public var exif: Data?
    public var iptc: Data?
    public var xmp: Data?
    public var hasGPS: Bool
    public var creationDate: Date?

    public init(exif: Data? = nil, iptc: Data? = nil, xmp: Data? = nil, hasGPS: Bool = false, creationDate: Date? = nil) {
        self.exif = exif; self.iptc = iptc; self.xmp = xmp; self.hasGPS = hasGPS; self.creationDate = creationDate
    }
}
