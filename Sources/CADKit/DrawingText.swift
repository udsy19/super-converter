import CoreText
import Foundation

/// Text as DXF stores it: `%%` control codes in TEXT, MTEXT formatting codes, `\U+XXXX` escapes. The plotter lays out the
/// plain strings these produce.
enum DrawingText {
    /// `\U+XXXX` escapes as the characters they stand for (how pre-2007 files carry non-ASCII text).
    static func unicodeEscapes(_ raw: String) -> String {
        guard raw.contains("\\U+") else { return raw }
        var out = ""
        var chars = Array(raw)[...]
        while let c = chars.popFirst() {
            if c == "\\", chars.first == "U", chars.dropFirst().first == "+" {
                let hex = chars.dropFirst(2).prefix(4)
                if hex.count == 4, let n = UInt32(String(hex), radix: 16), let scalar = Unicode.Scalar(n) {
                    out.unicodeScalars.append(scalar); chars.removeFirst(6); continue
                }
            }
            out.append(c)
        }
        return out
    }

    /// `%%c` Ø, `%%d` °, `%%p` ±, `%%nnn` a character code; underline/overline/strike toggles are dropped.
    static func clean(_ raw: String) -> String {
        var out = ""
        var chars = Array(raw)[...]
        while let c = chars.popFirst() {
            if c == "%", chars.first == "%" {
                chars.removeFirst()
                guard let code = chars.first else { break }
                switch code {
                case "c", "C": out.append("Ø"); chars.removeFirst()
                case "d", "D": out.append("°"); chars.removeFirst()
                case "p", "P": out.append("±"); chars.removeFirst()
                case "%": out.append("%"); chars.removeFirst()
                case "u", "U", "o", "O", "k", "K": chars.removeFirst()
                default:
                    let digits = chars.prefix(3).prefix { $0.isNumber }
                    if digits.count == 3, let n = UInt32(String(digits)), let scalar = Unicode.Scalar(n) {
                        out.unicodeScalars.append(scalar); chars.removeFirst(3)
                    } else { out.append("%%") }
                }
            } else if c == "\\", chars.first == "U", chars.dropFirst().first == "+" {
                let hex = chars.dropFirst(2).prefix(4)
                if hex.count == 4, let n = UInt32(String(hex), radix: 16), let scalar = Unicode.Scalar(n) {
                    out.unicodeScalars.append(scalar); chars.removeFirst(6)
                } else { out.append(c) }
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// The paragraphs of an MTEXT string with its formatting codes removed (`\P` ends a paragraph, `\S` stacks become "a/b").
    static func mtextParagraphs(_ raw: String) -> [String] {
        var paragraphs: [String] = []
        var current = ""
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "{", "}":
                i += 1
            case "\\":
                guard i + 1 < chars.count else { i += 1; continue }
                let code = chars[i + 1]
                i += 2
                switch code {
                case "P", "p": paragraphs.append(current); current = ""
                case "\\", "{", "}": current.append(code)
                case "~": current.append("\u{00A0}")
                case "L", "l", "O", "o", "K", "k", "N": break
                case "U" where i < chars.count && chars[i] == "+":
                    // \U+XXXX
                    let hex = chars[(i + 1)...].prefix(4)
                    if hex.count == 4, let n = UInt32(String(hex), radix: 16), let scalar = Unicode.Scalar(n) {
                        current.unicodeScalars.append(scalar); i += 5
                    }
                case "S":
                    var body = ""
                    while i < chars.count, chars[i] != ";" { body.append(chars[i]); i += 1 }
                    i += 1
                    current += body.replacingOccurrences(of: "^", with: "/").replacingOccurrences(of: "#", with: "/")
                default:
                    // \fFont|b0|i0;  \H2.5;  \C1;  \W0.8;  \Q15;  \T1;  \A1; : an argument up to the semicolon.
                    while i < chars.count, chars[i] != ";" { i += 1 }
                    i += 1
                }
            default:
                current.append(c); i += 1
            }
        }
        paragraphs.append(current)
        return paragraphs.map(clean)
    }

    /// Width of `text` in a font, per unit of text height (before any width factor).
    static func width(_ text: String, font fontName: String) -> Double {
        guard !text.isEmpty else { return 0 }
        let font = CTFontCreateWithName(fontName as CFString, 100, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil) / 100
    }

    /// Greedy word wrap of one paragraph to `limit` text-height units (a single long word stays whole).
    static func wrap(_ paragraph: String, limit: Double, font: String) -> [String] {
        guard limit > 0, width(paragraph, font: font) > limit else { return [paragraph] }
        var lines: [String] = []
        var line = ""
        for word in paragraph.split(separator: " ", omittingEmptySubsequences: false) {
            let candidate = line.isEmpty ? String(word) : line + " " + word
            if width(candidate, font: font) <= limit || line.isEmpty { line = candidate } else { lines.append(line); line = String(word) }
        }
        lines.append(line)
        return lines
    }
}
