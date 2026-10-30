// Adapted from Super PDF Sources/ConvertKit/Helpers/{LibreOffice,AppAutomation}.swift (commit 058469b) for LibreOffice's command
// line, its private profile and the Apple Events export scripts; the other adapters are new (formats §4, "Run as").

import Foundation
import SuperConverterCore

/// An engine run through a helper (ARCHITECTURE §4: helper-run engines belong to HelperKit). Availability is the helper's
/// status; the matrix decides which pairs reach it.
protocol HelperConverter: Converter { var runtime: HelperRuntime { get } }

extension HelperConverter {
    func availability() -> EngineAvailability { runtime.availability(id.helpers) }
}

private let fileToFile = [StepPattern(from: .anyFile, to: .anyFile)]

private func complete(_ context: StepContext, _ fraction: Double, _ unit: String? = nil) {
    context.report(StepProgress(fraction: fraction, unit: unit))
}

// MARK: - LibreOffice

/// `soffice --headless --convert-to …` with a private profile, no restore, no logo (formats §4). One process at a time.
struct LibreOfficeConverter: HelperConverter {
    let runtime: HelperRuntime
    var id: EngineID { .libreOffice }
    var handles: [StepPattern] { fileToFile }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let soffice = try runtime.requireExecutable(.libreoffice)
        let folder = try HelperRuntime.outputFolder(context, "lo")
        // LibreOffice drops a lock file next to the document it opens, so it works on a copy (a clone on APFS) in a folder
        // of its own, and the dropped file's folder is never writable.
        let staged = folder.appendingPathComponent("in", isDirectory: true), written = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: written, withIntermediateDirectories: true)
        let source = try HelperRuntime.stagedInput(input, step, context, in: staged)
        let profile = runtime.libreOfficeProfile
        Self.prepareProfile(profile)
        complete(context, 0)
        await runtime.libreOfficeGate.enter()
        do {
            try await runtime.runChecked(.libreoffice, soffice, Self.arguments(input: source, format: context.targetFormat.rawValue,
                                                                              outputFolder: written, profile: profile),
                                         workFolder: context.workFolder, writable: [staged, written, profile],
                                         extraWriteFilters: [Self.launcherPipe])
            await runtime.libreOfficeGate.leave()
        } catch {
            await runtime.libreOfficeGate.leave()
            throw error
        }
        let output = try HelperRuntime.produced(HelperRuntime.outputURL(in: written, input: source, extension: context.targetFormat.rawValue), in: written)
        complete(context, 1)
        return StepOutput(.file(output))
    }

    /// The one place outside the work folder LibreOffice insists on writing: the pipe its launcher talks to its worker through.
    static let launcherPipe = #"(regex #"^/private/(var/)?tmp(/OSL_PIPE_[0-9A-Za-z_]+)?$")"#

    /// Headless, private profile, no restore, no logo.
    static func arguments(input: URL, format: String, outputFolder: URL, profile: URL) -> [String] {
        let filter = format == "txt" ? "txt:Text (encoded):UTF8" : format
        return ["-env:UserInstallation=\(profile.absoluteURL.absoluteString)", "--headless", "--invisible", "--nocrashreport", "--nodefault",
                "--nofirststartwizard", "--nolockcheck", "--nologo", "--norestore", "--convert-to", filter, "--outdir", outputFolder.path, input.path]
    }

    /// A fresh profile turns off the update check and first-start tasks, so a run never reaches the network.
    static func prepareProfile(_ profile: URL) {
        let user = profile.appendingPathComponent("user", isDirectory: true)
        let file = user.appendingPathComponent("registrymodifications.xcu")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let items = [
            #"<item oor:path="/org.openoffice.Office.Jobs/Jobs/org.openoffice.Office.Jobs:Job['UpdateCheck']/Arguments"><prop oor:name="AutoCheckEnabled" oor:op="fuse"><value>false</value></prop></item>"#,
            #"<item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="FirstRun" oor:op="fuse"><value>false</value></prop></item>"#,
            #"<item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="ShowTipOfTheDay" oor:op="fuse"><value>false</value></prop></item>"#,
            #"<item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>"#,
        ]
        let xml = #"<?xml version="1.0" encoding="UTF-8"?>"# + "\n"
            + #"<oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#
            + "\n" + items.joined(separator: "\n") + "\n</oor:items>\n"
        try? xml.write(to: file, atomically: true, encoding: .utf8)
    }
}

