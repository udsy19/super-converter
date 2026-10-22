import Foundation
import SuperConverterCore

/// `DocModel` → LaTeX (formats §3.2 `LaTeXWriter`): article, report or book with `lmodern`, `microtype`, `booktabs` and
/// `hyperref`. This is what the quality bench compiles with Tectonic to make the LaTeX goldens (quality §3.7), so it writes
/// plain, conventional LaTeX: `\\section`, `itemize`, `booktabs` tables, `figure` floats with captions, `\\footnote`.
/// Pictures go to a "<name> files" folder next to the .tex.
enum LaTeXWriter {
    struct Output {
        var tex: String
        var files: [String: Data]
        var lossNotes: [LossNote]
    }

    static func write(_ model: DocModel, options: DocWriteOptions, to url: URL) throws -> [LossNote] {
        let folder = url.deletingPathExtension().lastPathComponent + " files"
        let output = render(model, documentClass: options.latexClass, filesFolder: folder)
        for (path, data) in output.files {
            let target = url.deletingLastPathComponent().appendingPathComponent(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
        try TextCoding.encode(options.crlf ? output.tex.replacingOccurrences(of: "\n", with: "\r\n") : output.tex, as: options.encoding).write(to: url, options: .atomic)
        return output.lossNotes
    }

    static func render(_ model: DocModel, documentClass: String = "article", filesFolder: String = "files") -> Output {
        var r = Renderer(model: model, documentClass: documentClass, filesFolder: filesFolder)
        return r.run()
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\textbackslash{}"
            case "{", "}", "$", "&", "#", "_", "%": out += "\\" + String(c)
            case "^": out += "\\textasciicircum{}"
            case "~": out += "\\textasciitilde{}"
            case "<": out += "\\textless{}"
            case ">": out += "\\textgreater{}"
            case "|": out += "\\textbar{}"
            case "\u{A0}": out += "~"
            default: out.append(c)
            }
        }
        return out
    }

    private struct Renderer {
        let model: DocModel
        let documentClass: String
        let filesFolder: String
        var lossNotes: [LossNote] = []
        var footnoteBodies: [String: [DocBlock]] = [:]
        var files: [String: Data] = [:]
        var fileNames: [String: String] = [:]
        var usesColour = false
        var usesStrike = false

        static let babel: [String: String] = ["en": "english", "de": "ngerman", "fr": "french", "es": "spanish", "it": "italian", "nl": "dutch", "pt": "portuguese", "sv": "swedish", "da": "danish", "fi": "finnish", "pl": "polish", "cs": "czech"]

        init(model: DocModel, documentClass: String, filesFolder: String) {
            self.model = model; self.documentClass = ["article", "report", "book"].contains(documentClass) ? documentClass : "article"; self.filesFolder = filesFolder
            for case .footnote(let id, let blocks) in model.blocks { footnoteBodies[id] = blocks }
        }

        mutating func run() -> Output {
            var body: [String] = []
            for block in model.blocks { if let s = self.block(block) { body.append(s) } }
            let m = model.metadata
            var preamble = ["\\documentclass[11pt]{\(documentClass)}", "\\usepackage[T1]{fontenc}", "\\usepackage[utf8]{inputenc}", "\\usepackage{lmodern}", "\\usepackage{microtype}",
                            "\\usepackage{amsmath,amssymb}", "\\usepackage{booktabs}", "\\usepackage{graphicx}"]
            if let lang = m.language?.split(separator: "-").first.map(String.init), let name = Self.babel[lang.lowercased()] { preamble.append("\\usepackage[\(name)]{babel}") }
            if usesStrike { preamble.append("\\usepackage[normalem]{ulem}") }
            if usesColour { preamble.append("\\usepackage{xcolor}") }
            preamble.append("\\usepackage{hyperref}")
            if let t = m.title { preamble.append("\\title{\(LaTeXWriter.escape(t))}") }
            if !m.authors.isEmpty { preamble.append("\\author{\(m.authors.map(LaTeXWriter.escape).joined(separator: " \\and "))}") }
            if let d = m.date { preamble.append("\\date{\(DocDates.string(d))}") } else if m.title != nil { preamble.append("\\date{}") }
            var doc = ["\\begin{document}"]
            if m.title != nil || !m.authors.isEmpty { doc.append("\\maketitle") }
            if let s = m.summary { doc.append("\\begin{abstract}\n\(LaTeXWriter.escape(s))\n\\end{abstract}") }
            doc += body
            doc.append("\\end{document}")
            return Output(tex: preamble.joined(separator: "\n") + "\n\n" + doc.joined(separator: "\n\n") + "\n", files: files, lossNotes: LossNote.merged(lossNotes))
        }

        // MARK: Blocks

