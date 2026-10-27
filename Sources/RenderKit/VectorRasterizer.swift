import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SuperConverterCore

/// VectorDocument → pixels with Core Graphics. Pages are in points, y up, so a context scaled by dpi/72 draws them as they
/// are. Images are placed in the unit square under their transform (as PDF's `cm` + `Do` places them).
public enum VectorRasterizer {
    public static func render(_ page: VectorPage, width: Int, height: Int, space: CGColorSpace, transparent: Bool) throws -> CGImage {
        let context = try Rasterizer.bitmapContext(width: width, height: height, space: space, transparent: transparent && page.background == nil)
        context.scaleBy(x: CGFloat(width) / max(CGFloat(page.size.width), 1), y: CGFloat(height) / max(CGFloat(page.size.height), 1))
        if let background = page.background {
            context.setFillColor(cgColour(background))
            context.fill(CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height))
        }
        for node in page.nodes { draw(node, in: context) }
        guard let image = context.makeImage() else { throw ConversionError.failed("The drawing couldn’t be rendered.") }
        return image
    }

    // MARK: Nodes

    static func draw(_ node: VectorNode, in context: CGContext) {
        switch node {
        case .path(let segments, let fill, let stroke, let rule):
            let path = cgPath(segments)
            if let fill { paint(fill, path: path, rule: rule, in: context) }
            if let stroke { strokePath(path, stroke, in: context) }
        case .text(let run):
            drawText(run, in: context)
        case .image(let asset, let transform):
            guard let frame = asset.frames.first, let image = cgImage(frame) else { return }
            context.saveGState()
            context.concatenate(affine(transform))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            context.restoreGState()
        case .group(let nodes, let transform, let clip, let opacity):
            context.saveGState()
            context.concatenate(affine(transform))
            if let clip { context.addPath(cgPath(clip)); context.clip() }
            let layered = opacity < 1
            if layered { context.setAlpha(CGFloat(max(opacity, 0))); context.beginTransparencyLayer(auxiliaryInfo: nil) }
            for child in nodes { draw(child, in: context) }
            if layered { context.endTransparencyLayer() }
            context.restoreGState()
        }
    }

    static func affine(_ t: VectorTransform) -> CGAffineTransform {
        CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty)
    }

    static func cgPath(_ segments: [PathSegment]) -> CGPath {
        let path = CGMutablePath()
        for segment in segments {
            switch segment {
            case .move(let p): path.move(to: CGPoint(x: p.x, y: p.y))
            case .line(let p): path.addLine(to: CGPoint(x: p.x, y: p.y))
            case .cubic(let a, let b, let c): path.addCurve(to: CGPoint(x: c.x, y: c.y), control1: CGPoint(x: a.x, y: a.y), control2: CGPoint(x: b.x, y: b.y))
            case .quad(let a, let b): path.addQuadCurve(to: CGPoint(x: b.x, y: b.y), control: CGPoint(x: a.x, y: a.y))
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    static func cgColour(_ c: VectorColour) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [CGFloat(c.red), CGFloat(c.green), CGFloat(c.blue), CGFloat(c.alpha)])!
    }

    // MARK: Paint

    /// Fills `path` with `paint`.
    static func paint(_ paint: VectorPaint, path: CGPath, rule: FillRule = .nonZero, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if case .solid(let colour) = paint {
            context.setFillColor(cgColour(colour)); context.addPath(path); context.fillPath(using: rule == .evenOdd ? .evenOdd : .winding)
            return
        }
        context.addPath(path); context.clip(using: rule == .evenOdd ? .evenOdd : .winding)
        paintClip(paint, bounds: path.boundingBoxOfPath, in: context)
    }

    /// Strokes `path`: solid strokes directly, other paints through the stroke's outline as a clip.
    static func strokePath(_ path: CGPath, _ stroke: VectorStroke, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineWidth(CGFloat(stroke.width))
        context.setLineCap(stroke.cap == .round ? .round : stroke.cap == .square ? .square : .butt)
        context.setLineJoin(stroke.join == .round ? .round : stroke.join == .bevel ? .bevel : .miter)
        context.setMiterLimit(CGFloat(stroke.miterLimit))
        if !stroke.dash.isEmpty { context.setLineDash(phase: CGFloat(stroke.dashPhase), lengths: stroke.dash.map { CGFloat($0) }) }
        context.addPath(path)
        if case .solid(let colour) = stroke.paint {
            context.setStrokeColor(cgColour(colour)); context.strokePath()
        } else {
            context.replacePathWithStrokedPath(); context.clip()
            paintClip(stroke.paint, bounds: path.boundingBoxOfPath.insetBy(dx: CGFloat(-stroke.width), dy: CGFloat(-stroke.width)), in: context)
        }
    }

    /// Paints into the current clip.
    private static func paintClip(_ paint: VectorPaint, bounds: CGRect, in context: CGContext) {
        switch paint {
        case .solid(let colour):
            context.setFillColor(cgColour(colour)); context.fill(bounds)
        case .linear(let from, let to, let stops):
            guard let gradient = gradient(stops) else { return }
            context.drawLinearGradient(gradient, start: CGPoint(x: from.x, y: from.y), end: CGPoint(x: to.x, y: to.y),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial(let centre, let radius, let stops):
            guard let gradient = gradient(stops) else { return }
            let c = CGPoint(x: centre.x, y: centre.y)
            context.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(radius), options: [.drawsAfterEndLocation])
        case .rasterised(let asset):
            if let frame = asset.frames.first, let image = cgImage(frame) { context.draw(image, in: bounds) }
        }
    }

    private static func gradient(_ stops: [GradientStop]) -> CGGradient? {
        let sorted = stops.sorted { $0.offset < $1.offset }
        guard !sorted.isEmpty else { return nil }
        return CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: sorted.map { cgColour($0.colour) } as CFArray,
                          locations: sorted.map { CGFloat($0.offset) })
    }

    // MARK: Text and images

    private static func drawText(_ run: VectorTextRun, in context: CGContext) {
        var font = CTFontCreateWithName(run.fontName as CFString, CGFloat(run.size), nil)
        if let data = run.fontData, let provider = CGDataProvider(data: data as CFData), let cgFont = CGFont(provider) {
            font = CTFontCreateWithGraphicsFont(cgFont, CGFloat(run.size), nil, nil)
        }
        let colour: CGColor
        switch run.fill {
        case .solid(let c): colour = cgColour(c)
        case .linear(_, _, let stops), .radial(_, _, let stops): colour = stops.first.map { cgColour($0.colour) } ?? CGColor(gray: 0, alpha: 1)
        case .rasterised: colour = CGColor(gray: 0, alpha: 1)
        }
        let attributed = NSAttributedString(string: run.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour])
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: run.origin.x, y: run.origin.y)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.restoreGState()
    }

    /// A frame as a CGImage (8-bit or half-float RGBA un-premultiplied, or a file ImageIO reads).
    static func cgImage(_ frame: ImageFrame) -> CGImage? {
        let space = frame.iccProfile.flatMap { CGColorSpace(iccData: $0 as CFData) } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        switch frame.pixels {
        case .rgba8(let data, let bytesPerRow):
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        case .rgbaHalf(let data, let bytesPerRow):
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.floatComponents.rawValue | CGImageByteOrderInfo.order16Little.rawValue)
            return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: bytesPerRow, space: space,
                           bitmapInfo: info, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        case .file(let url):
            return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }
    }
}
