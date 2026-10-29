import Foundation

/// What `\usepackage[<language>]{babel}` changes in LaTeX's typesetting of a language (DocKit's LaTeX loads babel for
/// the document's language, so TeX's run of it — the parity golden, quality §3.7 — sets these too). Values as babel 3
/// leaves them (read back from TeX under Tectonic 0.17: `\sfcode`, `\lefthyphenmin`/`\righthyphenmin`, `\@afterindent`
/// after a heading). Other languages get none of these and their patterns' own hyphenation minimums; "As written"
/// gets `none`.
struct LanguageConventions: Sendable {
    /// `\frenchspacing`: no extra space after a sentence, and every punctuation mark's space stretches alike.
    var frenchSpacing: Bool
    /// The first paragraph after a heading is indented too (babel-french's IndentFirst; spanish.ldf's default layout).
    var indentFirst: Bool
    /// babel-french's high punctuation: a thin non-breaking space (half an inter-word space) before ; ! ? and a
    /// non-breaking inter-word space before :, in place of the space typed there (or added where none was).
    var frenchPunctuation: Bool
    /// `\lefthyphenmin`/`\righthyphenmin`; nil for a language babel is not loaded for (the patterns' own values).
    var hyphenMins: (left: Int, right: Int)?

    static let none = LanguageConventions()
    private static let latexDefault = LanguageConventions(hyphenMins: (2, 3))

    /// The conventions of a language code ("fr", "de-DE", "pt_BR").
    init(language: String?) {
        switch (language ?? "en").lowercased().prefix(while: \.isLetter) {
        case "en": self = .latexDefault
        case "de", "sv", "da", "fi": self.init(frenchSpacing: true, hyphenMins: (2, 2))
        case "fr": self.init(frenchSpacing: true, indentFirst: true, frenchPunctuation: true, hyphenMins: (2, 3))
        case "es": self.init(frenchSpacing: true, indentFirst: true, hyphenMins: (2, 2))
        case "it": self.init(hyphenMins: (2, 2))
        case "nl", "pt": self = .latexDefault
        case "pl", "cs": self.init(frenchSpacing: true, hyphenMins: (2, 3))
        default: self.init()
        }
    }

    private init(frenchSpacing: Bool = false, indentFirst: Bool = false, frenchPunctuation: Bool = false, hyphenMins: (left: Int, right: Int)? = nil) {
        self.frenchSpacing = frenchSpacing; self.indentFirst = indentFirst; self.frenchPunctuation = frenchPunctuation; self.hyphenMins = hyphenMins
    }
}
