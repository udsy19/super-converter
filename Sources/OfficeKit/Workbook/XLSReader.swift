import Foundation
import SuperConverterCore

// XLS reader (formats §3.2: "XLS via libxls"). The libxls vendor library is not built yet (WP0b), so this is an own reader
// of the same files: the OLE2 compound container, then BIFF8 records for sheets, shared strings, cell values (numbers, RK,
// text, booleans, errors, formula results), number formats, fonts, fills, alignment, merges and column widths. Formulas
// are read as their stored results (the token stream is not decompiled). BIFF5 and older (Excel 95) files, and
// password-protected ones, are reported.

enum XLSReader {
    static func read(_ url: URL) throws -> XLSXReader.Result {
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch { throw ConversionError.damaged(FormatID("xls")) }
        return try read(data)
    }

    static func read(_ data: Data) throws -> XLSXReader.Result {
        guard let container = OLEContainer(data), let stream = container.stream(named: ["Workbook", "Book"]) else {
            throw ConversionError.damaged(FormatID("xls"))
        }
        var book = try BIFFBook(stream)
        let sheets = try book.sheets()
        var notes: [LossNote] = []
        if book.sawFormula { notes.append(LossNote(.otherLoss, detail: "Formulas were replaced by their results.")) }
        return XLSXReader.Result(workbook: Workbook(sheets: sheets), lossNotes: notes, warnings: [])
    }
}

// MARK: - OLE2 compound file

struct OLEContainer {
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private var fat: [UInt32] = []
    private var miniFAT: [UInt32] = []
    private var entries: [(name: String, type: UInt8, start: UInt32, size: Int)] = []
    private var miniStream = Data()

    private static let endOfChain: UInt32 = 0xFFFF_FFFE

    init?(_ data: Data) {
        guard data.count > 512, data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else { return nil }
        self.data = data
        let shift = Int(data.u16(0x1E)), miniShift = Int(data.u16(0x20))
        guard (7...12).contains(shift), (1...shift).contains(miniShift) else { return nil }
        sectorSize = 1 << shift
        miniSectorSize = 1 << miniShift
        miniCutoff = Int(data.u32(0x38))

        // FAT: the sector numbers in the header's DIFAT, then the DIFAT chain.
        var fatSectors: [UInt32] = []
        for i in 0..<109 { let s = data.u32(0x4C + i * 4); if s < Self.endOfChain { fatSectors.append(s) } }
        var difat = data.u32(0x44)
        var guardCount = 0
        while difat < Self.endOfChain, guardCount < 10_000 {
            guard let sector = sectorData(difat) else { return nil }
            for i in 0..<(sectorSize / 4 - 1) { let s = sector.u32(i * 4); if s < Self.endOfChain { fatSectors.append(s) } }
            difat = sector.u32(sectorSize - 4)
            guardCount += 1
        }
        for s in fatSectors {
            guard let sector = sectorData(s) else { return nil }
            for i in 0..<(sectorSize / 4) { fat.append(sector.u32(i * 4)) }
        }
        // Directory.
        guard let directory = chain(start: data.u32(0x30)) else { return nil }
        for offset in stride(from: 0, to: directory.count - 127, by: 128) {
            let nameLength = min(Int(directory.u16(offset + 0x40)), 64)
            let nameBytes = directory.subdata(in: directory.startIndex + offset..<directory.startIndex + offset + max(nameLength - 2, 0))
            let name = String(data: nameBytes, encoding: .utf16LittleEndian) ?? ""
            entries.append((name, directory[directory.startIndex + offset + 0x42], directory.u32(offset + 0x74), Int(directory.u32(offset + 0x78))))
        }
        // Mini stream and its FAT.
        if let root = entries.first(where: { $0.type == 5 }), let mini = chain(start: root.start) { miniStream = mini }
        if let table = chain(start: data.u32(0x3C)) { for i in 0..<(table.count / 4) { miniFAT.append(table.u32(i * 4)) } }
    }