// MARK: - calibre

/// `ebook-convert in.x out.y` (calibre.app/Contents/MacOS), with calibre's own folders kept private.
struct CalibreConverter: HelperConverter {
    let runtime: HelperRuntime
    var id: EngineID { .calibre }
    var handles: [StepPattern] { fileToFile }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let tool = try runtime.requireExecutable(.calibre)
        let source = try HelperRuntime.stagedInput(input, step, context)
        let folder = try HelperRuntime.outputFolder(context, "calibre")
        let output = HelperRuntime.outputURL(in: folder, input: source, extension: context.targetFormat.rawValue)
        let private_ = folder.appendingPathComponent(".calibre", isDirectory: true)
        try FileManager.default.createDirectory(at: private_, withIntermediateDirectories: true)
        complete(context, 0)
        try await runtime.runChecked(.calibre, tool, [source.path, output.path], workFolder: context.workFolder, writable: [folder],
                                     environment: ["CALIBRE_CONFIG_DIRECTORY": private_.appendingPathComponent("config").path,
                                                   "CALIBRE_CACHE_DIRECTORY": private_.appendingPathComponent("cache").path,
                                                   "CALIBRE_TEMP_DIR": private_.appendingPathComponent("tmp").path,
                                                   "CALIBRE_NO_UPDATE_CHECK": "1"])
        try? FileManager.default.removeItem(at: private_)
        complete(context, 1)
        return StepOutput(.file(try HelperRuntime.produced(output, in: folder)))
    }
}

// MARK: - Pandoc

/// `pandoc -f rst|latex -t json` → our `DocModel` (formats §4): Pandoc's reader, never its writers.
struct PandocConverter: HelperConverter {
    let runtime: HelperRuntime
    var id: EngineID { .pandoc }
    var handles: [StepPattern] { [StepPattern(from: .anyFile, to: .model(.docModel))] }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let tool = try runtime.requireExecutable(.pandoc)
        let source = try HelperRuntime.inputFile(input, context)
        let folder = try HelperRuntime.outputFolder(context, "pandoc")
        let json = folder.appendingPathComponent("ast.json")
        let reader = context.sourceFormat.rawValue == "tex" ? "latex" : context.sourceFormat.rawValue
        complete(context, 0)
        try await runtime.runChecked(.pandoc, tool, ["-f", reader, "-t", "json", "-o", json.path, source.path],
                                     workFolder: context.workFolder, writable: [folder])
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let (model, flattened) = try PandocAST.docModel(from: try Data(contentsOf: json), baseFolder: source.deletingLastPathComponent())
            complete(context, 1)
            return StepOutput(.doc(model), lossNotes: flattened.isEmpty ? [] : [LossNote(.formattingSimplified, detail: flattened.joined(separator: ", "))])
        } catch {
            throw ConversionError.damaged(context.sourceFormat)
        }
    }
}

// MARK: - Tectonic