        mutating func block(_ block: DocBlock, depth: Int = 0) -> String? {
            switch block {
            case .heading(let level, let text):
                let names = documentClass == "article" ? ["section", "subsection", "subsubsection", "paragraph", "subparagraph", "subparagraph"]
                                                       : ["chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph"]
                return "\\\(names[min(max(level, 1), 6) - 1]){\(inline(text))}"
            case .paragraph(let text, let style):
                let s = inline(text)
                if s.isEmpty { return nil }
                switch style.alignment {
                case .centre: return "\\begin{center}\n\(s)\n\\end{center}"
                case .end: return "\\begin{flushright}\n\(s)\n\\end{flushright}"
                default: return s
                }
            case .list(let ordered, let start, let items):
                let env = ordered ? "enumerate" : "itemize"
                var out = "\\begin{\(env)}"
                if ordered && start != 1 { out += "\n\\setcounter{enumi}{\(start - 1)}" }
                for item in items {
                    var body = ""
                    for child in item { if let part = self.block(child, depth: depth + 1) { body += body.isEmpty ? part : "\n\n" + part } }
                    out += "\n\\item " + body
                }
                return out + "\n\\end{\(env)}"
            case .table(let table): return self.table(table)
            case .figure(let resource, let caption, let alt):
                guard let path = picture(resource) else {
                    lossNotes.append(LossNote(.imagesDropped, detail: resource))
                    return alt.map { "[\(LaTeXWriter.escape($0))]" }
                }
                var out = "\\begin{figure}[htbp]\n\\centering\n\\includegraphics[width=\\linewidth,height=0.6\\textheight,keepaspectratio]{\(path)}"
                if let caption { out += "\n\\caption{\(inline(caption))}" }
                return out + "\n\\end{figure}"
            case .code(_, let text):
                return "\\begin{verbatim}\n\(text.replacingOccurrences(of: "\\end{verbatim}", with: "\\ end{verbatim}"))\n\\end{verbatim}"
            case .quote(let blocks):
                return "\\begin{quote}\n" + blocks.compactMap { self.block($0, depth: depth) }.joined(separator: "\n\n") + "\n\\end{quote}"
            case .math(let tex, _): return "\\[\n\(tex)\n\\]"
            case .footnote: return nil
            case .thematicBreak: return "\\par\\medskip\\noindent\\rule{\\linewidth}{0.4pt}\\par\\medskip"
            case .pageBreak: return "\\newpage"
            }
        }

        mutating func picture(_ resource: String) -> String? {
            guard let data = model.resources[resource] else { return nil }
            if let name = fileNames[resource] { return name }
            guard let prepared = ImageSniff.prepare(data) else { return nil }
            let ext = prepared.type == "jpeg" ? "jpg" : prepared.type
            let path = "\(filesFolder)/image\(fileNames.count + 1).\(ext)"
            files[path] = prepared.data
            fileNames[resource] = path
            return path
        }

        mutating func table(_ table: DocTable) -> String? {
            let (columns, rows) = TableGrid.expand(table)
            guard !rows.isEmpty else { return nil }
            var rowSpanned = false
            let spec = (0..<columns).map { c -> String in
                switch c < table.alignments.count ? table.alignments[c] : .start { case .centre: "c"; case .end: "r"; default: "l" }
            }.joined()
            var lines = ["\\begin{tabular}{\(spec)}", "\\toprule"]
            let headers = table.rows.prefix { !$0.isEmpty && $0.allSatisfy(\.isHeader) }.count
            for (r, row) in rows.enumerated() {
                var cells: [String] = []
                var c = 0
                while c < columns {
                    let slot = row[c]
                    var span = 1
                    if let cell = slot.cell {
                        span = min(cell.columnSpan, columns - c)
                        if cell.rowSpan > 1 { rowSpanned = true }
                        let text = cell.blocks.compactMap { b -> String? in
                            if case .paragraph(let t, _) = b { return inline(t) }
                            return self.block(b)
                        }.joined(separator: " \\newline ")
                        cells.append(span > 1 ? "\\multicolumn{\(span)}{c}{\(text)}" : text)
                    } else { cells.append("") }
                    c += span
                }
                lines.append(cells.joined(separator: " & ") + " \\\\")
                if r == max(headers, 1) - 1 { lines.append("\\midrule") }
            }
            lines += ["\\bottomrule", "\\end{tabular}"]
            if rowSpanned { lossNotes.append(LossNote(.tableSimplified, detail: "merged cells")) }
            var out = lines.joined(separator: "\n")
            if let caption = table.caption {
                out = "\\begin{table}[htbp]\n\\centering\n\\caption{\(inline(caption))}\n\(out)\n\\end{table}"
            } else {
                out = "\\begin{center}\n\(out)\n\\end{center}"
            }
            return out
        }

        // MARK: Inlines

        mutating func inline(_ text: DocText) -> String {
            var out = ""
            for item in text {
                switch item {
                case .text(let t): out += LaTeXWriter.escape(t)
                case .emphasis(let c): out += "\\emph{\(inline(c))}"
                case .strong(let c): out += "\\textbf{\(inline(c))}"
                case .strike(let c): usesStrike = true; out += "\\sout{\(inline(c))}"
                case .code(let t): out += "\\texttt{\(LaTeXWriter.escape(t))}"
                case .link(let c, let destination):
                    if destination.hasPrefix("#") { out += inline(c) }
                    else { out += "\\href{\(Self.url(destination))}{\(inline(c))}" }
                case .image(let resource, _):
                    if let path = picture(resource) { out += "\\includegraphics[height=1em]{\(path)}" } else { lossNotes.append(LossNote(.imagesDropped, detail: resource)) }
                case .footnoteReference(let id):
                    var body = ""
                    for b in footnoteBodies[id] ?? [] { if let s = self.block(b) { body += body.isEmpty ? s : "\n\n" + s } }
                    out += "\\footnote{\(body)}"
                case .math(let tex): out += "$\(tex)$"
                case .styled(let c, let style):
                    var inner = inline(c)
                    if let colour = style.colour { usesColour = true; inner = "\\textcolor[HTML]{\(colour.replacingOccurrences(of: "#", with: ""))}{\(inner)}" }
                    if style.underline { inner = "\\underline{\(inner)}" }
                    if style.superscript { inner = "\\textsuperscript{\(inner)}" } else if style.subscripted { inner = "\\textsubscript{\(inner)}" }
                    out += inner
                case .lineBreak: out += "\\newline\n"
                }
            }
            return out
        }

        static func url(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "#", with: "\\#").replacingOccurrences(of: "&", with: "\\&")
        }
    }
}
