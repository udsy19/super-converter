import CoreText
import Foundation

/// Picks the font for a run: Latin Modern at the optical size LaTeX would use, or, in the "As written" look, the
/// document's own font (Carlito and Caladea for Calibri and Cambria). Keeps a list of fonts that had to be replaced
/// for the loss note.
final class FontResolver {
    let library: FontLibrary
    let latex: Bool
    let sans: Bool
    let normalSize: Double
    private(set) var replaced: Set<String> = []
    private var cache: [RunStyle: CTFont] = [:]

    init(library: FontLibrary, latex: Bool, sans: Bool, normalSize: Double) {
        self.library = library; self.latex = latex; self.sans = sans; self.normalSize = normalSize
    }

    func font(for style: RunStyle) -> CTFont {
        var key = style
        key.colour = nil; key.underline = false; key.strike = false; key.isURL = false; key.verbatim = false; key.script = .none
        if let f = cache[key] { return f }
        let f: CTFont
        if !latex, let name = style.documentFont {
            let r = library.documentFont(named: name, size: style.size, bold: style.bold, italic: style.italic)
            if let note = r.replaced { replaced.insert(note) }
            f = r.font
        } else {
            f = library.latinModern(style.family == .roman && sans ? .sans : style.family, bold: style.bold, shape: style.shape,
                                    size: style.size)
        }
        cache[key] = f
        return f
    }

    /// The upright or italic text font at `size`, or the typewriter one (math's `\text`, `\textbf`, `\texttt`).
    func textFont(size: Double, bold: Bool, italic: Bool, mono: Bool) -> CTFont {
        font(for: RunStyle(family: mono ? .mono : .roman, bold: bold, shape: italic ? .italic : .upright, size: size))
    }
}
