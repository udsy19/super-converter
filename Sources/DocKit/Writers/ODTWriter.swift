import Foundation
import SuperConverterCore

/// `DocModel` → ODT (formats §3.2 `ODTWriter`): OpenDocument 1.3 text with named styles for headings, quotations and source
/// code, automatic styles for the formatting of each run, real lists, tables with header rows and spans, inline notes,
/// pictures in `Pictures/`, and formulas as embedded MathML objects (with the TeX alongside).
enum ODTWriter {
    static func write(_ model: DocModel, to url: URL) throws -> [LossNote] {
        var builder = Builder(model)
        let data = builder.build()
        try data.write(to: url, options: .atomic)
        return builder.lossNotes
    }

    static func data(_ model: DocModel) -> (data: Data, lossNotes: [LossNote]) {
        var builder = Builder(model)
        return (builder.build(), builder.lossNotes)
    }

    private static let namespaces = """
        xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" \
        xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" \
        xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" xmlns:math="http://www.w3.org/1998/Math/MathML" \
        xmlns:loext="urn:org:documentfoundation:names:experimental:office:xmlns:loext:1.0" office:version="1.3"
        """

    private struct Builder {
        let model: DocModel
        var lossNotes: [LossNote] = []
        var textStyles: [RunFormat: String] = [:]
        var textStyleOrder: [RunFormat] = []
        var paragraphStyles: [String: String] = [:]   // properties → name
        var paragraphStyleOrder: [(String, String)] = []
        var listStyles: [(name: String, ordered: Bool, start: Int)] = []
        var pictures: [(path: String, data: Data, type: String)] = []
        var pictureNames: [String: (path: String, width: Double, height: Double)] = [:]
        var objects: [String] = []   // MathML documents
        var footnoteBodies: [String: [DocBlock]] = [:]
        var noteCount = 0
        var tableCount = 0
        var frameCount = 0
        var textWidth = 0.0

        init(_ model: DocModel) {
            self.model = model
            for case .footnote(let id, let blocks) in model.blocks { footnoteBodies[id] = blocks }
        }

        mutating func build() -> Data {
            let paper = model.metadata.pageSize.map { (width: $0.width, height: $0.height) } ?? PaperSize.regional
            textWidth = paper.width - 144
            var body = ""
            let m = model.metadata
            if let title = m.title { body += "<text:p text:style-name=\"Title\">\(XML.escape(title))</text:p>" }
            if !m.authors.isEmpty { body += "<text:p text:style-name=\"Author\">\(XML.escape(m.authors.joined(separator: "; ")))</text:p>" }
            if let date = m.date { body += "<text:p text:style-name=\"Date\">\(XML.escape(DocDates.string(date)))</text:p>" }
            if let summary = m.summary { body += "<text:p text:style-name=\"Abstract\">\(XML.escape(summary))</text:p>" }
            for block in model.blocks { body += self.block(block, depth: 0) }

            var automatic = ""
            for format in textStyleOrder { automatic += textStyleXML(format) }
            for (_, xml) in paragraphStyleOrder { automatic += xml }
            for list in listStyles { automatic += listStyleXML(list) }
            automatic += """
                <style:style style:name="Tbl" style:family="table"><style:table-properties style:width="\(pt(textWidth))" table:align="margins"/></style:style>\
                <style:style style:name="TC" style:family="table-cell"><style:table-cell-properties fo:padding="0.05in" fo:border="0.5pt solid #000000"/></style:style>\
                <style:style style:name="Fr" style:family="graphic"><style:graphic-properties style:wrap="none" text:anchor-type="as-char" style:vertical-pos="top" style:vertical-rel="baseline"/></style:style>
                """
            let content = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-content \(ODTWriter.namespaces)>"
                + "<office:automatic-styles>\(automatic)</office:automatic-styles><office:body><office:text>\(body)</office:text></office:body></office:document-content>"

            var zip = ZipWriter()
            zip.add("mimetype", "application/vnd.oasis.opendocument.text", compress: false)
            zip.add("content.xml", content)
            zip.add("styles.xml", Self.stylesXML(paper, language: m.language))
            zip.add("meta.xml", metaXML())
            for picture in pictures { zip.add(picture.path, picture.data, compress: false) }
            for (i, math) in objects.enumerated() { zip.add("Object \(i + 1)/content.xml", math) }
            zip.add("META-INF/manifest.xml", manifestXML())
            lossNotes = LossNote.merged(lossNotes)
            return zip.finish()
        }

