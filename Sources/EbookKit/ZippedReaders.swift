import Foundation
import SuperConverterCore

/// Unpacks an archive into a folder with the app's archive engine (libarchive or the bundled 7zz). EbookKit does not import
/// ArchiveKit or start processes itself (ARCHITECTURE §4); the app hands this in through `EbookKitModule.install`.
public typealias ArchiveExtractor = @Sendable (_ archive: URL, _ destination: URL) async throws -> Void

/// The metadata and cover a calibre-style ZIP (HTMLZ, TXTZ) keeps in `metadata.opf`.
private func zipMetadata(_ files: ContainerFiles) -> (DocMetadata, coverPath: String?) {
    guard let opfPath = files.paths.first(where: { $0.lowercased() == "metadata.opf" }) ?? files.paths.first(where: { $0.lowercased().hasSuffix(".opf") }),
          let data = files.read(opfPath) else { return (DocMetadata(), nil) }
    let doc = MarkupParser.parse(TextDecoding.string(from: data), html: false, lowercase: true)
    guard let package = doc.descendant("package") else { return (DocMetadata(), nil) }
    var cover: String?
    if let ref = package.first("guide")?.elements(named: "reference").first(where: { $0.attribute("type")?.lowercased().contains("cover") == true }),
       let href = ref.attribute("href") { cover = PackagePath.resolve(href, against: opfPath) }
    if cover == nil, let id = package.descendants("meta").first(where: { $0.attribute("name") == "cover" })?.attribute("content"),
       let item = package.first("manifest")?.elements(named: "item").first(where: { $0.attribute("id") == id }), let href = item.attribute("href") {
        cover = PackagePath.resolve(href, against: opfPath)
    }
    return (PackageReader.metadata(from: package), cover)
}

private func openZip(_ url: URL, _ format: FormatID) throws -> (ZipArchive, ContainerFiles) {
    do {
        let zip = try ZipArchive(url: url)
        return (zip, ContainerFiles(zip: zip))
    } catch ZipError.encrypted { throw ConversionError.passwordRequired(format) }
    catch { throw ConversionError.damaged(format) }
}

/// Builds a one-document publication (HTMLZ, TXTZ) with the pictures the document uses and a cover when the package has one.
private func singleDocument(_ blocks: [DocBlock], resources: [String: Data], metadata: DocMetadata, coverPath: String?, files: ContainerFiles,
                            fallbackTitle: String) -> Publication {
    var meta = metadata
    if meta.title == nil { meta.title = fallbackTitle }
    var publication = PublicationBuilder.publication(from: DocModel(metadata: meta, blocks: blocks, resources: resources))
    if let coverPath, let data = files.read(coverPath), MediaTypes.isImage(MediaTypes.forImage(data, name: coverPath)) {
        publication.resources["cover"] = PublicationResource(mediaType: MediaTypes.forImage(data, name: coverPath), data: data)
        publication.cover = "cover"
    }
    return publication
}

/// HTMLZ (a ZIP with `index.html`, its pictures and `metadata.opf`) → Publication.
public enum HTMLZReader {
    public static func read(url: URL) throws -> PublicationRead {
        let (_, files) = try openZip(url, "htmlz")
        let candidates = files.paths.filter { ["html", "htm", "xhtml"].contains(($0 as NSString).pathExtension.lowercased()) }
        guard let page = candidates.first(where: { $0.lowercased() == "index.html" }) ?? candidates.sorted(by: { $0.count < $1.count }).first,
              let data = files.read(page) else { throw ConversionError.damaged("htmlz") }
        let (metadata, coverPath) = zipMetadata(files)
        let markup = MarkupParser.parse(TextDecoding.string(from: data), html: true)
        let reader = ContentReader(
            documentPath: page, footnotePrefix: "n-",
            images: { path in files.read(path).map { (path, $0) } },
            links: { _ in nil })
        let blocks = reader.blocks(of: markup)
        var meta = metadata
        if meta.title == nil { meta.title = markup.descendant("title")?.plainText.nonEmpty }
        let stem = ((url.lastPathComponent as NSString).deletingPathExtension)
        let publication = singleDocument(blocks, resources: reader.resources, metadata: meta, coverPath: coverPath, files: files, fallbackTitle: stem)
        guard !blocks.isEmpty else { throw ConversionError.damaged("htmlz") }
        return PublicationRead(publication, lossNotes: PublicationRead.notes(reader.losses))
    }
}

