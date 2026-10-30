import Foundation
import ImageIO
import SuperConverterCore

// What every DocKit reader and writer shares: options, results, the inline run model (RunFormat) with its builder and its
// flattening, list nesting, and small text helpers. No app policy; configuration comes from `OptionValues`.

/// What a reader hands back: the model and everything it could not carry over.
struct DocReadResult {
    var model: DocModel
    var lossNotes: [LossNote] = []
}

/// Reader options (formats §5, O-DOC / O-DOC-PDF+TXT / O-DOC+MD): the keys are `OptionProfiles`'.
struct DocReadOptions {
    enum Changes: String { case accept, reject, keep }
    var trackedChanges = Changes.accept
    /// "auto", "github", "strict", "pandoc", "mmd".
    var markdownFlavour = "auto"
    /// "auto", "prose", "code".
    var treatAs = "auto"
    /// IANA name, or "auto".
    var encoding = "auto"
    var tabWidth = 8
    var password: String?

    init() {}

    init(_ values: OptionValues) {
        trackedChanges = values["trackedChanges"]?.string.flatMap(Changes.init) ?? .accept
        markdownFlavour = values["markdownInput"]?.string ?? "auto"
        treatAs = values["treatAs"]?.string ?? "auto"
        encoding = values["encoding"]?.string ?? "auto"
        tabWidth = values["tabWidth"]?.int ?? 8
        password = values["password"]?.string
    }
}

/// Writer options (O-DOC, O-DOC+MD).
struct DocWriteOptions {
    var markdownFlavour = "github"
    var embedImages = true
    var latexClass = "article"
    var crlf = false
    var encoding = "UTF-8"
    /// Wrap prose at this column; nil for none.
    var wrap: Int?

    init() {}

    init(_ values: OptionValues) {
        markdownFlavour = values["markdownFlavour"]?.string ?? "github"
        embedImages = values["embedImages"]?.bool ?? true
        latexClass = values["latexClass"]?.string ?? "article"
        crlf = values["lineEndings"]?.string == "crlf"
        encoding = values["encoding"]?.string ?? "UTF-8"
        wrap = values["wrap"]?.string.flatMap { Int($0) }
    }
}

extension LossNote {
    /// Notes for what a writer dropped, one per kind, in order of first appearance.
    static func merged(_ notes: [LossNote]) -> [LossNote] {
        var seen = Set<LossNote>()
        return notes.filter { seen.insert($0).inserted }
    }
}

// MARK: - Inline runs

/// The formatting of one run of text, flattened out of the nested `DocInline` tree.
struct RunFormat: Hashable {
    var bold = false
    var italic = false
    var strike = false
    var code = false
    var underline = false
    var superscript = false
    var subscripted = false
    var font: String?
    var size: Double?
    /// "#RRGGBB".
    var colour: String?
    var link: String?

    var hasRunStyle: Bool { font != nil || size != nil || colour != nil || underline || superscript || subscripted }
    var runStyle: DocRunStyle {
        DocRunStyle(fontName: font, fontSize: size, colour: colour, underline: underline, superscript: superscript, subscripted: subscripted)
    }
}

/// One item of a paragraph with its formatting resolved: what the writers walk.
enum FlatItem: Equatable {
    case run(String, RunFormat)
    case image(resource: String, alt: String?, link: String?)
    case footnote(id: String)
    case math(tex: String)
    case lineBreak
}

enum Inlines {
    /// The paragraph as flat items; adjacent runs with the same format are merged.
    static func flatten(_ text: DocText, base: RunFormat = RunFormat()) -> [FlatItem] {
        var out: [FlatItem] = []
        func add(_ item: FlatItem) {
            if case .run(let t, let f) = item, case .run(let previous, let pf)? = out.last, pf == f {
                out[out.count - 1] = .run(previous + t, f)
            } else {
                out.append(item)
            }
        }
        func walk(_ text: DocText, _ f: RunFormat) {
            for inline in text {
                switch inline {
                case .text(let t): if !t.isEmpty { add(.run(t, f)) }
                case .emphasis(let c): var g = f; g.italic = true; walk(c, g)
                case .strong(let c): var g = f; g.bold = true; walk(c, g)
                case .strike(let c): var g = f; g.strike = true; walk(c, g)
                case .code(let t): var g = f; g.code = true; add(.run(t, g))
                case .link(let c, let destination): var g = f; g.link = destination; walk(c, g)
                case .image(let resource, let alt): add(.image(resource: resource, alt: alt, link: f.link))
                case .footnoteReference(let id): add(.footnote(id: id))
                case .math(let tex): add(.math(tex: tex))
                case .styled(let c, let style):
                    var g = f
                    g.font = style.fontName ?? g.font; g.size = style.fontSize ?? g.size; g.colour = style.colour ?? g.colour
                    g.underline = g.underline || style.underline
                    g.superscript = g.superscript || style.superscript; g.subscripted = g.subscripted || style.subscripted
                    walk(c, g)
                case .lineBreak: add(.lineBreak)
                }
            }
        }
        walk(text, base)
        return out
    }

