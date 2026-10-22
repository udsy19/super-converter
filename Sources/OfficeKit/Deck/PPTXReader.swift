import CoreGraphics
import Foundation
import SuperConverterCore

// PPTX / PPSX / PPTM / POTX reader into Core's `Deck` (formats §3.2: text, pictures, shapes, themes, backgrounds; no
// animations). It walks the same package model as the renderer (`SlideDeck`, `SlideCanvas`'s placeholder and text
// inheritance) but produces data instead of drawing. A shape's `box` is in points with the origin at the slide's top
// left and y down; a vector shape's nodes are in points relative to its box's top left. A slide's title placeholder is
// the slide's `title`, not a shape. `PPTXReader.docModel` is "slide text extraction for MD/TXT".

enum PPTXReader {
    struct Result {
        var deck: Deck
        var title: String?
        var lossNotes: [LossNote]
    }

    static func read(_ url: URL) throws -> Result {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.damaged(FormatID("pptx")) }
        if data.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { throw ConversionError.passwordRequired(FormatID("pptx")) }
        return try read(SlideDeck(url: url))
    }

    static func read(_ deck: SlideDeck) throws -> Result {
        var slides: [Slide] = []
        var leftOut = false, animations = false
        for (index, path) in deck.slidePaths.enumerated() {
            guard let part = try deck.part(path), part.root.name == "sld" else { continue }
            let extractor = try SlideExtractor(deck: deck, slide: part, number: index + 1)
            slides.append(try extractor.extract())
            leftOut = leftOut || extractor.leftOut
            animations = animations || part.root.child("timing") != nil
        }
        var notes: [LossNote] = []
        if leftOut { notes.append(LossNote(.otherLoss, detail: "Some charts, diagrams or embedded objects couldn’t be read, so they were left out.")) }
        if animations { notes.append(LossNote(.animationDropped)) }
        var theme = DeckTheme()
        if let first = try deck.slidePaths.first.flatMap({ try deck.part($0) }),
           let layout = try deck.part(first.target(ofType: "/slideLayout")), let master = try deck.part(layout.target(ofType: "/slideMaster")) {
            let slideTheme = deck.theme(for: master)
            theme = DeckTheme(headingFont: slideTheme.majorFont ?? theme.headingFont, bodyFont: slideTheme.minorFont ?? theme.bodyFont,
                              accents: (1...6).compactMap { slideTheme.colors["accent\($0)"].map(hex) })
        }
        return Result(deck: Deck(size: VectorSize(width: Double(deck.size.width), height: Double(deck.size.height)), slides: slides, theme: theme),
                      title: deck.title, lossNotes: notes)
    }

    static func hex(_ colour: SlideColor) -> String {
        func byte(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(colour.r), byte(colour.g), byte(colour.b))
    }

    // MARK: Text extraction

    /// The words of a deck as a document: each slide's title as a heading, its text and pictures in reading order, and
    /// optionally its speaker notes; hidden slides only when asked for.
    static func docModel(_ deck: Deck, title: String? = nil, includeNotes: Bool = false, includeHidden: Bool = false) -> DocModel {
        var blocks: [DocBlock] = []
        var resources: [String: Data] = [:]
        var first = true
        for (index, slide) in deck.slides.enumerated() where includeHidden || !slide.isHidden {
            if !first { blocks.append(.thematicBreak) }
            first = false
            blocks.append(.heading(level: 1, [.text(slide.title ?? "Slide \(index + 1)")]))
            // Reading order: top to bottom in bands, left to right within a band.
            let ordered = slide.shapes.sorted { a, b in
                let rowA = (a.box.y / 24).rounded(.down), rowB = (b.box.y / 24).rounded(.down)
                return rowA != rowB ? rowA < rowB : a.box.x < b.box.x
            }
            for shape in ordered {
                switch shape.content {
                case .text(let content): blocks += content
                case .picture(let image):
                    guard let png = Pictures.png(image) else { continue }
                    let name = "slide\(index + 1)-picture\(resources.count + 1).png"
                    resources[name] = png
                    blocks.append(.figure(resource: name, caption: nil, altText: nil))
                case .vector: continue
                }
            }
            if includeNotes, let notes = slide.notes, !notes.isEmpty {
                blocks.append(.quote([.paragraph([.strong([.text("Notes")])], DocParagraphStyle())]
                    + notes.components(separatedBy: "\n").filter { !$0.isEmpty }.map { .paragraph([.text($0)], DocParagraphStyle()) }))
            }
        }
        return DocModel(metadata: DocMetadata(title: title ?? deck.slides.first?.title), blocks: blocks, resources: resources)
    }
}

