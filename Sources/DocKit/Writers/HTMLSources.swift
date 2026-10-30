import Foundation
import SuperConverterCore

/// The other models `HTMLWriter` writes (formats §3.2 and the matrix): a `LayoutDocument` from a PDF (reflowed text, or
/// positioned pages as SVG with selectable text), a `VectorDocument` from slides (one inline SVG per slide), and a
/// `Workbook` (one table per sheet). They share the page shell and style with the `DocModel` route.
enum HTMLSources {
    // MARK: Layout (PDF → HTML)

    /// Reflowed: headings, paragraphs (hyphenated line ends joined), lists, tables and figures in reading order, running
    /// headers and footers left out. Built as a `DocModel` so the markup is the one `HTMLWriter` makes.
    static func reflowed(_ layout: LayoutDocument, title: String?, embedImages: Bool, filesFolder: String) -> HTMLWriter.Output {
        var model = DocModel(metadata: DocMetadata(title: title))   // the <title>; no title block in the page
        var listEntries: [(ordered: Bool, text: DocText)] = []
        func flushList() {
            guard let first = listEntries.first else { return }
            let items = listEntries.map { [DocBlock.paragraph($0.text, DocParagraphStyle())] }
            model.blocks.append(.list(ordered: first.ordered, start: 1, items: items))
            listEntries = []
        }
        for page in layout.pages {
            for block in page.blocks {
                switch block {
                case .paragraph(let lines, _): flushList(); model.blocks.append(.paragraph(text(lines), DocParagraphStyle()))
                case .heading(let level, let lines): flushList(); model.blocks.append(.heading(level: min(max(level, 1), 6), text(lines, bold: false)))
                case .listItem(let marker, let lines):
                    let ordered = marker.contains { $0.isNumber || $0.isLetter }
                    if let last = listEntries.last, last.ordered != ordered { flushList() }
                    listEntries.append((ordered, text(lines)))
                case .table(let rows, _):
                    flushList()
                    model.blocks.append(.table(DocTable(rows: rows.map { row in
                        row.map { DocTable.Cell(blocks: [.paragraph(text($0), DocParagraphStyle())]) }
                    })))
                case .figure(_, let image):
                    flushList()
                    if let image, let png = image.frames.first?.pngData() {
                        let key = "figure\(model.resources.count + 1).png"
                        model.resources[key] = png
                        model.blocks.append(.figure(resource: key, caption: nil, altText: nil))
                    }
                case .header, .footer: break
                }
            }
        }
        flushList()
        return HTMLWriter.render(model, embedImages: embedImages, filesFolder: filesFolder, titleBlock: false)
    }

    /// The text of lines as inline runs: words joined by spaces; a hyphen at a line end joins the word to the next line's.
    private static func text(_ lines: [LayoutLine], bold: Bool = true) -> DocText {
        var builder = InlineBuilder()
        for (index, line) in lines.enumerated() {
            if index > 0 {
                if case .run(let t, _)? = builder.items.last, t.hasSuffix("-"), t.count > 1, let next = line.words.first?.text.first, next.isLowercase {
                    builder.removeLastCharacter()
                } else { builder.add(" ", RunFormat()) }
            }
            for (w, word) in line.words.enumerated() {
                var f = RunFormat()
                f.bold = bold && word.isBold; f.italic = word.isItalic
                builder.add((w > 0 ? " " : "") + word.text, f)
            }
        }
        return builder.build()
    }