/// `tectonic -X compile --only-cached --untrusted` (offline, from the cache the install warmed), or MacTeX's `latexmk` when
/// that is what was found (formats §4).
struct TectonicConverter: HelperConverter {
    let runtime: HelperRuntime
    var id: EngineID { .tectonic }
    var handles: [StepPattern] { fileToFile }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let tool = try runtime.requireExecutable(.tectonic)
        let source = try HelperRuntime.inputFile(input, context)
        let folder = try HelperRuntime.outputFolder(context, "tex")
        let cache = runtime.tectonicCache
        complete(context, 0)
        if tool.lastPathComponent == "latexmk" {
            // Includes next to the source are found through TEXINPUTS; the only place written is the output folder.
            try await runtime.runChecked(.tectonic, tool, ["-pdf", "-interaction=nonstopmode", "-halt-on-error", "-no-shell-escape", "-norc",
                                                           "-outdir=\(folder.path)", source.path],
                                         workFolder: context.workFolder, writable: [folder], environment: ["TEXINPUTS": source.deletingLastPathComponent().path + "//:"],
                                         searchPath: [tool.deletingLastPathComponent()])
        } else {
            try await runtime.runChecked(.tectonic, tool, Self.arguments(input: source, outputFolder: folder), workFolder: context.workFolder,
                                         writable: [folder, cache], environment: ["TECTONIC_CACHE_DIR": cache.path])
        }
        complete(context, 1)
        return StepOutput(.file(try HelperRuntime.produced(HelperRuntime.outputURL(in: folder, input: source, extension: "pdf"), in: folder)))
    }

    static func arguments(input: URL, outputFolder: URL) -> [String] {
        ["-X", "compile", "--only-cached", "--untrusted", "--outdir", outputFolder.path, input.path]
    }

    /// The document the installer compiles once, with network, so the common packages are in the cache before the first
    /// offline run.
    static let warmUpDocument = """
        \\documentclass{article}
        \\usepackage{amsmath,amssymb,graphicx,hyperref,booktabs,longtable,xcolor,geometry,fancyvrb,enumitem,microtype}
        \\begin{document}
        Warm-up. $e^{i\\pi}+1=0$ \\begin{tabular}{ll}\\toprule a & b\\\\\\bottomrule\\end{tabular}
        \\end{document}
        """
}

// MARK: - Ghostscript, DjVuLibre, sfArk

/// `gs -dSAFER -dBATCH -dNOPAUSE -sDEVICE=… ` (formats §4).
struct GhostscriptConverter: HelperConverter {
    let runtime: HelperRuntime
    var id: EngineID { .ghostscript }
    var handles: [StepPattern] { fileToFile }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let tool = try runtime.requireExecutable(.ghostscript)
        let source = try HelperRuntime.stagedInput(input, step, context)
        let folder = try HelperRuntime.outputFolder(context, "gs")
        let target = context.targetFormat.rawValue
        let output = HelperRuntime.outputURL(in: folder, input: source, extension: target)
        complete(context, 0)
        try await runtime.runChecked(.ghostscript, tool, Self.arguments(input: source, output: output, target: target),
                                     workFolder: context.workFolder, writable: [folder])
        complete(context, 1)
        return StepOutput(.file(try HelperRuntime.produced(output, in: folder)))
    }

    static func arguments(input: URL, output: URL, target: String) -> [String] {
        let device = ["pdf": "pdfwrite", "ps": "ps2write", "eps": "eps2write"][target] ?? "pdfwrite"
        var args = ["-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET", "-sDEVICE=\(device)", "-sOutputFile=\(output.path)"]
        if input.pathExtension.lowercased() == "eps" && target == "pdf" { args.append("-dEPSCrop") }
        return args + [input.path]
    }
}

/// `ddjvu -format=pdf in.djvu out.pdf`.
struct DjVuLibreConverter: HelperConverter {
    let runtime: HelperRuntime
    var id: EngineID { .djvuLibre }
    var handles: [StepPattern] { fileToFile }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let tool = try runtime.requireExecutable(.djvulibre)
        let source = try HelperRuntime.stagedInput(input, step, context)
        let folder = try HelperRuntime.outputFolder(context, "djvu")
        let output = HelperRuntime.outputURL(in: folder, input: source, extension: "pdf")
        complete(context, 0)
        try await runtime.runChecked(.djvulibre, tool, ["-format=pdf", source.path, output.path], workFolder: context.workFolder, writable: [folder])
        complete(context, 1)
        return StepOutput(.file(try HelperRuntime.produced(output, in: folder)))
    }
}

