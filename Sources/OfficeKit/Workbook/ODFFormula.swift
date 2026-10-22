import Foundation

// Formulas between the Excel text the Workbook keeps ("SUM(A1:B2,Sheet2!C3)") and OpenDocument's ("of:=SUM([.A1:.B2];[$Sheet2.C3])").
// References are rewritten; function names are shared by both. Text in double quotes is left alone.

enum ODFFormula {
    private static let excelReference = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.$\]])((?:'(?:[^']|'')+'|[A-Za-z_][A-Za-z0-9_.]*)!)?(\$?[A-Z]{1,3}\$?[0-9]{1,7})(?::(\$?[A-Z]{1,3}\$?[0-9]{1,7}))?(?![A-Za-z0-9_(])"#)
    private static let odfReference = try! NSRegularExpression(
        pattern: #"\[(\$?(?:'(?:[^']|'')+'|[^.\]:]+))?\.(\$?[A-Z]{1,3}\$?[0-9]{1,7})(?::(?:(?:\$?(?:'(?:[^']|'')+'|[^.\]:]+))?\.)?(\$?[A-Z]{1,3}\$?[0-9]{1,7}))?\]"#)

    /// The OpenDocument form ("of:=…") of an Excel-style formula without its "=".
    static func toODF(_ formula: String) -> String {
        "of:=" + mapUnquoted(formula) { part in
            let ns = part as NSString
            var out = "", last = 0
            for match in excelReference.matches(in: part, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let sheet = match.range(at: 1).location == NSNotFound ? nil : String(ns.substring(with: match.range(at: 1)).dropLast())
                let start = ns.substring(with: match.range(at: 2))
                let end = match.range(at: 3).location == NSNotFound ? nil : ns.substring(with: match.range(at: 3))
                out += "[" + (sheet.map { "$" + $0 } ?? "") + "." + start + (end.map { ":." + $0 } ?? "") + "]"
                last = match.range.location + match.range.length
            }
            return (out + ns.substring(from: last)).replacingOccurrences(of: ",", with: ";")
        }
    }

    /// The Excel-style text (no "=") of an OpenDocument formula; nil when it is in another formula language.
    static func toExcel(_ formula: String) -> String? {
        var text = formula
        if text.hasPrefix("of:") { text.removeFirst(3) } else if text.contains(":=") && !text.hasPrefix("=") { return nil }
        if text.hasPrefix("=") { text.removeFirst() }
        // References first (their sheet names may hold odd characters), then separators outside quotes.
        let ns = text as NSString
        var out = "", last = 0
        for match in odfReference.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            var sheet = match.range(at: 1).location == NSNotFound ? "" : ns.substring(with: match.range(at: 1))
            if sheet.hasPrefix("$") { sheet.removeFirst() }
            let start = ns.substring(with: match.range(at: 2))
            let end = match.range(at: 3).location == NSNotFound ? nil : ns.substring(with: match.range(at: 3))
            out += (sheet.isEmpty ? "" : sheet + "!") + start + (end.map { ":" + $0 } ?? "")
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        return mapUnquoted(out) { $0.replacingOccurrences(of: ";", with: ",") }
    }

    /// Applies `transform` to the runs outside double quotes.
    private static func mapUnquoted(_ text: String, _ transform: (String) -> String) -> String {
        var out = "", run = ""
        var quoted = false
        for ch in text {
            if ch == "\"" {
                if quoted { run.append(ch); out += run; run = ""; quoted = false } else { out += transform(run); run = "\""; quoted = true }
            } else {
                run.append(ch)
            }
        }
        return out + (quoted ? run : transform(run))
    }
}
