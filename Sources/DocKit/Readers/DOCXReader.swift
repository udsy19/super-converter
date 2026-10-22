import Foundation
import SuperConverterCore

/// DOCX (and DOCM, DOTX) → `DocModel`: our own OOXML reader (formats §3.2 `DOCXReader`). Styles are resolved through
/// `basedOn`, lists through numbering.xml, links through the relationships; tracked changes are accepted or rejected as asked;
/// math (OMML) becomes TeX; footnotes and endnotes become `DocBlock.footnote`.
enum DOCXReader {
    static func read(_ url: URL, options: DocReadOptions = DocReadOptions()) throws -> DocReadResult {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try read(data, options: options)
    }

    static func read(_ data: Data, options: DocReadOptions = DocReadOptions()) throws -> DocReadResult {
        // A password-protected DOCX is an OLE container around an encrypted package.
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { throw ConversionError.passwordRequired("docx") }
        let archive: ZipArchive
        do { archive = try ZipArchive(data: data) } catch { throw ConversionError.damaged("docx") }
        let context = Context(archive: archive, options: options)
        try context.load()
        return context.run()
    }

    // MARK: - Package

    private struct Style {
        var name = ""
        var basedOn: String?
        var rPr: XMLNode?
        var pPr: XMLNode?
    }

    private struct Level {
        var ordered: Bool
        var start: Int
    }

    private struct Relationship {
        var target: String
        var isExternal: Bool
    }

    private enum Parsed {
        case block(DocBlock)
        case caption(DocText)
        case listItem(ListAssembler.Entry)
        case codeLine(String)
        case quote(DocBlock)
        case heading(Int, DocText)
    }

    private final class Context {
        let archive: ZipArchive
        let options: DocReadOptions
        var mainPath = "word/document.xml"
        var relationships: [String: Relationship] = [:]
        var styles: [String: Style] = [:]
        var defaultRPr: XMLNode?
        var defaultPPr: XMLNode?
        var numbering: [String: [Int: Level]] = [:]   // numId → level → info
        var body: XMLNode?
        var footnoteNodes: [String: XMLNode] = [:]
        var referencedNotes: [String] = []
        var resources: [String: Data] = [:]
        var imageNames: [String: String] = [:]   // part path → resource key
        var metadata = DocMetadata()
        var lossNotes: [LossNote] = []
        var sawTrackedChange = false

        init(archive: ZipArchive, options: DocReadOptions) { self.archive = archive; self.options = options }

        // MARK: Loading

        func load() throws {
            if let rels = try? archive.data("_rels/.rels"), let root = try? XML.parse(rels),
               let main = root.children("Relationship").first(where: { $0.attr("Type")?.hasSuffix("/officeDocument") == true }),
               let target = main.attr("Target") {
                mainPath = target.hasPrefix("/") ? String(target.dropFirst()) : target
            }
            guard let documentData = try archive.data(mainPath), let document = try? XML.parse(documentData),
                  let body = document.child("body") else { throw ConversionError.damaged("docx") }
            self.body = body
            let folder = (mainPath as NSString).deletingLastPathComponent
            let relsPath = (folder.isEmpty ? "" : folder + "/") + "_rels/" + (mainPath as NSString).lastPathComponent + ".rels"
            if let data = try archive.data(relsPath), let root = try? XML.parse(data) {
                for r in root.children("Relationship") {
                    guard let id = r.attr("Id"), let target = r.attr("Target") else { continue }
                    relationships[id] = Relationship(target: target, isExternal: r.attr("TargetMode") == "External")
                }
            }
            if let data = try archive.data(part("styles.xml")), let root = try? XML.parse(data) { loadStyles(root) }
            if let data = try archive.data(part("numbering.xml")), let root = try? XML.parse(data) { loadNumbering(root) }
            for (file, tag) in [("footnotes.xml", "footnote"), ("endnotes.xml", "endnote")] {
                guard let data = try archive.data(part(file)), let root = try? XML.parse(data) else { continue }
                for note in root.children(tag) {
                    guard let id = note.attr("id"), note.attr("type") == nil || note.attr("type") == "normal" else { continue }
                    footnoteNodes[(tag == "endnote" ? "e" : "") + id] = note
                }
            }
            loadProperties()
            if let sect = body.child("sectPr") ?? body.all("sectPr").last, let size = sect.child("pgSz"),
               let w = Double(size.attr("w") ?? ""), let h = Double(size.attr("h") ?? ""), w > 0, h > 0 {
                metadata.pageSize = VectorSize(width: w / 20, height: h / 20)
            }
        }

