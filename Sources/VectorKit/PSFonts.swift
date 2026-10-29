import CoreText
import Foundation

/// The TrueType fonts a PostScript file uses, embedded as Type 42 (Adobe Technical Note #5012) so text stays text
/// (formats §3.2, `PSWriter`; O-VEC "Text as outlines" off). Each font is subset by emptying the outlines of glyphs that
/// are not shown (composite components kept) and keeping only the tables a Type 42 rasteriser reads; glyphs are drawn
/// by name with `glyphshow` (`/g<id>` → glyph id in CharStrings), so any number of glyphs needs no re-encoding.
/// CFF-flavoured fonts have no `glyf` table: the caller draws their text as outlines.
final class PSFonts {
    struct Font {
        let resourceName: String
        let tables: [String: [UInt8]]
        var glyphs: Set<Int> = [0]
    }

    private(set) var fonts: [Font] = []
    private var index: [String: Int?] = [:]
    /// Tables a Type 42 font needs; the rest (names, cmap, layout tables) are never read by a PostScript interpreter.
    private static let kept = ["head", "hhea", "hmtx", "maxp", "loca", "glyf", "cvt ", "fpgm", "prep"]

    /// The PostScript font name for `font` with `glyphs` recorded as used, or nil when it has no TrueType outlines.
    /// `key` tells apart fonts that share a PostScript name (an embedded program and an installed font).
    func use(_ font: CTFont, key: String, glyphs: [CGGlyph]) -> String? {
        let slot: Int?
        if let known = index[key] { slot = known } else {
            slot = Self.load(font, number: fonts.count + 1).map { fonts.append($0); return fonts.count - 1 }
            index[key] = slot
        }
        guard let slot else { return nil }
        fonts[slot].glyphs.formUnion(glyphs.map(Int.init))
        return fonts[slot].resourceName
    }

    private static func load(_ font: CTFont, number: Int) -> Font? {
        var tables: [String: [UInt8]] = [:]
        for tag in kept {
            let code = tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if let data = CTFontCopyTable(font, CTFontTableTag(code), []) as Data? { tables[tag] = [UInt8](data) }
        }
        guard ["head", "hhea", "hmtx", "maxp", "loca", "glyf"].allSatisfy({ tables[$0] != nil }),
              (tables["head"]?.count ?? 0) >= 54, (tables["maxp"]?.count ?? 0) >= 6 else { return nil }
        let base = (CTFontCopyPostScriptName(font) as String).unicodeScalars
            .filter { $0.isASCII && $0.value > 32 && !"()<>[]{}/%".unicodeScalars.contains($0) }
        // A subset tag as in PDF, so a printer never confuses the subset with a resident font of the same name.
        return Font(resourceName: "SC\(String(format: "%04d", number))+" + (base.isEmpty ? "Font" : String(String.UnicodeScalarView(base))), tables: tables)
    }

    /// `%%BeginResource` … `%%EndResource` blocks defining every font used so far.
    func resources() -> String { fonts.map(Self.resource).joined() }

    private static func resource(_ font: Font) -> String {
        let head = font.tables["head"]!
        let unitsPerEm = Double(max(16, u16(head, 18)))
        let bbox = [i16(head, 36), i16(head, 38), i16(head, 40), i16(head, 42)].map { SVGWriter.fmt(Double($0) / unitsPerEm) }
        let (sfnt, cuts) = subset(font)
        let used = font.glyphs.sorted()
        var out = "%%BeginResource: font \(font.resourceName)\n"
        out += "11 dict begin\n/FontName /\(font.resourceName) def\n/FontType 42 def\n/PaintType 0 def\n"
        out += "/FontMatrix [1 0 0 1 0 0] def\n/FontBBox [\(bbox.joined(separator: " "))] def\n"
        out += "/Encoding 256 array 0 1 255 { 1 index exch /.notdef put } for def\n"
        out += "/CharStrings \(used.count + 1) dict dup begin\n/.notdef 0 def\n"
        out += used.map { "/g\($0) \($0) def" }.joined(separator: "\n") + "\nend readonly def\n"
        out += "/sfnts [\n"
        // Every string ends with one pad byte the interpreter ignores (TN #5012 §4.2).
        for (start, end) in zip(cuts, cuts.dropFirst()) {
            var hex = ""
            for (k, byte) in sfnt[start..<end].enumerated() {
                if k > 0 && k % 40 == 0 { hex += "\n" }
                hex += String(format: "%02X", byte)
            }
            out += "<" + hex + "00>\n"
        }
        out += "] def\nFontName currentdict end definefont pop\n%%EndResource\n"
        return out
    }

