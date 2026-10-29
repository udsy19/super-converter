import CoreFoundation
import Foundation
import NaturalLanguage

/// Hyphenation points (quality §3.3): TeX's Liang patterns from hyph-utf8 for the languages with a permissive pattern
/// licence (Resources/Hyphenation: English, German, French, Spanish, Dutch, Polish, Portuguese, Ukrainian, Danish,
/// Greek), so breaks match `pdflatex`; Apple's dictionaries (`CFStringGetHyphenationLocationBeforeIndex`) for the
/// rest. TeX's `\lefthyphenmin`/`\righthyphenmin` (2 and 3 for English, the pattern file's own values otherwise). Words
/// with digits, all capitals, words shorter than five letters, URLs and code are never hyphenated.
public final class Hyphenator {
    private enum Source {
        case patterns(LiangPatterns)
        case apple(CFLocale)
    }
    private let source: Source
    /// Whether TeX's patterns (rather than Apple's dictionary) hyphenate this language.
    public var usesTeXPatterns: Bool { if case .patterns = source { true } else { false } }
    private var cache: [String: [Int]] = [:]

    /// Nil when there are neither patterns nor a macOS dictionary for the language.
    public init?(language: String?) {
        let id = (language ?? "en_US").replacingOccurrences(of: "_", with: "-").lowercased()
        if let patterns = LiangPatterns.load(for: id) {
            source = .patterns(patterns)
        } else {
            let locale = Locale(identifier: language ?? "en_US") as CFLocale
            guard CFStringIsHyphenationAvailableForLocale(locale) else { return nil }
            source = .apple(locale)
        }
    }

    /// The dominant language of a text (NaturalLanguage), as a locale identifier hyphenation understands.
    public static func detectLanguage(_ text: String) -> String? {
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(String(text.prefix(2000)))
        guard let language = recogniser.dominantLanguage else { return nil }
        let map = ["en": "en_US", "de": "de_DE", "fr": "fr_FR", "es": "es_ES", "it": "it_IT", "pt": "pt_PT",
                   "nl": "nl_NL", "sv": "sv_SE", "da": "da_DK", "nb": "nb_NO", "fi": "fi_FI", "ru": "ru_RU",
                   "pl": "pl_PL", "cs": "cs_CZ", "hu": "hu_HU", "tr": "tr_TR", "uk": "uk_UA", "el": "el_GR"]
        return map[language.rawValue] ?? language.rawValue
    }

    /// Offsets (in UTF-16 units of `word`) where the word may be broken, ascending.
    public func points(in word: String) -> [Int] {
        if let cached = cache[word] { return cached }
        let letters = word.filter(\.isLetter)
        let wordlike = word.allSatisfy { $0.isLetter || $0 == "\u{2019}" || $0 == "'" }
        guard letters.count >= 5, wordlike, word != word.uppercased() else {
            cache[word] = []
            return []
        }
        let result: [Int]
        switch source {
        case .patterns(let patterns): result = patterns.points(in: word)
        case .apple(let locale): result = Self.applePoints(word, locale)
        }
        cache[word] = result
        return result
    }

    private static func applePoints(_ word: String, _ locale: CFLocale) -> [Int] {
        let ns = word as NSString
        var result: [Int] = []
        var index = ns.length
        while index > 0 {
            var ch: UTF32Char = 0
            let p = CFStringGetHyphenationLocationBeforeIndex(word as CFString, index, CFRange(location: 0, length: ns.length), 0, locale, &ch)
            if p == kCFNotFound || p <= 0 || p >= index { break }
            result.append(p)
            index = p
        }
        return result.reversed().filter { p in
            ns.substring(to: p).filter(\.isLetter).count >= 2 && ns.substring(from: p).filter(\.isLetter).count >= 3
        }
    }
}

/// One language's Liang patterns and exceptions, read from a hyph-utf8 `.tex` file (`\patterns{…}`, `\hyphenation{…}`
/// and the `hyphenmins: typesetting:` header). Algorithm: Liang, "Word Hy-phen-a-tion by Com-put-er" (1983), as
/// TeX §919–§965 applies it.
final class LiangPatterns: @unchecked Sendable {
    /// Pattern letters → the digits between them (count = letters + 1).
    private var patterns: [String: [UInt8]] = [:]
    private var exceptions: [String: [Int]] = [:]
    private var longest = 0
    private(set) var leftMin = 2
    private(set) var rightMin = 3

    /// Language (lower case, `-` separated) → pattern file, by most specific prefix.
    static let files: [(String, String)] = [
        ("en-gb", "hyph-en-gb"), ("en", "hyph-en-us"), ("de", "hyph-de-1996"), ("es", "hyph-es"), ("fr", "hyph-fr"),
        ("nl", "hyph-nl"), ("pl", "hyph-pl"), ("pt", "hyph-pt"), ("uk", "hyph-uk"), ("da", "hyph-da"), ("el", "hyph-el-monoton"),
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: LiangPatterns] = [:]

