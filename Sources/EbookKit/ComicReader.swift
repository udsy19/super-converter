import Foundation
import SuperConverterCore

/// CBZ, CBR and CBC → fixed-layout Publication. Pages keep their bytes (never recompressed); only picture types an e-book
/// cannot hold (BMP, TIFF) are re-encoded as PNG.
public enum ComicReader {
    static let pageExtensions: Set<String> = ["png", "jpg", "jpeg", "jpe", "gif", "webp", "avif", "bmp", "tif", "tiff"]
    private static let corePictureTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]

    /// - Parameter extractor: unpacks RAR/7z-based comics; ZIP comics (the usual case, whatever the extension) need none.
    public static func read(url: URL, format: FormatID, workFolder: URL, extractor: ArchiveExtractor?,
                            progress: (Double) -> Void = { _ in }) async throws -> PublicationRead {
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        if let zip = try? ZipArchive(url: url) {
            let files = ContainerFiles(zip: zip)
            return try build(from: files, stem: stem, format: format, progress: progress)
        }
        guard let extractor else {
            throw ConversionError.failed("This comic needs the archive engine, which isn’t available.")
        }
        let folder = workFolder.appendingPathComponent("comic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await extractor(url, folder)
        return try build(from: ContainerFiles(directory: folder), stem: stem, format: format, progress: progress)
    }

    static func build(from files: ContainerFiles, stem: String, format: FormatID, progress: (Double) -> Void) throws -> PublicationRead {
        var spine: [PublicationItem] = []
        var resources: [String: PublicationResource] = [:]
        var contents: [ContentsEntry] = []
        var metadata = DocMetadata(title: stem)
        var direction = Publication.Direction.leftToRight
        var warnings: [String] = []

        func isPage(_ path: String) -> Bool {
            let parts = path.split(separator: "/")
            guard let name = parts.last, !name.hasPrefix("."), !parts.contains("__MACOSX") else { return false }
            return pageExtensions.contains((path as NSString).pathExtension.lowercased())
        }
        func addPages(_ paths: [String], read: (String) -> Data?, title: String?) {
            var first: String?
            for path in paths.sorted(by: naturalLess) {
                guard var data = read(path) else { continue }
                var type = MediaTypes.forImage(data, name: path)
                if !corePictureTypes.contains(type) {
                    guard let png = PackageWriter.transcodeToPNG(data) else { warnings.append("Skipped a page that couldn’t be read: \(path)"); continue }
                    data = png; type = "image/png"
                }
                let id = String(format: "p%04d", spine.count + 1)
                resources[id] = PublicationResource(mediaType: type, data: data)
                spine.append(PublicationItem(id: id, content: .page(resource: id)))
                if first == nil { first = id }
            }
            if let first, let title, !title.isEmpty { contents.append(ContentsEntry(title: title, itemID: first)) }
        }

        let collection = files.paths.filter { ($0 as NSString).pathExtension.lowercased() == "cbz" }
        if !collection.isEmpty {   // a CBC: CBZ files and a comics.txt that names them
            var titles: [String: String] = [:]
            if let listing = files.paths.first(where: { $0.lowercased() == "comics.txt" }), let data = files.read(listing) {
                for line in TextDecoding.string(from: data).split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2 { titles[parts[0].lowercased()] = parts[1] }
                }
            }
            var ordered = collection
            if let listing = files.paths.first(where: { $0.lowercased() == "comics.txt" }), let data = files.read(listing) {
                let order = TextDecoding.string(from: data).split(whereSeparator: \.isNewline).compactMap { $0.split(separator: ":", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } }
                ordered.sort { (order.firstIndex(of: ($0 as NSString).lastPathComponent.lowercased()) ?? .max) < (order.firstIndex(of: ($1 as NSString).lastPathComponent.lowercased()) ?? .max) }
            }
            for (n, path) in ordered.enumerated() {
                progress(Double(n) / Double(max(1, ordered.count)))
                guard let data = files.read(path), let inner = try? ZipArchive(data: data) else { continue }
                let innerFiles = ContainerFiles(zip: inner)
                let name = (path as NSString).lastPathComponent
                let title = titles[name.lowercased()] ?? (name as NSString).deletingPathExtension
                addPages(innerFiles.paths.filter(isPage), read: innerFiles.read, title: title)
            }
        } else {
            let pages = files.paths.filter(isPage)
            if let info = files.paths.first(where: { ($0 as NSString).lastPathComponent.lowercased() == "comicinfo.xml" }), let data = files.read(info) {
                let doc = MarkupParser.parse(TextDecoding.string(from: data), html: false, lowercase: true)
                if let info = doc.descendant("comicinfo") {
                    let series = info.first("series")?.plainText.nonEmpty, number = info.first("number")?.plainText.nonEmpty
                    metadata.title = info.first("title")?.plainText.nonEmpty ?? [series, number.map { "#" + $0 }].compactMap { $0 }.joined(separator: " ").nonEmpty ?? stem
                    metadata.authors = (info.first("writer")?.plainText ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    metadata.language = info.first("languageiso")?.plainText.nonEmpty
                    metadata.summary = info.first("summary")?.plainText.nonEmpty
                    if let year = Int(info.first("year")?.plainText ?? "") {
                        metadata.date = Date.fromBookDate(String(format: "%04d-%02d-%02d", year, Int(info.first("month")?.plainText ?? "") ?? 1, Int(info.first("day")?.plainText ?? "") ?? 1))
                    }
                    if info.first("manga")?.plainText.lowercased() == "yesandrighttoleft" { direction = .rightToLeft }
                }
            }
            addPages(pages, read: files.read, title: nil)
            progress(1)
        }
        guard !spine.isEmpty else { throw ConversionError.damaged(format) }
        let publication = Publication(metadata: metadata, layout: .fixed, direction: direction, spine: spine, contents: contents,
                                      cover: spine.first.flatMap { if case .page(let r) = $0.content { r } else { nil } }, resources: resources)
        return PublicationRead(publication, warnings: warnings)
    }
}

