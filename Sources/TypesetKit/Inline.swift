import CoreGraphics
import Foundation

/// How a run of text is set: the font choice, size, and decorations.
struct RunStyle: Hashable {
    enum Script: Hashable { case none, raised, lowered }

    var family: FontLibrary.Family = .roman
    var bold = false
    var shape: FontLibrary.Shape = .upright
    var size: Double
    /// "As written": the document's own font name (else Latin Modern).
    var documentFont: String? = nil
    /// "#RRGGBB".
    var colour: String? = nil
    var underline = false
    var strike = false
    var script: Script = .none
    /// Code, URLs and the like: never hyphenated and never given smart punctuation.
    var verbatim = false
    var isURL = false

    var italic: Bool { shape == .italic || shape == .slanted }
}

/// A paragraph's content before it is broken into lines.
enum InlinePiece {
    case text(String, RunStyle)
    case math(String, RunStyle)
    /// A footnote mark with its number.
    case footnote(Int, RunStyle)
    case image(ImageContent, width: Double, height: Double)
    /// `\\`: ends the line here.
    case lineBreak
    /// Horizontal glue (the em after a run-in heading, `\quad` after a section number).
    case hskip(Glue)
    case box(HBox)
    case linkStart(String)
    case linkEnd
}

// MARK: TeX punctuation (quality §3.1 item 5)

enum Punctuation {
    /// Curly quotes from straight ones, `--`/`---` to en and em dashes, `...` to an ellipsis — what TeX's ligatures and
    /// a careful author give. `previous` is the character before `text` in the paragraph (for the quote direction).
    static func smarten(_ text: String, after previous: Character?) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        let chars = Array(text)
        var prev = previous
        var i = 0
        func opensQuote(_ p: Character?) -> Bool {
            guard let p else { return true }
            return p.isWhitespace || "([{<\u{2014}\u{2013}-/\u{201C}\u{2018}".contains(p)
        }
        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "\"":
                out.append(opensQuote(prev) && !(next?.isWhitespace ?? true) ? "\u{201C}" : "\u{201D}")
            case "'":
                let decade = next?.isNumber == true && i + 2 < chars.count && chars[i + 2].isNumber
                out.append(opensQuote(prev) && !(next?.isWhitespace ?? true) && !decade ? "\u{2018}" : "\u{2019}")
            case "`":
                out.append("\u{2018}")
            case "-" where next == "-":
                if i + 2 < chars.count && chars[i + 2] == "-" { out.append("\u{2014}"); i += 2 } else { out.append("\u{2013}"); i += 1 }
            case "." where next == "." && i + 2 < chars.count && chars[i + 2] == ".":
                out.append("\u{2026}"); i += 2
            default:
                out.append(c)
            }
            prev = out.last
            i += 1
        }
        return out
    }
}

// MARK: Space factors (quality §3.3)

enum SpaceFactor {
    /// Plain TeX's `\sfcode`: 3000 after .?!, 2000 after :, 1500 after ;, 1250 after a comma, 999 for capitals, 0 for
    /// closing quotes and brackets (they keep the factor of the character before them).
    static func code(_ c: Character) -> Int {
        switch c {
        case ".", "?", "!", "\u{2026}": return 3000
        case ":": return 2000
        case ";": return 1500
        case ",": return 1250
        case ")", "]", "'", "\"", "\u{2019}", "\u{201D}", "*": return 0
        default: return c.isUppercase ? 999 : 1000
        }
    }

    /// The space factor after `word` (TeX's rule: a code above 1000 after a factor below 1000 gives 1000, so "U.S. Army"
    /// and initials get normal spaces).
    static func after(_ word: String) -> Int {
        var sf = 1000
        for c in word {
            let code = code(c)
            if code == 0 { continue }
            sf = code > 1000 && sf < 1000 ? 1000 : code
        }
        return sf
    }

    /// Abbreviations after which a period does not end a sentence (what an author marks with `\ ` or `~`).
    static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "cf.", "vs.", "al.", "fig.", "figs.", "eq.", "eqs.", "no.", "nos.", "vol.", "pp.", "p.", "ch.",
        "sec.", "dr.", "mr.", "mrs.", "ms.", "prof.", "st.", "jr.", "sr.", "approx.", "resp.", "viz.", "ca.", "c.",
    ]
}
