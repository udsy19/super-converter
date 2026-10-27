import Foundation
import SuperConverterCore

/// The O-FONT options (formats §5) a font converter honours.
struct FontOptions {
    enum Subset: Equatable { case off, latin, custom(String) }

    var subset = Subset.off
    /// Largest outline deviation when cubic curves become quadratic, in thousandths of an em.
    var curveTolerance = 1.0
    var verticalMetricsFix = false

    init(_ values: OptionValues = OptionValues()) {
        switch values["subset"]?.string {
        case "latin": subset = .latin
        case "custom":
            let text = values["subsetText"]?.string ?? ""
            subset = text.isEmpty ? .off : .custom(text)
        default: subset = .off
        }
        if let t = values["curveTolerance"]?.double, t > 0 { curveTolerance = t }
        verticalMetricsFix = values["verticalMetricsFix"]?.bool ?? false
    }

    var writerOptions: SFNTWriter.Options { SFNTWriter.Options(verticalMetricsFix: verticalMetricsFix) }

    /// Tolerance for `OutlineConversion.quadratic` in font units.
    func toleranceUnits(for model: FontModel) -> Double { Double(model.unitsPerEm) * curveTolerance / 1000 }

    func apply(to model: FontModel) -> (FontModel, [LossNote]) {
        switch subset {
        case .off: return (model, [])
        case .latin: return Subsetter.subset(model, keeping: Subsetter.latin)
        case .custom(let text): return Subsetter.subset(model, keeping: Set(text.unicodeScalars.map(\.value)))
        }
    }
}

/// Keeps the glyphs for some characters (plus `.notdef`), renumbering the rest. Tables that refer to glyphs by number and
/// cannot be renumbered here (OpenType layout, kerning) are dropped.
enum Subsetter {
    static let latin: Set<UInt32> = {
        var s = Set<UInt32>(0x20...0x7E)
        s.formUnion(0xA0...0xFF)
        s.formUnion([0x152, 0x153, 0x160, 0x161, 0x178, 0x17D, 0x17E, 0x192, 0x2C6, 0x2DC, 0x2013, 0x2014, 0x2018, 0x2019, 0x201A,
                     0x201C, 0x201D, 0x201E, 0x2020, 0x2021, 0x2022, 0x2026, 0x2030, 0x2039, 0x203A, 0x20AC, 0x2122])
        return s
    }()

    static let glyphIndexedTables: Set<String> = ["GSUB", "GPOS", "GDEF", "kern", "morx", "mort", "kerx", "feat", "trak", "ankr", "JSTF",
                                                  "BASE", "MATH", "lcar", "prop", "opbd", "bsln", "just", "fmtx", "COLR", "CPAL",
                                                  "EBDT", "EBLC", "EBSC", "sbix", "CBDT", "CBLC", "SVG ", "Zapf", "meta"]

    static func subset(_ model: FontModel, keeping characters: Set<UInt32>) -> (FontModel, [LossNote]) {
        var order = [0]
        var newIndex = [0: 0]
        for (code, g) in model.characterMap.sorted(by: { $0.key < $1.key }) where characters.contains(code) && g > 0 && g < model.glyphs.count {
            if newIndex[g] == nil { newIndex[g] = order.count; order.append(g) }
        }
        var out = model
        out.glyphs = order.map { model.glyphs[$0] }
        out.characterMap = [:]
        for (code, g) in model.characterMap where characters.contains(code) { if let n = newIndex[g] { out.characterMap[code] = n } }
        var dropped = false
        for tag in glyphIndexedTables where out.tables[tag] != nil { out.tables[tag] = nil; dropped = true }
        let notes = dropped ? [LossNote(.otherLoss, detail: "Kerning and other layout features were dropped by subsetting")] : []
        return (out, notes)
    }
}
