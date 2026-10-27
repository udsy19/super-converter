import Foundation
import SuperConverterCore

/// `FontModel` → OpenType/TrueType tables. The outline table follows the model's `outlineKind` (quadratic → `glyf`/`loca`,
/// cubic → `CFF `); `head`, `hhea`, `hmtx`, `maxp`, `cmap` and `post` are rebuilt from the model, `name` and `OS/2` are
/// carried (or created when the source had none) with their derived fields refreshed, and the other carried tables are
/// written as they were.
enum SFNTWriter {
    struct Options {
        /// Make `hhea` and `OS/2` typographic and Windows metrics agree with the glyph bounds.
        var verticalMetricsFix = false
    }

    struct Built {
        var flavor: Int
        var tables: [(String, [UInt8])]
    }

    static func serialize(_ model: FontModel, options: Options = Options()) throws -> [UInt8] {
        let built = try build(model, options: options)
        return SFNTContainer.serialize(flavor: built.flavor, tables: built.tables)
    }

    static func build(_ model: FontModel, options: Options = Options()) throws -> Built {
        guard !model.glyphs.isEmpty, model.glyphs.count <= 0xFFFF else { throw FontError.unsupported("glyph count") }
        let count = model.glyphs.count
        var out: [String: [UInt8]] = [:]
        for (tag, data) in model.tables where !SFNTReader.structural.contains(tag) && !SFNTReader.dropped.contains(tag) { out[tag] = Array(data) }

        var bounds: [(xMin: Int, yMin: Int, xMax: Int, yMax: Int)?]
        var maxPoints = 0, maxContours = 0
        var longLoca = false
        let isCFF = model.outlineKind == .cubic
        if isCFF {
            out["CFF "] = try CFFBuilder.build(model, postScriptName: postScriptName(model))
            bounds = model.glyphs.map { g in
                model.bounds(of: g).map { (Int($0.minX.rounded(.down)), Int($0.minY.rounded(.down)), Int($0.maxX.rounded(.up)), Int($0.maxY.rounded(.up))) }
            }
        } else {
            let t = try GlyfBuilder.build(model)
            out["glyf"] = t.glyf; out["loca"] = t.loca
            bounds = t.bounds; maxPoints = t.maxPoints; maxContours = t.maxContours; longLoca = t.longLoca
        }

        let advances = model.glyphs.map { max(0, min(0xFFFF, $0.advance)) }
        let lsbs = bounds.map { $0?.xMin ?? 0 }
        var metricCount = count
        while metricCount > 1, advances[metricCount - 1] == advances[metricCount - 2] { metricCount -= 1 }
        var hmtx = ByteWriter()
        for g in 0..<count {
            if g < metricCount { hmtx.u16(advances[g]) }
            hmtx.i16(lsbs[g])
        }
        out["hmtx"] = hmtx.bytes

        var xMin = Int.max, yMin = Int.max, xMax = Int.min, yMax = Int.min
        var minRSB = Int.max, extent = Int.min
        for g in 0..<count {
            guard let b = bounds[g] else { continue }
            xMin = min(xMin, b.xMin); yMin = min(yMin, b.yMin); xMax = max(xMax, b.xMax); yMax = max(yMax, b.yMax)
            minRSB = min(minRSB, advances[g] - b.xMax); extent = max(extent, b.xMax)
        }
        if xMin == Int.max { xMin = 0; yMin = 0; xMax = 0; yMax = 0; minRSB = 0; extent = 0 }
        let minLSB = bounds.compactMap { $0?.xMin }.min() ?? 0

        var head = ByteWriter()
        if let template = out["head"], template.count >= 54 { head.append(Array(template.prefix(54))) }
        else {
            let now = Int(Date().timeIntervalSince1970) + 2_082_844_800
            head.u32(0x0001_0000); head.u32(0x0001_0000); head.u32(0); head.u32(0x5F0F_3CF5); head.u16(0)
            head.u16(model.unitsPerEm); head.i64(now); head.i64(now)
            head.u16(0); head.u16(0); head.u16(0); head.u16(0); head.u16(0); head.u16(8); head.u16(2); head.u16(0); head.u16(0)
        }
        head.patch16(16, (try head.bytes.be16(16)) | 3)
        head.patch16(18, model.unitsPerEm)
        head.patch16(36, xMin & 0xFFFF); head.patch16(38, yMin & 0xFFFF); head.patch16(40, xMax & 0xFFFF); head.patch16(42, yMax & 0xFFFF)
        head.patch16(50, longLoca ? 1 : 0)
        head.patch16(52, 0)
        out["head"] = head.bytes

        var hhea = ByteWriter()
        if let template = out["hhea"], template.count >= 36 { hhea.append(Array(template.prefix(36))) }
        else { hhea.u32(0x0001_0000); for _ in 0..<8 { hhea.u32(0) }; hhea.patch16(18, 1) }
        var ascent = model.ascent, descent = model.descent
        var lineGap = (try? hhea.bytes.beS16(8)) ?? 0
        if options.verticalMetricsFix { lineGap = 0 }
        if ascent == 0 && descent == 0 { ascent = yMax; descent = yMin }
        hhea.patch16(4, ascent & 0xFFFF); hhea.patch16(6, descent & 0xFFFF); hhea.patch16(8, lineGap & 0xFFFF)
        hhea.patch16(10, advances.max() ?? 0)
        hhea.patch16(12, minLSB & 0xFFFF); hhea.patch16(14, (minRSB == Int.max ? 0 : minRSB) & 0xFFFF); hhea.patch16(16, extent & 0xFFFF)
        hhea.patch16(32, 0); hhea.patch16(34, metricCount)
        out["hhea"] = hhea.bytes

        var maxp = ByteWriter()
        if isCFF { maxp.u32(0x0000_5000); maxp.u16(count) }
        else {
            maxp.u32(0x0001_0000); maxp.u16(count); maxp.u16(maxPoints); maxp.u16(maxContours); maxp.u16(0); maxp.u16(0)
            maxp.u16(1); for _ in 0..<8 { maxp.u16(0) }
        }
        out["maxp"] = maxp.bytes

        var map: [UInt32: Int] = [:]
        for (code, g) in model.characterMap where g > 0 && g < count && code <= 0x10FFFF { map[code] = g }
        out["cmap"] = CmapTable.build(map)

        var names = out["name"].map(NameTable.strings) ?? [:]
        if names[1] == nil { names[1] = model.familyName }
        if names[2] == nil { names[2] = model.styleName }
        if names[4] == nil { names[4] = model.styleName == "Regular" ? model.familyName : "\(model.familyName) \(model.styleName)" }
        if names[6] == nil { names[6] = postScriptName(model) }
        if names[5] == nil { names[5] = "Version 1.000" }
        if names[3] == nil { names[3] = "\(names[5]!);\(names[6]!)" }
        if out["name"] == nil { out["name"] = NameTable.build(names) }

        let fixedPitch = Set(model.glyphs.dropFirst().filter { !$0.contours.isEmpty }.map(\.advance)).count == 1
        out["post"] = PostTable.build(names: model.glyphs.map(\.name), header: out["post"], withNames: !isCFF, isFixedPitch: fixedPitch)

        out["OS/2"] = os2(model, existing: out["OS/2"], bounds: (yMin, yMax), advances: advances, map: map, fix: options.verticalMetricsFix,
                          ascent: ascent, descent: descent)

        return Built(flavor: isCFF ? SFNTTables.cffFlavor : SFNTTables.trueTypeFlavor, tables: out.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 })
    }

    static func postScriptName(_ model: FontModel) -> String {
        if let table = model.tables["name"], let ps = NameTable.strings(Array(table))[6], !ps.isEmpty { return ps }
        let raw = model.familyName + (model.styleName == "Regular" ? "" : "-" + model.styleName)
        let cleaned = raw.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-") }
        let name = String(String.UnicodeScalarView(cleaned))
        return name.isEmpty ? "Untitled" : String(name.prefix(63))
    }

    private static func os2(_ model: FontModel, existing: [UInt8]?, bounds: (Int, Int), advances: [Int], map: [UInt32: Int],
                           fix: Bool, ascent: Int, descent: Int) -> [UInt8] {
        let nonZero = advances.filter { $0 > 0 }
        let average = nonZero.isEmpty ? 0 : nonZero.reduce(0, +) / nonZero.count
        let bmp = map.keys.filter { $0 <= 0xFFFF }
        let first = bmp.min().map(Int.init) ?? 0, last = bmp.max().map(Int.init) ?? 0
        var w = ByteWriter()
        if let existing, existing.count >= 68 {
            w.append(existing)
        } else {
            let style = model.styleName.lowercased()
            let bold = style.contains("bold") || style.contains("black") || style.contains("heavy")
            let italic = style.contains("italic") || style.contains("oblique")
            let em = model.unitsPerEm
            w.u16(4); w.i16(average); w.u16(bold ? 700 : 400); w.u16(5); w.u16(0)
            w.i16(em * 65 / 100); w.i16(em * 70 / 100); w.i16(0); w.i16(em * 14 / 100)
            w.i16(em * 65 / 100); w.i16(em * 70 / 100); w.i16(0); w.i16(em * 48 / 100)
            w.i16(em * 5 / 100); w.i16(em * 26 / 100)
            w.i16(0); for _ in 0..<10 { w.u8(0) }
            let latin = map[0x20] != nil || map[0x41] != nil
            w.u32(latin ? 1 | (map.keys.contains { $0 >= 0xA0 && $0 <= 0xFF } ? 2 : 0) : 0); w.u32(0); w.u32(0); w.u32(0)
            w.append(Array("NONE".utf8))
            w.u16((italic ? 1 : 0) | (bold ? 0x20 : 0) | (!bold && !italic ? 0x40 : 0) | 0x80)
            w.u16(min(first, 0xFFFF)); w.u16(min(last, 0xFFFF))
            w.i16(ascent); w.i16(descent); w.i16(0)
            w.u16(max(bounds.1, ascent)); w.u16(abs(min(bounds.0, descent)))
            w.u32(latin ? 1 : 0); w.u32(0)
            w.i16(map[0x78] != nil ? em / 2 : 0); w.i16(map[0x48] != nil ? em * 7 / 10 : 0)
            w.u16(0); w.u16(32); w.u16(1)
            return w.bytes
        }
        w.patch16(2, average); w.patch16(64, min(first, 0xFFFF)); w.patch16(66, min(last, 0xFFFF))
        if fix, w.count >= 78 {
            w.patch16(68, ascent & 0xFFFF); w.patch16(70, descent & 0xFFFF); w.patch16(72, 0)
            w.patch16(74, max(bounds.1, ascent)); w.patch16(76, abs(min(bounds.0, descent)))
            w.patch16(62, ((try? w.bytes.be16(62)) ?? 0) | 0x80)
        }
        return w.bytes
    }
}
