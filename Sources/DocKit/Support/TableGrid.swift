import Foundation
import SuperConverterCore

/// A table as a rectangular grid: `DocTable` rows list only the cells that start in them, so the rest of a span shows up
/// here as `covered`. Writers whose format wants every position (RST, plain text, LaTeX, Markdown, DOCX, ODT) use this.
enum TableGrid {
    struct Slot {
        /// Why a position has no cell of its own.
        enum Covered { case none, above, left, missing }

        /// The cell that starts here; nil where an earlier cell's span covers the position (or the row is short).
        var cell: DocTable.Cell?
        var covered = Covered.none
    }

    /// The widest span a reader keeps and the most columns a grid has (HTML's own colspan limit): the writers allocate a slot
    /// per position, and a damaged file can claim a span of billions.
    static let maxSpan = 1_000

    /// A span read from a file: at least 1, at most `maxSpan`.
    static func span(_ value: Int?) -> Int { min(max(value ?? 1, 1), maxSpan) }

    static func columnCount(_ table: DocTable) -> Int {
        min(max(table.rows.map { $0.reduce(0) { $0 + span($1.columnSpan) } }.max() ?? 1, 1), maxSpan)
    }

    /// Rows of exactly `columns` slots; a spanning cell sits in its first slot and the slots it covers say which way: `above`
    /// (the rest of a row span), `left` (the rest of a column span) or `missing` (a short row).
    static func expand(_ table: DocTable) -> (columns: Int, rows: [[Slot]]) {
        let columns = columnCount(table)
        var pending = [Int](repeating: 0, count: columns)
        var out: [[Slot]] = []
        for row in table.rows {
            var slots = [Slot](repeating: Slot(cell: nil, covered: .missing), count: columns)
            var column = 0
            var cells = row[...]
            while column < columns {
                if pending[column] > 0 { slots[column].covered = .above; pending[column] -= 1; column += 1; continue }
                guard let cell = cells.popFirst() else { break }
                slots[column].cell = cell
                slots[column].covered = .none
                let span = max(min(cell.columnSpan, columns - column), 1)
                for c in column + 1..<column + span { slots[c].covered = .left }
                if cell.rowSpan > 1 { for c in column..<column + span { pending[c] = cell.rowSpan - 1 } }
                column += span
            }
            out.append(slots)
        }
        return (columns, out)
    }

    /// True when any cell spans rows or columns.
    static func hasSpans(_ table: DocTable) -> Bool {
        table.rows.contains { $0.contains { $0.columnSpan > 1 || $0.rowSpan > 1 } }
    }
}

enum TextWrap {
    /// Greedy word wrap at `width` columns; existing line breaks stay.
    static func wrap(_ text: String, width: Int, indent: String = "") -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var lines: [String] = []
            var current = ""
            for word in line.split(separator: " ", omittingEmptySubsequences: true) {
                if current.isEmpty { current = String(word) }
                else if current.count + 1 + word.count <= width { current += " " + word }
                else { lines.append(current); current = indent + word }
            }
            lines.append(current)
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
