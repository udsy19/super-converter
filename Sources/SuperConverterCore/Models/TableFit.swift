import Foundation

/// How the LaTeX look fits a table to the text block (quality §3.3, the Tables row): at its natural width when it fits,
/// else at `\small`, then `\footnotesize`; a table of figures and short labels then turns onto landscape pages of its
/// own, while a table with sentences in its cells wraps its columns as `p{}` columns would. TypesetKit lays tables out by
/// this plan and DocKit's `LaTeXWriter` writes the same decisions as LaTeX, so TypesetKit's PDF and TeX's run on that
/// LaTeX agree (the parity test, quality §3.7). Widths are TeX points.
public struct TableFit: Equatable, Sendable {
    /// The size the table is set at.
    public enum Size: CaseIterable, Sendable {
        case normal, small, footnote   // \normalsize, \small, \footnotesize
    }

    /// Each column's width at one size: `natural`, the widest cell set on one line; `minimum`, its longest word
    /// (at most 6 em: a longer one breaks).
    public struct Columns: Sendable {
        public var natural: [Double]
        public var minimum: [Double]
        public init(natural: [Double], minimum: [Double]) { self.natural = natural; self.minimum = minimum }
    }

    public var size: Size
    /// The width of each column's contents (`\tabcolsep` on either side comes on top).
    public var widths: [Double]
    /// Some columns are narrower than their contents: their cells wrap.
    public var wrap: Bool
    /// On landscape pages of its own (the text block turned: `landscapeWidth` wide).
    public var landscape = false
    /// Too wide even wrapped at its longest words: `\footnotesize` columns squeezed to the measure, long words broken.
    public var squeezed = false

    public init(size: Size, widths: [Double], wrap: Bool, landscape: Bool = false, squeezed: Bool = false) {
        self.size = size; self.widths = widths; self.wrap = wrap; self.landscape = landscape; self.squeezed = squeezed
    }

    /// `\tabcolsep`.
    public static let tabcolsep = 6.0

    /// A cell holds a sentence when it has six words or more.
    public static func isProse(_ text: String) -> Bool { text.split(whereSeparator: \.isWhitespace).count >= 6 }

    /// The plan for a table whose columns measure `columns(size)` at each size, in a text block `textWidth` wide.
    /// `landscapeWidth` is the turned text block's width (`\textheight`), nil where the table may not turn (in a list,
    /// in two columns, a spreadsheet); a table with sentences in its cells (`prose`) never turns.
    public static func plan(textWidth: Double, landscapeWidth: Double?, prose: Bool, columns: (Size) -> Columns) -> TableFit {
        var measured: [Size: Columns] = [:]
        func at(_ size: Size) -> Columns {
            if let c = measured[size] { return c }
            let c = columns(size)
            measured[size] = c
            return c
        }
        let count = at(.normal).natural.count
        let padding = 2 * tabcolsep * Double(count)
        let available = textWidth - padding
        for size in Size.allCases {
            let natural = at(size).natural
            if natural.reduce(0, +) <= available { return TableFit(size: size, widths: natural, wrap: false) }
        }
        if let landscapeWidth, !prose {
            for size in Size.allCases {
                let natural = at(size).natural
                if natural.reduce(0, +) <= landscapeWidth - padding { return TableFit(size: size, widths: natural, wrap: false, landscape: true) }
            }
        }
        for size in Size.allCases {
            let c = at(size)
            if c.minimum.reduce(0, +) <= available {
                return TableFit(size: size, widths: distribute(natural: c.natural, minimum: c.minimum, available: available), wrap: true)
            }
        }
        let natural = at(.footnote).natural
        let total = max(natural.reduce(0, +), 1)
        return TableFit(size: .footnote, widths: natural.map { max(12, $0 / total * available) }, wrap: true, squeezed: true)
    }

    /// Widths that fit `available`: columns that need no wrapping keep their natural width; the rest share what is left
    /// in proportion to their natural widths, never below their longest word.
    static func distribute(natural: [Double], minimum: [Double], available: Double) -> [Double] {
        var widths = natural
        var fixed = Set<Int>()
        for _ in natural.indices {
            let flexible = natural.indices.filter { !fixed.contains($0) }
            let rest = available - fixed.reduce(0.0) { $0 + widths[$1] }
            let flexNatural = flexible.reduce(0.0) { $0 + natural[$1] }
            var changed = false
            for j in flexible {
                let share = flexNatural > 0 ? rest * natural[j] / flexNatural : rest / Double(flexible.count)
                if natural[j] <= share { widths[j] = natural[j]; fixed.insert(j); changed = true }
                else if minimum[j] > share { widths[j] = minimum[j]; fixed.insert(j); changed = true }
                else { widths[j] = share }
            }
            if !changed { break }
        }
        return widths
    }
}