// MARK: - One slide

final class SlideExtractor {
    let deck: SlideDeck
    private let canvas: SlideCanvas
    private let slide: SlidePart
    private(set) var leftOut = false
    private var title: String?
    private var shapes: [SlideShape] = []
    private var shapeCount = 0

    init(deck: SlideDeck, slide: SlidePart, number: Int) throws {
        self.deck = deck
        self.slide = slide
        // The canvas supplies placeholder and style inheritance; nothing is drawn into this 1 × 1 context.
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas = try SlideCanvas(deck: deck, slide: slide, number: number, context: context)
    }

    func extract() throws -> Slide {
        let top = CGAffineTransform(scaleX: 1 / slideEMU, y: 1 / slideEMU)
        if let tree = slide.root.path("cSld/spTree") { walk(tree, mapper: top, depth: 0, group: nil) }
        return Slide(title: title, shapes: shapes, background: background(), notes: notes(),
                     isHidden: ["0", "false", "off"].contains(slide.root.attr("show") ?? ""))
    }

    // MARK: Trees

    private func walk(_ tree: XMLNode, mapper: CGAffineTransform, depth: Int, group: SlideFill?) {
        guard depth <= SlideLimits.groupDepth else { return }
        for child in tree.children {
            guard shapeCount < SlideLimits.shapesPerSlide else { return }
            switch child.name {
            case "sp", "cxnSp": shapeCount += 1; shape(child, mapper: mapper, group: group)
            case "pic": shapeCount += 1; picture(child, mapper: mapper)
            case "graphicFrame": shapeCount += 1; graphicFrame(child, mapper: mapper)
            case "grpSp": shapeCount += 1; self.group(child, mapper: mapper, depth: depth, group: group)
            case "AlternateContent": if let branch = SlideCanvas.branch(child) { walk(branch, mapper: mapper, depth: depth + 1, group: group) }
            default: continue
            }
        }
    }

