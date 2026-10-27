import CoreText
import Foundation
import SuperConverterCore

public enum TypesetError: Error, CustomStringConvertible {
    case missingFont(String)
    case cannotWrite(String)

    public var description: String {
        switch self {
        case .missingFont(let f): "The font \(f) is missing from the app"
        case .cannotWrite(let f): "\(f) couldn’t be written"
        }
    }
}

/// The O-DOC-PDF, O-EBOOK-PDF and O-SHEET-PDF options TypesetKit honours (formats §5).
public struct TypesetOptions: Sendable {
    public enum NumberedSections: String, Sendable { case auto, on, off }

    public var look: DocumentLook = .latex
    /// "auto" (from `region`), "a4", "letter", "legal", "a5", "b5", "a3", "6x9".
    public var paper = "auto"
    public var region: String? = Locale.current.region?.identifier
    public var baseSize = 10
    /// "default", "narrow", "wide".
    public var margins = "default"
    /// "latinModern", "latinModernSans", "own".
    public var font = "latinModern"
    public var columns = 1
    public var numberedSections: NumberedSections = .auto
    public var contents = false
    public var hyphenation = true
    /// "auto" or a language code.
    public var language = "auto"
    public var bookmarks = true
    public var pdfA = false
    public var twoSided = false
    /// Spreadsheets: "auto", "portrait", "landscape".
    public var orientation = "auto"
    /// Spreadsheets: "all" or comma-separated sheet names.
    public var sheets = "all"

    public init() {}

    /// Reads a profile's option values (keys as in `OptionProfiles`).
    public init(_ values: OptionValues, look: DocumentLook?) {
        self.init()
        if let look { self.look = look }
        if let s = values["look"]?.string { self.look = s == "grid" ? .asWritten : DocumentLook(rawValue: s) ?? self.look }
        if let p = values["paper"]?.string ?? values["trimSize"]?.string { paper = p }
        if let b = values["baseSize"]?.string.flatMap(Int.init) ?? values["baseSize"]?.int { baseSize = b }
        if let m = values["margins"]?.string { margins = m }
        if let f = values["font"]?.string { font = f }
        if let c = values["columns"]?.string.flatMap(Int.init) ?? values["columns"]?.int { columns = c }
        if let n = values["numberedSections"]?.string, let v = NumberedSections(rawValue: n) { numberedSections = v }
        if let c = values["contents"]?.bool { contents = c }
        if let h = values["hyphenation"]?.bool { hyphenation = h }
        if let l = values["language"]?.string { language = l }
        if let b = values["bookmarks"]?.bool { bookmarks = b }
        if let p = values["pdfA"]?.string { pdfA = p != "off" }
        if let t = values["twoSided"]?.bool { twoSided = t }
        if let o = values["orientation"]?.string { orientation = o }
        if let s = values["sheet"]?.string { sheets = s }
    }
}

/// What the typographic lint (quality §3.7) checks: every line with its page and place.
public struct TypesetLog: Sendable {
    public struct Line: Sendable {
        public var page: Int
        public var column: Int
        public var baseline: Double
        public var badness: Int
        public var hyphenated: Bool
        public var emergency: Bool
        public var overfull: Double
        public var paragraph: Int
        public var lineInParagraph: Int
        public var linesInParagraph: Int
        public var isHeading: Bool
        public var lastOnPage: Bool
        public var firstOnPage: Bool
        public var text: String
    }
    public var lines: [Line] = []
    public var pages = 0
    /// Heading titles as bookmarked, with their numbers.
    public var headings: [String] = []
}

public struct TypesetResult: Sendable {
    public var pageCount: Int
    public var lossNotes: [LossNote]
    public var warnings: [String]
    public var log: TypesetLog
}

/// DocModel, Publication and Workbook to PDF with the LaTeX look (quality §3): `article` metrics and Latin Modern,
/// Knuth–Plass paragraphs, LaTeX's headings, lists, footnotes, floats and booktabs tables, TeX math; or "As written"
/// with the document's own fonts.
public final class Typesetter {
    let library: FontLibrary

    public init(fonts: FontLibrary) { library = fonts }

    private struct Engines {
        let fonts: FontResolver
        let math: MathBridge
        let setter: ParagraphSetter
    }

    private func engines(_ style: StyleSheet, latex: Bool, sans: Bool, language: String?, hyphenate: Bool) -> Engines {
        let fonts = FontResolver(library: library, latex: latex, sans: sans, normalSize: style.normal.size)
        let math = MathBridge(library: library, fonts: fonts)
        let setter = ParagraphSetter(fonts: fonts, hyphenator: hyphenate ? Hyphenator(language: language) : nil,
                                     mathBox: { tex, s in math.box(tex, display: false, size: s.size).box })
        return Engines(fonts: fonts, math: math, setter: setter)
    }