    /// The subset font file and the offsets where the sfnts strings break: table boundaries, glyph boundaries inside
    /// `glyf`, each string under 65 535 bytes with its pad byte.
    private static func subset(_ font: Font) -> ([UInt8], [Int]) {
        let head = font.tables["head"]!, loca = font.tables["loca"]!, glyf = font.tables["glyf"]!
        let count = u16(font.tables["maxp"]!, 4)
        let long = i16(head, 50) == 1
        func offset(_ g: Int) -> Int { long ? u32(loca, g * 4) : u16(loca, g * 2) * 2 }
        func glyph(_ g: Int) -> ArraySlice<UInt8> {
            guard g < count, (g + 2) * (long ? 4 : 2) <= loca.count else { return [] }
            let s = offset(g), e = offset(g + 1)
            return s < e && e <= glyf.count ? glyf[s..<e] : []
        }
        // Composite glyphs pull in their components.
        var used = Set(font.glyphs.filter { $0 < count }), queue = Array(used)
        while let g = queue.popLast() {
            let data = Array(glyph(g))
            guard data.count >= 10, i16(data, 0) < 0 else { continue }
            var o = 10
            while o + 4 <= data.count {
                let flags = u16(data, o), component = u16(data, o + 2)
                if used.insert(component).inserted { queue.append(component) }
                o += 4 + (flags & 1 != 0 ? 4 : 2) + (flags & 8 != 0 ? 2 : flags & 0x40 != 0 ? 4 : flags & 0x80 != 0 ? 8 : 0)
                if flags & 0x20 == 0 { break }
            }
        }
        var newGlyf: [UInt8] = [], newLoca: [UInt8] = [], glyphEnds: [Int] = []
        for g in 0..<count {
            put32(&newLoca, newGlyf.count)
            if used.contains(g) {
                newGlyf.append(contentsOf: glyph(g))
                while newGlyf.count % 4 != 0 { newGlyf.append(0) }
            }
            glyphEnds.append(newGlyf.count)
        }
        put32(&newLoca, newGlyf.count)
        var tables = font.tables
        var newHead = head
        newHead[8] = 0; newHead[9] = 0; newHead[10] = 0; newHead[11] = 0   // checkSumAdjustment: not used by rasterisers
        newHead[50] = 0; newHead[51] = 1                                     // indexToLocFormat: long offsets
        tables["head"] = newHead; tables["loca"] = newLoca; tables["glyf"] = newGlyf

        let tags = tables.keys.sorted()
        var file: [UInt8] = []
        put32(&file, 0x0001_0000)
        let n = tags.count
        var power = 1, log = 0
        while power * 2 <= n { power *= 2; log += 1 }
        put16(&file, n); put16(&file, power * 16); put16(&file, log); put16(&file, n * 16 - power * 16)
        var offsetHere = 12 + 16 * n
        for tag in tags {
            let data = tables[tag]!
            file.append(contentsOf: Array(tag.utf8))
            put32(&file, checksum(data)); put32(&file, offsetHere); put32(&file, data.count)
            offsetHere += (data.count + 3) & ~3
        }
        // Cut points: the directory, then each table; glyf may break between glyphs; any other table over the limit
        // is cut at an even offset (only the glyf rule is required by TN #5012).
        let limit = 65_534
        var atoms: [Int] = [file.count]
        for tag in tags {
            let start = file.count
            file.append(contentsOf: tables[tag]!)
            while file.count % 4 != 0 { file.append(0) }
            if tag == "glyf" {
                atoms.append(contentsOf: glyphEnds.map { start + $0 })
            } else {
                var at = start + limit - limit % 4
                while at < file.count { atoms.append(at); at += limit - limit % 4 }
            }
            atoms.append(file.count)
        }
        var cuts = [0], last = 0, previous = 0
        for atom in Set(atoms).sorted() where atom > last {
            if atom - last > limit, previous > last { cuts.append(previous); last = previous }
            previous = atom
        }
        if cuts.last! < file.count { cuts.append(file.count) }
        return (file, cuts)
    }

    private static func checksum(_ data: [UInt8]) -> Int {
        var sum: UInt32 = 0
        for i in stride(from: 0, to: data.count, by: 4) {
            var word: UInt32 = 0
            for k in 0..<4 { word = word << 8 | UInt32(i + k < data.count ? data[i + k] : 0) }
            sum = sum &+ word
        }
        return Int(sum)
    }

    private static func u16(_ b: [UInt8], _ o: Int) -> Int { o + 1 < b.count ? Int(b[o]) << 8 | Int(b[o + 1]) : 0 }
    private static func i16(_ b: [UInt8], _ o: Int) -> Int { let v = u16(b, o); return v > 32767 ? v - 65536 : v }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int { u16(b, o) << 16 | u16(b, o + 2) }
    private static func put16(_ b: inout [UInt8], _ v: Int) { b.append(UInt8(v >> 8 & 0xFF)); b.append(UInt8(v & 0xFF)) }
    private static func put32(_ b: inout [UInt8], _ v: Int) { put16(&b, v >> 16 & 0xFFFF); put16(&b, v & 0xFFFF) }
}