        func part(_ name: String) -> String {
            let folder = (mainPath as NSString).deletingLastPathComponent
            return folder.isEmpty ? name : folder + "/" + name
        }

        func loadStyles(_ root: XMLNode) {
            defaultRPr = root.child("docDefaults")?.path("rPrDefault/rPr")
            defaultPPr = root.child("docDefaults")?.path("pPrDefault/pPr")
            for s in root.children("style") {
                guard let id = s.attr("styleId") else { continue }
                styles[id] = Style(name: s.child("name")?.attr("val") ?? id, basedOn: s.child("basedOn")?.attr("val"),
                                   rPr: s.child("rPr"), pPr: s.child("pPr"))
            }
            metadata.language = defaultRPr?.child("lang")?.attr("val")
        }

        func loadNumbering(_ root: XMLNode) {
            var abstracts: [String: [Int: Level]] = [:]
            for a in root.children("abstractNum") {
                guard let id = a.attr("abstractNumId") else { continue }
                var levels: [Int: Level] = [:]
                for l in a.children("lvl") {
                    let format = l.child("numFmt")?.attr("val") ?? "decimal"
                    levels[Int(l.attr("ilvl") ?? "0") ?? 0] = Level(ordered: format != "bullet" && format != "none",
                                                                    start: Int(l.child("start")?.attr("val") ?? "1") ?? 1)
                }
                abstracts[id] = levels
            }
            for n in root.children("num") {
                guard let id = n.attr("numId"), let abstract = n.child("abstractNumId")?.attr("val"), var levels = abstracts[abstract] else { continue }
                for o in n.children("lvlOverride") {
                    if let level = Int(o.attr("ilvl") ?? ""), let start = o.child("startOverride")?.attr("val").flatMap(Int.init), levels[level] != nil {
                        levels[level]?.start = start
                    }
                }
                numbering[id] = levels
            }
        }

        func loadProperties() {
            guard let data = try? archive.data("docProps/core.xml"), let root = try? XML.parse(data) else { return }
            func text(_ name: String) -> String? { root.child(name)?.allText.trimmed }
            if let title = text("title"), !title.isEmpty { metadata.title = title }
            if let creator = text("creator"), !creator.isEmpty {
                metadata.authors = creator.split(separator: ";").map { $0.trimmed }.filter { !$0.isEmpty }
            }
            if let description = text("description"), !description.isEmpty { metadata.summary = description }
            if let language = text("language"), !language.isEmpty { metadata.language = language }
            if let created = text("created"), let date = ISO8601DateFormatter().date(from: created) { metadata.date = date }
        }

        // MARK: Styles

        func chain(_ id: String?) -> [Style] {
            var out: [Style] = []
            var seen = Set<String>()
            var current = id
            while let key = current, seen.insert(key).inserted, let style = styles[key] { out.append(style); current = style.basedOn }
            return out
        }

        /// A character-level toggle resolved through the style chain: the first explicit value wins.
        func toggle(_ element: String, in nodes: [XMLNode?]) -> Bool? {
            for node in nodes {
                guard let e = node?.child(element) else { continue }
                let v = e.attr("val")?.lowercased()
                return !(v == "0" || v == "false" || v == "off" || v == "none")
            }
            return nil
        }

        func rPrChain(style: String?) -> [XMLNode?] { chain(style).map(\.rPr) + [defaultRPr] }

