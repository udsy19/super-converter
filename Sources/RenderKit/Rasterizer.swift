// Adapted from Super PDF Sources/RenderKit/Rasterizer.swift (commit 058469b): contexts are RGBA in a chosen RGB space (sRGB,
// Display P3, Adobe RGB or the file's output intent) with an optional transparent background; ImageEncoder is ImageKit's job.
import CoreGraphics
import Foundation
import SuperConverterCore

/// Page → pixels through a bitmap context in the requested colour space (ColorSync converts), off the main actor.
public enum Rasterizer {
    /// Rasters above this many pixels are refused rather than swapped to disk (A3 at 600 dpi is 70 M).
    public static let maxPixels = 120_000_000

    /// Pixels the page takes at `dpi`, or fitted into `width` × `height` (either may be nil) keeping the aspect.
    public static func pixelSize(of size: CGSize, dpi: Double, width: Int?, height: Int?) -> (width: Int, height: Int) {
        var scale = dpi / 72
        if let width, let height { scale = min(Double(width) / max(size.width, 1), Double(height) / max(size.height, 1)) }
        else if let width { scale = Double(width) / max(size.width, 1) }
        else if let height { scale = Double(height) / max(size.height, 1) }
        // A damaged page can be any size, NaN included: sides stay in 1…1,000,000 px so the conversion can't trap and
        // width × height can't overflow; `bitmapContext` then refuses what is over `maxPixels`.
        func side(_ v: Double) -> Int { v.isNaN ? 1 : Int(min(max(v.rounded(), 1), 1_000_000)) }
        return (side(size.width * scale), side(size.height * scale))
    }

    /// A bitmap context (8-bit RGBA, premultiplied) in `space`, white-filled unless `transparent`.
    public static func bitmapContext(width: Int, height: Int, space: CGColorSpace, transparent: Bool = false) throws -> CGContext {
        guard width > 0, height > 0, width * height <= maxPixels else {
            throw ConversionError.failed("This is too large to draw at that resolution. Try a lower resolution.")
        }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.failed("A picture of that size couldn’t be made.")
        }
        context.interpolationQuality = .high
        if !transparent {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context
    }

    /// The page drawn into `width` × `height` pixels.
    public static func render(_ page: CGPDFPage, width: Int, height: Int, space: CGColorSpace, transparent: Bool = false) throws -> CGImage {
        let context = try bitmapContext(width: width, height: height, space: space, transparent: transparent)
        PDFPages.draw(page, in: context, fitting: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ConversionError.failed("The page couldn’t be drawn.") }
        return image
    }
}