    /// Positioned: each page is an SVG at the PDF's size; every line is a `<text>` placed where the PDF has it (and stretched
    /// to its width), so the page looks like the PDF and its text can be selected and searched.
    static func positioned(_ layout: LayoutDocument, title: String?) -> HTMLWriter.Output {
        var body = ""
        for (n, page) in layout.pages.enumerated() {
            let w = page.size.width, h = page.size.height
            body += "<section class=\"page\" id=\"page-\(n + 1)\"><svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(num(w)) \(num(h))\" width=\"\(num(w))pt\" height=\"\(num(h))pt\">"
            body += "<rect width=\"\(num(w))\" height=\"\(num(h))\" fill=\"#fff\"/>"
            func lines(_ lines: [LayoutLine]) {
                for line in lines {
                    guard let first = line.words.first else { continue }
                    let size = first.fontSize
                    let baseline = h - (line.box.y + size * 0.22)
                    var weight = "", style = ""
                    if first.isBold { weight = " font-weight=\"bold\"" }
                    if first.isItalic { style = " font-style=\"italic\"" }
                    let family = first.fontName.split(separator: "+").last.map(String.init)?.replacingOccurrences(of: "\"", with: "") ?? first.fontName
                    body += "<text x=\"\(num(line.box.x))\" y=\"\(num(baseline))\" font-size=\"\(num(size))\" font-family=\"'\(HTMLEntities.escape(family, attribute: true))', serif\"\(weight)\(style) textLength=\"\(num(line.box.width))\" lengthAdjust=\"spacingAndGlyphs\" xml:space=\"preserve\">\(HTMLEntities.escape(line.words.map(\.text).joined(separator: " ")))</text>"
                }
            }
            for block in page.blocks {
                switch block {
                case .paragraph(let l, _), .heading(_, let l), .listItem(_, let l), .header(let l), .footer(let l): lines(l)
                case .table(let rows, _): for row in rows { for cell in row { lines(cell) } }
                case .figure(let box, let image):
                    if let image, let png = image.frames.first?.pngData() {
                        body += "<image x=\"\(num(box.x))\" y=\"\(num(h - box.y - box.height))\" width=\"\(num(box.width))\" height=\"\(num(box.height))\" href=\"data:image/png;base64,\(png.base64EncodedString())\"/>"
                    }
                }
            }
            body += "</svg></section>\n"
        }
        let css = "body{margin:0;background:#888}.page{margin:12pt auto;width:max-content;box-shadow:0 1px 6px rgba(0,0,0,.4)}svg{display:block}@media print{body{background:none}.page{margin:0;box-shadow:none;break-after:page}}"
        return HTMLWriter.Output(html: shell(title: title, css: css, body: body))
    }

    // MARK: Slides (VectorDocument → HTML)

    static func slides(_ document: VectorDocument) -> HTMLWriter.Output {
        var body = ""
        for (n, page) in document.pages.enumerated() {
            body += "<section class=\"slide\" id=\"slide-\(n + 1)\">" + svg(page) + "</section>\n"
        }
        let css = "body{margin:0;background:#222;padding:1px 0}.slide{margin:18pt auto;width:max-content;max-width:100%;box-shadow:0 2px 10px rgba(0,0,0,.5)}svg{display:block;max-width:100%;height:auto}@media print{body{background:none}.slide{margin:0;box-shadow:none;break-after:page}}"
        return HTMLWriter.Output(html: shell(title: document.title, css: css, body: body))
    }

    private static func shell(title: String?, css: String, body: String) -> String {
        "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>\(HTMLEntities.escape(title ?? ""))</title>\n<style>\(css)</style>\n</head>\n<body>\n\(body)</body>\n</html>\n"
    }

    static func num(_ v: Double) -> String {
        let s = String(format: "%.3f", v)
        guard s.contains(".") else { return s }
        var t = s
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t == "-0" ? "0" : t
    }

