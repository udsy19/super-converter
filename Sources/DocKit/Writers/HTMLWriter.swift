import Foundation
import SuperConverterCore

/// `DocModel` → HTML5 (formats §3.2 `HTMLWriter`): semantic markup (headings, lists, tables with `thead`, `figure`, footnote
/// section), MathML with the TeX in an annotation, pictures embedded as `data:` URIs or written to a "<name> files" folder.
/// The same markup is what WebKit prints, and what `HTMLReader` reads back.
enum HTMLWriter {
    struct Output {
        var html: String
        /// Pictures to write next to the file when they are not embedded: relative path → bytes.
        var files: [String: Data] = [:]
        var lossNotes: [LossNote] = []
    }

    /// Writes the file, and the pictures folder next to it when the pictures are not embedded.
    static func writeOutput(_ output: Output, options: DocWriteOptions, to url: URL) throws {
        if !output.files.isEmpty {
            let directory = url.deletingLastPathComponent()
            for (path, data) in output.files {
                let target = directory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
            }
        }
        try TextCoding.encode(options.crlf ? output.html.replacingOccurrences(of: "\n", with: "\r\n") : output.html, as: options.encoding).write(to: url, options: .atomic)
    }

    static let style = """
        :root{color-scheme:light dark}body{font:17px/1.55 -apple-system,"Helvetica Neue",Helvetica,Arial,sans-serif;max-width:44em;margin:2.5em auto;padding:0 1.2em}\
        h1,h2,h3,h4,h5,h6{line-height:1.25;margin:1.6em 0 .5em}h1{font-size:1.9em}h2{font-size:1.5em}h3{font-size:1.25em}p{margin:.8em 0}\
        img{max-width:100%;height:auto}figure{margin:1.2em 0;text-align:center}figcaption,caption{font-size:.9em;color:#666;margin:.4em 0}\
        blockquote{margin:1em 0;padding:0 1.2em;border-left:3px solid #bbb;color:#555}pre{background:rgba(127,127,127,.12);padding:.8em 1em;overflow:auto;border-radius:6px}\
        code,pre{font:.9em ui-monospace,Menlo,Consolas,monospace}table{border-collapse:collapse;margin:1.2em 0}th,td{border:1px solid #bbb;padding:.35em .7em;vertical-align:top}\
        th{background:rgba(127,127,127,.12)}hr{border:0;border-top:1px solid #bbb;margin:2em 0}.footnotes{font-size:.9em;border-top:1px solid #bbb;margin-top:2em}\
        .math{overflow-x:auto;text-align:center}sup.fn a{text-decoration:none}@media print{body{max-width:none;margin:0}h1,h2,h3{break-after:avoid}pre,table,figure{break-inside:avoid}}
        """

    /// `titleBlock` off keeps the title in `<title>` only (pages made from a PDF's file name).
    static func render(_ model: DocModel, embedImages: Bool, filesFolder: String, titleBlock: Bool = true) -> Output {
        var writer = Renderer(model: model, embedImages: embedImages, filesFolder: filesFolder, titleBlock: titleBlock)
        return writer.run()
    }

    private struct Renderer {
        let model: DocModel
        let embedImages: Bool
        let filesFolder: String
        let titleBlock: Bool
        var files: [String: Data] = [:]
        var lossNotes: [LossNote] = []
        var footnoteNumbers: [String: Int] = [:]
        var footnoteBodies: [String: [DocBlock]] = [:]
        var fileNames: [String: String] = [:]

        init(model: DocModel, embedImages: Bool, filesFolder: String, titleBlock: Bool) {
            self.model = model; self.embedImages = embedImages; self.filesFolder = filesFolder; self.titleBlock = titleBlock
            for case .footnote(let id, let blocks) in model.blocks { footnoteBodies[id] = blocks }
        }

        mutating func run() -> Output {
            let m = model.metadata
            var head = "<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            head += "<title>\(HTMLEntities.escape(m.title ?? ""))</title>\n"
            if !m.authors.isEmpty { head += "<meta name=\"author\" content=\"\(HTMLEntities.escape(m.authors.joined(separator: "; "), attribute: true))\">\n" }
            if let s = m.summary { head += "<meta name=\"description\" content=\"\(HTMLEntities.escape(s, attribute: true))\">\n" }
            if let d = m.date { head += "<meta name=\"date\" content=\"\(DocDates.string(d))\">\n" }
            head += "<style>\(HTMLWriter.style)</style>\n"
            let lang = m.language.map { " lang=\"\(HTMLEntities.escape($0, attribute: true))\"" } ?? ""
            let html = "<!DOCTYPE html>\n<html\(lang)>\n<head>\n\(head)</head>\n<body>\n<article>\n\(bodyHTML())</article>\n</body>\n</html>\n"
            return Output(html: html, files: files, lossNotes: LossNote.merged(lossNotes))
        }

