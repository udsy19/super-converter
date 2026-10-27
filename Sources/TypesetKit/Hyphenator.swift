import CoreFoundation
import Foundation
import NaturalLanguage

/// Hyphenation points from Apple's dictionaries (`CFStringGetHyphenationLocationBeforeIndex`, quality §3.3), with TeX's
/// `\lefthyphenmin` 2 and `\righthyphenmin` 3. Words with digits, all capitals, words shorter than five letters, URLs
/// and code are never hyphenated.
final class Hyphenator {
    let locale: CFLocale
    private var cache: [String: [Int]] = [:]

    /// Nil when macOS has no hyphenation dictionary for the language.
    init?(language: String?) {
        let locale = Locale(identifier: language ?? "en_US") as CFLocale
        guard CFStringIsHyphenationAvailableForLocale(locale) else { return nil }
        self.locale = locale
    }

    /// The dominant language of a text (NaturalLanguage), as a locale identifier hyphenation understands.
    static func detectLanguage(_ text: String) -> String? {
        let recogniser = NLLanguageRecognizer()
        recogniser.processString(String(text.prefix(2000)))
        guard let language = recogniser.dominantLanguage else { return nil }
        let map = ["en": "en_US", "de": "de_DE", "fr": "fr_FR", "es": "es_ES", "it": "it_IT", "pt": "pt_PT",
                   "nl": "nl_NL", "sv": "sv_SE", "da": "da_DK", "nb": "nb_NO", "fi": "fi_FI", "ru": "ru_RU",
                   "pl": "pl_PL", "cs": "cs_CZ", "hu": "hu_HU", "tr": "tr_TR", "uk": "uk_UA", "el": "el_GR"]
        return map[language.rawValue] ?? language.rawValue
    }

    /// Offsets (in UTF-16 units of `word`) where the word may be broken, ascending.
    func points(in word: String) -> [Int] {
        if let cached = cache[word] { return cached }
        let letters = word.filter(\.isLetter)
        let wordlike = word.allSatisfy { $0.isLetter || $0 == "\u{2019}" || $0 == "'" }
        guard letters.count >= 5, wordlike, word != word.uppercased() else {
            cache[word] = []
            return []
        }
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
        let filtered = result.reversed().filter { p in
            ns.substring(to: p).filter(\.isLetter).count >= 2 && ns.substring(from: p).filter(\.isLetter).count >= 3
        }
        cache[word] = filtered
        return filtered
    }
}