    /// One page as SVG. The page's y axis points up; one wrapping group flips it, and text and pictures flip back.
    static func svg(_ page: VectorPage) -> String {
        var defs = ""
        var gradients = 0
        var clips = 0
        func colour(_ c: VectorColour) -> String { String(format: "#%02X%02X%02X", Int(measure: min(max(c.red, 0), 1) * 255), Int(measure: min(max(c.green, 0), 1) * 255), Int(measure: min(max(c.blue, 0), 1) * 255)) }
        func opacity(_ c: VectorColour) -> String { c.alpha < 1 ? " fill-opacity=\"\(num(c.alpha))\"" : "" }
        func pathData(_ segments: [PathSegment]) -> String {
            segments.map { s -> String in
                switch s {
                case .move(let p): "M\(num(p.x)) \(num(p.y))"
                case .line(let p): "L\(num(p.x)) \(num(p.y))"
                case .cubic(let a, let b, let c): "C\(num(a.x)) \(num(a.y)) \(num(b.x)) \(num(b.y)) \(num(c.x)) \(num(c.y))"
                case .quad(let a, let b): "Q\(num(a.x)) \(num(a.y)) \(num(b.x)) \(num(b.y))"
                case .close: "Z"
                }
            }.joined()
        }
        func paint(_ p: VectorPaint) -> String {
            switch p {
            case .solid(let c): return colour(c)
            case .linear(let from, let to, let stops):
                gradients += 1
                defs += "<linearGradient id=\"g\(gradients)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(num(from.x))\" y1=\"\(num(from.y))\" x2=\"\(num(to.x))\" y2=\"\(num(to.y))\">"
                    + stops.map { "<stop offset=\"\(num($0.offset))\" stop-color=\"\(colour($0.colour))\"/>" }.joined() + "</linearGradient>"
                return "url(#g\(gradients))"
            case .radial(let centre, let radius, let stops):
                gradients += 1
                defs += "<radialGradient id=\"g\(gradients)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(num(centre.x))\" cy=\"\(num(centre.y))\" r=\"\(num(radius))\">"
                    + stops.map { "<stop offset=\"\(num($0.offset))\" stop-color=\"\(colour($0.colour))\"/>" }.joined() + "</radialGradient>"
                return "url(#g\(gradients))"
            case .rasterised: return "#808080"
            }
        }
        func node(_ n: VectorNode) -> String {
            switch n {
            case .path(let segments, let fill, let stroke, let rule):
                var attrs = " d=\"\(pathData(segments))\""
                if rule == .evenOdd { attrs += " fill-rule=\"evenodd\"" }
                if let fill { attrs += " fill=\"\(paint(fill))\""; if case .solid(let c) = fill, c.alpha < 1 { attrs += opacity(c) } } else { attrs += " fill=\"none\"" }
                if let stroke {
                    attrs += " stroke=\"\(paint(stroke.paint))\" stroke-width=\"\(num(stroke.width))\""
                    if !stroke.dash.isEmpty { attrs += " stroke-dasharray=\"\(stroke.dash.map(num).joined(separator: " "))\"" }
                    if stroke.cap != .butt { attrs += " stroke-linecap=\"\(stroke.cap.rawValue)\"" }
                    if stroke.join != .miter { attrs += " stroke-linejoin=\"\(stroke.join.rawValue)\"" }
                }
                return "<path\(attrs)/>"
            case .text(let run):
                let family = run.fontName.split(separator: "+").last.map(String.init) ?? run.fontName
                return "<text transform=\"translate(\(num(run.origin.x)) \(num(run.origin.y))) scale(1 -1)\" font-size=\"\(num(run.size))\" font-family=\"'\(HTMLEntities.escape(family, attribute: true))', sans-serif\" fill=\"\(paint(run.fill))\" xml:space=\"preserve\">\(HTMLEntities.escape(run.text))</text>"
            case .image(let asset, let t):
                guard let png = asset.frames.first?.pngData() else { return "" }
                return "<image transform=\"matrix(\(num(t.a)) \(num(t.b)) \(num(t.c)) \(num(t.d)) \(num(t.tx)) \(num(t.ty))) translate(0 1) scale(1 -1)\" width=\"1\" height=\"1\" preserveAspectRatio=\"none\" href=\"data:image/png;base64,\(png.base64EncodedString())\"/>"
            case .group(let children, let t, let clip, let alpha):
                var attrs = ""
                if t != .identity { attrs += " transform=\"matrix(\(num(t.a)) \(num(t.b)) \(num(t.c)) \(num(t.d)) \(num(t.tx)) \(num(t.ty)))\"" }
                if alpha < 1 { attrs += " opacity=\"\(num(alpha))\"" }
                if let clip {
                    clips += 1
                    defs += "<clipPath id=\"c\(clips)\"><path d=\"\(pathData(clip))\"/></clipPath>"
                    attrs += " clip-path=\"url(#c\(clips))\""
                }
                return "<g\(attrs)>" + children.map(node).joined() + "</g>"
            }
        }
        let w = page.size.width, h = page.size.height
        let content = page.nodes.map(node).joined()
        let background = page.background.map { "<rect width=\"\(num(w))\" height=\"\(num(h))\" fill=\"\(colour($0))\"/>" } ?? "<rect width=\"\(num(w))\" height=\"\(num(h))\" fill=\"#fff\"/>"
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(num(w)) \(num(h))\" width=\"\(num(w))pt\" height=\"\(num(h))pt\"><defs>\(defs)</defs>\(background)<g transform=\"translate(0 \(num(h))) scale(1 -1)\">\(content)</g></svg>"
    }

