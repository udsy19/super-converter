import CoreGraphics
import Foundation
import SuperConverterCore

// Origin: Super PDF Sources/ConvertKit/Export/OOXML.swift @ 058469b (OfficeRelationship, OfficePackage, OfficeUnits), adapted:
// only what the XLSX and PPTX writers share; page geometry, text runs and page pictures were LayoutKit-specific.
// OPC package parts (content types, relationships, document properties) and units. Output is deterministic (no dates,
// stable ids).

/// One relationship of an OPC part.
struct OfficeRelationship {
    var id: String
    var type: String
    var target: String
    /// A link to somewhere outside the package (`TargetMode="External"`).
    var isExternal = false

    static let officeDocument = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    static let coreProperties = "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"
    static let extendedProperties = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties"
    static let image = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
    static let styles = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"
    static let sharedStrings = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings"
    static let worksheet = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"
    static let hyperlink = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink"
    static let notesMaster = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster"
    static let notesSlide = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide"
    static let slide = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide"
    static let slideLayout = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout"
    static let slideMaster = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster"
    static let theme = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme"
    static let presProps = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/presProps"
    static let viewProps = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/viewProps"
    static let tableStyles = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/tableStyles"
}

/// Building an OPC package (ECMA-376 Part 2) into a ZIP.
struct OfficePackage {
    static let xmlHeader = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"# + "\n"

    /// Parts in the order added: path, bytes, whether to deflate.
    private var parts: [(String, Data, Bool)] = []
    /// Part name ("/word/document.xml") → content type.
    private var overrides: [(String, String)] = []
    private var mediaTypes: Set<String> = []

    /// Adds an XML part with its content type (an override in [Content_Types].xml); `nil` for .rels parts.
    mutating func add(_ path: String, xml: String, contentType: String?) {
        parts.append((path, Data((Self.xmlHeader + xml).utf8), true))
        if let contentType { overrides.append(("/" + path, contentType)) }
    }

    /// Adds a picture ("word/media/image1.png"); its extension gets a default content type.
    mutating func add(_ path: String, media: Data) {
        parts.append((path, media, false))
        mediaTypes.insert((path as NSString).pathExtension.lowercased())
    }

    mutating func addRelationships(_ path: String, _ relationships: [OfficeRelationship]) {
        add(path, xml: Self.relationships(relationships), contentType: nil)
    }

    /// docProps/core.xml and app.xml plus the package relationships to them and to the main part.
    mutating func addProperties(title: String, mainPart: String) {
        add("docProps/core.xml", xml: """
            <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
            xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(XML.escape(title))</dc:title>\
            <dc:creator>\(XML.escape(Strings.appName))</dc:creator></cp:coreProperties>
            """, contentType: "application/vnd.openxmlformats-package.core-properties+xml")
        add("docProps/app.xml", xml: """
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" \
            xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>\(XML.escape(Strings.appName))</Application></Properties>
            """, contentType: "application/vnd.openxmlformats-officedocument.extended-properties+xml")
        addRelationships("_rels/.rels", [
            OfficeRelationship(id: "rId1", type: OfficeRelationship.officeDocument, target: mainPart),
            OfficeRelationship(id: "rId2", type: OfficeRelationship.coreProperties, target: "docProps/core.xml"),
            OfficeRelationship(id: "rId3", type: OfficeRelationship.extendedProperties, target: "docProps/app.xml"),
        ])
    }

    /// The finished ZIP, [Content_Types].xml first.
    func finish() -> Data {
        var defaults = [("rels", "application/vnd.openxmlformats-package.relationships+xml"), ("xml", "application/xml")]
        for ext in mediaTypes.sorted() {
            switch ext {
            case "png": defaults.append(("png", "image/png"))
            case "jpeg", "jpg": defaults.append((ext, "image/jpeg"))
            case "gif": defaults.append((ext, "image/gif"))
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

    static func relationships(_ relationships: [OfficeRelationship]) -> String {
        var xml = #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        for r in relationships {
            xml += #"<Relationship Id="\#(r.id)" Type="\#(r.type)" Target="\#(XML.escape(r.target))"\#(r.isExternal ? " TargetMode=\"External\"" : "")/>"#
        }
        return xml + "</Relationships>"
    }
}

/// Lengths in the units OOXML uses.
enum OfficeUnits {
    /// English Metric Units: 12,700 per point.
    static func emu(_ points: CGFloat) -> Int { Int((points * 12_700).rounded()) }
}

