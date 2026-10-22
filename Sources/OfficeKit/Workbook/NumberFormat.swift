import Foundation
import SuperConverterCore

// Origin: Super PDF Sources/ConvertKit/Import/SpreadsheetImporter.swift @ 058469b (`SheetNumberFormat`), adapted: separators and
// month and weekday names are fixed to English (US) so a conversion gives the same text on every Mac; the decimal
// separator can be changed afterwards (`CSVOptions.decimalSeparator`).

/// An Excel number format code ("#,##0.00", "0.0%", "yyyy-mm-dd", "$#,##0;($#,##0)", "h:mm AM/PM") applied to a value.
/// Separators follow the person's locale, as Excel shows them.
struct SheetNumberFormat: Sendable {
    static let locale = Locale(identifier: "en_US")

    let code: String
    private let sections: [String]
    /// Built-in 14 and 22 follow the system's short date (and time), as Excel does.
    private let localeTemplate: String?
    let isDate: Bool
    let isText: Bool

    init(code: String, builtInID: Int? = nil) {
        self.code = code
        sections = Self.split(code)
        localeTemplate = builtInID == 14 ? "yMd" : builtInID == 22 ? "yMdjm" : nil
        isDate = localeTemplate != nil || sections.first.map(Self.hasDateTokens) ?? false
        isText = code == "@"
    }

    /// The codes of Excel's built-in formats.
    static func builtIn(_ id: Int) -> String {
        switch id {
        case 1: "0"
        case 2: "0.00"
        case 3: "#,##0"
        case 4: "#,##0.00"
        case 5: "$#,##0_);($#,##0)"
        case 6: "$#,##0_);[Red]($#,##0)"
        case 7: "$#,##0.00_);($#,##0.00)"
        case 8: "$#,##0.00_);[Red]($#,##0.00)"
        case 9: "0%"
        case 10: "0.00%"
        case 11: "0.00E+00"
        case 12: "# ?/?"
        case 13: "# ??/??"
        case 14: "m/d/yyyy"
        case 15: "d-mmm-yy"
        case 16: "d-mmm"
        case 17: "mmm-yy"
        case 18: "h:mm AM/PM"
        case 19: "h:mm:ss AM/PM"
        case 20: "h:mm"
        case 21: "h:mm:ss"
        case 22: "m/d/yyyy h:mm"
        case 37: "#,##0 ;(#,##0)"
        case 38: "#,##0 ;[Red](#,##0)"
        case 39: "#,##0.00;(#,##0.00)"
        case 40: "#,##0.00;[Red](#,##0.00)"
        case 41: "_(* #,##0_);_(* (#,##0);_(* \"-\"_);_(@_)"
        case 42: "_(\"$\"* #,##0_);_(\"$\"* (#,##0);_(\"$\"* \"-\"_);_(@_)"
        case 43: "_(* #,##0.00_);_(* (#,##0.00);_(* \"-\"??_);_(@_)"
        case 44: "_(\"$\"* #,##0.00_);_(\"$\"* (#,##0.00);_(\"$\"* \"-\"??_);_(@_)"
        case 45: "mm:ss"
        case 46: "[h]:mm:ss"
        case 47: "mm:ss.0"
        case 48: "##0.0E+0"
        case 49: "@"
        default: "General"
        }
    }

    // MARK: Text

    /// Text through the format's text section ("\"Note: \"@"); other formats show text as it is.
    func format(text: String) -> String {
        guard sections.count >= 4 || (sections.count == 1 && sections[0].contains("@") && sections[0] != "@") else { return text }
        let section = sections.count >= 4 ? sections[3] : sections[0]
        var out = ""
        for token in Self.tokens(section) {
            switch token {
            case .literal(let s): out += s
            case .at: out += text
            default: break
            }
        }
        return out
    }

    // MARK: Numbers

    func format(_ value: Double, date1904: Bool) -> String {
        guard value.isFinite else { return "#NUM!" }
        if let localeTemplate { return Self.localeDate(value, template: localeTemplate, date1904: date1904) }
        // Pick the section: one for all; two: ≥ 0 / < 0; three: > 0 / < 0 / = 0 (conditions are read as these).
        var section = sections.first ?? "General"
        var number = value
        var signShown = true
        if sections.count >= 2, value < 0 {
            section = sections[1]; number = -value; signShown = false
        } else if sections.count >= 3, value == 0 {
            section = sections[2]
        }
        if Self.hasDateTokens(section) { return Self.formatDate(value, section: section, date1904: date1904) }
        let trimmed = Self.strip(section)
        if trimmed.lowercased() == "general" || trimmed.isEmpty && section.lowercased().contains("general") {
            return Self.general(signShown ? value : number)
        }
        let text = Self.formatNumber(number, section: section)
        if signShown, value < 0, Self.roundsToNonZero(text) { return "-" + text }
        return text
    }

