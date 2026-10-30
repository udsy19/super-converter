import Foundation
import SuperConverterCore

/// `DocModel` → DOCX (formats §3.2 `DOCXWriter`; the OPC package comes from Super PDF's Word writer). Real paragraph styles
/// (Heading 1–6, Title, Caption, Quote, Source Code), real Word lists, tables with header rows and merged cells, inline
/// pictures, footnotes, hyperlinks and OMML math. Output is deterministic.
enum DOCXWriter {
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

    private struct Builder {
        let model: DocModel
        var lossNotes: [LossNote] = []
        var relationships: [OPCRelationship] = []
        var media: [(path: String, data: Data)] = []
        var imageIDs: [String: (rId: String, width: Int, height: Int, dpi: Double)] = [:]   // resource → relationship
        var footnoteIDs: [String: Int] = [:]
        var footnoteBodies: [String: [DocBlock]] = [:]
        var numbers: [(ordered: Bool, start: Int)] = []   // numId - 2 → ordered list info (numId 1 is the bullet list)
        var drawingID = 1
        var nextRel = 10
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
            if let title = m.title { body += styled("Title", text: title) }
            if !m.authors.isEmpty { body += styled("Author", text: m.authors.joined(separator: "; ")) }
            if let date = m.date { body += styled("Date", text: DocDates.string(date)) }
            if let summary = m.summary { body += styled("Abstract", text: summary) }
            for block in model.blocks { body += self.block(block, listDepth: 0) }
            body += """
                <w:sectPr><w:footnotePr><w:numFmt w:val="decimal"/></w:footnotePr><w:pgSz w:w="\(Int(measure: paper.width * 20))" w:h="\(Int(measure: paper.height * 20))"/>\
                <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
                """