    // MARK: Workbook (spreadsheet → HTML)

    static func workbook(_ workbook: Workbook) -> HTMLWriter.Output {
        var body = ""
        for sheet in workbook.sheets where !sheet.isHidden {
            body += "<section class=\"sheet\">\n<h2>\(HTMLEntities.escape(sheet.name))</h2>\n<table>\n"
            // A merge covers every position it spans; only its first cell is written, with spans.
            var origin: [Int: [Int: CellRange]] = [:]
            var covered = Set<[Int]>()
            for m in sheet.merges {
                origin[m.firstRow, default: [:]][m.firstColumn] = m
                for r in m.firstRow...m.lastRow { for c in m.firstColumn...m.lastColumn where r != m.firstRow || c != m.firstColumn { covered.insert([r, c]) } }
            }
            let columns = sheet.rows.map(\.count).max() ?? 0
            for (r, row) in sheet.rows.enumerated() {
                body += "<tr>"
                for c in 0..<columns {
                    if covered.contains([r, c]) { continue }
                    let cell = c < row.count ? row[c] : Cell()
                    var attrs = ""
                    if let m = origin[r]?[c] {
                        if m.lastColumn > m.firstColumn { attrs += " colspan=\"\(m.lastColumn - m.firstColumn + 1)\"" }
                        if m.lastRow > m.firstRow { attrs += " rowspan=\"\(m.lastRow - m.firstRow + 1)\"" }
                    }
                    var css: [String] = []
                    let alignment = cell.style.alignment ?? { if case .number = cell.value { .end } else { nil } }()
                    switch alignment { case .centre?: css.append("text-align:center"); case .end?: css.append("text-align:right"); default: break }
                    if cell.style.bold { css.append("font-weight:bold") }
                    if cell.style.italic { css.append("font-style:italic") }
                    if let colour = cell.style.textColour { css.append("color:\(colour)") }
                    if let fill = cell.style.fillColour { css.append("background:\(fill)") }
                    if !css.isEmpty { attrs += " style=\"\(css.joined(separator: ";"))\"" }
                    body += "<td\(attrs)>\(HTMLEntities.escape(display(cell)))</td>"
                }
                body += "</tr>\n"
            }
            body += "</table>\n</section>\n"
        }
        let css = HTMLWriter.style + "table{font-size:.9em}td{white-space:pre-wrap}body{max-width:none}"
        return HTMLWriter.Output(html: shell(title: workbook.title, css: css, body: body))
    }

    static func display(_ cell: Cell) -> String {
        if let text = cell.displayText { return text }
        switch cell.value {
        case .empty: return ""
        case .number(let v): return v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(format: "%.15g", v)
        case .text(let s): return s
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .date(let d): return DocDates.string(d)
        case .error(let e): return e
        }
    }
}
