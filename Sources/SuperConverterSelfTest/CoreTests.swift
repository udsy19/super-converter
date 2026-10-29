import AppKit
import Combine
import Foundation
import SuperConverterCore
import UniformTypeIdentifiers

// Owned with SuperConverterCore: the contracts every module builds on.
func registerCoreTests() {
    SelfTest.cases.append(("Core.formats", { coreFormats() }))
    SelfTest.cases.append(("Core.formatDetails", { coreFormatDetails() }))
    SelfTest.cases.append(("Core.matrixShape", { coreMatrixShape() }))
    SelfTest.cases.append(("Core.matrixSteps", { coreMatrixSteps() }))
    SelfTest.cases.append(("Core.matrixHelpers", { coreMatrixHelpers() }))
    SelfTest.cases.append(("Core.matrixAgainstJSON", { coreMatrixAgainstJSON() }))
    SelfTest.cases.append(("Core.engines", { coreEngines() }))
    SelfTest.cases.append(("Core.optionProfiles", { coreOptionProfiles() }))
    SelfTest.cases.append(("Core.defaultTargets", { coreDefaultTargets() }))
    SelfTest.cases.append(("Core.magic", { coreMagic() }))
    SelfTest.cases.append(("Core.tokens", { coreTokens() }))
    SelfTest.cases.append(("Core.defaultsRoundTrip", { coreDefaultsRoundTrip() }))
    SelfTest.cases.append(("Core.paths", { corePaths() }))
    SelfTest.cases.append(("Core.strings", { coreStrings() }))
    SelfTest.cases.append(("Core.codable", { coreCodable() }))
    SelfTest.cases.append(("Core.contracts", { coreContracts() }))
    SelfTest.cases.append(("Core.moduleGraph", { coreModuleGraph() }))
    SelfTest.cases.append(("Core.fakes", { coreFakes() }))
}

func roundTrips<T: Codable & Equatable>(_ value: T) -> Bool {
    guard let data = try? JSONEncoder().encode(value), let back = try? JSONDecoder().decode(T.self, from: data) else { return false }
    return back == value
}

/// Copy rules of ux §1.1: curly quotes and apostrophes, a real ellipsis, no exclamation marks.
private func followsTone(_ text: String) -> Bool {
    !text.contains("\"") && !text.contains("'") && !text.contains("...") && !text.contains("!")
}

/// The repository root, found from this file's path (nil when the sources are not on disk).
private func repositoryRoot() -> URL? {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }   // <root>/Sources/SuperConverterSelfTest/CoreTests.swift → <root>
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) ? url : nil
}

// MARK: - Formats (formats §1)

@MainActor
private func coreFormats() {
    check(FormatCatalog.inputs.count == 212, "212 catalog formats (\(FormatCatalog.inputs.count))")
    check(Set(FormatCatalog.all.map(\.id)).count == FormatCatalog.all.count, "format ids are unique")
    let expected: [FormatCategory: Int] = [.document: 23, .image: 42, .video: 28, .audio: 21, .spreadsheet: 8, .presentation: 11,
                                           .ebook: 22, .archive: 39, .vector: 10, .cad: 3, .font: 5]
    for category in FormatCategory.allCases {
        check(FormatCatalog.inputs.filter { $0.category == category }.count == expected[category], "\(category.title): \(expected[category] ?? 0) formats")
    }
    check(FormatCatalog.all.filter(\.isOutputOnly).map(\.id.rawValue) == ["sfz"], "SFZ is the one output-only format")
    check(FormatCatalog.all.allSatisfy { !$0.name.isEmpty && $0.id.rawValue == $0.id.rawValue.lowercased() }, "names present, ids lower-case")
    check(FormatCatalog.format("docx")?.name == "Word document" && FormatCatalog.format("docx")?.category == .document, "DOCX")
    check(FormatCatalog.format(forExtension: ".JPG")?.id == "jpg", "extensions are case-insensitive and dot-tolerant")
    check(FormatCatalog.format(forFileName: "backup.2026.tar.gz")?.id == "tar.gz", "the longest known extension wins")
    check(FormatCatalog.format(forFileName: "photo.final.jpg")?.id == "jpg", "inner dots do not matter")
    check(FormatCatalog.format(forFileName: "README") == nil, "no extension, no format")
    // Extensions that are one format share a family (formats §1).
    for (a, b) in [("jpg", "jpeg"), ("jpg", "jfif"), ("tif", "tiff"), ("aif", "aiff"), ("mpg", "mpeg"), ("3gp", "3gpp"), ("tgz", "tar.gz"), ("htm", "html")] {
        check(FormatCatalog.isSameFormat(FormatID(a), FormatID(b)), "\(a) and \(b) are one format")
    }
    check(!FormatCatalog.isSameFormat("png", "jpg"), "PNG and JPG are not")
    check(FormatID("tar.gz").pill == "TAR.GZ", "pills are upper case")
    check(FormatCatalog.format("heic")?.synonyms.contains("iphone") == true, "HEIC is found by “iphone”")
}

