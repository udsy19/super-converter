import Foundation
import SuperConverterCore

/// Where a container's files come from: a ZIP in memory, or a folder on disk (an unpacked OEB, a CHM extracted by the archive
/// engine, a bare `.opf`).
struct ContainerFiles {
    var paths: [String]
    var read: (String) -> Data?

    func has(_ path: String) -> Bool { paths.contains(path) }

    init(paths: [String], read: @escaping (String) -> Data?) { self.paths = paths; self.read = read }

    init(zip: ZipArchive, transform: @escaping (String, Data) -> Data = { $1 }) {
        paths = zip.entries.filter { !$0.isDirectory }.map { PackagePath.normalise($0.name) }
        let index = Dictionary(zip.entries.filter { !$0.isDirectory }.map { (PackagePath.normalise($0.name), $0) }, uniquingKeysWith: { a, _ in a })
        read = { path in
            guard let entry = index[path] ?? zip.entry(named: path), let data = try? zip.data(for: entry) else { return nil }
            return transform(path, data)
        }
    }

    init(directory: URL) {
        let base = directory.standardizedFileURL
        var found: [String] = []
        if let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let full = url.standardizedFileURL.path, prefix = base.path + "/"
                if full.hasPrefix(prefix) { found.append(String(full.dropFirst(prefix.count))) }
            }
        }
        paths = found.sorted()
        read = { path in
            let url = base.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(base.path + "/") else { return nil }
            return try? Data(contentsOf: url)
        }
    }
}

/// Reads an OPF package (EPUB 2/3 and OEB 1.2) into a `Publication`.
struct PackageReader {
    let files: ContainerFiles
    let format: FormatID