/// `sfarkxtc in.sfark out.sf2`.
struct SfArkConverter: HelperConverter {
    let runtime: HelperRuntime
    var id: EngineID { .sfArk }
    var handles: [StepPattern] { fileToFile }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let tool = try runtime.requireExecutable(.sfark)
        let source = try HelperRuntime.stagedInput(input, step, context)
        let folder = try HelperRuntime.outputFolder(context, "sfark")
        let output = HelperRuntime.outputURL(in: folder, input: source, extension: "sf2")
        complete(context, 0)
        try await runtime.runChecked(.sfark, tool, [source.path, output.path], workFolder: context.workFolder, writable: [folder])
        complete(context, 1)
        return StepOutput(.file(try HelperRuntime.produced(output, in: folder)))
    }
}

// MARK: - DWG (ODA File Converter, LibreDWG)

/// DWG ↔ DXF and DWG → DWG (other versions): the ODA File Converter when present, else LibreDWG's `dwg2dxf` / `dxf2dwg`
/// (formats §4). ODA works on folders, so the input is copied into a folder of its own.
struct DWGConverter: HelperConverter {
    let runtime: HelperRuntime
    var id: EngineID { .dwgConverter }
    var handles: [StepPattern] { fileToFile }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let source = try HelperRuntime.stagedInput(input, step, context)
        let folder = try HelperRuntime.outputFolder(context, "dwg")
        let from = context.sourceFormat.rawValue, to = context.targetFormat.rawValue
        complete(context, 0)
        let output: URL
        if let oda = runtime.location(of: .oda) {
            output = try await viaODA(oda.executable, source: source, from: from, to: to, folder: folder, context: context)
        } else if let dwg2dxf = runtime.location(of: .libredwg)?.executable {
            output = try await viaLibreDWG(dwg2dxf, source: source, from: from, to: to, folder: folder, context: context)
        } else {
            throw ConversionError.helperMissing(.oda)
        }
        complete(context, 1)
        return StepOutput(.file(output))
    }

    private func viaODA(_ tool: URL, source: URL, from: String, to: String, folder: URL, context: StepContext) async throws -> URL {
        // The staged input sits alone in its folder, which is what ODA converts.
        let inFolder = source.deletingLastPathComponent(), outFolder = folder.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
        // <in> <out> <output version> <output type> <recurse> <audit> <filter>
        try await runtime.runChecked(.oda, tool, [inFolder.path, outFolder.path, "ACAD2018", to.uppercased(), "0", "1", "*.\(from.uppercased())"],
                                     workFolder: context.workFolder, writable: [outFolder], environment: ["QT_QPA_PLATFORM": "offscreen"])
        return try HelperRuntime.produced(HelperRuntime.outputURL(in: outFolder, input: source, extension: to), in: outFolder)
    }

    private func viaLibreDWG(_ dwg2dxf: URL, source: URL, from: String, to: String, folder: URL, context: StepContext) async throws -> URL {
        let dxf2dwg = dwg2dxf.deletingLastPathComponent().appendingPathComponent("dxf2dwg")
        func convert(_ tool: URL, _ input: URL, _ ext: String) async throws -> URL {
            let output = HelperRuntime.outputURL(in: folder, input: input, extension: ext)
            try await runtime.runChecked(.libredwg, tool, ["-y", "-o", output.path, input.path], workFolder: context.workFolder, writable: [folder])
            return try HelperRuntime.produced(output, in: folder)
        }
        switch (from, to) {
        case ("dwg", "dxf"): return try await convert(dwg2dxf, source, "dxf")
        case ("dxf", "dwg"): return try await convert(dxf2dwg, source, "dwg")
        default:
            // DWG → DWG: out to DXF and back in, which rewrites the file in the version LibreDWG writes.
            let dxf = try await convert(dwg2dxf, source, "dxf")
            let back = folder.appendingPathComponent("rewritten", isDirectory: true)
            try FileManager.default.createDirectory(at: back, withIntermediateDirectories: true)
            let output = HelperRuntime.outputURL(in: back, input: source, extension: "dwg")
            try await runtime.runChecked(.libredwg, dxf2dwg, ["-y", "-o", output.path, dxf.path], workFolder: context.workFolder, writable: [back])
            return try HelperRuntime.produced(output, in: back)
        }
    }
}

