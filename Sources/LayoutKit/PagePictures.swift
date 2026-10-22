import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore
import UniformTypeIdentifiers

/// Pictures cut out of PDF pages for figures and covers. (RenderKit does the same for whole pages; LayoutKit does not depend
/// on it, so the few lines this needs live here, as in Super PDF.)
final class PagePictures {
    private let document: CGPDFDocument

    init(url: URL, password: String?) throws { document = try Self.open(url, password: password) }

    static func open(_ url: URL, password: String?) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL) else { throw ConversionError.damaged("pdf") }
        if document.isEncrypted, !document.isUnlocked {
            guard let password, !password.isEmpty, document.unlockWithPassword(password) else { throw ConversionError.passwordRequired("pdf") }
        }
        return document
    }

    /// `rect` (page space, as the analysis reports it) drawn at `dpi`, the long side capped at `maxSide` pixels.
    func crop(_ rect: CGRect, of page: AnalysedPage, dpi: Double = 200, maxSide: Int = 3000) -> CGImage? {
        guard let pdfPage = document.page(at: page.index + 1) else { return nil }
        let shown = Geometry.displayed(rect, in: page)
        guard shown.width >= 2, shown.height >= 2 else { return nil }
        let scale = min(dpi / 72, Double(maxSide) / Double(max(shown.width, shown.height)))
        let width = Int((shown.width * scale).rounded()), height = Int((shown.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -shown.minX, y: -shown.minY)
        let crop = pdfPage.getBoxRect(.cropBox)
        let displayed = pdfPage.rotationAngle % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        context.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: displayed), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(pdfPage)
        return context.makeImage()
    }

    /// The whole page as a picture of at most `maxSide` pixels.
    func page(_ page: AnalysedPage, maxSide: Int = 1200) -> CGImage? {
        crop(CGRect(origin: .zero, size: page.size), of: page, dpi: 1000, maxSide: maxSide)
    }

    /// JPEG or PNG bytes.
    static func encode(_ image: CGImage, jpeg: Bool) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, (jpeg ? UTType.jpeg : UTType.png).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

enum Geometry {
    /// The page's displayed size (after /Rotate).
    static func displayedSize(_ page: AnalysedPage) -> CGSize { page.size.rotated(by: page.rotation) }

    /// A rect in the analysis' unrotated page space → the displayed page (y up).
    static func displayed(_ rect: CGRect, in page: AnalysedPage) -> CGRect { rect.rotated(by: page.rotation, pageSize: page.size) }
}
