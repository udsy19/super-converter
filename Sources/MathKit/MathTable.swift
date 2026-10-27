import Foundation

/// The OpenType MATH table (OpenType 1.9, "MATH — The Mathematical Typesetting Table"): the font's math constants,
/// per-glyph italic corrections and top-accent attachments, and the size variants and assemblies that let
/// delimiters, radicals, big operators and wide accents grow. Values are in font units.
struct MathTable {
    let constants: [MathConstant: Int]
    let italicsCorrection: [UInt16: Int]
    let topAccentAttachment: [UInt16: Int]
    let minConnectorOverlap: Int
    let verticalConstructions: [UInt16: Construction]
    let horizontalConstructions: [UInt16: Construction]

    struct Variant { let glyph: UInt16; let advance: Int }
    struct Part { let glyph: UInt16; let startConnector: Int; let endConnector: Int; let fullAdvance: Int; let isExtender: Bool }
    struct Construction { let variants: [Variant]; let assembly: [Part]?; let assemblyItalic: Int }

    init?(data: Data) {
        let r = Reader(data)
        guard data.count > 10, r.u16(0) == 1 else { return nil }
        let constantsOffset = Int(r.u16(4)), glyphInfoOffset = Int(r.u16(6)), variantsOffset = Int(r.u16(8))
        guard constantsOffset > 0, variantsOffset > 0 else { return nil }

        var constants: [MathConstant: Int] = [:]
        for c in MathConstant.allCases {
            let at = constantsOffset + c.offset
            constants[c] = c.isSigned ? Int(r.s16(at)) : Int(r.u16(at))
        }
        self.constants = constants

        var italics: [UInt16: Int] = [:], accents: [UInt16: Int] = [:]
        if glyphInfoOffset > 0 {
            let g = glyphInfoOffset
            let italicsOffset = Int(r.u16(g)), accentOffset = Int(r.u16(g + 2))
            // MathItalicsCorrectionInfo and MathTopAccentAttachment: a coverage table and one MathValueRecord per glyph.
            func valueTable(_ base: Int) -> [UInt16: Int] {
                let coverage = r.coverage(base + Int(r.u16(base)))
                let count = Int(r.u16(base + 2))
                var out: [UInt16: Int] = [:]
                for (i, glyph) in coverage.enumerated() where i < count { out[glyph] = Int(r.s16(base + 4 + 4 * i)) }
                return out
            }
            if italicsOffset > 0 { italics = valueTable(g + italicsOffset) }
            if accentOffset > 0 { accents = valueTable(g + accentOffset) }
        }
        italicsCorrection = italics; topAccentAttachment = accents

        let v = variantsOffset
        minConnectorOverlap = Int(r.u16(v))
        let vertCoverage = Int(r.u16(v + 2)) > 0 ? r.coverage(v + Int(r.u16(v + 2))) : []
        let horizCoverage = Int(r.u16(v + 4)) > 0 ? r.coverage(v + Int(r.u16(v + 4))) : []
        let vertCount = Int(r.u16(v + 6))
        func construction(_ at: Int) -> Construction {
            let assemblyOffset = Int(r.u16(at))
            let variants = (0..<Int(r.u16(at + 2))).map { i in
                Variant(glyph: r.u16(at + 4 + 4 * i), advance: Int(r.u16(at + 6 + 4 * i)))
            }
            var parts: [Part]? = nil
            var italic = 0
            if assemblyOffset > 0 {
                let a = at + assemblyOffset
                italic = Int(r.s16(a))
                parts = (0..<Int(r.u16(a + 4))).map { i in
                    let p = a + 6 + 10 * i
                    return Part(glyph: r.u16(p), startConnector: Int(r.u16(p + 2)), endConnector: Int(r.u16(p + 4)),
                                fullAdvance: Int(r.u16(p + 6)), isExtender: r.u16(p + 8) & 1 == 1)
                }
            }
            return Construction(variants: variants, assembly: parts, assemblyItalic: italic)
        }
        var vert: [UInt16: Construction] = [:], horiz: [UInt16: Construction] = [:]
        for (i, glyph) in vertCoverage.enumerated() where i < vertCount {
            vert[glyph] = construction(v + Int(r.u16(v + 10 + 2 * i)))
        }
        for (i, glyph) in horizCoverage.enumerated() where i < Int(r.u16(v + 8)) {
            horiz[glyph] = construction(v + Int(r.u16(v + 10 + 2 * vertCount + 2 * i)))
        }
        verticalConstructions = vert; horizontalConstructions = horiz
    }

