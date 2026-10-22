import CoreGraphics
import Foundation
import SuperConverterCore

/// PDF analysis → `Publication` (formats §6, for the calibre routes): chapters from the top-level headings, each a `DocModel`,
/// the first page as the cover. EbookKit writes the EPUB from it.
enum PublicationBuilder {
    static func build(_ doc: DocModel, analysis: PDFAnalysis) throws -> Publication {
        let levels = doc.blocks.compactMap { block -> Int? in if case .heading(let level, _) = block { level } else { nil } }
        let split = levels.min()
        var chapters: [(title: String?, blocks: [DocBlock])] = [(nil, [])]
        for block in doc.blocks {
            if case .heading(let level, let text) = block, level == split {
                if chapters.count == 1, chapters[0].blocks.isEmpty { chapters[0] = (DocModelBuilder.plain(text), []) } else { chapters.append((DocModelBuilder.plain(text), [])) }
            }
            chapters[chapters.count - 1].blocks.append(block)
        }
        var spine: [PublicationItem] = []
        var contents: [ContentsEntry] = []
        for (n, chapter) in chapters.enumerated() where !chapter.blocks.isEmpty {
            let id = "chapter-\(n + 1)"
            let names = Set(chapter.blocks.compactMap { block -> String? in if case .figure(let r, _, _) = block { r } else { nil } })
            let part = DocModel(metadata: doc.metadata, blocks: chapter.blocks, resources: doc.resources.filter { names.contains($0.key) })
            let title = chapter.title ?? doc.metadata.title ?? "Beginning"
            spine.append(PublicationItem(id: id, title: title, content: .document(part)))
            contents.append(ContentsEntry(title: title, itemID: id))
        }
        var resources: [String: PublicationResource] = [:]
        var cover: String?
        if let page = analysis.pages.first, let jpeg = try PagePictures(url: analysis.url, password: analysis.password).page(page).flatMap({ PagePictures.encode($0, jpeg: true) }) {
            resources["cover"] = PublicationResource(mediaType: "image/jpeg", data: jpeg)
            cover = "cover"
        }
        return Publication(metadata: doc.metadata, spine: spine, contents: contents, cover: cover, resources: resources)
    }
}