    // MARK: Documents

    public func typeset(_ doc: DocModel, options: TypesetOptions, to url: URL, progress: (Double) -> Void = { _ in }) throws -> TypesetResult {
        let style = styleSheet(options, cls: .article, pageSize: options.look == .asWritten ? doc.metadata.pageSize : nil)
        var blocks = doc.blocks
        var meta = doc.metadata
        // A document that opens with its only top-level heading has a title (Markdown's "# Title"): \maketitle.
        let levels = Self.headingLevels(blocks)
        if let first = blocks.first(where: { if case .footnote = $0 { return false }; return true }),
           case .heading(let level, let text) = first, levels.filter({ $0 == level }).count == 1, levels.count > 1,
           meta.title == nil || meta.title == Composer.plainText(text) {
            meta.title = Composer.plainText(text)
            blocks.removeFirst(blocks.firstIndex { if case .heading = $0 { return true }; return false }! + 1)
        }
        let sectionLevel = Self.headingLevels(blocks).min() ?? 1
        let numbered: Bool
        switch options.numberedSections {
        case .on: numbered = true
        case .off: numbered = false
        case .auto:
            // "As written" keeps the document's own headings; the LaTeX look numbers three or more sections.
            numbered = options.look != .asWritten && Self.headingLevels(blocks).filter { $0 == sectionLevel }.count >= 3
                && !Self.alreadyNumbered(blocks)
        }
        var doc2 = doc
        doc2.blocks = blocks
        doc2.metadata = meta
        let language = options.language == "auto" ? (meta.language ?? Hyphenator.detectLanguage(Self.sampleText(blocks))) : options.language
        let latex = options.look != .asWritten
        func run(_ headingPages: [String: String]) -> (Composer, [Page]) {
            let e = engines(style, latex: latex, sans: options.font == "latinModernSans", language: language, hyphenate: options.hyphenation)
            let composer = Composer(style: style, look: latex ? .latex : .asWritten, fonts: e.fonts, setter: e.setter, math: e.math,
                                    doc: doc2, numberSections: numbered, sectionLevel: sectionLevel, headingPages: headingPages)
            let ctx = composer.rootContext
            let twoColumnTitle = options.columns == 2 && !(meta.title ?? "").isEmpty
            if !twoColumnTitle { composer.titleBlock(meta, ctx) }
            if let summary = meta.summary, !summary.isEmpty, latex { composer.abstract(summary, ctx) }
            if options.contents {
                composer.contents(Self.marks(blocks, sectionLevel: sectionLevel, numbered: numbered, style: style), ctx)
            }
            composer.compose(blocks, ctx)
            let builder = PageBuilder(style: style, footnotes: composer.footnotes, tableHeaders: composer.tableHeaders)
            builder.noTopFloatsOnFirstPage = meta.title != nil
            if twoColumnTitle {
                // \twocolumn[\@maketitle]: the title spans both columns.
                var wide = style
                wide.geometry.columns = 1
                let t = Composer(style: wide, look: composer.look, fonts: e.fonts, setter: e.setter, math: e.math, doc: DocModel(),
                                 numberSections: false, sectionLevel: 1, headingPages: [:])
                t.titleBlock(meta, t.rootContext)
                builder.firstPageHeader = t.items
            }
            return (composer, builder.build(composer.items))
        }
        var (composer, pages) = run([:])
        progress(0.4)
        if options.contents { (composer, pages) = run(Self.headingPages(pages)) }
        progress(0.6)
        let renderer = PDFRenderer(style: style, fonts: composer.fonts, documentFont: composer.defaultFont)
        let pdfMeta = PDFRenderer.Metadata(title: meta.title, author: meta.authors.isEmpty ? nil : meta.authors.joined(separator: ", "),
                                           subject: meta.summary, pdfA: options.pdfA)
        try renderer.render(pages, metadata: pdfMeta, outline: options.bookmarks ? outline(pages, style) : [], to: url) { n in
            progress(0.6 + 0.4 * Double(n) / Double(max(pages.count, 1)))
        }
        let log = log(pages)
        let lint = TypographicLint.check(log)
        let notes = composer.finish() + fontNotes(composer.fonts) + mathNotes(composer.math)
        return TypesetResult(pageCount: pages.count, lossNotes: Self.unique(notes), warnings: Array(lint.prefix(5)), log: log)
    }