    /// The patterns for a language, parsed once per process; nil when no bundled file covers it.
    static func load(for language: String) -> LiangPatterns? {
        guard let file = files.first(where: { language == $0.0 || language.hasPrefix($0.0 + "-") })?.1 else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let p = loaded[file] { return p }
        guard let url = directory()?.appendingPathComponent(file + ".tex"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let p = LiangPatterns(tex: text, english: file.hasPrefix("hyph-en"))
        loaded[file] = p
        return p
    }

    /// `Contents/Resources/Hyphenation` in the app, else the repository's `Resources/Hyphenation` (SwiftPM builds).
    static func directory() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("Hyphenation")) }
        var source = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { source.deleteLastPathComponent() }   // <root>/Sources/TypesetKit/Hyphenator.swift → <root>
        candidates.append(source.appendingPathComponent("Resources/Hyphenation"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("hyph-en-us.tex").path) }
    }

    init(tex: String, english: Bool) {
        var section = ""   // "patterns", "hyphenation" or ""
        var inMins = false, inTypesetting = false
        for raw in tex.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("%") {
                // The YAML-like header: `% hyphenmins:` / `%     typesetting:` / `%         left: 2`.
                let body = line.drop { $0 == "%" }.trimmingCharacters(in: .whitespaces)
                if body == "hyphenmins:" { inMins = true; continue }
                if inMins {
                    if body == "typesetting:" { inTypesetting = true; continue }
                    if body == "generation:" { inTypesetting = false; continue }
                    if inTypesetting, let v = body.split(separator: ":").last.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                        if body.hasPrefix("left") { leftMin = v } else if body.hasPrefix("right") { rightMin = v }
                        continue
                    }
                    if !body.hasPrefix("left") && !body.hasPrefix("right") { inMins = false; inTypesetting = false }
                }
                continue
            }
            var content = Substring(line)
            if let comment = content.firstIndex(of: "%") { content = content[..<comment] }
            for token in content.split(whereSeparator: \.isWhitespace) {
                var t = Substring(token)
                if t.hasPrefix("\\patterns{") { section = "patterns"; t = t.dropFirst("\\patterns{".count) }
                else if t.hasPrefix("\\hyphenation{") { section = "hyphenation"; t = t.dropFirst("\\hyphenation{".count) }
                var closes = false
                if t.hasSuffix("}") { closes = true; t = t.dropLast() }
                if !t.isEmpty {
                    if section == "patterns" { addPattern(String(t)) } else if section == "hyphenation" { addException(String(t)) }
                }
                if closes { section = "" }
            }
        }
        // LaTeX's \lefthyphenmin 2 and \righthyphenmin 3 for English (quality §3.3).
        if english { leftMin = 2; rightMin = 3 }
    }

    private func addPattern(_ p: String) {
        var letters = "", digits: [UInt8] = [0]
        for ch in p {
            if let d = ch.wholeNumberValue, ch.isASCII { digits[digits.count - 1] = UInt8(d) }
            else { letters.append(ch); digits.append(0) }
        }
        patterns[letters] = digits
        longest = max(longest, letters.count)
    }

    private func addException(_ e: String) {
        var word = "", points: [Int] = []
        for ch in e { if ch == "-" { points.append(word.count) } else { word.append(ch) } }
        exceptions[word.lowercased()] = points
    }

    /// Break offsets in UTF-16 units of `word`.
    func points(in word: String) -> [Int] {
        let chars = Array(word)
        let lower = chars.map { c -> Character in
            let l = String(c).lowercased()
            return l.count == 1 ? Character(l) : c
        }
        var letterPoints: [Int]   // break before character index
        if let e = exceptions[String(lower)] {
            letterPoints = e
        } else {
            let dotted: [Character] = ["."] + lower + ["."]
            var values = [UInt8](repeating: 0, count: dotted.count + 1)
            for start in 0..<dotted.count {
                var key = ""
                for end in start..<min(dotted.count, start + longest) {
                    key.append(dotted[end])
                    guard let digits = patterns[key] else { continue }
                    for (k, d) in digits.enumerated() where d > values[start + k] { values[start + k] = d }
                }
            }
            // values[i] sits before dotted[i]; dotted[i] is chars[i - 1], so a break before chars[j] is values[j + 1].
            letterPoints = (1..<max(1, chars.count)).filter { values[$0 + 1] % 2 == 1 }
        }
        letterPoints = letterPoints.filter { $0 >= leftMin && chars.count - $0 >= rightMin }
        var offsets: [Int] = [], utf16 = 0, next = 0
        for (i, c) in chars.enumerated() {
            if next < letterPoints.count, letterPoints[next] == i { offsets.append(utf16); next += 1 }
            utf16 += c.utf16.count
        }
        return offsets
    }
}
