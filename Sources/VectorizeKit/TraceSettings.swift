import Foundation
import SuperConverterCore

/// How a picture is quantised (formats §5, O-TRACE).
public enum TracePreset: String, Sendable { case auto, bw, poster, photo }

/// How region outlines are written.
public enum TraceMode: String, Sendable { case spline, polygon, pixel }

/// The O-TRACE options.
public struct TraceSettings: Sendable, Equatable {
    public var preset: TracePreset
    /// Palette size 2–64; nil lets the preset choose.
    public var colours: Int?
    public var mode: TraceMode
    /// Regions smaller than this many pixels are merged into their neighbours (0–128).
    public var filterSpeckle: Int
    /// Bits kept per colour channel when clustering (1–8).
    public var colourPrecision: Int
    /// Extra outline simplification in pixels (0–10); 0 is off.
    public var simplify: Double

    public init(preset: TracePreset = .auto, colours: Int? = nil, mode: TraceMode = .spline, filterSpeckle: Int = 4,
                colourPrecision: Int = 6, simplify: Double = 0) {
        self.preset = preset
        self.colours = colours.map { min(max($0, 2), 64) }
        self.mode = mode
        self.filterSpeckle = min(max(filterSpeckle, 0), 128)
        self.colourPrecision = min(max(colourPrecision, 1), 8)
        self.simplify = min(max(simplify, 0), 10)
    }

    /// Reads the option keys of the O-TRACE profile; anything absent keeps its default.
    public init(_ options: OptionValues) {
        self.init(preset: options["preset"]?.string.flatMap(TracePreset.init(rawValue:)) ?? .auto,
                  colours: options["colours"]?.int,
                  mode: options["mode"]?.string.flatMap(TraceMode.init(rawValue:)) ?? .spline,
                  filterSpeckle: options["filterSpeckle"]?.int ?? 4,
                  colourPrecision: options["colourPrecision"]?.int ?? 6,
                  simplify: options["simplify"]?.double ?? 0)
    }
}

/// A finished trace.
public struct TraceResult: Sendable {
    public var svg: Data
    public var width: Int
    public var height: Int
    public var pathCount: Int
    public var colourCount: Int
    /// The preset that ran (what `auto` resolved to).
    public var preset: TracePreset
}
