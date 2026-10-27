import Foundation
import SuperConverterCore

/// OpenType/TrueType tables → `FontModel`. Outlines, advances, the Unicode cmap, names and glyph names become the
/// model; everything else that does not depend on the outline format travels in `FontModel.tables`.
enum SFNTReader {
    /// Tables the model replaces, and the writers rebuild.
    static let structural: Set<String> = ["cmap", "glyf", "loca", "hmtx", "maxp", "CFF ", "CFF2"]
    /// Tables that cannot survive an outline change or describe a variable font's other instances.
    static let dropped: Set<String> = ["fpgm", "prep", "cvt ", "hdmx", "LTSH", "VDMX", "DSIG", "fvar", "gvar", "cvar", "avar",
                                       "HVAR", "MVAR", "VVAR", "STAT", "vmtx", "vhea", "VORG"]

    static func read(_ bytes: [UInt8]) throws -> (FontModel, [LossNote]) {
        try read(tables: SFNTContainer.parse(bytes).tables)
    }

    static func read(tables: [String: [UInt8]]) throws -> (FontModel, [LossNote]) {
        guard let head = tables["head"], let hhea = tables["hhea"], let maxp = tables["maxp"] else {
            throw FontError.damaged("missing head, hhea or maxp")
        }
        let unitsPerEm = try head.be16(18)
        guard (16...16384).contains(unitsPerEm) else { throw FontError.damaged("unitsPerEm") }
        let glyphCount = try maxp.be16(4)
        guard glyphCount > 0 else { throw FontError.damaged("no glyphs") }
        let ascent = try hhea.beS16(4), descent = try hhea.beS16(6)
        let metricCount = max(1, min(try hhea.be16(34), glyphCount))

        var advances = [Int](repeating: 0, count: glyphCount), bearings = advances
        if let hmtx = tables["hmtx"] {
            for g in 0..<glyphCount {
                if g < metricCount {
                    advances[g] = try hmtx.be16(g * 4); bearings[g] = try hmtx.beS16(g * 4 + 2)
                } else {
                    advances[g] = advances[metricCount - 1]
                    bearings[g] = (try? hmtx.beS16(metricCount * 4 + (g - metricCount) * 2)) ?? 0
                }
            }
        }

        var contours: [[FontModel.Contour]]
        var cffNames: [String?] = []
        var kind = FontModel.OutlineKind.quadratic
        var notes: [LossNote] = []
        var hinted = tables["fpgm"] != nil || tables["prep"] != nil
        if let cff = tables["CFF "] ?? tables["CFF2"] {
            let parsed = try CFFReader.read(cff, isV2: tables["CFF "] == nil)
            guard parsed.contours.count == glyphCount else { throw FontError.damaged("CFF glyph count") }
            contours = parsed.contours; cffNames = parsed.names; kind = .cubic
        } else if let glyf = tables["glyf"], let loca = tables["loca"] {
            var reader = try GlyfReader(glyf: glyf, loca: loca, longOffsets: try head.beS16(50) != 0, glyphCount: glyphCount)
            contours = []
            contours.reserveCapacity(glyphCount)
            for g in 0..<glyphCount {
                var c = try reader.contours(of: g)
                if let xMin = reader.headerXMin(of: g), bearings[g] != xMin, !c.isEmpty {
                    let shift = Double(bearings[g] - xMin)
                    c = c.map { FontModel.Contour(points: $0.points.map { .init($0.x + shift, $0.y, onCurve: $0.onCurve) }) }
                }
                contours.append(c)
            }
            hinted = hinted || reader.hasInstructions
        } else {
            throw FontError.unsupported("This font has no outlines (bitmap-only fonts can’t be converted).")
        }

        let characterMap = try tables["cmap"].map(CmapTable.parse) ?? [:]
        let postNames = tables["post"].map { PostTable.glyphNames($0, glyphCount: glyphCount) } ?? []
        var reverse: [Int: UInt32] = [:]
        for (code, g) in characterMap where g < glyphCount { if let old = reverse[g], old < code { continue }; reverse[g] = code }
        var glyphs: [FontModel.Glyph] = []
        glyphs.reserveCapacity(glyphCount)
        for g in 0..<glyphCount {
            var name = g < postNames.count ? postNames[g] : nil
            if name == nil, g < cffNames.count { name = cffNames[g] }
            if name == nil || name!.isEmpty {
                if g == 0 { name = ".notdef" }
                else if let code = reverse[g] { name = String(format: code > 0xFFFF ? "u%X" : "uni%04X", code) }
                else { name = "glyph\(g)" }
            }
            glyphs.append(FontModel.Glyph(name: name!, advance: advances[g], contours: contours[g]))
        }

        let names = tables["name"].map(NameTable.strings) ?? [:]
        var kept: [String: Data] = [:]
        for (tag, data) in tables where !structural.contains(tag) && !dropped.contains(tag) { kept[tag] = Data(data) }

        if hinted { notes.append(LossNote(.otherLoss, detail: "TrueType hinting instructions were dropped")) }
        if tables["fvar"] != nil { notes.append(LossNote(.otherLoss, detail: "Only the default style of the variable font was kept")) }
        let model = FontModel(familyName: names[16] ?? names[1] ?? "Untitled", styleName: names[17] ?? names[2] ?? "Regular",
                              unitsPerEm: unitsPerEm, ascent: ascent, descent: descent, outlineKind: kind, glyphs: glyphs,
                              characterMap: characterMap, tables: kept)
        return (model, notes)
    }
}