@MainActor
private func coreFormatDetails() {
    // Every declared type identifier must exist on this Mac (a wrong one would mislead Open With and drag-and-drop).
    for format in FormatCatalog.all {
        for identifier in format.utTypeIdentifiers {
            check(UTType(identifier) != nil, "\(format.id): \(identifier) is not a type macOS knows")
        }
        for mime in format.mimeTypes {
            check(mime.contains("/") && !mime.contains(" "), "\(format.id): MIME type \(mime)")
        }
    }
    check(FormatCatalog.format("pdf")?.utTypes.first == .pdf, "PDF is public.pdf")
    check(FormatCatalog.format("png")?.utTypes.first == .png && FormatCatalog.format("mp3")?.utTypes.first == .mp3, "PNG, MP3")
    check(FormatCatalog.format("docx")?.mimeTypes.first == "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "DOCX MIME")
}

// MARK: - The matrix (formats §6)

@MainActor
private func coreMatrixShape() {
    let routes = FormatMatrix.routes
    check(routes.count == 2268, "2,268 pairs (\(routes.count))")
    check(routes.filter { $0.origin == .cloudconvert }.count == 2156, "2,156 CloudConvert pairs")
    check(routes.filter { $0.origin == .added }.count + routes.filter { $0.origin == .bonus }.count == 112, "112 pairs we add")
    check(routes.filter { !$0.isOffered }.count == 16, "16 pairs are not offered")
    check(Set(routes.map { "\($0.from)>\($0.to)" }).count == routes.count, "no pair is listed twice")
    check(routes.filter { $0.need == .builtin }.count == 1671 && routes.filter { $0.need == .optional }.count == 121
          && routes.filter { $0.need == .required }.count == 460, "built in 1,671 · helper better 121 · needs helper 460")
    for route in routes {
        check(FormatCatalog.format(route.from).map { !$0.isOutputOnly } == true, "\(route.from): an input in the catalog")
        check(FormatCatalog.format(route.to) != nil, "\(route.to): a format in the catalog")
        check(route.from != route.to || route.options != "—" || !route.isOffered, "\(route.from)>\(route.to)")
    }
    for format in FormatCatalog.inputs {
        check(!FormatMatrix.targets(for: format.id).isEmpty, "\(format.id) has at least one target")
    }
    // Not offered pairs say why (ux §7.2).
    check(FormatMatrix.notOfferedReason(from: "gif", to: "mp3")?.isEmpty == false, "GIF → MP3 says why it is not offered")
    check(FormatMatrix.notOfferedReason(from: "heic", to: "jpg") == nil, "HEIC → JPG is offered")
    check(FormatMatrix.route(from: "heic", to: "jpg")?.rank == .p1, "HEIC → JPG is P1")
    check(FormatMatrix.route(from: "doc", to: "pdf")?.prefer == .helper && FormatMatrix.route(from: "doc", to: "pdf")?.need == .optional,
          "DOC → PDF is built in and prefers the helper when present")
}

@MainActor
private func coreMatrixSteps() {
    for route in FormatMatrix.offered {
        let label = "\(route.from)>\(route.to)"
        check(route.builtin != nil || route.helper != nil, "\(label): at least one route")
        check(route.need != .builtin || route.builtin != nil && route.helper == nil, "\(label): built in means no helper chain")
        check(route.need != .required || route.builtin == nil && route.helper != nil, "\(label): needs helper means only a helper chain")
        check(route.need != .optional || route.builtin != nil && route.helper != nil, "\(label): optional means both chains")
        var chains: [(String, [Step])] = []
        if let b = route.builtin { chains.append(("builtin", b)) }
        if let h = route.helper { chains.append(("helper", h)) }
        chains += route.alternates.map { ("\($0.look)", $0.steps) }
        for (name, steps) in chains {
            check(!steps.isEmpty, "\(label) \(name): steps")
            check(steps.first?.from == .format(route.from), "\(label) \(name): starts at the input (\(steps.first.map(\.description) ?? "-"))")
            check(steps.last?.to == .format(route.to), "\(label) \(name): ends at the output (\(steps.last.map(\.description) ?? "-"))")
            check(zip(steps, steps.dropFirst()).allSatisfy { $0.to == $1.from }, "\(label) \(name): each step starts where the last ended")
            if name == "builtin" {
                check(steps.allSatisfy { $0.engine.info.kind != .helper }, "\(label): the built-in chain uses no helper")
            }
            if name == "helper" {
                check(steps.contains { $0.engine.info.kind == .helper }, "\(label): the helper chain uses a helper")
            }
        }
        check(OptionProfiles.profile(route.options) != nil, "\(label): option profile \(route.options) exists")
    }
    // Spot checks of typed routes.
    let heic = FormatMatrix.route(from: "heic", to: "jpg")?.builtin
    check(heic == [Step(.imageIO, "heic", .imageAsset), Step(.imagePipeline, .imageAsset, .imageAsset), Step(.imageIO, .imageAsset, "jpg")],
          "HEIC → JPG is decode, pipeline, encode")
    check(FormatMatrix.route(from: "pdf", to: "docx")?.builtin == [Step(.layoutKit, "pdf", .docModel), Step(.docxWriter, .docModel, "docx")],
          "PDF → DOCX goes through LayoutKit and the DocModel")
    check(FormatMatrix.route(from: "docx", to: "pdf")?.helper == [Step(.libreOffice, "docx", "pdf")], "DOCX → PDF original layout is LibreOffice")
    check(FormatMatrix.route(from: "html", to: "pdf")?.alternates.first?.look == .latex, "HTML → PDF offers the LaTeX look")
}

@MainActor
private func coreMatrixHelpers() {
    for route in FormatMatrix.offered {
        let label = "\(route.from)>\(route.to)"
        let fromChain = Set((route.helper ?? []).flatMap(\.engine.helpers))
        check(Set(route.helpers) == fromChain, "\(label): helpers \(route.helpers.map(\.rawValue)) match the helper chain \(fromChain.map(\.rawValue).sorted())")
        check(route.helpers.allSatisfy { HelperCatalog.all.map(\.id).contains($0) }, "\(label): helpers are in the catalog")
    }
    check(HelperCatalog.all.count == 13 && Set(HelperCatalog.all.map(\.id)) == Set(HelperID.allCases), "13 helpers, each described once")
    // No public helpers repository [D]: GPL and AGPL helpers are only detected where people have them.
    for info in HelperCatalog.all where info.licence == .copyleft {
        if case .oneClick(let page) = info.install {
            check(info.id == .calibre || info.id == .pandoc, "\(info.name): a copyleft helper downloads from upstream only (\(page))")
        }
    }
    check(HelperCatalog.info(.ghostscript).install == .homebrew(formula: "ghostscript"), "Ghostscript is detected from Homebrew")
    check(HelperCatalog.all.allSatisfy { !$0.detection.isEmpty && !$0.unlocks.isEmpty }, "every helper says where it is looked for and what it unlocks")
}

/// The generated Swift must say what `docs/specs/data/format-matrix.json` says (run the generator, commit both).
@MainActor
private func coreMatrixAgainstJSON() {
    guard let root = repositoryRoot(),
          let data = try? Data(contentsOf: root.appendingPathComponent("docs/specs/data/format-matrix.json")),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let formats = json["formats"] as? [[String: Any]] else {
        print("  (format-matrix.json not found; skipped)")
        return
    }
    var pairs = 0
    for format in formats {
        guard let input = format["input"] as? String, let outputs = format["outputs"] as? [[String: Any]] else { continue }
        for row in outputs {
            guard let output = row["output"] as? String else { continue }
            pairs += 1
            guard let route = FormatMatrix.route(from: FormatID(input), to: FormatID(output)) else {
                check(false, "\(input)>\(output) is in the JSON but not in the generated Swift"); continue
            }
            let need = row["need"] as? String
            check(route.need.rawValue == (need == "no" ? "notOffered" : need), "\(input)>\(output): need")
            check(route.options == (row["options"] as? String), "\(input)>\(output): options")
            if let steps = row["steps"] as? [String: Any] {
                func stepList(_ key: String) -> [String]? {
                    (steps[key] as? [[String: String]])?.map { "\($0["engine"] ?? ""):\($0["from"] ?? "")>\($0["to"] ?? "")" }
                }
                func swiftSteps(_ s: [Step]?) -> [String]? { s?.map { "\($0.engine.rawValue):\($0.from)>\($0.to)" } }
                check(swiftSteps(route.builtin) == stepList("builtin"), "\(input)>\(output): built-in steps")
                check(swiftSteps(route.helper) == stepList("helper"), "\(input)>\(output): helper steps")
                check((steps["alternates"] as? [Any])?.count == route.alternates.count, "\(input)>\(output): alternates")
            }
        }
    }
    check(pairs == FormatMatrix.routes.count, "the JSON and the Swift list the same \(pairs) pairs")
}

@MainActor
private func coreEngines() {
    let used = Set(FormatMatrix.routes.flatMap(\.engines))
    check(used == Set(EngineID.allCases), "every engine is used by a route and every route engine is in the list (unused: \(Set(EngineID.allCases).subtracting(used).map(\.rawValue)))")
    check(EngineID.allCases.count > 100, "the engine list (\(EngineID.allCases.count))")
    check(Set(EngineID.allCases.map(\.rawValue)).count == EngineID.allCases.count, "engine ids are unique")
    for engine in EngineID.allCases {
        let info = engine.info
        check(info.module.role == .engine || info.module == .convertKit, "\(engine.rawValue): owned by an engine module (or ConvertKit)")
        check((info.kind == .helper) == (info.module == .helperKit), "\(engine.rawValue): helper engines belong to HelperKit")
        check((info.kind == .helper) == !engine.helpers.isEmpty, "\(engine.rawValue): helper engines name their helpers")
    }
    check(EngineID(rawValue: "ImageIO") == .imageIO && EngineID(rawValue: "FFmpeg-GPL") == .ffmpegGPL, "raw values are the matrix names")
}

// MARK: - Option profiles (formats §5)

@MainActor
private func coreOptionProfiles() {
    for id in OptionProfiles.baseIDs {
        guard let profile = OptionProfiles.profile(id) else { check(false, "\(id) resolves"); continue }
        check(Set(profile.options.map(\.key)).count == profile.options.count, "\(id): option keys are unique")
        check(!profile.primary.isEmpty, "\(id): at least one plain control")
        check(profile.primary.count <= 6, "\(id): at most a handful of plain controls (\(profile.primary.count))")
        for option in profile.options {
            check(!option.label.isEmpty && followsTone(option.label), "\(id).\(option.key): label “\(option.label)”")
            switch (option.kind, option.defaultValue) {
            case (.toggle, let value?): check(value.bool != nil, "\(id).\(option.key): a toggle defaults to a bool")
            case (.integer(let range, _), let value?): check(value.int.map(range.contains) == true, "\(id).\(option.key): default inside its range")
            case (.number(let range, _), let value?): check(value.double.map(range.contains) == true, "\(id).\(option.key): default inside its range")
            case (.choice(let choices), let value?): check(choices.contains { $0.id == value.string }, "\(id).\(option.key): default is one of the choices")
            default: break
            }
        }
    }
    check(OptionProfiles.profile("O-IMG+Q+DPI")?.definition("quality")?.defaultValue == .int(90), "JPG quality 90 (quality §2.3)")
    check(OptionProfiles.profile("O-IMG+Q")?.definition("quality")?.cloudConvertName == "quality", "quality matches CloudConvert’s `quality`")
    check(OptionProfiles.profile("O-IMG+Q")?.primary.first?.key == "quality", "quality comes first among the image controls (ux §5.5)")
    check(OptionProfiles.profile("O-VIDEO")?.definition("quality")?.defaultValue == .int(20), "CRF 20, not CloudConvert’s 23 (formats §7)")
    check(OptionProfiles.profile("O-AUDIO")?.definition("bitrate")?.defaultValue == .int(192), "AAC 192 kb/s")
    check(OptionProfiles.profile("O-DOC-PDF")?.definition("look")?.defaultValue == .string("asWritten"), "document look")
    check(OptionProfiles.profile("O-WEB+O-DOC-PDF")?.definition("zoom") != nil && OptionProfiles.profile("O-WEB+O-DOC-PDF")?.definition("look") != nil,
          "composite profiles merge both bases")
    check(OptionProfiles.profile("O-NOPE") == nil && OptionProfiles.profile("O-IMG+NOPE") == nil, "unknown profiles do not resolve")
    check(OptionProfiles.profile("O-IMG+Q")!.defaults["quality"] == .int(90), "defaults are the options’ defaults")
    check(OptionProfiles.profile("O-IMG")!.options.filter(\.isAddition).count > 5, "options CloudConvert lacks are marked (⁺)")
}

// MARK: - Default targets (ux §6.1)

@MainActor
private func coreDefaultTargets() {
    for format in FormatCatalog.inputs {
        guard let target = DefaultTargets.target(for: format.id) else { check(false, "\(format.id) has a default target"); continue }
        check(FormatMatrix.route(from: format.id, to: target)?.isOffered == true, "\(format.id) → \(target) is an offered pair")
        check(format.id != target, "\(format.id) does not default to itself")
    }
    func d(_ s: FormatID, _ t: DefaultTargets.Traits = .init()) -> FormatID? { DefaultTargets.target(for: s, traits: t) }
    check(d("heic") == "jpg" && d("nef") == "jpg" && d("jpg") == "pdf", "HEIC and RAW become JPG, JPG becomes PDF")
    check(d("gif", .init(isAnimated: true)) == "mp4" && d("gif") == "png", "animated GIF becomes MP4")
    check(d("webp") == "jpg" && d("webp", .init(hasTransparency: true)) == "png" && d("avif") == "jpg", "WEBP and AVIF keep transparency")
    check(d("ai") == "svg" && d("svg") == "png" && d("docx") == "pdf" && d("pdf") == "docx", "vector and documents")
    check(d("xlsx") == "pdf" && d("xls") == "xlsx" && d("pptx") == "pdf" && d("ppt") == "pptx", "sheets and slides")
    check(d("epub") == "pdf" && d("mobi") == "epub" && d("mov") == "mp4" && d("mp4") == "mp3", "e-books and video")
    check(d("wav") == "mp3" && d("mp3") == "wav" && d("rar") == "zip" && d("zip") == "7z", "audio and archives")
    check(d("ttf") == "woff2" && d("woff2") == "ttf" && d("dwg") == "pdf" && d("sf2") == "zip" && d("sfark") == "sf2", "fonts, CAD, soundfonts")
    check(d("ogg") == "mp3" && d("ogg", .init(hasVideo: true)) == "mp4", "Ogg audio or video")
    check(DefaultTargets.target(for: "heic", remembered: "png") == "png", "the last choice wins when it is offered")
    check(DefaultTargets.target(for: "gif", remembered: "mp3") == "png", "a remembered target that is not offered is ignored")
}

// MARK: - Magic bytes (ux §6.2)

@MainActor
private func coreMagic() {
    let catalog = Set(FormatCatalog.all.map(\.id))
    for rule in MagicTable.rules {
        check(catalog.contains(rule.format), "magic rule for \(rule.format) names a catalog format")
        check(!rule.bytes.isEmpty, "\(rule.format): a rule needs bytes")
        check(rule.family.allSatisfy(catalog.contains), "\(rule.format): family members exist")
        check(rule.offset + rule.bytes.count <= MagicTable.headerLength, "\(rule.format): the signature fits the header")
    }
    for rule in MagicTable.zipRules { check(catalog.contains(rule.format), "zip rule for \(rule.format)") }
    func sniff(_ bytes: [UInt8], at offset: Int = 0) -> FormatID? {
        var header = [UInt8](repeating: 0, count: MagicTable.headerLength)
        for (i, b) in bytes.enumerated() where offset + i < header.count { header[offset + i] = b }
        return MagicTable.rules.first { $0.matches(header) }?.format
    }
    let ascii: (String) -> [UInt8] = { Array($0.utf8) }
    check(sniff(ascii("%PDF-1.7")) == "pdf" && sniff([0x89] + ascii("PNG\r\n") + [0x1A, 0x0A]) == "png", "PDF, PNG")
    check(sniff([0xFF, 0xD8, 0xFF, 0xE0]) == "jpg" && sniff(ascii("GIF89a")) == "gif", "JPEG, GIF")
    check(sniff(ascii("ftypheic"), at: 4) == "heic" && sniff(ascii("ftypmif1"), at: 4) == "heif", "HEIC and HEIF brands")
    check(sniff(ascii("RIFF") + [0, 0, 0, 0] + ascii("WEBP")) == "webp" && sniff(ascii("RIFF") + [0, 0, 0, 0] + ascii("WAVE")) == "wav"
          && sniff(ascii("RIFF") + [0, 0, 0, 0] + ascii("AVI ")) == "avi" && sniff(ascii("RIFF") + [0, 0, 0, 0] + ascii("sfbk")) == "sf2",
          "RIFF forms")
    check(sniff(ascii("Rar!") + [0x1A, 0x07, 0x00]) == "rar" && sniff([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) == "7z" && sniff([0x1F, 0x8B, 8]) == "gz",
          "RAR, 7Z, gzip")
    check(sniff(ascii("ID3")) == "mp3" && sniff(ascii("fLaC")) == "flac" && sniff(ascii("OggS")) == "ogg", "MP3, FLAC, Ogg")
    check(sniff([0x1A, 0x45, 0xDF, 0xA3]) == "mkv" && sniff(ascii("FWS")) == "swf" && sniff(ascii("AC1027")) == "dwg", "Matroska, SWF, DWG")
    check(sniff([0x50, 0x4B, 3, 4]) == "zip", "PK is a ZIP until its entries say more")
    check(MagicTable.zipRules.first { $0.format == "docx" }?.requiredEntries == ["word/document.xml"], "DOCX is told apart by word/document.xml")
    let m = MagicRule("png", [0x89, 0x50])
    check(m.matches([0x89, 0x50, 0x00]) && !m.matches([0x89]), "a short header never matches")
}

// MARK: - Design tokens (ux §3)

@MainActor
private func coreTokens() {
    check(SCColor.categories.count == 11 && Set(SCColor.categories.map(\.category)) == Set(FormatCategory.allCases), "eleven category hues")
    for c in SCColor.categories {
        let name = c.category.title
        let light = SCColor.contrast(c.ink, c.tint), dark = SCColor.contrast(c.darkInk, c.darkTint)
        func tenth(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        check(tenth(light) >= c.inkContrast.light - 0.05 && light >= 4.5, "\(name): ink on tint \(light) ≥ \(c.inkContrast.light) (light)")
        check(tenth(dark) >= c.inkContrast.dark - 0.05 && dark >= 4.5, "\(name): ink on tint \(dark) ≥ \(c.inkContrast.dark) (dark)")
        let filled = SCColor.contrast(c.filledTextHex, c.filledFillHex)
        check(tenth(filled) >= c.filledContrast - 0.05 && filled >= 4.5, "\(name): filled pill \(filled) ≥ \(c.filledContrast)")
        // Tint = base 13 % into white; deep = base 45 % toward ink (ux §3.2). Within one step per channel.
        func close(_ a: String, _ b: String) -> Bool {
            let x = NSColor(hex: a).usingColorSpace(.sRGB)!, y = NSColor(hex: b).usingColorSpace(.sRGB)!
            return abs(x.redComponent - y.redComponent) < 3.0 / 255 && abs(x.greenComponent - y.greenComponent) < 3.0 / 255
                && abs(x.blueComponent - y.blueComponent) < 3.0 / 255
        }
        check(close(SCColor.mix("#FFFFFF", with: c.base, fraction: 0.13), c.tint), "\(name): tint is the base mixed 13 % into white (\(SCColor.mix("#FFFFFF", with: c.base, fraction: 0.13)) vs \(c.tint))")
        check(close(SCColor.mix(c.base, with: c.ink, fraction: 0.45), c.deep), "\(name): deep is the base mixed 45 % toward ink (\(SCColor.mix(c.base, with: c.ink, fraction: 0.45)) vs \(c.deep))")
        check(c.baseToken.color.hexRGBA.hasPrefix(c.base), "\(name): base token renders its hex")
    }
    check(SCColor.contrast("#FFFFFF", "#000000") > 20.9 && SCColor.contrast("#777777", "#777777") == 1, "contrast formula")
    check(SCColor.contrast(SCColor.label.light, SCColor.card.light) > 15 && SCColor.contrast(SCColor.label.dark, SCColor.card.dark) > 12, "text on cards")
    check(SCColor.contrast(SCColor.secondaryLabel.light, SCColor.card.light) >= 4.5 && SCColor.contrast(SCColor.secondaryLabel.dark, SCColor.card.dark) >= 4.5,
          "secondary text on cards is AA")
    check(SCColor.neutrals.allSatisfy { !$0.light.isEmpty && !$0.dark.isEmpty }, "neutrals have both appearances")

    check(SCFont.all.count == 9 && SCFont.display.size == 30 && SCFont.display.weight == .heavy, "type roles (ux §3.1)")
    check(SCFont.all.allSatisfy { $0.font.pointSize == $0.size && $0.line >= $0.size }, "fonts resolve at their size, lines are not tighter than the size")
    check(SCMetrics.Card.size == NSSize(width: 208, height: 250) && SCMetrics.Card.thumbnailWell == NSSize(width: 192, height: 132), "card metrics")
    check(SCMetrics.ActionBar.height == 76 && SCMetrics.ActionBar.buttonHeight == 44 && SCMetrics.Picker.width == 452, "action bar and picker metrics")
    check(SCMetrics.Window.defaultSize == NSSize(width: 1080, height: 700) && SCMetrics.Window.minimumSize == NSSize(width: 640, height: 480), "window metrics")
    check(SCMotion.cardAppear == SCSpring(response: 0.35, dampingFraction: 0.8) && SCMotion.cardStaggerLimit == 12 && SCMotion.tintCrossFade == 0.4, "motion")
}

// MARK: - Defaults (ux §5.11)

@MainActor
private func coreDefaultsRoundTrip() {
    var checked: Set<String> = []
    func roundTrip<V: Codable & Equatable>(_ key: Defaults.Key<V>, _ value: V, native: Bool = false) {
        checked.insert(key.name)
        check(Defaults[key] == key.defaultValue, "\(key.name) starts at its default")
        check(value != key.defaultValue, "\(key.name): the test value differs from the default")
        var seen: [V] = []
        let watcher = Defaults.publisher(key).sink { seen.append($0) }
        Defaults[key] = value
        check(Defaults[key] == value, "\(key.name) reads back what was written")
        check(seen == [key.defaultValue, value], "\(key.name) publishes the default, then the change")
        if native {
            // Plain values stay readable with `defaults read`.
            check(Defaults.store.object(forKey: key.name) is NSNumber || Defaults.store.object(forKey: key.name) is String,
                  "\(key.name) is stored natively")
        }
        Defaults.reset(key)
        check(Defaults[key] == key.defaultValue, "\(key.name) resets to its default")
        watcher.cancel()
    }

    roundTrip(.outputPlace, .downloads)
    roundTrip(.outputPlace, .folder(URL(fileURLWithPath: "/Users/Shared")))
    roundTrip(.collisionPolicy, .replace, native: true)
    roundTrip(.rememberFormatChoices, false, native: true)
    roundTrip(.showInMenuBar, false, native: true)
    roundTrip(.convertOnMenuBarDrop, true, native: true)
    roundTrip(.notifyWhenDone, false, native: true)
    roundTrip(.playSound, true, native: true)
    roundTrip(.checkForUpdates, false, native: true)
    roundTrip(.viewMode, .list, native: true)
    roundTrip(.target(for: "heic"), "png")
    roundTrip(.savedOptions(for: "jpg"), OptionValues(["quality": 75, "progressive": false, "colourProfile": "srgb"]))
    roundTrip(.helperPath(.libreoffice), URL(fileURLWithPath: "/Applications/LibreOffice.app"), native: true)
    check(checked.count == 12, "every key is exercised (\(checked.count) of 12)")

    check(Defaults.Keys.checkForUpdates.defaultValue && Defaults.Keys.showInMenuBar.defaultValue && Defaults.Keys.rememberFormatChoices.defaultValue,
          "updates, the menu-bar item and remembered choices start on")
    check(!Defaults.Keys.playSound.defaultValue && !Defaults.Keys.convertOnMenuBarDrop.defaultValue, "the sound and menu-bar auto-convert start off")
    check(Defaults.Keys.outputPlace.defaultValue == .nextToOriginal && Defaults.Keys.collisionPolicy.defaultValue == .addNumber, "results next to the originals, numbered")
    check(Defaults.Keys.target(for: "heic").name == "target.heic" && Defaults.Keys.savedOptions(for: "jpg").name == "options.jpg", "dynamic key names")
}

// MARK: - Paths and bootstrap (ARCHITECTURE §8, §9)

@MainActor
private func corePaths() {
    let base = SuperConverterPaths.base
    check(SuperConverterPaths.support.path.hasPrefix(base.path) && SuperConverterPaths.support.lastPathComponent == "Super Converter", "support folder")
    check(SuperConverterPaths.helpers.lastPathComponent == "Helpers" && SuperConverterPaths.helpersRecord.lastPathComponent == "helpers.json", "helpers")
    let id = JobID()
    check(SuperConverterPaths.job(id).path.hasSuffix("Jobs/\(id.rawValue.uuidString.lowercased())"), "work folder per job")
    check(FileManager.default.fileExists(atPath: SuperConverterPaths.job(id).path), "work folders are created")
    check(SuperConverterPaths.helper(.calibre, version: "7.0").path.hasSuffix("Helpers/calibre/7.0"), "helper folder")
    check(SuperConverterPaths.thumbnails.path.hasSuffix("Super Converter/thumbnails") && SuperConverterPaths.thumbnails.path.hasPrefix(SuperConverterPaths.cacheBase.path), "thumbnails live in Caches")
    check(SuperConverterPaths.recent.lastPathComponent == "recent.json" && SuperConverterPaths.updateState.lastPathComponent == "update.json", "recent and update files")
    check(SuperConverterPaths.libreOfficeProfile.lastPathComponent == "lo-profile" && SuperConverterPaths.tectonicCache.lastPathComponent == "tectonic-cache", "helper state")
    check(SuperConverterPaths.freeSpace(at: base) > 0, "free space is reported")

    // The environment gives tests throwaway places and no updater.
    let savedBase = SuperConverterPaths.base, savedCache = SuperConverterPaths.cacheBase, savedStore = Defaults.store
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sc-bootstrap-\(UUID().uuidString)")
    let suite = "superconverter-bootstrap-\(UUID().uuidString)"
    check(CoreBootstrap.configure(environment: ["SUPERCONVERTER_DATA_DIR": temp.path, "SUPERCONVERTER_DEFAULTS_SUITE": suite]), "overrides report a throwaway run")
    check(SuperConverterPaths.base.path == temp.appendingPathComponent("Application Support").path, "SUPERCONVERTER_DATA_DIR moves Application Support")
    check(SuperConverterPaths.cacheBase.path == temp.appendingPathComponent("Caches").path, "…and Caches")
    check(Defaults.store !== savedStore, "SUPERCONVERTER_DEFAULTS_SUITE moves the defaults")
    check(!CoreBootstrap.configure(environment: [:]), "no overrides, no throwaway run")
    SuperConverterPaths.base = savedBase
    SuperConverterPaths.cacheBase = savedCache
    Defaults.store = savedStore
    UserDefaults.standard.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: temp)
    try? FileManager.default.removeItem(at: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Preferences/\(suite).plist"))
    check(SuperConverterPaths.urlScheme == "superconverter" && SuperConverterPaths.repository.absoluteString == "https://github.com/udsy19/super-converter", "scheme and repository")
}

// MARK: - Strings (ux §7)

@MainActor
private func coreStrings() {
    var lines: [String] = [
        Strings.Window.emptyHeadline, Strings.Window.emptyLine, Strings.Window.chooseFiles, Strings.Window.emptyFootnote,
        Strings.Window.dragHeadline(1), Strings.Window.dragHeadline(3), Strings.Window.convertButton(files: 8),
        Strings.Window.subtitle(files: 8, bytes: 1_700_000_000), Strings.Window.subtitleConverting(done: 2, of: 8), Strings.Window.subtitleConverted(done: 7, of: 8),
        Strings.Window.dragLine([(.image, 2), (.video, 1)]),
        Strings.Card.progress(percent: 62, secondsLeft: 40), Strings.Card.page(3, of: 12), Strings.Card.slide(7, of: 18), Strings.Card.chapter(4, of: 31),
        Strings.Card.waiting, Strings.Card.waiting(for: .calibre), Strings.Card.done(newSize: 1_900_000, oldSize: 4_200_000), Strings.Card.mismatch("png"),
        Strings.Card.unreadable, Strings.ActionBar.converting(done: 2, of: 8), Strings.ActionBar.done(ok: 7, of: 8),
        Strings.ActionBar.doneDetail(old: 1_700_000_000, new: 356_000_000, place: "next to the originals", needAttention: 1),
        Strings.Helper.needs(.calibre), Strings.Helper.cost(.calibre), Strings.Helper.installing(.calibre, percent: 64),
        Strings.Helper.betterWithHelper(.libreoffice), Strings.Picker.searchPlaceholder(count: 16, source: "heic"),
        Strings.Picker.useFromNowOn("jpg", source: "heic"), Strings.Picker.needsHelperHint(.calibre),
    ]
    let errors: [ConversionError] = [
        .passwordRequired("pdf"), .damaged("docx"), .drmProtected, .helperMissing(.calibre), .helperMissing(.libreoffice),
        .helperTimedOut(.libreoffice, seconds: 120), .notEnoughSpace(volume: "Macintosh HD", needed: 1_200_000_000),
        .folderNotWritable(name: "Shared"), .notReadableYet, .classicDWF, .impossiblePair(reason: "GIF pictures have no sound"),
        .unsupportedPair(from: "gif", to: "mp3"), .cancelled,
        .needsConfirmation(question: "This archive unpacks to over 1,000 times its size — extract it anyway?",
                           proceed: .extractAnyway, option: "extractAnyway"),
    ]
    lines += errors.map { Strings.problem($0, libreOfficeInstalled: true).message }
    lines += LossNote.Kind.allCases.map { LossNote($0).headline }
    for line in lines { check(followsTone(line), "tone of “\(line)”: curly quotes, a real ellipsis, no exclamation marks") }

    check(Strings.Window.dragHeadline(3) == "Drop 3 files to add them" && Strings.Window.dragHeadline(1) == "Drop 1 file to add it", "drag headline")
    check(Strings.Window.dragLine([(.image, 2), (.video, 1)]) == "2 photos and a video. You’ll pick what each becomes next.", "drag line (ux §5.2)")
    check(Strings.Window.subtitle(files: 8, bytes: 1_700_000_000) == "8 files · 1.7 GB" && Strings.Window.convertButton(files: 8) == "Convert 8 files", "subtitle and button")
    check(Strings.ActionBar.done(ok: 7, of: 8) == "Done. 7 of 8 files converted", "done line")
    check(Strings.Helper.needs(.calibre) == "Needs calibre" && Strings.Helper.cost(.calibre) == "Free · 160 MB", "helper notice (ux §7.1)")
    check(Strings.Picker.needsHelperHint(.calibre) == "Needs calibre — free, 160 MB", "picker hint (ux §5.4)")
    check(Strings.Helper.betterWithHelper(.libreoffice) == "Make it look like the original — Install LibreOffice", "optional helper line")
    check(Strings.problem(.passwordRequired("pdf")) == ("This PDF needs its password", .enterPassword), "password problem")
    check(Strings.problem(.needsConfirmation(question: "Extract it anyway?", proceed: .extractAnyway, option: "extractAnyway")) == ("Extract it anyway?", .extractAnyway)
          && ConversionError.Fix.extractAnyway.rawValue == "Extract Anyway", "a question is the card's line, its proceed the button (quality §8)")
    check(Strings.problem(.helperTimedOut(.libreoffice, seconds: 120)).message == "LibreOffice took longer than 2 minutes and was stopped", "timeout problem")
    check(Strings.problem(.notEnoughSpace(volume: "Macintosh HD", needed: 1_200_000_000)).message == "There isn’t enough space on “Macintosh HD” — 1.2 GB more is needed",
          "space problem")
    check(Strings.problem(.helperMissing(.calibre)).fix == .install && Strings.problem(.helperMissing(.oda)).fix == .get, "Install for one-click helpers, Get… for vendor apps")
    check(Strings.problem(.damaged("docx"), libreOfficeInstalled: false).fix == nil && Strings.problem(.damaged("docx"), libreOfficeInstalled: true).fix == .tryWithLibreOffice,
          "Try with LibreOffice only when it is installed")
    check(Strings.Window.popularPairs.count == 8 && Strings.Window.popularPairs.allSatisfy { FormatMatrix.route(from: $0.from, to: $0.to)?.isOffered == true },
          "the popular pairs are offered pairs")
    check(Strings.quoted("Report.pdf") == "“Report.pdf”", "curly quotes around names")
    check(Formatting.timeLeft(40) == "about 40 s left" && Formatting.timeLeft(300) == "about 5 min left" && Formatting.count(1, "file", "files") == "1 file", "formatting")
}

// MARK: - Codable and value types

@MainActor
private func coreCodable() {
    check(roundTrips(OptionValues(["quality": 75, "lossless": true, "fit": "max", "scale": 1.5])), "OptionValues round-trips")
    check(String(data: (try? JSONEncoder().encode(OptionValues(["quality": 75, "fit": "max"]))) ?? Data(), encoding: .utf8)?.contains("\"quality\":75") == true,
          "options are plain JSON scalars")
    check(roundTrips(Step(.imageIO, "heic", .imageAsset)) && roundTrips(StepEndpoint.model(.docModel)) && roundTrips(FormatID("tar.gz")), "steps and ids")
    check(String(data: (try! JSONEncoder().encode(Step(.imageIO, "heic", .imageAsset))), encoding: .utf8)!.contains("\"@ImageAsset\""), "models encode as @Name")
    for route in FormatMatrix.routes.prefix(40) { check(roundTrips(route), "\(route.from)>\(route.to) round-trips") }
    check(roundTrips(OutputPlace.nextToOriginal) && roundTrips(OutputPlace.folder(URL(fileURLWithPath: "/tmp"))) && roundTrips(CollisionPolicy.ask), "output place")

    // Intermediate models are plain Sendable, Codable data.
    let image = ImageAsset(frames: [ImageFrame(width: 2, height: 1, pixels: .rgba8(Data([255, 0, 0, 255, 0, 255, 0, 128]), bytesPerRow: 8), hasAlpha: true,
                                               iccProfile: Data([1, 2, 3]), delay: 0.1)], loopCount: 0)
    check(roundTrips(image) && image.hasAlpha && !image.isAnimated, "ImageAsset")
    let vector = VectorDocument(pages: [VectorPage(size: VectorSize(width: 100, height: 50), nodes: [
        .path([.move(VectorPoint(0, 0)), .line(VectorPoint(10, 10)), .close], fill: .solid(VectorColour(red: 1, green: 0, blue: 0)), stroke: nil),
        .group([.text(VectorTextRun(text: "Hi", fontName: "Helvetica", size: 12, origin: VectorPoint(1, 1), fill: .solid(VectorColour(red: 0, green: 0, blue: 0))))],
               transform: .identity, clip: nil, opacity: 0.5),
    ])])
    check(roundTrips(vector), "VectorDocument")
    let doc = DocModel(metadata: DocMetadata(title: "T", authors: ["A"]), blocks: [
        .heading(level: 1, [.text("Title")]),
        .paragraph([.text("Hello "), .strong([.text("world")]), .math(tex: "x^2")], DocParagraphStyle()),
        .list(ordered: true, start: 1, items: [[.paragraph([.text("one")], DocParagraphStyle())]]),
        .table(DocTable(rows: [[DocTable.Cell(blocks: [.paragraph([.text("c")], DocParagraphStyle())], isHeader: true)]])),
    ])
    check(roundTrips(doc), "DocModel")
    check(roundTrips(LayoutDocument(pages: [LayoutPage(size: VectorSize(width: 612, height: 792), blocks: [
        .paragraph([LayoutLine(words: [LayoutWord(text: "a", box: LayoutBox(x: 0, y: 0, width: 5, height: 9), fontName: "F", fontSize: 9)],
                               box: LayoutBox(x: 0, y: 0, width: 5, height: 9))], column: 0)])])), "LayoutDocument")
    check(roundTrips(Workbook(sheets: [Sheet(name: "S", rows: [[Cell(value: .number(1)), Cell(value: .text("a"), formula: "A1")]])])), "Workbook")
    check(roundTrips(Deck(size: VectorSize(width: 960, height: 540), slides: [Slide(title: "T", shapes: [
        SlideShape(box: LayoutBox(x: 0, y: 0, width: 10, height: 10), content: .text([.heading(level: 1, [.text("T")])]))])])), "Deck")
    check(roundTrips(Publication(spine: [PublicationItem(id: "c1", content: .document(doc))], contents: [ContentsEntry(title: "C", itemID: "c1")])), "Publication")
    check(roundTrips(ArchiveTree(entries: [.init(path: "a/b.txt", kind: .file, size: 3)])) && ArchiveTree(entries: [.init(path: "a", kind: .file, size: 3)]).totalSize == 3, "ArchiveTree")
    check(roundTrips(MediaPlan(engine: .avFoundation, container: "mp4", streams: [.init(index: 0, kind: .video, codec: "h264")])), "MediaPlan")
    check(roundTrips(FontModel(familyName: "F", glyphs: [.init(name: "a", advance: 500, contours: [.init(points: [.init(0, 0), .init(10, 10, onCurve: false)])])])), "FontModel")
    check(roundTrips(CADDrawing(layers: [.init(name: "0")], modelSpace: [.line(.init(0, 0), .init(1, 1), layer: "0")])), "CADDrawing")
    check(roundTrips(LossNote(.layersFlattened, detail: "3 layers")), "LossNote")
    check(ModelKind.allCases.count == 11, "eleven intermediate models")
}

// MARK: - Contracts

@MainActor
private func coreContracts() {
    let jpeg = FakeConverter(.imageIO, handles: [StepPattern(from: .formats(["heic", "jpg"]), to: .model(.imageAsset)),
                                                 StepPattern(from: .model(.imageAsset), to: .formats(["jpg", "png"]))])
    check(jpeg.handles(Step(.imageIO, "heic", .imageAsset)) && jpeg.handles(Step(.imageIO, .imageAsset, "png")), "a converter handles the patterns it declares")
    check(!jpeg.handles(Step(.imageIO, "bmp", .imageAsset)) && !jpeg.handles(Step(.imageIO, "heic", "jpg")) && !jpeg.handles(Step(.libwebp, "heic", .imageAsset)),
          "…and nothing else, nor another engine’s steps")
    check(StepPattern(from: .anyFile, to: .model(.docModel)).matches(Step(.docxReader, "docx", .docModel)) && !StepPattern(from: .anyFile, to: .anyFile).matches(Step(.docxReader, "docx", .docModel)),
          "any-file patterns match files, not models")

    let registry = ConverterList()
    registry.register(jpeg)
    registry.register(FakeConverter(.libwebp))
    registry.register(FakeConverter(.imageIO))
    check(registry.converters.count == 2 && (registry.converter(for: .imageIO) as AnyObject?) !== jpeg && registry.converter(for: .avifEncoder) == nil, "registering twice replaces")
    check(Services.converters is ConverterList, "the registry exists from the start")

    check(StepValue.file(URL(fileURLWithPath: "/x")).model == nil && StepValue.doc(DocModel()).model == .docModel && StepValue.cad(CADDrawing()).model == .cadDrawing, "step values know their model")
    let plan = ConversionPlan(request: ConversionRequest(source: URL(fileURLWithPath: "/a.heic"), sourceFormat: "heic", target: "jpg"),
                              choice: .helper(steps: [Step(.libreOffice, "doc", "pdf")], helpers: [.libreoffice], missing: [.libreoffice]), optionProfile: "O-IMG+Q")
    check(plan.choice.steps.count == 1 && RouteChoice.unavailable(reason: .notOffered("x")).steps.isEmpty, "route choices expose their steps")
    check(ConversionError.passwordRequired("pdf") == .passwordRequired("pdf") && ConversionError.cancelled != .classicDWF, "errors compare")
    let neighbour = SniffResult(format: "png", claimed: "jpg")
    check(neighbour.mismatch && !SniffResult(format: "jpeg", claimed: "jpg").mismatch && !SniffResult(format: nil, claimed: "jpg").mismatch, "a mismatch is a different format, not a different extension")
    check(HelperStatus.installed(version: "1", location: URL(fileURLWithPath: "/x"), sizeOnDisk: nil).isReady && !HelperStatus.notInstalled.isReady, "helper status")
    check(SettingsPane.allCases.map(\.title) == ["General", "Formats", "Helpers", "Quick Actions", "About"], "Settings panes (ux §5.11)")
    check(DocumentLook.allCases.count == 3, "three document looks")
}

// MARK: - Module graph (ARCHITECTURE §4)

@MainActor
private func coreModuleGraph() {
    check(!ModuleGraph.hasCycle, "the engine edges have no cycle")
    check(ModuleID.allCases.count == 21 && ModuleID.allCases.filter { $0.role == .feature }.count == 4, "21 modules, 4 of them feature modules")
    check(ModuleGraph.allowedImports(of: .windowKit).isEmpty && ModuleGraph.allowedImports(of: .convertKit).contains(.imageKit), "feature modules import no engines, except ConvertKit")
    check(!ModuleGraph.allowedImports(of: .convertKit).contains(.windowKit), "ConvertKit does not import feature modules")

    guard let root = repositoryRoot() else { print("  (sources not on disk; imports not scanned)"); return }
    let moduleNames = Set(ModuleID.allCases.map(\.rawValue))
    for module in ModuleID.allCases {
        let folder = root.appendingPathComponent("Sources/\(module.rawValue)")
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            check(false, "Sources/\(module.rawValue) exists"); continue
        }
        for case let file as URL in files where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.hasPrefix("import ") {
                let imported = line.dropFirst(7).split(separator: ".").first.map(String.init) ?? ""
                if moduleNames.contains(imported), let other = ModuleID(rawValue: imported) {
                    check(other == module || ModuleGraph.allowedImports(of: module).contains(other),
                          "\(module.rawValue) imports \(imported) (\(file.lastPathComponent)), which ARCHITECTURE §4 does not allow")
                }
            }
        }
    }
    // Package.swift mirrors the table.
    if let manifest = try? String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8) {
        for (module, imports) in ModuleGraph.engineEdges {
            let line = "\"\(module.rawValue)\": [" + imports.map { "\"\($0.rawValue)\"" }.sorted().joined(separator: ", ") + "]"
            let alternative = "\"\(module.rawValue)\": [" + imports.map { "\"\($0.rawValue)\"" }.joined(separator: ", ") + "]"
            check(manifest.contains(line) || manifest.contains(alternative) || manifestEdges(manifest, module) == Set(imports.map(\.rawValue)),
                  "Package.swift lists the edges of \(module.rawValue)")
        }
    }
}

/// The imports Package.swift's `engineEdges` gives a module.
private func manifestEdges(_ manifest: String, _ module: ModuleID) -> Set<String> {
    guard let line = manifest.split(separator: "\n").first(where: { $0.contains("\"\(module.rawValue)\": [") }),
          let open = line.firstIndex(of: "["), let close = line.lastIndex(of: "]") else { return [] }
    return Set(line[line.index(after: open)..<close].split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) })
}

