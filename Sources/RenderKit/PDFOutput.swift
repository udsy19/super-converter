// Adapted from Super PDF Sources/RenderKit/PDFOutput.swift (commit 058469b): only the PDF/A writer is kept (no other route
// uses PDF/X, colour conversion or print-as-image), taking a file URL.
import CoreGraphics
import Foundation
import SuperConverterCore

/// Re-rendered PDF output through Quartz contexts.
///
/// PDF/A: Quartz's `kCGPDFContextCreatePDFA` writes a PDF/A-2B file (sRGB OutputIntent, fonts embedded, XMP with
/// `pdfaid:part 2 / conformance B`). Pages are drawn, not rasterised, so text stays text.
public enum PDFOutput {
    /// Writes every page of `source` as PDF/A-2b to `destination`.
    public static func writePDFA(_ source: URL, password: String? = nil, to destination: URL) throws {
        let document = try PDFPages.open(source, password: password)
        var info = PDFPages.metadata(document)
        info[kCGPDFContextCreatePDFA] = true
        let profile = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()! as Data
        info[kCGPDFContextOutputIntent] = [kCGPDFXOutputIntentSubtype: "GTS_PDFA1", kCGPDFXOutputConditionIdentifier: "sRGB IEC61966-2.1",
                                           kCGPDFXRegistryName: "http://www.color.org", kCGPDFXInfo: "sRGB IEC61966-2.1",
                                           kCGPDFXDestinationOutputProfile: profile as CFData] as [CFString: Any]
        try PDFWriter.write(to: destination, info: info, pages: PDFWriter.copiedPages(document))
    }
}
