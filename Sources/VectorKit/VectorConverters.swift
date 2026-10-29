import Foundation
import SuperConverterCore

// VectorKit's converters (ARCHITECTURE §4, §6): one per engine id `format-matrix.json` names for this module.
// None needs a helper: Ghostscript's PostScript/EPS → PDF step belongs to HelperKit.

enum VectorConverters {
    static let all: [VectorConverter] = [
        ConverterSupport.reader(.vectorKit, from: ["pdf"]) { url in try PDFReader.read(url) },
        ConverterSupport.reader(.svgReader, from: ["svg", "svgz"]) { url in try SVGReader.read(try ConverterSupport.readData(url), baseURL: url) },
        ConverterSupport.reader(.emfReader, from: ["emf"]) { url in try EMFReader.read(try ConverterSupport.readData(url)) },
        ConverterSupport.reader(.wmfReader, from: ["wmf"]) { url in try WMFReader.read(try ConverterSupport.readData(url)) },
        ConverterSupport.reader(.aiReader, from: ["ai"]) { url in try AIReader.read(url) },
        ConverterSupport.writer(.svgWriter, to: "svg", singlePage: true) { doc, options in try SVGWriter.write(doc, options: options) },
        ConverterSupport.writer(.emfWriter, to: "emf", singlePage: true) { doc, options in try EMFWriter.write(doc, options: options) },
        ConverterSupport.writer(.wmfWriter, to: "wmf", singlePage: true) { doc, options in try WMFWriter.write(doc, options: options) },
    ]
}