    /// The headings the contents page lists, numbered and anchored as the composer will number them.
    static func marks(_ blocks: [DocBlock], sectionLevel: Int, numbered: Bool, style: StyleSheet) -> [HeadingMark] {
        var counters = [0, 0, 0, 0, 0]
        var marks: [HeadingMark] = []
        var count = 1   // the contents heading itself is sec1
        for b in blocks {
            guard case .heading(let level, let text) = b else { continue }
            count += 1
            let index = max(0, min(level - sectionLevel, 4))
            var number: String? = nil
            if numbered && style.headings[index].numbered {
                counters[index] += 1
                for j in (index + 1)..<counters.count { counters[j] = 0 }
                number = counters[0...index].map(String.init).joined(separator: ".")
            }
            marks.append(HeadingMark(level: index, title: Composer.plainText(text), number: number, anchor: "sec\(count)", inContents: true))
        }
        return marks
    }

    static func headingPages(_ pages: [Page]) -> [String: String] {
        var map: [String: String] = [:]
        for p in pages { for m in p.marks { map[m.anchor] = "\(p.number)" } }
        return map
    }

    static func headingLevels(_ blocks: [DocBlock]) -> [Int] {
        blocks.compactMap { if case .heading(let l, _) = $0 { return l }; return nil }
    }

    /// True when the source numbers its own headings ("1. Introduction", "II. Methods").
    static func alreadyNumbered(_ blocks: [DocBlock]) -> Bool {
        let pattern = try! NSRegularExpression(pattern: "^\\s*([0-9]+(\\.[0-9]+)*\\.?|[IVXLC]+\\.|[A-Z]\\.)\\s")
        return blocks.contains { b in
            guard case .heading(_, let t) = b else { return false }
            let s = Composer.plainText(t)
            return pattern.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
        }
    }

    static func sampleText(_ blocks: [DocBlock]) -> String {
        var s = ""
        for b in blocks where s.count < 2000 { if case .paragraph(let t, _) = b { s += Composer.plainText(t) + " " } }
        return s
    }

    // MARK: Style sheets

    func styleSheet(_ o: TypesetOptions, cls: StyleSheet.DocumentClass, pageSize: VectorSize?) -> StyleSheet {
        var paper = Paper.named(o.paper) ?? Paper.forRegion(o.region)
        if let size = pageSize, size.width > 0, size.height > 0 { paper = Paper(width: size.width.fromBP, height: size.height.fromBP) }
        if o.look == .asWritten {
            // Word's defaults: 1 in margins, 11 pt text on 13.4 pt, no first-line indent, space after paragraphs.
            var s = StyleSheet.latex(cls, baseSize: 10, paper: paper, columns: o.columns == 2 ? 2 : 1, twoSided: o.twoSided, margins: .narrow)
            s.sizes[.normalsize] = SizeLeading(size: 11, leading: 13.4)
            s.sizes[.footnotesize] = SizeLeading(size: 10, leading: 12)
            s.sizes[.small] = SizeLeading(size: 10, leading: 12)
            s.parindent = 0
            return s
        }
        let margins: StyleSheet.MarginChoice = o.margins == "narrow" ? .narrow : o.margins == "wide" ? .wide : .latex
        return StyleSheet.latex(cls, baseSize: o.baseSize, paper: paper, columns: o.columns == 2 ? 2 : 1, twoSided: o.twoSided, margins: margins)
    }

    // MARK: E-books (book class)

