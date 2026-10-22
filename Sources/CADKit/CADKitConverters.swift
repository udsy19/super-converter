import Foundation
import SuperConverterCore

// CADKit's converters (ARCHITECTURE §4, §6): one per engine id `format-matrix.json` names for this module — DXFReader, CADKit
// (the plot), DXFWriter, DWFReader. DWG goes through HelperKit's DWGConverter (ODA File Converter / LibreDWG as separate
// processes: LibreDWG is GPL, so nothing of it is linked here); this module only ever sees the DXF that helper produces.

struct CADKitConverter: Converter {
    let id: EngineID
    let handles: [StepPattern]
    let body: @Sendable (Step, StepValue, StepContext) throws -> StepOutput

    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        if context.isCancelled() { throw ConversionError.cancelled }
        return try body(step, input, context)
    }
}

enum CADKitConverters {
    static let rasterTargets: Set<FormatID> = ["bmp", "gif", "jpg", "png", "tiff"]

    static let all: [CADKitConverter] = [
        CADKitConverter(id: .dxfReader, handles: [StepPattern(from: .formats(["dxf"]), to: .model(.cadDrawing))]) { _, input, _ in
            guard case .file(let url) = input else { throw ConversionError.impossiblePair(reason: "A file was expected here.") }
            let data: Data
            do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.damaged("dxf") }
            let result = try DXFReader.read(data)
            return StepOutput(.cad(result.drawing), lossNotes: result.lossNotes)
        },
        CADKitConverter(id: .cadKit, handles: [StepPattern(from: .model(.cadDrawing), to: .model(.vectorDocument))]) { _, input, context in
            guard case .cad(let drawing) = input else { throw ConversionError.impossiblePair(reason: "The drawing wasn’t handed over.") }
            let options = CADPlotOptions(context.options, rasterTarget: rasterTargets.contains(context.targetFormat))
            let result = CADPlotter.plot(drawing, options: options)
            return StepOutput(.vector(result.document), lossNotes: result.lossNotes)
        },
        CADKitConverter(id: .dxfWriter, handles: [StepPattern(from: .model(.cadDrawing), to: .formats(["dxf"])),
                                                  StepPattern(from: .model(.vectorDocument), to: .formats(["dxf"]))]) { _, input, context in
            var notes: [LossNote] = []
            let drawing: CADDrawing
            switch input {
            case .cad(let d): drawing = d
            case .vector(let document):
                let converted = VectorToCAD.convert(document, unit: context.options["dxfUnits"]?.string ?? "mm")
                drawing = converted.drawing; notes = converted.lossNotes
            default: throw ConversionError.impossiblePair(reason: "The drawing wasn’t handed over.")
            }
            let version = DXFVersion(option: context.options["version"]?.string ?? context.options["dxfVersion"]?.string)
            let written = DXFWriter.write(drawing, version: version)
            let url = try output(context, "dxf")
            do { try written.data.write(to: url, options: .atomic) } catch { throw ConversionError.folderNotWritable(name: context.workFolder.lastPathComponent) }
            return StepOutput(.file(url), lossNotes: notes + written.lossNotes)
        },
        // DWFx is an XPS package (XPSKit's reader) and DWF 6 a W2D opcode stream; neither is decoded yet (formats §7: P3, timeboxed).
        CADKitConverter(id: .dwfReader, handles: [StepPattern(from: .formats(["dwf"]), to: .model(.cadDrawing))]) { _, _, _ in
            throw ConversionError.classicDWF
        },
    ]

    /// A new file in the work folder named after the source; an existing name gets a number.
    static func output(_ context: StepContext, _ pathExtension: String) throws -> URL {
        let stem = context.source.deletingPathExtension().lastPathComponent
        var url = context.workFolder.appendingPathComponent(stem).appendingPathExtension(pathExtension)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = context.workFolder.appendingPathComponent("\(stem) \(n)").appendingPathExtension(pathExtension)
            n += 1
        }
        return url
    }
}
