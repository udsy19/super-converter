import AppKit
import Foundation
import SuperConverterCore

/// RTF, Word 97 `.doc` and `.dot` → `DocModel` through TextKit (formats §3.2 `TextKitImport`: the same importers as
/// `textutil`). TextKit gives attributed text; this turns it into blocks: paragraphs with their character styles, lists from
/// `NSTextList`, tables from `NSTextTableBlock`, pictures from attachments, headings inferred from large bold lines, code
/// from monospaced paragraphs. AppKit's text system is main-thread: call from the main actor.
@MainActor
enum TextKitImport {
    static func read(_ url: URL, format: FormatID) throws -> DocReadResult {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let type: NSAttributedString.DocumentType = format.rawValue == "rtf" ? .rtf : .docFormat
        var attributes: NSDictionary?
        let text: NSAttributedString
        // TextKit's RTF reader ignores `\pict`: pictures come out first and return as markers.
        let (source, pictures) = format.rawValue == "rtf" ? RTFPictures.extract(data) : (data, [])
        if type == .docFormat, !plausibleWord97(data) { throw ConversionError.damaged(format) }
        do {
            text = try NSAttributedString(data: source, options: [.documentType: type], documentAttributes: &attributes)
        } catch {
            throw ConversionError.damaged(format)
        }
        return convert(text, attributes: attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:], pictures: pictures)
    }

    /// AppKit's Word 97 importer trusts the file: a 25 KB `.doc` with a damaged compound-file directory made it allocate
    /// 9 GB in two seconds. So before it runs, the container and the File Information Block ([MS-DOC] 2.5.1) must hold
    /// together: a `WordDocument` stream with the Word signature, its table stream, the piece table (Clx) inside that, and
    /// no more text than the stream has bytes.
    static func plausibleWord97(_ data: Data) -> Bool {
        guard let file = CompoundFile(data), let word = file.stream("WordDocument"), word.count >= 0x200, word.u16(0) == 0xA5EC,
              let table = file.stream(word.u16(10) & 0x200 != 0 ? "1Table" : "0Table") else { return false }
        // FibBase (32 bytes), then the 16-bit and 32-bit value arrays, each after its count, then the (fc, lcb) pairs.
        let longs = 34 + Int(word.u16(32)) * 2
        let pairs = longs + 2 + Int(word.u16(longs)) * 4
        guard Int(word.u16(longs)) > 3, Int(word.u16(pairs)) > 33, pairs + 2 + 34 * 8 <= word.count else { return false }
        let ccpText = Int(Int32(bitPattern: word.u32(longs + 2 + 3 * 4)))
        let fcClx = Int(word.u32(pairs + 2 + 33 * 8)), lcbClx = Int(word.u32(pairs + 2 + 33 * 8 + 4))
        return (0...word.count).contains(ccpText) && lcbClx > 0 && fcClx <= table.count && lcbClx <= table.count - fcClx
    }

    static func convert(_ text: NSAttributedString, attributes: [NSAttributedString.DocumentAttributeKey: Any], pictures: [Data] = []) -> DocReadResult {
        var metadata = DocMetadata()
        if let title = attributes[.title] as? String, !title.isEmpty { metadata.title = title }
        if let author = attributes[.author] as? String, !author.isEmpty { metadata.authors = [author] }
        if let comment = attributes[.comment] as? String, !comment.isEmpty { metadata.summary = comment }
        if let date = attributes[.creationTime] as? Date { metadata.date = date }
        if let size = attributes[.paperSize] as? NSSize, size.width > 0, size.height > 0 { metadata.pageSize = VectorSize(width: size.width, height: size.height) }

        var converter = Converter(text: text, pictures: pictures)
        let blocks = converter.run()
        return DocReadResult(model: DocModel(metadata: metadata, blocks: blocks, resources: converter.resources))
    }

    private struct Converter {
        let text: NSAttributedString
        let pictures: [Data]
        var resources: [String: Data] = [:]
        let bodySize: Double

        init(text: NSAttributedString, pictures: [Data]) {
            self.text = text
            self.pictures = pictures
            // The most common font size, by characters.
            var counts: [Double: Int] = [:]
            text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
                if let f = value as? NSFont { counts[Double(f.pointSize).rounded(), default: 0] += range.length }
            }
            bodySize = counts.max { $0.value < $1.value }?.key ?? 12
        }

        mutating func run() -> [DocBlock] {
            let string = text.string as NSString
            var blocks: [DocBlock] = []
            var listEntries: [ListAssembler.Entry] = []
            var cells: [TableKey: [Int: [Int: (blocks: [DocBlock], colSpan: Int, rowSpan: Int)]]] = [:]
            var tableOrder: [TableKey] = []
            var codeLines: [String] = []
            var location = 0
            func flushList() { blocks += ListAssembler.assemble(listEntries); listEntries = [] }
            func flushCode() { if !codeLines.isEmpty { blocks.append(.code(language: nil, text: codeLines.joined(separator: "\n"))); codeLines = [] } }
            func flushTables() {
                for key in tableOrder {
                    guard let rows = cells[key] else { continue }
                    let table = DocTable(rows: rows.sorted { $0.key < $1.key }.map { _, row in
                        row.sorted { $0.key < $1.key }.map { DocTable.Cell(blocks: $0.value.blocks, columnSpan: $0.value.colSpan, rowSpan: $0.value.rowSpan, isHeader: false) }
                    })
                    blocks.append(.table(table))
                }
                cells = [:]; tableOrder = []
            }
            var currentTable: TableKey?
            while location < string.length {
                let range = string.paragraphRange(for: NSRange(location: location, length: 0))
                location = NSMaxRange(range)
                let paragraph = text.attributedSubstring(from: range)
                let style = paragraph.length > 0 ? paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil

                // Table cell paragraph.
                if let block = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last {
                    flushList(); flushCode()
                    let key = TableKey(ObjectIdentifier(block.table))
                    if currentTable != key { if currentTable != nil { flushTables() }; currentTable = key }
                    if cells[key] == nil { cells[key] = [:]; tableOrder.append(key) }
                    let inline = inlines(paragraph)
                    var entry = cells[key]![block.startingRow]?[block.startingColumn] ?? ([], block.columnSpan, block.rowSpan)
                    if !(inline.isEmpty && !entry.blocks.isEmpty) { entry.blocks.append(.paragraph(inline, paragraphStyle(style))) }
                    cells[key]![block.startingRow, default: [:]][block.startingColumn] = entry
                    continue
                }
                if currentTable != nil { flushTables(); currentTable = nil }

                // Form feed: a page break.
                if paragraph.string.contains("\u{0C}") {
                    flushList(); flushCode()
                    blocks.append(.pageBreak)
                    if paragraph.string.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0C}"))).isEmpty { continue }
                }

                // List item.
                if let list = style?.textLists.last {
                    flushCode()
                    var inline = inlines(paragraph, dropMarker: list)
                    inline = trimmed(inline)
                    let format = list.markerFormat.rawValue
                    let ordered = format.contains("decimal") || format.contains("alpha") || format.contains("roman") || format.contains("Alpha") || format.contains("Roman")
                    listEntries.append(ListAssembler.Entry(level: (style?.textLists.count ?? 1) - 1, ordered: ordered, start: ListAssembler.start(list.startingItemNumber),
                                                           blocks: [.paragraph(inline, paragraphStyle(style))], listID: "\(ObjectIdentifier(style!.textLists.first!).hashValue)"))
                    continue
                }
                flushList()

                var inline = trimmed(inlines(paragraph))
                if inline.isEmpty {
                    flushCode()
                    if paragraph.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, paragraph.length > 1 || !blocks.isEmpty { /* blank line */ }
                    continue
                }
                // Monospaced throughout: code.
                let flat = Inlines.flatten(inline)
                if flat.allSatisfy({ if case .run(_, let f) = $0 { f.code } else { false } }) {
                    codeLines.append(Inlines.plain(inline))
                    continue
                }
                flushCode()
                if let level = headingLevel(paragraph, inline) {
                    // Headings carry no inline bold of their own.
                    inline = Inlines.build(flat.map { if case .run(let t, var f) = $0 { f.bold = false; return .run(t, f) }; return $0 })
                    blocks.append(.heading(level: level, inline))
                    continue
                }
                if inline.count == 1, case .image(let r, let a) = inline[0] { blocks.append(.figure(resource: r, caption: nil, altText: a)); continue }
                blocks.append(.paragraph(inline, paragraphStyle(style)))
            }
            flushList(); flushCode(); flushTables()
            return blocks
        }

        struct TableKey: Hashable { let id: ObjectIdentifier; init(_ id: ObjectIdentifier) { self.id = id } }

        func paragraphStyle(_ style: NSParagraphStyle?) -> DocParagraphStyle {
            var s = DocParagraphStyle()
            switch style?.alignment {
            case .center: s.alignment = .centre
            case .right: s.alignment = .end
            case .justified: s.alignment = .justified
            default: break
            }
            if let b = style?.paragraphSpacingBefore, b > 0 { s.spaceBefore = Double(b) }
            if let a = style?.paragraphSpacing, a > 0 { s.spaceAfter = Double(a) }
            return s
        }

        func trimmed(_ text: DocText) -> DocText {
            var builder = InlineBuilder()
            for item in Inlines.flatten(text) { builder.add(item) }
            builder.trim(leading: true)
            return builder.build()
        }

        /// Large bold single-line paragraphs are headings (RTF has no heading styles; Word's become big bold runs).
        func headingLevel(_ paragraph: NSAttributedString, _ inline: DocText) -> Int? {
            guard paragraph.length > 0, paragraph.length < 200, !paragraph.string.dropLast().contains("\n") else { return nil }
            var allBold = true
            var maxSize = 0.0
            paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) { value, range, _ in
                guard let f = value as? NSFont else { return }
                let text = paragraph.attributedSubstring(from: range).string
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                if !f.fontDescriptor.symbolicTraits.contains(.bold) { allBold = false }
                maxSize = max(maxSize, Double(f.pointSize))
            }
            guard allBold, maxSize >= bodySize * 1.15 else { return nil }
            switch maxSize / bodySize {
            case 1.8...: return 1
            case 1.5...: return 2
            case 1.3...: return 3
            default: return 4
            }
        }

        mutating func inlines(_ paragraph: NSAttributedString, dropMarker list: NSTextList? = nil) -> DocText {
            var builder = InlineBuilder()
            var skip = 0
            if let list {
                // The marker is part of the text: "\t•\t" or "\t1.\t".
                let s = paragraph.string
                if s.hasPrefix("\t") || list.markerFormat.rawValue.isEmpty == false {
                    let parts = s.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
                    if parts.count == 3, parts[0].isEmpty { skip = (parts[0].count + parts[1].count + 2) }
                }
            }
            paragraph.enumerateAttributes(in: NSRange(location: skip, length: max(paragraph.length - skip, 0))) { attributes, range, _ in
                let piece = paragraph.attributedSubstring(from: range).string
                var f = RunFormat()
                if let font = attributes[.font] as? NSFont {
                    let traits = font.fontDescriptor.symbolicTraits
                    f.bold = traits.contains(.bold)
                    f.italic = traits.contains(.italic)
                    let family = font.familyName ?? font.fontName
                    if traits.contains(.monoSpace) || DOCXReader.monospaceFonts.contains(family.lowercased()) { f.code = true }
                    else if !Self.systemFamilies.contains(family) { f.font = family }
                    if abs(Double(font.pointSize) - bodySize) > 0.5 { f.size = Double(font.pointSize) }
                }
                if let u = attributes[.underlineStyle] as? Int, u != 0 { f.underline = true }
                if let s = attributes[.strikethroughStyle] as? Int, s != 0 { f.strike = true }
                if let sup = attributes[.superscript] as? Int { f.superscript = sup > 0; f.subscripted = sup < 0 }
                if let colour = attributes[.foregroundColor] as? NSColor, let rgb = colour.usingColorSpace(.sRGB) {
                    let hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                    if hex != "#000000" { f.colour = hex }
                }
                if let link = attributes[.link] { f.link = (link as? URL)?.absoluteString ?? (link as? String) }
                if let attachment = attributes[.attachment] as? NSTextAttachment {
                    if let data = attachment.fileWrapper?.regularFileContents ?? attachment.contents ?? attachment.image.flatMap({ Self.png($0) }) {
                        let ext = ImageSniff.commonType(data).map { $0 == "jpeg" ? "jpg" : $0 } ?? "png"
                        let key = "image\(resources.count + 1).\(ext)"
                        resources[key] = data
                        builder.add(.image(resource: key, alt: nil, link: f.link))
                    }
                    return
                }
                let cleaned = piece.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{0C}", with: "").replacingOccurrences(of: "\u{FFFC}", with: "")
                // Picture markers (RTFPictures) split the text.
                var rest = cleaned[...]
                while let match = RTFPictures.markerPattern.firstMatch(in: String(rest), range: NSRange(rest.startIndex..., in: rest)), let whole = Range(match.range, in: rest),
                      let numberRange = Range(match.range(at: 1), in: rest), let index = Int(rest[numberRange]), index < pictures.count {
                    addText(String(rest[..<whole.lowerBound]), f, &builder)
                    let data = pictures[index]
                    let key = "image\(resources.count + 1)." + (ImageSniff.commonType(data) == "jpeg" ? "jpg" : "png")
                    resources[key] = data
                    builder.add(.image(resource: key, alt: nil, link: f.link))
                    rest = rest[whole.upperBound...]
                }
                addText(String(rest), f, &builder)
            }
            return builder.build()
        }

        func addText(_ text: String, _ f: RunFormat, _ builder: inout InlineBuilder) {
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if i > 0 { builder.add(.lineBreak) }
                builder.add(String(line), f)
            }
        }

        static let systemFamilies: Set<String> = ["Helvetica", "Helvetica Neue", "Times", "Times New Roman", "Arial", "Calibri", ".AppleSystemUIFont", "System Font", "Times-Roman"]

        static func png(_ image: NSImage) -> Data? {
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }
    }
}