// MARK: - FFmpeg with GPL encoders

/// A separate `ffmpeg` that was built with `--enable-gpl` (formats §4): CAVS output through libxavs.
struct FFmpegGPLConverter: HelperConverter {
    let runtime: HelperRuntime
    var id: EngineID { .ffmpegGPL }
    var handles: [StepPattern] { fileToFile }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let tool = try runtime.requireExecutable(.ffmpegGPL)
        let source = try HelperRuntime.stagedInput(input, step, context)
        let folder = try HelperRuntime.outputFolder(context, "ffmpeg")
        let output = HelperRuntime.outputURL(in: folder, input: source, extension: "cavs")
        complete(context, 0)
        try await runtime.runChecked(.ffmpegGPL, tool, ["-nostdin", "-y", "-hide_banner", "-loglevel", "error", "-i", source.path,
                                                         "-an", "-c:v", "libxavs", "-f", "cavsvideo", output.path],
                                     workFolder: context.workFolder, writable: [folder])
        complete(context, 1)
        return StepOutput(.file(try HelperRuntime.produced(output, in: folder)))
    }
}

// MARK: - RAR

/// `rar a -ma5 -m3` over an extracted archive tree (formats §4; creating RAR is RARLAB's proprietary tool).
struct RARConverter: HelperConverter {
    let runtime: HelperRuntime
    var id: EngineID { .rar }
    var handles: [StepPattern] { [StepPattern(from: .model(.archiveTree), to: .anyFile)] }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        guard case .archive(let tree) = input, let root = tree.root else { throw ConversionError.failed("There is nothing to pack.") }
        let tool = try runtime.requireExecutable(.rar)
        let folder = try HelperRuntime.outputFolder(context, "rar")
        let output = HelperRuntime.outputURL(in: folder, input: context.source, extension: "rar")
        var level = "-m3"
        switch context.options["compression"]?.string { case "fast": level = "-m1"; case "smallest": level = "-m5"; default: break }
        // Paths are stored as the tree names them: run in the folder the tree was extracted into.
        let names = tree.entries.filter { $0.kind != .symlink }.map(\.path)
        guard !names.isEmpty else { throw ConversionError.failed("There is nothing to pack.") }
        complete(context, 0)
        try await runtime.runChecked(.rar, tool, ["a", "-ma5", level, "-idq", "-ep1", "-r-", output.path, "--"] + names,
                                     workFolder: root, writable: [folder])
        complete(context, 1)
        return StepOutput(.file(try HelperRuntime.produced(output, in: folder)))
    }
}

// MARK: - Pages, Numbers, Keynote (Apple Events)

/// Exports through the app's own AppleScript dictionary. The app opens briefly (the card says so before this runs) and is
/// quit afterwards only when this run launched it.
struct IWorkConverter: HelperConverter {
    enum App { case pages, numbers, keynote
        var bundleID: String {
            switch self { case .pages: "com.apple.iWork.Pages"; case .numbers: "com.apple.iWork.Numbers"; case .keynote: "com.apple.iWork.Keynote" }
        }
        var native: String { switch self { case .pages: "pages"; case .numbers: "numbers"; case .keynote: "key" } }
        var appName: String { switch self { case .pages: "Pages"; case .numbers: "Numbers"; case .keynote: "Keynote" } }
    }

    let runtime: HelperRuntime
    let app: App
    var id: EngineID { switch app { case .pages: .pages; case .numbers: .numbers; case .keynote: .keynote } }
    var handles: [StepPattern] { fileToFile }
    /// An export or a save in the app's own format can take a while on big documents.
    static let timeLimit: TimeInterval = 180

