import Foundation
import SuperConverterCore

// ODF drawing picture reader and writer (formats §3.2: "OpenDocument Drawing with one embedded picture, what converters
// call .odd; anything richer goes to LibreOffice"). The writer makes an `.odg` package whose one page is the picture at
// 96 dpi; the reader returns the first embedded picture, or the package's thumbnail (reported) when there is none.

enum ODFPicture {
    static let mimeType = "application/vnd.oasis.opendocument.graphics"

    // MARK: Writer

    /// The `.odd` bytes for the first frame of `image`.
    static func write(_ image: ImageAsset, title: String? = nil) throws -> Data {
        guard let frame = image.frames.first, let png = Pictures.png(image) else { throw ConversionError.failed("The picture couldn’t be read.") }
        let width = String(format: "%.4fin", Double(frame.width) / 96), height = String(format: "%.4fin", Double(frame.height) / 96)
        let namespaces = ODSWriter.namespaces
            + #" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:xlink="http://www.w3.org/1999/xlink""#
        let content = """
            <office:document-content \(namespaces) office:version="1.3"><office:scripts/><office:font-face-decls/>\
            <office:automatic-styles><style:style style:name="gr1" style:family="graphic" style:parent-style-name="standard">\
            <style:graphic-properties draw:stroke="none" draw:fill="none"/></style:style></office:automatic-styles>\
            <office:body><office:drawing><draw:page draw:name="page1" draw:master-page-name="Default">\
            <draw:frame draw:style-name="gr1" draw:name="Picture" svg:width="\(width)" svg:height="\(height)" svg:x="0in" svg:y="0in">\
            <draw:image xlink:href="Pictures/image1.png" xlink:type="simple" xlink:show="embed" xlink:actuate="onLoad"/></draw:frame>\
            </draw:page></office:drawing></office:body></office:document-content>
            """
        let styles = """
            <office:document-styles \(namespaces) office:version="1.3"><office:styles>\
            <style:default-style style:family="graphic"/><style:style style:name="standard" style:family="graphic"/></office:styles>\
            <office:automatic-styles><style:page-layout style:name="PM1"><style:page-layout-properties fo:margin-top="0in" fo:margin-bottom="0in" \
            fo:margin-left="0in" fo:margin-right="0in" fo:page-width="\(width)" fo:page-height="\(height)" style:print-orientation="portrait"/>\
            </style:page-layout></office:automatic-styles>\
            <office:master-styles><style:master-page style:name="Default" style:page-layout-name="PM1"/></office:master-styles></office:document-styles>
            """
        let meta = """
            <office:document-meta \(namespaces) office:version="1.3"><office:meta><meta:generator>\(XML.escape(Strings.appName))</meta:generator>\
            \(title.map { "<dc:title>\(XML.escape($0))</dc:title>" } ?? "")</office:meta></office:document-meta>
            """
        let manifest = """
            <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">\
            <manifest:file-entry manifest:full-path="/" manifest:version="1.3" manifest:media-type="\(mimeType)"/>\
            <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>\
            <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>\
            <manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/>\
            <manifest:file-entry manifest:full-path="Pictures/image1.png" manifest:media-type="image/png"/></manifest:manifest>
            """
        var zip = ZipWriter()
        zip.add("mimetype", Data(mimeType.utf8), compress: false)
        zip.add("META-INF/manifest.xml", OfficePackage.xmlHeader + manifest)
        zip.add("content.xml", OfficePackage.xmlHeader + content)
        zip.add("styles.xml", OfficePackage.xmlHeader + styles)
        zip.add("meta.xml", OfficePackage.xmlHeader + meta)
        zip.add("Pictures/image1.png", png, compress: false)
        return zip.finish()
    }

    // MARK: Reader

    struct Result {
        var image: ImageAsset
        var lossNotes: [LossNote]
    }

    static func read(_ url: URL) throws -> Result {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.damaged(FormatID("odd")) }
        return try read(data)
    }

    static func read(_ data: Data) throws -> Result {
        let archive: ZipArchive
        do { archive = try ZipArchive(data: data) } catch { throw ConversionError.damaged(FormatID("odd")) }
        guard let contentData = try? archive.data("content.xml"), let content = try? XML.parse(contentData) else { throw ConversionError.damaged(FormatID("odd")) }
        let images = content.all("image").compactMap { $0.attr("xlink:href") }.filter { !$0.contains("://") }
        let shapes = ["custom-shape", "rect", "ellipse", "line", "polygon", "path", "connector", "text-box", "g", "polyline", "circle"]
        let hasOtherShapes = content.first("page").map { page in page.children.contains { shapes.contains($0.name) } } ?? false
        var notes: [LossNote] = []
        for href in images {
            let path = href.hasPrefix("./") ? String(href.dropFirst(2)) : href
            if let bytes = try? archive.data(path), let image = Pictures.asset(from: bytes) {
                if images.count > 1 || hasOtherShapes { notes.append(LossNote(.otherLoss, detail: "Only the first picture was kept.")) }
                return Result(image: image, lossNotes: notes)
            }
        }
        if let bytes = try? archive.data("Thumbnails/thumbnail.png"), let image = Pictures.asset(from: bytes) {
            return Result(image: image, lossNotes: [LossNote(.otherLoss, detail: "The drawing has no picture of its own, so its preview was used.")])
        }
        throw ConversionError.failed("This drawing is more than a picture, so it needs LibreOffice.")
    }
}
