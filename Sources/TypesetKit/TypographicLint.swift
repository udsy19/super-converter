import Foundation

/// The typographic lint every TypesetKit PDF passes (quality §3.7): no overfull line (more than 0.1 pt past the
/// margin), no line with badness above 200 outside the emergency pass, at most two hyphenated lines in a row, no widow
/// or orphan unless the paragraph has two lines or fewer, and no heading as the last line of a page.
public enum TypographicLint {
    public static func check(_ log: TypesetLog) -> [String] {
        var problems: [String] = []
        var run = 0
        var lastParagraph = -2
        for line in log.lines {
            let place = "page \(line.page): “\(line.text.prefix(40))”"
            if line.overfull > 0.1 { problems.append("Overfull by \(String(format: "%.2f", line.overfull)) pt on \(place)") }
            if line.badness > 200 && !line.emergency && !line.isHeading && line.lineInParagraph < line.linesInParagraph - 1 {
                problems.append("Badness \(line.badness) on \(place)")
            }
            if line.paragraph != lastParagraph { run = 0; lastParagraph = line.paragraph }
            run = line.hyphenated ? run + 1 : 0
            if run > 2 { problems.append("More than two hyphenated lines in a row on \(place)") }
            if line.paragraph >= 0 && line.linesInParagraph > 2 {
                if line.firstOnPage && line.lineInParagraph == line.linesInParagraph - 1 { problems.append("Widow on \(place)") }
                if line.lastOnPage && line.lineInParagraph == 0 && line.page < log.pages { problems.append("Orphan on \(place)") }
            }
            if line.isHeading && line.lastOnPage && line.page < log.pages { problems.append("Heading at the foot of \(place)") }
        }
        return problems
    }
}