    func stream(named names: [String]) -> Data? {
        guard let entry = entries.first(where: { $0.type == 2 && names.contains($0.name) }) else { return nil }
        if entry.size < miniCutoff {
            var out = Data()
            var s = entry.start
            var steps = 0
            while s < Self.endOfChain, steps < 1_000_000 {
                let offset = Int(s) * miniSectorSize
                guard offset + miniSectorSize <= miniStream.count else { return nil }
                out.append(miniStream.subdata(in: miniStream.startIndex + offset..<miniStream.startIndex + offset + miniSectorSize))
                guard Int(s) < miniFAT.count else { break }
                s = miniFAT[Int(s)]
                steps += 1
            }
            return out.prefix(entry.size)
        }
        return chain(start: entry.start).map { $0.prefix(entry.size) }
    }

    private func sectorData(_ sector: UInt32) -> Data? {
        let offset = 512 + Int(sector) * sectorSize
        guard sector < Self.endOfChain, offset + sectorSize <= data.count else { return nil }
        return data.subdata(in: data.startIndex + offset..<data.startIndex + offset + sectorSize)
    }

    private func chain(start: UInt32) -> Data? {
        var out = Data()
        var s = start
        var steps = 0
        while s < Self.endOfChain {
            guard let sector = sectorData(s), steps < 4_000_000 else { return nil }
            out.append(sector)
            guard Int(s) < fat.count else { return nil }
            s = fat[Int(s)]
            steps += 1
        }
        return out
    }
}

// MARK: - BIFF8

private struct BIFFRecord {
    var type: Int
    var data: Data
    /// The CONTINUE records that followed, for SST.
    var continuations: [Data] = []
}

private struct BIFFBook {
    let stream: Data
    var sheetEntries: [(name: String, offset: Int, hidden: Bool)] = []
    var strings: [String] = []
    var formats: [Int: String] = [:]
    struct Font { var bold = false, italic = false, name = "", size = 11.0, colour: Int = 0x7FFF }
    var fonts: [Font] = []
    struct XF { var font = 0, format = 0, horizontal = 0, wrap = false, fill: Int? }
    var xfs: [XF] = []
    var palette: [Int: SheetRGB] = [:]
    var date1904 = false
    var sawFormula = false

    init(_ stream: Data) throws {
        self.stream = stream
        try readGlobals()
    }

    // MARK: Records

    private func records(from start: Int, until stop: (Int) -> Bool) -> [BIFFRecord] {
        var out: [BIFFRecord] = []
        var p = start
        while p + 4 <= stream.count {
            let type = Int(stream.u16(p)), length = Int(stream.u16(p + 2))
            guard p + 4 + length <= stream.count else { break }
            let body = stream.subdata(in: stream.startIndex + p + 4..<stream.startIndex + p + 4 + length)
            p += 4 + length
            if type == 0x3C, !out.isEmpty { out[out.count - 1].continuations.append(body); continue }
            out.append(BIFFRecord(type: type, data: body))
            if stop(type) { break }
        }
        return out
    }

    private mutating func readGlobals() throws {
        let records = self.records(from: 0) { $0 == 0x0A }
        guard let bof = records.first, bof.type == 0x809, bof.data.u16(0) == 0x0600 else { throw ConversionError.damaged(FormatID("xls")) }
        var customFormats: [Int: String] = [:]
        for record in records {
            switch record.type {
            case 0x2F: throw ConversionError.passwordRequired(FormatID("xls"))
            case 0x22: date1904 = record.data.u16(0) == 1
            case 0x85:
                let state = record.data.count > 4 ? record.data[record.data.startIndex + 4] : 0
                let type = record.data.count > 5 ? record.data[record.data.startIndex + 5] : 0
                guard type == 0 else { continue }   // worksheets only
                var reader = BIFFReader([record.data.dropFirst(6)])
                let name = reader.string(lengthBytes: 1) ?? "Sheet\(sheetEntries.count + 1)"
                sheetEntries.append((name, Int(record.data.u32(0)), state != 0))
            case 0xFC: strings = Self.sharedStrings(record)
            case 0x41E:
                var reader = BIFFReader([record.data.dropFirst(2)])
                if let code = reader.string(lengthBytes: 2) { customFormats[Int(record.data.u16(0))] = code }
            case 0x31:
                var font = Font()
                font.size = Double(record.data.u16(0)) / 20
                let flags = record.data.u16(2)
                font.italic = flags & 2 != 0
                font.colour = Int(record.data.u16(4))
                font.bold = record.data.u16(6) >= 700
                var reader = BIFFReader([record.data.dropFirst(14)])
                font.name = reader.string(lengthBytes: 1) ?? ""
                fonts.append(font)
                if fonts.count == 4 { fonts.append(Font()) }   // font index 4 does not exist
            case 0xE0:
                var xf = XF()
                xf.font = Int(record.data.u16(0)); xf.format = Int(record.data.u16(2))
                let alignment = record.data.count > 6 ? record.data[record.data.startIndex + 6] : 0
                xf.horizontal = Int(alignment & 7); xf.wrap = alignment & 8 != 0
                if record.data.count >= 20 {
                    let pattern = Int(record.data[record.data.startIndex + 17] >> 2)
                    if pattern == 1 { xf.fill = Int(record.data.u16(18) & 0x7F) }
                }
                xfs.append(xf)
            case 0x92:
                let count = Int(record.data.u16(0))
                for i in 0..<min(count, 56) where 2 + i * 4 + 3 <= record.data.count {
                    let o = 2 + i * 4
                    let b = { (k: Int) in Double(record.data[record.data.startIndex + o + k]) / 255 }
                    palette[8 + i] = SheetRGB(red: b(0), green: b(1), blue: b(2))
                }
            default: break
            }
        }
        formats = customFormats
        if sheetEntries.isEmpty { throw ConversionError.damaged(FormatID("xls")) }
    }

