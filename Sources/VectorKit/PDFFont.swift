import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore

/// A PDF font as the reader needs it: how string bytes become glyphs (code, Unicode, advance), and where outlines come
/// from — the embedded TrueType/OpenType program when Core Text can open it, else a system font standing in by name.
final class PDFFont {
    struct Glyph {
        var code: Int
        var unicode: String
        /// Advance in 1/1000 em.
        var width: Double
        var isSpace: Bool
        var glyphName: String?
    }

    let isType0: Bool
    private(set) var widths: [Int: Double] = [:]
    private(set) var defaultWidth = 0.0
    private(set) var missingWidth = 0.0
    private var toUnicode: [Int: String] = [:]
    private var encoding: [String?] = Array(repeating: nil, count: 256)
    private var encodingNames: [String?] = Array(repeating: nil, count: 256)
    private(set) var hasWidths = false
    /// The embedded program as a font at 1 pt (paths come out in em units).
    private(set) var embedded: CTFont?
    /// The embedded program's bytes (an SFNT), carried on text runs that stay text.
    private(set) var embeddedProgram: Data?
    private var cidToGID: [Int]?
    private var cidToGIDIdentity = true
    /// PostScript name of the system font that stands in when nothing is embedded or the program can't be used.
    private(set) var substitute = "Helvetica"
    private(set) var hadUnusableEmbedding = false
    private(set) var isSymbolic = false
    var codeBytes = 1
    private var glyphCache: [Int: [PathSegment]?] = [:]
    private var substituteFont: CTFont?

    init(_ dict: CGPDFDictionaryRef) {
        let subtype = PDFObj.name(dict, "Subtype") ?? "Type1"
        isType0 = subtype == "Type0"
        var baseName = PDFObj.name(dict, "BaseFont") ?? "Helvetica"
        var descriptor = PDFObj.dict(dict, "FontDescriptor")
        if isType0 {
            codeBytes = 2
            if let descendants = PDFObj.array(dict, "DescendantFonts"), let cid = PDFObj.dictElement(descendants, 0) {
                descriptor = PDFObj.dict(cid, "FontDescriptor")
                if let n = PDFObj.name(cid, "BaseFont") { baseName = n }
                defaultWidth = PDFObj.number(cid, "DW") ?? 1000
                parseCIDWidths(cid)
                parseCIDToGID(cid)
                if PDFObj.name(dict, "Encoding") == nil, let st = PDFObj.stream(dict, "Encoding"), let loaded = PDFObj.data(st) { codeBytes = PDFFont.codespaceBytes(loaded.0) }
            }
        } else {
            parseSimpleWidths(dict)
            buildEncoding(dict, subtype: subtype)
        }
        if let st = PDFObj.stream(dict, "ToUnicode"), let loaded = PDFObj.data(st) { toUnicode = PDFFont.parseToUnicode(loaded.0) }
        let flags = descriptor.flatMap { PDFObj.int($0, "Flags") } ?? 0
        isSymbolic = flags & 4 != 0 && flags & 32 == 0
        missingWidth = descriptor.flatMap { PDFObj.number($0, "MissingWidth") } ?? 0
        loadEmbedded(descriptor)
        substitute = PDFFont.substituteName(baseName: baseName, flags: flags)
    }

    // MARK: Widths and encodings

    private func parseSimpleWidths(_ dict: CGPDFDictionaryRef) {
        guard let first = PDFObj.int(dict, "FirstChar"), (0..<256).contains(first), let array = PDFObj.array(dict, "Widths") else { return }
        for (i, w) in PDFObj.numbers(array).prefix(256).enumerated() { widths[first + i] = w }
        hasWidths = true
    }

