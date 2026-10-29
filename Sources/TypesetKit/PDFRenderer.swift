import CoreGraphics
import CoreText
import Foundation
import VectorKit

/// A bookmark: a heading's title, its page and position, and its children.
struct OutlineEntry {
    var title: String
    var page: Int
    var y: Double
    var children: [OutlineEntry] = []
}

/// Draws pages into a PDF with Core Graphics: text as real text with subset-embedded fonts (Core Text writes /ActualText
/// for ligatures, so copied text reads "office"), a tagged structure tree (headings, paragraphs, lists, tables, formulas
/// with their TeX as /ActualText, figures with alternative text), links without visible boxes (hyperref's
/// `hidelinks`), named destinations for footnotes, and bookmarks from headings. Layout is in TeX points; everything is
/// converted to PDF units here (fonts at 72/72.27 of their size), so the page has no scaling transform.
final class PDFRenderer {
    let style: StyleSheet
    let fonts: FontResolver
    /// "As written": the document's font for page numbers and running heads.
    let documentFont: String?
    private let k = 72 / 72.27
    private var scaledFonts: [ObjectIdentifier: CTFont] = [:]
    private var openTags: [TagNode] = []

    init(style: StyleSheet, fonts: FontResolver, documentFont: String?) {
        self.style = style; self.fonts = fonts; self.documentFont = documentFont
    }

    struct Metadata {
        var title: String?
        var author: String?
        var subject: String?
        var pdfA = false
    }

    func render(_ pages: [Page], metadata: Metadata, outline: [OutlineEntry], to url: URL, progress: (Int) -> Void = { _ in }) throws {
        var info: [CFString: Any] = [kCGPDFContextCreator: "Super Converter"]
        if let t = metadata.title { info[kCGPDFContextTitle] = t }
        if let a = metadata.author { info[kCGPDFContextAuthor] = a }
        if let s = metadata.subject { info[kCGPDFContextSubject] = s }
        if metadata.pdfA { info[kCGPDFContextCreatePDFA] = true }
        let g = style.geometry
        var media = CGRect(x: 0, y: 0, width: g.paper.width.bp, height: g.paper.height.bp)
        guard let ctx = CGContext(url as CFURL, mediaBox: &media, info as CFDictionary) else {
            throw TypesetError.cannotWrite(url.lastPathComponent)
        }
        for (index, page) in pages.enumerated() {
            ctx.beginPDFPage([kCGPDFContextMediaBox: media] as CFDictionary)
            ctx.textMatrix = .identity
            drawPage(page, ctx)
            ctx.endPDFPage()
            progress(index + 1)
        }
        if !outline.isEmpty {
            CGPDFContextSetOutline(ctx, [kCGPDFOutlineChildren: outline.map(outlineDictionary)] as CFDictionary)
        }
        ctx.closePDF()
    }

    private func outlineDictionary(_ e: OutlineEntry) -> CFDictionary {
        let top = (style.geometry.paper.height - e.y).bp
        var d: [CFString: Any] = [kCGPDFOutlineTitle: e.title, kCGPDFOutlineDestination: e.page,
                                  kCGPDFOutlineDestinationRect: CGRect(x: 0, y: top, width: 0, height: 0).dictionaryRepresentation]
        if !e.children.isEmpty { d[kCGPDFOutlineChildren] = e.children.map(outlineDictionary) }
        return d as CFDictionary
    }

    // MARK: Pages

