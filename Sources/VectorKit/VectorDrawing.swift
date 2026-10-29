import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore

/// VectorDocument → any Core Graphics context (a bitmap, a PDF page, a print context). Pages are in points, y up, so a
/// context in points draws them as they are. Images are placed in the unit square under their transform (as PDF's `cm` +
/// `Do` places them). RenderKit's rasteriser, VectorKit's PDF writer and the engines that import VectorKit (TypesetKit,
/// XPSKit, CADKit) all draw through here.
public enum VectorDrawing {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A page as an sRGB bitmap at `scale` pixels per point, over `background` (white unless given; nil keeps it
    /// transparent). For engines and tests that need pixels without RenderKit's colour-managed rasteriser.
    public static func render(_ page: VectorPage, scale: Double = 1, background: VectorColour? = .white) -> CGImage? {
        let width = max(1, Int((page.size.width * scale).rounded(.up))), height = max(1, Int((page.size.height * scale).rounded(.up)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background {
            context.setFillColor(background.cg)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.scaleBy(x: CGFloat(width) / max(CGFloat(page.size.width), 1), y: CGFloat(height) / max(CGFloat(page.size.height), 1))
        draw(page, in: context)
        return context.makeImage()
    }

    /// Draws `page` (its background, then its nodes) into `context`, whose user space is the page's points.
    public static func draw(_ page: VectorPage, in context: CGContext) {
        if let background = page.background {
            context.setFillColor(background.cg)
            context.fill(CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height))
        }
        for node in page.nodes { draw(node, in: context) }
    }

    // MARK: Nodes

    public static func draw(_ node: VectorNode, in context: CGContext) {
        switch node {
        case .path(let segments, let fill, let stroke, let rule):
            let path = segments.cgPath
            if path.isEmpty { return }
            if let fill { paintFill(path, fill, rule: rule, in: context) }
            if let stroke, stroke.width > 0 { paintStroke(path, stroke, in: context) }
        case .text(let run):
            drawText(run, in: context)
        case .image(let asset, let transform):
            guard let image = ImageBridge.cgImage(asset) else { return }
            context.saveGState()
            context.concatenate(transform.cg)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            context.restoreGState()
        case .group(let children, let transform, let clip, let opacity):
            context.saveGState()
            defer { context.restoreGState() }
            context.concatenate(transform.cg)
            if let clip {
                // An empty clip path clips everything away.
                if clip.isEmpty { return }
                context.addPath(clip.cgPath); context.clip()
            }
            let layered = opacity < 0.999
            if layered { context.setAlpha(CGFloat(max(0, opacity))); context.beginTransparencyLayer(auxiliaryInfo: nil) }
            for child in children { draw(child, in: context) }
            if layered { context.endTransparencyLayer() }
        }
    }

    // MARK: Paint

    private static func paintFill(_ path: CGPath, _ paint: VectorPaint, rule: FillRule, in context: CGContext) {
        let cgRule: CGPathFillRule = rule == .evenOdd ? .evenOdd : .winding
        if case .solid(let colour) = paint {
            context.setFillColor(colour.cg)
            context.addPath(path)
            context.fillPath(using: cgRule)
            return
        }
        context.saveGState()
        context.addPath(path)
        context.clip(using: cgRule)
        paintClip(paint, bounds: path.boundingBoxOfPath, in: context)
        context.restoreGState()
    }

    /// Strokes `path`: solid strokes directly, other paints through the stroke's outline as a clip.
    private static func paintStroke(_ path: CGPath, _ stroke: VectorStroke, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(CGFloat(stroke.width))
        context.setLineCap(stroke.cap == .round ? .round : stroke.cap == .square ? .square : .butt)
        context.setLineJoin(stroke.join == .round ? .round : stroke.join == .bevel ? .bevel : .miter)
        context.setMiterLimit(CGFloat(stroke.miterLimit))
        let dash = stroke.dash.map { CGFloat(max(0, $0)) }
        if dash.contains(where: { $0 > 0 }) { context.setLineDash(phase: CGFloat(stroke.dashPhase), lengths: dash) }
        context.addPath(path)
        if case .solid(let colour) = stroke.paint {
            context.setStrokeColor(colour.cg)
            context.strokePath()
        } else {
            context.replacePathWithStrokedPath()
            context.clip()
            paintClip(stroke.paint, bounds: path.boundingBoxOfPath.insetBy(dx: -stroke.width, dy: -stroke.width), in: context)
        }
    }

    /// Paints into the current clip.
    private static func paintClip(_ paint: VectorPaint, bounds: CGRect, in context: CGContext) {
        switch paint {
        case .solid(let colour):
            context.setFillColor(colour.cg)
            context.fill(context.boundingBoxOfClipPath)
        case .linear(let from, let to, let stops):
            guard let gradient = gradient(stops) else { return }
            context.drawLinearGradient(gradient, start: from.cg, end: to.cg, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial(let centre, let radius, let stops):
            guard let gradient = gradient(stops), radius > 0 else { return }
            context.drawRadialGradient(gradient, startCenter: centre.cg, startRadius: 0, endCenter: centre.cg, endRadius: CGFloat(radius),
                                       options: [.drawsAfterEndLocation])
        case .rasterised(let asset):
            guard let image = ImageBridge.cgImage(asset) else { return }
            context.draw(image, in: bounds)
        }
    }

    /// The stops as a CGGradient (sorted, offsets clamped; one stop paints flat).
    static func gradient(_ stops: [GradientStop]) -> CGGradient? {
        let sorted = stops.sorted { $0.offset < $1.offset }
        guard let first = sorted.first else { return nil }
        let list = sorted.count == 1 ? [first, first] : sorted
        let locations = list.enumerated().map { CGFloat(sorted.count == 1 ? Double($0.offset) : max(0, min(1, $0.element.offset))) }
        return CGGradient(colorsSpace: srgb, colors: list.map(\.colour.cg) as CFArray, locations: locations)
    }

    // MARK: Text

    /// The CoreText font for a name (PostScript or family name; falls back to Helvetica as the system does).
    public static func font(named name: String, size: Double) -> CTFont { CTFontCreateWithName(name as CFString, CGFloat(size), nil) }

    /// The run's font: its embedded program when it has one, else the installed font of that name.
    public static func font(for run: VectorTextRun) -> CTFont {
        if let data = run.fontData, let provider = CGDataProvider(data: data as CFData), let cgFont = CGFont(provider) {
            return CTFontCreateWithGraphicsFont(cgFont, CGFloat(run.size), nil, nil)
        }
        return font(named: run.fontName, size: run.size)
    }

    private static func drawText(_ run: VectorTextRun, in context: CGContext) {
        var colour = CGColor(gray: 0, alpha: 1)
        switch run.fill {
        case .solid(let c): colour = c.cg
        case .linear(_, _, let stops), .radial(_, _, let stops): colour = stops.first?.colour.cg ?? colour
        case .rasterised: break
        }
        let attributes: [CFString: Any] = [kCTFontAttributeName: font(for: run), kCTForegroundColorFromContextAttributeName: true]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, run.text as CFString, attributes as CFDictionary))
        context.saveGState()
        context.setFillColor(colour)
        context.textMatrix = .identity
        context.textPosition = run.origin.cg
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