    /// CIDs are 16-bit; the `W` array's runs are clipped to that range, and all of them together set at most a few full
    /// ranges' worth of widths (a damaged array can repeat a 65 536-wide run endlessly).
    private func parseCIDWidths(_ dict: CGPDFDictionaryRef) {
        guard let w = PDFObj.array(dict, "W") else { return }
        var i = 0
        var budget = 1 << 18
        let n = CGPDFArrayGetCount(w)
        func cid(_ v: Double) -> Int { v.isNaN ? -1 : Int(min(max(v, -1), 65_536)) }
        while i < n, budget > 0 {
            guard let firstNumber = PDFObj.numberElement(w, i) else { i += 1; continue }
            let first = cid(firstNumber)
            if let list = PDFObj.arrayElement(w, i + 1) {
                for (k, width) in PDFObj.numbers(list).enumerated() where first >= 0 && first + k < 65_536 { widths[first + k] = width; budget -= 1 }
                i += 2
            } else if let last = PDFObj.numberElement(w, i + 1).map(cid), let width = PDFObj.numberElement(w, i + 2) {
                if first >= 0, first <= last { for c in first...min(last, 65_535) { widths[c] = width }; budget -= last - first + 1 }
                i += 3
            } else { i += 1 }
        }
        hasWidths = true
    }

    private func parseCIDToGID(_ dict: CGPDFDictionaryRef) {
        if let st = PDFObj.stream(dict, "CIDToGIDMap"), let loaded = PDFObj.data(st) {
            let bytes = loaded.0
            cidToGIDIdentity = false
            cidToGID = stride(from: 0, to: bytes.count - 1, by: 2).map { Int(bytes[bytes.startIndex + $0]) << 8 | Int(bytes[bytes.startIndex + $0 + 1]) }
        }
    }

    private func buildEncoding(_ dict: CGPDFDictionaryRef, subtype: String) {
        var base = subtype == "TrueType" ? "WinAnsiEncoding" : "StandardEncoding"
        var differences: CGPDFArrayRef?
        if let name = PDFObj.name(dict, "Encoding") { base = name }
        else if let enc = PDFObj.dict(dict, "Encoding") {
            if let b = PDFObj.name(enc, "BaseEncoding") { base = b }
            differences = PDFObj.array(enc, "Differences")
        }
        for code in 0..<256 { encoding[code] = PDFFont.unicode(forCode: code, encoding: base) }
        if let differences {
            var code = 0
            for i in 0..<CGPDFArrayGetCount(differences) {
                // A code outside 0...255 (damage) names nothing until the next number.
                if let n = PDFObj.numberElement(differences, i) { code = n >= 0 && n < 256 ? Int(n) : 256 }
                else if let name = PDFObj.nameElement(differences, i) {
                    if code >= 0, code < 256 { encoding[code] = PDFFont.unicode(forGlyphName: name); encodingNames[code] = name }
                    code += 1
                }
            }
        }
    }

    static func unicode(forCode code: Int, encoding: String) -> String? {
        let byte = UInt8(code)
        switch encoding {
        case "WinAnsiEncoding":
            if code < 32 { return nil }
            return String(data: Data([byte]), encoding: .windowsCP1252)
        case "MacRomanEncoding":
            if code < 32 { return nil }
            return String(data: Data([byte]), encoding: .macOSRoman)
        default:
            if code < 32 { return nil }
            if code < 128 { return code == 0x27 ? "\u{2019}" : code == 0x60 ? "\u{2018}" : String(UnicodeScalar(byte)) }
            return standardUpper[code].map { String(UnicodeScalar($0)!) }
        }
    }

    private static let standardUpper: [Int: UInt32] = [
        0xA1: 0xA1, 0xA2: 0xA2, 0xA3: 0xA3, 0xA4: 0x2044, 0xA5: 0xA5, 0xA6: 0x192, 0xA7: 0xA7, 0xA8: 0xA4, 0xA9: 0x27, 0xAA: 0x201C, 0xAB: 0xAB,
        0xAC: 0x2039, 0xAD: 0x203A, 0xAE: 0xFB01, 0xAF: 0xFB02, 0xB1: 0x2013, 0xB2: 0x2020, 0xB3: 0x2021, 0xB4: 0xB7, 0xB6: 0xB6, 0xB7: 0x2022,
        0xB8: 0x201A, 0xB9: 0x201E, 0xBA: 0x201D, 0xBB: 0xBB, 0xBC: 0x2026, 0xBD: 0x2030, 0xBF: 0xBF, 0xC1: 0x60, 0xC2: 0xB4, 0xC3: 0x2C6,
        0xC4: 0x2DC, 0xC5: 0xAF, 0xC6: 0x2D8, 0xC7: 0x2D9, 0xC8: 0xA8, 0xCA: 0x2DA, 0xCB: 0xB8, 0xCD: 0x2DD, 0xCE: 0x2DB, 0xCF: 0x2C7,
        0xD0: 0x2014, 0xE1: 0xC6, 0xE3: 0xAA, 0xE8: 0x141, 0xE9: 0xD8, 0xEA: 0x152, 0xEB: 0xBA, 0xF1: 0xE6, 0xF5: 0x131, 0xF8: 0x142,
        0xF9: 0xF8, 0xFA: 0x153, 0xFB: 0xDF,
    ]