        mutating func bodyHTML() -> String {
            var body = ""
            let m = model.metadata
            if titleBlock, let title = m.title { body += "<h1 class=\"title\">\(HTMLEntities.escape(title))</h1>\n" }
            if !m.authors.isEmpty { body += "<p class=\"author\">\(HTMLEntities.escape(m.authors.joined(separator: "; ")))</p>\n" }
            if let date = m.date { body += "<p class=\"date\">\(DocDates.string(date))</p>\n" }
            if let summary = m.summary { body += "<p class=\"abstract\">\(HTMLEntities.escape(summary))</p>\n" }
            for block in model.blocks { body += self.block(block) }
            if !footnoteNumbers.isEmpty {
                body += "<section class=\"footnotes\" role=\"doc-endnotes\">\n<ol>\n"
                var done = 0
                while done < footnoteNumbers.count {
                    // Notes may refer to further notes: the dictionary grows while this runs.
                    guard let (id, number) = footnoteNumbers.first(where: { $0.value == done + 1 }) else { break }
                    done += 1
                    var inner = ""
                    for b in footnoteBodies[id] ?? [] { inner += self.block(b) }
                    let back = " <a href=\"#fnref-\(number)\" role=\"doc-backlink\">\u{21A9}\u{FE0E}</a>"
                    if let range = inner.range(of: "</p>", options: .backwards) { inner.replaceSubrange(range, with: back + "</p>") } else { inner += "<p>" + back + "</p>" }
                    body += "<li id=\"fn-\(number)\">\(inner)</li>\n"
                }
                body += "</ol>\n</section>\n"
            }
            return body
        }

        // MARK: Blocks

        mutating func block(_ block: DocBlock) -> String {
            switch block {
            case .heading(let level, let text):
                let n = min(max(level, 1), 6)
                return "<h\(n)>\(inlines(text))</h\(n)>\n"
            case .paragraph(let text, let style):
                return "<p\(paragraphAttributes(style))>\(inlines(text))</p>\n"
            case .list(let ordered, let start, let items):
                var out = ordered ? "<ol\(start != 1 ? " start=\"\(start)\"" : "")>\n" : "<ul>\n"
                for item in items {
                    out += "<li>"
                    let simple = item.count == 1
                    for (i, b) in item.enumerated() {
                        if simple || i == 0, case .paragraph(let text, _) = b { out += inlines(text) + (item.count > 1 ? "\n" : "") }
                        else { out += "\n" + self.block(b) }
                    }
                    out += "</li>\n"
                }
                return out + (ordered ? "</ol>\n" : "</ul>\n")
            case .table(let table): return self.table(table)
            case .figure(let resource, let caption, let alt):
                var out = "<figure>\(img(resource, alt: alt))"
                if let caption { out += "<figcaption>\(inlines(caption))</figcaption>" }
                return out + "</figure>\n"
            case .code(let language, let text):
                let cls = language.map { " class=\"language-\(HTMLEntities.escape($0, attribute: true))\"" } ?? ""
                return "<pre><code\(cls)>\(HTMLEntities.escape(text))</code></pre>\n"
            case .quote(let blocks):
                var out = "<blockquote>\n"
                for b in blocks { out += self.block(b) }
                return out + "</blockquote>\n"
            case .math(let tex, let display):
                return "<div class=\"math\">\(MathML.write(tex: tex, display: display))</div>\n"
            case .footnote: return ""
            case .thematicBreak: return "<hr>\n"
            case .pageBreak: return "<div style=\"page-break-after: always; break-after: page\"></div>\n"
            }
        }

        func paragraphAttributes(_ style: DocParagraphStyle) -> String {
            var css: [String] = []
            switch style.alignment {
            case .start: break
            case .centre: css.append("text-align:center")
            case .end: css.append("text-align:right")
            case .justified: css.append("text-align:justify")
            }
            if let b = style.spaceBefore { css.append("margin-top:\(b)pt") }
            if let a = style.spaceAfter { css.append("margin-bottom:\(a)pt") }
            return css.isEmpty ? "" : " style=\"\(css.joined(separator: ";"))\""
        }

