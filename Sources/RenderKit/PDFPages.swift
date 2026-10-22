// Adapted from Super PDF Sources/RenderKit/PDFPages.swift and PDFOutput.swift (commit 058469b): PDFSource becomes a file URL
// plus password, errors map to Core's ConversionError, the Quartz writer stays, and the output-intent reader is new.
import CoreGraphics
import Foundation
import SuperConverterCore

/// Quartz-level access to a PDF's pages, off the main actor. Pages are drawn as displayed: /Rotate applied, crop box as the
/// visible area.
public enum PDFPages {
    /// Opens `url`, unlocking it with `password` when it is encrypted.
    public static func open(_ url: URL, password: String? = nil) throws -> CGPDFDocument {
        guard let document = CGPDFDocument(url as CFURL) else { throw ConversionError.damaged("pdf") }
        if document.isEncrypted, !document.isUnlocked {
            guard let password, !password.isEmpty, document.unlockWithPassword(password) else { throw ConversionError.passwordRequired("pdf") }
        }
        return document
    }

    /// Page `index` (0-based).
    public static func page(_ document: CGPDFDocument, at index: Int) throws -> CGPDFPage {
        guard index >= 0, let page = document.page(at: index + 1) else { throw ConversionError.failed("Page \(index + 1) isn’t in this file.") }
        return page
    }

    /// The page's size as displayed (crop box, rotated), in points.
    public static func displayedSize(_ page: CGPDFPage) -> CGSize {
        let crop = page.getBoxRect(.cropBox)
        return page.rotationAngle % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
    }

    /// Draws the page as displayed, fitted and centred in `rect` (aspect kept).
    public static func draw(_ page: CGPDFPage, in context: CGContext, fitting rect: CGRect) {
        context.saveGState()
        context.concatenate(drawingTransform(page, fitting: rect))
        context.drawPDFPage(page)
        context.restoreGState()
    }

    /// Crop box (with /Rotate) → `rect`, scaled either way and centred. `CGPDFPageGetDrawingTransform` only ever scales
    /// down, so it is used just for the rotation at the page's own size.
    public static func drawingTransform(_ page: CGPDFPage, fitting rect: CGRect) -> CGAffineTransform {
        let displayed = displayedSize(page)
        let scale = min(rect.width / max(displayed.width, 1), rect.height / max(displayed.height, 1))
        let drawn = CGSize(width: displayed.width * scale, height: displayed.height * scale)
        let placement = CGAffineTransform(translationX: rect.minX + (rect.width - drawn.width) / 2, y: rect.minY + (rect.height - drawn.height) / 2).scaledBy(x: scale, y: scale)
        return page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: displayed), rotate: 0, preserveAspectRatio: true).concatenating(placement)
    }

    /// The document's Info dictionary strings as PDF-context keys, so re-rendered files keep title, author and the rest.
    public static func metadata(_ document: CGPDFDocument) -> [CFString: Any] {
        guard let info = document.info else { return [:] }
        var result: [CFString: Any] = [:]
        let keys: [(String, CFString)] = [("Title", kCGPDFContextTitle), ("Author", kCGPDFContextAuthor), ("Subject", kCGPDFContextSubject), ("Keywords", kCGPDFContextKeywords), ("Creator", kCGPDFContextCreator)]
        for (name, key) in keys {
            var string: CGPDFStringRef?
            if CGPDFDictionaryGetString(info, name, &string), let string, let value = CGPDFStringCopyTextString(string) { result[key] = value as String }
        }
        return result
    }

    /// The colour space of the first output intent's profile (what "Colours: Keep" means for a page), when the file has one
    /// and it is an RGB profile.
    public static func outputIntentSpace(_ document: CGPDFDocument) -> CGColorSpace? {
        guard let catalog = document.catalog else { return nil }
        var intents: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(catalog, "OutputIntents", &intents), let intents, CGPDFArrayGetCount(intents) > 0 else { return nil }
        var intent: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        guard CGPDFArrayGetDictionary(intents, 0, &intent), let intent, CGPDFDictionaryGetStream(intent, "DestOutputProfile", &stream), let stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return nil }
        guard let space = CGColorSpace(iccData: data), space.model == .rgb else { return nil }
        return space
    }
}

/// Writes a PDF with Quartz: one page at a time, each drawn by a closure into a context of the page's size.
public enum PDFWriter {
    public struct Page {
        public var size: CGSize
        public var draw: (CGContext) throws -> Void
        public init(size: CGSize, draw: @escaping (CGContext) throws -> Void) { self.size = size; self.draw = draw }
    }

    public static func write(to destination: URL, info: [CFString: Any], pages: [Page]) throws {
        var mediaBox = CGRect(origin: .zero, size: pages.first?.size ?? CGSize(width: 612, height: 792))
        guard let context = CGContext(destination as CFURL, mediaBox: &mediaBox, info as CFDictionary) else { throw ConversionError.failed("The PDF couldn’t be written.") }
        var failure: Error?
        for page in pages {
            var box = CGRect(origin: .zero, size: page.size)
            let pageInfo = [kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData] as CFDictionary
            context.beginPDFPage(pageInfo)
            do { try page.draw(context) } catch { failure = error }
            context.endPDFPage()
            if failure != nil { break }
        }
        context.closePDF()
        if let failure { try? FileManager.default.removeItem(at: destination); throw failure }
    }

    /// Every page of `document` copied as drawn (vectors, text and images stay), for the PDF/A re-render.
    static func copiedPages(_ document: CGPDFDocument) throws -> [Page] {
        try (0..<document.numberOfPages).map { index in
            let page = try PDFPages.page(document, at: index)
            let size = PDFPages.displayedSize(page)
            return Page(size: size) { context in PDFPages.draw(page, in: context, fitting: CGRect(origin: .zero, size: size)) }
        }
    }
}