    // MARK: Glyph names

    private static let namedGlyphs: [String: String] = [
        "space": " ", "exclam": "!", "quotedbl": "\"", "numbersign": "#", "dollar": "$", "percent": "%", "ampersand": "&", "quotesingle": "'",
        "parenleft": "(", "parenright": ")", "asterisk": "*", "plus": "+", "comma": ",", "hyphen": "-", "minus": "\u{2212}", "period": ".",
        "slash": "/", "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "colon": ":", "semicolon": ";", "less": "<", "equal": "=", "greater": ">", "question": "?", "at": "@",
        "bracketleft": "[", "backslash": "\\", "bracketright": "]", "asciicircum": "^", "underscore": "_", "grave": "`", "braceleft": "{",
        "bar": "|", "braceright": "}", "asciitilde": "~", "bullet": "\u{2022}", "endash": "\u{2013}", "emdash": "\u{2014}",
        "quoteleft": "\u{2018}", "quoteright": "\u{2019}", "quotedblleft": "\u{201C}", "quotedblright": "\u{201D}", "quotesinglbase": "\u{201A}",
        "quotedblbase": "\u{201E}", "ellipsis": "\u{2026}", "dagger": "\u{2020}", "daggerdbl": "\u{2021}", "perthousand": "\u{2030}",
        "guilsinglleft": "\u{2039}", "guilsinglright": "\u{203A}", "guillemotleft": "\u{AB}", "guillemotright": "\u{BB}", "fi": "\u{FB01}",
        "fl": "\u{FB02}", "ff": "\u{FB00}", "ffi": "\u{FB03}", "ffl": "\u{FB04}", "section": "\u{A7}", "paragraph": "\u{B6}", "copyright": "\u{A9}",
        "registered": "\u{AE}", "trademark": "\u{2122}", "degree": "\u{B0}", "plusminus": "\u{B1}", "multiply": "\u{D7}", "divide": "\u{F7}",
        "mu": "\u{B5}", "periodcentered": "\u{B7}", "exclamdown": "\u{A1}", "questiondown": "\u{BF}", "cent": "\u{A2}", "sterling": "\u{A3}",
        "currency": "\u{A4}", "yen": "\u{A5}", "Euro": "\u{20AC}", "florin": "\u{192}", "germandbls": "\u{DF}", "AE": "\u{C6}", "ae": "\u{E6}",
        "OE": "\u{152}", "oe": "\u{153}", "Oslash": "\u{D8}", "oslash": "\u{F8}", "Lslash": "\u{141}", "lslash": "\u{142}", "dotlessi": "\u{131}",
        "ordfeminine": "\u{AA}", "ordmasculine": "\u{BA}", "logicalnot": "\u{AC}", "onesuperior": "\u{B9}", "twosuperior": "\u{B2}",
        "threesuperior": "\u{B3}", "onequarter": "\u{BC}", "onehalf": "\u{BD}", "threequarters": "\u{BE}", "brokenbar": "\u{A6}",
        "fraction": "\u{2044}", "Eth": "\u{D0}", "eth": "\u{F0}", "Thorn": "\u{DE}", "thorn": "\u{FE}", "Yacute": "\u{DD}", "yacute": "\u{FD}",
        "nbspace": "\u{A0}", "nonbreakingspace": "\u{A0}", "hyphenminus": "-", "softhyphen": "\u{AD}", "macron": "\u{AF}", "acute": "\u{B4}",
        "dieresis": "\u{A8}", "cedilla": "\u{B8}", "circumflex": "\u{2C6}", "tilde": "\u{2DC}", "caron": "\u{2C7}", "breve": "\u{2D8}",
        "dotaccent": "\u{2D9}", "ring": "\u{2DA}", "ogonek": "\u{2DB}", "hungarumlaut": "\u{2DD}", "summation": "\u{2211}", "product": "\u{220F}",
        "radical": "\u{221A}", "infinity": "\u{221E}", "integral": "\u{222B}", "notequal": "\u{2260}", "lessequal": "\u{2264}",
        "greaterequal": "\u{2265}", "approxequal": "\u{2248}", "partialdiff": "\u{2202}", "Delta": "\u{394}", "Omega": "\u{3A9}", "pi": "\u{3C0}",
        "alpha": "\u{3B1}", "beta": "\u{3B2}", "gamma": "\u{3B3}", "delta": "\u{3B4}", "epsilon": "\u{3B5}", "lambda": "\u{3BB}", "sigma": "\u{3C3}",
        "theta": "\u{3B8}", "omega": "\u{3C9}", "arrowright": "\u{2192}", "arrowleft": "\u{2190}", "arrowup": "\u{2191}", "arrowdown": "\u{2193}",
    ]
    private static let accents: [String: String] = [
        "acute": "\u{301}", "grave": "\u{300}", "circumflex": "\u{302}", "tilde": "\u{303}", "dieresis": "\u{308}", "ring": "\u{30A}",
        "caron": "\u{30C}", "cedilla": "\u{327}", "macron": "\u{304}", "breve": "\u{306}", "dotaccent": "\u{307}", "ogonek": "\u{328}",
        "hungarumlaut": "\u{30B}", "stroke": "",
    ]