            let namespaces = """
                xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
                xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
                xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math" \
                xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
                xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
                xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
                """
            var package = OPCPackage()
            package.add("word/document.xml", xml: "<w:document \(namespaces)><w:body>\(body)</w:body></w:document>",
                        contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml")
            package.add("word/styles.xml", xml: Self.styles(model.metadata.language),
                        contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml")
            package.add("word/numbering.xml", xml: numberingXML(),
                        contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml")
            package.add("word/settings.xml", xml: """
                <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:footnotePr><w:footnote w:id="-1"/><w:footnote w:id="0"/></w:footnotePr></w:settings>
                """, contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml")
            relationships += [
                OPCRelationship(id: "rId1", type: OPCRelationship.styles, target: "styles.xml"),
                OPCRelationship(id: "rId2", type: OPCRelationship.numbering, target: "numbering.xml"),
                OPCRelationship(id: "rId3", type: OPCRelationship.settings, target: "settings.xml"),
            ]
            if !footnoteIDs.isEmpty {
                package.add("word/footnotes.xml", xml: footnotesXML(namespaces),
                            contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml")
                relationships.append(OPCRelationship(id: "rId4", type: OPCRelationship.footnotes, target: "footnotes.xml"))
            }
            package.addRelationships("word/_rels/document.xml.rels", relationships)
            for item in media { package.add(item.path, media: item.data) }
            package.addProperties(model.metadata, mainPart: "word/document.xml", application: "Super Converter")
            lossNotes = LossNote.merged(lossNotes)
            return package.finish()
        }

        // MARK: Blocks

        func styled(_ style: String, text: String) -> String {
            "<w:p><w:pPr><w:pStyle w:val=\"\(style)\"/></w:pPr><w:r><w:t xml:space=\"preserve\">\(XML.escape(text))</w:t></w:r></w:p>"
        }

        mutating func block(_ block: DocBlock, listDepth: Int, style: String? = nil, quoted: Bool = false) -> String {
            switch block {
            case .heading(let level, let text):
                return paragraph(text, style: "Heading\(min(max(level, 1), 6))", paragraphStyle: DocParagraphStyle())
            case .paragraph(let text, let pStyle):
                return paragraph(text, style: quoted ? "Quote" : style, paragraphStyle: pStyle)
            case .list(let ordered, let start, let items):
                return list(ordered: ordered, start: start, items: items, depth: listDepth)
            case .table(let table): return self.table(table)
            case .figure(let resource, let caption, let alt):
                var out = "<w:p><w:pPr><w:keepNext/><w:jc w:val=\"center\"/></w:pPr>\(drawing(resource, alt: alt, link: nil))</w:p>"
                if let caption { out += paragraph(caption, style: "Caption", paragraphStyle: DocParagraphStyle()) }
                return out
            case .code(_, let text):
                return text.normalisedNewlines.split(separator: "\n", omittingEmptySubsequences: false).map { line in
                    "<w:p><w:pPr><w:pStyle w:val=\"SourceCode\"/></w:pPr><w:r><w:rPr><w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/></w:rPr>\(Self.textRun(String(line)))</w:r></w:p>"
                }.joined()
            case .quote(let blocks):
                var out = ""
                for inner in blocks { out += self.block(inner, listDepth: listDepth, quoted: true) }
                return out
            case .math(let tex, _):
                return "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr><m:oMathPara><m:oMath>\(OMML.write(tex: tex))</m:oMath></m:oMathPara></w:p>"
            case .footnote: return ""
            case .thematicBreak:
                return "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"808080\"/></w:pBdr></w:pPr></w:p>"
            case .pageBreak:
                return "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }
        }

        static func textRun(_ text: String) -> String {
            var out = ""
            var current = ""
            func flush() { if !current.isEmpty { out += "<w:t xml:space=\"preserve\">\(XML.escape(current))</w:t>"; current = "" } }
            for ch in text {
                if ch == "\t" { flush(); out += "<w:tab/>" } else if ch == "\n" { flush(); out += "<w:br/>" } else { current.append(ch) }
            }
            flush()
            return out
        }

        mutating func paragraph(_ text: DocText, style: String?, paragraphStyle: DocParagraphStyle, numbering: (id: Int, level: Int)? = nil) -> String {
            var pPr = ""
            if let style { pPr += "<w:pStyle w:val=\"\(style)\"/>" }
            if let numbering { pPr += "<w:numPr><w:ilvl w:val=\"\(numbering.level)\"/><w:numId w:val=\"\(numbering.id)\"/></w:numPr>" }
            if paragraphStyle.spaceBefore != nil || paragraphStyle.spaceAfter != nil {
                pPr += "<w:spacing"
                if let b = paragraphStyle.spaceBefore { pPr += " w:before=\"\(Int(measure: b * 20))\"" }
                if let a = paragraphStyle.spaceAfter { pPr += " w:after=\"\(Int(measure: a * 20))\"" }
                pPr += "/>"
            }
            switch paragraphStyle.alignment {
            case .start: break
            case .centre: pPr += "<w:jc w:val=\"center\"/>"
            case .end: pPr += "<w:jc w:val=\"right\"/>"
            case .justified: pPr += "<w:jc w:val=\"both\"/>"
            }
            return "<w:p>\(pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>")\(runs(text))</w:p>"
        }

        // MARK: Inlines

        mutating func runs(_ text: DocText) -> String {
            var out = ""
            var openLink: String?
            var linkBody = ""
            func closeLink(_ out: inout String) {
                guard let link = openLink else { return }
                out += hyperlinkOpen(link) + linkBody + "</w:hyperlink>"
                openLink = nil; linkBody = ""
            }
            for item in Inlines.flatten(text) {
                var chunk = ""
                var link: String?
                switch item {
                case .run(let t, let f): chunk = run(t, f); link = f.link
                case .image(let resource, let alt, let l): chunk = drawing(resource, alt: alt, link: l); link = l
                case .footnote(let id):
                    let number = footnoteNumber(id)
                    chunk = "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"\(number)\"/></w:r>"
                case .math(let tex): chunk = "<m:oMath>\(OMML.write(tex: tex))</m:oMath>"
                case .lineBreak: chunk = "<w:r><w:br/></w:r>"
                }
                if link != openLink { closeLink(&out) ; openLink = link }
                if openLink != nil { linkBody += chunk } else { out += chunk }
            }
            closeLink(&out)
            return out
        }

        mutating func hyperlinkOpen(_ destination: String) -> String {
            if destination.hasPrefix("#") { return "<w:hyperlink w:anchor=\"\(XML.escape(String(destination.dropFirst())))\">" }
            nextRel += 1
            let id = "rId\(nextRel)"
            relationships.append(OPCRelationship(id: id, type: OPCRelationship.hyperlink, target: destination, external: true))
            return "<w:hyperlink r:id=\"\(id)\">"
        }

        func run(_ text: String, _ f: RunFormat) -> String {
            var rPr = ""
            if f.link != nil { rPr += "<w:rStyle w:val=\"Hyperlink\"/>" }
            if f.code { rPr += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>" }
            else if let font = f.font { rPr += "<w:rFonts w:ascii=\"\(XML.escape(font))\" w:hAnsi=\"\(XML.escape(font))\" w:cs=\"\(XML.escape(font))\"/>" }
            if f.bold { rPr += "<w:b/>" }
            if f.italic { rPr += "<w:i/>" }
            if f.strike { rPr += "<w:strike/>" }
            if let colour = f.colour { rPr += "<w:color w:val=\"\(colour.replacingOccurrences(of: "#", with: ""))\"/>" }
            if let size = f.size { rPr += "<w:sz w:val=\"\(Int(measure: size * 2))\"/>" }
            if f.underline { rPr += "<w:u w:val=\"single\"/>" }
            if f.superscript { rPr += "<w:vertAlign w:val=\"superscript\"/>" } else if f.subscripted { rPr += "<w:vertAlign w:val=\"subscript\"/>" }
            return "<w:r>\(rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>")\(Self.textRun(text))</w:r>"
        }

        mutating func footnoteNumber(_ id: String) -> Int {
            if let n = footnoteIDs[id] { return n }
            let n = footnoteIDs.count + 1
            footnoteIDs[id] = n
            return n
        }

        mutating func drawing(_ resource: String, alt: String?, link: String?) -> String {
            guard let info = imageInfo(resource) else {
                lossNotes.append(LossNote(.imagesDropped, detail: resource))
                return alt.map { "<w:r><w:t xml:space=\"preserve\">\(XML.escape($0))</w:t></w:r>" } ?? ""
            }
            var width = Double(info.width) / info.dpi * 72, height = Double(info.height) / info.dpi * 72
            let scale = min(1, textWidth / max(width, 1), 600 / max(height, 1))
            width *= scale; height *= scale
            let cx = Int(measure: width * 12700), cy = Int(measure: height * 12700)
            let id = drawingID
            drawingID += 1
            let description = XML.escape(alt ?? "")
            return """
                <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
                <wp:docPr id="\(id)" name="Picture \(id)" descr="\(description)"/>\
                <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
                <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
                <pic:nvPicPr><pic:cNvPr id="\(id)" name="Picture \(id)" descr="\(description)"/><pic:cNvPicPr/></pic:nvPicPr>\
                <pic:blipFill><a:blip r:embed="\(info.rId)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
                <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
                </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
                """
        }

        mutating func imageInfo(_ resource: String) -> (rId: String, width: Int, height: Int, dpi: Double)? {
            if let known = imageIDs[resource] { return known }
            guard let data = model.resources[resource], let prepared = ImageSniff.prepare(data) else { return nil }
            let ext = prepared.type == "jpeg" ? "jpg" : prepared.type
            let path = "word/media/image\(media.count + 1).\(ext)"
            media.append((path, prepared.data))
            nextRel += 1
            let rId = "rId\(nextRel)"
            relationships.append(OPCRelationship(id: rId, type: OPCRelationship.image, target: String(path.dropFirst(5))))
            let info = (rId, prepared.pixelWidth, prepared.pixelHeight, prepared.dpi)
            imageIDs[resource] = info
            return info
        }

        // MARK: Lists

        mutating func list(ordered: Bool, start: Int, items: [[DocBlock]], depth: Int) -> String {
            var numId = 1
            if ordered {
                numbers.append((true, start))
                numId = numbers.count + 1
            }
            let level = min(depth, 8)
            var out = ""
            for item in items {
                var first = true
                for block in item {
                    switch block {
                    case .paragraph(let text, let style) where first:
                        out += paragraph(text, style: "ListParagraph", paragraphStyle: style, numbering: (numId, level))
                    case .list(let o, let s, let nested):
                        out += list(ordered: o, start: s, items: nested, depth: depth + 1)
                    case .paragraph(let text, let style):
                        out += paragraph(text, style: "ListParagraph", paragraphStyle: style)
                    default:
                        if first { out += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numId)\"/></w:numPr></w:pPr></w:p>" }
                        out += self.block(block, listDepth: depth + 1)
                    }
                    first = false
                }
                if item.isEmpty {
                    out += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numId)\"/></w:numPr></w:pPr></w:p>"
                }
            }
            return out
        }

        func numberingXML() -> String {
            func levels(bullet: Bool) -> String {
                (0..<9).map { i in
                    let indent = 720 * (i + 1)
                    let format = bullet ? "bullet" : ["decimal", "lowerLetter", "lowerRoman"][i % 3]
                    let text = bullet ? ["•", "◦", "▪"][i % 3] : "%\(i + 1)."
                    let font = bullet ? "<w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\"/></w:rPr>" : ""
                    return "<w:lvl w:ilvl=\"\(i)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(format)\"/><w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr>\(font)</w:lvl>"
                }.joined()
            }
            var xml = "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
            xml += "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels(bullet: true))</w:abstractNum>"
            xml += "<w:abstractNum w:abstractNumId=\"2\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels(bullet: false))</w:abstractNum>"
            xml += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"1\"/></w:num>"
            for (i, number) in numbers.enumerated() {
                xml += "<w:num w:numId=\"\(i + 2)\"><w:abstractNumId w:val=\"2\"/>"
                xml += (0..<9).map { "<w:lvlOverride w:ilvl=\"\($0)\"><w:startOverride w:val=\"\($0 == 0 ? number.start : 1)\"/></w:lvlOverride>" }.joined()
                xml += "</w:num>"
            }
            return xml + "</w:numbering>"
        }

        // MARK: Tables

        mutating func table(_ table: DocTable) -> String {
            let (columns, rows) = TableGrid.expand(table)
            let width = Int(measure: textWidth * 20)
            let columnWidth = width / columns
            var out = ""
            if let caption = table.caption { out += paragraph(caption, style: "Caption", paragraphStyle: DocParagraphStyle()) }
            out += "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(width)\" w:type=\"dxa\"/></w:tblPr><w:tblGrid>"
            out += String(repeating: "<w:gridCol w:w=\"\(columnWidth)\"/>", count: columns)
            out += "</w:tblGrid>"
            for (rowIndex, row) in rows.enumerated() {
                let source = table.rows[rowIndex]
                let isHeader = !source.isEmpty && source.allSatisfy(\.isHeader)
                out += "<w:tr>" + (isHeader ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
                for (column, slot) in row.enumerated() {
                    switch slot.covered {
                    case .left: continue   // the cell's gridSpan covers it
                    case .above: out += "<w:tc><w:tcPr><w:tcW w:w=\"\(columnWidth)\" w:type=\"dxa\"/><w:vMerge/></w:tcPr><w:p/></w:tc>"; continue
                    case .missing: out += "<w:tc><w:tcPr><w:tcW w:w=\"\(columnWidth)\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"; continue
                    case .none: break
                    }
                    guard let cell = slot.cell else { continue }
                    let span = max(min(cell.columnSpan, columns - column), 1)
                    var tcPr = "<w:tcW w:w=\"\(columnWidth * span)\" w:type=\"dxa\"/>"
                    if span > 1 { tcPr += "<w:gridSpan w:val=\"\(span)\"/>" }
                    if cell.rowSpan > 1 { tcPr += "<w:vMerge w:val=\"restart\"/>" }
                    var content = ""
                    let alignment = column < table.alignments.count ? table.alignments[column] : .start
                    for block in cell.blocks {
                        if case .paragraph(let text, var style) = block {
                            if style.alignment == .start { style.alignment = alignment }
                            content += paragraph(text, style: nil, paragraphStyle: style)
                        } else {
                            content += self.block(block, listDepth: 0)
                        }
                    }
                    if content.isEmpty || !content.hasSuffix("</w:p>") { content += "<w:p/>" }
                    out += "<w:tc><w:tcPr>\(tcPr)</w:tcPr>\(content)</w:tc>"
                }
                out += "</w:tr>"
            }
            return out + "</w:tbl><w:p><w:pPr><w:spacing w:after=\"0\"/></w:pPr></w:p>"
        }

        // MARK: Footnotes

        mutating func footnotesXML(_ namespaces: String) -> String {
            var xml = "<w:footnotes \(namespaces)>"
            xml += "<w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>"
            xml += "<w:footnote w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>"
            var written = 0
            // Notes can refer to further notes, so keep going until every referenced one is written.
            while written < footnoteIDs.count {
                let pending = footnoteIDs.filter { $0.value == written + 1 }
                guard let (id, number) = pending.first else { break }
                written += 1
                let blocks = footnoteBodies[id] ?? []
                var body = ""
                for (i, block) in blocks.enumerated() {
                    if i == 0, case .paragraph(let text, let style) = block {
                        let mark = "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/></w:r><w:r><w:t xml:space=\"preserve\"> </w:t></w:r>"
                        var p = paragraph(text, style: "FootnoteText", paragraphStyle: style)
                        if let range = p.range(of: "</w:pPr>") { p.replaceSubrange(range, with: "</w:pPr>" + mark) } else { p = p.replacingOccurrences(of: "<w:p>", with: "<w:p>" + mark) }
                        body += p
                    } else {
                        body += self.block(block, listDepth: 0, style: "FootnoteText")
                    }
                }
                if body.isEmpty { body = "<w:p><w:pPr><w:pStyle w:val=\"FootnoteText\"/></w:pPr><w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/></w:r></w:p>" }
                xml += "<w:footnote w:id=\"\(number)\">\(body)</w:footnote>"
            }
            return xml + "</w:footnotes>"
        }

        // MARK: Styles

        static func styles(_ language: String?) -> String {
            func heading(_ n: Int, _ size: Int) -> String {
                """
                <w:style w:type="paragraph" w:styleId="Heading\(n)"><w:name w:val="heading \(n)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
                <w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="\(n == 1 ? 360 : 240)" w:after="80"/><w:outlineLvl w:val="\(n - 1)"/></w:pPr>\
                <w:rPr><w:b/><w:sz w:val="\(size)"/></w:rPr></w:style>
                """
            }
            return """
                <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
                <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/>\(language.map { "<w:lang w:val=\"\(XML.escape($0))\"/>" } ?? "")</w:rPr></w:rPrDefault>\
                <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
                <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
                <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/></w:style>\
                \(heading(1, 40))\(heading(2, 32))\(heading(3, 28))\(heading(4, 24))\(heading(5, 22))\(heading(6, 22))\
                <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="120"/></w:pPr><w:rPr><w:sz w:val="56"/></w:rPr></w:style>\
                <w:style w:type="paragraph" w:styleId="Author"><w:name w:val="Author"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:jc w:val="center"/></w:pPr></w:style>\
                <w:style w:type="paragraph" w:styleId="Date"><w:name w:val="Date"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:jc w:val="center"/></w:pPr></w:style>\
                <w:style w:type="paragraph" w:styleId="Abstract"><w:name w:val="Abstract"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="720" w:right="720"/></w:pPr></w:style>\
                <w:style w:type="paragraph" w:styleId="Caption"><w:name w:val="caption"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="200"/></w:pPr><w:rPr><w:i/><w:sz w:val="18"/></w:rPr></w:style>\
                <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="720" w:right="720"/></w:pPr><w:rPr><w:i/></w:rPr></w:style>\
                <w:style w:type="paragraph" w:styleId="SourceCode"><w:name w:val="Source Code"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:ind w:left="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/></w:rPr></w:style>\
                <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/></w:pPr></w:style>\
                <w:style w:type="paragraph" w:styleId="FootnoteText"><w:name w:val="footnote text"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:sz w:val="20"/></w:rPr></w:style>\
                <w:style w:type="character" w:styleId="FootnoteReference"><w:name w:val="footnote reference"/><w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style>\
                <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>\
                <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:tblPr><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
                <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:tblPr><w:tblBorders>\
                <w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
                <w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/></w:tblBorders></w:tblPr></w:style>\
                </w:styles>
                """
        }
    }
}
