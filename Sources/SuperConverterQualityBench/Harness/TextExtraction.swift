import Foundation
import PDFKit

/// Plain text out of any document the bench produces, so a check can compare what a person would read.
enum TextExtraction {
    /// PDF through PDFKit; DOCX, ODT, ODS, XLSX, PPTX and EPUB by reading their XML parts with the tags stripped; anything
    /// else as UTF-8.
    static func text(of url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw CheckFailure("\(url.lastPathComponent) is not a readable PDF") }
            return doc.string ?? ""
        }
        let parts: [String]? = switch ext {
        case "docx": ["word/document.xml"]
        case "odt", "ods", "odp": ["content.xml"]
        case "xlsx": ["xl/sharedStrings.xml", "xl/worksheets/*.xml"]
        case "pptx": ["ppt/slides/*.xml"]
        case "epub": ["*.xhtml", "*.html"]
        default: nil
        }
        guard let parts else {
            let text = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
            return ["html", "htm", "xhtml", "xml", "svg"].contains(ext) ? stripTags(text) : text
        }
        var out = ""
        for part in parts {
            let r = Subprocess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", url.path, part])
            guard r.status == 0 || r.status == 11 else { continue }   // 11: no match for one pattern
            out += stripTags(String(decoding: r.data, as: UTF8.self)) + "\n"
        }
        guard !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CheckFailure("no text in \(url.lastPathComponent)") }
        return out
    }

    /// Markup removed, paragraph and cell ends turned into spaces, entities decoded.
    static func stripTags(_ xml: String) -> String {
        var s = xml
        // What a reader never sees: the head (title, styles, scripts), navigation lists, comments.
        for pattern in ["(?s)<head[\\s>].*?</head>", "(?s)<nav[\\s>].*?</nav>", "(?s)<style[\\s>].*?</style>", "(?s)<script[\\s>].*?</script>", "(?s)<!--.*?-->", "<!DOCTYPE[^>]*>", "<\\?xml[^>]*\\?>"] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        for end in ["</w:p>", "</w:tc>", "</text:p>", "</text:h>", "</a:p>", "</p>", "</h1>", "</h2>", "</li>", "</si>", "</c>", "</v>", "</t>"] { s = s.replacingOccurrences(of: end, with: " ") }
        var out = "", inTag = false
        for ch in s { if ch == "<" { inTag = true } else if ch == ">" { inTag = false; out.append(" ") } else if !inTag { out.append(ch) } }
        return out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
    }
}