    private func drawPage(_ page: Page, _ ctx: CGContext) {
        let g = style.geometry
        let height = g.paper.height
        let odd = page.number % 2 == 1 || !style.twoSided
        let left = odd ? g.oddLeft : g.evenLeft
        openTags = []
        for p in page.header {
            syncTags(p.box.tags, ctx)
            draw(p.box.box.ops, x: left + p.x, y: height - (g.textTop + p.y), ctx)
        }
        closeTags(ctx)
        let top = g.textTop + (page.number == 1 ? page.headerHeight : 0)
        for (c, column) in page.columns.enumerated() {
            let colLeft = left + Double(c) * (g.columnWidth + g.columnSep)
            for p in column {
                syncTags(p.box.tags, ctx)
                draw(p.box.box.ops, x: colLeft + p.x, y: height - (top + p.y), ctx)
            }
            closeTags(ctx)
            if c < page.footnoteRules.count, let rule = page.footnoteRules[c] {
                // \footnoterule: 0.4 pt high, 0.4 of the column wide.
                fill(CGRect(x: colLeft, y: height - (top + rule) - 0.4, width: 0.4 * g.columnWidth, height: 0.4), colour: nil, ctx)
            }
            if c < page.footnotes.count {
                for p in page.footnotes[c] {
                    syncTags(p.box.tags, ctx)
                    draw(p.box.box.ops, x: colLeft + p.x, y: height - (top + p.y), ctx)
                }
                closeTags(ctx)
            }
        }
        drawFurniture(page, left: left, odd: odd, ctx)
    }

    /// Page numbers and running heads: `plain` centres the number in the footer, `\footskip` below the text block; the
    /// book's `headings` style puts it at the outer edge of the head with the chapter title in slanted capitals.
    private func drawFurniture(_ page: Page, left: Double, odd: Bool, _ ctx: CGContext) {
        let g = style.geometry
        let size = style.normal.size
        let roman = fonts.font(for: RunStyle(size: size, documentFont: documentFont))
        switch page.style {
        case .empty:
            return
        case .plain:
            let number = textLine("\(page.number)", font: roman)
            drawLine(number, x: left + (g.textWidth - width(number)) / 2, y: g.paper.height - (g.textTop + g.textHeight + g.footSkip), ctx)
        case .headings:
            let baseline = g.paper.height - (g.textTop - g.headSep)
            let number = textLine("\(page.number)", font: roman)
            let head = page.runningHead.flatMap { $0.isEmpty ? nil : textLine($0, font: fonts.font(for: RunStyle(shape: .slanted, size: size, documentFont: documentFont))) }
            if odd {
                if let head { drawLine(head, x: left, y: baseline, ctx) }
                drawLine(number, x: left + g.textWidth - width(number), y: baseline, ctx)
            } else {
                drawLine(number, x: left, y: baseline, ctx)
                if let head { drawLine(head, x: left + g.textWidth - width(head), y: baseline, ctx) }
            }
        }
    }