    private static func roundsToNonZero(_ text: String) -> Bool { text.contains { $0.isNumber && $0 != "0" } }

    /// Excel's "General": up to 11 significant characters, scientific for very large or small numbers.
    static func general(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude == 0 { return "0" }
        let decimal = "."
        if magnitude >= 1e11 || magnitude < 1e-9 {
            var text = String(format: "%.5E", value)
            // "1.23450E+11" → "1.2345E+11"
            if let e = text.firstIndex(of: "E") {
                var mantissa = String(text[..<e]), exponent = String(text[text.index(after: e)...])
                while mantissa.contains("."), mantissa.hasSuffix("0") { mantissa.removeLast() }
                if mantissa.hasSuffix(".") { mantissa.removeLast() }
                let sign = exponent.hasPrefix("-") ? "-" : "+"
                exponent = exponent.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
                while exponent.count > 2, exponent.hasPrefix("0") { exponent.removeFirst() }
                text = mantissa + "E" + sign + exponent
            }
            return text.replacingOccurrences(of: ".", with: decimal)
        }
        if value == value.rounded(), magnitude < 1e15 { return String(Int64(value)) }
        let integerDigits = max(1, Int(log10(magnitude)) + 1)
        var text = String(format: "%.\(max(0, 10 - integerDigits))f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text.replacingOccurrences(of: ".", with: decimal)
    }

    private enum Token {
        case literal(String)
        case digit(Character)   // 0 # ?
        case point, comma, percent, slash, at
        case exponent(sign: Bool)
    }

    /// A section's tokens; brackets other than currency are dropped, "_x" becomes a space and "*x" nothing.
    private static func tokens(_ section: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(section)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "\"":
                var j = i + 1, text = ""
                while j < chars.count, chars[j] != "\"" { text.append(chars[j]); j += 1 }
                tokens.append(.literal(text)); i = j + 1
            case "\\":
                if i + 1 < chars.count { tokens.append(.literal(String(chars[i + 1]))) }
                i += 2
            case "_":
                tokens.append(.literal(" ")); i += 2
            case "*":
                i += 2
            case "[":
                var j = i + 1, inner = ""
                while j < chars.count, chars[j] != "]" { inner.append(chars[j]); j += 1 }
                if inner.hasPrefix("$") {
                    let symbol = inner.dropFirst().split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    if !symbol.isEmpty { tokens.append(.literal(symbol)) }
                }
                i = j + 1
            case "0", "#", "?": tokens.append(.digit(c)); i += 1
            case ".": tokens.append(.point); i += 1
            case ",": tokens.append(.comma); i += 1
            case "%": tokens.append(.percent); i += 1
            case "/": tokens.append(.slash); i += 1
            case "@": tokens.append(.at); i += 1
            case "E", "e":
                if i + 1 < chars.count, chars[i + 1] == "+" || chars[i + 1] == "-" {
                    tokens.append(.exponent(sign: chars[i + 1] == "+")); i += 2
                } else {
                    tokens.append(.literal(String(c))); i += 1
                }
            default:
                tokens.append(.literal(String(c))); i += 1
            }
        }
        return tokens
    }

    private static func formatNumber(_ value: Double, section: String) -> String {
        let tokens = tokens(section)
        let decimalSep = ".", groupSep = ","
        var number = value
        let percents = tokens.filter { if case .percent = $0 { true } else { false } }.count
        for _ in 0..<min(percents, 3) { number *= 100 }

        // Where the number's parts are.
        guard let firstDigit = tokens.firstIndex(where: { if case .digit = $0 { true } else { false } }) else {
            // No placeholders: literals only (";;;" hides, "\"-\"" shows a dash).
            return tokens.compactMap { if case .literal(let s) = $0 { s } else if case .percent = $0 { "%" } else { nil } }.joined()
        }
        let lastDigit = tokens.lastIndex(where: { if case .digit = $0 { true } else { false } })!
        if let slash = tokens.firstIndex(where: { if case .slash = $0 { true } else { false } }), slash > firstDigit, slash < lastDigit {
            return formatFraction(number, tokens: tokens, firstDigit: firstDigit, lastDigit: lastDigit, slash: slash)
        }
        let exponentIndex = tokens.firstIndex(where: { if case .exponent = $0 { true } else { false } })
        let pointIndex = tokens.firstIndex(where: { if case .point = $0 { true } else { false } })
        let mantissaEnd = exponentIndex ?? tokens.count
        func digits(_ range: Range<Int>) -> [Character] {
            tokens[range].compactMap { if case .digit(let d) = $0 { d } else { nil } }
        }
        let intEnd = min(pointIndex ?? mantissaEnd, mantissaEnd)
        let intPlaceholders = digits(firstDigit..<intEnd)
        let fracPlaceholders = pointIndex.map { digits(($0 + 1)..<mantissaEnd) } ?? []
        // Commas between integer placeholders group thousands; commas right after the last one scale by 1,000.
        var grouping = false
        var scaleCommas = 0
        var lastIntDigit = firstDigit
        for i in firstDigit..<intEnd { if case .digit = tokens[i] { lastIntDigit = i } }
        for i in firstDigit..<intEnd {
            if case .comma = tokens[i] { if i < lastIntDigit { grouping = true } else { scaleCommas += 1 } }
        }
        for _ in 0..<min(scaleCommas, 4) { number /= 1000 }

        var exponent = 0
        if exponentIndex != nil, number != 0 {
            let intCount = max(intPlaceholders.count, 1)
            // "##0.0E+0": exponents in multiples of the integer placeholders' count (engineering notation).
            let step = intPlaceholders.count > 1 && intPlaceholders.first == "#" ? intCount : 1
            exponent = Int(floor(log10(abs(number))))
            exponent = Int((Double(exponent) / Double(step)).rounded(.down)) * step
            if step == 1 { exponent -= max(intPlaceholders.filter { $0 == "0" }.count - 1, 0) }
            number /= pow(10, Double(exponent))
        }

        let maxFraction = fracPlaceholders.count, minFraction = fracPlaceholders.filter { $0 == "0" }.count
        let rounded = String(format: "%.\(maxFraction)f", abs(number))
        var intPart = rounded, fracPart = ""
        if let dot = rounded.firstIndex(of: ".") { intPart = String(rounded[..<dot]); fracPart = String(rounded[rounded.index(after: dot)...]) }
        while fracPart.count > minFraction, fracPart.hasSuffix("0") { fracPart.removeLast() }
        let minInt = intPlaceholders.filter { $0 == "0" }.count
        if intPart == "0", minInt == 0 { intPart = "" }
        while intPart.count < minInt { intPart = "0" + intPart }
        if grouping, intPart.count > 3 {
            var grouped = "", count = 0
            for ch in intPart.reversed() {
                if count > 0, count % 3 == 0 { grouped = groupSep + grouped }
                grouped = String(ch) + grouped
                count += 1
            }
            intPart = grouped
        }

        var out = ""
        var emittedInt = false, emittedFrac = false
        for (i, token) in tokens.enumerated() {
            switch token {
            case .literal(let s): out += s
            case .percent: out += "%"
            case .digit:
                if i < intEnd || pointIndex == nil && i < mantissaEnd {
                    if !emittedInt { out += intPart; emittedInt = true }
                } else if i < mantissaEnd {
                    if !emittedFrac { out += fracPart; emittedFrac = true }
                } else if let exponentIndex, i > exponentIndex {
                    continue
                }
            case .point:
                if !emittedInt { out += intPart; emittedInt = true }
                out += decimalSep
            case .comma:
                if i >= intEnd { out += "," }
            case .exponent(let sign):
                let expDigits = tokens[(i + 1)...].prefix { if case .digit = $0 { true } else { false } }.count
                var e = String(abs(exponent))
                while e.count < max(expDigits, 1) { e = "0" + e }
                out += "E" + (exponent < 0 ? "-" : sign ? "+" : "") + e
            case .slash: out += "/"
            case .at: break
            }
        }
        return out
    }

    /// "# ?/?" and "?/??" fractions.
    private static func formatFraction(_ value: Double, tokens: [Token], firstDigit: Int, lastDigit: Int, slash: Int) -> String {
        // An integer part exists when a literal space separates placeholders before the numerator.
        var integerEnd: Int?
        for i in firstDigit..<slash {
            if case .literal(let s) = tokens[i], s.trimmingCharacters(in: .whitespaces).isEmpty { integerEnd = i; break }
        }
        let denominatorDigits = tokens[(slash + 1)...lastDigit].filter { if case .digit = $0 { true } else { false } }.count
        let fixedDenominator: Int? = {
            let literal = tokens[(slash + 1)...lastDigit].compactMap { if case .literal(let s) = $0 { s } else { nil } }.joined()
            return Int(literal)
        }()
        let magnitude = abs(value)
        var whole = integerEnd != nil ? floor(magnitude) : 0
        let fraction = magnitude - whole
        var numerator = 0, denominator = 1
        if let fixed = fixedDenominator, fixed > 0 {
            numerator = Int((fraction * Double(fixed)).rounded()); denominator = fixed
        } else {
            let limit = max(Int(pow(10, Double(max(denominatorDigits, 1)))) - 1, 1)
            var best = (n: 0, d: 1, error: fraction)
            for d in 1...limit {
                let n = Int((fraction * Double(d)).rounded())
                let error = abs(fraction - Double(n) / Double(d))
                if error < best.error - 1e-12 { best = (n, d, error) }
                if error < 1e-12 { break }
            }
            numerator = best.n; denominator = best.d
        }
        if numerator == denominator, integerEnd != nil { whole += 1; numerator = 0 }
        var out = ""
        if integerEnd != nil, whole > 0 || numerator == 0 { out += String(Int(whole)) }
        if numerator != 0 { out += (out.isEmpty ? "" : " ") + "\(numerator)/\(denominator)" }
        if out.isEmpty { out = "0" }
        return out
    }

    // MARK: Dates

    /// The serial number of an ISO 8601 date-time ("2024-03-15T10:30:00Z").
    static func serial(iso: String, date1904: Bool) -> Double? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withFullDate]
            date = formatter.date(from: String(iso.prefix(10)))
        }
        guard let date else { return nil }
        let base = date1904 ? -2_082_844_800.0 : -2_209_161_600.0   // 1904-01-01 / 1899-12-30, UTC
        var serial = (date.timeIntervalSince1970 - base) / 86_400
        if !date1904, serial < 61 { serial -= 1 }
        return serial
    }

    private struct DateParts { var year, month, day, hour, minute, second, weekday: Int; var fraction: Double }

    private static func parts(_ serial: Double, date1904: Bool) -> DateParts? {
        guard serial >= 0, serial < 2_958_466 else { return nil }
        var days = floor(serial)
        var seconds = ((serial - days) * 86_400 * 1000).rounded() / 1000
        if seconds >= 86_400 { days += 1; seconds -= 86_400 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // Excel's 1900 system counts a 29 February 1900 that never was (serial 60).
        if !date1904, days == 60 {
            return DateParts(year: 1900, month: 2, day: 29, hour: Int(seconds) / 3600, minute: Int(seconds) / 60 % 60, second: Int(seconds) % 60,
                             weekday: 4, fraction: seconds - floor(seconds))
        }
        let base = date1904 ? DateComponents(year: 1904, month: 1, day: 1) : days < 60 ? DateComponents(year: 1899, month: 12, day: 31) : DateComponents(year: 1899, month: 12, day: 30)
        guard let start = calendar.date(from: base), let date = calendar.date(byAdding: .day, value: Int(days), to: start) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let whole = Int(floor(seconds))
        return DateParts(year: c.year ?? 1900, month: c.month ?? 1, day: c.day ?? 1, hour: whole / 3600, minute: whole / 60 % 60,
                         second: whole % 60, weekday: c.weekday ?? 1, fraction: seconds - Double(whole))
    }

    private static let symbols: (months: [String], shortMonths: [String], weekdays: [String], shortWeekdays: [String], am: String, pm: String) = {
        let formatter = DateFormatter()
        formatter.locale = SheetNumberFormat.locale
        return (formatter.monthSymbols, formatter.shortMonthSymbols, formatter.weekdaySymbols, formatter.shortWeekdaySymbols,
                formatter.amSymbol, formatter.pmSymbol)
    }()

    private static func localeDate(_ serial: Double, template: String, date1904: Bool) -> String {
        guard let p = parts(serial, date1904: date1904) else { return general(serial) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: p.year, month: p.month, day: p.day, hour: p.hour, minute: p.minute,
                                                            second: p.second)) else { return general(serial) }
        let formatter = DateFormatter()
        formatter.locale = SheetNumberFormat.locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// Whether a section reads as a date or time (y, m, d, h, s outside quotes and brackets other than [h] [m] [s]).
    private static func hasDateTokens(_ section: String) -> Bool {
        let bare = strip(section).lowercased()
        if bare.contains("general") { return false }
        if section.lowercased().range(of: #"\[(h+|m+|s+)\]"#, options: .regularExpression) != nil { return true }
        return bare.contains { "ymdhs".contains($0) }
    }

    /// The section without quoted text, escapes and brackets.
    private static func strip(_ section: String) -> String {
        var out = "", inQuote = false, inBracket = false, escape = false
        for c in section {
            if escape { escape = false; continue }
            if inQuote { if c == "\"" { inQuote = false }; continue }
            if inBracket { if c == "]" { inBracket = false }; continue }
            switch c {
            case "\"": inQuote = true
            case "[": inBracket = true
            case "\\", "_", "*": escape = true
            default: out.append(c)
            }
        }
        return out
    }

    private static func formatDate(_ serial: Double, section: String, date1904: Bool) -> String {
        guard let p = parts(serial, date1904: date1904) else { return String(repeating: "#", count: 8) }
        let chars = Array(section)
        let lower = chars.map { $0.lowercased().first ?? $0 }
        let twelveHour = section.lowercased().contains("am/pm") || section.lowercased().contains("a/p")
        func starts(_ word: String, at index: Int) -> Bool {
            let w = Array(word)
            return index + w.count <= lower.count && Array(lower[index..<index + w.count]) == w
        }
        // Tokens: runs of the same letter, literals, brackets, AM/PM.
        enum Piece { case run(Character, Int), literal(String), elapsed(Character, Int), ampm(Bool), fraction(Int) }
        var pieces: [Piece] = []
        var i = 0
        while i < chars.count {
            let c = chars[i], lc = lower[i]
            if c == "\"" {
                var j = i + 1, text = ""
                while j < chars.count, chars[j] != "\"" { text.append(chars[j]); j += 1 }
                pieces.append(.literal(text)); i = j + 1
            } else if c == "\\" {
                if i + 1 < chars.count { pieces.append(.literal(String(chars[i + 1]))) }
                i += 2
            } else if c == "_" { pieces.append(.literal(" ")); i += 2
            } else if c == "*" { i += 2
            } else if c == "[" {
                var j = i + 1, inner = ""
                while j < chars.count, chars[j] != "]" { inner.append(chars[j]); j += 1 }
                let lowered = inner.lowercased()
                if let first = lowered.first, "hms".contains(first), lowered.allSatisfy({ $0 == first }) {
                    pieces.append(.elapsed(first, lowered.count))
                }
                i = j + 1
            } else if starts("am/pm", at: i) {
                pieces.append(.ampm(true)); i += 5
            } else if starts("a/p", at: i) {
                pieces.append(.ampm(false)); i += 3
            } else if "ymdhse".contains(lc) {
                var j = i
                while j < chars.count, lower[j] == lc { j += 1 }
                pieces.append(.run(lc == "e" ? "y" : lc, j - i)); i = j
            } else if c == ".", i + 1 < chars.count, chars[i + 1] == "0", case .run("s", _)? = pieces.last {
                var j = i + 1
                while j < chars.count, chars[j] == "0" { j += 1 }
                pieces.append(.fraction(j - i - 1)); i = j
            } else {
                pieces.append(.literal(String(c))); i += 1
            }
        }
        // "m" is minutes right after an hour or right before a second.
        func isMinute(_ index: Int) -> Bool {
            var k = index - 1
            while k >= 0 { if case .run(let l, _) = pieces[k] { return l == "h" }; if case .elapsed(let l, _) = pieces[k] { return l == "h" }; k -= 1 }
            k = index + 1
            while k < pieces.count { if case .run(let l, _) = pieces[k] { return l == "s" }; if case .elapsed(let l, _) = pieces[k] { return l == "s" }; k += 1 }
            return false
        }
        func pad(_ n: Int, _ width: Int) -> String { width >= 2 && n < 10 ? "0\(n)" : "\(n)" }
        let totalSeconds = serial * 86_400
        var out = ""
        for (index, piece) in pieces.enumerated() {
            switch piece {
            case .literal(let s): out += s
            case .ampm(let full):
                let pm = p.hour >= 12
                out += full ? (pm ? symbols.pm : symbols.am) : (pm ? "P" : "A")
            case .fraction(let digits):
                let value = Int((p.fraction * pow(10, Double(digits))).rounded())
                out += Self.decimalSeparator + String(format: "%0\(digits)d", min(value, Int(pow(10, Double(digits))) - 1))
            case .elapsed(let letter, let width):
                let value: Int
                switch letter {
                case "h": value = Int(totalSeconds / 3600)
                case "m": value = Int(totalSeconds / 60)
                default: value = Int(totalSeconds.rounded())
                }
                out += pad(value, width)
            case .run(let letter, let count):
                switch letter {
                case "y": out += count <= 2 ? pad(p.year % 100, 2) : String(p.year)
                case "m" where count <= 2 && isMinute(index): out += pad(p.minute, count)
                case "m":
                    switch count {
                    case 1, 2: out += pad(p.month, count)
                    case 3: out += symbols.shortMonths[p.month - 1]
                    case 5: out += String(symbols.months[p.month - 1].prefix(1))
                    default: out += symbols.months[p.month - 1]
                    }
                case "d":
                    switch count {
                    case 1, 2: out += pad(p.day, count)
                    case 3: out += symbols.shortWeekdays[p.weekday - 1]
                    default: out += symbols.weekdays[p.weekday - 1]
                    }
                case "h":
                    var hour = p.hour
                    if twelveHour { hour = hour % 12; if hour == 0 { hour = 12 } }
                    out += pad(hour, count)
                case "s": out += pad(p.second, count)
                default: break
                }
            }
        }
        return out
    }

    private static var decimalSeparator: String { "." }

    /// Splits a code into its sections at ";" outside quotes and brackets.
    private static func split(_ code: String) -> [String] {
        var sections: [String] = [], current = "", inQuote = false, inBracket = false, escape = false
        for c in code {
            if escape { current.append(c); escape = false; continue }
            switch c {
            case "\\": escape = true; current.append(c)
            case "\"": inQuote.toggle(); current.append(c)
            case "[" where !inQuote: inBracket = true; current.append(c)
            case "]" where !inQuote: inBracket = false; current.append(c)
            case ";" where !inQuote && !inBracket: sections.append(current); current = ""
            default: current.append(c)
            }
        }
        sections.append(current)
        return sections
    }
}

// MARK: Dates as Workbook values

extension SheetNumberFormat {
    private static let epoch1900 = -2_209_161_600.0   // 1899-12-30 UTC
    private static let epoch1904 = -2_082_844_800.0   // 1904-01-01 UTC

    /// The `Date` (UTC) for a serial number.
    static func date(fromSerial serial: Double, date1904: Bool) -> Date? {
        guard serial.isFinite, serial >= 0, serial < 2_958_466 else { return nil }
        let days = (!date1904 && serial < 61) ? serial + 1 : serial
        return Date(timeIntervalSince1970: (date1904 ? epoch1904 : epoch1900) + days * 86_400)
    }

    /// The serial number for a `Date`, as Excel counts (its 1900 system includes the 29 February that never was).
    static func serial(from date: Date, date1904: Bool) -> Double {
        let serial = (date.timeIntervalSince1970 - (date1904 ? epoch1904 : epoch1900)) / 86_400
        return (!date1904 && serial < 61) ? serial - 1 : serial
    }
}


// MARK: Displayed text

extension Cell {
    /// The text the cell shows: the source's own `displayText`, else the value through its number format.
    var shown: String {
        if let displayText { return displayText }
        switch value {
        case .empty: return ""
        case .text(let t): return numberFormat.map { SheetNumberFormat(code: $0).format(text: t) } ?? t
        case .error(let e): return e
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .number(let n): return numberFormat.map { SheetNumberFormat(code: $0).format(n, date1904: false) } ?? SheetNumberFormat.general(n)
        case .date(let d):
            guard let code = numberFormat else { return CSVWriter.isoDate(d) }
            return SheetNumberFormat(code: code).format(SheetNumberFormat.serial(from: d, date1904: false), date1904: false)
        }
    }
}
