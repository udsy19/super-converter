import CoreGraphics
import Foundation
import SuperConverterCore
import VectorKit

/// VectorDocument → pixels: a bitmap context scaled from the page's points to pixels, drawn by VectorKit's `VectorDrawing`.
public enum VectorRasterizer {
    public static func render(_ page: VectorPage, width: Int, height: Int, space: CGColorSpace, transparent: Bool) throws -> CGImage {
        let context = try Rasterizer.bitmapContext(width: width, height: height, space: space, transparent: transparent && page.background == nil)
        context.scaleBy(x: CGFloat(width) / max(CGFloat(page.size.width), 1), y: CGFloat(height) / max(CGFloat(page.size.height), 1))
        VectorDrawing.draw(page, in: context)
        guard let image = context.makeImage() else { throw ConversionError.failed("The drawing couldn’t be rendered.") }
        return image
    }
}
