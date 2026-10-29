import Foundation
import SuperConverterCore

/// The OPC layer of an XPS, OpenXPS or DWFx file: the package, its relationships and the fixed-page parts in reading order.
struct XPSPackage {
    let zip: ZipReader

    static let fixedRepresentationSuffix = "fixedrepresentation"

    init(_ data: Data) throws { zip = try ZipReader(data) }

    struct Relationship { let type: String; let target: String; let external: Bool }

    /// Relationships of a part ("" for the package itself), targets resolved to absolute part names.
    func relationships(of part: String) -> [Relationship] {
        let dir = (part as NSString).deletingLastPathComponent
        let name = (part as NSString).lastPathComponent
        let relsName = part.isEmpty ? "/_rels/.rels" : (dir.hasPrefix("/") ? dir : "/" + dir) + "/_rels/" + name + ".rels"
        guard let data = try? zip.read(relsName), data.count < 8 << 20, let root = try? XMLTree.parse(data) else { return [] }
        return root.children.filter { $0.name == "Relationship" }.compactMap { r in
            guard let type = r.attr("Type"), let target = r.attr("Target") else { return nil }
            let external = r.attr("TargetMode") == "External"
            return Relationship(type: type, target: external ? target : XPSSyntax.resolve(target, base: part.isEmpty ? "/x" : part), external: external)
        }
    }

    /// The page parts in order, found through the start part, else by scanning for fixed-document parts.
    func pageParts() throws -> [String] {
        var starts = relationships(of: "").filter { $0.type.lowercased().hasSuffix(Self.fixedRepresentationSuffix) && !$0.external }.map(\.target)
        if starts.isEmpty {
            let lower = zip.names.map { ($0.hasPrefix("/") ? $0 : "/" + $0) }
            for ext in [".fdseq", ".fdoc", ".fpage"] {
                let hit = lower.filter { $0.lowercased().hasSuffix(ext) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                if !hit.isEmpty { starts = ext == ".fpage" ? hit : [hit[0]]; break }
            }
        }
        var pages: [String] = []
        var seen = Set<String>()
        func visit(_ part: String, depth: Int) {
            guard depth < 6, !seen.contains(part.lowercased()), pages.count < 5000, zip.has(part), let data = try? zip.read(part), data.count < 64 << 20,
                  let root = try? XMLTree.parse(data) else { return }
            seen.insert(part.lowercased())
            switch root.name {
            case "FixedDocumentSequence":
                for r in root.children where r.name == "DocumentReference" { if let s = r.attr("Source") { visit(XPSSyntax.resolve(s, base: part), depth: depth + 1) } }
            case "FixedDocument":
                for r in root.children where r.name == "PageContent" { if let s = r.attr("Source") { pages.append(XPSSyntax.resolve(s, base: part)) } }
            case "FixedPage": pages.append(part)
            default: break
            }
        }
        for s in starts { visit(s, depth: 0) }
        pages = pages.filter { zip.has($0) }
        guard !pages.isEmpty else { throw ConversionError.damaged("xps") }
        return pages
    }
}
