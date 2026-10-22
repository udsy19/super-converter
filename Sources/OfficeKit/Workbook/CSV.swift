import Foundation
import SuperConverterCore

// CSV (RFC 4180) reader and writer for `Workbook` (formats §3.2, quality §4): quoted fields with embedded delimiters, quotes
// and line breaks; encodings detected (UTF-8, UTF-16 with or without a byte-order mark, Windows-1252, MacRoman, Shift-JIS);
// delimiter detected (comma, semicolon, tab, pipe). Numbers, ISO dates and TRUE/FALSE become typed cells and keep the text
// as written for "as displayed" output, so a CSV round-trips byte for byte in value.

// MARK: - Encodings

enum CSVEncoding {
    /// Decodes `data`, detecting the encoding unless one is given. The byte-order mark is never part of the text.
    static func decode(_ data: Data) -> String {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        else if bytes.starts(with: [0xFF, 0xFE]) { return String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        else if bytes.starts(with: [0xFE, 0xFF]) { return String(data: bytes.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        if let text = String(data: bytes, encoding: .utf8) { return text }
        // UTF-16 without a mark: ASCII text has a zero byte in every other position.
        let sample = bytes.prefix(512)
        let even = sample.enumerated().filter { $0.offset % 2 == 0 && $0.element == 0 }.count
        let odd = sample.enumerated().filter { $0.offset % 2 == 1 && $0.element == 0 }.count
        if max(even, odd) * 4 > sample.count, let text = String(data: bytes, encoding: odd > even ? .utf16LittleEndian : .utf16BigEndian) { return text }
        if looksLikeShiftJIS(bytes), let text = String(data: bytes, encoding: .shiftJIS) { return text }
        // Windows-1252 leaves five bytes undefined; Mac files that use them are MacRoman.
        if !bytes.contains(where: { [0x81, 0x8D, 0x8F, 0x90, 0x9D].contains($0) }), let text = String(data: bytes, encoding: .windowsCP1252) { return text }
        return String(data: bytes, encoding: .macOSRoman) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Mostly valid two-byte sequences: a lead byte (0x81–0x9F, 0xE0–0xFC) followed by 0x40–0xFC, or half-width katakana.
    private static func looksLikeShiftJIS(_ bytes: Data) -> Bool {
        var pairs = 0, high = 0, bad = 0
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let b = bytes[i]
            if b < 0x80 { i += 1; continue }
            high += 1
            if (0xA1...0xDF).contains(b) { i += 1; continue }
            if (0x81...0x9F).contains(b) || (0xE0...0xFC).contains(b), i + 1 < bytes.endIndex, (0x40...0xFC).contains(bytes[i + 1]), bytes[i + 1] != 0x7F {
                pairs += 1; i += 2
            } else {
                bad += 1; i += 1
            }
        }
        return high > 0 && pairs > 0 && bad * 10 <= high
    }
}

// MARK: - Reader


enum CSVReader {
    static let maxRows = 1_048_576
    static let maxColumns = 16_384

    /// The file as a one-sheet workbook; encoding and delimiter are detected.
    static func read(_ data: Data, sheetName: String = "Sheet1") -> Workbook {
        let text = CSVEncoding.decode(data)
        let rows = parse(text, delimiter: detectDelimiter(text))
        return Workbook(sheets: [Sheet(name: sheetName, rows: rows.map { $0.map(cell) })])
    }

    /// The delimiter that gives the most consistent column count over the first lines (outside quotes).
    static func detectDelimiter(_ text: String) -> Character {
        let sample = String(text.prefix(65_536))
        var best: (delimiter: Character, score: Int) = (",", -1)
        for candidate: Character in [",", ";", "\t", "|"] {
            let rows = parse(sample, delimiter: candidate, limit: 20)
            guard let first = rows.first, first.count > 1 else { continue }
            let consistent = rows.filter { $0.count == first.count }.count
            let score = consistent * 1000 + first.count
            if score > best.score { best = (candidate, score) }
        }
        return best.delimiter
    }

    /// RFC 4180: fields separated by `delimiter`, quoted with `"` (doubled inside), CRLF, LF or CR between records. A
    /// trailing line break does not make an empty record.
    static func parse(_ text: String, delimiter: Character, limit: Int = maxRows) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldWasQuoted = false
        var pendingRecord = false
        let scalars = Array(text.unicodeScalars)
        let delimiterScalar = delimiter.unicodeScalars.first!
        var i = 0
        func endField() { if row.count < maxColumns { row.append(field) }; field = ""; fieldWasQuoted = false }
        func endRow() { endField(); rows.append(row); row = []; pendingRecord = false }
        while i < scalars.count, rows.count < limit {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" { field.unicodeScalars.append(c); i += 1 } else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == "\"" && field.isEmpty && !fieldWasQuoted {
                inQuotes = true; fieldWasQuoted = true; pendingRecord = true
            } else if c == delimiterScalar {
                endField(); pendingRecord = true
            } else if c == "\r" || c == "\n" {
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                endRow()
            } else {
                field.unicodeScalars.append(c); pendingRecord = true
            }
            i += 1
        }
        if pendingRecord || !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    private static let number = try! NSRegularExpression(pattern: #"^-?(0|[1-9][0-9]*)(\.([0-9]+))?([eE][+-]?[0-9]+)?$"#)
    private static let isoDate = try! NSRegularExpression(pattern: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#)

    /// A field as a typed cell: a plain number (no leading zeros, at most 15 digits), an ISO date or TRUE/FALSE; else text.
    static func cell(_ field: String) -> Cell {
        guard !field.isEmpty else { return Cell() }
        let range = NSRange(location: 0, length: (field as NSString).length)
        if field.utf8.count <= 20, let match = number.firstMatch(in: field, range: range), let value = Double(field),
           field.filter(\.isNumber).count <= 15 {
            let decimals = match.range(at: 3).location != NSNotFound ? match.range(at: 3).length : 0
            let exponent = match.range(at: 4).location != NSNotFound
            let code = exponent ? nil : decimals > 0 ? "0." + String(repeating: "0", count: decimals) : nil
            return Cell(value: .number(value), numberFormat: code, displayText: field)
        }
        if field.utf8.count == 10, isoDate.firstMatch(in: field, range: range) != nil {
            let parts = field.split(separator: "-").compactMap { Int($0) }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            if parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
               calendar.dateComponents([.month, .day], from: date) == DateComponents(month: parts[1], day: parts[2]) {
                return Cell(value: .date(date), numberFormat: "yyyy-mm-dd", displayText: field)
            }
        }
        if field == "TRUE" { return Cell(value: .bool(true)) }
        if field == "FALSE" { return Cell(value: .bool(false)) }
        return Cell(value: .text(field))
    }
}

// MARK: - Writer

struct CSVWriteOptions: Sendable {
    enum Output: Sendable { case utf8, utf8WithBOM, utf16 }
    var delimiter: Character = ","
    var output: Output = .utf8
    /// "As displayed" (the text the source showed) or raw values.
    var displayed = true
    /// Replaces "." in numbers when set.
    var decimalSeparator: String?

    /// From the O-CSV option profile's values.
    init(_ options: OptionValues) {
        switch options["delimiter"]?.string {
        case "semicolon": delimiter = ";"
        case "tab": delimiter = "\t"
        default: delimiter = ","
        }
        switch options["encoding"]?.string {
        case "utf8bom": output = .utf8WithBOM
        case "utf16": output = .utf16
        default: output = .utf8
        }
        displayed = options["values"]?.string != "raw"
        if let separator = options["decimalSeparator"]?.string, !separator.isEmpty { decimalSeparator = separator }
    }

    init() {}
}

enum CSVWriter {
    /// One sheet as CSV text: CRLF between records (RFC 4180), fields quoted when they hold the delimiter, a quote, a line
    /// break or edge spaces.
    static func text(_ sheet: Sheet, options: CSVWriteOptions = CSVWriteOptions()) -> String {
        let width = sheet.rows.map(\.count).max() ?? 0
        var out = ""
        for row in sheet.rows {
            var fields = row.map { field($0, options: options) }
            // Short rows are padded so every record has the same number of fields.
            if fields.count < width { fields += [String](repeating: "", count: width - fields.count) }
            out += fields.map { quoted($0, delimiter: options.delimiter) }.joined(separator: String(options.delimiter)) + "\r\n"
        }
        return out
    }

    static func data(_ sheet: Sheet, options: CSVWriteOptions = CSVWriteOptions()) -> Data {
        encode(text(sheet, options: options), options.output)
    }

    static func encode(_ text: String, _ output: CSVWriteOptions.Output) -> Data {
        switch output {
        case .utf8: return Data(text.utf8)
        case .utf8WithBOM: return Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)
        case .utf16: return Data([0xFF, 0xFE]) + (text.data(using: .utf16LittleEndian) ?? Data())
        }
    }

    static func quoted(_ text: String, delimiter: Character) -> String {
        guard text.contains(where: { $0 == delimiter || $0 == "\"" || $0 == "\n" || $0 == "\r" }) || text.hasPrefix(" ") || text.hasSuffix(" ") else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A cell's text: what the source displayed, or the raw value.
    static func field(_ cell: Cell, options: CSVWriteOptions) -> String {
        var text: String
        switch cell.value {
        case .empty: return ""
        case .text(let t): return options.displayed ? cell.shown : t
        case .error(let e): return e
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .number(let n):
            text = options.displayed ? cell.shown : raw(n)
            return decimal(text, options)
        case .date(let d):
            return options.displayed ? cell.shown : isoDate(d)
        }
    }

    private static func decimal(_ text: String, _ options: CSVWriteOptions) -> String {
        guard let separator = options.decimalSeparator, separator != "." else { return text }
        return text.replacingOccurrences(of: ".", with: separator)
    }

    /// The shortest text that reads back as the same number, without an exponent for ordinary sizes.
    static func raw(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "#NUM!" : value < 0 ? "-Infinity" : "Infinity" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.15g", value)
        if Double(text) != value { text = String(format: "%.17g", value) }
        return text
    }

    /// "2024-03-15", or "2024-03-15 10:30:00" when the date has a time of day.
    static func isoDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 1900, c.month ?? 1, c.day ?? 1)
        guard (c.hour ?? 0) != 0 || (c.minute ?? 0) != 0 || (c.second ?? 0) != 0 else { return day }
        return day + String(format: " %02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