    /// The text without any formatting (math as its TeX, pictures as their alt text).
    static func plain(_ text: DocText) -> String {
        text.map { inline -> String in
            switch inline {
            case .text(let t), .code(let t), .math(let t): t
            case .emphasis(let c), .strong(let c), .strike(let c), .link(let c, _), .styled(let c, _): plain(c)
            case .image(_, let alt): alt ?? ""
            case .footnoteReference: ""
            case .lineBreak: "\n"
            }
        }.joined()
    }

    /// Builds the nested tree back from flat items: link outermost, then strong, emphasis, strike and the run style, with
    /// neighbouring runs that share a style under one node (`**a *b* c**`, not three).
    static func build(_ items: [FlatItem]) -> DocText {
        var out: DocText = []
        var group: [FlatItem] = []
        var link: String?
        func flush() {
            guard !group.isEmpty else { return }
            let inner = peel(group, level: 0)
            if let destination = link { out.append(.link(inner, destination: destination)) } else { out += inner }
            group = []
        }
        func put(_ item: FlatItem, _ destination: String?) {
            if destination != link { flush(); link = destination }
            group.append(item)
        }
        for item in items {
            switch item {
            case .run(_, let f): put(item, f.link)
            case .image(_, _, let destination): put(item, destination)
            default: put(item, link)
            }
        }
        flush()
        return out
    }

    private static let layers: [(has: (RunFormat) -> Bool, clear: (inout RunFormat) -> Void, wrap: (RunFormat, DocText) -> DocInline)] = [
        ({ $0.bold }, { $0.bold = false }, { _, c in .strong(c) }),
        ({ $0.italic }, { $0.italic = false }, { _, c in .emphasis(c) }),
        ({ $0.strike }, { $0.strike = false }, { _, c in .strike(c) }),
        ({ $0.hasRunStyle }, { $0.font = nil; $0.size = nil; $0.colour = nil; $0.underline = false; $0.superscript = false; $0.subscripted = false },
         { f, c in .styled(c, f.runStyle) }),
    ]

    /// Wraps spans of consecutive runs that have the layer's style, innermost layers last.
    private static func peel(_ items: [FlatItem], level: Int) -> DocText {
        guard level < layers.count else {
            return items.map { item -> DocInline in
                switch item {
                case .run(let t, let f): f.code ? .code(t) : .text(t)
                case .image(let resource, let alt, _): .image(resource: resource, altText: alt)
                case .footnote(let id): .footnoteReference(id: id)
                case .math(let tex): .math(tex: tex)
                case .lineBreak: .lineBreak
                }
            }
        }
        let layer = layers[level]
        var out: DocText = []
        var span: [FlatItem] = []
        var spanFormat = RunFormat()
        func flushSpan() {
            guard !span.isEmpty else { return }
            out.append(layer.wrap(spanFormat, peel(span, level: level + 1)))
            span = []
        }
        var plain: [FlatItem] = []
        func flushPlain() {
            if !plain.isEmpty { out += peel(plain, level: level + 1); plain = [] }
        }
        for item in items {
            if case .run(let t, var f) = item, layer.has(f) {
                flushPlain()
                if span.isEmpty { spanFormat = f }
                else if layer.wrap(spanFormat, []) != layer.wrap(f, []) { flushSpan(); spanFormat = f }
                layer.clear(&f)
                span.append(.run(t, f))
            } else {
                flushSpan()
                plain.append(item)
            }
        }
        flushSpan()
        flushPlain()
        return out
    }
}

/// Collects runs while a reader walks a paragraph.
struct InlineBuilder {
    private(set) var items: [FlatItem] = []

    var isEmpty: Bool { items.isEmpty }

