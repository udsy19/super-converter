// Adapted from super-pdf Sources/ConvertKit/Import/HWPXImporter.swift (commit 058469b): the same OWPML package reading
// (manifest order, charPr/paraPr tables, runs, tables, BinData pictures), producing a `DocModel` instead of laying the text
// out with TextKit; table spans, header rows and pictures are kept as model blocks.

import Foundation
import SuperConverterCore

/// Hangul .hwpx (OWPML, a ZIP of XML) → `DocModel` (formats §3.2 `HWPXReader`).
enum HWPXReader {
    static func read(_ url: URL, options: DocReadOptions = DocReadOptions()) throws -> DocReadResult {
        let archive: ZipArchive
        do { archive = try ZipArchive(url: url) } catch { throw ConversionError.damaged("hwpx") }
        if let manifest = try? archive.data("META-INF/manifest.xml"), String(decoding: manifest, as: UTF8.self).contains("encryption-data") {
            throw ConversionError.passwordRequired("hwpx")
        }
        let package = try Package(archive)
        var blocks: [DocBlock] = []
        var resources: [String: Data] = [:]
        for section in package.sections {
            guard let data = try archive.data(section), let root = try? XML.parse(data, keepWhitespace: true) else { continue }
            for paragraph in root.children("p") { blocks += package.blocks(paragraph, resources: &resources) }
        }
        guard !blocks.isEmpty else { throw ConversionError.damaged("hwpx") }
        var metadata = DocMetadata()
        if let head = try? archive.data("Contents/content.hpf"), let root = try? XML.parse(head) {
            if let title = root.first("title")?.allText.trimmed, !title.isEmpty { metadata.title = title }
            if let creator = root.all("meta").first(where: { $0.attr("name") == "creator" })?.allText.trimmed, !creator.isEmpty { metadata.authors = [creator] }
        }
        return DocReadResult(model: DocModel(metadata: metadata, blocks: blocks, resources: resources))
    }

    /// The package: sections in reading order, character and paragraph properties, pictures.
    struct Package {
        var sections: [String] = []
        var characters: [String: (size: Double, bold: Bool, italic: Bool, underline: Bool, colour: String?)] = [:]
        var alignments: [String: DocParagraphStyle.Alignment] = [:]
        var pictures: [String: (name: String, data: Data)] = [:]

        init(_ archive: ZipArchive) throws {
            var manifest: [String: String] = [:]
            if let hpf = try archive.data("Contents/content.hpf") {
                let opf = try XML.parse(hpf)
                for item in opf.all("item") {
                    if let id = item.attr("id"), let href = item.attr("href") { manifest[id] = href }
                }
                sections = opf.all("itemref").compactMap { $0.attr("idref").flatMap { manifest[$0] } }
            }
            if sections.isEmpty {
                sections = archive.entries.map(\.path).filter { $0.hasPrefix("Contents/section") && $0.hasSuffix(".xml") }
                    .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            }
            guard !sections.isEmpty else { throw ConversionError.damaged("hwpx") }
            if let header = try archive.data("Contents/header.xml"), let root = try? XML.parse(header) {
                for property in root.all("charPr") {
                    guard let id = property.attr("id") else { continue }
                    let size = (Double(property.attr("height") ?? "1000") ?? 1000) / 100
                    let colour = property.attr("textColor").flatMap { $0.hasPrefix("#") && $0.count == 7 && $0 != "#000000" ? $0.uppercased() : nil }
                    characters[id] = (max(size, 4), property.child("bold") != nil, property.child("italic") != nil,
                                      property.child("underline").map { $0.attr("type") != "NONE" } ?? false, colour)
                }
                for property in root.all("paraPr") {
                    guard let id = property.attr("id") else { continue }
                    alignments[id] = switch property.first("align")?.attr("horizontal")?.uppercased() {
                    case "CENTER": .centre
                    case "RIGHT": .end
                    case "JUSTIFY", "DISTRIBUTE": .justified
                    default: .start
                    }
                }
            }
            for (id, href) in manifest where href.lowercased().hasPrefix("bindata/") {
                if let data = try archive.data(href) { pictures[id] = ((href as NSString).lastPathComponent, data) }
            }
        }

        func format(_ characterID: String?) -> RunFormat {
            var f = RunFormat()
            guard let p = characterID.flatMap({ characters[$0] }) else { return f }
            f.bold = p.bold; f.italic = p.italic; f.underline = p.underline; f.colour = p.colour
            return f
        }

        /// One `hp:p` as blocks: its text, then the tables and pictures that sit in its runs.
        func blocks(_ paragraph: XMLNode, resources: inout [String: Data]) -> [DocBlock] {
            let alignment = paragraph.attr("paraPrIDRef").flatMap { alignments[$0] } ?? .start
            var builder = InlineBuilder()
            var extra: [DocBlock] = []
            for run in paragraph.children("run") {
                let f = format(run.attr("charPrIDRef") ?? paragraph.attr("charPrIDRef"))
                for child in run.children {
                    switch child.name {
                    case "t":
                        for content in child.content {
                            switch content {
                            case .text(let string): builder.add(string, f)
                            case .element(let node) where node.name == "tab": builder.add("\t", f)
                            case .element(let node) where node.name == "lineBreak": builder.add(.lineBreak)
                            default: break
                            }
                        }
                    case "tbl": extra.append(.table(table(child, resources: &resources)))
                    case "pic":
                        if let id = child.first("img")?.attr("binaryItemIDRef"), let picture = pictures[id] {
                            resources[picture.name] = picture.data
                            extra.append(.figure(resource: picture.name, caption: nil, altText: nil))
                        }
                    default: break
                    }
                }
            }
            builder.trim()
            var out: [DocBlock] = []
            if !builder.isEmpty { out.append(.paragraph(builder.build(), DocParagraphStyle(alignment: alignment))) }
            return out + extra
        }

        private func table(_ table: XMLNode, resources: inout [String: Data]) -> DocTable {
            var rows: [[DocTable.Cell]] = []
            for (r, row) in table.children("tr").enumerated() {
                var cells: [DocTable.Cell] = []
                for cell in row.children("tc") {
                    let span = cell.first("cellSpan")
                    var content: [DocBlock] = []
                    for p in cell.all("p") { content += blocks(p, resources: &resources) }
                    if content.isEmpty { content = [.paragraph([], DocParagraphStyle())] }
                    cells.append(DocTable.Cell(blocks: content, columnSpan: max(Int(span?.attr("colSpan") ?? "1") ?? 1, 1),
                                               rowSpan: max(Int(span?.attr("rowSpan") ?? "1") ?? 1, 1),
                                               isHeader: r == 0 && table.attr("repeatHeader") == "1"))
                }
                rows.append(cells)
            }
            return DocTable(rows: rows)
        }
    }
}