    private static func sharedStrings(_ record: BIFFRecord) -> [String] {
        let chunks = [record.data.dropFirst(8)] + record.continuations
        var reader = BIFFReader(chunks)
        let unique = Int(record.data.u32(4))
        var out: [String] = []
        out.reserveCapacity(min(unique, 1_000_000))
        while out.count < unique, let text = reader.string(lengthBytes: 2) { out.append(text) }
        return out
    }

    // MARK: Sheets

    mutating func sheets() throws -> [Sheet] {
        var sheets: [Sheet] = []
        for entry in sheetEntries {
            sheets.append(try sheet(entry))
        }
        return sheets
    }

    private mutating func sheet(_ entry: (name: String, offset: Int, hidden: Bool)) throws -> Sheet {
        var sheet = Sheet(name: entry.name, isHidden: entry.hidden)
        guard entry.offset >= 0, entry.offset < stream.count else { throw ConversionError.damaged(FormatID("xls")) }
        var cells: [Int: [Int: Cell]] = [:]
        var pendingFormula: (row: Int, column: Int, xf: Int)?
        var started = false
        for record in records(from: entry.offset, until: { $0 == 0x0A }) {
            let d = record.data
            if !started { started = true; continue }   // BOF
            switch record.type {
            case 0xFD:   // LABELSST
                let index = Int(d.u32(6))
                put(&cells, d, value: .text(index < strings.count ? strings[index] : ""))
            case 0x204:  // LABEL
                var reader = BIFFReader([d.dropFirst(6)])
                put(&cells, d, value: .text(reader.string(lengthBytes: 2) ?? ""))
            case 0x203:  // NUMBER
                put(&cells, d, number: d.f64(6))
            case 0x27E:  // RK
                put(&cells, d, number: Self.rk(d.u32(6)))
            case 0xBD:   // MULRK
                let row = Int(d.u16(0)), first = Int(d.u16(2))
                let count = (d.count - 6) / 6
                for i in 0..<max(count, 0) {
                    let o = 4 + i * 6
                    put(&cells, row: row, column: first + i, xf: Int(d.u16(o)), number: Self.rk(d.u32(o + 2)))
                }
            case 0x205:  // BOOLERR
                let value = d.count > 7 ? d[d.startIndex + 6] : 0
                let isError = d.count > 7 && d[d.startIndex + 7] != 0
                put(&cells, d, value: isError ? .error(Self.errorText(value)) : .bool(value != 0))
            case 0x201:  // BLANK
                put(&cells, d, value: .empty)
            case 0xBE:   // MULBLANK
                let row = Int(d.u16(0)), first = Int(d.u16(2))
                let count = (d.count - 6) / 2
                for i in 0..<max(count, 0) { put(&cells, row: row, column: first + i, xf: Int(d.u16(4 + i * 2)), value: .empty) }
            case 0x06:   // FORMULA
                sawFormula = true
                let row = Int(d.u16(0)), column = Int(d.u16(2)), xf = Int(d.u16(4))
                if d.count >= 14, d.u16(12) == 0xFFFF {
                    let kind = d[d.startIndex + 6], payload = d[d.startIndex + 8]
                    switch kind {
                    case 0: pendingFormula = (row, column, xf)
                    case 1: put(&cells, row: row, column: column, xf: xf, value: .bool(payload != 0))
                    case 2: put(&cells, row: row, column: column, xf: xf, value: .error(Self.errorText(payload)))
                    default: put(&cells, row: row, column: column, xf: xf, value: .text(""))
                    }
                } else {
                    put(&cells, row: row, column: column, xf: xf, number: d.f64(6))
                }
            case 0x207:  // STRING (the result of the formula before it)
                if let pending = pendingFormula {
                    var reader = BIFFReader([d] + record.continuations)
                    put(&cells, row: pending.row, column: pending.column, xf: pending.xf, value: .text(reader.string(lengthBytes: 2) ?? ""))
                    pendingFormula = nil
                }
            case 0xE5:   // MERGEDCELLS
                let count = Int(d.u16(0))
                for i in 0..<count where 2 + i * 8 + 8 <= d.count {
                    let o = 2 + i * 8
                    sheet.merges.append(CellRange(firstRow: Int(d.u16(o)), firstColumn: Int(d.u16(o + 4)), lastRow: Int(d.u16(o + 2)), lastColumn: Int(d.u16(o + 6))))
                }
            case 0x7D:   // COLINFO
                let first = Int(d.u16(0)), last = min(Int(d.u16(2)), first + 255)
                let width = Double(d.u16(4)) / 256
                if width > 0, first <= last { for c in first...last { sheet.columnWidths[c] = (width * 100).rounded() / 100 } }
            default: break
            }
        }
        if let lastRow = cells.keys.max() {
            sheet.rows = (0...lastRow).map { r in
                guard let row = cells[r], let lastColumn = row.keys.max() else { return [] }
                return (0...lastColumn).map { row[$0] ?? Cell() }
            }
        }
        return sheet
    }

