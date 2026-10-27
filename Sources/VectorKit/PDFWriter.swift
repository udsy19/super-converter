import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore

/// PDF output on Core Graphics: vector pages (paths, gradients, clips, groups, text with embedded subset fonts, pictures),
/// raster pages for image → PDF (JPEG passes through without re-encoding) and fixed-layout publications (comics).
public enum PDFWriter {
    /// Builds a PDF in memory page by page.
    final class Builder {
        private let data = NSMutableData()
        private var context: CGContext?

        init?(title: String?, pdfA: Bool) {
            var dict: [CFString: Any] = [kCGPDFContextCreator: "Super Converter"]
            if let title { dict[kCGPDFContextTitle] = title }
            if pdfA, let profile = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() {
                dict[kCGPDFContextOutputIntents] = [[kCGPDFXOutputIntentSubtype: "GTS_PDFA1", kCGPDFXOutputConditionIdentifier: "sRGB IEC61966-2.1",
                                                      kCGPDFXOutputCondition: "sRGB", kCGPDFXRegistryName: "http://www.color.org",
                                                      kCGPDFXDestinationOutputProfile: CGColorSpace(iccData: profile as CFData) as Any]]
            }
            guard let consumer = CGDataConsumer(data: data) else { return nil }
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let ctx = CGContext(consumer: consumer, mediaBox: &box, dict as CFDictionary) else { return nil }
            context = ctx
        }

        /// Starts a page of the given size and returns the context to draw into.
        func page(_ size: VectorSize) -> CGContext {
            let ctx = context!
            var box = CGRect(x: 0, y: 0, width: max(1, size.width), height: max(1, size.height))
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            return ctx
        }

        func endPage() { context?.endPDFPage() }

        func finish() -> Data {
            context?.closePDF()
            context = nil
            return data as Data
        }
    }

    public static func write(_ document: VectorDocument, options: VectorWriteOptions) throws -> VectorWriteResult {
        var doc = document
        var notes: [LossNote] = []
        if options.textAsOutlines, doc.containsText { doc = doc.outlinedText(); notes.append(LossNote(.textAsOutlines)) }
        guard !doc.pages.isEmpty, let builder = Builder(title: doc.title ?? options.title, pdfA: options.pdfA) else { throw ConversionError.failed("There are no pages to write.") }
        for page in doc.pages {
            let ctx = builder.page(page.size)
            VectorRenderer.draw(page, in: ctx)
            builder.endPage()
        }
        return VectorWriteResult(data: builder.finish(), lossNotes: notes)
    }

    // MARK: Raster pages

    /// The CGImage for a frame, passing a JPEG file through untouched so the PDF keeps its bytes.
    static func pdfImage(_ frame: ImageFrame, in asset: ImageAsset, index: Int) -> CGImage? {
        if case .file(let url) = frame.pixels, ["jpg", "jpeg"].contains(url.pathExtension.lowercased()),
           let provider = CGDataProvider(url: url as CFURL),
           let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) { return image }
        return ImageBridge.cgImage(asset, frame: index)
    }

    /// Image → PDF with the O-IMG-PDF options: page size (fit/A4/Letter), margin in mm, orientation.
    public static func write(image asset: ImageAsset, options: OptionValues, title: String?) throws -> VectorWriteResult {
        guard let builder = Builder(title: title, pdfA: options["pdfA"]?.bool ?? false) else { throw ConversionError.failed("The PDF couldn’t be created.") }
        var wrote = 0
        for (index, frame) in asset.frames.enumerated() {
            guard let image = pdfImage(frame, in: asset, index: index) else { continue }
            let (page, rect) = ImagePage.layout(width: image.width, height: image.height, options: options)
            let ctx = builder.page(page)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
            builder.endPage()
            wrote += 1
        }
        guard wrote > 0 else { throw ConversionError.failed("There’s no picture to write.") }
        return VectorWriteResult(data: builder.finish())
    }

    /// A fixed-layout publication's page pictures as PDF pages, in reading order.
    public static func write(publication: Publication, title: String?) throws -> VectorWriteResult {
        guard let builder = Builder(title: publication.metadata.title ?? title, pdfA: false) else { throw ConversionError.failed("The PDF couldn’t be created.") }
        var wrote = 0
        for item in publication.spine {
            guard case .page(let resource) = item.content, let picture = publication.resources[resource] else { continue }
            let image: CGImage?
            if picture.mediaType == "image/jpeg", let provider = CGDataProvider(data: picture.data as CFData) {
                image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            } else {
                image = CGImageSourceCreateWithData(picture.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
            guard let image else { continue }
            let size = VectorSize(width: Double(image.width) * 0.75, height: Double(image.height) * 0.75)
            let ctx = builder.page(size)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            builder.endPage()
            wrote += 1
        }
        guard wrote > 0 else { throw ConversionError.failed("This book has no page pictures.") }
        return VectorWriteResult(data: builder.finish())
    }
}

/// Page geometry for a picture on its own page (O-IMG-PDF: page size, margin, orientation); also used for PostScript pages.
enum ImagePage {
    /// A picture's natural size is 1 px = 0.75 pt (96 dpi, like SVG).
    static func layout(width: Int, height: Int, options: OptionValues) -> (VectorSize, CGRect) {
        let pageSize = options["pageSize"]?.string ?? "fit"
        let margin = (Double(options["margin"]?.string ?? "0") ?? 0) * 72 / 25.4
        let orientation = options["orientation"]?.string ?? "auto"
        let natural = VectorSize(width: Double(width) * 0.75, height: Double(height) * 0.75)
        guard pageSize != "fit" || margin > 0 else { return (natural, CGRect(x: 0, y: 0, width: natural.width, height: natural.height)) }
        var base = pageSize == "a4" ? VectorSize(width: 595.276, height: 841.89) : pageSize == "letter" ? VectorSize(width: 612, height: 792) : natural
        if pageSize != "fit" {
            let landscape = orientation == "landscape" || (orientation == "auto" && width > height)
            if landscape != (base.width > base.height) { base = VectorSize(width: base.height, height: base.width) }
        } else {
            base = VectorSize(width: natural.width + 2 * margin, height: natural.height + 2 * margin)
        }
        let box = CGRect(x: margin, y: margin, width: base.width - 2 * margin, height: base.height - 2 * margin)
        let scale = min(Double(box.width) / natural.width, Double(box.height) / natural.height)
        let w = natural.width * scale, h = natural.height * scale
        return (base, CGRect(x: Double(box.midX) - w / 2, y: Double(box.midY) - h / 2, width: w, height: h))
    }
}
