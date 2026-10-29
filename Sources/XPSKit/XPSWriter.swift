import CoreGraphics
import Foundation
import SuperConverterCore
import VectorKit

/// VectorDocument → XPS package (formats §3.2): one FixedPage per page; paths with solid, gradient and picture brushes,
/// groups as canvases, pictures as PNG parts, text as Glyphs over embedded obfuscated fonts (text without a font program
/// becomes outlines).
public enum XPSWriter {
    public static func write(_ document: VectorDocument, options: VectorWriteOptions) throws -> VectorWriteResult {
        let doc = document   // ConverterSupport.writer has already applied the page selection
        guard !doc.pages.isEmpty else { throw ConversionError.failed("There are no pages to write.") }
        var notes: Set<LossNote> = []
        let package = XPSPackageBuilder()
        var pageParts: [String] = []
        for (index, original) in doc.pages.enumerated() {
            var page = original
            page.nodes = page.nodes.map { convertText($0, force: options.textAsOutlines, notes: &notes) }
            let name = "/Documents/1/Pages/\(index + 1).fpage"
            var writer = XPSPageWriter(page: page, package: package)
            let (xml, resources) = writer.write()
            package.add(name, Data(xml.utf8))
            if !resources.isEmpty {
                var rels = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                for (i, target) in resources.enumerated() {
                    rels += "<Relationship Id=\"R\(i + 1)\" Type=\"http://schemas.microsoft.com/xps/2005/06/required-resource\" Target=\"\(target)\"/>"
                }
                package.add("/Documents/1/Pages/_rels/\(index + 1).fpage.rels", Data((rels + "</Relationships>").utf8))
            }
            pageParts.append(name)
        }
        package.finish(pages: pageParts, doc: doc)
        return VectorWriteResult(data: package.zip.finish(), lossNotes: notes.sorted { $0.detail < $1.detail })
    }

    /// Text runs the package cannot carry (no font program, or outlines asked for) become glyph outlines.
    static func convertText(_ node: VectorNode, force: Bool, notes: inout Set<LossNote>) -> VectorNode {
        switch node {
        case .text(let run):
            if !force, run.fontData != nil { return node }
            notes.insert(LossNote(.textAsOutlines, detail: force ? "" : "Text without an embedded font"))
            return VectorOutlines.glyphPaths(run)
        case .group(let kids, let t, let clip, let o):
            return .group(kids.map { convertText($0, force: force, notes: &notes) }, transform: t, clip: clip, opacity: o)
        default: return node
        }
    }
}

final class XPSPackageBuilder {
    var zip = ZipWriter()
    var imageParts: [ImageAsset: String] = [:]
    var fontParts: [Data: String] = [:]

    func add(_ name: String, _ data: Data) { zip.add(String(name.dropFirst()), data) }

    func imagePart(_ asset: ImageAsset) -> String? {
        if let hit = imageParts[asset] { return hit }
        guard let png = ImageBridge.pngData(asset) else { return nil }
        let name = "/Resources/Images/\(imageParts.count + 1).png"
        add(name, png)
        imageParts[asset] = name
        return name
    }

    func fontPart(_ data: Data) -> String {
        if let hit = fontParts[data] { return hit }
        let guid = UUID().uuidString
        let name = "/Resources/Fonts/\(guid).odttf"
        let key = XPSSyntax.obfuscationKey(partName: name) ?? Array(repeating: 0, count: 16)
        add(name, XPSSyntax.xorFont(data, key: key))
        fontParts[data] = name
        return name
    }

