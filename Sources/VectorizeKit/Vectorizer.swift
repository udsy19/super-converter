// Adapted from vtracer cmdapp/src/converter.rs and cmdapp/src/svg.rs (MIT, 0.6.15, commit
// fd9cdb08e622f237eb05be553a020ddc9e4c47a1). Copyright (c) 2024 TSANG, Hao Fung. See THIRD_PARTY_NOTICES.md.
// What changed: the key colour for transparency is chosen deterministically (vtracer tries random colours after its six
// special ones); pixels under half opacity count as transparent, and as background in black-and-white mode (vtracer
// thresholds red alone); `auto` picks the preset from the picture (formats §5); the `colours` option caps the palette by
// a weighted median cut of the layer colours; consecutive layers of one colour share a `<path>`; coordinates are absolute.
import Foundation
import SuperConverterCore

/// Raster → SVG (formats §3.2): vtracer's hierarchical colour clustering with stacked layers (each layer also covers every
/// layer above it, so regions never leave seams), outlines walked along pixel edges and written as splines, polygons or
/// left on the pixel grid.
public enum Vectorizer {
    /// The fraction of pixels in the sampled rows that must be transparent before transparency is keyed out.
    private static let keyingThreshold = 0.2

    public static func trace(_ image: ImageAsset, settings: TraceSettings, progress: @Sendable (Double) -> Void = { _ in },
                             isCancelled: @Sendable () -> Bool = { false }) throws -> TraceResult {
        let raster = try PixelSource.decode(image)
        let w = raster.width, h = raster.height
        let preset = settings.preset == .auto ? choosePreset(raster, bits: settings.colourPrecision) : settings.preset
        let config = TraceConfig(preset: preset, settings: settings)
        var layers: [(colour: (r: Int, g: Int, b: Int), area: Int, paths: [OutlinePath])] = []
        if config.binary {
            var bits = BinaryImage(width: w, height: h)
            for p in 0..<(w * h) where raster.rgba[p * 4 + 3] >= 128 && raster.rgba[p * 4] < 128 { bits.bits[p] = true }
            if isCancelled() { throw ConversionError.cancelled }
            progress(0.1)
            let pieces = bits.clusters(diagonal: false)
            for (n, piece) in pieces.enumerated() where piece.points.count >= config.filterSpeckleArea {
                if isCancelled() { throw ConversionError.cancelled }
                layers.append(((0, 0, 0), piece.points.count, piece.compoundPath(mode: config.mode, config: config)))
                progress(0.1 + 0.9 * Double(n + 1) / Double(pieces.count))
            }
        } else {
            var pixels = raster.rgba
            let key = shouldKey(pixels, w, h) ? unusedColour(pixels) : nil
            if let key {
                for p in 0..<(w * h) where pixels[p * 4 + 3] < 128 {
                    pixels[p * 4] = key.r; pixels[p * 4 + 1] = key.g; pixels[p * 4 + 2] = key.b; pixels[p * 4 + 3] = 255
                }
            }
            var clusters = ColorClusters(pixels: pixels, width: w, height: h, config: ColorClusters.Config(
                diagonal: config.layerDifference == 0, goodMinArea: config.filterSpeckleArea, goodMaxArea: w * h,
                sameShift: config.colourPrecisionLoss, deepenDiff: config.layerDifference, key: key))
            try clusters.run(progress: progress, isCancelled: isCancelled)
            let order = Array(clusters.output.reversed())
            for (n, index) in order.enumerated() {
                if isCancelled() { throw ConversionError.cancelled }
                let c = clusters.clusters[index].residueColour
                layers.append(((Int(c.r), Int(c.g), Int(c.b)), clusters.clusters[index].area, clusters.compoundPath(index, mode: config.mode, config: config)))
                progress(0.9 + 0.1 * Double(n + 1) / Double(order.count))
            }
        }
        if let cap = settings.colours {
            let palette = capPalette(layers.map { ($0.colour, $0.area) }, to: cap)
            for i in layers.indices { layers[i].colour = palette[i] }
        }
        // svg.rs: one path per layer, bottom first; consecutive layers of one colour are written as one path.
        var body = ""
        var paths = 0
        var colours = Set<Int>()
        var i = 0
        while i < layers.count {
            let c = layers[i].colour
            var d = ""
            while i < layers.count, layers[i].colour == c { d += layers[i].paths.map(\.svg).joined(); i += 1 }
            guard !d.isEmpty else { continue }
            body += String(format: "<path fill=\"#%02x%02x%02x\" fill-rule=\"evenodd\" d=\"", c.r, c.g, c.b) + d + "\"/>\n"
            paths += 1
            colours.insert(c.r << 16 | c.g << 8 | c.b)
        }
        progress(1)
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\">\n" + body + "</svg>\n"
        return TraceResult(svg: Data(svg.utf8), width: w, height: h, pathCount: paths, colourCount: colours.count, preset: preset)
    }

