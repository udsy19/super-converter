import Foundation
import SuperConverterCore

/// Traversal helpers for `DocModel` content.
enum DocWalk {
    static func plainText(_ text: DocText) -> String {
        text.map { piece -> String in
            switch piece {
            case .text(let s), .code(let s): s
            case .emphasis(let t), .strong(let t), .strike(let t), .link(let t, _), .styled(let t, _): plainText(t)
            case .image(_, let alt): alt ?? ""
            case .math(let tex): tex
            case .lineBreak: " "
            case .footnoteReference: ""
            }
        }.joined().collapsingWhitespace()
    }

    static func plainText(_ blocks: [DocBlock]) -> String {
        blocks.map { block -> String in
            switch block {
            case .heading(_, let t), .paragraph(let t, _): plainText(t)
            case .list(_, _, let items): items.map { plainText($0) }.joined(separator: " ")
            case .table(let table): table.rows.flatMap { $0 }.map { plainText($0.blocks) }.joined(separator: " ")
            case .figure(_, let caption, _): caption.map(plainText) ?? ""
            case .code(_, let text): text
            case .quote(let inner), .footnote(_, let inner): plainText(inner)
            case .math(let tex, _): tex
            case .thematicBreak, .pageBreak: ""
            }
        }.joined(separator: " ").collapsingWhitespace()
    }

    /// Calls `inline` for every inline in `blocks`, depth first, and `block` for every block.
    static func visit(_ blocks: [DocBlock], block: (DocBlock) -> Void = { _ in }, inline: (DocInline) -> Void = { _ in }) {
        func walkText(_ text: DocText) {
            for piece in text {
                inline(piece)
                switch piece {
                case .emphasis(let t), .strong(let t), .strike(let t), .link(let t, _), .styled(let t, _): walkText(t)
                default: break
                }
            }
        }
        func walk(_ blocks: [DocBlock]) {
            for b in blocks {
                block(b)
                switch b {
                case .heading(_, let t), .paragraph(let t, _): walkText(t)
                case .list(_, _, let items): items.forEach(walk)
                case .table(let table):
                    if let c = table.caption { walkText(c) }
                    table.rows.forEach { $0.forEach { walk($0.blocks) } }
                case .figure(_, let caption, _): if let caption { walkText(caption) }
                case .quote(let inner), .footnote(_, let inner): walk(inner)
                default: break
                }
            }
        }
        walk(blocks)
    }

    /// Rewrites inlines: where `transform` answers non-nil the piece is replaced (and not descended into); else its children
    /// are rewritten.
    static func rewrite(_ blocks: [DocBlock], _ transform: (DocInline) -> DocText?) -> [DocBlock] {
        func text(_ t: DocText) -> DocText {
            t.flatMap { piece -> DocText in
                if let replacement = transform(piece) { return replacement }
                switch piece {
                case .emphasis(let x): return [.emphasis(text(x))]
                case .strong(let x): return [.strong(text(x))]
                case .strike(let x): return [.strike(text(x))]
                case .link(let x, let d): return [.link(text(x), destination: d)]
                case .styled(let x, let s): return [.styled(text(x), s)]
                default: return [piece]
                }
            }
        }
        func map(_ blocks: [DocBlock]) -> [DocBlock] {
            blocks.map { b in
                switch b {
                case .heading(let l, let t): return .heading(level: l, text(t))
                case .paragraph(let t, let s): return .paragraph(text(t), s)
                case .list(let o, let n, let items): return .list(ordered: o, start: n, items: items.map(map))
                case .table(var table):
                    table.caption = table.caption.map(text)
                    table.rows = table.rows.map { $0.map { var c = $0; c.blocks = map(c.blocks); return c } }
                    return .table(table)
                case .figure(let r, let c, let a): return .figure(resource: r, caption: c.map(text), altText: a)
                case .quote(let inner): return .quote(map(inner))
                case .footnote(let id, let inner): return .footnote(id: id, map(inner))
                default: return b
                }
            }
        }
        return map(blocks)
    }

    static func imageKeys(in blocks: [DocBlock]) -> Set<String> {
        var keys: Set<String> = []
        visit(blocks, block: { if case .figure(let r, _, _) = $0 { keys.insert(r) } }, inline: { if case .image(let r, _) = $0 { keys.insert(r) } })
        return keys
    }