/// TXTZ (a ZIP with `index.txt`, its pictures and `metadata.opf`) → Publication. The text is read as light Markdown, which is
/// what calibre writes by default and is harmless for plain text.
public enum TXTZReader {
    public static func read(url: URL) throws -> PublicationRead {
        let (_, files) = try openZip(url, "txtz")
        let candidates = files.paths.filter { ($0 as NSString).pathExtension.lowercased() == "txt" }
        guard let page = candidates.first(where: { $0.lowercased() == "index.txt" }) ?? candidates.sorted(by: { $0.count < $1.count }).first,
              let data = files.read(page) else { throw ConversionError.damaged("txtz") }
        let (metadata, coverPath) = zipMetadata(files)
        var resources: [String: Data] = [:]
        let blocks = LightMarkdown.blocks(from: TextDecoding.string(from: data)) { src in
            guard !PackagePath.isExternal(src) else { return nil }
            let path = PackagePath.resolve(src, against: page)
            guard let image = files.read(path) else { return nil }
            resources[path] = image
            return path
        }
        guard !blocks.isEmpty else { throw ConversionError.damaged("txtz") }
        let stem = ((url.lastPathComponent as NSString).deletingPathExtension)
        let publication = singleDocument(blocks, resources: resources, metadata: metadata, coverPath: coverPath, files: files, fallbackTitle: stem)
        return PublicationRead(publication)
    }
}

