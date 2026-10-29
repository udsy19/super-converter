import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SuperConverterCore

/// PostScript Level 3 and EPS 3.0 (formats §3.2, `PSWriter`): DSC-conforming files with vector pages from the vector
/// model or raster pages from a picture. Vector pages keep paths with their exact stroke geometry (widths, caps, joins,
/// miter limits, dashes with phase; quality §6), fill rules, clips, gradients as shading dictionaries and text as
/// embedded Type 42 fonts (or outlines with "Text as outlines", O-VEC). PostScript has no transparency, so a see-through
/// object is the one thing rasterised: that object and what lies under it become a picture at the render density, with a
/// loss note. EPS holds one page and may carry a TIFF preview in a DOS EPS binary header (O-VEC `epsPreview`, O-IMG+PS
/// `preview`).
public enum PSWriter {
    /// VectorDocument → PostScript (every page) or EPS (the first page; the converter selects it).
    public static func write(_ document: VectorDocument, options: VectorWriteOptions, eps: Bool) throws -> VectorWriteResult {
        var doc = document
        var notes: [LossNote] = []
        if options.textAsOutlines, doc.containsText { doc = doc.outlinedText(); notes.append(LossNote(.textAsOutlines)) }
        if eps, doc.pages.count > 1 { doc.pages = [doc.pages[0]] }
        guard !doc.pages.isEmpty else { throw ConversionError.failed("There are no pages to write.") }
        let fonts = PSFonts()
        var bodies: [String] = []
        var flattened = 0, outlinedFonts: Set<String> = []
        for page in doc.pages {
            var emitter = PageEmitter(fonts: fonts)
            if let background = page.background {
                emitter.out += "\(rgb(background)) setrgbcolor 0 0 \(fmt(page.size.width)) \(fmt(page.size.height)) rectfill\n"
            }
            for (i, node) in page.nodes.enumerated() {
                if node.isTranslucent {
                    if emitter.flatten(page, through: i, density: options.density) { flattened += 1 }
                } else {
                    emitter.node(node)
                }
            }
            outlinedFonts.formUnion(emitter.outlinedFonts)
            bodies.append(emitter.out)
        }
        if flattened > 0 {
            notes.append(LossNote(.layersFlattened, detail: "PostScript has no transparency: \(flattened) see-through \(flattened == 1 ? "object became a picture" : "objects became pictures") at \(Int(options.density)) dpi"))
        }
        if !outlinedFonts.isEmpty {
            notes.append(LossNote(.textAsOutlines, detail: "Fonts without TrueType outlines were drawn as shapes: \(outlinedFonts.sorted().joined(separator: ", "))"))
        }
        let ps = file(pages: zip(doc.pages.map(\.size), bodies).map { ($0, $1) }, title: doc.title ?? options.title, eps: eps,
                          level: 3, setup: fonts.resources(), supplied: fonts.fonts.map(\.resourceName))
        guard eps, options.epsPreview, let image = VectorDrawing.render(doc.pages[0], scale: 1), let tiff = PSImages.tiff(image) else {
            return VectorWriteResult(data: Data(ps.utf8), lossNotes: notes)
        }
        return VectorWriteResult(data: dosEPS(Data(ps.utf8), tiff: tiff), lossNotes: notes)
    }