    static func footnoteReferences(in blocks: [DocBlock]) -> [String] {
        var ids: [String] = []
        visit(blocks, inline: { if case .footnoteReference(let id) = $0, !ids.contains(id) { ids.append(id) } })
        return ids
    }
}

/// Building publications from documents and documents from publications.
public enum PublicationBuilder {
    /// A document becomes a book: split into chapters at its top-level headings (level 1, else 2), with a contents entry per
    /// chapter. Footnotes travel with the chapter that cites them; each chapter keeps only the pictures it uses.
    public static func publication(from doc: DocModel) -> Publication {
        let headingLevels = doc.blocks.compactMap { b -> Int? in if case .heading(let l, _) = b { return l }; return nil }
        let splitLevel = headingLevels.contains(1) ? 1 : (headingLevels.contains(2) ? 2 : 0)

        var notes: [String: DocBlock] = [:]
        var stream: [DocBlock] = []
        for b in doc.blocks { if case .footnote(let id, _) = b { notes[id] = b } else { stream.append(b) } }

        var groups: [(title: String?, blocks: [DocBlock])] = []
        for b in stream {
            if splitLevel > 0, case .heading(let level, let text) = b, level == splitLevel {
                groups.append((DocWalk.plainText(text), [b]))
            } else if groups.isEmpty {
                groups.append((nil, [b]))
            } else {
                groups[groups.count - 1].blocks.append(b)
            }
        }
        if groups.isEmpty { groups = [(nil, [])] }

        var spine: [PublicationItem] = []
        var contents: [ContentsEntry] = []
        for (n, group) in groups.enumerated() {
            let id = String(format: "c%03d", n + 1)
            var blocks = group.blocks
            for ref in DocWalk.footnoteReferences(in: blocks) { if let note = notes[ref] { blocks.append(note) } }
            let keys = DocWalk.imageKeys(in: blocks)
            let resources = doc.resources.filter { keys.contains($0.key) }
            let title = group.title ?? (n == 0 ? doc.metadata.title : nil)
            spine.append(PublicationItem(id: id, title: title, content: .document(DocModel(metadata: DocMetadata(title: title), blocks: blocks, resources: resources))))
            if let title, !title.isEmpty { contents.append(ContentsEntry(title: title, itemID: id)) }
        }
        return Publication(metadata: doc.metadata, spine: spine, contents: contents)
    }

    /// The book as one document (for RTF, TXT and the other document targets): chapters in reading order, pictures of fixed
    /// layout pages as figures. Links between chapters cannot be kept in a flat document and become plain text.
    public static func document(from publication: Publication) -> (doc: DocModel, lossNotes: [LossNote]) {
        var blocks: [DocBlock] = []
        var resources: [String: Data] = [:]
        var droppedLinks = false
        let bookTitle = publication.metadata.title
        for (n, item) in publication.spine.enumerated() {
            switch item.content {
            case .document(let doc):
                var chapter = DocWalk.rewrite(doc.blocks) { piece in
                    if case .link(let text, let destination) = piece, destination.hasPrefix("item:") { droppedLinks = true; return text }
                    return nil
                }
                if publication.spine.count > 1, let title = item.title, !title.isEmpty, title != bookTitle {
                    var hasHeading = false
                    if case .heading? = chapter.first { hasHeading = true }
                    if !hasHeading { chapter.insert(.heading(level: 1, [.text(title)]), at: 0) }
                }
                if n > 0, !blocks.isEmpty { blocks.append(.pageBreak) }
                blocks += chapter
                resources.merge(doc.resources) { a, _ in a }
            case .page(let key):
                guard let picture = publication.resources[key] else { continue }
                resources[key] = picture.data
                blocks.append(.figure(resource: key, caption: nil, altText: "Page \(n + 1)"))
            }
        }
        var meta = publication.metadata
        if meta.title == nil { meta.title = publication.spine.first?.title }
        return (DocModel(metadata: meta, blocks: blocks, resources: resources), droppedLinks ? [LossNote(.hyperlinksDropped, detail: "Links between chapters")] : [])
    }
}
