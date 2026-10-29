import CoreGraphics
import Foundation
import SuperConverterCore

// Origin: Super PDF Sources/ConvertKit/Export/PresentationWriter.swift @ 058469b (package layout, master, layout and theme
// parts, text and picture shapes), rewritten over Core's `Deck`: titles as placeholders, text boxes with styled runs,
// links, bullets and numbering, tables, pictures, vector shapes as custom geometry, backgrounds, speaker notes and
// hidden slides. Output is deterministic.
//
// PPTX writer (formats §3.2). Box coordinates are points from the slide's top left (see PPTXReader).

enum PPTXWriter {
    static let ns = #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
    private static let contentTypePrefix = "application/vnd.openxmlformats-officedocument.presentationml."
    private static let defaultAccents = ["4472C4", "ED7D31", "A5A5A5", "FFC000", "5B9BD5", "70AD47"]

    /// PowerPoint's limits: 1–56 inches (4032 points) a side.
    static func slideSize(_ size: VectorSize) -> CGSize {
        let width = size.width > 0 ? size.width : 720, height = size.height > 0 ? size.height : 540
        let scale = min(1, 4032 / max(width, height))
        return CGSize(width: min(max(width * scale, 72), 4032), height: min(max(height * scale, 72), 4032))
    }

    static func write(_ deck: Deck, title: String) -> Data {
        let slide = slideSize(deck.size)
        var package = OfficePackage()
        var presentationRelationships = [OfficeRelationship(id: "rId1", type: OfficeRelationship.slideMaster, target: "slideMasters/slideMaster1.xml")]
        var slideIDs = ""
        let slides = deck.slides.isEmpty ? [Slide()] : deck.slides
        var mediaCount = 0
        var hasNotes = false
        for (number, content) in slides.enumerated() {
            let n = number + 1
            var relationships = [OfficeRelationship(id: "rId1", type: OfficeRelationship.slideLayout, target: "../slideLayouts/slideLayout1.xml")]
            var nextID = 2
            func relationship(_ type: String, _ target: String, external: Bool = false) -> String {
                nextID += 1
                let id = "rId\(nextID)"
                relationships.append(OfficeRelationship(id: id, type: type, target: target, isExternal: external))
                return id
            }
            var shapes = ""
            var shapeID = 1
            func newID() -> Int { shapeID += 1; return shapeID }
            if let titleText = content.title, !titleText.isEmpty {
                shapes += """
                    <p:sp><p:nvSpPr><p:cNvPr id="\(newID())" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>\
                    <p:spPr/><p:txBody><a:bodyPr><a:normAutofit/></a:bodyPr><a:lstStyle/><a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>\(XML.escape(titleText))</a:t></a:r></a:p></p:txBody></p:sp>
                    """
            }
            for shape in content.shapes {
                let frame = CGRect(x: shape.box.x, y: shape.box.y, width: shape.box.width, height: shape.box.height)
                switch shape.content {
                case .text(let blocks):
                    let tables = blocks.compactMap { block -> DocTable? in if case .table(let t) = block { t } else { nil } }
                    let rest = blocks.filter { if case .table = $0 { false } else { true } }
                    if !rest.isEmpty {
                        let text = paragraphs(rest) { relationship(OfficeRelationship.hyperlink, $0, external: true) }
                        shapes += textBox(id: newID(), frame: frame, rotation: shape.rotation, paragraphs: text)
                    }
                    for table in tables { shapes += tableFrame(id: newID(), table: table, frame: frame) }
                case .picture(let image):
                    guard let png = Pictures.png(image) else { continue }
                    mediaCount += 1
                    package.add("ppt/media/image\(mediaCount).png", media: png)
                    let id = relationship(OfficeRelationship.image, "../media/image\(mediaCount).png")
                    shapes += pictureShape(id: newID(), name: "Picture \(shapeID)", relationship: id, frame: frame, rotation: shape.rotation)
                case .vector(let nodes):
                    shapes += vectorShapes(nodes, frame: frame, rotation: shape.rotation, newID: newID)
                }
            }
            let background = content.background.map {
                "<p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"\(hex($0))\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>"
            } ?? ""
            package.add("ppt/slides/slide\(n).xml", xml: """
                <p:sld \(ns)\(content.isHidden ? " show=\"0\"" : "")><p:cSld>\(background)<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
                <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
                \(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
                """, contentType: Self.contentTypePrefix + "slide+xml")
            if let notes = content.notes, !notes.isEmpty {
                hasNotes = true
                package.add("ppt/notesSlides/notesSlide\(n).xml", xml: notesSlideXML(notes), contentType: Self.contentTypePrefix + "notesSlide+xml")
                package.addRelationships("ppt/notesSlides/_rels/notesSlide\(n).xml.rels", [
                    OfficeRelationship(id: "rId1", type: OfficeRelationship.notesMaster, target: "../notesMasters/notesMaster1.xml"),
                    OfficeRelationship(id: "rId2", type: OfficeRelationship.slide, target: "../slides/slide\(n).xml"),
                ])
                _ = relationship(OfficeRelationship.notesSlide, "../notesSlides/notesSlide\(n).xml")
            }
            package.addRelationships("ppt/slides/_rels/slide\(n).xml.rels", relationships)
            presentationRelationships.append(OfficeRelationship(id: "rId\(n + 1)", type: OfficeRelationship.slide, target: "slides/slide\(n).xml"))
            slideIDs += "<p:sldId id=\"\(255 + n)\" r:id=\"rId\(n + 1)\"/>"
        }
        var next = slides.count + 2
        presentationRelationships += [
            OfficeRelationship(id: "rId\(next)", type: OfficeRelationship.theme, target: "theme/theme1.xml"),
            OfficeRelationship(id: "rId\(next + 1)", type: OfficeRelationship.presProps, target: "presProps.xml"),
            OfficeRelationship(id: "rId\(next + 2)", type: OfficeRelationship.viewProps, target: "viewProps.xml"),
            OfficeRelationship(id: "rId\(next + 3)", type: OfficeRelationship.tableStyles, target: "tableStyles.xml"),
        ]
        next += 4
        var notesMasterList = ""
        if hasNotes {
            presentationRelationships.append(OfficeRelationship(id: "rId\(next)", type: OfficeRelationship.notesMaster, target: "notesMasters/notesMaster1.xml"))
            notesMasterList = "<p:notesMasterIdLst><p:notesMasterId r:id=\"rId\(next)\"/></p:notesMasterIdLst>"
            package.add("ppt/notesMasters/notesMaster1.xml", xml: notesMasterXML(), contentType: Self.contentTypePrefix + "notesMaster+xml")
            package.addRelationships("ppt/notesMasters/_rels/notesMaster1.xml.rels", [
                OfficeRelationship(id: "rId1", type: OfficeRelationship.theme, target: "../theme/theme2.xml"),
            ])
            package.add("ppt/theme/theme2.xml", xml: themeXML(deck.theme), contentType: "application/vnd.openxmlformats-officedocument.theme+xml")
        }
        let cx = OfficeUnits.emu(slide.width), cy = OfficeUnits.emu(slide.height)
        package.add("ppt/presentation.xml", xml: """
            <p:presentation \(ns) saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\(notesMasterList)\
            <p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(cx)" cy="\(cy)"/><p:notesSz cx="6858000" cy="9144000"/>\
            <p:defaultTextStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr></p:defaultTextStyle></p:presentation>
            """, contentType: Self.contentTypePrefix + "presentation.main+xml")
        package.addRelationships("ppt/_rels/presentation.xml.rels", presentationRelationships)
        package.add("ppt/presProps.xml", xml: "<p:presentationPr \(ns)/>", contentType: Self.contentTypePrefix + "presProps+xml")
        package.add("ppt/viewProps.xml", xml: """
            <p:viewPr \(ns)><p:normalViewPr><p:restoredLeft sz="15620"/><p:restoredTop sz="94660"/></p:normalViewPr>\
            <p:gridSpacing cx="76200" cy="76200"/></p:viewPr>
            """, contentType: Self.contentTypePrefix + "viewProps+xml")
        package.add("ppt/tableStyles.xml", xml: #"<a:tblStyleLst xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" def="{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"/>"#,
                    contentType: Self.contentTypePrefix + "tableStyles+xml")
        package.add("ppt/slideMasters/slideMaster1.xml", xml: masterXML(slide), contentType: Self.contentTypePrefix + "slideMaster+xml")
        package.addRelationships("ppt/slideMasters/_rels/slideMaster1.xml.rels", [
            OfficeRelationship(id: "rId1", type: OfficeRelationship.slideLayout, target: "../slideLayouts/slideLayout1.xml"),
            OfficeRelationship(id: "rId2", type: OfficeRelationship.theme, target: "../theme/theme1.xml"),
        ])
        package.add("ppt/slideLayouts/slideLayout1.xml", xml: layoutXML(), contentType: Self.contentTypePrefix + "slideLayout+xml")
        package.addRelationships("ppt/slideLayouts/_rels/slideLayout1.xml.rels", [
            OfficeRelationship(id: "rId1", type: OfficeRelationship.slideMaster, target: "../slideMasters/slideMaster1.xml"),
        ])
        package.add("ppt/theme/theme1.xml", xml: themeXML(deck.theme), contentType: "application/vnd.openxmlformats-officedocument.theme+xml")
        package.addProperties(title: title, mainPart: "ppt/presentation.xml")
        return package.finish()
    }

