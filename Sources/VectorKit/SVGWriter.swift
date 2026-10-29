import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore

/// VectorDocument → SVG 1.1 (one page). Coordinates stay in the model's points (the viewBox is in points, the size in
/// CSS pixels), y flipped to SVG's downward axis. Text stays text with its font family; embedded font programs travel
/// as `@font-face` data.
public enum SVGWriter {
    public static func write(_ document: VectorDocument, options: VectorWriteOptions) throws -> VectorWriteResult {
        var doc = document
        var notes: [LossNote] = []
        if options.textAsOutlines, doc.containsText { doc = doc.outlinedText(); notes.append(LossNote(.textAsOutlines)) }
        guard let page = doc.pages.first else { throw ConversionError.failed("There are no pages to write.") }
        var w = Emitter(height: page.size.height)
        let body = w.nodes(page.nodes)
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" version=\"1.1\" "
        out += "width=\"\(fmt(page.size.width / 0.75))\" height=\"\(fmt(page.size.height / 0.75))\" viewBox=\"0 0 \(fmt(page.size.width)) \(fmt(page.size.height))\">\n"
        if let title = doc.title ?? options.title { out += "<title>\(escape(title))</title>\n" }
        if !w.fontFaces.isEmpty { out += "<style>\n" + w.fontFaces.joined(separator: "\n") + "\n</style>\n" }
        if !w.defs.isEmpty { out += "<defs>\n" + w.defs.joined(separator: "\n") + "\n</defs>\n" }
        if let bg = page.background {
            out += "<rect width=\"\(fmt(page.size.width))\" height=\"\(fmt(page.size.height))\" \(paintAttrs("fill", .solid(bg), id: nil))/>\n"
        }
        out += body
        out += "</svg>\n"
        return VectorWriteResult(data: Data(out.utf8), lossNotes: notes)
    }

    static func fmt(_ v: Double) -> String {
        if !v.isFinite { return "0" }
        let rounded = (v * 10000).rounded() / 10000
        if rounded == rounded.rounded(), abs(rounded) < 1e15 { return String(Int64(rounded)) }
        var s = String(format: "%.4f", rounded)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func hex(_ c: VectorColour) -> String {
        func b(_ v: Double) -> Int { Int(max(0, min(255, (v * 255).rounded()))) }
        return String(format: "#%02x%02x%02x", b(c.red), b(c.green), b(c.blue))
    }

    /// `fill="#abc" fill-opacity="0.5"` for a solid paint, or a `url(#id)` reference when the paint was registered.
    static func paintAttrs(_ name: String, _ paint: VectorPaint?, id: String?) -> String {
        guard let paint else { return "\(name)=\"none\"" }
        switch paint {
        case .solid(let c):
            var s = "\(name)=\"\(hex(c))\""
            if c.alpha < 0.9999 { s += " \(name)-opacity=\"\(fmt(c.alpha))\"" }
            return s
        default:
            return id.map { "\(name)=\"url(#\($0))\"" } ?? "\(name)=\"none\""
        }
    }

    struct Emitter {
        let height: Double
        var defs: [String] = []
        var fontFaces: [String] = []
        var seed = 0
        var faces: Set<String> = []

        init(height: Double) { self.height = height }

        var flip: VectorTransform { VectorTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height) }

        mutating func nextID(_ prefix: String) -> String { seed += 1; return "\(prefix)\(seed)" }

        func pt(_ p: VectorPoint) -> String { "\(SVGWriter.fmt(p.x)) \(SVGWriter.fmt(height - p.y))" }

        func pathData(_ segments: [PathSegment]) -> String {
            var d = ""
            for s in segments {
                switch s {
                case .move(let p): d += "M\(pt(p))"
                case .line(let p): d += "L\(pt(p))"
                case .cubic(let a, let b, let c): d += "C\(pt(a)) \(pt(b)) \(pt(c))"
                case .quad(let a, let b): d += "Q\(pt(a)) \(pt(b))"
                case .close: d += "Z"
                }
            }
            return d
        }

        func matrix(_ t: VectorTransform) -> String {
            "matrix(\(SVGWriter.fmt(t.a)) \(SVGWriter.fmt(t.b)) \(SVGWriter.fmt(t.c)) \(SVGWriter.fmt(t.d)) \(SVGWriter.fmt(t.tx)) \(SVGWriter.fmt(t.ty)))"
        }

        /// Registers a gradient in `<defs>` and returns its id.
        mutating func gradient(_ paint: VectorPaint) -> String? {
            let id = nextID("g")
            func stopsXML(_ stops: [GradientStop]) -> String {
                stops.map { s in
                    var x = "<stop offset=\"\(SVGWriter.fmt(s.offset))\" stop-color=\"\(SVGWriter.hex(s.colour))\""
                    if s.colour.alpha < 0.9999 { x += " stop-opacity=\"\(SVGWriter.fmt(s.colour.alpha))\"" }
                    return x + "/>"
                }.joined()
            }
            switch paint {
            case .linear(let a, let b, let stops):
                let p0 = pt(a).split(separator: " "), p1 = pt(b).split(separator: " ")
                defs.append("<linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(p0[0])\" y1=\"\(p0[1])\" x2=\"\(p1[0])\" y2=\"\(p1[1])\">\(stopsXML(stops))</linearGradient>")
            case .radial(let c, let r, let stops):
                let p = pt(c).split(separator: " ")
                defs.append("<radialGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(p[0])\" cy=\"\(p[1])\" r=\"\(SVGWriter.fmt(r))\">\(stopsXML(stops))</radialGradient>")
            default: return nil
            }
            return id
        }

        mutating func nodes(_ list: [VectorNode]) -> String { list.map { node($0) }.joined() }

        mutating func node(_ n: VectorNode) -> String {
            switch n {
            case .path(let segments, let fill, let stroke, let rule):
                var attrs = "d=\"\(pathData(segments))\""
                var prefix = ""
                if let fill {
                    if case .rasterised(let asset) = fill { prefix = rasterFill(segments, asset); attrs += " fill=\"none\"" }
                    else { attrs += " " + SVGWriter.paintAttrs("fill", fill, id: gradient(fill)) }
                } else { attrs += " fill=\"none\"" }
                if rule == .evenOdd { attrs += " fill-rule=\"evenodd\"" }
                if let stroke {
                    attrs += " " + SVGWriter.paintAttrs("stroke", stroke.paint, id: gradient(stroke.paint))
                    attrs += " stroke-width=\"\(SVGWriter.fmt(stroke.width))\""
                    if stroke.cap != .butt { attrs += " stroke-linecap=\"\(stroke.cap.rawValue)\"" }
                    if stroke.join != .miter { attrs += " stroke-linejoin=\"\(stroke.join.rawValue)\"" }
                    else if stroke.miterLimit != 4 { attrs += " stroke-miterlimit=\"\(SVGWriter.fmt(stroke.miterLimit))\"" }
                    if !stroke.dash.isEmpty { attrs += " stroke-dasharray=\"\(stroke.dash.map(SVGWriter.fmt).joined(separator: " "))\"" }
                    if stroke.dashPhase != 0 { attrs += " stroke-dashoffset=\"\(SVGWriter.fmt(stroke.dashPhase))\"" }
                }
                return prefix + "<path \(attrs)/>\n"
            case .text(let run):
                return text(run)
            case .image(let asset, let t):
                guard let png = asset.frames.first?.pngData() else { return "" }
                let m = VectorTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1).then(t).then(flip)
                return "<image width=\"1\" height=\"1\" preserveAspectRatio=\"none\" transform=\"\(matrix(m))\" xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/>\n"
            case .group(let children, let t, let clip, let opacity):
                var attrs = ""
                if !t.isIdentity { attrs += " transform=\"\(matrix(flip.then(t).then(flip)))\"" }
                if let clip {
                    let id = nextID("c")
                    defs.append("<clipPath id=\"\(id)\"><path d=\"\(pathData(clip))\"/></clipPath>")
                    attrs += " clip-path=\"url(#\(id))\""
                }
                if opacity < 0.9999 { attrs += " opacity=\"\(SVGWriter.fmt(opacity))\"" }
                let inner = nodes(children)
                return attrs.isEmpty ? inner : "<g\(attrs)>\n\(inner)</g>\n"
            }
        }

