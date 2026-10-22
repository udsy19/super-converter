import CryptoKit
import Foundation
import SuperConverterCore

/// What a reader hands back: the publication plus everything it could not carry over.
public struct PublicationRead: Sendable {
    public var publication: Publication
    public var lossNotes: [LossNote]
    public var warnings: [String]
    public init(_ publication: Publication, lossNotes: [LossNote] = [], warnings: [String] = []) {
        self.publication = publication; self.lossNotes = lossNotes; self.warnings = warnings
    }

    static func notes(_ kinds: Set<LossNote.Kind>) -> [LossNote] { kinds.sorted { $0.rawValue < $1.rawValue }.map { LossNote($0) } }
}

/// EPUB 2 and 3 → Publication (formats §3.2). Encrypted fonts are un-obfuscated; any other encryption is DRM and refused.
public enum EPUBReader {
    public static func read(url: URL, progress: (Double) -> Void = { _ in }) throws -> PublicationRead {
        let zip: ZipArchive
        do { zip = try ZipArchive(url: url) } catch { throw ConversionError.damaged("epub") }
        let probe = ContainerFiles(zip: zip)

        guard let opfPath = rootfile(in: probe) else { throw ConversionError.damaged("epub") }
        var transforms: [String: String] = [:]   // path → obfuscation algorithm
        if let enc = probe.read("META-INF/encryption.xml") {
            let doc = MarkupParser.parse(TextDecoding.string(from: enc), html: false, lowercase: true)
            for data in doc.descendants("encrypteddata") {
                let algorithm = data.descendant("encryptionmethod")?.attribute("algorithm") ?? ""
                guard let uri = data.descendant("cipherreference")?.attribute("uri") else { continue }
                if algorithm == idpfAlgorithm || algorithm == adobeAlgorithm { transforms[PackagePath.resolve(uri, against: "")] = algorithm }
                else { throw ConversionError.drmProtected }
            }
        }
        var files = probe
        if !transforms.isEmpty, let identifier = identifier(opfPath: opfPath, files: probe) {
            let idpfKey = Array(Insecure.SHA1.hash(data: Data(identifier.filter { !" \t\r\n".contains($0) }.utf8)))
            let hex = identifier.replacingOccurrences(of: "urn:uuid:", with: "").replacingOccurrences(of: "-", with: "")
            let adobeKey: [UInt8] = stride(from: 0, to: hex.count - 1, by: 2).compactMap {
                let a = hex.index(hex.startIndex, offsetBy: $0)
                return UInt8(hex[a..<hex.index(a, offsetBy: 2)], radix: 16)
            }
            files = ContainerFiles(zip: zip) { path, data in
                guard let algorithm = transforms[path] else { return data }
                let (key, length) = algorithm == idpfAlgorithm ? (idpfKey, 1040) : (adobeKey, 1024)
                guard !key.isEmpty else { return data }
                var out = data
                for i in 0..<min(length, out.count) { out[out.startIndex + i] ^= key[i % key.count] }
                return out
            }
        }
        let (publication, losses) = try PackageReader(files: files, format: "epub").read(opfPath: opfPath, report: progress)
        guard !publication.spine.isEmpty else { throw ConversionError.damaged("epub") }
        return PublicationRead(publication, lossNotes: PublicationRead.notes(losses))
    }

    static let idpfAlgorithm = "http://www.idpf.org/2008/embedding"
    static let adobeAlgorithm = "http://ns.adobe.com/pdf/enc#RC"

    static func rootfile(in files: ContainerFiles) -> String? {
        if let container = files.read("META-INF/container.xml") {
            let doc = MarkupParser.parse(TextDecoding.string(from: container), html: false, lowercase: true)
            let roots = doc.descendants("rootfile")
            let chosen = roots.first { $0.attribute("media-type") == "application/oebps-package+xml" } ?? roots.first
            if let path = chosen?.attribute("full-path") {
                let resolved = PackagePath.normalise(path.removingPercentEncoding ?? path)
                if files.has(resolved) { return resolved }
            }
        }
        return files.paths.filter { $0.lowercased().hasSuffix(".opf") }.sorted { $0.count < $1.count }.first
    }

    static func identifier(opfPath: String, files: ContainerFiles) -> String? {
        guard let data = files.read(opfPath) else { return nil }
        let doc = MarkupParser.parse(TextDecoding.string(from: data), html: false, lowercase: true)
        guard let package = doc.descendant("package") else { return nil }
        let wanted = package.attribute("unique-identifier")
        let ids = package.descendants("identifier")
        return (ids.first { $0.attribute("id") == wanted } ?? ids.first)?.rawText
    }
}

/// OEB 1.2 → Publication: a ZIP holding an OPF package (with or without `container.xml`), or a bare `.opf`/`.oeb` package
/// file next to its parts.
public enum OEBReader {
    public static func read(url: URL, progress: (Double) -> Void = { _ in }) throws -> PublicationRead {
        let files: ContainerFiles
        let opfPath: String
        if let zip = try? ZipArchive(url: url) {
            files = ContainerFiles(zip: zip)
            guard let found = EPUBReader.rootfile(in: files) else { throw ConversionError.damaged("oeb") }
            opfPath = found
        } else {
            guard let head = try? FileHandle(forReadingFrom: url).read(upToCount: 4096),
                  String(decoding: head, as: UTF8.self).lowercased().contains("<package") else { throw ConversionError.damaged("oeb") }
            files = ContainerFiles(directory: url.deletingLastPathComponent())
            opfPath = url.lastPathComponent
        }
        let (publication, losses) = try PackageReader(files: files, format: "oeb").read(opfPath: opfPath, report: progress)
        guard !publication.spine.isEmpty else { throw ConversionError.damaged("oeb") }
        return PublicationRead(publication, lossNotes: PublicationRead.notes(losses))
    }
}