        func pt(_ v: Double) -> String { String(format: "%.2fpt", v) }

        func metaXML() -> String {
            let m = model.metadata
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-meta \(ODTWriter.namespaces)><office:meta>"
            xml += "<meta:generator>Super Converter</meta:generator>"
            if let t = m.title { xml += "<dc:title>\(XML.escape(t))</dc:title>" }
            if let s = m.summary { xml += "<dc:description>\(XML.escape(s))</dc:description>" }
            if !m.authors.isEmpty { xml += "<meta:initial-creator>\(XML.escape(m.authors.joined(separator: "; ")))</meta:initial-creator>" }
            if let l = m.language { xml += "<dc:language>\(XML.escape(l))</dc:language>" }
            if let d = m.date { xml += "<meta:creation-date>\(ISO8601DateFormatter().string(from: d))</meta:creation-date>" }
            return xml + "</office:meta></office:document-meta>"
        }

        func manifestXML() -> String {
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.3\">"
            xml += "<manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/>"
            for part in ["content.xml", "styles.xml", "meta.xml"] {
                xml += "<manifest:file-entry manifest:full-path=\"\(part)\" manifest:media-type=\"text/xml\"/>"
            }
            for p in pictures { xml += "<manifest:file-entry manifest:full-path=\"\(p.path)\" manifest:media-type=\"\(ImageSniff.mime(p.type))\"/>" }
            for i in 1...max(objects.count, 1) where i <= objects.count {
                xml += "<manifest:file-entry manifest:full-path=\"Object \(i)/\" manifest:media-type=\"application/vnd.oasis.opendocument.formula\"/>"
                xml += "<manifest:file-entry manifest:full-path=\"Object \(i)/content.xml\" manifest:media-type=\"text/xml\"/>"
            }
            return xml + "</manifest:manifest>"
        }

        // MARK: Styles

        mutating func textStyle(_ f: RunFormat) -> String? {
            var key = f
            key.link = nil
            if key == RunFormat() { return nil }
            if let name = textStyles[key] { return name }
            let name = "T\(textStyles.count + 1)"
            textStyles[key] = name
            textStyleOrder.append(key)
            return name
        }