    /// The structural parts, written last so every resource is known.
    func finish(pages: [String], doc: VectorDocument) {
        let types = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="fdseq" ContentType="application/vnd.ms-package.xps-fixeddocumentsequence+xml"/><Default Extension="fdoc" ContentType="application/vnd.ms-package.xps-fixeddocument+xml"/><Default Extension="fpage" ContentType="application/vnd.ms-package.xps-fixedpage+xml"/><Default Extension="png" ContentType="image/png"/><Default Extension="odttf" ContentType="application/vnd.ms-package.obfuscated-opentype"/></Types>
        """
        add("/[Content_Types].xml", Data(types.utf8))
        add("/_rels/.rels", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="R0" Type="http://schemas.microsoft.com/xps/2005/06/fixedrepresentation" Target="/FixedDocumentSequence.fdseq"/></Relationships>
        """.utf8))
        add("/FixedDocumentSequence.fdseq", Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <FixedDocumentSequence xmlns="http://schemas.microsoft.com/xps/2005/06"><DocumentReference Source="/Documents/1/FixedDocument.fdoc"/></FixedDocumentSequence>
        """.utf8))
        var fdoc = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<FixedDocument xmlns=\"http://schemas.microsoft.com/xps/2005/06\">"
        for (page, p) in Swift.zip(pages, doc.pages) {
            fdoc += "<PageContent Source=\"\(page)\" Width=\"\(XPSPageWriter.fmt(p.size.width / 0.75))\" Height=\"\(XPSPageWriter.fmt(p.size.height / 0.75))\"/>"
        }
        add("/Documents/1/FixedDocument.fdoc", Data((fdoc + "</FixedDocument>").utf8))
    }
}

struct XPSPageWriter {
    let page: VectorPage
    let package: XPSPackageBuilder
    var resources: [String] = []
    /// Model (points, y up, local) → XPS (px, y down).
    let f: VectorTransform

    init(page: VectorPage, package: XPSPackageBuilder) {
        self.page = page
        self.package = package
        f = VectorTransform(a: 4.0 / 3, b: 0, c: 0, d: -4.0 / 3, tx: 0, ty: page.size.height * 4.0 / 3)
    }

    static func fmt(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        let r = (v * 10000).rounded() / 10000
        if r == r.rounded(), abs(r) < 1e15 { return String(Int64(r)) }
        var s = String(format: "%.4f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func colour(_ c: VectorColour) -> String {
        func b(_ v: Double) -> Int { Int(max(0, min(255, (v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X%02X", b(c.alpha), b(c.red), b(c.green), b(c.blue))
    }

    func pt(_ p: VectorPoint) -> String { let q = f.apply(p); return "\(Self.fmt(q.x)),\(Self.fmt(q.y))" }

    func data(_ segments: [PathSegment], rule: FillRule) -> String {
        var d = rule == .nonZero ? "F1 " : "F0 "
        for s in segments {
            switch s {
            case .move(let p): d += "M \(pt(p)) "
            case .line(let p): d += "L \(pt(p)) "
            case .cubic(let a, let b, let c): d += "C \(pt(a)) \(pt(b)) \(pt(c)) "
            case .quad(let a, let b): d += "Q \(pt(a)) \(pt(b)) "
            case .close: d += "Z "
            }
        }
        return d.trimmingCharacters(in: .whitespaces)
    }

    func matrix(_ t: VectorTransform) -> String { [t.a, t.b, t.c, t.d, t.tx, t.ty].map(Self.fmt).joined(separator: ",") }

    mutating func resource(_ name: String) { if !resources.contains(name) { resources.append(name) } }

    func firstColour(_ p: VectorPaint) -> VectorColour? {
        switch p {
        case .solid(let c): return c
        case .linear(_, _, let s), .radial(_, _, let s): return s.first?.colour
        case .rasterised: return nil
        }
    }

    /// `(attribute, element)` for a paint: a colour attribute, or a property element holding the brush.
    mutating func brush(_ owner: String, _ prop: String, _ paint: VectorPaint, bounds: CGRect) -> (String, String) {
        func stops(_ s: [GradientStop]) -> String {
            s.map { "<GradientStop Color=\"\(Self.colour($0.colour))\" Offset=\"\(Self.fmt($0.offset))\"/>" }.joined()
        }
        switch paint {
        case .solid(let c): return (" \(prop)=\"\(Self.colour(c))\"", "")
        case .linear(let a, let b, let s):
            return ("", "<\(owner).\(prop)><LinearGradientBrush MappingMode=\"Absolute\" StartPoint=\"\(pt(a))\" EndPoint=\"\(pt(b))\"><LinearGradientBrush.GradientStops>\(stops(s))</LinearGradientBrush.GradientStops></LinearGradientBrush></\(owner).\(prop)>")
        case .radial(let c, let r, let s):
            let px = r * 4.0 / 3
            return ("", "<\(owner).\(prop)><RadialGradientBrush MappingMode=\"Absolute\" Center=\"\(pt(c))\" GradientOrigin=\"\(pt(c))\" RadiusX=\"\(Self.fmt(px))\" RadiusY=\"\(Self.fmt(px))\"><RadialGradientBrush.GradientStops>\(stops(s))</RadialGradientBrush.GradientStops></RadialGradientBrush></\(owner).\(prop)>")
        case .rasterised(let asset):
            guard let frame = asset.frames.first, let part = package.imagePart(asset) else { return ("", "") }
            resource(part)
            let box = bounds.applying(f.cg)
            return ("", "<\(owner).\(prop)><ImageBrush ImageSource=\"\(part)\" Viewbox=\"0,0,\(frame.width),\(frame.height)\" Viewport=\"\(Self.fmt(box.minX)),\(Self.fmt(box.minY)),\(Self.fmt(box.width)),\(Self.fmt(box.height))\" ViewboxUnits=\"Absolute\" ViewportUnits=\"Absolute\" TileMode=\"None\"/></\(owner).\(prop)>")
        }
    }

    mutating func write() -> (String, [String]) {
        var body = ""
        if let bg = page.background {
            let full = PathBuilder.rect(x: 0, y: 0, width: page.size.width, height: page.size.height)
            body += "<Path Data=\"\(data(full, rule: .nonZero))\" Fill=\"\(Self.colour(bg))\"/>"
        }
        for node in page.nodes { body += emit(node) }
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<FixedPage xmlns=\"http://schemas.microsoft.com/xps/2005/06\" xmlns:x=\"http://schemas.microsoft.com/winfx/2006/xaml\" Width=\"\(Self.fmt(page.size.width / 0.75))\" Height=\"\(Self.fmt(page.size.height / 0.75))\" xml:lang=\"en-US\">\(body)</FixedPage>"
        return (xml, resources)
    }

    mutating func emit(_ node: VectorNode) -> String {
        switch node {
        case .path(let segments, let fill, let stroke, let rule):
            guard !segments.isEmpty else { return "" }
            let bounds = segments.cgPath.boundingBoxOfPath
            var attrs = " Data=\"\(data(segments, rule: rule))\""
            var children = ""
            if let fill { let (a, e) = brush("Path", "Fill", fill, bounds: bounds); attrs += a; children += e }
            if let stroke, stroke.width > 0 {
                let w = stroke.width * 4.0 / 3
                let (a, e) = brush("Path", "Stroke", stroke.paint, bounds: bounds)
                attrs += a; children += e
                attrs += " StrokeThickness=\"\(Self.fmt(w))\""
                let cap = stroke.cap == .round ? "Round" : stroke.cap == .square ? "Square" : "Flat"
                attrs += " StrokeStartLineCap=\"\(cap)\" StrokeEndLineCap=\"\(cap)\" StrokeDashCap=\"\(cap)\""
                attrs += " StrokeLineJoin=\"\(stroke.join == .round ? "Round" : stroke.join == .bevel ? "Bevel" : "Miter")\" StrokeMiterLimit=\"\(Self.fmt(stroke.miterLimit))\""
                if !stroke.dash.isEmpty {
                    attrs += " StrokeDashArray=\"\(stroke.dash.map { Self.fmt($0 / stroke.width) }.joined(separator: " "))\""
                    if stroke.dashPhase != 0 { attrs += " StrokeDashOffset=\"\(Self.fmt(stroke.dashPhase / stroke.width))\"" }
                }
            }
            if fill == nil, stroke == nil { return "" }
            return children.isEmpty ? "<Path\(attrs)/>" : "<Path\(attrs)>\(children)</Path>"
        case .text(let run):
            guard let font = run.fontData else { return "" }
            let part = package.fontPart(font)
            resource(part)
            guard let colour = firstColour(run.fill) else { return "" }
            var text = Self.escape(run.text)
            if text.hasPrefix("{") { text = "{}" + text }
            let o = f.apply(run.origin)
            return "<Glyphs UnicodeString=\"\(text)\" FontUri=\"\(part)\" FontRenderingEmSize=\"\(Self.fmt(run.size * 4.0 / 3))\" OriginX=\"\(Self.fmt(o.x))\" OriginY=\"\(Self.fmt(o.y))\" Fill=\"\(Self.colour(colour))\" StyleSimulations=\"None\" BidiLevel=\"0\"/>"
        case .image(let asset, let t):
            guard let frame = asset.frames.first, let part = package.imagePart(asset) else { return "" }
            resource(part)
            let w = Double(frame.width), h = Double(frame.height)
            let s = VectorTransform(a: 1 / w, b: 0, c: 0, d: -1 / h, tx: 0, ty: 1)
            let a = s.then(t).then(f)
            let rect = "M 0,0 L \(frame.width),0 L \(frame.width),\(frame.height) L 0,\(frame.height) Z"
            return "<Path Data=\"\(rect)\" RenderTransform=\"\(matrix(a))\"><Path.Fill><ImageBrush ImageSource=\"\(part)\" Viewbox=\"0,0,\(frame.width),\(frame.height)\" Viewport=\"0,0,\(frame.width),\(frame.height)\" ViewboxUnits=\"Absolute\" ViewportUnits=\"Absolute\" TileMode=\"None\"/></Path.Fill></Path>"
        case .group(let children, let t, let clip, let opacity):
            var attrs = ""
            if !t.isIdentity, let inverse = f.inverted { attrs += " RenderTransform=\"\(matrix(inverse.then(t).then(f)))\"" }
            if let clip { attrs += " Clip=\"\(clip.isEmpty ? "F1 M 0,0 L 0,0 Z" : data(clip, rule: .nonZero))\"" }
            if opacity < 0.9999 { attrs += " Opacity=\"\(Self.fmt(opacity))\"" }
            var inner = ""
            for child in children { inner += emit(child) }
            if inner.isEmpty { return "" }
            return attrs.isEmpty ? inner : "<Canvas\(attrs)>\(inner)</Canvas>"
        }
    }
}