/// The small slice of Markdown e-book text files use: headings, rules, lists, quotes, pictures, emphasis, code, links.
enum LightMarkdown {
    static func blocks(from text: String, image: (String) -> String?) -> [DocBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var out: [DocBlock] = []
        var paragraph: [String] = []
        var list: (ordered: Bool, start: Int, items: [[DocBlock]])?
        var quote: [String] = []
        var fence: (language: String?, lines: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            paragraph = []
            let inlines = ContentReader.normalise(inlineText(joined, image: image))
            if inlines.count == 1, case .image(let r, let alt) = inlines[0] { out.append(.figure(resource: r, caption: nil, altText: alt)) }
            else if !inlines.isEmpty { out.append(.paragraph(inlines, DocParagraphStyle())) }
        }
        func flushList() { if let l = list { out.append(.list(ordered: l.ordered, start: l.start, items: l.items)); list = nil } }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            let inner = blocks(from: quote.joined(separator: "\n"), image: image)
            quote = []
            if !inner.isEmpty { out.append(.quote(inner)) }
        }
        func flushAll() { flushParagraph(); flushList(); flushQuote() }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            i += 1
            if var f = fence {
                if trimmed.hasPrefix("```") { out.append(.code(language: f.language, text: f.lines.joined(separator: "\n"))); fence = nil }
                else { f.lines.append(line); fence = f }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushAll()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                fence = (lang.isEmpty ? nil : lang, [])
                continue
            }
            if trimmed.isEmpty { flushAll(); continue }
            if trimmed.hasPrefix(">") { flushParagraph(); flushList(); quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .init(charactersIn: " "))); continue }
            flushQuote()
            if let h = heading(trimmed) {
                flushAll()
                let t = ContentReader.normalise(inlineText(h.text, image: image))
                if !t.isEmpty { out.append(.heading(level: h.level, t)) }
                continue
            }
            if i < lines.count, !trimmed.isEmpty, paragraph.isEmpty {   // setext heading
                let under = lines[i].trimmingCharacters(in: .whitespaces)
                if under.count >= 3, Set(under) == ["="] || Set(under) == ["-"] {
                    flushList()
                    let t = ContentReader.normalise(inlineText(trimmed, image: image))
                    if !t.isEmpty { out.append(.heading(level: under.hasPrefix("=") ? 1 : 2, t)) }
                    i += 1
                    continue
                }
            }
            if trimmed.count >= 3, Set(trimmed.filter { $0 != " " }).count == 1, ["-", "*", "_"].contains(String(trimmed.first!)) {
                flushAll(); out.append(.thematicBreak); continue
            }
            if let item = listItem(trimmed) {
                flushParagraph()
                if list == nil || list!.ordered != item.ordered { flushList(); list = (item.ordered, item.number, []) }
                let t = ContentReader.normalise(inlineText(item.text, image: image))
                list!.items.append(t.isEmpty ? [] : [.paragraph(t, DocParagraphStyle())])
                continue
            }
            flushList()
            paragraph.append(line)
        }
        if let f = fence { out.append(.code(language: f.language, text: f.lines.joined(separator: "\n"))) }
        flushAll()
        return out
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func listItem(_ line: String) -> (ordered: Bool, number: Int, text: String)? {
        if let first = line.first, "-*+".contains(first), line.dropFirst().first == " " {
            return (false, 1, String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count < 6, let n = Int(digits), line.dropFirst(digits.count).hasPrefix(". ") {
            return (true, n, String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    /// `**strong**`, `*emphasis*`/`_emphasis_`, `` `code` ``, `[text](url)`, `![alt](path)`.
    static func inlineText(_ s: String, image: (String) -> String?) -> DocText {
        let chars = Array(s)
        var out: DocText = []
        var buffer = ""
        func flush() { if !buffer.isEmpty { out.append(.text(buffer)); buffer = "" } }
        func find(_ marker: [Character], from: Int) -> Int? {
            var j = from
            while j + marker.count <= chars.count {
                if Array(chars[j..<j + marker.count]) == marker { return j }
                j += 1
            }
            return nil
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, "*_`[]()#\\".contains(chars[i + 1]) { buffer.append(chars[i + 1]); i += 2; continue }
            if c == "!", i + 1 < chars.count, chars[i + 1] == "[", let close = find(["]", "("], from: i + 2), let end = find([")"], from: close + 2) {
                let alt = String(chars[(i + 2)..<close]), src = String(chars[(close + 2)..<end])
                flush()
                if let key = image(src) { out.append(.image(resource: key, altText: alt.isEmpty ? nil : alt)) } else if !alt.isEmpty { out.append(.text(alt)) }
                i = end + 1; continue
            }
            if c == "[", let close = find(["]", "("], from: i + 1), let end = find([")"], from: close + 2) {
                let label = String(chars[(i + 1)..<close]), href = String(chars[(close + 2)..<end])
                flush()
                let inner = inlineText(label, image: image)
                if PackagePath.isExternal(href) { out.append(.link(inner, destination: href)) } else { out += inner }
                i = end + 1; continue
            }
            if c == "`", let end = find(["`"], from: i + 1), end > i + 1 { flush(); out.append(.code(String(chars[(i + 1)..<end]))); i = end + 1; continue }
            if (c == "*" || c == "_"), i + 1 < chars.count, chars[i + 1] == c, let end = find([c, c], from: i + 2), end > i + 2,
               chars[i + 2] != " ", chars[end - 1] != " " {
                flush(); out.append(.strong(inlineText(String(chars[(i + 2)..<end]), image: image))); i = end + 2; continue
            }
            if c == "*" || c == "_", i + 1 < chars.count, chars[i + 1] != " ", chars[i + 1] != c,
               i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber), let end = find([c], from: i + 1), end > i + 1, chars[end - 1] != " ",
               end + 1 >= chars.count || !(chars[end + 1].isLetter || chars[end + 1].isNumber) {
                flush(); out.append(.emphasis(inlineText(String(chars[(i + 1)..<end]), image: image))); i = end + 1; continue
            }
            buffer.append(c); i += 1
        }
        flush()
        return out
    }
}