    public func typeset(_ pub: Publication, options: TypesetOptions, to url: URL, progress: (Double) -> Void = { _ in }) throws -> TypesetResult {
        var o = options
        if Paper.named(o.paper) == nil { o.paper = "a5" }
        o.look = .latex
        let style = styleSheet(o, cls: .book, pageSize: nil)
        let documents = pub.spine.compactMap { item -> DocModel? in if case .document(let d) = item.content { return d }; return nil }
        let language = o.language == "auto"
            ? (pub.metadata.language ?? Hyphenator.detectLanguage(Self.sampleText(documents.flatMap(\.blocks)))) : o.language
        let e = engines(style, latex: true, sans: o.font == "latinModernSans", language: language, hyphenate: o.hyphenation)
        var resources: [String: Data] = [:]
        for (key, value) in pub.resources { resources[key] = value.data }
        func composer(_ doc: DocModel, sectionLevel: Int = 1) -> Composer {
            Composer(style: style, look: .latex, fonts: e.fonts, setter: e.setter, math: e.math, doc: doc, numberSections: false,
                     sectionLevel: sectionLevel, headingPages: [:])
        }
        var items: [VItem] = []
        var footnotes: [Int: [VItem]] = [:]
        var headers: [Int: [VItem]] = [:]
        var notes: [LossNote] = []
        if let cover = pub.cover, resources[cover] != nil {
            let c = composer(DocModel(resources: resources))
            c.figure(resource: cover, caption: nil, alt: "Cover", c.rootContext)
            items += c.items + [.clearPage]
        }
        if let title = pub.metadata.title, !title.isEmpty {
            // book.cls's titlepage: 60 pt down, the title, the authors and the date.
            let c = composer(DocModel(metadata: pub.metadata))
            c.items.append(.kern(60))
            c.titleBlock(pub.metadata, c.rootContext)
            items += c.items + [.clearPage]
        }
        for item in pub.spine {
            switch item.content {
            case .page(let resource):
                let c = composer(DocModel(resources: resources))
                c.figure(resource: resource, caption: nil, alt: item.title, c.rootContext)
                items += [.clearPage] + c.items
            case .document(var d):
                d.resources.merge(resources) { own, _ in own }
                var title = item.title
                if let first = d.blocks.first, case .heading(_, let t) = first {
                    title = Composer.plainText(t)
                    d.blocks.removeFirst()
                }
                let c = composer(d, sectionLevel: Self.headingLevels(d.blocks).min() ?? 1)
                c.chapterHeading(title, numbered: false, c.rootContext)
                c.compose(d.blocks, c.rootContext)
                // Footnotes and table headers are numbered per chapter; keep them apart.
                let offset = footnotes.keys.max() ?? 0
                for (n, list) in c.footnotes { footnotes[n + offset] = list }
                let tableOffset = headers.keys.max() ?? 0
                for (id, h) in c.tableHeaders { headers[id + tableOffset] = h }
                items += c.items.map { Self.offset($0, footnotes: offset, tables: tableOffset) }
                notes += c.finish()
            }
        }
        let pages = PageBuilder(style: style, footnotes: footnotes, tableHeaders: headers).build(items)
        progress(0.6)
        let meta = PDFRenderer.Metadata(title: pub.metadata.title, author: pub.metadata.authors.joined(separator: ", "),
                                        subject: pub.metadata.summary, pdfA: o.pdfA)
        try PDFRenderer(style: style, fonts: e.fonts, documentFont: nil).render(pages, metadata: meta, outline: o.bookmarks ? outline(pages, style) : [], to: url) { n in
            progress(0.6 + 0.4 * Double(n) / Double(max(pages.count, 1)))
        }
        return TypesetResult(pageCount: pages.count, lossNotes: Self.unique(notes + fontNotes(e.fonts) + mathNotes(e.math)),
                             warnings: [], log: log(pages))
    }

    static func offset(_ item: VItem, footnotes: Int, tables: Int) -> VItem {
        guard case .box(var v) = item else { return item }
        v.footnotes = v.footnotes.map { $0 + footnotes }
        v.tableID = v.tableID.map { $0 + tables }
        return .box(v)
    }

    // MARK: Spreadsheets (quality §4)