    // MARK: Shapes

    private static func hex(_ c: VectorColour) -> String { String(PPTXReader.hex(SlideColor(r: c.red, g: c.green, b: c.blue)).dropFirst()) }

    private static func xfrm(_ frame: CGRect, rotation: Double = 0) -> String {
        let rot = rotation != 0 ? " rot=\"\(Int((rotation * 60_000).rounded()))\"" : ""
        return #"<a:xfrm\#(rot)><a:off x="\#(OfficeUnits.emu(frame.minX))" y="\#(OfficeUnits.emu(frame.minY))"/><a:ext cx="\#(max(OfficeUnits.emu(frame.width), 12_700))" cy="\#(max(OfficeUnits.emu(frame.height), 12_700))"/></a:xfrm>"#
    }

    private static func pictureShape(id: Int, name: String, relationship: String, frame: CGRect, rotation: Double) -> String {
        """
        <p:pic><p:nvPicPr><p:cNvPr id="\(id)" name="\(XML.escape(name))"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
        <p:blipFill><a:blip r:embed="\(relationship)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
        <p:spPr>\(xfrm(frame, rotation: rotation))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
        """
    }

    private static func textBox(id: Int, frame: CGRect, rotation: Double, paragraphs: String) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Text \(id)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
        <p:spPr>\(xfrm(frame, rotation: rotation))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>\
        <p:txBody><a:bodyPr wrap="square" lIns="0" tIns="0" rIns="0" bIns="0" rtlCol="0"><a:spAutoFit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>
        """
    }

    // MARK: Text

    private struct RunStyle {
        var bold = false, italic = false, strike = false, underline = false
        var font: String?
        var size: Double?
        var colour: String?
        var baseline = 0
        var link: String?
        var mono = false
    }

    private static func paragraphs(_ blocks: [DocBlock], link: (String) -> String, level: Int = 0, quoted: Bool = false) -> String {
        var out = ""
        for block in blocks {
            switch block {
            case .paragraph(let text, let style):
                out += paragraph(text, style: style, bullet: nil, level: level, base: RunStyle(italic: quoted), link: link)
            case .heading(let depth, let text):
                let sizes: [Double] = [28, 24, 20, 18, 16, 14]
                var base = RunStyle(bold: true)
                base.size = sizes[min(max(depth, 1), 6) - 1]
                out += paragraph(text, style: DocParagraphStyle(), bullet: nil, level: level, base: base, link: link)
            case .list(let ordered, let start, let items):
                for item in items {
                    var first = true
                    for sub in item {
                        if case .list = sub { out += paragraphs([sub], link: link, level: level + 1, quoted: quoted); continue }
                        if case .paragraph(let text, let style) = sub, first {
                            let bullet = ordered ? "<a:buFont typeface=\"+mj-lt\"/><a:buAutoNum type=\"arabicPeriod\"\(start != 1 ? " startAt=\"\(start)\"" : "")/>"
                                : "<a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/>"
                            out += paragraph(text, style: style, bullet: bullet, level: level, base: RunStyle(italic: quoted), link: link)
                            first = false
                        } else {
                            out += paragraphs([sub], link: link, level: level, quoted: quoted)
                        }
                    }
                }
            case .quote(let inner): out += paragraphs(inner, link: link, level: level, quoted: true)
            case .code(_, let text):
                for line in text.components(separatedBy: "\n") {
                    out += paragraph([.text(line)], style: DocParagraphStyle(), bullet: nil, level: level, base: RunStyle(mono: true), link: link)
                }
            case .math(let tex, _): out += paragraph([.text(tex)], style: DocParagraphStyle(), bullet: nil, level: level, base: RunStyle(), link: link)
            case .figure(_, let caption, _):
                if let caption { out += paragraph(caption, style: DocParagraphStyle(), bullet: nil, level: level, base: RunStyle(italic: true), link: link) }
            case .footnote, .thematicBreak, .pageBreak, .table: continue
            }
        }
        return out
    }

    private static func paragraph(_ text: DocText, style: DocParagraphStyle, bullet: String?, level: Int, base: RunStyle, link: (String) -> String) -> String {
        var properties = ""
        let algn: String? = switch style.alignment {
        case .centre: "ctr"
        case .end: "r"
        case .justified: "just"
        case .start: nil
        }
        var attributes = algn.map { " algn=\"\($0)\"" } ?? ""
        if bullet != nil { attributes = " marL=\"\(285_750 + level * 457_200)\" indent=\"-285750\" lvl=\"\(min(level, 8))\"" + attributes }
        else if level > 0 { attributes = " lvl=\"\(min(level, 8))\"" + attributes }
        if let before = style.spaceBefore { properties += "<a:spcBef><a:spcPts val=\"\(Int(before * 100))\"/></a:spcBef>" }
        if let after = style.spaceAfter { properties += "<a:spcAft><a:spcPts val=\"\(Int(after * 100))\"/></a:spcAft>" }
        properties += bullet ?? ""
        var inherited = base
        inherited.font = base.font ?? style.fontName
        inherited.size = base.size ?? style.fontSize
        var runs = ""
        emit(text, inherited, link: link, into: &runs)
        let pPr = properties.isEmpty && attributes.isEmpty ? "" : "<a:pPr\(attributes)\(properties.isEmpty ? "/>" : ">\(properties)</a:pPr>")"
        return "<a:p>\(pPr)\(runs)</a:p>"
    }

    private static func emit(_ text: DocText, _ style: RunStyle, link: (String) -> String, into out: inout String) {
        for piece in text {
            var s = style
            switch piece {
            case .text(let t): out += run(t, s)
            case .code(let t): s.mono = true; out += run(t, s)
            case .emphasis(let c): s.italic = true; emit(c, s, link: link, into: &out)
            case .strong(let c): s.bold = true; emit(c, s, link: link, into: &out)
            case .strike(let c): s.strike = true; emit(c, s, link: link, into: &out)
            case .link(let c, let destination): s.link = link(destination); emit(c, s, link: link, into: &out)
            case .styled(let c, let r):
                s.font = r.fontName ?? s.font; s.size = r.fontSize ?? s.size; s.colour = r.colour ?? s.colour
                s.underline = s.underline || r.underline
                if r.superscript { s.baseline = 30 } else if r.subscripted { s.baseline = -25 }
                emit(c, s, link: link, into: &out)
            case .image, .footnoteReference: continue
            case .math(let tex): out += run(tex, s)
            case .lineBreak: out += "<a:br>\(runProperties(s))</a:br>"
            }
        }
    }

    private static func run(_ text: String, _ style: RunStyle) -> String {
        "<a:r>\(runProperties(style))<a:t>\(XML.escape(text))</a:t></a:r>"
    }

    private static func runProperties(_ style: RunStyle) -> String {
        var attributes = #" lang="en-US""#
        if let size = style.size { attributes += " sz=\"\(min(max(Int((size * 100).rounded()), 100), 400_000))\"" }
        if style.bold { attributes += #" b="1""# }
        if style.italic { attributes += #" i="1""# }
        if style.underline { attributes += #" u="sng""# }
        if style.strike { attributes += #" strike="sngStrike""# }
        if style.baseline != 0 { attributes += " baseline=\"\(style.baseline * 1000)\"" }
        var children = ""
        if let colour = style.colour.flatMap({ SheetRGB(hex: $0) }) { children += "<a:solidFill><a:srgbClr val=\"\(colour.hash.dropFirst())\"/></a:solidFill>" }
        let face = style.mono ? "Menlo" : style.font
        if let face { children += "<a:latin typeface=\"\(XML.escape(face))\"/><a:cs typeface=\"\(XML.escape(face))\"/>" }
        if let link = style.link { children += "<a:hlinkClick r:id=\"\(link)\"/>" }
        return children.isEmpty ? "<a:rPr\(attributes) dirty=\"0\"/>" : "<a:rPr\(attributes) dirty=\"0\">\(children)</a:rPr>"
    }

    // MARK: Tables

    private static func tableFrame(id: Int, table: DocTable, frame: CGRect) -> String {
        // Place cells on a grid: spans cover the slots after and below their anchor.
        var covered = [[Bool]](repeating: [], count: table.rows.count)
        var placed: [[(cell: DocTable.Cell?, hMerge: Bool, vMerge: Bool)]] = []
        var columns = 1
        for (r, row) in table.rows.enumerated() {
            var line: [(cell: DocTable.Cell?, hMerge: Bool, vMerge: Bool)] = []
            var c = 0
            func isCovered(_ r: Int, _ c: Int) -> Bool { c < covered[r].count && covered[r][c] }
            func cover(_ r: Int, _ c: Int) {
                while covered[r].count <= c { covered[r].append(false) }
                covered[r][c] = true
            }
            for cell in row {
                while isCovered(r, c) { line.append((nil, false, true)); c += 1 }
                line.append((cell, false, false))
                let colSpan = max(cell.columnSpan, 1), rowSpan = max(cell.rowSpan, 1)
                for dc in 1..<max(colSpan, 1) { line.append((nil, true, false)); cover(r, c + dc) }
                if rowSpan > 1 { for dr in 1..<rowSpan where r + dr < covered.count { for dc in 0..<colSpan { cover(r + dr, c + dc) } } }
                c += colSpan
            }
            while isCovered(r, c) { line.append((nil, false, true)); c += 1 }
            columns = max(columns, line.count)
            placed.append(line)
        }
        let columnWidth = OfficeUnits.emu(frame.width / CGFloat(columns))
        let rowHeight = OfficeUnits.emu(max(frame.height / CGFloat(max(table.rows.count, 1)), 12))
        let header = table.rows.first?.contains { $0.isHeader } ?? false
        var xml = "<a:tbl><a:tblPr firstRow=\"\(header ? 1 : 0)\" bandRow=\"1\"><a:tableStyleId>{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}</a:tableStyleId></a:tblPr><a:tblGrid>"
            + String(repeating: "<a:gridCol w=\"\(columnWidth)\"/>", count: columns) + "</a:tblGrid>"
        for line in placed {
            xml += "<a:tr h=\"\(rowHeight)\">"
            for slot in line + [(DocTable.Cell?, Bool, Bool)](repeating: (nil, false, false), count: columns - line.count) {
                guard let cell = slot.cell else {
                    xml += "<a:tc\(slot.hMerge ? " hMerge=\"1\"" : "")\(slot.vMerge ? " vMerge=\"1\"" : "")><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang=\"en-US\"/></a:p></a:txBody><a:tcPr/></a:tc>"
                    continue
                }
                var attributes = ""
                if cell.columnSpan > 1 { attributes += " gridSpan=\"\(cell.columnSpan)\"" }
                if cell.rowSpan > 1 { attributes += " rowSpan=\"\(cell.rowSpan)\"" }
                var body = paragraphs(cell.blocks, link: { _ in "" })
                if body.isEmpty { body = "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>" }
                xml += "<a:tc\(attributes)><a:txBody><a:bodyPr/><a:lstStyle/>\(body)</a:txBody><a:tcPr/></a:tc>"
            }
            xml += "</a:tr>"
        }
        xml += "</a:tbl>"
        return """
            <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="\(id)" name="Table \(id)"/><p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr>\
            <p:xfrm><a:off x="\(OfficeUnits.emu(frame.minX))" y="\(OfficeUnits.emu(frame.minY))"/><a:ext cx="\(columnWidth * columns)" cy="\(rowHeight * max(table.rows.count, 1))"/></p:xfrm>\
            <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table">\(xml)</a:graphicData></a:graphic></p:graphicFrame>
            """
    }

    // MARK: Vector shapes

    private static func vectorShapes(_ nodes: [VectorNode], frame: CGRect, rotation: Double, newID: () -> Int) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case .path(let segments, let fill, let stroke, _):
                out += pathShape(id: newID(), segments: segments, fill: fill, stroke: stroke, frame: frame, rotation: rotation)
            case .group(let children, _, _, _):
                out += vectorShapes(children, frame: frame, rotation: rotation, newID: newID)
            case .text, .image: continue
            }
        }
        return out
    }

    private static func pathShape(id: Int, segments: [PathSegment], fill: VectorPaint?, stroke: VectorStroke?, frame: CGRect, rotation: Double) -> String {
        func point(_ p: VectorPoint) -> String { "<a:pt x=\"\(OfficeUnits.emu(p.x))\" y=\"\(OfficeUnits.emu(p.y))\"/>" }
        var path = ""
        for segment in segments {
            switch segment {
            case .move(let p): path += "<a:moveTo>\(point(p))</a:moveTo>"
            case .line(let p): path += "<a:lnTo>\(point(p))</a:lnTo>"
            case .cubic(let a, let b, let c): path += "<a:cubicBezTo>\(point(a))\(point(b))\(point(c))</a:cubicBezTo>"
            case .quad(let a, let b): path += "<a:quadBezTo>\(point(a))\(point(b))</a:quadBezTo>"
            case .close: path += "<a:close/>"
            }
        }
        let w = max(OfficeUnits.emu(frame.width), 1), h = max(OfficeUnits.emu(frame.height), 1)
        var line = "<a:ln><a:noFill/></a:ln>"
        if let stroke, let colour = solid(stroke.paint) {
            let dash = stroke.dash.isEmpty ? "" : "<a:prstDash val=\"dash\"/>"
            line = "<a:ln w=\"\(OfficeUnits.emu(stroke.width))\"><a:solidFill>\(colour)</a:solidFill>\(dash)</a:ln>"
        }
        return """
            <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Shape \(id)"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>\
            <p:spPr>\(xfrm(frame, rotation: rotation))<a:custGeom><a:avLst/><a:gdLst/><a:ahLst/><a:cxnLst/><a:rect l="0" t="0" r="r" b="b"/>\
            <a:pathLst><a:path w="\(w)" h="\(h)">\(path)</a:path></a:pathLst></a:custGeom>\(fillXML(fill))\(line)</p:spPr></p:sp>
            """
    }

    private static func solid(_ paint: VectorPaint) -> String? {
        switch paint {
        case .solid(let c): return color(c)
        case .linear(_, _, let stops), .radial(_, _, let stops): return stops.first.map { color($0.colour) }
        case .rasterised: return nil
        }
    }

    private static func color(_ c: VectorColour) -> String {
        c.alpha < 1 ? "<a:srgbClr val=\"\(hex(c))\"><a:alpha val=\"\(Int(c.alpha * 100_000))\"/></a:srgbClr>" : "<a:srgbClr val=\"\(hex(c))\"/>"
    }

    private static func fillXML(_ paint: VectorPaint?) -> String {
        switch paint {
        case nil, .rasterised?: return "<a:noFill/>"
        case .solid(let c)?: return "<a:solidFill>\(color(c))</a:solidFill>"
        case .linear(let from, let to, let stops)?:
            let angle = atan2(to.y - from.y, to.x - from.x) * 180 / .pi
            let list = stops.map { "<a:gs pos=\"\(Int($0.offset * 100_000))\">\(color($0.colour))</a:gs>" }.joined()
            return "<a:gradFill rotWithShape=\"1\"><a:gsLst>\(list)</a:gsLst><a:lin ang=\"\(Int(((angle + 360).truncatingRemainder(dividingBy: 360)) * 60_000))\" scaled=\"0\"/></a:gradFill>"
        case .radial(_, _, let stops)?:
            let list = stops.map { "<a:gs pos=\"\(Int($0.offset * 100_000))\">\(color($0.colour))</a:gs>" }.joined()
            return "<a:gradFill rotWithShape=\"1\"><a:gsLst>\(list)</a:gsLst><a:path path=\"circle\"><a:fillToRect l=\"50000\" t=\"50000\" r=\"50000\" b=\"50000\"/></a:path></a:gradFill>"
        }
    }

    // MARK: Notes

    private static func notesSlideXML(_ notes: String) -> String {
        let body = notes.components(separatedBy: "\n").map { "<a:p><a:r><a:rPr lang=\"en-US\" dirty=\"0\"/><a:t>\(XML.escape($0))</a:t></a:r></a:p>" }.joined()
        return """
            <p:notes \(ns)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
            <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp>\
            <p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/>\
            <p:txBody><a:bodyPr/><a:lstStyle/>\(body)</p:txBody></p:sp></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>
            """
    }

    private static func notesMasterXML() -> String {
        """
        <p:notesMaster \(ns)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>\
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg" idx="2"/></p:nvPr></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="685800" y="1143000"/><a:ext cx="5486400" cy="3086100"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr></p:sp>\
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" sz="quarter" idx="3"/></p:nvPr></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="685800" y="4400550"/><a:ext cx="5486400" cy="3600450"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
        <p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:pPr lvl="0"/><a:r><a:rPr lang="en-US"/><a:t>Notes</a:t></a:r></a:p></p:txBody></p:sp>\
        </p:spTree></p:cSld>\
        <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
        <p:notesStyle><a:lvl1pPr marL="0" algn="l"><a:defRPr sz="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/></a:defRPr></a:lvl1pPr></p:notesStyle></p:notesMaster>
        """
    }

    // MARK: Master, layout, theme

    private static func placeholderFrames(_ slide: CGSize) -> (title: CGRect, body: CGRect) {
        let margin = slide.width * 0.06
        let title = CGRect(x: margin, y: slide.height * 0.05, width: slide.width - 2 * margin, height: slide.height * 0.17)
        let body = CGRect(x: margin, y: slide.height * 0.25, width: slide.width - 2 * margin, height: slide.height * 0.68)
        return (title, body)
    }

    private static func masterXML(_ slide: CGSize) -> String {
        let frames = placeholderFrames(slide)
        let titleSize = Int(min(max(slide.height / 540 * 3600, 1200), 8000))
        let bodySize = Int(min(max(slide.height / 540 * 2400, 900), 6000))
        func level(_ n: Int, size: Int) -> String {
            let marL = 228_600 + n * 457_200
            return #"<a:lvl\#(n + 1)pPr marL="\#(marL)" indent="-228600" algn="l"><a:spcBef><a:spcPts val="600"/></a:spcBef><a:buFont typeface="Arial"/><a:buChar char="•"/><a:defRPr sz="\#(size)"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl\#(n + 1)pPr>"#
        }
        let levels = (0..<9).map { level($0, size: max(bodySize - $0 * 200, 800)) }.joined()
        return """
            <p:sldMaster \(ns)><p:cSld><p:bg><p:bgPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree>\
            <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
            <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
            <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>\
            <p:spPr>\(xfrm(frames.title))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
            <p:txBody><a:bodyPr vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0" anchor="ctr"><a:normAutofit/></a:bodyPr><a:lstStyle/>\
            <a:p><a:r><a:rPr lang="en-US"/><a:t>Title</a:t></a:r></a:p></p:txBody></p:sp>\
            <p:sp><p:nvSpPr><p:cNvPr id="3" name="Text Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>\
            <p:spPr>\(xfrm(frames.body))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
            <p:txBody><a:bodyPr vert="horz" lIns="91440" tIns="45720" rIns="91440" bIns="45720" rtlCol="0"><a:normAutofit/></a:bodyPr><a:lstStyle/>\
            <a:p><a:pPr lvl="0"/><a:r><a:rPr lang="en-US"/><a:t>Text</a:t></a:r></a:p></p:txBody></p:sp>\
            </p:spTree></p:cSld>\
            <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" \
            accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
            <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>\
            <p:txStyles><p:titleStyle><a:lvl1pPr algn="l"><a:spcBef><a:spcPct val="0"/></a:spcBef><a:buNone/>\
            <a:defRPr sz="\(titleSize)" b="1"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/></a:defRPr></a:lvl1pPr></p:titleStyle>\
            <p:bodyStyle>\(levels)</p:bodyStyle>\
            <p:otherStyle><a:defPPr><a:defRPr lang="en-US"/></a:defPPr></p:otherStyle></p:txStyles></p:sldMaster>
            """
    }

    private static func layoutXML() -> String {
        """
        <p:sldLayout \(ns) type="obj" preserve="1"><p:cSld name="Title and Content"><p:spTree>\
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Title 1"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>\
        <p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang="en-US"/><a:t>Title</a:t></a:r></a:p></p:txBody></p:sp>\
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Content Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph idx="1"/></p:nvPr></p:nvSpPr>\
        <p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:pPr lvl="0"/><a:r><a:rPr lang="en-US"/><a:t>Text</a:t></a:r></a:p></p:txBody></p:sp>\
        </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """
    }

    private static func themeXML(_ theme: DeckTheme) -> String {
        func colour(_ name: String, _ value: String) -> String { "<a:\(name)><a:srgbClr val=\"\(value)\"/></a:\(name)>" }
        let accents = (0..<6).map { index -> String in
            theme.accents.indices.contains(index) ? (SheetRGB(hex: theme.accents[index])?.hash.dropFirst()).map(String.init) ?? defaultAccents[index] : defaultAccents[index]
        }
        let colors = [colour("dk1", "000000"), colour("lt1", "FFFFFF"), colour("dk2", "44546A"), colour("lt2", "E7E6E6")]
            + accents.enumerated().map { colour("accent\($0.offset + 1)", $0.element) }
            + [colour("hlink", "0563C1"), colour("folHlink", "954F72")]
        let line = #"<a:ln w="9525" cap="flat" cmpd="sng" algn="ctr"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:prstDash val="solid"/><a:miter lim="800000"/></a:ln>"#
        let fill = #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#
        return """
            <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements>\
            <a:clrScheme name="Office">\(colors.joined())</a:clrScheme>\
            <a:fontScheme name="Office"><a:majorFont><a:latin typeface="\(XML.escape(theme.headingFont))"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>\
            <a:minorFont><a:latin typeface="\(XML.escape(theme.bodyFont))"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>\
            <a:fmtScheme name="Office"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst>\
            <a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>\
            <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
            <a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements>\
            <a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
            """
    }
}
