// Adapted from super-pdf Sources/ConvertKit/Export/OOXML.swift (commit 058469b): `OfficePackage` and `OfficeRelationship`
// only (the LayoutKit geometry and run helpers belong to the PDF writers); no app name in the properties, the title,
// author and date come from the `DocModel`'s metadata, GIF and SVG content types added.

import Foundation
import SuperConverterCore

/// One relationship of an OPC part.
struct OPCRelationship {
    var id: String
    var type: String
    var target: String
    var external = false

    static let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    static let officeDocument = base + "officeDocument"
    static let coreProperties = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
    static let extendedProperties = base + "extended-properties"
    static let image = base + "image"
    static let styles = base + "styles"
    static let settings = base + "settings"
    static let numbering = base + "numbering"
    static let footnotes = base + "footnotes"
    static let hyperlink = base + "hyperlink"
}

/// Building an OPC package (ECMA-376 Part 2) into a ZIP.
struct OPCPackage {
    static let xmlHeader = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

    private var parts: [(String, Data, Bool)] = []
    private var overrides: [(String, String)] = []
    private var mediaTypes: Set<String> = []

    /// Adds an XML part with its content type (an override in [Content_Types].xml); `nil` for .rels parts.
    mutating func add(_ path: String, xml: String, contentType: String?) {
        parts.append((path, Data((Self.xmlHeader + xml).utf8), true))
        if let contentType { overrides.append(("/" + path, contentType)) }
    }

    mutating func add(_ path: String, media: Data) {
        parts.append((path, media, false))
        mediaTypes.insert((path as NSString).pathExtension.lowercased())
    }

    mutating func addRelationships(_ path: String, _ relationships: [OPCRelationship]) {
        add(path, xml: Self.relationships(relationships), contentType: nil)
    }

    /// docProps/core.xml and app.xml plus the package relationships to them and to the main part.
    mutating func addProperties(_ metadata: DocMetadata, mainPart: String, application: String) {
        var core = ""
        if let title = metadata.title { core += "<dc:title>\(XML.escape(title))</dc:title>" }
        if let summary = metadata.summary { core += "<dc:description>\(XML.escape(summary))</dc:description>" }
        if !metadata.authors.isEmpty { core += "<dc:creator>\(XML.escape(metadata.authors.joined(separator: "; ")))</dc:creator>" }
        if let language = metadata.language { core += "<dc:language>\(XML.escape(language))</dc:language>" }
        if let date = metadata.date {
            let stamp = ISO8601DateFormatter().string(from: date)
            core += "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(stamp)</dcterms:created>"
        }
        add("docProps/core.xml", xml: """
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
            xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\(core)</cp:coreProperties>
            """, contentType: "application/vnd.openxmlformats-package.core-properties+xml")
        add("docProps/app.xml", xml: """
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
            xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>\(XML.escape(application))</Application></Properties>
            """, contentType: "application/vnd.openxmlformats-officedocument.extended-properties+xml")
        addRelationships("_rels/.rels", [
            OPCRelationship(id: "rId1", type: OPCRelationship.officeDocument, target: mainPart),
            OPCRelationship(id: "rId2", type: OPCRelationship.coreProperties, target: "docProps/core.xml"),
            OPCRelationship(id: "rId3", type: OPCRelationship.extendedProperties, target: "docProps/app.xml"),
        ])
    }

    /// The finished ZIP, [Content_Types].xml first.
    func finish() -> Data {
        var defaults = [("rels", "application/vnd.openxmlformats-package.relationships+xml"), ("xml", "application/xml")]
        for ext in mediaTypes.sorted() {
            switch ext {
            case "png": defaults.append(("png", "image/png"))
            case "jpeg", "jpg": defaults.append((ext, "image/jpeg"))
            case "gif": defaults.append(("gif", "image/gif"))
            default: break
            }
        }
        var types = #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
        for (ext, type) in defaults { types += #"<Default Extension="\#(ext)" ContentType="\#(type)"/>"# }
        for (part, type) in overrides { types += #"<Override PartName="\#(XML.escape(part))" ContentType="\#(type)"/>"# }
        types += "</Types>"
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", Self.xmlHeader + types)
        for (path, data, compress) in parts { zip.add(path, data, compress: compress) }
        return zip.finish()
    }

    static func relationships(_ relationships: [OPCRelationship]) -> String {
        var xml = #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        for r in relationships {
            xml += #"<Relationship Id="\#(r.id)" Type="\#(r.type)" Target="\#(XML.escape(r.target))"\#(r.external ? " TargetMode=\"External\"" : "")/>"#
        }
        return xml + "</Relationships>"
    }
}