    mutating func add(_ text: String, _ format: RunFormat = RunFormat()) {
        guard !text.isEmpty else { return }
        if case .run(let previous, let f)? = items.last, f == format {
            items[items.count - 1] = .run(previous + text, f)
        } else {
            items.append(.run(text, format))
        }
    }

    mutating func add(_ item: FlatItem) {
        if case .run(let t, let f) = item { add(t, f) } else { items.append(item) }
    }

    /// Removes the last character of the last run (a hyphen at a line end that is joined with the next line).
    mutating func removeLastCharacter() {
        guard case .run(let t, let f)? = items.last else { return }
        if t.count > 1 { items[items.count - 1] = .run(String(t.dropLast()), f) } else { items.removeLast() }
    }

    /// Drops trailing white space and line breaks (paragraph ends), and leading white space when asked.
    mutating func trim(leading: Bool = false) {
        while case .run(let t, let f)? = items.last {
            let trimmed = String(t.reversed().drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }).reversed())
            if trimmed.isEmpty { items.removeLast() } else { items[items.count - 1] = .run(trimmed, f); break }
        }
        while case .lineBreak? = items.last { items.removeLast() }
        if leading, case .run(let t, let f)? = items.first {
            let trimmed = String(t.drop(while: { $0 == " " || $0 == "\t" || $0 == "\n" }))
            if trimmed.isEmpty { items.removeFirst() } else { items[0] = .run(trimmed, f) }
        }
    }

    func build() -> DocText { Inlines.build(items) }
}

// MARK: - Lists

/// Turns a flat run of list paragraphs (each with a nesting level) into nested `DocBlock.list` values.
enum ListAssembler {
    struct Entry {
        var level: Int
        var ordered: Bool
        var start: Int
        var blocks: [DocBlock]
        /// Which list the source put the paragraph in; adjacent lists with different ids stay separate lists.
        var listID = ""
    }

    /// A list's first number as a file gives it: at most CommonMark's nine digits and never negative, so the writers' item
    /// numbers (`start + index`, `start - 1`) cannot overflow.
    static func start(_ value: Int?) -> Int { min(max(value ?? 1, 0), 999_999_999) }

    /// The deepest list level (Word's and OpenDocument's nine): each level is a level of recursion here and in the writers,
    /// and a file can number its levels without end.
    static let maxLevel = 8

    static func assemble(_ entries: [Entry]) -> [DocBlock] {
        let entries = entries.map { entry in var e = entry; e.level = min(max(e.level, 0), maxLevel); return e }
        var index = 0
        var out: [DocBlock] = []
        let base = entries.map(\.level).min() ?? 0
        while index < entries.count { out.append(build(entries, &index, level: base)) }
        return out
    }

    private static func build(_ entries: [Entry], _ index: inout Int, level: Int) -> DocBlock {
        let first = entries[index]
        var items: [[DocBlock]] = []
        while index < entries.count {
            let entry = entries[index]
            if entry.level > level {
                var nested: [DocBlock] = []
                let deeper = entry.level
                while index < entries.count, entries[index].level >= deeper { nested.append(build(entries, &index, level: deeper)) }
                if items.isEmpty { items.append(nested) } else { items[items.count - 1] += nested }
            } else if entry.level == level, entry.ordered == first.ordered, entry.listID == first.listID {
                items.append(entry.blocks)
                index += 1
            } else {
                break
            }
        }
        return .list(ordered: first.ordered, start: first.start, items: items)
    }
}

// MARK: - Text