    static func unicode(forGlyphName rawName: String) -> String? {
        var name = rawName
        if let dot = name.firstIndex(of: "."), dot != name.startIndex { name = String(name[..<dot]) }
        if let hit = namedGlyphs[name] { return hit }
        if name.count == 1 { return name }
        if name.hasPrefix("uni"), name.count >= 7, let v = UInt32(name.dropFirst(3).prefix(4), radix: 16), let s = UnicodeScalar(v) { return String(s) }
        if name.hasPrefix("u"), name.count >= 5, name.count <= 7, let v = UInt32(name.dropFirst(1), radix: 16), let s = UnicodeScalar(v) { return String(s) }
        for (accent, mark) in accents where name.hasSuffix(accent) && name.count == accent.count + 1 {
            return (String(name.prefix(1)) + mark).precomposedStringWithCanonicalMapping
        }
        if name.contains("_") { return name.split(separator: "_").compactMap { unicode(forGlyphName: String($0)) }.joined() }
        return nil
    }

    // MARK: ToUnicode and CMap parsing

    static func parseToUnicode(_ data: Data) -> [Int: String] {
        let text = String(decoding: data, as: UTF8.self)
        var map: [Int: String] = [:]
        func utf16(_ hex: String) -> String {
            var units: [UInt16] = []
            var i = hex.startIndex
            while hex.distance(from: i, to: hex.endIndex) >= 4 {
                let j = hex.index(i, offsetBy: 4)
                if let u = UInt16(hex[i..<j], radix: 16) { units.append(u) }
                i = j
            }
            return String(decoding: units, as: UTF16.self)
        }
        func hexTokens(_ s: Substring) -> [String] {
            var out: [String] = []
            var cur = ""
            var inHex = false
            for ch in s { if ch == "<" { inHex = true; cur = "" } else if ch == ">" { inHex = false; out.append(cur) } else if inHex { cur.append(ch) } }
            return out
        }
        var rest = Substring(text)
        while let r = rest.range(of: "beginbfchar") {
            rest = rest[r.upperBound...]
            guard let end = rest.range(of: "endbfchar") else { break }
            for line in rest[..<end.lowerBound].split(whereSeparator: { $0.isNewline }) {
                let t = hexTokens(line)
                if t.count >= 2, let code = Int(t[0], radix: 16) { map[code] = utf16(t[1]) }
            }
            rest = rest[end.upperBound...]
        }
        rest = Substring(text)
        // Ranges together map at most a few full 16-bit code spaces: a damaged CMap can repeat a 65 536-code range endlessly.
        var budget = 1 << 18
        while budget > 0, let r = rest.range(of: "beginbfrange") {
            rest = rest[r.upperBound...]
            guard let end = rest.range(of: "endbfrange") else { break }
            for line in rest[..<end.lowerBound].split(whereSeparator: { $0.isNewline }) where budget > 0 {
                let t = hexTokens(line)
                guard t.count >= 3, let lo = Int(t[0], radix: 16), let hi = Int(t[1], radix: 16), hi >= lo, hi - lo < 65536 else { continue }
                budget -= hi - lo + 1
                if line.contains("[") {
                    for (k, h) in t.dropFirst(2).enumerated() where lo + k <= hi { map[lo + k] = utf16(h) }
                } else {
                    let start = utf16(t[2])
                    guard let last = start.unicodeScalars.last else { continue }
                    for c in lo...hi {
                        var scalars = Array(start.unicodeScalars.dropLast())
                        if let s = UnicodeScalar(last.value + UInt32(c - lo)) { scalars.append(s) }
                        map[c] = String(String.UnicodeScalarView(scalars))
                    }
                }
            }
            rest = rest[end.upperBound...]
        }
        return map
    }