        func isHeadingStyle(_ id: String?) -> Int? {
            for s in chain(id) {
                let name = s.name.lowercased()
                if name.hasPrefix("heading "), let n = Int(name.dropFirst(8)), (1...9).contains(n) { return min(n, 6) }
                if let level = s.pPr?.child("outlineLvl")?.attr("val").flatMap(Int.init), level < 9 { return min(level + 1, 6) }
            }
            return nil
        }

        func styleName(_ id: String?) -> String { (id.flatMap { styles[$0]?.name } ?? id ?? "").lowercased() }

        func chainNames(_ id: String?) -> [String] { chain(id).map { $0.name.lowercased() } }

        // MARK: Running

        func run() -> DocReadResult {
            var blocks = parseBlocks(body?.children ?? [], inFootnote: false)
            var index = 0
            var notes: [DocBlock] = []
            while index < referencedNotes.count {   // notes can reference notes
                let id = referencedNotes[index]; index += 1
                guard let note = footnoteNodes[id] else { continue }
                notes.append(.footnote(id: id, parseBlocks(note.children, inFootnote: true)))
            }
            blocks += notes
            if options.trackedChanges == .keep && sawTrackedChange { lossNotes.append(LossNote(.formattingSimplified, detail: "Tracked changes were accepted")) }
            return DocReadResult(model: DocModel(metadata: metadata, blocks: blocks, resources: resources), lossNotes: lossNotes)
        }

        // MARK: Blocks

        func parseBlocks(_ nodes: [XMLNode], inFootnote: Bool) -> [DocBlock] {
            var parsed: [Parsed] = []
            collect(nodes, into: &parsed)
            var blocks = assemble(parsed)
            // A note's first run is its mark, then a space.
            if inFootnote, case .paragraph(var text, let style)? = blocks.first, case .text(let first)? = text.first {
                text[0] = .text(String(first.drop(while: { $0 == " " })))
                blocks[0] = .paragraph(text, style)
            }
            return blocks
        }

        func collect(_ nodes: [XMLNode], into out: inout [Parsed]) {
            for node in nodes {
                switch node.name {
                case "p": paragraph(node, into: &out)
                case "tbl": out.append(.block(.table(table(node))))
                case "sdt": if let content = node.child("sdtContent") { collect(content.children, into: &out) }
                case "ins", "moveTo": if options.trackedChanges != .reject { collect(node.children, into: &out) }
                case "del", "moveFrom": if options.trackedChanges == .reject { collect(node.children, into: &out) }
                case "customXml", "smartTag": collect(node.children, into: &out)
                default: break
                }
            }
        }

        func assemble(_ parsed: [Parsed]) -> [DocBlock] {
            var out: [DocBlock] = []
            var i = 0
            while i < parsed.count {
                switch parsed[i] {
                case .listItem:
                    var entries: [ListAssembler.Entry] = []
                    while i < parsed.count, case .listItem(let e) = parsed[i] { entries.append(e); i += 1 }
                    out += ListAssembler.assemble(entries)
                    continue
                case .codeLine:
                    var lines: [String] = []
                    while i < parsed.count, case .codeLine(let l) = parsed[i] { lines.append(l); i += 1 }
                    out.append(.code(language: nil, text: lines.joined(separator: "\n")))
                    continue
                case .quote:
                    var inner: [DocBlock] = []
                    while i < parsed.count, case .quote(let b) = parsed[i] { inner.append(b); i += 1 }
                    out.append(.quote(inner))
                    continue
                case .heading(let level, let text):
                    out.append(.heading(level: level, text))
                case .caption(let text):
                    // A caption sits under a figure and above a table.
                    if case .figure(let resource, let existing, let alt)? = out.last, existing == nil {
                        out[out.count - 1] = .figure(resource: resource, caption: text, altText: alt)
                    } else if i + 1 < parsed.count, case .block(.table(var table)) = parsed[i + 1], table.caption == nil {
                        table.caption = text
                        out.append(.table(table))
                        i += 2
                        continue
                    } else {
                        out.append(.paragraph(text, DocParagraphStyle()))
                    }
                case .block(let block):
                    out.append(block)
                }
                i += 1
            }
            return out
        }