        func textStyleXML(_ f: RunFormat) -> String {
            var p = ""
            if f.bold { p += " fo:font-weight=\"bold\"" }
            if f.italic { p += " fo:font-style=\"italic\"" }
            if f.strike { p += " style:text-line-through-style=\"solid\"" }
            if f.underline { p += " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"" }
            if f.superscript { p += " style:text-position=\"super 58%\"" } else if f.subscripted { p += " style:text-position=\"sub 58%\"" }
            if f.code { p += " style:font-name=\"Courier New\" fo:font-family=\"'Courier New'\"" }
            else if let font = f.font { p += " style:font-name=\"\(XML.escape(font))\" fo:font-family=\"\(XML.escape(font))\"" }
            if let size = f.size { p += " fo:font-size=\"\(size)pt\"" }
            if let colour = f.colour { p += " fo:color=\"\(colour)\"" }
            return "<style:style style:name=\"\(textStyles[f.withoutLink]!)\" style:family=\"text\"><style:text-properties\(p)/></style:style>"
        }

        mutating func paragraphStyle(_ s: DocParagraphStyle, parent: String) -> String {
            var props = ""
            switch s.alignment {
            case .start: break
            case .centre: props += " fo:text-align=\"center\""
            case .end: props += " fo:text-align=\"end\""
            case .justified: props += " fo:text-align=\"justify\""
            }
            if let b = s.spaceBefore { props += " fo:margin-top=\"\(b)pt\"" }
            if let a = s.spaceAfter { props += " fo:margin-bottom=\"\(a)pt\"" }
            if props.isEmpty { return parent }
            let key = parent + "|" + props
            if let name = paragraphStyles[key] { return name }
            let name = "P\(paragraphStyles.count + 1)"
            paragraphStyles[key] = name
            paragraphStyleOrder.append((key, "<style:style style:name=\"\(name)\" style:family=\"paragraph\" style:parent-style-name=\"\(parent)\"><style:paragraph-properties\(props)/></style:style>"))
            return name
        }

        func listStyleXML(_ list: (name: String, ordered: Bool, start: Int)) -> String {
            var xml = "<text:list-style style:name=\"\(list.name)\">"
            for level in 1...10 {
                let indent = 0.25 * Double(level)
                let props = "<style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\"><style:list-level-label-alignment text:label-followed-by=\"listtab\" text:list-tab-stop-position=\"\(indent + 0.25)in\" fo:text-indent=\"-0.25in\" fo:margin-left=\"\(indent + 0.25)in\"/></style:list-level-properties>"
                if list.ordered {
                    let format = ["1", "a", "i"][(level - 1) % 3]
                    xml += "<text:list-level-style-number text:level=\"\(level)\" style:num-suffix=\".\" style:num-format=\"\(format)\" text:start-value=\"\(level == 1 ? list.start : 1)\">\(props)</text:list-level-style-number>"
                } else {
                    let bullet = ["•", "◦", "▪"][(level - 1) % 3]
                    xml += "<text:list-level-style-bullet text:level=\"\(level)\" text:bullet-char=\"\(bullet)\">\(props)</text:list-level-style-bullet>"
                }
            }
            return xml + "</text:list-style>"
        }

        static func stylesXML(_ paper: (width: Double, height: Double), language: String?) -> String {
            func named(_ name: String, display: String, parent: String? = "Standard", next: String? = nil, para: String = "", text: String = "", outline: Int? = nil) -> String {
                "<style:style style:name=\"\(name)\" style:display-name=\"\(display)\" style:family=\"paragraph\"\(parent.map { " style:parent-style-name=\"\($0)\"" } ?? "")\(next.map { " style:next-style-name=\"\($0)\"" } ?? "")\(outline.map { " style:default-outline-level=\"\($0)\"" } ?? "")>"
                    + (para.isEmpty ? "" : "<style:paragraph-properties \(para)/>") + (text.isEmpty ? "" : "<style:text-properties \(text)/>") + "</style:style>"
            }
            var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<office:document-styles \(ODTWriter.namespaces)>"
            xml += "<office:styles><style:default-style style:family=\"paragraph\"><style:paragraph-properties fo:margin-bottom=\"0.1in\" fo:line-height=\"115%\"/>"
            xml += "<style:text-properties style:font-name=\"Calibri\" fo:font-family=\"Calibri\" fo:font-size=\"11pt\"\(language.map { " fo:language=\"\(XML.escape($0.split(separator: "-").first.map(String.init) ?? $0))\"" } ?? "")/></style:default-style>"
            xml += "<style:style style:name=\"Standard\" style:family=\"paragraph\" style:class=\"text\"/>"
            let sizes = [20, 16, 14, 12, 11, 11]
            for (i, size) in sizes.enumerated() {
                xml += named("Heading_20_\(i + 1)", display: "Heading \(i + 1)", next: "Standard", para: "fo:margin-top=\"\(i == 0 ? 0.25 : 0.17)in\" fo:margin-bottom=\"0.06in\" fo:keep-with-next=\"always\"", text: "fo:font-size=\"\(size)pt\" fo:font-weight=\"bold\"", outline: i + 1)
            }
            xml += named("Title", display: "Title", text: "fo:font-size=\"28pt\"")
            xml += named("Author", display: "Author", para: "fo:text-align=\"center\"")
            xml += named("Date", display: "Date", para: "fo:text-align=\"center\"")
            xml += named("Abstract", display: "Abstract", para: "fo:margin-left=\"0.5in\" fo:margin-right=\"0.5in\"")
            xml += named("Caption", display: "Caption", text: "fo:font-size=\"9pt\" fo:font-style=\"italic\"")
            xml += named("Quotations", display: "Quotations", para: "fo:margin-left=\"0.5in\" fo:margin-right=\"0.5in\"", text: "fo:font-style=\"italic\"")
            xml += named("Preformatted_20_Text", display: "Preformatted Text", para: "fo:margin-top=\"0in\" fo:margin-bottom=\"0in\" fo:margin-left=\"0.25in\"", text: "style:font-name=\"Courier New\" fo:font-family=\"'Courier New'\" fo:font-size=\"10pt\"")
            xml += named("Footnote", display: "Footnote", para: "fo:margin-bottom=\"0in\"", text: "fo:font-size=\"10pt\"")
            xml += named("Formula", display: "Formula", para: "fo:text-align=\"center\"")
            xml += named("Figure", display: "Figure", para: "fo:text-align=\"center\" fo:keep-with-next=\"always\"")
            xml += named("Horizontal_20_Line", display: "Horizontal Line", para: "fo:margin-top=\"0in\" fo:margin-bottom=\"0.1in\" fo:border-bottom=\"0.5pt solid #808080\" fo:padding=\"0in\"")
            xml += named("List_20_Paragraph", display: "List Paragraph", para: "fo:margin-bottom=\"0.03in\"")
            xml += "<style:style style:name=\"PageBreak\" style:family=\"paragraph\" style:parent-style-name=\"Standard\"><style:paragraph-properties fo:break-before=\"page\"/></style:style>"
            xml += "<style:style style:name=\"Internet_20_link\" style:display-name=\"Internet link\" style:family=\"text\"><style:text-properties fo:color=\"#0563C1\" style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"/></style:style>"
            xml += "</office:styles><office:automatic-styles>"
            xml += "<style:page-layout style:name=\"pm1\"><style:page-layout-properties fo:page-width=\"\(String(format: "%.2f", paper.width))pt\" fo:page-height=\"\(String(format: "%.2f", paper.height))pt\" "
            xml += "fo:margin-top=\"1in\" fo:margin-bottom=\"1in\" fo:margin-left=\"1in\" fo:margin-right=\"1in\" style:print-orientation=\"\(paper.width > paper.height ? "landscape" : "portrait")\"/></style:page-layout>"
            xml += "</office:automatic-styles><office:master-styles><style:master-page style:name=\"Standard\" style:page-layout-name=\"pm1\"/></office:master-styles></office:document-styles>"
            return xml
        }

        // MARK: Blocks

        mutating func block(_ block: DocBlock, depth: Int, quoted: Bool = false, noteStyle: Bool = false) -> String {
            switch block {
            case .heading(let level, let text):
                let n = min(max(level, 1), 6)
                return "<text:h text:style-name=\"Heading_20_\(n)\" text:outline-level=\"\(n)\">\(inlines(text))</text:h>"
            case .paragraph(let text, let style):
                let parent = quoted ? "Quotations" : noteStyle ? "Footnote" : "Standard"
                return "<text:p text:style-name=\"\(paragraphStyle(style, parent: parent))\">\(inlines(text))</text:p>"
            case .list(let ordered, let start, let items): return list(ordered: ordered, start: start, items: items, depth: depth)
            case .table(let table): return self.table(table)
            case .figure(let resource, let caption, let alt):
                var out = "<text:p text:style-name=\"Figure\">\(picture(resource, alt: alt))</text:p>"
                if let caption { out += "<text:p text:style-name=\"Caption\">\(inlines(caption))</text:p>" }
                return out
            case .code(_, let text):
                return text.normalisedNewlines.split(separator: "\n", omittingEmptySubsequences: false).map {
                    "<text:p text:style-name=\"Preformatted_20_Text\">\(Self.spaced(String($0)))</text:p>"
                }.joined()
            case .quote(let blocks):
                var out = ""
                for inner in blocks { out += self.block(inner, depth: depth, quoted: true) }
                return out
            case .math(let tex, _):
                return "<text:p text:style-name=\"Formula\">\(formula(tex))</text:p>"
            case .footnote: return ""
            case .thematicBreak: return "<text:p text:style-name=\"Horizontal_20_Line\"/>"
            case .pageBreak: return "<text:p text:style-name=\"PageBreak\"/>"
            }
        }

        /// Text with ODF's whitespace rules: runs of spaces as `text:s`, tabs and line breaks as elements.
        static func spaced(_ text: String) -> String {
            var out = ""
            var spaces = 0
            func flushSpaces() {
                if spaces > 0 { out += spaces == 1 ? " " : " <text:s text:c=\"\(spaces - 1)\"/>"; spaces = 0 }
            }
            for ch in text {
                switch ch {
                case " ": spaces += 1
                case "\t": flushSpaces(); out += "<text:tab/>"
                case "\n": flushSpaces(); out += "<text:line-break/>"
                default: flushSpaces(); out += XML.escape(String(ch))
                }
            }
            flushSpaces()
            return out
        }

        mutating func inlines(_ text: DocText) -> String {
            var out = ""
            var open: String?
            var body = ""
            func close(_ out: inout String) {
                guard let link = open else { return }
                out += "<text:a xlink:type=\"simple\" xlink:href=\"\(XML.escape(link))\" text:style-name=\"Internet_20_link\" text:visited-style-name=\"Internet_20_link\">\(body)</text:a>"
                open = nil; body = ""
            }
            for item in Inlines.flatten(text) {
                var chunk = ""
                var link: String?
                switch item {
                case .run(let t, let f):
                    link = f.link
                    chunk = Self.spaced(t)
                    if let style = textStyle(f) { chunk = "<text:span text:style-name=\"\(style)\">\(chunk)</text:span>" }
                case .image(let resource, let alt, let l): link = l; chunk = picture(resource, alt: alt)
                case .footnote(let id): chunk = note(id)
                case .math(let tex): chunk = formula(tex)
                case .lineBreak: chunk = "<text:line-break/>"
                }
                if link != open { close(&out); open = link }
                if open != nil { body += chunk } else { out += chunk }
            }
            close(&out)
            return out
        }

        mutating func note(_ id: String) -> String {
            noteCount += 1
            var body = ""
            for block in footnoteBodies[id] ?? [] { body += self.block(block, depth: 0, noteStyle: true) }
            if body.isEmpty { body = "<text:p text:style-name=\"Footnote\"/>" }
            return "<text:note text:id=\"ftn\(noteCount)\" text:note-class=\"footnote\"><text:note-citation>\(noteCount)</text:note-citation><text:note-body>\(body)</text:note-body></text:note>"
        }

        mutating func formula(_ tex: String) -> String {
            let mathml = MathML.write(tex: tex, display: false).replacingOccurrences(of: "<math ", with: "<math ")
            objects.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + mathml)
            frameCount += 1
            return "<draw:frame draw:style-name=\"Fr\" draw:name=\"Formula\(frameCount)\" text:anchor-type=\"as-char\" svg:width=\"1in\" svg:height=\"0.3in\"><draw:object xlink:href=\"./Object \(objects.count)\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/></draw:frame>"
        }

        mutating func picture(_ resource: String, alt: String?) -> String {
            var info = pictureNames[resource]
            if info == nil {
                guard let data = model.resources[resource], let prepared = ImageSniff.prepare(data) else {
                    lossNotes.append(LossNote(.imagesDropped, detail: resource))
                    return alt.map { XML.escape($0) } ?? ""
                }
                let ext = prepared.type == "jpeg" ? "jpg" : prepared.type
                let path = "Pictures/image\(pictures.count + 1).\(ext)"
                pictures.append((path, prepared.data, prepared.type))
                var w = Double(prepared.pixelWidth) / prepared.dpi * 72, h = Double(prepared.pixelHeight) / prepared.dpi * 72
                let scale = min(1, textWidth / max(w, 1), 600 / max(h, 1))
                w *= scale; h *= scale
                info = (path, w, h)
                pictureNames[resource] = info
            }
            guard let info else { return "" }
            frameCount += 1
            return "<draw:frame draw:style-name=\"Fr\" draw:name=\"Image\(frameCount)\" text:anchor-type=\"as-char\" svg:width=\"\(pt(info.width))\" svg:height=\"\(pt(info.height))\">"
                + "<draw:image xlink:href=\"\(info.path)\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/>"
                + (alt.map { "<svg:desc>\(XML.escape($0))</svg:desc>" } ?? "") + "</draw:frame>"
        }

        // MARK: Lists

        mutating func list(ordered: Bool, start: Int, items: [[DocBlock]], depth: Int) -> String {
            let name = "L\(listStyles.count + 1)"
            listStyles.append((name, ordered, start))
            var out = "<text:list text:style-name=\"\(name)\">"
            for item in items {
                out += "<text:list-item>"
                var any = false
                for block in item {
                    switch block {
                    case .list(let o, let s, let nested): out += list(ordered: o, start: s, items: nested, depth: depth + 1)
                    case .paragraph(let text, let style):
                        out += "<text:p text:style-name=\"\(paragraphStyle(style, parent: "List_20_Paragraph"))\">\(inlines(text))</text:p>"
                    default: out += self.block(block, depth: depth + 1)
                    }
                    any = true
                }
                if !any { out += "<text:p text:style-name=\"List_20_Paragraph\"/>" }
                out += "</text:list-item>"
            }
            return out + "</text:list>"
        }

        // MARK: Tables

        mutating func table(_ table: DocTable) -> String {
            tableCount += 1
            let (columns, rows) = TableGrid.expand(table)
            var out = ""
            if let caption = table.caption { out += "<text:p text:style-name=\"Caption\">\(inlines(caption))</text:p>" }
            out += "<table:table table:name=\"Table\(tableCount)\" table:style-name=\"Tbl\"><table:table-column table:number-columns-repeated=\"\(columns)\"/>"
            var inHeader = false
            for (rowIndex, row) in rows.enumerated() {
                let source = table.rows[rowIndex]
                let isHeader = !source.isEmpty && source.allSatisfy(\.isHeader)
                if isHeader && !inHeader { out += "<table:table-header-rows>"; inHeader = true }
                if !isHeader && inHeader { out += "</table:table-header-rows>"; inHeader = false }
                out += "<table:table-row>"
                for (column, slot) in row.enumerated() {
                    switch slot.covered {
                    case .above, .left: out += "<table:covered-table-cell/>"; continue
                    case .missing: out += "<table:table-cell table:style-name=\"TC\" office:value-type=\"string\"><text:p/></table:table-cell>"; continue
                    case .none: break
                    }
                    guard let cell = slot.cell else { continue }
                    var attrs = "table:style-name=\"TC\" office:value-type=\"string\""
                    if cell.columnSpan > 1, columns - column > 1 { attrs += " table:number-columns-spanned=\"\(min(cell.columnSpan, columns - column))\"" }
                    if cell.rowSpan > 1 { attrs += " table:number-rows-spanned=\"\(cell.rowSpan)\"" }
                    let alignment = column < table.alignments.count ? table.alignments[column] : .start
                    var content = ""
                    for block in cell.blocks {
                        if case .paragraph(let text, var style) = block {
                            if style.alignment == .start { style.alignment = alignment }
                            content += "<text:p text:style-name=\"\(paragraphStyle(style, parent: "Standard"))\">\(inlines(text))</text:p>"
                        } else {
                            content += self.block(block, depth: 0)
                        }
                    }
                    if content.isEmpty { content = "<text:p/>" }
                    out += "<table:table-cell \(attrs)>\(content)</table:table-cell>"
                }
                out += "</table:table-row>"
            }
            if inHeader { out += "</table:table-header-rows>" }
            return out + "</table:table>"
        }
    }
}

private extension RunFormat {
    var withoutLink: RunFormat { var copy = self; copy.link = nil; return copy }
}