    /// Code length from a CMap's codespace range (`<0000> <FFFF>` → 2 bytes).
    static func codespaceBytes(_ data: Data) -> Int {
        let text = String(decoding: data, as: UTF8.self)
        guard let r = text.range(of: "begincodespacerange"), let open = text[r.upperBound...].firstIndex(of: "<"),
              let close = text[open...].firstIndex(of: ">") else { return 2 }
        return max(1, min(4, (text.distance(from: open, to: close) - 1) / 2))
    }

    // MARK: Fonts

    private func loadEmbedded(_ descriptor: CGPDFDictionaryRef?) {
        guard let descriptor else { return }
        for key in ["FontFile2", "FontFile3", "FontFile"] {
            guard let stream = PDFObj.stream(descriptor, key), let loaded = PDFObj.data(stream) else { continue }
            if let font = PDFFont.coreTextFont(from: loaded.0) { embedded = font; embeddedProgram = loaded.0; return }
            hadUnusableEmbedding = true
        }
    }

    /// Opens an SFNT (TrueType / OpenType) program without registering it system-wide.
    static func coreTextFont(from data: Data) -> CTFont? {
        guard data.count > 12 else { return nil }
        let sfnt: Set<[UInt8]> = [[0, 1, 0, 0], Array("OTTO".utf8), Array("true".utf8), Array("ttcf".utf8)]
        guard sfnt.contains([UInt8](data.prefix(4))), let provider = CGDataProvider(data: data as CFData), let cg = CGFont(provider) else { return nil }
        return CTFontCreateWithGraphicsFont(cg, 1, nil, nil)
    }

    static func substituteName(baseName: String, flags: Int) -> String {
        var name = baseName
        if name.count > 7, name[name.index(name.startIndex, offsetBy: 6)] == "+" { name = String(name.dropFirst(7)) }
        let lower = name.lowercased()
        let bold = lower.contains("bold") || lower.contains("black") || lower.contains("heavy") || flags & (1 << 18) != 0
        let italic = lower.contains("italic") || lower.contains("oblique") || flags & 64 != 0
        let exact = CTFontCreateWithName(name as CFString, 12, nil)
        if (CTFontCopyPostScriptName(exact) as String).caseInsensitiveCompare(name) == .orderedSame { return CTFontCopyPostScriptName(exact) as String }
        let compact = name.replacingOccurrences(of: ",", with: "-").replacingOccurrences(of: " ", with: "")
        let guess = CTFontCreateWithName(compact as CFString, 12, nil)
        if (CTFontCopyPostScriptName(guess) as String).caseInsensitiveCompare(compact) == .orderedSame { return CTFontCopyPostScriptName(guess) as String }
        let family: String
        if lower.contains("courier") || lower.contains("mono") || lower.contains("consolas") || flags & 1 != 0 { family = "Courier" }
        else if lower.contains("times") || (lower.contains("serif") && !lower.contains("sans")) || lower.contains("georgia") || lower.contains("palatino")
                    || lower.contains("garamond") || lower.contains("cmr") || lower.contains("minion") || lower.contains("book") || (flags & 2 != 0 && !lower.contains("sans")) { family = "Times" }
        else { family = "Helvetica" }
        return SVGInterpreter.postScriptName(families: family, weight: bold ? "bold" : "normal", italic: italic)
    }

