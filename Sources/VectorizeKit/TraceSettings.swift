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
    /// Squares smaller than this side (px) are merged into their neighbours (0–128).
    public var filterSpeckle: Int
    /// Bits kept per colour channel when clustering (1–8).
    public var colourPrecision: Int
    /// Extra outline simplification in pixels (0–10); 0 is off.
    public var simplify: Double
    /// Whether `filterSpeckle` and `colourPrecision` were given: given values override the preset's, as vtracer's
    /// command-line flags do; otherwise a named preset uses its own (vtracer `config.rs`) and `auto` the O-TRACE defaults.
    let speckleGiven: Bool, precisionGiven: Bool

    public init(preset: TracePreset = .auto, colours: Int? = nil, mode: TraceMode = .spline, filterSpeckle: Int? = nil,
                colourPrecision: Int? = nil, simplify: Double = 0) {
        self.preset = preset
        self.colours = colours.map { min(max($0, 2), 64) }
        self.mode = mode
        self.filterSpeckle = min(max(filterSpeckle ?? 4, 0), 128)
        self.colourPrecision = min(max(colourPrecision ?? 6, 1), 8)
        self.simplify = min(max(simplify, 0), 10)
        speckleGiven = filterSpeckle != nil
        precisionGiven = colourPrecision != nil
    }

    /// Reads the option keys of the O-TRACE profile; anything absent keeps its default.
    public init(_ options: OptionValues) {
        self.init(preset: options["preset"]?.string.flatMap(TracePreset.init(rawValue:)) ?? .auto,
                  colours: options["colours"]?.int,
                  mode: options["mode"]?.string.flatMap(TraceMode.init(rawValue:)) ?? .spline,
                  filterSpeckle: options["filterSpeckle"]?.int,
                  colourPrecision: options["colourPrecision"]?.int,
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

// Adapted from vtracer cmdapp/src/config.rs (MIT, 0.6.15, commit fd9cdb08e622f237eb05be553a020ddc9e4c47a1).
// Copyright (c) 2024 TSANG, Hao Fung. See THIRD_PARTY_NOTICES.md.
// What changed: the preset table is vtracer's; O-TRACE values that were given (formats §5) override the preset's
// filter_speckle and color_precision the way vtracer's command-line flags override a preset; `mode` is always the
// O-TRACE one (every preset uses spline, its default); `simplify` lengthens the smoothing segments and loosens the polygon
// penalty (an O-TRACE addition: 0 keeps vtracer's own values).
/// vtracer's converter configuration (`ConverterConfig`), angles in radians.
struct TraceConfig {
    var binary: Bool
    var filterSpeckleArea: Int
    var colourPrecisionLoss: Int
    var layerDifference: Int
    var mode: PathSimplifyMode
    var cornerThreshold: Double
    var lengthThreshold: Double
    var maxIterations: Int
    var spliceThreshold: Double
    /// `PathSimplify::limit_penalties` tolerance (1 px upstream).
    var penaltyTolerance: Double

    init(preset: TracePreset, settings: TraceSettings) {
        // Per preset: colour mode, filter_speckle, color_precision, layer_difference, corner_threshold (degrees); `auto`
        // resolves before this, and an unresolved one gets vtracer's `Config::default` (the O-TRACE defaults). Shared:
        // length_threshold 4, max_iterations 10, splice_threshold 45°, path_precision 2.
        let table: (binary: Bool, speckle: Int, precision: Int, layerDifference: Int, corner: Int) = switch preset {
        case .bw: (true, 4, 6, 16, 60)
        case .poster: (false, 4, 8, 16, 60)
        case .photo: (false, 10, 8, 48, 180)
        case .auto: (false, 4, 6, 16, 60)
        }
        binary = table.binary
        layerDifference = table.layerDifference
        cornerThreshold = Double(table.corner) / 180 * .pi
        let speckle = settings.speckleGiven ? settings.filterSpeckle : table.speckle
        filterSpeckleArea = speckle * speckle
        colourPrecisionLoss = 8 - (settings.precisionGiven ? settings.colourPrecision : table.precision)
        mode = switch settings.mode { case .spline: .spline; case .polygon: .polygon; case .pixel: .none }
        lengthThreshold = 4 + settings.simplify
        maxIterations = 10
        spliceThreshold = 45.0 / 180 * .pi
        penaltyTolerance = 1 + settings.simplify
    }
}
