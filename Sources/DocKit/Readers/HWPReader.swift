import Foundation
import SuperConverterCore

/// Hangul .hwp (HWP 5.x) → `DocModel` (formats §3.2 `HWPReader`), from Hancom's published "Hangul Word Processor file format
/// 5.0" description: an OLE compound file (`CompoundFile`) whose `FileHeader` stream carries the flags, whose `BodyText/SectionN`
/// streams hold the records. Text, paragraphs, tables with spans and line breaks are read; fonts, styles, drawings and
/// equations are not (they are reported).
enum HWPReader {
    static func read(_ url: URL, options: DocReadOptions = DocReadOptions()) throws -> DocReadResult {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let file = CompoundFile(data), let header = file.stream("FileHeader"), header.count >= 40,
              String(decoding: header.prefix(17), as: UTF8.self) == "HWP Document File" else { throw ConversionError.damaged("hwp") }
        let flags = header.u32(36)
        if flags & 2 != 0 { throw ConversionError.passwordRequired("hwp") }
        if flags & 4 != 0 { throw ConversionError.damaged("hwp") }   // distribution documents are scrambled
        let compressed = flags & 1 != 0
        var blocks: [DocBlock] = []
        var index = 0
        var lossNotes: [LossNote] = []
        while let stream = file.stream("BodyText/Section\(index)") {
            index += 1
            var body = stream
            if compressed {
                guard let inflated = Inflate.raw(stream, limit: ZipArchive.maxEntrySize) else { throw ConversionError.damaged("hwp") }
                body = inflated
            }
            let records = Record.parse(body)
            var parser = Parser(records: records)
            blocks += parser.sectionBlocks()
            if parser.skippedControls { lossNotes.append(LossNote(.formattingSimplified, detail: "drawings and equations")) }
        }
        guard !blocks.isEmpty else { throw ConversionError.damaged("hwp") }
        var metadata = DocMetadata()
        if let info = file.stream("\u{5}HwpSummaryInformation") { metadata = summary(info) }
        return DocReadResult(model: DocModel(metadata: metadata, blocks: blocks), lossNotes: lossNotes)
    }

    /// Title and author from the OLE property set (HwpSummaryInformation).
    private static func summary(_ data: Data) -> DocMetadata {
        var metadata = DocMetadata()
        guard data.count > 48 else { return metadata }
        let sectionOffset = Int(data.u32(44))
        guard sectionOffset + 8 < data.count else { return metadata }
        let count = Int(data.u32(sectionOffset + 4))
        guard count < 64 else { return metadata }
        for i in 0..<count {
            let entry = sectionOffset + 8 + i * 8
            guard entry + 8 <= data.count else { break }
            let id = data.u32(entry), offset = sectionOffset + Int(data.u32(entry + 4))
            guard offset + 8 <= data.count, data.u32(offset) == 0x1E else { continue }   // VT_LPSTR
            let length = Int(data.u32(offset + 4))
            guard length > 0, offset + 8 + length <= data.count else { continue }
            let text = String(decoding: data.subdata(in: offset + 8..<offset + 8 + length).prefix { $0 != 0 }, as: UTF8.self)
            if id == 2, !text.isEmpty { metadata.title = text }
            if id == 4, !text.isEmpty { metadata.authors = [text] }
        }
        return metadata
    }

    // MARK: Records

    struct Record {
        var tag: Int
        var level: Int
        var data: Data

        static let paraHeader = 0x42, paraText = 0x43, ctrlHeader = 0x47, listHeader = 0x48

        static func parse(_ data: Data) -> [Record] {
            var out: [Record] = []
            var p = 0
            while p + 4 <= data.count {
                let header = data.u32(p)
                p += 4
                let tag = Int(header & 0x3FF), level = Int((header >> 10) & 0x3FF)
                var size = Int(header >> 20)
                if size == 0xFFF { guard p + 4 <= data.count else { break }; size = Int(data.u32(p)); p += 4 }
                guard size >= 0, p + size <= data.count else { break }
                out.append(Record(tag: tag, level: level, data: data.subdata(in: data.startIndex + p..<data.startIndex + p + size)))
                p += size
            }
            return out
        }
    }

    private struct Parser {
        let records: [Record]
        var position = 0
        var skippedControls = false

        init(records: [Record]) { self.records = records }

        mutating func sectionBlocks() -> [DocBlock] {
            blocks(level: 0, count: nil)
        }

