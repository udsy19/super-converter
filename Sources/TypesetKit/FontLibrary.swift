import CoreText
import Foundation
import SuperConverterCore

/// The fonts TypesetKit sets type with (Resources/Fonts, formats §3): Latin Modern Roman/Sans/Mono at optical sizes,
/// Latin Modern Math, CMU Serif/Sans/Typewriter for Greek and Cyrillic, STIX Two Math for symbols Latin Modern Math
/// lacks, and Carlito/Caladea for the "As written" look (quality §3.5). Fonts are opened from their files and never
/// registered with the system.
public final class FontLibrary: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var descriptors: [String: CTFontDescriptor] = [:]
    private var fonts: [FontKey: CTFont] = [:]

    private struct FontKey: Hashable { let file: String; let size: Double }

    /// Files every look needs; `init` fails when one is missing so a broken bundle is caught at launch, not mid-job.
    static let requiredFiles = [
        "LatinModern/lmroman10-regular.otf", "LatinModern/lmroman10-bold.otf", "LatinModern/lmroman10-italic.otf",
        "LatinModern/lmmono10-regular.otf", "LatinModern/lmsans10-regular.otf", "LatinModernMath/latinmodern-math.otf",
        "CMU/cmunrm.otf", "STIXTwo/STIXTwoMath-Regular.otf", "Carlito/Carlito-Regular.ttf", "Caladea/Caladea-Regular.ttf",
    ]

    public init(directory: URL) throws {
        self.directory = directory
        for file in Self.requiredFiles where !FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) {
            throw TypesetError.missingFont(file)
        }
    }

    /// The fonts shipped with the app: `Contents/Resources/Fonts` in the bundle, else the repository's `Resources/Fonts`
    /// when running from a SwiftPM build (self-test, `sconv`, the bench).
    public static func bundled() -> FontLibrary? {
        for url in SuperConverterPaths.bundledResources("Fonts") { if let library = try? FontLibrary(directory: url) { return library } }
        return nil
    }

    public func url(_ file: String) -> URL { directory.appendingPathComponent(file) }

    func descriptor(_ file: String) -> CTFontDescriptor? {
        lock.lock(); defer { lock.unlock() }
        if let d = descriptors[file] { return d }
        guard let list = CTFontManagerCreateFontDescriptorsFromURL(url(file) as CFURL) as? [CTFontDescriptor],
              let d = list.first else { return nil }
        descriptors[file] = d
        return d
    }

    /// The font in `file` at `size` (TeX points; the renderer scales to PDF units). Characters the font lacks come
    /// from the matching CMU face, then Latin Modern Math and STIX Two Math, then the system's cascade (CJK, Arabic, …).
    func font(_ file: String, size: Double) -> CTFont {
        let key = FontKey(file: file, size: size)
        lock.lock()
        if let f = fonts[key] { lock.unlock(); return f }
        lock.unlock()
        let made: CTFont
        if var d = descriptor(file) {
            let fallbacks = cascadeFiles(for: file).compactMap(descriptor)
            if !fallbacks.isEmpty {
                d = CTFontDescriptorCreateCopyWithAttributes(d, [kCTFontCascadeListAttribute: fallbacks] as CFDictionary)
            }
            made = CTFontCreateWithFontDescriptor(d, CGFloat(size), nil)
        } else {
            made = CTFontCreateWithName("Times-Roman" as CFString, CGFloat(size), nil)
        }
        lock.lock(); fonts[key] = made; lock.unlock()
        return made
    }

    private func cascadeFiles(for file: String) -> [String] {
        let name = (file as NSString).lastPathComponent.lowercased()
        let bold = name.contains("bold")
        let italic = name.contains("italic") || name.contains("oblique") || name.contains("slant")
        var list: [String]
        if name.hasPrefix("lmmono") { list = ["CMU/cmuntt.otf"] }
        else if name.hasPrefix("lmsans") { list = [bold ? "CMU/cmunsx.otf" : italic ? "CMU/cmunsi.otf" : "CMU/cmunss.otf"] }
        else if name.hasPrefix("lmroman") { list = [bold ? (italic ? "CMU/cmunbi.otf" : "CMU/cmunbx.otf") : italic ? "CMU/cmunti.otf" : "CMU/cmunrm.otf"] }
        else { list = [] }
        return list + ["LatinModernMath/latinmodern-math.otf", "STIXTwo/STIXTwoMath-Regular.otf"]
    }

    // MARK: Latin Modern at optical sizes (lmodern's T1 .fd files)

    enum Family: Hashable, Sendable { case roman, sans, mono }
    enum Shape: Hashable, Sendable { case upright, italic, slanted, smallCaps }

    /// The Latin Modern file LaTeX's `lmodern` picks for a family, series, shape and size: `lmr10` for 10 pt, `lmr12` for
    /// 11–15 pt, `lmr17` above, `lmbx12` for bold 11 pt and up, and so on.
    static func latinModernFile(_ family: Family, bold: Bool, shape: Shape, size: Double) -> String {
        func pick(_ table: [(Double, Int)], _ last: Int) -> Int {
            for (limit, cut) in table where size < limit { return cut }
            return last
        }
        let name: String
        switch family {
        case .roman:
            switch (bold, shape) {
            case (false, .upright):
                name = "lmroman\(pick([(5.5, 5), (6.5, 6), (7.5, 7), (8.5, 8), (9.5, 9), (11, 10), (15, 12)], 17))-regular"
            case (true, .upright), (true, .smallCaps):
                name = "lmroman\(pick([(5.5, 5), (6.5, 6), (7.5, 7), (8.5, 8), (9.5, 9), (11, 10)], 12))-bold"
            case (false, .italic):
                name = "lmroman\(pick([(7.5, 7), (8.5, 8), (9.5, 9), (11, 10)], 12))-italic"
            case (true, .italic):
                name = "lmroman10-bolditalic"
            case (false, .slanted):
                name = "lmromanslant\(pick([(8.5, 8), (9.5, 9), (11, 10), (15, 12)], 17))-regular"
            case (true, .slanted):
                name = "lmromanslant10-bold"
            case (false, .smallCaps):
                name = "lmromancaps10-regular"
            }
        case .sans:
            let cut = pick([(8.5, 8), (9.5, 9), (11, 10), (15.5, 12)], 17)
            switch (bold, shape) {
            case (false, .upright), (false, .smallCaps): name = "lmsans\(cut)-regular"
            case (false, _): name = "lmsans\(cut)-oblique"
            case (true, .upright), (true, .smallCaps): name = "lmsans10-bold"
            case (true, _): name = "lmsans10-boldoblique"
            }
        case .mono:
            switch (bold, shape) {
            case (false, .upright), (false, .smallCaps): name = "lmmono\(pick([(8.5, 8), (9.5, 9), (11, 10)], 12))-regular"
            case (false, .italic): name = "lmmono10-italic"
            case (false, .slanted): name = "lmmonoslant10-regular"
            case (true, .upright), (true, .smallCaps): name = "lmmonolt10-bold"
            case (true, _): name = "lmmonolt10-boldoblique"
            }
        }
        return "LatinModern/\(name).otf"
    }

    func latinModern(_ family: Family, bold: Bool = false, shape: Shape = .upright, size: Double) -> CTFont {
        font(Self.latinModernFile(family, bold: bold, shape: shape, size: size), size: size)
    }

    // MARK: "As written" fonts (quality §3.5)

    /// A font by the name a document asked for. Calibri and Cambria become Carlito and Caladea; fonts macOS has are used
    /// as they are; anything else falls back by classification and is reported in `replaced`.
    func documentFont(named requested: String, size: Double, bold: Bool, italic: Bool) -> (font: CTFont, replaced: String?) {
        let lower = requested.lowercased()
        func style(_ regular: String, _ b: String, _ i: String, _ bi: String) -> String {
            bold ? (italic ? bi : b) : (italic ? i : regular)
        }
        if lower.hasPrefix("calibri") {
            return (font(style("Carlito/Carlito-Regular.ttf", "Carlito/Carlito-Bold.ttf", "Carlito/Carlito-Italic.ttf",
                               "Carlito/Carlito-BoldItalic.ttf"), size: size), nil)
        }
        if lower.hasPrefix("cambria") {
            return (font(style("Caladea/Caladea-Regular.ttf", "Caladea/Caladea-Bold.ttf", "Caladea/Caladea-Italic.ttf",
                               "Caladea/Caladea-BoldItalic.ttf"), size: size), nil)
        }
        if lower.contains("latin modern") || lower.hasPrefix("lmroman") || lower.hasPrefix("cmu") {
            return (latinModern(.roman, bold: bold, shape: italic ? .italic : .upright, size: size), nil)
        }
        var replaced: String?
        var base = CTFontCreateWithName(requested as CFString, CGFloat(size), nil)
        let family = (CTFontCopyFamilyName(base) as String).lowercased()
        if family != lower && !lower.hasPrefix(family) && !family.hasPrefix(lower) {
            base = CTFontCreateWithName(Self.classify(lower) as CFString, CGFloat(size), nil)
            replaced = "\(requested) → \(CTFontCopyFamilyName(base) as String)"
        }
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(base, CGFloat(size), nil, traits, traits) {
            base = styled
        }
        return (base, replaced)
    }

    /// The macOS font that stands in for a missing one: by monospace, sans or serif classification of its name.
    static func classify(_ name: String) -> String {
        let mono = ["mono", "courier", "consol", "code", "menlo", "typewriter", "fixed"]
        let sans = ["sans", "arial", "helvetica", "verdana", "tahoma", "segoe", "gothic", "grotesk", "inter", "roboto",
                    "lato", "open", "candara", "corbel", "futura", "gill", "myriad", "frutiger", "trebuchet"]
        if mono.contains(where: name.contains) { return "Courier New" }
        if sans.contains(where: name.contains) { return "Arial" }
        return "Times New Roman"
    }
}