        // MARK: Paragraphs

        struct RunState {
            var link: String?
            var fieldStack: [FieldState] = []
        }

        struct FieldState {
            var instruction = ""
            var resultStarted = false
            var link: String?
        }

        func paragraph(_ p: XMLNode, into out: inout [Parsed]) {
            let pPr = p.child("pPr")
            let styleID = pPr?.child("pStyle")?.attr("val")
            let names = chainNames(styleID)
            let primary = names.first ?? ""
            let pageBreakBefore = toggle("pageBreakBefore", in: [pPr] + chain(styleID).map(\.pPr)) ?? false
            if pageBreakBefore { out.append(.block(.pageBreak)) }

            // Math-only paragraph.
            if let para = p.child("oMathPara"), p.children.allSatisfy({ $0.name == "pPr" || $0.name == "oMathPara" || $0.name == "bookmarkStart" || $0.name == "bookmarkEnd" }) {
                out.append(.block(.math(tex: para.children("oMath").map { OMML.tex($0) }.joined(separator: " \\\\ "), display: true)))
                return
            }

            var builder = InlineBuilder()
            var segments: [DocText] = []   // text between page breaks
            var state = RunState()
            var onlyImage: (resource: String, alt: String?)?
            var imageCount = 0
            // Headings, titles, captions and quotes look bold or italic by style; that is their role, not inline emphasis.
            let isSemantic = isHeadingStyle(styleID) != nil || names.contains { ["title", "subtitle", "caption", "quote", "intense quote", "block text", "footnote text", "author", "date", "abstract"].contains($0) }
            let baseRPr = rPrChain(style: styleID)
            let emphasisRPr: [XMLNode?] = isSemantic ? [] : baseRPr

            func finishSegment() { segments.append(builder.build()); builder = InlineBuilder() }

            // Inline walk (recursive through hyperlinks, ins/del, fields, sdt).
            func walk(_ nodes: [XMLNode]) {
                for node in nodes {
                    switch node.name {
                    case "r": runNode(node)
                    case "hyperlink":
                        let saved = state.link
                        if let id = node.attr("id"), let r = relationships[id] { state.link = r.target }
                        else if let anchor = node.attr("anchor") { state.link = "#" + anchor }
                        walk(node.children)
                        state.link = saved
                    case "ins", "moveTo": if options.trackedChanges != .reject { sawTrackedChange = true; walk(node.children) }
                    case "del", "moveFrom": if options.trackedChanges == .reject { sawTrackedChange = true; walk(node.children) }
                    case "smartTag", "customXml", "fldSimple", "sdtContent", "bdo", "dir": walk(node.children)
                    case "sdt": walk(node.child("sdtContent")?.children ?? [])
                    case "oMath": builder.add(.math(tex: OMML.tex(node)))
                    case "oMathPara": for m in node.children("oMath") { builder.add(.math(tex: OMML.tex(m))) }
                    default: break
                    }
                }
            }

            func runNode(_ r: XMLNode) {
                let rPr = r.child("rPr")
                let charStyle = rPr?.child("rStyle")?.attr("val")
                var format = RunFormat()
                let isHyperlinkStyle = styleName(charStyle) == "hyperlink"
                let nodes: [XMLNode?] = [rPr] + chain(charStyle).map(\.rPr)
                let all = nodes + emphasisRPr
                format.bold = toggle("b", in: all) ?? false
                format.italic = toggle("i", in: all) ?? false
                format.strike = (toggle("strike", in: all) ?? false) || (toggle("dstrike", in: all) ?? false)
                if let u = rPr?.child("u")?.attr("val") { format.underline = u != "none" } else if !isHyperlinkStyle, let u = chain(charStyle).compactMap({ $0.rPr?.child("u")?.attr("val") }).first { format.underline = u != "none" }
                if let va = ([rPr] + chain(charStyle).map(\.rPr)).compactMap({ $0?.child("vertAlign")?.attr("val") }).first {
                    format.superscript = va == "superscript"; format.subscripted = va == "subscript"
                }
                // Explicit font, size and colour only (the paragraph's own come with its style).
                let explicit = [rPr] + chain(charStyle).map(\.rPr)
                let font = explicit.compactMap { $0?.child("rFonts") }.compactMap { $0.attr("ascii") ?? $0.attr("hAnsi") ?? $0.attr("cs") }.first
                if let font, DOCXReader.monospaceFonts.contains(font.lowercased()) { format.code = true }
                else if let font, font != paragraphFont(baseRPr) { format.font = font }
                if let half = explicit.compactMap({ $0?.child("sz")?.attr("val") }).compactMap(Double.init).first, half / 2 != paragraphSize(baseRPr) { format.size = half / 2 }
                if let colour = (isHyperlinkStyle ? [rPr] : explicit).compactMap({ $0?.child("color")?.attr("val") }).first, colour.lowercased() != "auto", colour.count == 6 { format.colour = "#" + colour.uppercased() }
                if charStyle != nil {
                    let n = styleName(charStyle)
                    if n.contains("code") || n.contains("verbatim") { format.code = true }
                }
                format.link = state.link ?? state.fieldStack.last(where: { $0.resultStarted })?.link
                // A run inside a field's instruction part is not text.
                let inInstruction = state.fieldStack.last.map { !$0.resultStarted } ?? false

                for child in r.children {
                    switch child.name {
                    case "fldChar":
                        switch child.attr("fldCharType") {
                        case "begin": state.fieldStack.append(FieldState())
                        case "separate":
                            if !state.fieldStack.isEmpty {
                                state.fieldStack[state.fieldStack.count - 1].resultStarted = true
                                let instruction = state.fieldStack[state.fieldStack.count - 1].instruction.trimmed
                                if instruction.uppercased().hasPrefix("HYPERLINK"), let q = instruction.firstIndex(of: "\"") {
                                    let rest = instruction[instruction.index(after: q)...]
                                    if let end = rest.firstIndex(of: "\"") { state.fieldStack[state.fieldStack.count - 1].link = String(rest[..<end]) }
                                }
                            }
                        case "end": _ = state.fieldStack.popLast()
                        default: break
                        }
                    case "instrText": if !state.fieldStack.isEmpty { state.fieldStack[state.fieldStack.count - 1].instruction += child.allText }
                    case "t", "delText": if !inInstruction { builder.add(child.allText, format) }
                    case "tab", "ptab": if !inInstruction { builder.add("\t", format) }
                    case "noBreakHyphen": builder.add("\u{2011}", format)
                    case "softHyphen": break
                    case "sym": if let c = child.attr("char"), let v = UInt32(c.suffix(4), radix: 16), let scalar = Unicode.Scalar(v) { builder.add(String(Character(scalar)), format) }
                    case "br", "cr":
                        if child.attr("type") == "page" { finishSegment() } else { builder.add(.lineBreak) }
                    case "lastRenderedPageBreak": break
                    case "drawing", "pict", "object":
                        if let image = image(child) {
                            imageCount += 1
                            onlyImage = image
                            builder.add(.image(resource: image.resource, alt: image.alt, link: format.link))
                        }
                    case "footnoteReference":
                        if let id = child.attr("id") { noteReference(id) ; builder.add(.footnote(id: id)) }
                    case "endnoteReference":
                        if let id = child.attr("id") { noteReference("e" + id); builder.add(.footnote(id: "e" + id)) }
                    case "oMath": builder.add(.math(tex: OMML.tex(child)))
                    default: break
                    }
                }
            }

            walk(p.children)
            finishSegment()

            let align = alignment(pPr, styleID)
            var style = DocParagraphStyle(alignment: align)
            style.fontName = paragraphFont(baseRPr)
            style.fontSize = paragraphSize(baseRPr)
            if let spacing = pPr?.child("spacing") {
                style.spaceBefore = spacing.attr("before").flatMap(Double.init).map { $0 / 20 }
                style.spaceAfter = spacing.attr("after").flatMap(Double.init).map { $0 / 20 }
            }

            for (index, text) in segments.enumerated() {
                if index > 0 { out.append(.block(.pageBreak)) }
                classify(text, pPr: pPr, styleID: styleID, names: names, primary: primary, style: style, imageCount: imageCount,
                         onlyImage: onlyImage, segmentCount: segments.count, into: &out)
            }
        }

