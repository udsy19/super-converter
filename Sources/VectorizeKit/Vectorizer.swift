import Foundation
import SuperConverterCore

/// Raster → SVG (formats §3.2): colour clustering, stacked layers (each layer also covers every colour painted above it, so
/// regions never leave seams), pixel-edge outlines fitted with curves, polygons or left on the pixel grid.
public enum Vectorizer {
    public static func trace(_ image: ImageAsset, settings: TraceSettings, progress: @Sendable (Double) -> Void = { _ in },
                             isCancelled: @Sendable () -> Bool = { false }) throws -> TraceResult {
        let raster = try PixelSource.decode(image)
        let w = raster.width, h = raster.height
        let bits = settings.colourPrecision

        var preset = settings.preset
        if preset == .auto {
            let survey = Quantizer.survey(raster, bits: bits)
            preset = survey.distinct <= 2 && survey.dominantLuminance > 0.9 ? .bw : survey.distinct <= 16 ? .poster : .photo
        }
        var quantized: Quantized
        switch preset {
        case .bw, .auto: quantized = Quantizer.blackAndWhite(raster)
        case .poster: quantized = Quantizer.medianCut(raster, size: settings.colours ?? 16, bits: bits, isCancelled: isCancelled)
        case .photo: quantized = Quantizer.medianCut(raster, size: settings.colours ?? 64, bits: bits, isCancelled: isCancelled)
        }
        if isCancelled() { throw ConversionError.cancelled }
        Quantizer.removeSpecks(&quantized, limit: settings.filterSpeckle, isCancelled: isCancelled)
        if isCancelled() { throw ConversionError.cancelled }
        progress(0.1)

        // Which labels are drawn, and in what order: bw draws the dark class alone; otherwise largest area first.
        var area = [Int](repeating: 0, count: quantized.palette.count)
        for l in quantized.labels where l >= 0 { area[Int(l)] += 1 }
        let stacked = preset != .bw
        let order: [Int] = preset == .bw ? (area[0] > 0 ? [0] : [])
            : area.indices.filter { area[$0] > 0 }.sorted { (area[$1], $0) < (area[$0], $1) }
        var rank = [Int](repeating: -1, count: area.count)
        for (i, label) in order.enumerated() { rank[label] = i }

        let tracer = ContourTracer(width: w, height: h)
        var body = ""
        var paths = 0
        var mask = [UInt8](repeating: 0, count: w * h)
        for (i, label) in order.enumerated() {
            if isCancelled() { throw ConversionError.cancelled }
            for p in 0..<(w * h) {
                let l = quantized.labels[p]
                mask[p] = l >= 0 && (stacked ? rank[Int(l)] >= i : Int(l) == label) ? 1 : 0
            }
            let loops = tracer.trace(mask, isCancelled: isCancelled)
            if isCancelled() { throw ConversionError.cancelled }
            var d = ""
            for loop in loops where loop.count >= 4 {
                switch settings.mode {
                case .pixel: d += OutlineWriter.pixelPath(loop)
                case .polygon: d += OutlineWriter.polygonPath(loop, tolerance: 0.5 + 0.4 * settings.simplify)
                case .spline: d += OutlineWriter.splinePath(loop, tolerance: 0.35, simplification: settings.simplify)
                }
            }
            if !d.isEmpty {
                let c = quantized.palette[label]
                body += String(format: "<path fill=\"#%02x%02x%02x\" fill-rule=\"evenodd\" d=\"", c.r, c.g, c.b) + d + "\"/>\n"
                paths += 1
            }
            progress(0.1 + 0.9 * Double(i + 1) / Double(max(order.count, 1)))
        }
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" width=\"\(w)\" height=\"\(h)\" viewBox=\"0 0 \(w) \(h)\">\n" + body + "</svg>\n"
        return TraceResult(svg: Data(svg.utf8), width: w, height: h, pathCount: paths, colourCount: order.count, preset: preset)
    }
}
