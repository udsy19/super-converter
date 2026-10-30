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

    /// Headings as the LaTeX look reads them (quality §3.1): an opening "# Title" becomes `\maketitle`, the shallowest
    /// level `\section` (`\chapter` in a report or book), numbered only when "Numbered sections: auto" would number them.
    static func render(_ model: DocModel, documentClass: String = "article", filesFolder: String = "files") -> Output {
        var r = Renderer(model: model.liftingOpeningTitle(), documentClass: documentClass, filesFolder: filesFolder)
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
        var usesLongtable = false
        var usesLandscape = false
        var usesArray = false
        let sectionLevel: Int
        let star: String

        static let babel: [String: String] = ["en": "english", "de": "ngerman", "fr": "french", "es": "spanish", "it": "italian", "nl": "dutch", "pt": "portuguese", "sv": "swedish", "da": "danish", "fi": "finnish", "pl": "polish", "cs": "czech"]

        init(model: DocModel, documentClass: String, filesFolder: String) {
            self.model = model; self.documentClass = ["article", "report", "book"].contains(documentClass) ? documentClass : "article"; self.filesFolder = filesFolder
            sectionLevel = model.sectionLevel
            star = model.numbersSectionsByDefault ? "" : "*"
            for case .footnote(let id, let blocks) in model.blocks { footnoteBodies[id] = blocks }
        }

        mutating func run() -> Output {
            // Display math belongs to the paragraphs around it, as TypesetKit sets it: no blank line on either side (one
            // before `\[` leaves an empty line above the formula, one after starts a new, indented paragraph).
            var body: [String] = []
            var previous: DocBlock?
            for block in model.blocks {
                guard let s = self.block(block) else { continue }
                switch (previous, block) {
                case (.paragraph?, .math), (.math?, .paragraph): body[body.count - 1] += "\n" + s
                default: body.append(s)
                }
                previous = block
            }
            let m = model.metadata
            // pdfLaTeX gets Latin Modern through T1 and lmodern; XeTeX and LuaTeX (Tectonic is XeTeX) the same design as
            // OpenType through fontspec's default, which also has every character an 8-bit T1 font lacks (ł, ’, Greek).
            var preamble = ["\\documentclass{\(documentClass)}", "\\usepackage{iftex}",
                            "\\ifPDFTeX\n\\usepackage[T1]{fontenc}\n\\usepackage[utf8]{inputenc}\n\\usepackage{lmodern}\n\\else\n\\usepackage{fontspec}\n\\fi", "\\usepackage{microtype}",
                            "\\usepackage{amsmath,amssymb}", "\\usepackage{booktabs}", "\\usepackage{graphicx}"]
            if let lang = m.language?.split(separator: "-").first.map(String.init), let name = Self.babel[lang.lowercased()] { preamble.append("\\usepackage[\(name)]{babel}") }
            if usesArray { preamble.append("\\usepackage{array}") }
            if usesLongtable { preamble.append("\\usepackage{longtable}") }
            if usesLandscape { preamble += ["\\usepackage{pdflscape}", "\\usepackage{afterpage}"] }
            if usesStrike { preamble.append("\\usepackage[normalem]{ulem}") }
            if usesColour { preamble.append("\\usepackage{xcolor}") }
            preamble.append("\\usepackage{hyperref}")
            // TeX's third pass instead of an overfull line, as TypesetKit's emergency pass (quality §3.3).
            preamble.append("\\setlength{\\emergencystretch}{3em}")
            if let t = m.title { preamble.append("\\title{\(LaTeXWriter.escape(t))}") }
            if !m.authors.isEmpty { preamble.append("\\author{\(m.authors.map(LaTeXWriter.escape).joined(separator: " \\and "))}") }
            if let d = m.longDate { preamble.append("\\date{\(LaTeXWriter.escape(d))}") } else if m.title != nil { preamble.append("\\date{}") }
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
                return "\\\(names[min(max(level - sectionLevel, 0), 5)])\(star){\(inline(text))}"
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
            case .table(let table): return self.table(table, depth: depth)
            case .figure(let resource, let caption, let alt):
                guard let path = picture(resource) else {
                    lossNotes.append(LossNote(.imagesDropped, detail: resource))
                    return alt.map { "[\(LaTeXWriter.escape($0))]" }
                }
                var out = "\\begin{figure}[tbp]\n\\centering\n\\includegraphics[width=\\linewidth,height=0.6\\textheight,keepaspectratio]{\(path)}"
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

        /// Booktabs tables fitted to the text block as TypesetKit fits them (Core's `TableFit`, quality §3.3): a table too
        /// wide steps down to `\small`, then `\footnotesize`; a table of figures and short labels then goes on landscape
        /// pages of its own (`pdflscape`, split with the header repeated); one with sentences in its cells gets `p{}`
        /// columns as wide as TypesetKit wraps them.
        mutating func table(_ table: DocTable, depth: Int) -> String? {
            let (columns, rows) = TableGrid.expand(table)
            guard !rows.isEmpty else { return nil }
            var rowSpanned = false
            var alignments = (0..<columns).map { c -> String in
                switch c < table.alignments.count ? table.alignments[c] : .start { case .centre: "c"; case .end: "r"; default: "l" }
            }
            var rowLines: [String] = []
            for row in rows {
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
                rowLines.append(cells.joined(separator: " & ") + " \\\\")
            }
            if rowSpanned { lossNotes.append(LossNote(.tableSimplified, detail: "merged cells")) }
            let fit = self.fit(table, columns: columns, rows: rows, depth: depth)
            if let fit, fit.wrap {
                // Columns narrower than their contents wrap, ragged as TypesetKit sets them.
                usesArray = true
                let natural = Self.columns(columns, rows, fit.size).natural
                for j in 0..<columns where fit.widths[j] < natural[j] - 0.01 {
                    let ragged = alignments[j] == "c" ? "\\centering" : alignments[j] == "r" ? "\\raggedleft" : "\\raggedright"
                    alignments[j] = ">{\(ragged)\\arraybackslash}p{\(String(format: "%.2f", fit.widths[j]))pt}"
                }
            }
            let spec = alignments.joined()
            let size = switch fit?.size { case .small?: "\\small"; case .footnote?: "\\footnotesize"; default: "" }
            let headers = max(table.rows.prefix { !$0.isEmpty && $0.allSatisfy(\.isHeader) }.count, 1)
            let head = ["\\toprule"] + rowLines.prefix(headers) + ["\\midrule"]
            let body = Array(rowLines.dropFirst(headers))
            if fit?.landscape == true {
                // Landscape pages of their own after this one, the text going on around them (as a float page would):
                // the caption on the first, the header and the closing rule on every one.
                usesLongtable = true; usesLandscape = true
                var lines = ["\\begin{longtable}{\(spec)}"]
                if let caption = table.caption { lines += ["\\caption{\(inline(caption))}\\\\"] + head + ["\\endfirsthead"] }
                lines += head + ["\\endhead", "\\bottomrule", "\\endfoot", "\\bottomrule", "\\endlastfoot"] + body + ["\\end{longtable}"]
                if table.caption == nil { lines.append(Self.unnumbered) }
                return "\\afterpage{\\begin{landscape}\(size.isEmpty ? "" : "\n" + size)\n" + lines.joined(separator: "\n") + "\n\\end{landscape}}"
            }
            // A captioned table floats as a `tabular`; any other stays in the text as a `longtable`, which breaks across
            // pages with its header repeated (as TypesetKit sets both).
            guard let caption = table.caption else {
                usesLongtable = true
                let out = (["\\begin{longtable}{\(spec)}"] + head + ["\\endhead", "\\bottomrule", "\\endlastfoot"] + body + ["\\end{longtable}", Self.unnumbered]).joined(separator: "\n")
                return size.isEmpty ? out : "\\begingroup\(size)\n\(out)\n\\endgroup"
            }
            let out = (["\\begin{tabular}{\(spec)}"] + head + body + ["\\bottomrule", "\\end{tabular}"]).joined(separator: "\n")
            return "\\begin{table}[tbp]\n\\centering\n\\caption{\(inline(caption))}\n\(size.isEmpty ? "" : size + "\n")\(out)\n\\end{table}"
        }

        /// Every `longtable` steps the table counter; one without a caption gives its number back, so captioned tables
        /// are numbered as TypesetKit numbers them.
        static let unnumbered = "\\addtocounter{table}{-1}"

        /// The table's `TableFit` in the text block (narrowed by the lists it is in); nil without the bundled fonts to
        /// measure with. Only a table of the main text may turn.
        func fit(_ table: DocTable, columns: Int, rows: [[TableGrid.Slot]], depth: Int) -> TableFit? {
            guard LaTeXTableMetrics.available else { return nil }
            let indent = LaTeXTableMetrics.listMargins.prefix(depth).reduce(0, +)
            let prose = table.rows.contains { $0.contains { TableFit.isProse(LaTeXTableMetrics.text($0)) } }
            return TableFit.plan(textWidth: LaTeXTableMetrics.textWidth - indent, landscapeWidth: depth == 0 ? LaTeXTableMetrics.textHeight : nil,
                                 prose: prose) { Self.columns(columns, rows, $0) }
        }

        /// Each column's widths at `size`, from the cells that do not span columns.
        static func columns(_ count: Int, _ rows: [[TableGrid.Slot]], _ size: TableFit.Size) -> TableFit.Columns {
            var natural = [Double](repeating: 0, count: count), minimum = natural
            for row in rows {
                for (j, slot) in row.enumerated() {
                    guard let cell = slot.cell, cell.columnSpan <= 1 else { continue }
                    let m = LaTeXTableMetrics.measure(cell, size)
                    natural[j] = max(natural[j], m.natural); minimum[j] = max(minimum[j], m.minimum)
                }
            }
            return TableFit.Columns(natural: natural, minimum: minimum)
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
                    // A link that shows its own address is \url (typewriter, breaking after slashes and dots).
                    let shown = c.plainText
                    if destination.hasPrefix("#") { out += inline(c) }
                    else if shown == destination { out += "\\url{\(destination)}" }
                    else if "mailto:" + shown == destination { out += "\\href{\(Self.url(destination))}{\\nolinkurl{\(shown)}}" }
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