    /// ImageAsset → PostScript (a page per frame) or EPS (the first frame), with the O-IMG+PS options: `level` 2 or 3,
    /// `encoding` flate or jpeg (a JPEG source passes through), `preview` none or tiff; page geometry as image → PDF
    /// (O-IMG-PDF `pageSize`, `margin`, `orientation`).
    public static func write(image asset: ImageAsset, options: OptionValues, eps: Bool, title: String?) throws -> VectorWriteResult {
        let level = options["level"]?.string == "2" ? 2 : 3
        let encoding: PSImages.Encoding = options["encoding"]?.string == "jpeg" ? .jpeg : .flate
        var notes: [LossNote] = []
        let frames = eps ? Array(asset.frames.indices.prefix(1)) : Array(asset.frames.indices)
        if eps, asset.frames.count > 1 {
            notes.append(LossNote(.otherLoss, detail: "EPS holds one page; frame 1 of \(asset.frames.count) was written."))
        }
        var pages: [(VectorSize, String)] = []
        var preview: CGImage?
        for index in frames {
            guard let image = ImageBridge.cgImage(asset, frame: index) else { continue }
            let (size, rect) = ImagePage.layout(width: image.width, height: image.height, options: options)
            guard let paint = PSImages.paint(image, level: level, encoding: encoding, jpeg: passThroughJPEG(asset.frames[index]), tagged: true) else { continue }
            let body = "gsave\n[\(fmt(Double(rect.width))) 0 0 \(fmt(Double(rect.height))) \(fmt(Double(rect.minX))) \(fmt(Double(rect.minY)))] concat\n" + paint + "grestore\n"
            pages.append((size, body))
            if preview == nil { preview = image }
        }
        guard !pages.isEmpty else { throw ConversionError.failed("There’s no picture to write.") }
        if asset.hasAlpha { notes.append(LossNote(.transparencyFilled)) }
        let ps = file(pages: pages, title: title, eps: eps, level: level, setup: "", supplied: [])
        guard eps, options["preview"]?.string == "tiff", let preview, let tiff = PSImages.tiff(preview) else {
            return VectorWriteResult(data: Data(ps.utf8), lossNotes: notes)
        }
        return VectorWriteResult(data: dosEPS(Data(ps.utf8), tiff: tiff), lossNotes: notes)
    }

    // MARK: File structure

    /// The DSC file around the page bodies (Adobe DSC 3.0, EPSF 3.0).
    static func file(pages: [(VectorSize, String)], title: String?, eps: Bool, level: Int, setup: String, supplied: [String]) -> String {
        let width = pages.map(\.0.width).max() ?? 0, height = pages.map(\.0.height).max() ?? 0
        var out = eps ? "%!PS-Adobe-3.0 EPSF-3.0\n" : "%!PS-Adobe-3.0\n"
        out += "%%Creator: Super Converter\n"
        if let title, !title.isEmpty { out += "%%Title: \(psString(title))\n" }
        out += "%%BoundingBox: 0 0 \(Int(width.rounded(.up))) \(Int(height.rounded(.up)))\n"
        out += "%%HiResBoundingBox: 0 0 \(fmt(width)) \(fmt(height))\n"
        out += "%%LanguageLevel: \(level)\n%%DocumentData: Clean7Bit\n%%Pages: \(pages.count)\n"
        if !supplied.isEmpty { out += "%%DocumentSuppliedResources: " + supplied.map { "font \($0)" }.joined(separator: "\n%%+ ") + "\n" }
        out += "%%EndComments\n%%BeginProlog\n%%EndProlog\n%%BeginSetup\n" + setup + "%%EndSetup\n"
        for (n, (size, body)) in pages.enumerated() {
            out += "%%Page: \(n + 1) \(n + 1)\n%%PageBoundingBox: 0 0 \(Int(size.width.rounded(.up))) \(Int(size.height.rounded(.up)))\n"
            // EPS must not set the page device: the program that places it owns the page.
            if !eps { out += "%%BeginPageSetup\n<< /PageSize [\(fmt(size.width)) \(fmt(size.height))] >> setpagedevice\n%%EndPageSetup\n" }
            out += "gsave\n" + body + "grestore\nshowpage\n"
        }
        out += "%%Trailer\n%%EOF\n"
        return out
    }

    /// The DOS EPS binary header (EPSF 3.0 §5.2): PostScript section, then a TIFF preview; no WMF section, no checksum.
    static func dosEPS(_ ps: Data, tiff: Data) -> Data {
        var header = Data([0xC5, 0xD0, 0xD3, 0xC6])
        func le32(_ v: Int) { for k in 0..<4 { header.append(UInt8(truncatingIfNeeded: v >> (8 * k))) } }
        le32(30); le32(ps.count); le32(0); le32(0); le32(30 + ps.count); le32(tiff.count)
        header.append(contentsOf: [0xFF, 0xFF])
        return header + ps + tiff
    }

    /// The JPEG bytes of a frame read lazily from an RGB JPEG file, to embed unchanged.
    static func passThroughJPEG(_ frame: ImageFrame) -> Data? {
        guard case .file(let url) = frame.pixels, ["jpg", "jpeg", "jfif"].contains(url.pathExtension.lowercased()),
              let data = try? Data(contentsOf: url), let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              image.colorSpace?.model == .rgb else { return nil }
        return data
    }

    // MARK: Values

    static func fmt(_ v: Double) -> String { SVGWriter.fmt(v) }