// MARK: - Fakes

@MainActor
private func coreFakes() {
    installFakes()
    check(Services.converters is ConverterList && Services.planner is FakePlanner && Services.queue is FakeQueue && Services.sniffer is FakeSniffer
          && Services.output is FakeOutput && Services.thumbnails is FakeThumbnails && Services.helpers is FakeHelpers && Services.window is FakeWindow
          && Services.menuBar is FakeMenuBar && Services.settings is FakeSettings && Services.updates is FakeUpdates, "every slot has a fake")

    let request = ConversionRequest(source: URL(fileURLWithPath: "/tmp/a.heic"), sourceFormat: "heic", target: "jpg")
    let plan = Services.planner.plan(for: request)
    check(plan.request == request && (Services.planner as! FakePlanner).requests == [request], "the planner records requests")
    check(Services.planner.targets(for: "heic").map(\.format).contains("jpg"), "the planner lists the matrix’s targets")
    let job = Services.queue.enqueue(plan, into: .nextToOriginal)
    Services.queue.cancel(job)
    check((Services.queue as! FakeQueue).enqueued.count == 1 && (Services.queue as! FakeQueue).cancelled == [job], "the queue records jobs")
    check((try? Services.sniffer.sniff(URL(fileURLWithPath: "/tmp/x.docx")))?.format == "docx", "the sniffer reads the extension")
    check((try? Services.output.target(for: URL(fileURLWithPath: "/tmp/a.heic"), format: "jpg", place: .nextToOriginal, multipleFiles: false))?.url.lastPathComponent == "a.jpg", "output naming")
    check(Services.output.partName(base: "Report", kind: "page", index: 3, format: "png") == "Report – page 3.png", "page names use an en dash")

    let helpers = Services.helpers as! FakeHelpers
    check(helpers.status(of: .calibre) == .notInstalled, "helpers start missing")
    if let result = complete(5, { () -> Int in
        var finished = 0
        for await progress in helpers.install(.calibre) { if case .finished = progress { finished += 1 } }
        return finished
    }) { check((try? result.get()) == 1, "installing finishes") } else { check(false, "installing timed out") }
    check(helpers.status(of: .calibre).isReady, "…and the helper is ready")
    Services.window.add([URL(fileURLWithPath: "/tmp/a.heic")], target: "png")
    check((Services.window as! FakeWindow).added.first?.target == "png" && Services.window.hasWork, "the window records files")
    Services.updates.checkNow()
    check((Services.updates as! FakeUpdates).checks == 1, "the updater records checks")
    Services.converters = ConverterList()
}
