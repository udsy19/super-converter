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
        ConverterSupport.reader(.skencilReader, from: ["sk"]) { url in try SKReader.read(try ConverterSupport.readData(url), dialect: .skencil) },
        ConverterSupport.reader(.sk1Reader, from: ["sk1"]) { url in try SKReader.read(try ConverterSupport.readData(url), dialect: .sk1) },
        ConverterSupport.writer(.svgWriter, to: "svg", singlePage: true) { doc, options in try SVGWriter.write(doc, options: options) },
        ConverterSupport.writer(.emfWriter, to: "emf", singlePage: true) { doc, options in try EMFWriter.write(doc, options: options) },
        ConverterSupport.writer(.wmfWriter, to: "wmf", singlePage: true) { doc, options in try WMFWriter.write(doc, options: options) },
        ConverterSupport.writer(.cgmWriter, to: "cgm", singlePage: false, textAsOutlinesDefault: true) { doc, options in try CGMWriter.write(doc, options: options) },
        pdf,
        postScript,
    ]

    /// `PSWriter`: a drawing (O-VEC) or a picture (O-IMG+PS) to PostScript or EPS; EPS holds the first page.
    static let postScript = VectorConverter(id: .psWriter, handles: [
        StepPattern(from: .model(.vectorDocument), to: .formats(["ps", "eps"])),
        StepPattern(from: .model(.imageAsset), to: .formats(["ps", "eps"])),
    ]) { step, input, context in
        let eps = step.to == .format("eps")
        let format: FormatID = eps ? "eps" : "ps"
        guard case .image(let asset) = input else {
            return try ConverterSupport.writeVector(input, context, to: format, singlePage: eps) { try PSWriter.write($0, options: $1, eps: eps) }
        }
        let result = try PSWriter.write(image: asset, options: context.options, eps: eps, title: context.source.deletingPathExtension().lastPathComponent)
        return StepOutput(.file(try ConverterSupport.save(result.data, context, format.rawValue)), lossNotes: result.lossNotes)
    }

    /// `CGPDF`: drawings (O-VEC), pictures (O-IMG-PDF, one page per frame) and fixed-layout publications (comics) → PDF.
    static let pdf = VectorConverter(id: .cgPDF, handles: [
        StepPattern(from: .model(.vectorDocument), to: .formats(["pdf"])),
        StepPattern(from: .model(.imageAsset), to: .formats(["pdf"])),
        StepPattern(from: .model(.publication), to: .formats(["pdf"])),
    ]) { _, input, context in
        let title = context.source.deletingPathExtension().lastPathComponent
        let result: VectorWriteResult
        switch input {
        case .image(let asset): result = try PDFWriter.write(image: asset, options: context.options, title: title)
        case .publication(let publication): result = try PDFWriter.write(publication: publication, title: title)
        default: return try ConverterSupport.writeVector(input, context, to: "pdf", singlePage: false) { try PDFWriter.write($0, options: $1) }
        }
        return StepOutput(.file(try ConverterSupport.save(result.data, context, "pdf")), lossNotes: result.lossNotes)
    }
}