        /// Paragraphs at `level` until a record at a lower level, or `count` paragraphs.
        mutating func blocks(level: Int, count: Int?) -> [DocBlock] {
            var out: [DocBlock] = []
            var taken = 0
            while position < records.count, count.map({ taken < $0 }) ?? true {
                let record = records[position]
                if record.level < level { break }
                guard record.tag == Record.paraHeader, record.level == level else { position += 1; continue }
                position += 1
                taken += 1
                out += paragraph(level: level)
            }
            return out
        }

        mutating func paragraph(level: Int) -> [DocBlock] {
            var text = ""
            var tables: [DocBlock] = []
            while position < records.count, records[position].level > level {
                let record = records[position]
                switch record.tag {
                case Record.paraText:
                    text += Self.text(record.data)
                    position += 1
                case Record.ctrlHeader:
                    let id = record.data.count >= 4 ? String(decoding: record.data.prefix(4).reversed(), as: UTF8.self) : ""
                    position += 1
                    if id == "tbl " { tables.append(table(level: record.level)) } else {
                        if ["gso ", "eqed"].contains(id) { skippedControls = true }
                        // Skip the control's children (its nested paragraphs are read as the text of drawings and notes).
                        while position < records.count, records[position].level > record.level { position += 1 }
                    }
                default:
                    position += 1
                }
            }
            var out: [DocBlock] = []
            for line in text.split(separator: "\u{2029}", omittingEmptySubsequences: false) where !line.isEmpty || text.isEmpty {
                var inline: DocText = []
                for (i, piece) in line.split(separator: "\u{2028}", omittingEmptySubsequences: false).enumerated() {
                    if i > 0 { inline.append(.lineBreak) }
                    if !piece.isEmpty { inline.append(.text(String(piece))) }
                }
                if !inline.isEmpty { out.append(.paragraph(inline, DocParagraphStyle())) }
            }
            return out + tables
        }

        /// UTF-16 text with HWP's control characters: 10 line break, 13 paragraph end, 9 tab (inline control, 8 wchars),
        /// extended and inline controls are skipped along with their 14 bytes of data.
        static func text(_ data: Data) -> String {
            var out = ""
            var i = 0
            while i + 2 <= data.count {
                let unit = data.u16(i)
                i += 2
                switch unit {
                case 0: break
                case 9: out += "\t"; i += 14
                case 1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23: i += 14
                case 10: out += "\u{2028}"
                case 13: out += "\u{2029}"
                case 24: out += "-"
                case 30, 31: out += " "
                default:
                    if let scalar = Unicode.Scalar(UInt32(unit)) { out.unicodeScalars.append(scalar) }
                    else if (0xD800..<0xDC00).contains(unit), i + 2 <= data.count {
                        let low = data.u16(i)
                        if (0xDC00..<0xE000).contains(low), let scalar = Unicode.Scalar(0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)) { out.unicodeScalars.append(scalar); i += 2 }
                    }
                }
            }
            return out
        }

        /// A table control: each cell's LIST_HEADER (paragraph count, column, row, spans) followed by its paragraphs.
        mutating func table(level: Int) -> DocBlock {
            var cells: [(row: Int, column: Int, colSpan: Int, rowSpan: Int, blocks: [DocBlock])] = []
            while position < records.count, records[position].level > level {
                let record = records[position]
                if record.tag == Record.listHeader, record.data.count >= 16 {
                    let count = Int(record.data.u16(0))
                    let column = Int(record.data.u16(6)), row = Int(record.data.u16(8))
                    let colSpan = max(Int(record.data.u16(10)), 1), rowSpan = max(Int(record.data.u16(12)), 1)
                    let cellLevel = record.level
                    position += 1
                    let content = blocks(level: cellLevel, count: count)
                    cells.append((row, column, colSpan, rowSpan, content.isEmpty ? [.paragraph([], DocParagraphStyle())] : content))
                } else {
                    position += 1
                }
            }
            let rows = Dictionary(grouping: cells, by: \.row).sorted { $0.key < $1.key }.map { _, row in
                row.sorted { $0.column < $1.column }.map { DocTable.Cell(blocks: $0.blocks, columnSpan: $0.colSpan, rowSpan: $0.rowSpan, isHeader: false) }
            }
            return .table(DocTable(rows: rows))
        }
    }
}

/// An OLE compound file (MS-CFB): sectors, the FAT, mini streams, the directory tree. Read-only.
struct CompoundFile {
    private let data: Data
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniCutoff: Int
    private var fat: [UInt32] = []
    private var miniFat: [UInt32] = []
    private var entries: [Entry] = []
    private var miniStream = Data()