/// CHM (Compiled HTML Help) → Publication: the archive engine unpacks it, the `.hhc` sitemap gives the order and contents.
public enum CHMReader {
    public static func read(url: URL, workFolder: URL, extractor: ArchiveExtractor?, progress: (Double) -> Void = { _ in }) async throws -> PublicationRead {
        guard let extractor else { throw ConversionError.failed("CHM books need the archive engine, which isn’t available.") }
        let folder = workFolder.appendingPathComponent("chm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do { try await extractor(url, folder) } catch let e as ConversionError { throw e } catch { throw ConversionError.damaged("chm") }
        return try build(from: ContainerFiles(directory: folder), stem: (url.lastPathComponent as NSString).deletingPathExtension, progress: progress)
    }

    private struct Node { var title: String; var path: String?; var children: [Node] }

    static func build(from files: ContainerFiles, stem: String, progress: (Double) -> Void) throws -> PublicationRead {
        let byLower = Dictionary(files.paths.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        func canonical(_ path: String) -> String? { files.has(path) ? path : byLower[path.lowercased()] }
        let isPage: (String) -> Bool = { ["htm", "html", "xhtml"].contains(($0 as NSString).pathExtension.lowercased()) }

        // Sitemap
        var tree: [Node] = []
        if let hhc = files.paths.filter({ ($0 as NSString).pathExtension.lowercased() == "hhc" }).sorted(by: { $0.count < $1.count }).first,
           let data = files.read(hhc) {
            let doc = MarkupParser.parse(TextDecoding.string(from: data), html: true)
            func nodes(in list: MarkupNode) -> [Node] {
                var out: [Node] = []
                for li in list.elements where li.name == "li" {
                    let params = li.first("object")?.elements(named: "param") ?? []
                    func value(_ name: String) -> String? { params.first { $0.attribute("name")?.lowercased() == name }?.attribute("value") }
                    let sub = li.first("ul").map(nodes) ?? []
                    let path = value("local").flatMap { canonical(PackagePath.resolve($0, against: hhc)) }
                    if let title = value("name")?.nonEmpty { out.append(Node(title: title, path: path, children: sub)) } else { out += sub }
                }
                return out
            }
            if let top = doc.descendant("ul") { tree = nodes(in: top) }
        }
        var order: [String] = []
        func collect(_ list: [Node]) { for n in list { if let p = n.path, isPage(p), !order.contains(p) { order.append(p) }; collect(n.children) } }
        collect(tree)
        if order.isEmpty { order = files.paths.filter(isPage).sorted(by: naturalLess) }
        guard !order.isEmpty else { throw ConversionError.damaged("chm") }

        let ids = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, String(format: "c%04d", $0 + 1)) })
        func entries(_ list: [Node]) -> [ContentsEntry] {
            list.flatMap { n -> [ContentsEntry] in
                let kids = entries(n.children)
                if let p = n.path, let id = ids[p] { return [ContentsEntry(title: n.title, itemID: id, children: kids)] }
                if let first = kids.first { return [ContentsEntry(title: n.title, itemID: first.itemID, children: kids)] }
                return []
            }
        }
        var titles: [String: String] = [:]
        func note(_ list: [Node]) { for n in list { if let p = n.path, titles[p] == nil { titles[p] = n.title }; note(n.children) } }
        note(tree)

        var resources: [String: PublicationResource] = [:]
        var losses: Set<LossNote.Kind> = []
        var spine: [PublicationItem] = []
        for (n, path) in order.enumerated() {
            progress(Double(n) / Double(order.count))
            guard let data = files.read(path) else { continue }
            let markup = MarkupParser.parse(TextDecoding.string(from: data), html: true)
            let id = ids[path]!
            let reader = ContentReader(
                documentPath: path, footnotePrefix: id + "-",
                images: { target in
                    guard let real = canonical(target), let bytes = files.read(real) else { return nil }
                    let type = MediaTypes.forImage(bytes, name: real)
                    guard MediaTypes.isImage(type) else { return nil }
                    resources[real] = PublicationResource(mediaType: type, data: bytes)
                    return (real, bytes)
                },
                links: { target in canonical(target).flatMap { ids[$0] }.map { "item:" + $0 } })
            let blocks = reader.blocks(of: markup)
            losses.formUnion(reader.losses)
            let title = titles[path] ?? ContentReader.title(of: markup)
            spine.append(PublicationItem(id: id, title: title, content: .document(DocModel(metadata: DocMetadata(title: title), blocks: blocks, resources: reader.resources))))
        }
        var contents = entries(tree)
        if contents.isEmpty { contents = spine.compactMap { i in i.title.map { ContentsEntry(title: $0, itemID: i.id) } } }
        let publication = Publication(metadata: DocMetadata(title: stem), spine: spine, contents: contents, resources: resources)
        return PublicationRead(publication, lossNotes: PublicationRead.notes(losses))
    }
}
