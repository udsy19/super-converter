import Foundation
import SuperConverterCore

/// FictionBook 2 → Publication (formats §3.2): one chapter per top-level section, notes as footnotes, binaries as resources.
public enum FB2Reader {
    public static func read(url: URL, progress: (Double) -> Void = { _ in }) throws -> PublicationRead {
        var data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.damaged("fb2") }
        if data.starts(with: [0x50, 0x4B]), let zip = try? ZipArchive(data: data),
           let entry = zip.entries.first(where: { $0.name.lowercased().hasSuffix(".fb2") }), let inner = try? zip.data(for: entry) { data = inner }
        let root = MarkupParser.parse(TextDecoding.string(from: data), html: false, lowercase: true)
        guard let book = root.descendant("fictionbook") else { throw ConversionError.damaged("fb2") }
        var state = State()

        // Description
        var metadata = DocMetadata()
        let info = book.descendant("title-info")
        metadata.title = info?.first("book-title")?.plainText.nonEmpty
        metadata.authors = (info?.elements(named: "author") ?? []).compactMap { author -> String? in
            let parts = ["first-name", "middle-name", "last-name"].compactMap { author.first($0)?.plainText.nonEmpty }
            return parts.isEmpty ? author.first("nickname")?.plainText.nonEmpty : parts.joined(separator: " ")
        }
        metadata.language = info?.first("lang")?.plainText.nonEmpty
        if let d = info?.first("date") { metadata.date = Date.fromBookDate(d.attribute("value") ?? d.plainText) }
        metadata.summary = info?.first("annotation")?.plainText.nonEmpty

        // Binaries
        var resources: [String: PublicationResource] = [:]
        for binary in book.descendants("binary") {
            guard let id = binary.attribute("id"),
                  let data = Data(base64Encoded: binary.rawText.filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters), !data.isEmpty else { continue }
            let declared = binary.attribute("content-type")?.lowercased() ?? ""
            let type = declared.hasPrefix("image/") ? MediaTypes.forImage(data, name: id) : declared
            resources[id] = PublicationResource(mediaType: type.isEmpty ? MediaTypes.forImage(data, name: id) : type, data: data)
        }
        state.resources = resources

        // Notes
        for body in book.elements(named: "body") where body.attribute("name") != nil {
            for section in body.descendants("section") { if let id = section.attribute("id") { state.notes[id] = section } }
        }

        var cover: String?
        if let href = info?.first("coverpage")?.first("image")?.attribute("href"), href.hasPrefix("#"), resources[String(href.dropFirst())] != nil {
            cover = String(href.dropFirst())
        }

