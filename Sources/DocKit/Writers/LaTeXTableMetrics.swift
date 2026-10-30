import CoreText
import Foundation
import SuperConverterCore

/// Table cells measured as TeX sets them under `LaTeXWriter`'s preamble, for Core's `TableFit` (quality §3.3): the
/// standard classes at 10 pt on letter paper (size10.clo: the text block 345 pt wide and 550 pt tall; `\normalsize`,
/// `\small`, `\footnotesize` at 10, 9 and 8 pt) in Latin Modern at its optical sizes, measured with Core Text in the
/// bundled fonts (Resources/Fonts) — the same files TypesetKit sets with, so both make the same decision.
enum LaTeXTableMetrics {
    static let textWidth = 345.0
    static let textHeight = 550.0
    /// `\leftmargini` … `\leftmarginiv`: how far each list level narrows `\linewidth`.
    static let listMargins = [25.0, 22.0, 18.7, 17.0]

    static func pointSize(_ size: TableFit.Size) -> Double {
        switch size {
        case .normal: 10
        case .small: 9
        case .footnote: 8
        }
    }

    enum Face: CaseIterable { case regular, bold, italic, mono }

    private struct Key: Hashable { let face: Face; let size: TableFit.Size }

    /// Every face at every size, or nil when the bundled fonts are missing (the table is then written at its natural size).
    private static let fonts: [Key: CTFont]? = {
        guard let folder = SuperConverterPaths.bundledResources("Fonts").first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("LatinModern/lmroman10-regular.otf").path)
        }) else { return nil }
        var out: [Key: CTFont] = [:]
        for face in Face.allCases {
            for size in TableFit.Size.allCases {
                let design = Int(pointSize(size))
                let file = switch face {
                case .regular: "lmroman\(design)-regular"
                case .bold: "lmroman\(design)-bold"
                case .italic: "lmroman\(design)-italic"
                case .mono: "lmmono\(design)-regular"
                }
                let url = folder.appendingPathComponent("LatinModern/\(file).otf")
                guard let list = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let d = list.first else { return nil }
                out[Key(face: face, size: size)] = CTFontCreateWithFontDescriptor(d, pointSize(size), nil)
            }
        }
        return out
    }()

    static var available: Bool { fonts != nil }

    /// One line of runs, set without breaks: its width in TeX points (ligatures and kerning as XeTeX applies them).
    static func width(_ runs: [(String, Face)], _ size: TableFit.Size) -> Double {
        guard let fonts else { return 0 }
        let text = NSMutableAttributedString()
        for (s, face) in runs {
            text.append(NSAttributedString(string: s, attributes: [kCTFontAttributeName as NSAttributedString.Key: fonts[Key(face: face, size: size)]!]))
        }
        return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)
    }

    /// A cell's columns at `size`: its widest line (blocks and `\newline`s start lines) and its longest word, at most 6 em.
    static func measure(_ cell: DocTable.Cell, _ size: TableFit.Size) -> (natural: Double, minimum: Double) {
        let lines = cell.blocks.flatMap(lines)
        let natural = lines.map { width($0, size) }.max() ?? 0
        let words = lines.flatMap { line in line.flatMap { s, face in s.split(whereSeparator: \.isWhitespace).map { (String($0), face) } } }
        let minimum = words.map { width([$0], size) }.max() ?? 0
        return (natural, min(minimum, 6 * pointSize(size)))
    }

    /// A cell's words as one string.
    static func text(_ cell: DocTable.Cell) -> String {
        cell.blocks.flatMap(lines).map { $0.map(\.0).joined() }.joined(separator: " ")
    }

    private static func lines(_ block: DocBlock) -> [[(String, Face)]] {
        switch block {
        case .paragraph(let text, _): return lines(text)
        case .heading(_, let text): return lines(text).map { $0.map { ($0.0, Face.bold) } }
        case .code(_, let s): return s.split(separator: "\n", omittingEmptySubsequences: false).map { [(String($0), .mono)] }
        case .math(let tex, _): return [[(tex, .italic)]]
        case .list(_, _, let entries): return entries.flatMap { $0.flatMap(lines) }
        case .quote(let inner): return inner.flatMap(lines)
        default: return []
        }
    }

    private static func lines(_ text: DocText, _ face: Face = .regular) -> [[(String, Face)]] {
        var out: [[(String, Face)]] = [[]]
        for item in text {
            switch item {
            case .text(let t): out[out.count - 1].append((t, face))
            case .code(let t): out[out.count - 1].append((t, .mono))
            case .math(let t): out[out.count - 1].append((t, .italic))
            case .emphasis(let c): append(lines(c, face == .bold ? .bold : .italic), to: &out)
            case .strong(let c): append(lines(c, .bold), to: &out)
            case .link(let c, let destination) where c.plainText == destination: out[out.count - 1].append((destination, .mono))   // \url
            case .strike(let c), .link(let c, _), .styled(let c, _): append(lines(c, face), to: &out)
            case .lineBreak: out.append([])
            case .image, .footnoteReference: break
            }
        }
        return out
    }

    /// Lines of an inline span continue the current line, then start new ones.
    private static func append(_ more: [[(String, Face)]], to out: inout [[(String, Face)]]) {
        guard let first = more.first else { return }
        out[out.count - 1] += first
        out += more.dropFirst()
    }
}
