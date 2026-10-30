// Adapted from super-pdf Sources/ConvertKit/Import/MailImporter.swift (commit 058469b): the MIME parser (`MIMEPart`) only,
// unchanged apart from dropping `throws` from the nested parse where nothing throws; the PDF conversion became `MailReader`.

import Foundation
import SuperConverterCore

/// E-mail (.eml) → `DocModel`: the headers as a block, the body (HTML through `HTMLReader` with inline pictures resolved,
/// else the plain text), and the names of the attachments; or the attachments themselves as an `ArchiveTree` (eml → zip).
enum MailReader {
    static func read(_ url: URL, options: DocReadOptions = DocReadOptions()) throws -> DocReadResult {
        let message = MIMEPart.parse(try Data(contentsOf: url))
        var html: String?
        var plain: String?
        var inline: [String: (mime: String, data: Data)] = [:]
        var attachments: [String] = []
        for part in message.leaves() {
            let type = part.contentType
            if part.isAttachment || (!type.hasPrefix("text/") && !type.hasPrefix("multipart/")) {
                if let id = part.contentID, !part.isAttachment { inline[id] = (type, part.decodedBody) }
                else { attachments.append(part.fileName ?? "attachment-\(attachments.count + 1)") }
            } else if type == "text/html", html == nil { html = part.text }
            else if type == "text/plain", plain == nil { plain = part.text }
        }
        var model: DocModel
        if var html {
            for (id, picture) in inline { html = html.replacingOccurrences(of: "cid:" + id, with: "data:\(picture.mime);base64,\(picture.data.base64EncodedString())") }
            model = HTMLReader.parse(html).model
        } else {
            model = PlainTextReader.parse(plain ?? "", options: options).model
        }
        var header: [DocBlock] = []
        for (label, key) in [("From", "from"), ("To", "to"), ("Cc", "cc"), ("Date", "date")] {
            if let value = message.header(key), !value.isEmpty { header.append(.paragraph([.strong([.text(label + ": ")]), .text(value)], DocParagraphStyle())) }
        }
        header.append(.thematicBreak)
        model.blocks = header + model.blocks
        if !attachments.isEmpty {
            model.blocks.append(.thematicBreak)
            model.blocks.append(.paragraph([.strong([.text("Attachments: ")]), .text(attachments.joined(separator: ", "))], DocParagraphStyle()))
        }
        if let subject = message.subject, !subject.isEmpty { model.metadata.title = subject }
        if let from = message.header("from") { model.metadata.authors = [from] }
        if let date = message.header("date") { model.metadata.date = rfc2822(date) }
        return DocReadResult(model: model)
    }

    /// The attachments, written into `folder` under safe names, as an archive tree (ARCHITECTURE §6: archive contents are files).
    static func attachments(_ url: URL, into folder: URL) throws -> ArchiveTree {
        let message = MIMEPart.parse(try Data(contentsOf: url))
        var entries: [ArchiveTree.Entry] = []
        var used = Set<String>()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for part in message.leaves() where part.isAttachment || (!part.contentType.hasPrefix("text/") && !part.contentType.hasPrefix("multipart/")) {
            var name = (part.fileName ?? "attachment-\(entries.count + 1)").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            if name.hasPrefix(".") { name = "_" + name }
            var unique = name
            var n = 2
            while !used.insert(unique.lowercased()).inserted { unique = "\((name as NSString).deletingPathExtension) \(n)" + ((name as NSString).pathExtension.isEmpty ? "" : "." + (name as NSString).pathExtension); n += 1 }
            let file = folder.appendingPathComponent(unique)
            let data = part.decodedBody
            try data.write(to: file)
            entries.append(ArchiveTree.Entry(path: unique, kind: .file, size: Int64(data.count), modified: nil, permissions: 0o644, extracted: file))
        }
        return ArchiveTree(entries: entries, root: folder)
    }

    private static func rfc2822(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
            f.dateFormat = format
            if let d = f.date(from: text.components(separatedBy: " (").first ?? text) { return d }
        }
        return nil
    }
}