        func noteReference(_ id: String) { if !referencedNotes.contains(id) { referencedNotes.append(id) } }

        func paragraphFont(_ chain: [XMLNode?]) -> String? {
            chain.compactMap { $0?.child("rFonts") }.compactMap { $0.attr("ascii") ?? $0.attr("hAnsi") }.first
        }

        func paragraphSize(_ chain: [XMLNode?]) -> Double? {
            chain.compactMap { $0?.child("sz")?.attr("val") }.compactMap(Double.init).first.map { $0 / 2 }
        }

        func alignment(_ pPr: XMLNode?, _ styleID: String?) -> DocParagraphStyle.Alignment {
            let jc = ([pPr] + chain(styleID).map(\.pPr) + [defaultPPr]).compactMap { $0?.child("jc")?.attr("val") }.first
            switch jc {
            case "center": return .centre
            case "right", "end": return .end
            case "both", "distribute": return .justified
            default: return .start
            }
        }

        func classify(_ text: DocText, pPr: XMLNode?, styleID: String?, names: [String], primary: String, style: DocParagraphStyle,
                               imageCount: Int, onlyImage: (resource: String, alt: String?)?, segmentCount: Int, into out: inout [Parsed]) {
            let plain = Inlines.plain(text).trimmed
            // Document metadata styles.
            if primary == "title", !plain.isEmpty { metadata.title = plain; return }
            if primary == "author", !plain.isEmpty { metadata.authors = plain.split(separator: ";").map { $0.trimmed }; return }
            if primary == "date", !plain.isEmpty, let date = ISO8601DateFormatter().date(from: plain) ?? DOCXReader.plainDate(plain) { metadata.date = date; return }
            if primary == "abstract", !plain.isEmpty { metadata.summary = plain; return }

            let isCodeStyle = primary.contains("source code") || primary == "code" || primary.contains("preformatted") || primary == "macro text"
            if text.isEmpty && isCodeStyle { out.append(.codeLine("")); return }
            if text.isEmpty {
                if pPr?.child("pBdr")?.child("bottom") != nil { out.append(.block(.thematicBreak)) }
                return   // an empty paragraph is spacing, not content
            }
            if let level = isHeadingStyle(styleID) { out.append(.heading(level, text)); return }
            // Lists.
            if let numPr = pPr?.child("numPr") ?? chain(styleID).compactMap({ $0.pPr?.child("numPr") }).first,
               let numId = numPr.child("numId")?.attr("val"), numId != "0" {
                let level = Int(numPr.child("ilvl")?.attr("val") ?? "0") ?? 0
                let info = numbering[numId]?[level] ?? Level(ordered: false, start: 1)
                out.append(.listItem(ListAssembler.Entry(level: level, ordered: info.ordered, start: info.start, blocks: [.paragraph(text, style)], listID: numId)))
                return
            }
            if names.contains(where: { $0.contains("list bullet") }) || primary.hasPrefix("list number") || primary.hasPrefix("list bullet") {
                let ordered = primary.hasPrefix("list number")
                out.append(.listItem(ListAssembler.Entry(level: 0, ordered: ordered, start: 1, blocks: [.paragraph(text, style)])))
                return
            }
            if primary == "caption" || primary == "table caption" || primary == "image caption" { out.append(.caption(text)); return }
            // Code: a code style, or every character in a monospaced font.
            let allCode = !Inlines.flatten(text).isEmpty && Inlines.flatten(text).allSatisfy {
                if case .run(_, let f) = $0 { return f.code }
                if case .lineBreak = $0 { return true }
                return false
            }
            if isCodeStyle || allCode {
                let lines = Inlines.flatten(text).map { item -> String in
                    if case .run(let t, _) = item { return t }
                    return "\n"
                }.joined()
                out.append(.codeLine(lines))
                return
            }
            if primary.contains("quote") || primary == "block text" {
                out.append(.quote(.paragraph(text, style)))
                return
            }
            // A picture alone in its paragraph is a figure.
            if imageCount == 1, let image = onlyImage, text.count == 1, case .image = text[0] {
                out.append(.block(.figure(resource: image.resource, caption: nil, altText: image.alt)))
                return
            }
            out.append(.block(.paragraph(text, style)))
        }