    struct Entry {
        var name: String
        var type: UInt8
        var left: UInt32, right: UInt32, child: UInt32
        var start: UInt32
        var size: Int
    }

    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let free: UInt32 = 0xFFFF_FFFF

    init?(_ data: Data) {
        guard data.count > 512, data.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else { return nil }
        self.data = data
        let shift = Int(data.u16(30)), miniShift = Int(data.u16(32))
        guard (7...16).contains(shift), (4...shift).contains(miniShift) else { return nil }
        sectorSize = 1 << shift
        miniSectorSize = 1 << miniShift
        miniCutoff = Int(data.u32(56))
        // The FAT: sector numbers from the header's DIFAT, then the DIFAT chain.
        var fatSectors: [UInt32] = []
        for i in 0..<109 { let s = data.u32(76 + i * 4); if s != Self.free { fatSectors.append(s) } }
        var difat = data.u32(68)
        var guardCount = 0
        while difat != Self.free, difat != Self.endOfChain, guardCount < 10_000 {
            guardCount += 1
            guard let sector = Self.sector(data, difat, sectorSize) else { return nil }
            for i in 0..<(sectorSize / 4 - 1) { let s = sector.u32(i * 4); if s != Self.free { fatSectors.append(s) } }
            difat = sector.u32(sectorSize - 4)
        }
        for s in fatSectors {
            guard let sector = Self.sector(data, s, sectorSize) else { return nil }
            for i in 0..<(sectorSize / 4) { fat.append(sector.u32(i * 4)) }
        }
        let directory = chain(from: data.u32(48))
        guard !directory.isEmpty else { return nil }
        for i in 0..<(directory.count / 128) {
            let e = directory.subdata(in: i * 128..<(i + 1) * 128)
            let nameLength = min(Int(e.u16(64)), 64)
            var units: [UInt16] = []
            for k in 0..<max(nameLength / 2 - 1, 0) { units.append(e.u16(k * 2)) }
            let name = String(decoding: units, as: UTF16.self)
            entries.append(Entry(name: name, type: e[66], left: e.u32(68), right: e.u32(72), child: e.u32(76), start: e.u32(116), size: Int(e.u32(120))))
        }
        let miniChain = chain(from: data.u32(60))
        if let root = entries.first {
            miniStream = chain(from: root.start).prefix(root.size)
            if !miniChain.isEmpty { for i in 0..<(miniChain.count / 4) { miniFat.append(miniChain.u32(i * 4)) } }
        }
    }

    private static func sector(_ data: Data, _ n: UInt32, _ size: Int) -> Data? {
        let start = (Int(n) + 1) * size
        guard start >= 0, start + size <= data.count else { return nil }
        return data.subdata(in: data.startIndex + start..<data.startIndex + start + size)
    }

    private func chain(from start: UInt32) -> Data {
        var out = Data()
        var s = start
        var steps = 0
        while s != Self.endOfChain, s != Self.free, Int(s) < fat.count, steps < 1_000_000 {
            guard let sector = Self.sector(data, s, sectorSize) else { break }
            out.append(sector)
            s = fat[Int(s)]
            steps += 1
        }
        return out
    }

    /// A stream by path ("BodyText/Section0"); names compare as the file stores them.
    func stream(_ path: String) -> Data? {
        var index = 0   // the root entry
        for component in path.split(separator: "/") {
            guard let found = find(String(component), in: entries[index].child) else { return nil }
            index = found
        }
        let entry = entries[index]
        guard entry.type == 2 else { return nil }
        if entry.size < miniCutoff {
            var out = Data()
            var s = entry.start
            var steps = 0
            while s != Self.endOfChain, s != Self.free, Int(s) < miniFat.count, steps < 1_000_000 {
                let start = Int(s) * miniSectorSize
                guard start + miniSectorSize <= miniStream.count else { break }
                out.append(miniStream.subdata(in: miniStream.startIndex + start..<miniStream.startIndex + start + miniSectorSize))
                s = miniFat[Int(s)]
                steps += 1
            }
            return out.prefix(entry.size)
        }
        return chain(from: entry.start).prefix(entry.size)
    }

    /// Searches the red-black tree of sibling entries under a storage.
    private func find(_ name: String, in root: UInt32) -> Int? {
        var stack: [UInt32] = [root]
        var visited = Set<UInt32>()
        while let node = stack.popLast() {
            guard node != Self.free, Int(node) < entries.count, visited.insert(node).inserted else { continue }
            let entry = entries[Int(node)]
            if entry.name == name { return Int(node) }
            stack.append(entry.left); stack.append(entry.right)
        }
        return nil
    }
}
