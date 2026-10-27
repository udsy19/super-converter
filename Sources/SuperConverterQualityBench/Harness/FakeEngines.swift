import Foundation
import ImageIO
import SuperConverterCore

/// Stand-ins for engines other kits are still building, in a registry of their own (never `Services.converters`), so the
/// harness and every category's metrics run end to end before the real engines exist: `BenchCase.useFakes` selects it.
/// Each fake does the simplest honest thing with system tools: ImageIO re-encodes, audio passes through, an archive is
/// extracted with `unzip`. When the real engine lands, its kit adds real cases; these stay as the harness's own sample cases.
@MainActor
enum FakeEngines {
    static let registry: ConverterList = {
        let list = ConverterList()
        list.register(FakeImageEngine())
        list.register(FakeAudioEngine())
        list.register(FakeArchiveEngine())
        return list
    }()
}

/// `.imageIO`: decodes any picture ImageIO reads and encodes the target format (PNG, TIFF, BMP, or JPEG at quality 0.9).
struct FakeImageEngine: Converter {
    let id: EngineID = .imageIO
    var handles: [StepPattern] { [StepPattern(from: .anyFile, to: .anyFile)] }
    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        guard case .file(let url) = input, let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.damaged(context.sourceFormat)
        }
        let types: [String: String] = ["png": "public.png", "tiff": "public.tiff", "bmp": "com.microsoft.bmp", "jpg": "public.jpeg"]
        guard let type = types[context.targetFormat.rawValue] else { throw ConversionError.unsupportedPair(from: context.sourceFormat, to: context.targetFormat) }
        let out = context.workFolder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "." + context.targetFormat.rawValue)
        guard let destination = CGImageDestinationCreateWithURL(out as CFURL, type as CFString, 1, nil) else { throw ConversionError.failed("no encoder") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("encoding failed") }
        return StepOutput(.file(out))
    }
}

/// `.avFoundation`: audio passes through unchanged (a lossless "conversion").
struct FakeAudioEngine: Converter {
    let id: EngineID = .avFoundation
    var handles: [StepPattern] { [StepPattern(from: .anyFile, to: .anyFile)] }
    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        guard case .file(let url) = input else { throw ConversionError.failed("a file was expected") }
        let out = context.workFolder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: out)
        return StepOutput(.file(out))
    }
}

/// `.libarchive`: extracts a ZIP with `/usr/bin/unzip` into a folder named after the archive.
struct FakeArchiveEngine: Converter {
    let id: EngineID = .libarchive
    var handles: [StepPattern] { [StepPattern(from: .anyFile, to: .anyFile)] }
    func availability() -> EngineAvailability { .available }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        guard case .file(let url) = input else { throw ConversionError.failed("a file was expected") }
        let folder = context.workFolder.appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard Subprocess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", "-o", url.path, "-d", folder.path]).status == 0 else { throw ConversionError.damaged(context.sourceFormat) }
        return StepOutput(.file(folder))
    }
}