    public func typeset(_ workbook: Workbook, options: TypesetOptions, to url: URL, progress: (Double) -> Void = { _ in }) throws -> TypesetResult {
        let wanted = options.sheets == "all" ? nil : Set(options.sheets.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let sheets = workbook.sheets.filter { !$0.isHidden && (wanted?.contains($0.name) ?? true) }
        var style = styleSheet(options, cls: .article, pageSize: nil)
        // Landscape when a sheet is wider than tall (unless the person chose): a page on its side with 1 in margins.
        let landscape: Bool
        switch options.orientation {
        case "landscape": landscape = true
        case "portrait": landscape = false
        default:
            landscape = sheets.contains { s in
                let cols = s.rows.map(\.count).max() ?? 0
                return cols >= 7 && Double(cols) * 60 > Double(min(s.rows.count, 40)) * 14
            }
        }
        if landscape {
            let p = style.geometry.paper
            style = StyleSheet.latex(.article, baseSize: options.baseSize, paper: Paper(width: p.height, height: p.width), columns: 1,
                                     twoSided: false, margins: .narrow)
        }
        let latex = options.look != .asWritten
        let e = engines(style, latex: latex, sans: options.font == "latinModernSans", language: nil, hyphenate: false)
        let composer = Composer(style: style, look: latex ? .latex : .asWritten, fonts: e.fonts, setter: e.setter, math: e.math,
                                doc: DocModel(), numberSections: false, sectionLevel: 1, headingPages: [:])
        let ctx = composer.rootContext
        for (k, sheet) in sheets.enumerated() {
            if k > 0 { composer.items.append(.clearPage) }
            if sheets.count > 1 { composer.heading(level: 1, text: [.text(sheet.name)], ctx, numbered: false) }
            for (band, table) in TableComposer(composer: composer, ctx: ctx).sheet(sheet).enumerated() {
                if band > 0 { composer.items.append(.clearPage) }
                composer.appendTable(table)
            }
        }
        let pages = PageBuilder(style: style, footnotes: [:], tableHeaders: composer.tableHeaders).build(composer.items)
        progress(0.6)
        try PDFRenderer(style: style, fonts: e.fonts, documentFont: composer.defaultFont).render(pages, metadata: PDFRenderer.Metadata(title: workbook.title, pdfA: options.pdfA),
                                                             outline: options.bookmarks ? outline(pages, style) : [], to: url) { n in
            progress(0.6 + 0.4 * Double(n) / Double(max(pages.count, 1)))
        }
        return TypesetResult(pageCount: pages.count, lossNotes: Self.unique(composer.finish() + fontNotes(e.fonts)), warnings: [], log: log(pages))
    }

    // MARK: Finishing

    private func fontNotes(_ fonts: FontResolver) -> [LossNote] {
        fonts.replaced.isEmpty ? [] : [LossNote(.fontsReplaced, detail: fonts.replaced.sorted().joined(separator: "; "))]
    }

    private func mathNotes(_ math: MathBridge) -> [LossNote] {
        math.problems.isEmpty ? [] : [LossNote(.otherLoss, detail: "Unknown in formulas: " + math.problems.sorted().joined(separator: ", "))]
    }

    static func unique(_ notes: [LossNote]) -> [LossNote] {
        var seen = Set<LossNote>()
        return notes.filter { seen.insert($0).inserted }
    }

    /// Bookmarks from headings, nested by level, pointing at each heading's line.
    private func outline(_ pages: [Page], _ style: StyleSheet) -> [OutlineEntry] {
        var roots: [OutlineEntry] = []
        var stack: [(level: Int, path: [Int])] = []
        for page in pages {
            for mark in page.marks where mark.inContents {
                let y = page.columns.flatMap { $0 }.first { p in
                    p.box.box.ops.contains { if case .anchor(let a, _, _) = $0 { return a == mark.anchor }; return false }
                }.map { $0.y - $0.box.box.height - 4 } ?? 0
                let entry = OutlineEntry(title: (mark.number.map { $0 + " " } ?? "") + mark.title, page: page.number,
                                         y: style.geometry.textTop + y)
                while let last = stack.last, last.level >= mark.level { stack.removeLast() }
                if let parent = stack.last {
                    let child = Self.append(entry, at: parent.path[...], to: &roots)
                    stack.append((mark.level, parent.path + [child]))
                } else {
                    roots.append(entry)
                    stack.append((mark.level, [roots.count - 1]))
                }
            }
        }
        return roots
    }

    private static func append(_ e: OutlineEntry, at path: ArraySlice<Int>, to list: inout [OutlineEntry]) -> Int {
        let i = path.first!
        if path.count == 1 { list[i].children.append(e); return list[i].children.count - 1 }
        return append(e, at: path.dropFirst(), to: &list[i].children)
    }

    func log(_ pages: [Page]) -> TypesetLog {
        var log = TypesetLog()
        log.pages = pages.count
        for page in pages {
            for (c, column) in page.columns.enumerated() {
                let lines = column.filter { $0.box.line != nil || $0.box.isHeading }
                for (k, p) in lines.enumerated() {
                    let info = p.box.line
                    log.lines.append(TypesetLog.Line(page: page.number, column: c, baseline: p.y, badness: info?.badness ?? 0,
                                                     hyphenated: info?.hyphenated ?? false, emergency: info?.emergency ?? false,
                                                     overfull: info?.overfull ?? 0, paragraph: info?.paragraph ?? -1,
                                                     lineInParagraph: info?.lineInParagraph ?? 0,
                                                     linesInParagraph: info?.linesInParagraph ?? 1, isHeading: p.box.isHeading,
                                                     lastOnPage: k == lines.count - 1, firstOnPage: k == 0, text: info?.text ?? ""))
                }
            }
            for m in page.marks where m.inContents { log.headings.append((m.number.map { $0 + " " } ?? "") + m.title) }
        }
        return log
    }
}