        // MARK: Images

        func image(_ node: XMLNode) -> (resource: String, alt: String?)? {
            var rid = node.first("blip")?.attr("embed")
            if rid == nil { rid = node.first("imagedata")?.attr("id") }
            guard let rid, let relationship = relationships[rid], !relationship.isExternal else { return nil }
            let folder = (mainPath as NSString).deletingLastPathComponent
            var path = relationship.target
            path = path.hasPrefix("/") ? String(path.dropFirst()) : (folder.isEmpty ? path : folder + "/" + path)
            path = (path as NSString).standardizingPath
            let alt = node.first("docPr")?.attr("descr").flatMap { $0.isEmpty ? nil : $0 }
            if let key = imageNames[path] { return (key, alt) }
            guard let data = try? archive.data(path) else { return nil }
            var key = (path as NSString).lastPathComponent
            while resources[key] != nil { key = "image\(resources.count + 1)." + (key as NSString).pathExtension }
            resources[key] = data
            imageNames[path] = key
            return (key, alt)
        }

        // MARK: Tables

        func table(_ tbl: XMLNode) -> DocTable {
            var rows: [[DocTable.Cell]] = []
            var open: [Int: (row: Int, cell: Int)] = [:]   // grid column → merge origin
            for tr in tbl.children("tr") {
                let isHeader = tr.child("trPr")?.child("tblHeader") != nil
                var cells: [DocTable.Cell] = []
                var column = 0
                let rowIndex = rows.count
                for tc in tr.children("tc") + tr.children("sdt").flatMap({ $0.child("sdtContent")?.children("tc") ?? [] }) {
                    let tcPr = tc.child("tcPr")
                    let span = max(Int(tcPr?.child("gridSpan")?.attr("val") ?? "1") ?? 1, 1)
                    if let merge = tcPr?.child("vMerge"), merge.attr("val") != "restart" {
                        if let origin = open[column], origin.row < rowIndex {
                            rows[origin.row][origin.cell].rowSpan += 1
                        }
                        column += span
                        continue
                    }
                    var blocks = parseBlocks(tc.children, inFootnote: false)
                    if blocks.isEmpty { blocks = [.paragraph([], DocParagraphStyle())] }
                    if tcPr?.child("vMerge") != nil { open[column] = (rowIndex, cells.count) } else { open[column] = nil }
                    cells.append(DocTable.Cell(blocks: blocks, columnSpan: span, rowSpan: 1, isHeader: isHeader))
                    column += span
                }
                rows.append(cells)
            }
            var alignments: [DocParagraphStyle.Alignment] = []
            if let first = rows.first(where: { !$0.isEmpty }) {
                for cell in first {
                    var a = DocParagraphStyle.Alignment.start
                    if case .paragraph(_, let s)? = cell.blocks.first { a = s.alignment }
                    alignments += Array(repeating: a, count: cell.columnSpan)
                }
            }
            return DocTable(rows: rows, caption: nil, alignments: alignments)
        }
    }

    static let monospaceFonts: Set<String> = [
        "courier new", "courier", "consolas", "menlo", "monaco", "lucida console", "source code pro", "sf mono", "andale mono",
        "liberation mono", "dejavu sans mono", "cascadia code", "cascadia mono", "fira code", "jetbrains mono", "latin modern mono",
    ]

    static func plainDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "d MMMM yyyy", "MMMM d, yyyy", "dd/MM/yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
