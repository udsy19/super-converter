import AppKit
import Foundation
import SuperConverterCore

/// `DocModel` → RTF or Word 97 `.doc` through TextKit (formats §3.2 `TextKitExport`): the model becomes attributed text
/// (heading sizes, bold/italic/underline/strike, fonts and colours, links, `NSTextList` lists, `NSTextTable` tables, pictures
/// as attachments) and TextKit writes the file. Footnotes become numbered notes at the end; formulas stay as their TeX.
/// AppKit's text system is main-thread: call from the main actor.
@MainActor
enum TextKitExport {
    static func write(_ model: DocModel, format: FormatID, to url: URL) throws -> [LossNote] {
        let type: NSAttributedString.DocumentType = format.rawValue == "rtf" ? .rtf : .docFormat
        var builder = Builder(model: model, embedPictures: type == .rtf)
        let text = builder.attributedString()
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [:]
        attributes[.documentType] = type
        if let title = model.metadata.title { attributes[.title] = title }
        if let author = model.metadata.authors.first { attributes[.author] = author }
        if let summary = model.metadata.summary { attributes[.comment] = summary }
        var data: Data
        do { data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes) }
        catch { throw ConversionError.failed("The document couldn’t be written.") }
        if type == .rtf, !builder.pictures.isEmpty {
            // TextKit writes no pictures: the markers it carried become `\pict` groups.
            var rtf = String(decoding: data, as: UTF8.self)
            for (index, picture) in builder.pictures.enumerated() {
                rtf = rtf.replacingOccurrences(of: RTFPictures.marker(index), with: RTFPictures.group(picture.data, width: picture.width, height: picture.height))
            }
            data = Data(rtf.utf8)
        }
        try data.write(to: url, options: .atomic)
        return LossNote.merged(builder.lossNotes)
    }

    private struct Builder {
        let model: DocModel
        let embedPictures: Bool
        var pictures: [(data: Data, width: Double, height: Double)] = []
        var lossNotes: [LossNote] = []
        var footnoteNumbers: [String: Int] = [:]
        var footnoteBodies: [String: [DocBlock]] = [:]
        let bodyFont = NSFont(name: "Times New Roman", size: 12) ?? NSFont.systemFont(ofSize: 12)
        let monoFont = NSFont(name: "Courier New", size: 10) ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

        init(model: DocModel, embedPictures: Bool) {
            self.model = model; self.embedPictures = embedPictures
            for case .footnote(let id, let blocks) in model.blocks { footnoteBodies[id] = blocks }
        }

        mutating func attributedString() -> NSAttributedString {
            let out = NSMutableAttributedString()
            let m = model.metadata
            if let t = m.title { out.append(paragraph(attributed([.text(t)], font: bodyFont.sized(24).bold), style: style(alignment: .center, after: 6))) }
            if !m.authors.isEmpty { out.append(paragraph(attributed([.text(m.authors.joined(separator: "; "))], font: bodyFont), style: style(alignment: .center, after: 6))) }
            if let d = m.date { out.append(paragraph(attributed([.text(DocDates.string(d))], font: bodyFont), style: style(alignment: .center, after: 6))) }
            if let s = m.summary { out.append(paragraph(attributed([.text(s)], font: bodyFont.italic), style: style(after: 8))) }
            for block in model.blocks { out.append(self.block(block)) }
            var done = 0
            var heading = false
            while done < footnoteNumbers.count {
                guard let (id, number) = footnoteNumbers.first(where: { $0.value == done + 1 }) else { break }
                if !heading { out.append(paragraph(NSAttributedString(string: "Notes", attributes: [.font: bodyFont.sized(14).bold]), style: style(before: 12, after: 4))); heading = true }
                done += 1
                var note = NSMutableAttributedString(string: "\(number). ", attributes: [.font: bodyFont.sized(10)])
                for b in footnoteBodies[id] ?? [] { note.append(self.block(b, size: 10)) }
                if !note.string.hasSuffix("\n") { note = NSMutableAttributedString(attributedString: note); note.append(NSAttributedString(string: "\n")) }
                out.append(note)
            }
            if !footnoteNumbers.isEmpty { lossNotes.append(LossNote(.formattingSimplified, detail: "footnotes became notes at the end")) }
            return out
        }

        // MARK: Styles

        func style(alignment: NSTextAlignment = .natural, before: CGFloat = 0, after: CGFloat = 6, indent: CGFloat = 0) -> NSMutableParagraphStyle {
            let s = NSMutableParagraphStyle()
            s.alignment = alignment
            s.paragraphSpacingBefore = before
            s.paragraphSpacing = after
            s.firstLineHeadIndent = indent
            s.headIndent = indent
            return s
        }

        func paragraph(_ text: NSAttributedString, style: NSParagraphStyle) -> NSAttributedString {
            let out = NSMutableAttributedString(attributedString: text)
            out.append(NSAttributedString(string: "\n"))
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
            return out
        }

        func alignment(_ a: DocParagraphStyle.Alignment) -> NSTextAlignment {
            switch a { case .start: .natural; case .centre: .center; case .end: .right; case .justified: .justified }
        }

        // MARK: Blocks

        mutating func block(_ block: DocBlock, size: CGFloat = 12, indent: CGFloat = 0, textLists: [NSTextList] = []) -> NSAttributedString {
            let base = bodyFont.sized(size)
            switch block {
            case .heading(let level, let text):
                let sizes: [CGFloat] = [24, 20, 16, 14, 12, 12]
                return paragraph(attributed(text, font: base.sized(sizes[min(max(level, 1), 6) - 1]).bold), style: style(before: 12, after: 4, indent: indent))
            case .paragraph(let text, let pStyle):
                var font = base
                if let name = pStyle.fontName, let f = NSFont(name: name, size: CGFloat(pStyle.fontSize ?? Double(size))) { font = f }
                return paragraph(attributed(text, font: font), style: style(alignment: alignment(pStyle.alignment), before: CGFloat(pStyle.spaceBefore ?? 0), after: CGFloat(pStyle.spaceAfter ?? 6), indent: indent))
            case .list(let ordered, let start, let items):
                let list = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
                list.startingItemNumber = start
                let lists = textLists + [list]
                let out = NSMutableAttributedString()
                for (i, item) in items.enumerated() {
                    for (n, child) in item.enumerated() {
                        if case .list = child { out.append(self.block(child, size: size, indent: indent + 18, textLists: lists)); continue }
                        let inner = self.block(child, size: size, indent: indent + 18, textLists: lists)
                        guard n == 0 else { out.append(inner); continue }
                        // The marker is text: tab, marker, tab.
                        let marker = list.marker(forItemNumber: start + i)
                        let line = NSMutableAttributedString(string: "\t\(marker)\t", attributes: [.font: base])
                        line.append(inner)
                        let s = (inner.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSMutableParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? style()
                        s.textLists = lists
                        s.headIndent = indent + 36
                        s.firstLineHeadIndent = indent + 18
                        s.tabStops = [NSTextTab(textAlignment: .left, location: indent + 18 + 4), NSTextTab(textAlignment: .left, location: indent + 36)]
                        line.addAttribute(.paragraphStyle, value: s, range: NSRange(location: 0, length: line.length))
                        out.append(line)
                    }
                }
                return out
            case .table(let table): return self.table(table, size: size)
            case .figure(let resource, let caption, _):
                let out = NSMutableAttributedString()
                if let picture = picture(resource, maxWidth: 430, font: base) { out.append(paragraph(picture, style: style(alignment: .center, after: 4))) }
                if let caption { out.append(paragraph(attributed(caption, font: base.sized(10).italic), style: style(alignment: .center, after: 8))) }
                return out
            case .code(_, let text):
                let out = NSMutableAttributedString()
                for line in text.normalisedNewlines.split(separator: "\n", omittingEmptySubsequences: false) {
                    out.append(paragraph(NSAttributedString(string: String(line), attributes: [.font: monoFont]), style: style(after: 0, indent: indent + 12)))
                }
                return out
            case .quote(let blocks):
                let out = NSMutableAttributedString()
                for b in blocks { out.append(self.block(b, size: size, indent: indent + 36)) }
                return out
            case .math(let tex, _):
                lossNotes.append(LossNote(.formattingSimplified, detail: "formulas stay as TeX"))
                return paragraph(NSAttributedString(string: tex, attributes: [.font: monoFont.italic]), style: style(alignment: .center))
            case .footnote: return NSAttributedString()
            case .thematicBreak:
                return paragraph(NSAttributedString(string: String(repeating: "\u{2014}", count: 24), attributes: [.font: base, .foregroundColor: NSColor.gray]), style: style(alignment: .center))
            case .pageBreak:
                return NSAttributedString(string: "\u{0C}")
            }
        }

        mutating func table(_ table: DocTable, size: CGFloat) -> NSAttributedString {
            let textTable = NSTextTable()
            let (columns, rows) = TableGrid.expand(table)
            textTable.numberOfColumns = columns
            textTable.collapsesBorders = true
            let out = NSMutableAttributedString()
            for (r, row) in rows.enumerated() {
                for (c, slot) in row.enumerated() {
                    guard let cell = slot.cell else { continue }
                    let block = NSTextTableBlock(table: textTable, startingRow: r, rowSpan: cell.rowSpan, startingColumn: c, columnSpan: min(cell.columnSpan, columns - c))
                    block.setWidth(0.5, type: .absoluteValueType, for: .border)
                    block.setBorderColor(.darkGray)
                    block.setWidth(3, type: .absoluteValueType, for: .padding)
                    let content = NSMutableAttributedString()
                    for b in cell.blocks {
                        if case .paragraph(let text, let pStyle) = b {
                            let s = style(alignment: alignment(pStyle.alignment == .start && c < table.alignments.count ? table.alignments[c] : pStyle.alignment), after: 0)
                            content.append(paragraph(attributed(text, font: cell.isHeader ? bodyFont.sized(size).bold : bodyFont.sized(size)), style: s))
                        } else { content.append(self.block(b, size: size)) }
                    }
                    if content.length == 0 { content.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont.sized(size)])) }
                    content.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: content.length)) { value, range, _ in
                        let s = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                        s.textBlocks = [block]
                        content.addAttribute(.paragraphStyle, value: s, range: range)
                    }
                    out.append(content)
                }
            }
            if let caption = table.caption { out.append(paragraph(attributed(caption, font: bodyFont.sized(10).italic), style: style(alignment: .center, after: 8))) }
            return out
        }

        // MARK: Inlines

        mutating func attributed(_ text: DocText, font: NSFont) -> NSAttributedString {
            let out = NSMutableAttributedString()
            for item in Inlines.flatten(text) {
                switch item {
                case .run(let t, let f):
                    var run = font
                    if f.code { run = monoFont.sized(font.pointSize * 0.9) }
                    else if let name = f.font, let custom = NSFont(name: name, size: font.pointSize) { run = custom }
                    if let size = f.size { run = run.sized(CGFloat(size)) }
                    if f.bold { run = run.bold }
                    if f.italic { run = run.italic }
                    var attrs: [NSAttributedString.Key: Any] = [.font: run]
                    if f.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    if f.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                    if f.superscript { attrs[.superscript] = 1 } else if f.subscripted { attrs[.superscript] = -1 }
                    if let hex = f.colour, let colour = Self.colour(hex) { attrs[.foregroundColor] = colour }
                    if let link = f.link, let url = URL(string: link) { attrs[.link] = url; attrs[.foregroundColor] = NSColor.linkColor; attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    out.append(NSAttributedString(string: t, attributes: attrs))
                case .image(let resource, _, _):
                    if let picture = picture(resource, maxWidth: 200, font: font, inline: true) { out.append(picture) }
                case .footnote(let id):
                    let n = footnoteNumbers[id] ?? { let n = footnoteNumbers.count + 1; footnoteNumbers[id] = n; return n }()
                    out.append(NSAttributedString(string: "\(n)", attributes: [.font: font.sized(font.pointSize * 0.7), .superscript: 1]))
                case .math(let tex):
                    lossNotes.append(LossNote(.formattingSimplified, detail: "formulas stay as TeX"))
                    out.append(NSAttributedString(string: tex, attributes: [.font: monoFont.italic]))
                case .lineBreak:
                    out.append(NSAttributedString(string: "\u{2028}", attributes: [.font: font]))
                }
            }
            return out
        }

        /// A picture as marker text (RTF: swapped for a `\pict` group once TextKit has written the file). Word 97 files written
        /// by TextKit carry no pictures, which is reported.
        mutating func picture(_ resource: String, maxWidth: Double, font: NSFont, inline: Bool = false) -> NSAttributedString? {
            guard let data = model.resources[resource], let prepared = ImageSniff.prepare(data, native: ["png", "jpeg"]), embedPictures else {
                lossNotes.append(LossNote(.imagesDropped, detail: resource))
                return nil
            }
            var width = Double(prepared.pixelWidth) / prepared.dpi * 72, height = Double(prepared.pixelHeight) / prepared.dpi * 72
            let scale = inline ? font.pointSize * 1.2 / max(height, 1) : min(1, maxWidth / max(width, 1))
            width *= scale; height *= scale
            pictures.append((prepared.data, width, height))
            return NSAttributedString(string: RTFPictures.marker(pictures.count - 1), attributes: [.font: font])
        }

        static func colour(_ hex: String) -> NSColor? {
            let h = hex.replacingOccurrences(of: "#", with: "")
            guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
    }
}

private extension NSFont {
    func sized(_ size: CGFloat) -> NSFont { NSFont(descriptor: fontDescriptor, size: size) ?? self }
    var bold: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .boldFontMask) }
    var italic: NSFont { NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask) }
}