    // MARK: Cells

    private func put(_ cells: inout [Int: [Int: Cell]], _ d: Data, value: CellValue) {
        put(&cells, row: Int(d.u16(0)), column: Int(d.u16(2)), xf: Int(d.u16(4)), value: value)
    }

    private func put(_ cells: inout [Int: [Int: Cell]], _ d: Data, number: Double) {
        put(&cells, row: Int(d.u16(0)), column: Int(d.u16(2)), xf: Int(d.u16(4)), number: number)
    }

    private func put(_ cells: inout [Int: [Int: Cell]], row: Int, column: Int, xf index: Int, number: Double) {
        let xf = index < xfs.count ? xfs[index] : XF()
        let format = format(xf)
        var cell = style(xf)
        if format.isDate, let date = SheetNumberFormat.date(fromSerial: number, date1904: date1904) { cell.value = .date(date) } else { cell.value = .number(number) }
        if format.code != "General" {
            cell.numberFormat = format.code
            cell.displayText = format.format(number, date1904: date1904)
        }
        cells[row, default: [:]][column] = cell
    }

    private func put(_ cells: inout [Int: [Int: Cell]], row: Int, column: Int, xf index: Int, value: CellValue) {
        let xf = index < xfs.count ? xfs[index] : XF()
        var cell = style(xf)
        cell.value = value
        if value == .empty, cell.style == CellStyle(), cell.numberFormat == nil { return }
        cells[row, default: [:]][column] = cell
    }

    private func format(_ xf: XF) -> SheetNumberFormat {
        SheetNumberFormat(code: formats[xf.format] ?? SheetNumberFormat.builtIn(xf.format), builtInID: formats[xf.format] == nil ? xf.format : nil)
    }

