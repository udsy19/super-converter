import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore

/// Draws the vector model with Core Graphics. It is the shared drawing code of the PDF writer, the tests' pixel
/// comparisons and any engine that needs a bitmap of a drawing without going through RenderKit.
public enum VectorRenderer {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A page as a bitmap at `scale` pixels per point, over `background` (white unless given; nil keeps it transparent).
    public static func render(_ page: VectorPage, scale: Double = 1, background: VectorColour? = .white) -> CGImage? {
        let width = max(1, Int((page.size.width * scale).rounded(.up))), height = max(1, Int((page.size.height * scale).rounded(.up)))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let background {
            ctx.setFillColor(background.cg)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        ctx.scaleBy(x: CGFloat(width) / CGFloat(page.size.width), y: CGFloat(height) / CGFloat(page.size.height))
        draw(page, in: ctx)
        return ctx.makeImage()
    }

    /// Draws a page's background and nodes into `ctx`, whose user space is the page in points with y up.
    public static func draw(_ page: VectorPage, in ctx: CGContext) {
        if let background = page.background {
            ctx.setFillColor(background.cg)
            ctx.fill(CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height))
        }
        for node in page.nodes { draw(node, in: ctx) }
    }

    public static func draw(_ node: VectorNode, in ctx: CGContext) {
        switch node {
        case .path(let segments, let fill, let stroke, let rule):
            let path = segments.cgPath
            if path.isEmpty { return }
            if let fill { paintFill(path, fill, rule: rule, in: ctx) }
            if let stroke, stroke.width > 0 { paintStroke(path, stroke, in: ctx) }
        case .text(let run):
            drawText(run, in: ctx)
        case .image(let asset, let t):
            guard let image = ImageBridge.cgImage(asset) else { return }
            ctx.saveGState()
            ctx.concatenate(t.cg)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.restoreGState()
        case .group(let children, let t, let clip, let opacity):
            ctx.saveGState()
            ctx.concatenate(t.cg)
            if let clip { ctx.addPath(clip.cgPath); ctx.clip() }
            let layered = opacity < 0.999
            if layered { ctx.setAlpha(CGFloat(max(0, opacity))); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
            for child in children { draw(child, in: ctx) }
            if layered { ctx.endTransparencyLayer() }
            ctx.restoreGState()
        }
    }

    // MARK: Paint

    private static func paintFill(_ path: CGPath, _ paint: VectorPaint, rule: FillRule, in ctx: CGContext) {
        switch paint {
        case .solid(let colour):
            ctx.setFillColor(colour.cg)
            ctx.addPath(path)
            ctx.fillPath(using: rule == .evenOdd ? .evenOdd : .winding)
        default:
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip(using: rule == .evenOdd ? .evenOdd : .winding)
            drawPaint(paint, bounds: path.boundingBoxOfPath, in: ctx)
            ctx.restoreGState()
        }
    }

    private static func paintStroke(_ path: CGPath, _ stroke: VectorStroke, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setLineWidth(CGFloat(stroke.width))
        ctx.setLineCap(stroke.cap == .round ? .round : stroke.cap == .square ? .square : .butt)
        ctx.setLineJoin(stroke.join == .round ? .round : stroke.join == .bevel ? .bevel : .miter)
        ctx.setMiterLimit(CGFloat(stroke.miterLimit))
        let dash = stroke.dash.map { CGFloat(max(0, $0)) }
        if !dash.isEmpty, dash.contains(where: { $0 > 0 }) { ctx.setLineDash(phase: CGFloat(stroke.dashPhase), lengths: dash) }
        if case .solid(let colour) = stroke.paint {
            ctx.setStrokeColor(colour.cg)
            ctx.addPath(path)
            ctx.strokePath()
        } else {
            ctx.addPath(path)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            drawPaint(stroke.paint, bounds: path.boundingBoxOfPath.insetBy(dx: -stroke.width, dy: -stroke.width), in: ctx)
        }
        ctx.restoreGState()
    }

    /// Fills the current clip with a gradient or raster paint.
    private static func drawPaint(_ paint: VectorPaint, bounds: CGRect, in ctx: CGContext) {
        switch paint {
        case .solid(let colour):
            ctx.setFillColor(colour.cg)
            ctx.fill(ctx.boundingBoxOfClipPath)
        case .linear(let from, let to, let stops):
            guard let gradient = gradient(stops) else { return }
            ctx.drawLinearGradient(gradient, start: from.cg, end: to.cg, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial(let centre, let radius, let stops):
            guard let gradient = gradient(stops), radius > 0 else { return }
            ctx.drawRadialGradient(gradient, startCenter: centre.cg, startRadius: 0, endCenter: centre.cg, endRadius: CGFloat(radius),
                                   options: [.drawsAfterEndLocation])
        case .rasterised(let asset):
            guard let image = ImageBridge.cgImage(asset) else { return }
            ctx.draw(image, in: bounds)
        }
    }

    static func gradient(_ stops: [GradientStop]) -> CGGradient? {
        let sorted = stops.sorted { $0.offset < $1.offset }
        guard let first = sorted.first else { return nil }
        let list = sorted.count == 1 ? [first, first] : sorted
        let colours = list.map(\.colour.cg) as CFArray
        let locations = list.enumerated().map { CGFloat(sorted.count == 1 ? Double($0.offset) : max(0, min(1, $0.element.offset))) }
        return CGGradient(colorsSpace: srgb, colors: colours, locations: locations)
    }

    // MARK: Text

    /// The CoreText font for a run (PostScript or family name; falls back to Helvetica like the system does).
    public static func font(named name: String, size: Double) -> CTFont { CTFontCreateWithName(name as CFString, CGFloat(size), nil) }

    private static func drawText(_ run: VectorTextRun, in ctx: CGContext) {
        let font = font(named: run.fontName, size: run.size)
        var colour = CGColor(gray: 0, alpha: 1)
        switch run.fill {
        case .solid(let c): colour = c.cg
        case .linear(_, _, let stops), .radial(_, _, let stops): colour = stops.first?.colour.cg ?? colour
        case .rasterised: break
        }
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, run.text as CFString, attributes as CFDictionary))
        ctx.saveGState()
        ctx.setFillColor(colour)
        ctx.textMatrix = .identity
        ctx.textPosition = run.origin.cg
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