    private func textLine(_ s: String, font: CTFont) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                   kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true])
    }

    private func width(_ s: NSAttributedString) -> Double {
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(s), nil, nil, nil)
    }

    // MARK: Structure tags

    private func syncTags(_ path: [TagNode], _ ctx: CGContext) {
        var common = 0
        while common < openTags.count && common < path.count && openTags[common] == path[common] { common += 1 }
        while openTags.count > common { CGPDFContextEndTag(ctx); openTags.removeLast() }
        for node in path[common...] {
            beginTag(node, ctx)
            openTags.append(node)
        }
    }

    private func closeTags(_ ctx: CGContext) {
        while !openTags.isEmpty { CGPDFContextEndTag(ctx); openTags.removeLast() }
    }

    private func beginTag(_ node: TagNode, _ ctx: CGContext) {
        var props: [CFString: Any] = [:]
        if let t = node.actualText { props[CGPDFTagProperty.actualText.rawValue] = t }
        if let a = node.alt { props[CGPDFTagProperty.alternativeText.rawValue] = a }
        CGPDFContextBeginTag(ctx, Self.tagType(node.kind), props as CFDictionary)
    }

    static func tagType(_ kind: TagKind) -> CGPDFTagType {
        switch kind {
        case .paragraph: .paragraph
        case .heading(let n): [CGPDFTagType.header1, .header2, .header3, .header4, .header5, .header6][max(0, min(n - 1, 5))]
        case .list: .list
        case .listItem: .listItem
        case .table: .table
        case .tableRow: .tableRow
        case .tableHeaderCell: .tableHeaderCell
        case .tableCell: .tableDataCell
        case .figure: .figure
        case .formula: .formula
        case .caption: .caption
        case .blockQuote: .blockQuote
        case .code: .code
        case .note: .note
        case .tocItem: .TOCI
        case .division: .div
        }
    }

    // MARK: Drawing (TeX points in, PDF units out)

    private func scaled(_ font: CTFont) -> CTFont {
        let id = ObjectIdentifier(font)
        if let f = scaledFonts[id] { return f }
        let f = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * CGFloat(k), nil, nil)
        scaledFonts[id] = f
        return f
    }

    private func scaled(_ s: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: s)
        let all = NSRange(location: 0, length: m.length)
        let fontKey = kCTFontAttributeName as NSAttributedString.Key, kernKey = kCTKernAttributeName as NSAttributedString.Key
        s.enumerateAttribute(fontKey, in: all) { v, r, _ in if let v { m.addAttribute(fontKey, value: scaled(v as! CTFont), range: r) } }
        s.enumerateAttribute(kernKey, in: all) { v, r, _ in if let v = v as? Double { m.addAttribute(kernKey, value: v * k, range: r) } }
        return m
    }

    private func drawLine(_ s: NSAttributedString, x: Double, y: Double, _ ctx: CGContext) {
        ctx.textPosition = CGPoint(x: x * k, y: y * k)
        CTLineDraw(CTLineCreateWithAttributedString(scaled(s)), ctx)
    }

    private func fill(_ r: CGRect, colour: CGColor?, _ ctx: CGContext) {
        ctx.setFillColor(colour ?? CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k))
    }

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: x * k, y: y * k, width: w * k, height: h * k)
    }

    private func draw(_ ops: [DrawOp], x: Double, y: Double, _ ctx: CGContext) {
        for op in ops {
            switch op {
            case .text(let s, let dx, let dy):
                drawLine(s, x: x + dx, y: y + dy, ctx)
            case .vector(let nodes, let vx, let vy, let scale):
                ctx.saveGState()
                ctx.translateBy(x: (x + vx) * k, y: (y + vy) * k)
                ctx.scaleBy(x: scale * k, y: scale * k)
                for node in nodes { VectorDrawing.draw(node, in: ctx) }
                ctx.restoreGState()
            case .rule(let rx, let ry, let w, let h, let colour):
                fill(CGRect(x: x + rx, y: y + ry, width: w, height: h), colour: colour, ctx)
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            case .image(let content, let ix, let iy, let w, let h):
                let r = rect(x + ix, y + iy, w, h)
                switch content {
                case .raster(let image):
                    ctx.interpolationQuality = .high
                    ctx.draw(image, in: r)
                case .pdf(let page):
                    ctx.saveGState()
                    let box = page.getBoxRect(.cropBox)
                    ctx.translateBy(x: r.minX, y: r.minY)
                    ctx.scaleBy(x: r.width / box.width, y: r.height / box.height)
                    ctx.translateBy(x: -box.minX, y: -box.minY)
                    ctx.clip(to: box)
                    ctx.drawPDFPage(page)
                    ctx.restoreGState()
                }
            case .link(let url, let lx, let ly, let w, let h):
                if let u = URL(string: url) { ctx.setURL(u as CFURL, for: rect(x + lx, y + ly, w, h)) }
            case .internalLink(let name, let lx, let ly, let w, let h):
                ctx.setDestination(name as CFString, for: rect(x + lx, y + ly, w, h))
            case .anchor(let name, let ax, let ay):
                ctx.addDestination(name as CFString, at: CGPoint(x: (x + ax) * k, y: (y + ay) * k))
            case .tagged(let node, let inner):
                beginTag(node, ctx)
                draw(inner, x: x, y: y, ctx)
                CGPDFContextEndTag(ctx)
            case .box(let b, let bx, let by):
                draw(b.ops, x: x + bx, y: y + by, ctx)
            }
        }
    }
}
