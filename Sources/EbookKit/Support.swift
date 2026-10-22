import CoreFoundation
import Foundation
import ImageIO
import SuperConverterCore

/// Decoding bytes into text the way e-book files declare it: BOM, then the XML declaration or `<meta charset>`, then UTF-8,
/// then Windows-1252.
enum TextDecoding {
    static func string(from data: Data, hint: String? = nil) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        let head = String(decoding: data.prefix(1024), as: UTF8.self)
        let declared = hint ?? declaredCharset(in: head)
        if let name = declared?.lowercased(), name != "utf-8", name != "utf8",
           let encoding = encoding(named: name), let s = String(data: data, encoding: encoding) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    static func declaredCharset(in head: String) -> String? {
        for pattern in ["encoding=[\"']([A-Za-z0-9_\\-]+)[\"']", "charset=[\"']?([A-Za-z0-9_\\-]+)"] {
            if let r = head.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let match = String(head[r])
                if let eq = match.firstIndex(of: "=") {
                    return String(match[match.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                }
            }
        }
        return nil
    }

    static func encoding(named name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}

/// Paths inside a container: always `/`-separated, never absolute, never above the root.
enum PackagePath {
    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// `href` resolved against the file at `base`, without query or fragment, percent-decoded, `.`/`..` collapsed.
    static func resolve(_ href: String, against base: String) -> String {
        var h = href
        if let hash = h.firstIndex(of: "#") { h = String(h[..<hash]) }
        if let q = h.firstIndex(of: "?") { h = String(h[..<q]) }
        h = h.removingPercentEncoding ?? h
        let combined = h.hasPrefix("/") ? h : (directory(of: base).isEmpty ? h : directory(of: base) + "/" + h)
        return normalise(combined)
    }

    static func normalise(_ path: String) -> String {
        var parts: [String] = []
        for part in path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(part))
        }
        return parts.joined(separator: "/")
    }

    static func fragment(of href: String) -> String? {
        guard let hash = href.firstIndex(of: "#") else { return nil }
        let f = String(href[href.index(after: hash)...])
        return f.isEmpty ? nil : f
    }

    /// True for `http:`, `mailto:`, `data:` and the like.
    static func isExternal(_ href: String) -> Bool {
        guard let colon = href.firstIndex(of: ":") else { return false }
        let scheme = href[..<colon]
        return !scheme.isEmpty && scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }

    /// Percent-encodes a relative path for use in an `href`/`src`/`full-path`.
    static func encode(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0) }
            .joined(separator: "/")
    }

    /// `to` relative to the directory of `from` (both container paths).
    static func relative(_ to: String, from: String) -> String {
        let a = directory(of: from).split(separator: "/").map(String.init)
        let b = to.split(separator: "/").map(String.init)
        var k = 0
        while k < a.count, k < b.count - 1, a[k] == b[k] { k += 1 }
        return (Array(repeating: "..", count: a.count - k) + b[k...]).joined(separator: "/")
    }
}

enum MediaTypes {
    static func forPath(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "xhtml", "xht": return "application/xhtml+xml"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg", "jpe": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ncx": return "application/x-dtbncx+xml"
        case "opf": return "application/oebps-package+xml"
        case "js": return "text/javascript"
        case "mp3": return "audio/mpeg"
        case "mp4", "m4v": return "video/mp4"
        case "xml": return "application/xml"
        case "txt": return "text/plain"
        default: return "application/octet-stream"
        }
    }

    /// The type of picture bytes by their signature, else by the name.
    static func forImage(_ data: Data, name: String = "") -> String {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if b.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if b.count >= 12, b[0..<4] == [0x52, 0x49, 0x46, 0x46], b[8..<12] == [0x57, 0x45, 0x42, 0x50] { return "image/webp" }
        if String(decoding: data.prefix(512), as: UTF8.self).contains("<svg") { return "image/svg+xml" }
        let byName = forPath(name)
        return byName == "application/octet-stream" ? "image/jpeg" : byName
    }

    static func fileExtension(for mediaType: String) -> String {
        switch mediaType {
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/svg+xml": "svg"
        case "image/webp": "webp"
        case "image/avif": "avif"
        case "text/css", "text/x-oeb1-css": "css"
        case "font/ttf", "application/x-font-ttf", "application/vnd.ms-opentype" : "ttf"
        case "font/otf", "application/x-font-opentype": "otf"
        case "font/woff", "application/font-woff": "woff"
        case "font/woff2": "woff2"
        default: "bin"
        }
    }

    static func isImage(_ mediaType: String) -> Bool { mediaType.hasPrefix("image/") }
    static func isDocument(_ mediaType: String) -> Bool {
        ["application/xhtml+xml", "text/html", "text/x-oeb1-document", "application/x-dtbook+xml"].contains(mediaType)
    }

    /// Pixel size of a picture, or nil when ImageIO cannot read it (SVG).
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }
}

extension Date {
    /// Parses the date forms OPF, FB2 and ComicInfo use: `2024`, `2024-05`, `2024-05-17`, full ISO 8601.
    static func fromBookDate(_ text: String) -> Date? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: t) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: t) { return d }
        let parts = t.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard let year = parts.first, (1...9999).contains(year) else { return nil }
        var c = DateComponents()
        c.year = year; c.month = parts.count > 1 ? parts[1] : 1; c.day = parts.count > 2 ? parts[2] : 1
        c.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)
    }

    var bookDate: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }

    var isoSeconds: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: self)
    }
}

/// Natural ordering for page names (`page2` before `page10`), the order comics are read in.
func naturalLess(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [.numeric, .caseInsensitive, .diacriticInsensitive]) == .orderedAscending
}