    private func style(_ xf: XF) -> Cell {
        var cell = Cell()
        if xf.font < fonts.count {
            let font = fonts[xf.font]
            cell.style.bold = font.bold; cell.style.italic = font.italic
            // The default font (font 0) is the baseline, not a choice a cell made.
            if let base = fonts.first, xf.font != 0 {
                if font.name != base.name, !font.name.isEmpty { cell.style.fontName = font.name }
                if font.size != base.size { cell.style.fontSize = font.size }
            }
            if font.colour != 0x7FFF, font.colour != 8, font.colour != 64, let colour = palette[font.colour] ?? SheetPalette.indexed(font.colour), colour != .black {
                cell.style.textColour = colour.hash
            }
        }
        if let fill = xf.fill, fill != 64, let colour = palette[fill] ?? SheetPalette.indexed(fill) { cell.style.fillColour = colour.hash }
        switch xf.horizontal {
        case 1: cell.style.alignment = .start
        case 2: cell.style.alignment = .centre
        case 3: cell.style.alignment = .end
        case 5: cell.style.alignment = .justified
        default: break
        }
        cell.style.wrapsText = xf.wrap
        let code = format(xf).code
        if code != "General" { cell.numberFormat = code }
        return cell
    }

    /// An RK value: a 30-bit integer or the top 30 bits of a double, optionally divided by 100.
    private static func rk(_ value: UInt32) -> Double {
        var number: Double
        if value & 2 != 0 { number = Double(Int32(bitPattern: value) >> 2) }
        else { number = Double(bitPattern: UInt64(value & 0xFFFF_FFFC) << 32) }
        if value & 1 != 0 { number /= 100 }
        return number
    }

    private static func errorText(_ code: UInt8) -> String {
        switch code {
        case 0x00: "#NULL!"
        case 0x07: "#DIV/0!"
        case 0x0F: "#VALUE!"
        case 0x17: "#REF!"
        case 0x1D: "#NAME?"
        case 0x24: "#NUM!"
        default: "#N/A"
        }
    }
}

/// Reads BIFF8 strings across CONTINUE boundaries: where a string's characters straddle two records, the second record
/// starts with a fresh "compressed" flag byte.
private struct BIFFReader {
    private let chunks: [Data]
    private var chunk = 0
    private var position = 0

    init(_ chunks: [Data]) { self.chunks = chunks.map { Data($0) } }

    private var current: Data { chunk < chunks.count ? chunks[chunk] : Data() }
    private var remainingInChunk: Int { current.count - position }

    private mutating func byte() -> UInt8? {
        while remainingInChunk <= 0 {
            guard chunk + 1 < chunks.count else { return nil }
            chunk += 1; position = 0
        }
        defer { position += 1 }
        return current[current.startIndex + position]
    }

    private mutating func word() -> Int? {
        guard let a = byte(), let b = byte() else { return nil }
        return Int(a) | Int(b) << 8
    }

    private mutating func skip(_ count: Int) {
        var left = count
        while left > 0 {
            if remainingInChunk <= 0 { guard chunk + 1 < chunks.count else { return }; chunk += 1; position = 0 }
            let step = min(left, remainingInChunk)
            position += step; left -= step
        }
    }

    mutating func string(lengthBytes: Int) -> String? {
        guard let length = lengthBytes == 1 ? byte().map(Int.init) : word(), let flags = byte() else { return nil }
        var wide = flags & 1 != 0
        let hasPhonetic = flags & 4 != 0, hasRuns = flags & 8 != 0
        var runs = 0, phoneticSize = 0
        if hasRuns { runs = word() ?? 0 }
        if hasPhonetic { phoneticSize = Int((byte() ?? 0)) | Int(byte() ?? 0) << 8 | Int(byte() ?? 0) << 16 | Int(byte() ?? 0) << 24 }
        var units: [UInt16] = []
        units.reserveCapacity(length)
        while units.count < length {
            if remainingInChunk <= 0 {
                guard chunk + 1 < chunks.count else { return nil }
                chunk += 1; position = 0
                wide = (byte() ?? 0) & 1 != 0   // the continuation's own flag byte
                continue
            }
            if wide {
                guard let lo = byte(), let hi = byte() else { return nil }
                units.append(UInt16(lo) | UInt16(hi) << 8)
            } else if let b = byte() {
                units.append(UInt16(b))
            }
        }
        skip(runs * 4 + phoneticSize)
        return String(decoding: units, as: UTF16.self)
    }
}

private extension Data {
    func f64(_ offset: Int) -> Double { Double(bitPattern: u64(offset)) }
}
