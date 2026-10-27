import CoreGraphics
import CoreText
import Foundation

/// An OpenType math font (Latin Modern Math; STIX Two Math as the fallback for symbols it lacks): glyph lookup with the
/// `ssty` script-size variants (read from the font's GSUB table, since Core Text does not apply the feature), glyph
/// metrics, and the MATH table scaled to a size.
public final class MathFont: @unchecked Sendable {
    let table: MathTable
    /// `ssty` substitutions: index 0 for script style, 1 for scriptscript style.
    private let scriptVariants: [[UInt16: UInt16]]
    let unitsPerEm: Double
    private let descriptor: CTFontDescriptor
    private let lock = NSLock()
    private var fonts: [Double: CTFont] = [:]
    private var glyphCache: [UInt32: CGGlyph] = [:]


    public init(url: URL) throws {
        guard let list = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let d = list.first else {
            throw MathError.fontUnreadable(url.lastPathComponent)
        }
        let probe = CTFontCreateWithFontDescriptor(d, 10, nil)
        guard let data = CTFontCopyTable(probe, CTFontTableTag(0x4D41_5448), []) as Data?, let table = MathTable(data: data) else {
            throw MathError.noMathTable(url.lastPathComponent)
        }
        descriptor = d
        self.table = table
        unitsPerEm = Double(CTFontGetUnitsPerEm(probe))
        scriptVariants = (CTFontCopyTable(probe, CTFontTableTag(0x4753_5542), []) as Data?).map(Self.sstyVariants) ?? [[:], [:]]
    }

    /// The `ssty` feature's lookups in a GSUB table: single substitutions apply to both levels; alternate substitutions
    /// give the script form first and the scriptscript form second.
    static func sstyVariants(_ data: Data) -> [[UInt16: UInt16]] {
        let r = MathTable.Reader(data)
        var script: [UInt16: UInt16] = [:], scriptScript: [UInt16: UInt16] = [:]
        let featureList = Int(r.u16(6)), lookupList = Int(r.u16(8))
        var lookups: [Int] = []
        for i in 0..<Int(r.u16(featureList)) {
            let rec = featureList + 2 + 6 * i
            guard r.bytes.count > rec + 4, String(bytes: r.bytes[rec..<rec + 4], encoding: .ascii) == "ssty" else { continue }
            let feature = featureList + Int(r.u16(rec + 4))
            for k in 0..<Int(r.u16(feature + 2)) { lookups.append(Int(r.u16(feature + 4 + 2 * k))) }
        }
        for index in lookups {
            let lookup = lookupList + Int(r.u16(lookupList + 2 + 2 * index))
            var type = Int(r.u16(lookup))
            for k in 0..<Int(r.u16(lookup + 4)) {
                var sub = lookup + Int(r.u16(lookup + 6 + 2 * k))
                if type == 7 {   // extension
                    type = Int(r.u16(sub + 2))
                    sub += Int(r.u16(sub + 4)) << 16 | Int(r.u16(sub + 6))
                }
                let coverage = r.coverage(sub + Int(r.u16(sub + 2)))
                switch (type, Int(r.u16(sub))) {
                case (1, 1):
                    let delta = Int(r.s16(sub + 4))
                    for g in coverage {
                        let v = UInt16(truncatingIfNeeded: Int(g) + delta)
                        script[g] = v; scriptScript[g] = v
                    }
                case (1, 2):
                    for (i, g) in coverage.enumerated() { let v = r.u16(sub + 6 + 2 * i); script[g] = v; scriptScript[g] = v }
                case (3, 1):
                    for (i, g) in coverage.enumerated() {
                        let set = sub + Int(r.u16(sub + 6 + 2 * i))
                        let count = Int(r.u16(set))
                        guard count > 0 else { continue }
                        script[g] = r.u16(set + 2)
                        scriptScript[g] = r.u16(set + 2 + 2 * min(1, count - 1))
                    }
                default:
                    break
                }
            }
        }
        return [script, scriptScript]
    }

    /// The font at `size`.
    func font(size: Double) -> CTFont {
        lock.lock(); defer { lock.unlock() }
        if let f = fonts[size] { return f }
        let f = CTFontCreateWithFontDescriptor(descriptor, CGFloat(size), nil)
        fonts[size] = f
        return f
    }

    /// The glyph for a character (after `ssty` substitution), or nil when the font lacks it.
    func glyph(for scalar: Unicode.Scalar, ssty: Int) -> CGGlyph? {
        let key = scalar.value
        lock.lock()
        var base = glyphCache[key]
        lock.unlock()
        if base == nil {
            let utf16 = Array(String(Character(scalar)).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
            base = CTFontGetGlyphsForCharacters(font(size: 10), utf16, &glyphs, utf16.count) ? glyphs[0] : 0
            lock.lock(); glyphCache[key] = base; lock.unlock()
        }
        guard let g = base, g != 0 else { return nil }
        return ssty > 0 ? scriptVariants[min(ssty, 2) - 1][g] ?? g : g
    }

    /// Scale from font units to points at `size`.
    func scale(_ size: Double) -> Double { size / unitsPerEm }

    func constant(_ c: MathConstant, size: Double) -> Double { Double(table[c]) * scale(size) }

    struct GlyphMetrics { var width: Double; var height: Double; var depth: Double; var italic: Double }

    func metrics(_ glyph: CGGlyph, size: Double) -> GlyphMetrics {
        let f = font(size: size)
        var g = glyph
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(f, .horizontal, &g, &rect, 1)
        let advance = CTFontGetAdvancesForGlyphs(f, .horizontal, &g, nil, 1)
        let italic = Double(table.italicsCorrection[glyph] ?? 0) * scale(size)
        return GlyphMetrics(width: advance, height: max(0, Double(rect.maxY)), depth: max(0, -Double(rect.minY)), italic: italic)
    }

    func topAccent(_ glyph: CGGlyph, size: Double) -> Double? {
        table.topAccentAttachment[glyph].map { Double($0) * scale(size) }
    }
}

public enum MathError: Error, CustomStringConvertible {
    case fontUnreadable(String)
    case noMathTable(String)
    public var description: String {
        switch self {
        case .fontUnreadable(let f): "The math font \(f) couldn’t be read"
        case .noMathTable(let f): "The font \(f) has no MATH table"
        }
    }
}