    subscript(_ c: MathConstant) -> Int { constants[c] ?? 0 }

    /// Big-endian reads with bounds checks (a damaged table reads as zeros rather than crashing).
    struct Reader {
        let bytes: [UInt8]
        init(_ data: Data) { bytes = [UInt8](data) }
        func u16(_ at: Int) -> UInt16 {
            guard at >= 0, at + 1 < bytes.count else { return 0 }
            return UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
        }
        func s16(_ at: Int) -> Int16 { Int16(bitPattern: u16(at)) }
        /// The glyphs of a Coverage table, in coverage-index order.
        func coverage(_ at: Int) -> [UInt16] {
            switch u16(at) {
            case 1:
                return (0..<Int(u16(at + 2))).map { u16(at + 4 + 2 * $0) }
            case 2:
                var out: [UInt16] = []
                for i in 0..<Int(u16(at + 2)) {
                    let rec = at + 4 + 6 * i
                    let start = u16(rec), end = u16(rec + 2)
                    if end >= start { out.append(contentsOf: start...end) }
                }
                return out
            default:
                return []
            }
        }
    }
}

/// The MathConstants fields in table order: four plain 16-bit values, 51 MathValueRecords, one int16.
enum MathConstant: CaseIterable {
    case scriptPercentScaleDown, scriptScriptPercentScaleDown, delimitedSubFormulaMinHeight, displayOperatorMinHeight
    case mathLeading, axisHeight, accentBaseHeight, flattenedAccentBaseHeight, subscriptShiftDown, subscriptTopMax
    case subscriptBaselineDropMin, superscriptShiftUp, superscriptShiftUpCramped, superscriptBottomMin
    case superscriptBaselineDropMax, subSuperscriptGapMin, superscriptBottomMaxWithSubscript, spaceAfterScript
    case upperLimitGapMin, upperLimitBaselineRiseMin, lowerLimitGapMin, lowerLimitBaselineDropMin, stackTopShiftUp
    case stackTopDisplayStyleShiftUp, stackBottomShiftDown, stackBottomDisplayStyleShiftDown, stackGapMin
    case stackDisplayStyleGapMin, stretchStackTopShiftUp, stretchStackBottomShiftDown, stretchStackGapAboveMin
    case stretchStackGapBelowMin, fractionNumeratorShiftUp, fractionNumeratorDisplayStyleShiftUp
    case fractionDenominatorShiftDown, fractionDenominatorDisplayStyleShiftDown, fractionNumeratorGapMin
    case fractionNumDisplayStyleGapMin, fractionRuleThickness, fractionDenominatorGapMin, fractionDenomDisplayStyleGapMin
    case skewedFractionHorizontalGap, skewedFractionVerticalGap, overbarVerticalGap, overbarRuleThickness
    case overbarExtraAscender, underbarVerticalGap, underbarRuleThickness, underbarExtraDescender, radicalVerticalGap
    case radicalDisplayStyleVerticalGap, radicalRuleThickness, radicalExtraAscender, radicalKernBeforeDegree
    case radicalKernAfterDegree, radicalDegreeBottomRaisePercent

    private var index: Int { MathConstant.allCases.firstIndex(of: self)! }
    var offset: Int {
        let i = index
        if i < 4 { return 2 * i }
        if self == .radicalDegreeBottomRaisePercent { return 8 + 4 * 51 }
        return 8 + 4 * (i - 4)
    }
    /// Everything but the two UFWORD heights is signed.
    var isSigned: Bool { self != .delimitedSubFormulaMinHeight && self != .displayOperatorMinHeight }
}