/// A MIME entity (RFC 2045–2047): headers, and either a body or parts.
struct MIMEPart {
    var headers: [(name: String, value: String)]
    var body: Data
    var parts: [MIMEPart]

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map { Self.decodeWords($0.value) }
    }

    var subject: String? { header("subject") }

    /// "text/html", lower-cased, without parameters; text/plain when absent.
    var contentType: String {
        (header("content-type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }) ?? "text/plain"
    }

    var contentID: String? {
        header("content-id")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    var isAttachment: Bool { header("content-disposition")?.lowercased().hasPrefix("attachment") == true }

    var fileName: String? {
        parameter("filename", in: header("content-disposition")) ?? parameter("name", in: header("content-type"))
    }

    /// The body with its transfer encoding undone.
    var decodedBody: Data {
        switch header("content-transfer-encoding")?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64":
            let clean = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            return Data(base64Encoded: clean, options: .ignoreUnknownCharacters) ?? body
        case "quoted-printable":
            return Self.quotedPrintable(body)
        default:
            return body
        }
    }

    /// The decoded body as text in its charset.
    var text: String {
        let charset = parameter("charset", in: header("content-type")) ?? "utf-8"
        let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        let decoded = decodedBody
        if encoding != kCFStringEncodingInvalidId,
           let text = String(data: decoded, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
            return text
        }
        return String(data: decoded, encoding: .utf8) ?? String(data: decoded, encoding: .windowsCP1252) ?? ""
    }

    /// Parts without parts, depth first (bodies and attachments).
    func leaves() -> [MIMEPart] { parts.isEmpty ? [self] : parts.flatMap { $0.leaves() } }

    func parameter(_ name: String, in header: String?) -> String? {
        guard let header else { return nil }
        for piece in header.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pair.count == 2 else { continue }
            let key = pair[0].lowercased()
            // RFC 2231 "filename*=utf-8''name".
            if key == name + "*", let quote = pair[1].range(of: "''") {
                return String(pair[1][quote.upperBound...]).removingPercentEncoding
            }
            if key == name { return Self.decodeWords(pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
        }
        return nil
    }

    // MARK: Parsing

    static func parse(_ data: Data, depth: Int = 0) -> MIMEPart {
        let bytes = [UInt8](data)
        // Headers end at the first empty line (CRLF CRLF or LF LF).
        var split = bytes.count
        var bodyStart = bytes.count
        var i = 0
        while i < bytes.count {
            if bytes[i] == 10 {
                if i + 1 < bytes.count, bytes[i + 1] == 10 { split = i; bodyStart = i + 2; break }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { split = i; bodyStart = i + 3; break }
            }
            i += 1
        }
        let headerText = String(decoding: bytes[0..<split], as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        var headers: [(String, String)] = []
        for line in headerText.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", !headers.isEmpty {
                headers[headers.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        let body = bodyStart < bytes.count ? Data(bytes[bodyStart...]) : Data()
        var part = MIMEPart(headers: headers, body: body, parts: [])
        if part.contentType.hasPrefix("multipart/"), depth < 20, let boundary = part.parameter("boundary", in: part.header("content-type")) {
            part.parts = splitParts(body, boundary: boundary).map { parse($0, depth: depth + 1) }
        }
        return part
    }

    private static func splitParts(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data(("--" + boundary).utf8)
        var parts: [Data] = []
        var searchStart = body.startIndex
        var current: Int?
        while let range = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            if let start = current {
                var end = range.lowerBound
                // The line break before the delimiter belongs to it.
                if end > start, body[end - 1] == 10 { end -= 1 }
                if end > start, body[end - 1] == 13 { end -= 1 }
                parts.append(body.subdata(in: start..<max(start, end)))
            }
            var next = range.upperBound
            if next + 1 < body.endIndex, body[next] == 45, body[next + 1] == 45 { break }   // "--" closes
            while next < body.endIndex, body[next] != 10 { next += 1 }
            current = min(next + 1, body.endIndex)
            searchStart = current!
        }
        return parts
    }

    /// Compiled once: every header lookup decodes words, and a message can have thousands of parts.
    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#)

    /// RFC 2047 encoded words: "=?utf-8?B?…?=" and "=?iso-8859-1?Q?…?=".
    static func decodeWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let regex = encodedWord
        var result = ""
        var last = text.startIndex
        var previousWasWord = false
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let charsetRange = Range(match.range(at: 1), in: text),
                  let modeRange = Range(match.range(at: 2), in: text), let payloadRange = Range(match.range(at: 3), in: text) else { continue }
            let between = String(text[last..<whole.lowerBound])
            // Whitespace between two encoded words is dropped.
            if !(previousWasWord && between.allSatisfy(\.isWhitespace)) { result += between }
            let payload = String(text[payloadRange])
            let bytes: Data = text[modeRange].lowercased() == "b"
                ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters) ?? Data()
                : quotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            let encoding = CFStringConvertIANACharSetNameToEncoding(String(text[charsetRange]).split(separator: "*").first.map(String.init)! as CFString)
            let decoded = encoding != kCFStringEncodingInvalidId
                ? String(data: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) : nil
            result += decoded ?? String(decoding: bytes, as: UTF8.self)
            last = whole.upperBound
            previousWasWord = true
        }
        result += text[last...]
        return result
    }

    static func quotedPrintable(_ data: Data) -> Data {
        var out = Data()
        let bytes = [UInt8](data)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        while i < bytes.count {
            let c = bytes[i]
            if c == 61 {   // "="
                if i + 2 < bytes.count, let high = hex(bytes[i + 1]), let low = hex(bytes[i + 2]) {
                    out.append(high << 4 | low); i += 3; continue
                }
                // Soft line break.
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
            }
            out.append(c)
            i += 1
        }
        return out
    }
}