    func availability() -> EngineAvailability {
        runtime.detector.apps(of: .iwork).contains { $0.lastPathComponent == app.appName + ".app" } ? .available : .needsHelper(.iwork)
    }

    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let source = try HelperRuntime.stagedInput(input, step, context)
        let folder = try HelperRuntime.outputFolder(context, app.appName.lowercased())
        let target = context.targetFormat.rawValue
        let output = HelperRuntime.outputURL(in: folder, input: source, extension: target)
        guard let script = Self.script(app: app, source: source, target: target, output: output, folder: folder) else {
            throw ConversionError.unsupportedPair(from: context.sourceFormat, to: context.targetFormat)
        }
        complete(context, 0)
        let result = try await runtime.run(.iwork, runtime.osascript, ["-e", script], workFolder: context.workFolder, timeLimit: Self.timeLimit, sandbox: false)
        guard result.exitCode == 0 else {
            let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            // -1743: the person hasn't allowed Super Converter to control the app.
            throw ConversionError.failed(message.contains("-1743") ? "Allow Super Converter to control \(app.appName) in System Settings › Privacy & Security › Automation."
                                                                     : "\(app.appName) couldn’t export this file.")
        }
        complete(context, 1)
        if ["jpg", "png"].contains(target) { return StepOutput(.file(try Self.slideImages(in: folder, source: source, ext: target))) }
        return StepOutput(.file(try HelperRuntime.produced(output, in: folder)))
    }

    /// Keynote writes one image per slide into a folder; they are renamed "<name> – slide N.<ext>" in place and the first is
    /// the step's file, the rest sit beside it in the job's work folder.
    private static func slideImages(in folder: URL, source: URL, ext: String) throws -> URL {
        let fm = FileManager.default
        let images = ((try? fm.contentsOfDirectory(at: folder.appendingPathComponent("slides"), includingPropertiesForKeys: nil)) ?? [])
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !images.isEmpty else { throw ConversionError.failed("Keynote wrote no pictures.") }
        let base = source.deletingPathExtension().lastPathComponent
        var first: URL?
        for (i, image) in images.enumerated() {
            let named = folder.appendingPathComponent("\(base) – slide \(i + 1).\(ext)")
            try fm.moveItem(at: image, to: named)
            first = first ?? named
        }
        return first!
    }

    /// The AppleScript for one export or import; nil for a pair the app can't do.
    static func script(app: App, source: URL, target: String, output: URL, folder: URL) -> String? {
        let id = quote(app.bundleID)
        func wrap(_ body: String) -> String {
            """
            set wasRunning to application id \(id) is running
            set inFile to POSIX file \(quote(source.path))
            tell application id \(id)
                set theDocument to open inFile
                \(body)
                close theDocument saving no
                if not wasRunning then quit
            end tell
            """
        }
        let outFile = "POSIX file \(quote(output.path))"
        if target == app.native { return wrap("save theDocument in \(outFile)") }
        let format: String?
        switch (app, target) {
        case (_, "pdf"): format = "PDF"
        case (.pages, "docx"): format = "Microsoft Word"
        case (.pages, "epub"): format = "EPUB"
        case (.pages, "txt"): format = "unformatted text"
        case (.numbers, "xlsx"): format = "Microsoft Excel"
        case (.keynote, "pptx"): format = "Microsoft PowerPoint"
        default: format = nil
        }
        if let format { return wrap("export theDocument to \(outFile) as \(format)") }
        if app == .keynote, target == "jpg" || target == "png" {
            let slides = folder.appendingPathComponent("slides", isDirectory: true)
            try? FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
            return wrap("export theDocument to POSIX file \(quote(slides.path)) as slide images with properties {image format:\(target == "jpg" ? "JPEG" : "PNG"), skipped slides:false}")
        }
        return nil
    }

    /// An AppleScript string literal.
    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