enum TextCoding {
    /// Decodes bytes with a BOM, UTF-8 validity, UTF-16 heuristics, then a hint, then the common legacy encodings.
    /// Returns the text and the IANA-ish name used.
    static func decode(_ data: Data, hint: String = "auto") -> (text: String, encoding: String) {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return (String(decoding: data.dropFirst(3), as: UTF8.self), "UTF-8") }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]), let s = String(data: data.dropFirst(4), encoding: .utf32LittleEndian) { return (s, "UTF-32LE") }
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]), let s = String(data: data.dropFirst(4), encoding: .utf32BigEndian) { return (s, "UTF-32BE") }
        if data.starts(with: [0xFF, 0xFE]), let s = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return (s, "UTF-16LE") }
        if data.starts(with: [0xFE, 0xFF]), let s = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return (s, "UTF-16BE") }
        if hint.lowercased() != "auto", let encoding = encoding(named: hint), let s = String(data: data, encoding: encoding) { return (s, hint) }
        if let s = String(data: data, encoding: .utf8) { return (s, "UTF-8") }
        // UTF-16 without a mark: ASCII-heavy text has a zero in every other byte.
        if data.count >= 4 {
            let sample = data.prefix(512)
            let even = stride(from: 0, to: sample.count - 1, by: 2).filter { sample[sample.startIndex + $0] == 0 }.count
            let odd = stride(from: 1, to: sample.count, by: 2).filter { sample[sample.startIndex + $0] == 0 }.count
            let pairs = max(sample.count / 2, 1)
            if odd * 10 > pairs * 6, even == 0, let s = String(data: data, encoding: .utf16LittleEndian) { return (s, "UTF-16LE") }
            if even * 10 > pairs * 6, odd == 0, let s = String(data: data, encoding: .utf16BigEndian) { return (s, "UTF-16BE") }
        }
        var converted: NSString?
        var lossy = ObjCBool(false)
        let suggested: [NSNumber] = [
            NSNumber(value: String.Encoding.shiftJIS.rawValue), NSNumber(value: String.Encoding.japaneseEUC.rawValue),
            NSNumber(value: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            NSNumber(value: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
            NSNumber(value: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))),
            NSNumber(value: String.Encoding.windowsCP1252.rawValue),
        ]
        let raw = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: suggested, .allowLossyKey: false],
                                          convertedString: &converted, usedLossyConversion: &lossy)
        if raw != 0, let converted { return (converted as String, CFStringConvertEncodingToIANACharSetName(CFStringConvertNSStringEncodingToEncoding(raw)) as String? ?? "windows-1252") }
        return (String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self), "windows-1252")
    }

    static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// Encodes for output: the named encoding (UTF-8 without BOM by default); characters it lacks are written as `?`.
    static func encode(_ text: String, as name: String) -> Data {
        guard let encoding = encoding(named: name) else { return Data(text.utf8) }
        return text.data(using: encoding, allowLossyConversion: true) ?? Data(text.utf8)
    }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension String {
    /// Line endings normalised to "\n".
    var normalisedNewlines: String {
        replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

}

// MARK: - Images

enum ImageSniff {
    /// "png", "jpeg", "gif" for the formats Word, ODF and browsers all take; nil otherwise.
    static func commonType(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpeg" }
        if data.starts(with: Array("GIF8".utf8)) { return "gif" }
        return nil
    }

    /// A picture a writer can embed: the original when its type is one of `native`, else re-encoded as PNG through ImageIO. Size in pixels and the density the file declares (points per pixel at 72 dpi when it declares none).
    struct Prepared {
        var type: String
        var data: Data
        var pixelWidth: Int
        var pixelHeight: Int
        var dpi: Double
    }

    static func prepare(_ data: Data, native: Set<String> = ["png", "jpeg", "gif"]) -> Prepared? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        guard w > 0, h > 0 else { return nil }
        let dpi = max((props[kCGImagePropertyDPIWidth] as? Double) ?? 72, 1)
        if let type = commonType(data), native.contains(type) { return Prepared(type: type, data: data, pixelWidth: w, pixelHeight: h, dpi: dpi) }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Prepared(type: "png", data: out as Data, pixelWidth: w, pixelHeight: h, dpi: dpi)
    }

    static func mime(_ type: String) -> String { type == "jpeg" ? "image/jpeg" : "image/\(type)" }

    static func mimeForFileName(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "bmp": "image/bmp"
        case "tif", "tiff": "image/tiff"
        default: "application/octet-stream"
        }
    }
}

/// The date line the DOCX, ODT and text writers write for `DocMetadata.date` (ISO, UTC).
enum DocDates {
    static func string(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

enum PaperSize {
    /// US Letter in the regions that use it, else A4 (O-DOC-PDF "Paper"), in points.
    static var regional: (width: Double, height: Double) {
        let letter: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE"]
        return letter.contains(Locale.current.region?.identifier ?? "") ? (612, 792) : (595.28, 841.89)
    }
}

extension Int {
    /// A measurement written as a whole number (twips, half-points, EMUs, a colour channel): a size from a damaged file can
    /// be NaN or 1e308, which `Int(_:)` traps on, so it is rounded and kept within ±1 000 000 000, NaN as 0.
    init(measure value: Double) {
        self = value.isNaN ? 0 : Int(Swift.min(Swift.max(value.rounded(), -1_000_000_000), 1_000_000_000))
    }
}