    /// - Returns: the publication and the things that could not be carried over.
    func read(opfPath: String, report: (Double) -> Void = { _ in }) throws -> (Publication, Set<LossNote.Kind>) {
        guard let opfData = files.read(opfPath) else { throw ConversionError.damaged(format) }
        let opf = MarkupParser.parse(TextDecoding.string(from: opfData), html: false, lowercase: true)
        guard let package = opf.descendant("package") else { throw ConversionError.damaged(format) }

        // Metadata
        let metaRoot = package.first("metadata") ?? package
        let metadata = Self.metadata(from: package)

        // Manifest
        struct Item { var id: String; var path: String; var mediaType: String; var properties: [String] }
        var items: [String: Item] = [:]
        var manifestOrder: [String] = []
        for node in package.first("manifest")?.elements(named: "item") ?? [] {
            guard let id = node.attribute("id"), let href = node.attribute("href"), !PackagePath.isExternal(href) else { continue }
            let path = PackagePath.resolve(href, against: opfPath)
            let type = node.attribute("media-type")?.lowercased() ?? MediaTypes.forPath(path)
            items[id] = Item(id: id, path: path, mediaType: type, properties: (node.attribute("properties") ?? "").split(separator: " ").map(String.init))
            manifestOrder.append(id)
        }

        // Spine
        let spineNode = package.first("spine")
        let spineRefs = (spineNode?.elements(named: "itemref") ?? []).compactMap { $0.attribute("idref") }.filter { items[$0] != nil }
        let navID = manifestOrder.first { items[$0]!.properties.contains("nav") }
        let tocID = spineNode?.attribute("toc").flatMap { items[$0] != nil ? $0 : nil }
            ?? manifestOrder.first { items[$0]!.mediaType == "application/x-dtbncx+xml" }
        var seen: Set<String> = []
        let spineIDs = spineRefs.filter { $0 != navID && seen.insert($0).inserted }
        let spinePaths = Dictionary(spineIDs.map { (items[$0]!.path, $0) }, uniquingKeysWith: { a, _ in a })

        let rtl = spineNode?.attribute("page-progression-direction") == "rtl"
        let fixed = metaRoot.descendants("meta").contains {
            $0.attribute("property") == "rendition:layout" && $0.plainText == "pre-paginated"
        }

        // Resources: everything that is not content, navigation or the package itself
        var resources: [String: PublicationResource] = [:]
        var keyByPath: [String: String] = [:]
        for id in manifestOrder {
            let item = items[id]!
            if MediaTypes.isDocument(item.mediaType) || id == navID || id == tocID || item.mediaType == "application/oebps-package+xml" { continue }
            guard let data = files.read(item.path) else { continue }
            resources[id] = PublicationResource(mediaType: item.mediaType, data: data)
            keyByPath[item.path] = id
        }
        func resourceKey(for path: String) -> String? {
            if let key = keyByPath[path] { return key }
            guard files.has(path), !MediaTypes.isDocument(MediaTypes.forPath(path)), let data = files.read(path) else { return nil }
            resources[path] = PublicationResource(mediaType: MediaTypes.forImage(data, name: path), data: data)
            keyByPath[path] = path
            return path
        }

        // Contents
        var contents: [ContentsEntry] = []
        func entries(fromList ol: MarkupNode, base: String) -> [ContentsEntry] {
            var out: [ContentsEntry] = []
            for li in ol.elements where li.name == "li" {
                let anchor = li.first("a") ?? li.first("span")
                let label = anchor?.plainText ?? ""
                let children = (li.first("ol") ?? li.first("ul")).map { entries(fromList: $0, base: base) } ?? []
                if let href = anchor?.attribute("href"), let id = spinePaths[PackagePath.resolve(href, against: base)], !label.isEmpty {
                    out.append(ContentsEntry(title: label, itemID: id, children: children))
                } else { out += children }
            }
            return out
        }
        func entries(fromNCX points: [MarkupNode], base: String) -> [ContentsEntry] {
            var out: [ContentsEntry] = []
            for p in points {
                let label = p.first("navlabel")?.plainText ?? ""
                let children = entries(fromNCX: p.elements(named: "navpoint"), base: base)
                if let src = p.first("content")?.attribute("src"), let id = spinePaths[PackagePath.resolve(src, against: base)], !label.isEmpty {
                    out.append(ContentsEntry(title: label, itemID: id, children: children))
                } else { out += children }
            }
            return out
        }
        if let navID, let data = files.read(items[navID]!.path) {
            let doc = MarkupParser.parse(TextDecoding.string(from: data), html: false, lowercase: true)
            let navs = doc.descendants("nav")
            let toc = navs.first { ($0.attribute("epub:type") ?? $0.attribute("type") ?? "").split(separator: " ").contains("toc") } ?? navs.first
            if let ol = toc?.descendant("ol") { contents = entries(fromList: ol, base: items[navID]!.path) }
        }
        if contents.isEmpty, let tocID, let data = files.read(items[tocID]!.path) {
            let doc = MarkupParser.parse(TextDecoding.string(from: data), html: false, lowercase: true)
            if let map = doc.descendant("navmap") { contents = entries(fromNCX: map.elements(named: "navpoint"), base: items[tocID]!.path) }
        }
        let guideRefs = package.first("guide")?.elements(named: "reference") ?? []
        if contents.isEmpty, let ref = guideRefs.first(where: { $0.attribute("type")?.lowercased() == "toc" }), let href = ref.attribute("href") {
            let tocPath = PackagePath.resolve(href, against: opfPath)
            if let data = files.read(tocPath) {
                let doc = MarkupParser.parse(TextDecoding.string(from: data), html: true)
                if let list = (doc.descendant("body") ?? doc).descendant("ul") ?? (doc.descendant("body") ?? doc).descendant("ol") {
                    contents = entries(fromList: list, base: tocPath)
                }
            }
        }
        // An item is titled by the shallowest contents entry that points at it.
        var firstTitle: [String: String] = [:]
        var level = contents
        while !level.isEmpty {
            for e in level where firstTitle[e.itemID] == nil { firstTitle[e.itemID] = e.title }
            level = level.flatMap(\.children)
        }

        // Cover
        var cover: String?
        if let id = manifestOrder.first(where: { items[$0]!.properties.contains("cover-image") }), resources[id] != nil { cover = id }
        if cover == nil, let name = metaRoot.descendants("meta").first(where: { $0.attribute("name") == "cover" })?.attribute("content"), resources[name] != nil { cover = name }
        if cover == nil, let ref = guideRefs.first(where: { $0.attribute("type")?.lowercased().contains("cover") == true }),
           let href = ref.attribute("href"), let key = keyByPath[PackagePath.resolve(href, against: opfPath)],
           MediaTypes.isImage(resources[key]?.mediaType ?? "") { cover = key }

        // Spine items
        var losses: Set<LossNote.Kind> = []
        var spine: [PublicationItem] = []
        for (n, id) in spineIDs.enumerated() {
            report(Double(n) / Double(max(1, spineIDs.count)))
            let item = items[id]!
            if MediaTypes.isImage(item.mediaType) {
                if let key = resourceKey(for: item.path) { spine.append(PublicationItem(id: id, title: firstTitle[id], content: .page(resource: key))) }
                continue
            }
            guard MediaTypes.isDocument(item.mediaType), let data = files.read(item.path) else { continue }
            let markup = MarkupParser.parse(TextDecoding.string(from: data), html: item.mediaType != "application/xhtml+xml")
            if fixed, let page = Self.singlePicture(in: markup), let key = resourceKey(for: PackagePath.resolve(page, against: item.path)) {
                spine.append(PublicationItem(id: id, title: firstTitle[id], content: .page(resource: key)))
                continue
            }
            let reader = ContentReader(
                documentPath: item.path, footnotePrefix: id + "-",
                images: { path in
                    guard let key = resourceKey(for: path), let r = resources[key], MediaTypes.isImage(r.mediaType) || key == path else { return nil }
                    return (key, r.data)
                },
                links: { path in spinePaths[path].map { "item:" + $0 } })
            let blocks = reader.blocks(of: markup)
            losses.formUnion(reader.losses)
            let title = firstTitle[id] ?? ContentReader.title(of: markup)
            spine.append(PublicationItem(id: id, title: title, content: .document(DocModel(metadata: DocMetadata(title: title), blocks: blocks, resources: reader.resources))))
        }
        let publication = Publication(metadata: metadata, layout: fixed ? .fixed : .reflowable, direction: rtl ? .rightToLeft : .leftToRight,
                                      spine: spine, contents: contents, cover: cover, resources: resources)
        return (publication, losses)
    }

    /// Dublin Core fields of an OPF `package` (lower-cased tree).
    static func metadata(from package: MarkupNode) -> DocMetadata {
        let root = package.first("metadata") ?? package
        func dc(_ name: String) -> [MarkupNode] { root.descendants(name) }
        var metadata = DocMetadata()
        metadata.title = dc("title").map(\.plainText).first { !$0.isEmpty }
        metadata.authors = dc("creator").map(\.plainText).filter { !$0.isEmpty }
        metadata.language = dc("language").map(\.plainText).first { !$0.isEmpty }
        metadata.date = dc("date").compactMap { Date.fromBookDate($0.plainText) }.first
        metadata.summary = dc("description").map(\.plainText).first { !$0.isEmpty }
        return metadata
    }

    /// The picture path when the document is only one `<img>` (or SVG `<image>`) and no text.
    static func singlePicture(in root: MarkupNode) -> String? {
        let body = root.descendant("body") ?? root
        guard body.plainText.isEmpty else { return nil }
        let pictures = body.descendants("img") + body.descendants("image")
        guard pictures.count == 1 else { return nil }
        return pictures[0].attribute("src") ?? pictures[0].attribute("href")
    }
}
