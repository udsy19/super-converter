import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A plain typeset cover (title and author on a calm colour) for books that have none (O-EBOOK "Cover: make one").
enum CoverArt {
    static func png(title: String, authors: [String]) -> Data? {
        let width = 1200, height = 1800
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // A stable muted colour from the title.
        var hash: UInt32 = 5381
        for u in title.unicodeScalars { hash = hash &* 33 &+ u.value }
        let hue = CGFloat(hash % 360) / 360
        let background = rgb(hue: hue, saturation: 0.35, brightness: 0.32)
        ctx.setFillColor(background)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
        ctx.setLineWidth(6)
        ctx.stroke(CGRect(x: 70, y: 70, width: width - 140, height: height - 140))

        func draw(_ text: String, size: CGFloat, weight: CGFloat, in rect: CGRect) {
            let font = CTFontCreateWithName((weight > 0 ? "Georgia-Bold" : "Georgia") as CFString, size, nil)
            var alignment = CTTextAlignment.center
            let style = withUnsafePointer(to: &alignment) { pointer in
                var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
                return CTParagraphStyleCreate(&setting, 1)
            }
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
            ]
            let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            let fitted = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil,
                                                                      CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
            let box = CGRect(x: rect.minX, y: rect.maxY - fitted.height, width: rect.width, height: fitted.height)
            let path = CGPath(rect: box, transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), ctx)
        }
        draw(title, size: 96, weight: 1, in: CGRect(x: 150, y: 700, width: width - 300, height: 700))
        let author = authors.joined(separator: ", ")
        if !author.isEmpty { draw(author, size: 54, weight: 0, in: CGRect(x: 150, y: 260, width: width - 300, height: 300)) }
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    private static func rgb(hue h: CGFloat, saturation s: CGFloat, brightness v: CGFloat) -> CGColor {
        let i = Int(h * 6), f = h * 6 - CGFloat(i)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (CGFloat, CGFloat, CGFloat)
        switch i % 6 {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }
}