        mutating func table(_ table: DocTable) -> String {
            var out = "<table>\n"
            if let caption = table.caption { out += "<caption>\(inlines(caption))</caption>\n" }
            var bodyStarted = false
            var headOpen = false
            for row in table.rows {
                let isHeader = !row.isEmpty && row.allSatisfy(\.isHeader)
                if isHeader && !bodyStarted && !headOpen { out += "<thead>\n"; headOpen = true }
                if !isHeader && !bodyStarted { if headOpen { out += "</thead>\n"; headOpen = false }; out += "<tbody>\n"; bodyStarted = true }
                out += "<tr>"
                var column = 0
                for cell in row {
                    let tag = cell.isHeader ? "th" : "td"
                    var attrs = ""
                    if cell.columnSpan > 1 { attrs += " colspan=\"\(cell.columnSpan)\"" }
                    if cell.rowSpan > 1 { attrs += " rowspan=\"\(cell.rowSpan)\"" }
                    let alignment = column < table.alignments.count ? table.alignments[column] : .start
                    var content = ""
                    for b in cell.blocks {
                        if case .paragraph(let text, var style) = b {
                            if style.alignment == .start { style.alignment = alignment }
                            if alignment != .start || style.alignment != .start, attrs.contains("style=") == false {
                                switch style.alignment { case .centre: attrs += " style=\"text-align:center\""; case .end: attrs += " style=\"text-align:right\""; case .justified: attrs += " style=\"text-align:justify\""; case .start: break }
                            }
                            content += content.isEmpty ? inlines(text) : "<br>" + inlines(text)
                        } else { content += self.block(b) }
                    }
                    out += "<\(tag)\(attrs)>\(content)</\(tag)>"
                    column += cell.columnSpan
                }
                out += "</tr>\n"
            }
            if headOpen { out += "</thead>\n" }
            if bodyStarted { out += "</tbody>\n" }
            return out + "</table>\n"
        }

        // MARK: Inlines

        mutating func inlines(_ text: DocText) -> String {
            var out = ""
            for inline in text {
                switch inline {
                case .text(let t): out += HTMLEntities.escape(t)
                case .emphasis(let c): out += "<em>\(inlines(c))</em>"
                case .strong(let c): out += "<strong>\(inlines(c))</strong>"
                case .strike(let c): out += "<del>\(inlines(c))</del>"
                case .code(let t): out += "<code>\(HTMLEntities.escape(t))</code>"
                case .link(let c, let destination): out += "<a href=\"\(HTMLEntities.escape(destination, attribute: true))\">\(inlines(c))</a>"
                case .image(let resource, let alt): out += img(resource, alt: alt)
                case .footnoteReference(let id):
                    let number = footnoteNumber(id)
                    out += "<sup class=\"fn\"><a href=\"#fn-\(number)\" id=\"fnref-\(number)\" role=\"doc-noteref\">\(number)</a></sup>"
                case .math(let tex): out += MathML.write(tex: tex, display: false)
                case .styled(let c, let style):
                    var css: [String] = []
                    if let f = style.fontName { css.append("font-family:'\(f)'") }
                    if let s = style.fontSize { css.append("font-size:\(s)pt") }
                    if let colour = style.colour { css.append("color:\(colour)") }
                    if style.underline { css.append("text-decoration:underline") }
                    var inner = inlines(c)
                    if !css.isEmpty { inner = "<span style=\"\(css.joined(separator: ";"))\">\(inner)</span>" }
                    if style.superscript { inner = "<sup>\(inner)</sup>" } else if style.subscripted { inner = "<sub>\(inner)</sub>" }
                    out += inner
                case .lineBreak: out += "<br>"
                }
            }
            return out
        }

        mutating func footnoteNumber(_ id: String) -> Int {
            if let n = footnoteNumbers[id] { return n }
            let n = footnoteNumbers.count + 1
            footnoteNumbers[id] = n
            return n
        }

        mutating func img(_ resource: String, alt: String?) -> String {
            let altAttr = " alt=\"\(HTMLEntities.escape(alt ?? "", attribute: true))\""
            guard let data = model.resources[resource] else {
                // A remote or missing picture keeps its address.
                return "<img src=\"\(HTMLEntities.escape(resource, attribute: true))\"\(altAttr)>"
            }
            let mime = ImageSniff.commonType(data).map(ImageSniff.mime) ?? ImageSniff.mimeForFileName(resource)
            if embedImages {
                return "<img src=\"data:\(mime);base64,\(data.base64EncodedString())\"\(altAttr)>"
            }
            var name = fileNames[resource]
            if name == nil {
                let base = (resource as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_")
                var candidate = base.isEmpty ? "image" : base
                if candidate.hasPrefix(".") { candidate = "image" + candidate }
                while files[filesFolder + "/" + candidate] != nil { candidate = "\(fileNames.count + 1)-" + base }
                name = candidate
                fileNames[resource] = candidate
                files[filesFolder + "/" + candidate] = data
            }
            let href = (filesFolder + "/" + name!).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name!
            return "<img src=\"\(href)\"\(altAttr)>"
        }
    }
}