    var substituteCTFont: CTFont {
        if let f = substituteFont { return f }
        let f = CTFontCreateWithName(substitute as CFString, 1, nil)
        substituteFont = f
        return f
    }

    // MARK: Decoding

    /// Splits a string operand into glyphs.
    func decode(_ bytes: [UInt8]) -> [Glyph] {
        var out: [Glyph] = []
        var i = 0
        let step = isType0 ? max(1, codeBytes) : 1
        while i + step <= bytes.count {
            var code = 0
            for k in 0..<step { code = (code << 8) | Int(bytes[i + k]) }
            i += step
            var unicode = toUnicode[code]
            if unicode == nil, !isType0 { unicode = code < 256 ? encoding[code] : nil }
            if unicode == nil, isType0, codeBytes == 2, code < 0x110000, embedded == nil, let s = UnicodeScalar(UInt32(code)) { unicode = String(s) }
            let width: Double
            if let w = widths[code] { width = w }
            else if isType0 { width = defaultWidth }
            else if hasWidths { width = missingWidth }
            else { width = substituteAdvance(unicode ?? " ") }
            out.append(Glyph(code: code, unicode: unicode ?? "", width: width, isSpace: step == 1 && code == 32, glyphName: !isType0 && code < 256 ? encodingNames[code] : nil))
        }
        return out
    }

    private func substituteAdvance(_ s: String) -> Double {
        let font = substituteCTFont
        let ch = Array(s.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: ch.count)
        guard CTFontGetGlyphsForCharacters(font, ch, &glyphs, ch.count) else { return 500 }
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advance, 1)
        return Double(advance.width) * 1000
    }

    /// The glyph outline in em units (1 em = 1.0), when an embedded program is usable.
    func outline(_ glyph: Glyph) -> [PathSegment]? {
        guard let font = embedded else { return nil }
        if let cached = glyphCache[glyph.code] { return cached }
        let id = glyphID(glyph, in: font)
        let path = id == 0 && glyph.isSpace ? CGMutablePath() : CTFontCreatePathForGlyph(font, id, nil)
        let segments = path?.segments ?? []
        glyphCache[glyph.code] = segments
        return segments
    }

    /// Whether the embedded program's own character map gives exactly the glyphs the PDF shows for these characters, so
    /// the text can stay text in that font (quality §6: text stays text) instead of becoming outlines.
    func mapsAsText(_ glyphs: [Glyph]) -> Bool {
        guard let font = embedded, embeddedProgram != nil else { return false }
        for glyph in glyphs {
            let units = Array(glyph.unicode.utf16)
            guard !units.isEmpty else { return false }
            if glyph.isSpace || glyph.unicode == " " { continue }
            var mapped = [CGGlyph](repeating: 0, count: units.count)
            guard units.count == 1, CTFontGetGlyphsForCharacters(font, units, &mapped, 1), mapped[0] == glyphID(glyph, in: font), mapped[0] != 0 else { return false }
        }
        return true
    }

    /// The program's glyph for a PDF glyph: CID → GID for Type 0 fonts; glyph name, Unicode, the symbolic (0xF000) range
    /// or the code itself for simple fonts. 0 when there is none.
    private func glyphID(_ glyph: Glyph, in font: CTFont) -> CGGlyph {
        var id: CGGlyph = 0
        if isType0 {
            let cid = glyph.code
            let gid = cidToGIDIdentity ? cid : (cid < (cidToGID?.count ?? 0) ? cidToGID![cid] : 0)
            id = CGGlyph(exactly: gid) ?? 0  // a 3- or 4-byte code names no glyph
        } else {
            if let name = glyph.glyphName { id = CTFontGetGlyphWithName(font, name as CFString) }
            if id == 0, let scalar = glyph.unicode.utf16.first { var u = scalar; var g: CGGlyph = 0; if CTFontGetGlyphsForCharacters(font, &u, &g, 1) { id = g } }
            if id == 0 { var u = UInt16(0xF000 + glyph.code); var g: CGGlyph = 0; if CTFontGetGlyphsForCharacters(font, &u, &g, 1) { id = g } }
            if id == 0, glyph.code < CTFontGetGlyphCount(font) { id = CGGlyph(glyph.code) }
        }
        return id
    }
}