    private func group(_ node: XMLNode, mapper: CGAffineTransform, depth: Int, group parentFill: SlideFill?) {
        let props = node.child("grpSpPr")
        let fill = SlidePaint(deck: deck, part: slide, colors: canvas.colors).fill(in: props, group: parentFill) ?? parentFill
        guard let xfrm = SlideXfrm(props?.child("xfrm")) else { walk(node, mapper: mapper, depth: depth + 1, group: fill); return }
        let child = xfrm.childRect ?? xfrm.rect
        let sx = child.width != 0 ? xfrm.rect.width / child.width : 1
        let sy = child.height != 0 ? xfrm.rect.height / child.height : 1
        let childToParent = CGAffineTransform(translationX: -child.minX, y: -child.minY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: xfrm.rect.minX, y: xfrm.rect.minY))
        walk(node, mapper: childToParent.concatenating(mapper), depth: depth + 1, group: fill)
    }

    // MARK: Shapes

    private func shape(_ node: XMLNode, mapper: CGAffineTransform, group: SlideFill?) {
        let placeholder = SlideCanvas.placeholder(node)
        let chain = placeholder.map { canvas.inherited($0, in: slide) } ?? []
        let spPr = node.child("spPr")
        guard let xfrm = SlideXfrm(spPr?.child("xfrm")) ?? chain.lazy.compactMap({ SlideXfrm($0.node.child("spPr")?.child("xfrm")) }).first else { return }
        let frame = xfrm.rect.applying(mapper)
        guard frame.minX.isFinite, frame.minY.isFinite, frame.width.isFinite, frame.height.isFinite else { return }
        let box = LayoutBox(x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width), height: Double(frame.height))

        let style = node.child("style")
        let owner = canvas.geometryOwner(spPr, chain: chain)
        let (fill, line) = canvas.appearance(of: node, part: slide, chain: chain, group: group)
        if fill != nil || line != nil {
            let geometry = SlideGeometry.path(in: owner, rect: CGRect(origin: .zero, size: frame.size))
            let segments = Self.segments(geometry.path)
            if !segments.isEmpty {
                let paint = fill.flatMap { Self.paint($0, size: frame.size) }
                let stroke = line.flatMap { Self.stroke($0, size: frame.size) }
                if paint != nil || stroke != nil {
                    shapes.append(SlideShape(box: box, rotation: xfrm.rotation, content: .vector([.path(segments, fill: geometry.isOpen ? nil : paint, stroke: stroke)])))
                }
            }
        }
        guard let body = node.child("txBody") else { return }
        let context = canvas.textContext(placeholder: placeholder, chain: chain, style: style)
        let blocks = Self.blocks(body, context: context, slide: slide)
        guard !blocks.isEmpty else { return }
        if slide === canvas.slide, title == nil, placeholder?.masterType == "title" {
            title = SlideCanvas.outlineTitle(Self.plainText(blocks))
            if title != nil { return }
        }
        shapes.append(SlideShape(box: box, rotation: xfrm.rotation, content: .text(blocks)))
    }

    private func picture(_ node: XMLNode, mapper: CGAffineTransform) {
        let placeholder = SlideCanvas.placeholder(node)
        let chain = placeholder.map { canvas.inherited($0, in: slide) } ?? []
        guard let xfrm = SlideXfrm(node.child("spPr")?.child("xfrm")) ?? chain.lazy.compactMap({ SlideXfrm($0.node.child("spPr")?.child("xfrm")) }).first,
              let blipFill = node.child("blipFill") else { return }
        appendPicture(blipFill, xfrm: xfrm, mapper: mapper)
    }

    private func appendPicture(_ blipFill: XMLNode, xfrm: SlideXfrm, mapper: CGAffineTransform) {
        let frame = xfrm.rect.applying(mapper)
        guard let id = blipFill.child("blip")?.attr("r:embed"), var image = deck.image(slide, id) else { leftOut = true; return }
        func fraction(_ key: String) -> Double {
            guard let v = Double(blipFill.child("srcRect")?.attr(key) ?? ""), v.isFinite else { return 0 }
            return min(max(v / 100_000, 0), 0.99)
        }
        let l = fraction("l"), t = fraction("t"), r = fraction("r"), b = fraction("b")
        if l + t + r + b > 0, let cropped = image.cropping(to: CGRect(x: Double(image.width) * l, y: Double(image.height) * t,
                                                                      width: Double(image.width) * (1 - l - r), height: Double(image.height) * (1 - t - b))) {
            image = cropped
        }
        guard let asset = Pictures.asset(from: image) else { leftOut = true; return }
        shapes.append(SlideShape(box: LayoutBox(x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width), height: Double(frame.height)),
                                 rotation: xfrm.rotation, content: .picture(asset)))
    }

    private func graphicFrame(_ node: XMLNode, mapper: CGAffineTransform) {
        let placeholder = SlideCanvas.placeholder(node)
        let chain = placeholder.map { canvas.inherited($0, in: slide) } ?? []
        guard let xfrm = SlideXfrm(node.child("xfrm")) ?? chain.lazy.compactMap({ SlideXfrm($0.node.child("spPr")?.child("xfrm")) }).first else { return }
        let frame = xfrm.rect.applying(mapper)
        let data = node.child("graphic")?.child("graphicData")
        if let table = data?.child("tbl") {
            guard let docTable = Self.table(table) else { leftOut = true; return }
            shapes.append(SlideShape(box: LayoutBox(x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width), height: Double(frame.height)),
                                     rotation: 0, content: .text([.table(docTable)])))
        } else if let picture = data?.first("pic"), let blipFill = picture.child("blipFill") {
            appendPicture(blipFill, xfrm: xfrm, mapper: mapper)
        } else {
            leftOut = true
        }
    }

    // MARK: Slide-level parts

    private func background() -> VectorColour? {
        for part in [slide, canvas.layout, canvas.master].compactMap({ $0 }) {
            guard let bg = part.root.path("cSld/bg") else { continue }
            let paint = SlidePaint(deck: deck, part: part, colors: canvas.colors)
            guard let fill = paint.fill(in: bg.child("bgPr")) ?? paint.themeFill(bg.child("bgRef")) else { continue }
            return fill.averageColor.map { Self.colour($0) }
        }
        return nil
    }

    private func notes() -> String? {
        guard let part = try? deck.part(slide.target(ofType: "/notesSlide")), let tree = part.root.path("cSld/spTree") else { return nil }
        for shape in tree.children("sp") where SlideCanvas.placeholder(shape)?.type == "body" {
            let text = shape.child("txBody")?.children("p").map { paragraph in
                paragraph.children.map { item -> String in
                    switch item.name {
                    case "r", "fld": item.child("t")?.text ?? ""
                    case "br": "\n"
                    default: ""
                    }
                }.joined()
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let text, !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: Conversions

    static func colour(_ c: SlideColor) -> VectorColour { VectorColour(red: c.r, green: c.g, blue: c.b, alpha: c.a) }

    private static func paint(_ fill: SlideFill, size: CGSize) -> VectorPaint? {
        switch fill {
        case .none, .picture: return nil
        case .solid(let c): return .solid(colour(c))
        case .gradient(let stops, let angle, let radial):
            let mapped = stops.map { GradientStop(offset: $0.0, colour: colour($0.1)) }
            guard mapped.count > 1 else { return mapped.first.map { .solid($0.colour) } }
            let w = Double(size.width), h = Double(size.height)
            if radial { return .radial(centre: VectorPoint(w / 2, h / 2), radius: max(w, h) / 2, stops: mapped) }
            let a = angle * .pi / 180
            let dx = cos(a) * w / 2, dy = sin(a) * h / 2
            return .linear(from: VectorPoint(w / 2 - dx, h / 2 - dy), to: VectorPoint(w / 2 + dx, h / 2 + dy), stops: mapped)
        }
    }

    private static func stroke(_ line: SlideLine, size: CGSize) -> VectorStroke? {
        guard let paint = paint(line.fill, size: size) else { return nil }
        return VectorStroke(paint: paint, width: line.width, dash: (line.dash ?? []).map { $0 * line.width })
    }

    private static func segments(_ path: CGPath) -> [PathSegment] {
        var out: [PathSegment] = []
        path.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: out.append(.move(VectorPoint(Double(p[0].x), Double(p[0].y))))
            case .addLineToPoint: out.append(.line(VectorPoint(Double(p[0].x), Double(p[0].y))))
            case .addQuadCurveToPoint: out.append(.quad(VectorPoint(Double(p[0].x), Double(p[0].y)), VectorPoint(Double(p[1].x), Double(p[1].y))))
            case .addCurveToPoint:
                out.append(.cubic(VectorPoint(Double(p[0].x), Double(p[0].y)), VectorPoint(Double(p[1].x), Double(p[1].y)), VectorPoint(Double(p[2].x), Double(p[2].y))))
            case .closeSubpath: out.append(.close)
            @unknown default: break
            }
        }
        return out
    }

    // MARK: Text bodies

    private struct Entry { var level: Int; var ordered: Bool?; var block: DocBlock }

    /// A text body's paragraphs as blocks: bulleted runs become lists (nested by level), the rest paragraphs.
    static func blocks(_ body: XMLNode, context: SlideTextContext, slide: SlidePart) -> [DocBlock] {
        let own = body.child("lstStyle")
        let bodyProps = SlideBodyProps([body.child("bodyPr")].compactMap { $0 } + context.bodies)
        var entries: [Entry] = []
        for paragraph in body.children("p") {
            let pPr = paragraph.child("pPr")
            let level = min(max(Int(pPr?.attr("lvl") ?? "") ?? 0, 0), 8)
            let props = SlideText.paragraphProps(pPr, level: level, own: own, context: context)
            var inlines: [DocInline] = []
            var firstRun: SlideRunProps?
            for item in paragraph.children {
                switch item.name {
                case "r", "fld":
                    let text = item.name == "fld" && item.attr("type") == "slidenum" ? String(context.slideNumber) : (item.child("t")?.text ?? "")
                    guard !text.isEmpty else { continue }
                    let run = SlideRunProps(item.child("rPr"), colors: context.colors).merged(over: props.run)
                    firstRun = firstRun ?? run
                    var inline = styled(.text(run.allCaps == true ? text.uppercased() : text), run, context: context, scale: bodyProps.fontScale)
                    if let link = item.child("rPr")?.child("hlinkClick")?.attr("r:id"), let rel = slide.relationships[link], rel.isExternal {
                        inline = .link([inline], destination: rel.target)
                    }
                    inlines.append(inline)
                case "br": inlines.append(.lineBreak)
                default: continue
                }
            }
            guard inlines.contains(where: { if case .lineBreak = $0 { false } else { true } }) else { continue }
            var style = DocParagraphStyle()
            switch props.align {
            case "ctr": style.alignment = .centre
            case "r": style.alignment = .end
            case "just", "dist", "justLow": style.alignment = .justified
            default: break
            }
            if let run = firstRun {
                style.fontName = context.colors.theme.typeface(run.typeface) ?? context.colors.theme.typeface(context.defaultTypeface)
                style.fontSize = (run.size ?? 18) * bodyProps.fontScale
            }
            style.spaceBefore = props.spaceBefore.flatMap { if case .points(let p) = $0 { p } else { nil } }
            style.spaceAfter = props.spaceAfter.flatMap { if case .points(let p) = $0 { p } else { nil } }
            let ordered: Bool? = switch props.bullet {
            case .character?: false
            case .number?: true
            default: nil
            }
            entries.append(Entry(level: level, ordered: ordered, block: .paragraph(inlines, style)))
        }
        return group(entries)
    }

    /// Runs of bulleted entries as lists; deeper levels nest inside the item above them.
    private static func group(_ entries: [Entry]) -> [DocBlock] {
        var out: [DocBlock] = []
        var index = 0
        while index < entries.count {
            guard let ordered = entries[index].ordered else { out.append(entries[index].block); index += 1; continue }
            var end = index
            while end < entries.count, entries[end].ordered != nil { end += 1 }
            out.append(list(Array(entries[index..<end]), ordered: ordered))
            index = end
        }
        return out
    }

    private static func list(_ entries: [Entry], ordered: Bool) -> DocBlock {
        let base = entries.map(\.level).min() ?? 0
        var items: [[DocBlock]] = []
        var index = 0
        while index < entries.count {
            let entry = entries[index]
            var item = [entry.block]
            var end = index + 1
            while end < entries.count, entries[end].level > base { end += 1 }
            if end > index + 1 { item.append(list(Array(entries[(index + 1)..<end]), ordered: entries[index + 1].ordered ?? false)) }
            items.append(item)
            index = end
        }
        return .list(ordered: ordered, start: 1, items: items)
    }

    private static func styled(_ text: DocInline, _ run: SlideRunProps, context: SlideTextContext, scale: Double) -> DocInline {
        var inline = text
        var style = DocRunStyle()
        style.fontName = context.colors.theme.typeface(run.typeface) ?? context.colors.theme.typeface(context.defaultTypeface)
        style.fontSize = (run.size ?? 18) * scale
        style.colour = run.color.map(PPTXReader.hex)
        style.underline = run.underline == true
        if let baseline = run.baseline { style.superscript = baseline > 0; style.subscripted = baseline < 0 }
        inline = .styled([inline], style)
        if run.bold == true { inline = .strong([inline]) }
        if run.italic == true { inline = .emphasis([inline]) }
        return inline
    }

    static func plainText(_ blocks: [DocBlock]) -> String {
        func inline(_ text: DocText) -> String {
            text.map { piece -> String in
                switch piece {
                case .text(let t), .code(let t): t
                case .emphasis(let c), .strong(let c), .strike(let c), .link(let c, _), .styled(let c, _): inline(c)
                case .lineBreak: "\n"
                default: ""
                }
            }.joined()
        }
        return blocks.map { block -> String in
            switch block {
            case .paragraph(let t, _), .heading(_, let t): inline(t)
            case .list(_, _, let items): items.map { plainText($0) }.joined(separator: "\n")
            case .table(let table): table.rows.map { $0.map { plainText($0.blocks) }.joined(separator: "\t") }.joined(separator: "\n")
            default: ""
            }
        }.joined(separator: "\n")
    }

    // MARK: Tables

    private static func table(_ node: XMLNode) -> DocTable? {
        let rows = node.children("tr")
        let columns = node.child("tblGrid")?.children("gridCol").count ?? 0
        guard !rows.isEmpty, columns > 0, rows.count * columns <= SlideLimits.tableCells else { return nil }
        let headerRow = ["1", "true"].contains(node.child("tblPr")?.attr("firstRow") ?? "")
        var out: [[DocTable.Cell]] = []
        for (r, row) in rows.enumerated() {
            var cells: [DocTable.Cell] = []
            for cell in row.children("tc") {
                if ["1", "true"].contains(cell.attr("hMerge") ?? "") || ["1", "true"].contains(cell.attr("vMerge") ?? "") { continue }
                let paragraphs = (cell.child("txBody")?.children("p") ?? []).map { paragraph in
                    paragraph.children.map { item -> String in
                        switch item.name {
                        case "r", "fld": item.child("t")?.text ?? ""
                        case "br": "\n"
                        default: ""
                        }
                    }.joined()
                }
                let blocks: [DocBlock] = paragraphs.filter { !$0.isEmpty }.map { .paragraph([.text($0)], DocParagraphStyle()) }
                cells.append(DocTable.Cell(blocks: blocks, columnSpan: max(Int(cell.attr("gridSpan") ?? "") ?? 1, 1),
                                           rowSpan: max(Int(cell.attr("rowSpan") ?? "") ?? 1, 1), isHeader: headerRow && r == 0))
            }
            out.append(cells)
        }
        return DocTable(rows: out)
    }
}