        mutating func rasterFill(_ segments: [PathSegment], _ asset: ImageAsset) -> String {
            guard let png = asset.frames.first?.pngData() else { return "" }
            let box = segments.cgPath.boundingBoxOfPath
            let id = nextID("c")
            defs.append("<clipPath id=\"\(id)\"><path d=\"\(pathData(segments))\"/></clipPath>")
            return "<image clip-path=\"url(#\(id))\" x=\"\(SVGWriter.fmt(Double(box.minX)))\" y=\"\(SVGWriter.fmt(height - Double(box.maxY)))\" width=\"\(SVGWriter.fmt(Double(box.width)))\" height=\"\(SVGWriter.fmt(Double(box.height)))\" preserveAspectRatio=\"none\" xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/>\n"
        }

        mutating func text(_ run: VectorTextRun) -> String {
            let font = VectorDrawing.font(named: run.fontName, size: run.size)
            var family = CTFontCopyFamilyName(font) as String
            let traits = CTFontGetSymbolicTraits(font)
            var attrs = "x=\"\(SVGWriter.fmt(run.origin.x))\" y=\"\(SVGWriter.fmt(height - run.origin.y))\" font-size=\"\(SVGWriter.fmt(run.size))\""
            if let data = run.fontData, !faces.contains(run.fontName) {
                faces.insert(run.fontName)
                fontFaces.append("@font-face{font-family:\"\(SVGWriter.escape(run.fontName))\";src:url(data:font/ttf;base64,\(data.base64EncodedString())) format(\"truetype\");}")
            }
            if run.fontData != nil { family = run.fontName }
            attrs += " font-family=\"\(SVGWriter.escape(family))\""
            if traits.contains(.traitBold) { attrs += " font-weight=\"bold\"" }
            if traits.contains(.traitItalic) { attrs += " font-style=\"italic\"" }
            attrs += " " + SVGWriter.paintAttrs("fill", run.fill, id: gradient(run.fill))
            return "<text \(attrs) xml:space=\"preserve\">\(SVGWriter.escape(run.text))</text>\n"
        }
    }
}
