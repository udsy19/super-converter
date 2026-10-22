// Adapted from Super PDF Sources/ConvertKit/Export/PDFAVerifier.swift (commit 058469b): the object-model (QPDF) walk becomes a
// CGPDF walk, so it covers what a Quartz-written PDF/A-2b file must have and what makes real files fail: encryption,
// identification in the XMP, the output intent, embedded fonts and scripts. It is not a full veraPDF.
import CoreGraphics
import Foundation

/// One finding: a stable rule name, what is wrong in plain words (ux §1.1) and the pages it concerns (0-based).
public struct PDFAProblem: Hashable, Sendable {
    public var rule: String
    public var message: String
    public var pages: [Int]

    public init(rule: String, message: String, pages: [Int] = []) { self.rule = rule; self.message = message; self.pages = pages }
}

public enum PDFAVerifier {
    public static func verify(_ document: CGPDFDocument) -> [PDFAProblem] {
        var problems: [PDFAProblem] = []
        func add(_ rule: String, _ message: String, pages: Set<Int> = []) { problems.append(PDFAProblem(rule: rule, message: message, pages: pages.sorted())) }
        if document.isEncrypted { add("encrypted", "The file is protected with a password, which PDF/A doesn’t allow.") }
        guard let catalog = document.catalog else { return problems + [PDFAProblem(rule: "damaged", message: "The file’s structure couldn’t be read.", pages: [])] }

        // Identification in the XMP metadata (ISO 19005-2 §6.6).
        var stream: CGPDFStreamRef?
        var identified = false
        if CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream {
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(stream, &format) as Data?, let xmp = String(data: data, encoding: .utf8) {
                identified = xmp.contains("pdfaid:part")
                if identified && xmp.range(of: #"pdfaid:part(>|=")\s*2"#, options: .regularExpression) == nil {
                    add("pdfa-identification", "The file says it follows a different PDF/A part than 2.")
                }
            }
        }
        if !identified { add("metadata", "The file doesn’t say it is a PDF/A file.") }

        // The colour profile the file was made for (§6.2.3).
        var intents: CGPDFArrayRef?
        var hasIntent = false
        if CGPDFDictionaryGetArray(catalog, "OutputIntents", &intents), let intents {
            for index in 0..<CGPDFArrayGetCount(intents) {
                var intent: CGPDFDictionaryRef?, profile: CGPDFStreamRef?, subtype: UnsafePointer<CChar>?
                if CGPDFArrayGetDictionary(intents, index, &intent), let intent, CGPDFDictionaryGetName(intent, "S", &subtype), let subtype,
                   String(cString: subtype) == "GTS_PDFA1", CGPDFDictionaryGetStream(intent, "DestOutputProfile", &profile) { hasIntent = true }
            }
        }
        if !hasIntent { add("output-intent", "The file has no colour profile for printing and display.") }

        // Scripts (§6.6).
        var names: CGPDFDictionaryRef?, scripts: CGPDFObjectRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names, CGPDFDictionaryGetObject(names, "JavaScript", &scripts) {
            add("javascript", "The file contains scripts, which PDF/A doesn’t allow.")
        }

        // Fonts embedded (§6.3.4).
        var unembedded: Set<Int> = []
        for index in 0..<document.numberOfPages {
            guard let page = document.page(at: index + 1), let fonts = fontDictionary(of: page) else { continue }
            CGPDFDictionaryApplyBlock(fonts, { _, object, _ in
                var font: CGPDFDictionaryRef?
                if CGPDFObjectGetValue(object, .dictionary, &font), let font, !isEmbedded(font) { unembedded.insert(index) }
                return true
            }, nil)
        }
        if !unembedded.isEmpty { add("fonts-not-embedded", "Some fonts aren’t stored in the file, so text could look different later.", pages: unembedded) }
        return problems
    }

    /// The page's /Resources /Font, looking up through the page tree for inherited resources.
    private static func fontDictionary(of page: CGPDFPage) -> CGPDFDictionaryRef? {
        var node = page.dictionary
        while let current = node {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources {
                var fonts: CGPDFDictionaryRef?
                return CGPDFDictionaryGetDictionary(resources, "Font", &fonts) ? fonts : nil
            }
            var parent: CGPDFDictionaryRef?
            node = CGPDFDictionaryGetDictionary(current, "Parent", &parent) ? parent : nil
        }
        return nil
    }

    private static func isEmbedded(_ font: CGPDFDictionaryRef) -> Bool {
        var subtype: UnsafePointer<CChar>?
        CGPDFDictionaryGetName(font, "Subtype", &subtype)
        let kind = subtype.map { String(cString: $0) }
        if kind == "Type3" { return true }
        var target = font
        if kind == "Type0" {
            var descendants: CGPDFArrayRef?, descendant: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
                  CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant else { return false }
            target = descendant
        }
        var descriptor: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(target, "FontDescriptor", &descriptor), let descriptor else { return false }
        var file: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(descriptor, "FontFile", &file) || CGPDFDictionaryGetStream(descriptor, "FontFile2", &file)
            || CGPDFDictionaryGetStream(descriptor, "FontFile3", &file)
    }
}