        // Bodies
        var spine: [PublicationItem] = []
        var contents: [ContentsEntry] = []
        let bodies = book.elements(named: "body").filter { $0.attribute("name") == nil }
        let total = max(1, bodies.reduce(0) { $0 + max(1, $1.elements(named: "section").count) })
        var done = 0
        func addItem(title: String?, blocks: [DocBlock], state: inout State) {
            let id = String(format: "c%03d", spine.count + 1)
            var all = blocks
            for noteID in state.referenced { if let note = state.notes[noteID] { all.append(.footnote(id: id + "-" + noteID, state.noteBlocks(note))) } }
            let keys = DocWalk.imageKeys(in: all)
            // Footnote references were written with the bare note id; give them this chapter's prefix.
            let renamed = DocWalk.rewrite(all) { piece in
                if case .footnoteReference(let n) = piece { return [.footnoteReference(id: id + "-" + n)] }
                return nil
            }
            let doc = DocModel(metadata: DocMetadata(title: title), blocks: renamed, resources: state.resources.filter { keys.contains($0.key) }.mapValues(\.data))
            spine.append(PublicationItem(id: id, title: title, content: .document(doc)))
            if let title, !title.isEmpty { contents.append(ContentsEntry(title: title, itemID: id)) }
            state.referenced = []
        }
        for body in bodies {
            let sections = body.elements(named: "section")
            var front: [DocBlock] = []
            var frontTitle: String?
            for child in body.elements where child.name != "section" {
                switch child.name {
                case "title":
                    let t = state.titleText(child)
                    if !t.isEmpty { front.append(.heading(level: 1, [.text(t)])); frontTitle = frontTitle ?? t }
                default: state.blocks(of: child, depth: 0, into: &front)
                }
            }
            if sections.isEmpty {
                if !front.isEmpty { addItem(title: frontTitle ?? metadata.title, blocks: front, state: &state) }
                continue
            }
            if !front.isEmpty { addItem(title: frontTitle, blocks: front, state: &state) }
            for section in sections {
                var blocks: [DocBlock] = []
                state.section(section, depth: 0, into: &blocks)
                let title = section.first("title").map { state.titleText($0) }?.nonEmpty
                addItem(title: title, blocks: blocks, state: &state)
                done += 1
                progress(Double(done) / Double(total))
            }
        }
        guard !spine.isEmpty else { throw ConversionError.damaged("fb2") }
        let images = resources.filter { MediaTypes.isImage($0.value.mediaType) }
        let publication = Publication(metadata: metadata, spine: spine, contents: contents, cover: cover, resources: images)
        return PublicationRead(publication, lossNotes: PublicationRead.notes(state.losses))
    }

    private struct State {
        var resources: [String: PublicationResource] = [:]
        var notes: [String: MarkupNode] = [:]
        var referenced: [String] = []
        var losses: Set<LossNote.Kind> = []
        /// Blocks and inlines read inside one another, held to `ContentReader.maxDepth` as the content reader is (the
        /// stack is half a megabyte); deeper branches are kept as their text.
        var nesting = 0

        func titleText(_ title: MarkupNode) -> String {
            title.elements.map(\.plainText).filter { !$0.isEmpty }.joined(separator: " ").nonEmpty ?? title.plainText
        }

        mutating func noteBlocks(_ note: MarkupNode) -> [DocBlock] {
            var out: [DocBlock] = []
            for child in note.elements where child.name != "title" { blocks(of: child, depth: 1, into: &out) }
            return out
        }

        mutating func section(_ node: MarkupNode, depth: Int, into out: inout [DocBlock]) {
            guard nesting < ContentReader.maxDepth else {
                let text = ContentReader.plainText([node])
                if !text.isEmpty { out.append(.paragraph([.text(text)], DocParagraphStyle())) }
                return
            }
            nesting += 1
            defer { nesting -= 1 }
            for child in node.elements {
                switch child.name {
                case "title":
                    let t = titleText(child)
                    if !t.isEmpty { out.append(.heading(level: min(depth + 1, 6), [.text(t)])) }
                case "section": section(child, depth: depth + 1, into: &out)
                default: blocks(of: child, depth: depth, into: &out)
                }
            }
        }

        mutating func blocks(of node: MarkupNode, depth: Int, into out: inout [DocBlock]) {
            guard nesting < ContentReader.maxDepth else {
                let text = ContentReader.plainText([node])
                if !text.isEmpty { out.append(.paragraph([.text(text)], DocParagraphStyle())) }
                return
            }
            nesting += 1
            defer { nesting -= 1 }
            switch node.name {
            case "p":
                let text = ContentReader.normalise(inline(node.children))
                if !text.isEmpty { out.append(.paragraph(text, DocParagraphStyle())) }
            case "subtitle":
                let text = ContentReader.normalise(inline(node.children))
                if !text.isEmpty { out.append(.paragraph([.strong(text)], DocParagraphStyle(alignment: .centre))) }
            case "text-author":
                let text = ContentReader.normalise(inline(node.children))
                if !text.isEmpty { out.append(.paragraph([.emphasis(text)], DocParagraphStyle(alignment: .end))) }
            case "empty-line": break
            case "image":
                if let href = node.attribute("href"), href.hasPrefix("#"), resources[String(href.dropFirst())] != nil {
                    out.append(.figure(resource: String(href.dropFirst()), caption: nil, altText: node.attribute("alt") ?? node.attribute("title")))
                }
            case "epigraph", "cite", "annotation":
                var inner: [DocBlock] = []
                for child in node.elements { blocks(of: child, depth: depth, into: &inner) }
                if !inner.isEmpty { out.append(.quote(inner)) }
            case "poem":
                var inner: [DocBlock] = []
                for child in node.elements {
                    switch child.name {
                    case "title":
                        let t = titleText(child)
                        if !t.isEmpty { inner.append(.paragraph([.strong([.text(t)])], DocParagraphStyle())) }
                    case "stanza":
                        var lines: DocText = []
                        for v in child.elements where v.name == "v" {
                            if !lines.isEmpty { lines.append(.lineBreak) }
                            lines += ContentReader.normalise(inline(v.children))
                        }
                        if !lines.isEmpty { inner.append(.paragraph(lines, DocParagraphStyle())) }
                    default: blocks(of: child, depth: depth, into: &inner)
                    }
                }
                if !inner.isEmpty { out.append(.quote(inner)) }
            case "table":
                var rows: [[DocTable.Cell]] = []
                for tr in node.elements where tr.name == "tr" {
                    var cells: [DocTable.Cell] = []
                    for c in tr.elements where c.name == "td" || c.name == "th" {
                        let text = ContentReader.normalise(inline(c.children))
                        cells.append(DocTable.Cell(blocks: text.isEmpty ? [] : [.paragraph(text, DocParagraphStyle())],
                                                   columnSpan: ContentReader.span(c.attribute("colspan"), limit: 1_000),
                                                   rowSpan: ContentReader.span(c.attribute("rowspan"), limit: 65_534),
                                                   isHeader: c.name == "th"))
                    }
                    if !cells.isEmpty { rows.append(cells) }
                }
                if !rows.isEmpty { out.append(.table(DocTable(rows: rows))) }
            case "section": section(node, depth: depth + 1, into: &out)
            default: break
            }
        }

        mutating func inline(_ nodes: [MarkupNode]) -> DocText {
            guard nesting < ContentReader.maxDepth else { return [.text(ContentReader.plainText(nodes))] }
            nesting += 1
            defer { nesting -= 1 }
            var out: DocText = []
            for node in nodes {
                if let t = node.text { out.append(.text(ContentReader.collapse(t))); continue }
                switch node.name {
                case "emphasis": out.append(.emphasis(inline(node.children)))
                case "strong": out.append(.strong(inline(node.children)))
                case "strikethrough": out.append(.strike(inline(node.children)))
                case "sub": out.append(.styled(inline(node.children), DocRunStyle(subscripted: true)))
                case "sup": out.append(.styled(inline(node.children), DocRunStyle(superscript: true)))
                case "code": out.append(.code(node.rawText))
                case "image":
                    if let href = node.attribute("href"), href.hasPrefix("#"), resources[String(href.dropFirst())] != nil {
                        out.append(.image(resource: String(href.dropFirst()), altText: node.attribute("alt")))
                    }
                case "a":
                    let href = node.attribute("href") ?? ""
                    let inner = inline(node.children)
                    if node.attribute("type") == "note", href.hasPrefix("#"), notes[String(href.dropFirst())] != nil {
                        let id = String(href.dropFirst())
                        if !referenced.contains(id) { referenced.append(id) }
                        out.append(.footnoteReference(id: id))
                    } else if PackagePath.isExternal(href) { out.append(.link(inner, destination: href)) }
                    else { out += inner; if href.hasPrefix("#") { losses.insert(.hyperlinksDropped) } }
                default: out += inline(node.children)   // style, strong inside spans, …
                }
            }
            return out
        }
    }
}
