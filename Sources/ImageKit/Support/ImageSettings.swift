import CoreGraphics
import Foundation
import SuperConverterCore

/// The O-IMG options (formats §5) resolved for one conversion. `OptionValues` stores only what the person changed, so every
/// absent key falls back to the per-target default of quality §2.3 here (the profile's own defaults cannot say "JPG 90,
/// HEIC 85, AVIF 80").
struct ImageSettings: Sendable {
    enum Size: Equatable, Sendable { case original, percent(Double), box(width: Int?, height: Int?) }
    enum Fit: String, Sendable { case max, crop, scale, pad }
    enum Background: Equatable, Sendable {
        case transparent
        /// sRGB components 0…1.
        case colour(Double, Double, Double)
    }
    enum Profile: Equatable, Sendable { case keep, srgb, displayP3, adobeRGB, proPhoto, gray, cmyk, custom(URL) }
    enum Intent: String, Sendable { case relative, perceptual }
    enum BitDepth: Equatable, Sendable { case keep, eight, sixteen }
    enum MetadataPolicy: String, Sendable { case all, allButLocation, none }
    enum Dither: String, Sendable { case floydSteinberg, ordered, none }
    enum TIFFCompression: String, Sendable { case lzw, zip, none, jpeg }
    enum WhiteBalance: Equatable, Sendable { case asShot, auto, kelvin(Double) }

    var size: Size = .original
    var fit: Fit = .max
    var background: Background = .colour(1, 1, 1)
    var profile: Profile = .keep
    var intent: Intent = .relative
    var bitDepth: BitDepth = .keep
    var metadata: MetadataPolicy = .all
    var autoRotate = true
    /// The "Pages" text ("1-3,5"); nil or empty keeps every page and frame.
    var pages: String?
    /// 1…100; nil means the target's default (quality §2.3).
    var quality: Int?
    var lossless: Bool?
    var progressive = true
    var gifColours = 256
    var dither: Dither = .floydSteinberg
    /// GIF/WebP loop count: 0 forever, 1 once; nil keeps the source's.
    var loopCount: Int?
    /// Icon entry sizes in pixels; nil means every size the target holds.
    var iconSizes: [Int]?
    var tiffCompression: TIFFCompression = .lzw
    var multiPage = true
    // RAW development (quality §2.5)
    var whiteBalance: WhiteBalance = .asShot
    var exposure: Double = 0
    var neutralLook = false
    var lensCorrection = true
    var noiseReductionAuto = true

    init() {}

    init(_ options: OptionValues) {
        if let s = options["size"]?.string, s != "original", s != "custom", let p = Double(s) { size = .percent(p / 100) }
        let width = options["width"]?.int, height = options["height"]?.int
        if width != nil || height != nil { size = .box(width: width, height: height) }
        if let f = options["fit"]?.string, let fit = Fit(rawValue: f) { self.fit = fit }
        if let b = options["background"]?.string { background = Self.parseColour(b) ?? .colour(1, 1, 1) }
        switch options["colourProfile"]?.string {
        case "srgb": profile = .srgb
        case "displayP3": profile = .displayP3
        case "adobeRGB": profile = .adobeRGB
        case "proPhoto": profile = .proPhoto
        case "gray": profile = .gray
        case "cmyk": profile = .cmyk
        case "custom": if let path = options["iccProfilePath"]?.string { profile = .custom(URL(fileURLWithPath: path)) }
        default: break
        }
        if let i = options["renderingIntent"]?.string, let intent = Intent(rawValue: i) { self.intent = intent }
        switch options["bitDepth"]?.string { case "8": bitDepth = .eight; case "16": bitDepth = .sixteen; default: break }
        if let m = options["metadata"]?.string, let policy = MetadataPolicy(rawValue: m) { metadata = policy }
        if options["strip"]?.bool == true { metadata = .none }
        if let r = options["autoRotate"]?.bool { autoRotate = r }
        pages = options["pages"]?.string
        if let q = options["quality"]?.int { quality = min(max(q, 1), 100) }
        lossless = options["lossless"]?.bool
        if let p = options["progressive"]?.bool { progressive = p }
        if let c = options["colours"]?.int { gifColours = min(max(c, 2), 256) }
        if let d = options["dither"]?.string, let dither = Dither(rawValue: d) { self.dither = dither }
        switch options["loop"]?.string { case "once": loopCount = 1; case "forever": loopCount = 0; default: break }
        if let n = options["loop"]?.int { loopCount = max(n, 0) }
        if let s = options["sizes"]?.string, s != "all" {
            let sizes = s.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Int($0) }.filter { $0 > 0 }
            if !sizes.isEmpty { iconSizes = sizes }
        }
        if let c = options["compression"]?.string, let compression = TIFFCompression(rawValue: c) { tiffCompression = compression }
        if let m = options["multiPage"]?.bool { multiPage = m }
        switch options["rawWhiteBalance"]?.string {
        case "auto": whiteBalance = .auto
        case "kelvin": whiteBalance = .kelvin(options["rawKelvin"]?.double ?? 5500)
        default: break
        }
        if let e = options["rawExposure"]?.double { exposure = min(max(e, -4), 4) }
        neutralLook = options["rawLook"]?.string == "neutral"
        if let l = options["rawLensCorrection"]?.bool { lensCorrection = l }
        if let n = options["rawNoiseReduction"]?.string { noiseReductionAuto = n != "off" }
    }

    /// "#RRGGBB", "#RGB", "#RRGGBBAA" (alpha 0 = transparent) or "transparent".
    static func parseColour(_ text: String) -> Background? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "transparent" || t == "none" || t == "clear" { return .transparent }
        var hex = t.hasPrefix("#") ? String(t.dropFirst()) : t
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let v = UInt64(hex, radix: 16) else { return nil }
        if hex.count == 8, v & 0xFF == 0 { return .transparent }
        let rgb = hex.count == 8 ? v >> 8 : v
        return .colour(Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255)
    }

    /// The pages/frames to keep out of `count` (all when the text selects none).
    func pageIndices(count: Int) -> [Int] {
        let selected = PageSelection.indices(pages, pageCount: count)
        return selected.isEmpty ? Array(0..<count) : selected
    }

    /// The encoder quality 1…100 for a target (quality §2.3 defaults).
    func quality(for target: TargetKind) -> Int {
        if let quality { return quality }
        switch target {
        case .heic: return 85
        case .avif: return 80
        default: return 90
        }
    }
}