    // MARK: Presets

    /// formats §5 O-TRACE: two colours, both grey with one light and one dark → bw; up to 16 → poster; else photo. Colours
    /// are counted at the clustering precision over pixels at least half opaque.
    static func choosePreset(_ raster: Raster, bits: Int) -> TracePreset {
        let shift = UInt8(8 - bits)
        var seen = Set<Int>()
        var greys: [Int] = []
        for p in 0..<(raster.width * raster.height) where raster.rgba[p * 4 + 3] >= 128 {
            let r = raster.rgba[p * 4], g = raster.rgba[p * 4 + 1], b = raster.rgba[p * 4 + 2]
            if seen.insert(Int(r >> shift) << 16 | Int(g >> shift) << 8 | Int(b >> shift)).inserted {
                if max(r, g, b) - min(r, g, b) <= 16 { greys.append((Int(r) + Int(g) + Int(b)) / 3) }
                if seen.count > 16 { return .photo }
            }
        }
        if seen.count <= 2, greys.count == seen.count, greys.contains(where: { $0 >= 128 }), seen.count == 1 || greys.contains(where: { $0 < 128 }) { return .bw }
        return .poster
    }

    // MARK: Keying (converter.rs)

    /// Whether enough of the sampled rows (top, quarters, middle, bottom) is transparent to key transparency out.
    private static func shouldKey(_ px: [UInt8], _ w: Int, _ h: Int) -> Bool {
        guard w > 0, h > 0 else { return false }
        let threshold = Int(Double(w * 2) * keyingThreshold)
        var transparent = 0
        for y in [0, h / 4, h / 2, 3 * h / 4, h - 1] {
            for x in 0..<w where px[(y * w + x) * 4 + 3] < 128 {
                transparent += 1
                if transparent >= threshold { return true }
            }
        }
        return false
    }

    /// A colour the picture doesn't use: vtracer's six special colours, then a fixed sequence instead of random ones.
    private static func unusedColour(_ px: [UInt8]) -> ColorClusters.RGBA? {
        var used = Set<Int>()
        for p in stride(from: 0, to: px.count, by: 4) { used.insert(Int(px[p]) << 16 | Int(px[p + 1]) << 8 | Int(px[p + 2])) }
        let special = [0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0x00FFFF, 0xFF00FF]
        var state: UInt32 = 0x9E3779B9
        let sequence = (0..<4096).map { _ -> Int in state = state &* 1664525 &+ 1013904223; return Int(state >> 8) & 0xFFFFFF }
        guard let v = (special + sequence).first(where: { !used.contains($0) }) else { return nil }
        return ColorClusters.RGBA(r: UInt8(v >> 16), g: UInt8(v >> 8 & 255), b: UInt8(v & 255), a: 255)
    }

    // MARK: Palette cap

    /// At most `cap` colours: the layer colours split by weighted median cut (by area), each box its weighted mean.
    static func capPalette(_ items: [(colour: (r: Int, g: Int, b: Int), area: Int)], to cap: Int) -> [(r: Int, g: Int, b: Int)] {
        let distinct = Set(items.map { $0.colour.r << 16 | $0.colour.g << 8 | $0.colour.b })
        guard distinct.count > cap else { return items.map(\.colour) }
        func channel(_ i: Int, _ c: Int) -> Int { c == 0 ? items[i].colour.r : c == 1 ? items[i].colour.g : items[i].colour.b }
        var boxes: [[Int]] = [Array(items.indices)]
        while boxes.count < cap {
            // Split the box with the widest channel range at its weighted median.
            var best: (box: Int, channel: Int, range: Int)?
            for (b, box) in boxes.enumerated() where Set(box.map { items[$0].colour.r << 16 | items[$0].colour.g << 8 | items[$0].colour.b }).count > 1 {
                for c in 0..<3 {
                    let values = box.map { channel($0, c) }
                    let range = (values.max() ?? 0) - (values.min() ?? 0)
                    if best == nil || range > best!.range { best = (b, c, range) }
                }
            }
            guard let best else { break }
            let sorted = boxes[best.box].sorted { (channel($0, best.channel), $0) < (channel($1, best.channel), $1) }
            let total = sorted.reduce(0) { $0 + items[$1].area }
            var running = 0, cut = 1
            for (k, i) in sorted.enumerated() { running += items[i].area; if running * 2 >= total { cut = k + 1; break } }
            cut = min(max(cut, 1), sorted.count - 1)
            boxes[best.box] = Array(sorted[..<cut])
            boxes.append(Array(sorted[cut...]))
        }
        var out = items.map(\.colour)
        for box in boxes {
            let weight = max(box.reduce(0) { $0 + items[$1].area }, 1)
            let mean = (0..<3).map { c in (box.reduce(0) { $0 + channel($1, c) * items[$1].area } + weight / 2) / weight }
            for i in box { out[i] = (mean[0], mean[1], mean[2]) }
        }
        return out
    }
}