    static func rgb(_ c: VectorColour) -> String { "\(fmt(clamp(c.red))) \(fmt(clamp(c.green))) \(fmt(clamp(c.blue)))" }

    private static func clamp(_ v: Double) -> Double { max(0, min(1, v)) }

    /// A PostScript string literal: printable ASCII as is, `\`, `(`, `)` escaped, everything else as octal UTF-8 bytes.
    static func psString(_ s: String) -> String {
        var out = "("
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "\\"), UInt8(ascii: "("), UInt8(ascii: ")"): out += "\\" + String(UnicodeScalar(byte))
            case 32...126: out += String(UnicodeScalar(byte))
            default: out += "\\" + String(format: "%03o", byte)
            }
        }
        return out + ")"
    }

    /// A shading function over the stops (PLRM 4.9.1, 3.10): one exponential (Type 2) between two colours, or a stitching
    /// (Type 3) function of exponentials when there are more; stops not at 0 or 1 hold their colour to the ends.
    static func function(_ stops: [GradientStop]) -> String? {
        var list = stops.sorted { $0.offset < $1.offset }.map { GradientStop(offset: clamp($0.offset), colour: $0.colour) }
        guard let first = list.first, let last = list.last else { return nil }
        if first.offset > 0 { list.insert(GradientStop(offset: 0, colour: first.colour), at: 0) }
        if last.offset < 1 || list.count == 1 { list.append(GradientStop(offset: 1, colour: last.colour)) }
        func exponential(_ a: VectorColour, _ b: VectorColour) -> String {
            "<< /FunctionType 2 /Domain [0 1] /C0 [\(rgb(a))] /C1 [\(rgb(b))] /N 1 >>"
        }
        if list.count == 2 { return exponential(list[0].colour, list[1].colour) }
        let parts = zip(list, list.dropFirst()).map { exponential($0.colour, $1.colour) }
        let bounds = list.dropFirst().dropLast().map { fmt($0.offset) }.joined(separator: " ")
        let encode = Array(repeating: "0 1", count: parts.count).joined(separator: " ")
        return "<< /FunctionType 3 /Domain [0 1] /Functions [\(parts.joined(separator: " "))] /Bounds [\(bounds)] /Encode [\(encode)] >>"
    }

    /// `shfill` for a gradient paint (PLRM 4.9.3: ShadingType 2 axial, 3 radial), in the current user space.
    static func shading(_ paint: VectorPaint) -> String? {
        switch paint {
        case .linear(let from, let to, let stops):
            guard let f = function(stops) else { return nil }
            return "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [\(fmt(from.x)) \(fmt(from.y)) \(fmt(to.x)) \(fmt(to.y))] /Extend [true true] /Function \(f) >> shfill\n"
        case .radial(let c, let r, let stops):
            guard r > 0, let f = function(stops) else { return nil }
            return "<< /ShadingType 3 /ColorSpace /DeviceRGB /Coords [\(fmt(c.x)) \(fmt(c.y)) 0 \(fmt(c.x)) \(fmt(c.y)) \(fmt(r))] /Extend [true true] /Function \(f) >> shfill\n"
        default:
            return nil
        }
    }

    // MARK: Pages

    /// One page's content stream in the model's coordinates (points, y up: PostScript's default user space).
    struct PageEmitter {
        let fonts: PSFonts
        var out = ""
        var outlinedFonts: Set<String> = []

        init(fonts: PSFonts) { self.fonts = fonts }

        mutating func node(_ node: VectorNode) {
            switch node {
            case .path(let segments, let fill, let stroke, let rule):
                path(segments, fill: fill, stroke: stroke, rule: rule)
            case .text(let run):
                text(run)
            case .image(let asset, let t):
                guard let image = ImageBridge.cgImage(asset), let paint = PSImages.paint(image, level: 3, encoding: .flate, tagged: false) else { return }
                out += "gsave\n\(matrix(t)) concat\n" + paint + "grestore\n"
            case .group(let children, let t, let clip, _):
                if let clip, clip.isEmpty { return }
                out += "gsave\n"
                if !t.isIdentity { out += "\(matrix(t)) concat\n" }
                if let clip { out += "newpath\n" + construct(clip) + "clip newpath\n" }
                for child in children { self.node(child) }
                out += "grestore\n"
            }
        }

        func matrix(_ t: VectorTransform) -> String {
            "[\([t.a, t.b, t.c, t.d, t.tx, t.ty].map(PSWriter.fmt).joined(separator: " "))]"
        }

        /// Path construction operators; quadratic segments become the equivalent cubics.
        func construct(_ segments: [PathSegment]) -> String {
            var s = "", current = VectorPoint(0, 0), start = current, open = false
            func p(_ v: VectorPoint) -> String { "\(PSWriter.fmt(v.x)) \(PSWriter.fmt(v.y))" }
            for segment in segments {
                switch segment {
                case .move(let a): s += "\(p(a)) moveto\n"; current = a; start = a; open = true
                case .line(let a):
                    s += open ? "\(p(a)) lineto\n" : "\(p(a)) moveto\n"; current = a; open = true
                case .cubic(let a, let b, let c):
                    guard open else { continue }
                    s += "\(p(a)) \(p(b)) \(p(c)) curveto\n"; current = c
                case .quad(let q, let c):
                    guard open else { continue }
                    let c1 = VectorPoint(current.x + 2 / 3 * (q.x - current.x), current.y + 2 / 3 * (q.y - current.y))
                    let c2 = VectorPoint(c.x + 2 / 3 * (q.x - c.x), c.y + 2 / 3 * (q.y - c.y))
                    s += "\(p(c1)) \(p(c2)) \(p(c)) curveto\n"; current = c
                case .close:
                    guard open else { continue }
                    s += "closepath\n"; current = start
                }
            }
            return s
        }

        mutating func path(_ segments: [PathSegment], fill: VectorPaint?, stroke: VectorStroke?, rule: FillRule) {
            let drawsStroke = stroke.map { $0.width > 0 } ?? false
            guard !segments.isEmpty, fill != nil || drawsStroke else { return }
            out += "newpath\n" + construct(segments)
            let even = rule == .evenOdd
            if let fill {
                switch fill {
                case .solid(let c):
                    out += "gsave \(PSWriter.rgb(c)) setrgbcolor \(even ? "eofill" : "fill") grestore\n"
                case .linear, .radial:
                    if let sh = PSWriter.shading(fill) { out += "gsave \(even ? "eoclip" : "clip") newpath\n" + sh + "grestore\n" }
                case .rasterised(let asset):
                    out += "gsave \(even ? "eoclip" : "clip") newpath\n" + picture(asset, in: segments.cgPath.boundingBoxOfPath) + "grestore\n"
                }
            }
            if let stroke, drawsStroke {
                out += "gsave \(PSWriter.fmt(stroke.width)) setlinewidth "
                out += "\(stroke.cap == .round ? 1 : stroke.cap == .square ? 2 : 0) setlinecap "
                out += "\(stroke.join == .round ? 1 : stroke.join == .bevel ? 2 : 0) setlinejoin "
                out += "\(PSWriter.fmt(max(1, stroke.miterLimit))) setmiterlimit"
                let dash = stroke.dash.map { max(0, $0) }
                if dash.contains(where: { $0 > 0 }) { out += " [\(dash.map(PSWriter.fmt).joined(separator: " "))] \(PSWriter.fmt(stroke.dashPhase)) setdash" }
                out += "\n"
                switch stroke.paint {
                case .solid(let c): out += "\(PSWriter.rgb(c)) setrgbcolor stroke\n"
                case .linear, .radial:
                    if let sh = PSWriter.shading(stroke.paint) { out += "strokepath clip newpath\n" + sh }
                case .rasterised(let asset):
                    let box = segments.cgPath.boundingBoxOfPath.insetBy(dx: -stroke.width, dy: -stroke.width)
                    out += "strokepath clip newpath\n" + picture(asset, in: box)
                }
                out += "grestore\n"
            }
            out += "newpath\n"
        }

        /// A picture stretched over `box` (a rasterised paint, as VectorDrawing paints it); nothing when it can't be read.
        func picture(_ asset: ImageAsset, in box: CGRect) -> String {
            guard !box.isNull, let image = ImageBridge.cgImage(asset), let paint = PSImages.paint(image, level: 3, encoding: .flate, tagged: false) else { return "" }
            return "[\(PSWriter.fmt(Double(box.width))) 0 0 \(PSWriter.fmt(Double(box.height))) \(PSWriter.fmt(Double(box.minX))) \(PSWriter.fmt(Double(box.minY)))] concat\n" + paint
        }

        /// Text as `glyphshow` of Type 42 glyphs at CoreText's positions; a font without TrueType outlines is drawn as
        /// filled outlines instead.
        mutating func text(_ run: VectorTextRun) {
            let font = VectorDrawing.font(for: run)
            let attributes: [CFString: Any] = [kCTFontAttributeName: font]
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, run.text as CFString, attributes as CFDictionary))
            var shown = ""
            for ctRun in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                let count = CTRunGetGlyphCount(ctRun)
                guard count > 0 else { continue }
                var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(ctRun, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(ctRun, CFRange(location: 0, length: 0), &positions)
                let runFont = ((CTRunGetAttributes(ctRun) as? [CFString: Any])?[kCTFontAttributeName]).map { $0 as! CTFont } ?? font
                let psName = CTFontCopyPostScriptName(runFont) as String
                let embedded = run.fontData != nil && psName == (CTFontCopyPostScriptName(font) as String)
                let key = embedded ? "\(psName)#\(run.fontData!.hashValue)" : psName
                guard let name = fonts.use(runFont, key: key, glyphs: glyphs) else {
                    outlinedFonts.insert(psName)
                    let outline = VectorOutlines.glyphPaths(run)
                    if case .path(let segments, let fill, _, _) = outline { path(segments, fill: fill, stroke: nil, rule: .nonZero) }
                    return
                }
                shown += "/\(name) findfont \(PSWriter.fmt(Double(CTFontGetSize(runFont)))) scalefont setfont\n"
                for i in 0..<count {
                    shown += "\(PSWriter.fmt(run.origin.x + Double(positions[i].x))) \(PSWriter.fmt(run.origin.y + Double(positions[i].y))) moveto /g\(glyphs[i]) glyphshow\n"
                }
            }
            guard !shown.isEmpty else { return }
            let colour: VectorColour
            switch run.fill {
            case .solid(let c): colour = c
            case .linear(_, _, let stops), .radial(_, _, let stops): colour = stops.first?.colour ?? .black
            case .rasterised: colour = .black
            }
            out += "gsave \(PSWriter.rgb(colour)) setrgbcolor\n" + shown + "grestore\n"
        }

        /// Paints the page's nodes 0…`index` within the bounds of node `index` as one opaque picture at `density`: the
        /// see-through object flattened onto what lies under it. False when the node has no visible area.
        mutating func flatten(_ page: VectorPage, through index: Int, density: Double) -> Bool {
            let pageRect = CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height)
            guard let bounds = page.nodes[index].bounds?.insetBy(dx: -1, dy: -1).intersection(pageRect), !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return false }
            let scale = max(density, 36) / 72
            // Snapped to the pixel grid of the render density.
            let x0 = (bounds.minX * scale).rounded(.down) / scale, y0 = (bounds.minY * scale).rounded(.down) / scale
            let w = max(1, Int(((bounds.maxX - x0) * scale).rounded(.up))), h = max(1, Int(((bounds.maxY - y0) * scale).rounded(.up)))
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -x0, y: -y0)
            if let background = page.background {
                ctx.setFillColor(background.cg)
                ctx.fill(pageRect)
            }
            for node in page.nodes[0...index] { VectorDrawing.draw(node, in: ctx) }
            guard let image = ctx.makeImage(), let paint = PSImages.paint(image, level: 3, encoding: .flate, tagged: false) else { return false }
            let pw = Double(w) / scale, ph = Double(h) / scale
            out += "gsave\n[\(PSWriter.fmt(pw)) 0 0 \(PSWriter.fmt(ph)) \(PSWriter.fmt(x0)) \(PSWriter.fmt(y0))] concat\n" + paint + "grestore\n"
            return true
        }
    }
}

extension VectorNode {
    /// Whether drawing the node needs transparency (group opacity, translucent colours or pictures with alpha), which
    /// PostScript cannot express.
    var isTranslucent: Bool {
        func paint(_ p: VectorPaint?) -> Bool {
            switch p {
            case .solid(let c): c.alpha < 0.999
            case .linear(_, _, let stops), .radial(_, _, let stops): stops.contains { $0.colour.alpha < 0.999 }
            case .rasterised(let asset): asset.hasAlpha
            case nil: false
            }
        }
        switch self {
        case .path(_, let fill, let stroke, _): return paint(fill) || paint(stroke?.paint)
        case .text(let run): return paint(run.fill)
        case .image(let asset, _): return asset.hasAlpha
        case .group(let children, _, _, let opacity): return opacity < 0.999 || children.contains(where: \.isTranslucent)
        }
    }
}
