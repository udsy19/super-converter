import Foundation
import SuperConverterCore

/// Adobe Illustrator files. Since AI 9 a file is a PDF with Illustrator's private data appended, so the PDF reader reads
/// the drawing. Older (pure PostScript) files need Ghostscript, which HelperKit runs as a separate step of the route.
public enum AIReader {
    public static func read(_ url: URL) throws -> VectorReadResult {
        let data = try ConverterSupport.readData(url)
        // The PDF header may follow a few bytes of junk.
        guard data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else { throw ConversionError.helperMissing(.ghostscript) }
        return try PDFReader.read(data: data)
    }
}
