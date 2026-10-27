import Foundation
import SuperConverterCore

/// Quadratic outlines → `glyf` and `loca`.
struct GlyfTables {
    var glyf: [UInt8]
    var loca: [UInt8]
    var longLoca: Bool
    var maxPoints: Int
    var maxContours: Int
    /// Rounded control-point bounds per glyph; nil for an empty glyph.
    var bounds: [(xMin: Int, yMin: Int, xMax: Int, yMax: Int)?]
}

enum GlyfBuilder {
    static func build(_ model: FontModel) throws -> GlyfTables {
        var glyf = ByteWriter()
        var offsets = [0]
        var maxPoints = 0, maxContours = 0
        var bounds: [(Int, Int, Int, Int)?] = []
        for glyph in model.glyphs {
            let contours = glyph.contours.map(prepare).filter { $0.count >= 3 }
            let all = contours.flatMap { $0 }
            if all.isEmpty {
                bounds.append(nil)
            } else {
                let xs = all.map(\.x), ys = all.map(\.y)
                let box = (xs.min()!, ys.min()!, xs.max()!, ys.max()!)
                bounds.append(box)
                maxPoints = max(maxPoints, all.count); maxContours = max(maxContours, contours.count)
                guard all.count < 0xFFFF, contours.count < 0x7FFF else { throw FontError.unsupported("glyph too complex") }
                guard box.0 >= -32768, box.2 <= 32767, box.1 >= -32768, box.3 <= 32767 else {
                    throw FontError.unsupported("coordinates out of range")
                }
                encode(contours, box: box, into: &glyf)
                glyf.align4()
            }
            offsets.append(glyf.count)
        }
        let long = (offsets.last ?? 0) > 0x1FFFE
        var loca = ByteWriter()
        for o in offsets { if long { loca.u32(o) } else { loca.u16(o / 2) } }
        return GlyfTables(glyf: glyf.bytes, loca: loca.bytes, longLoca: long, maxPoints: maxPoints, maxContours: maxContours,
                          bounds: bounds.map { $0.map { (xMin: $0.0, yMin: $0.1, xMax: $0.2, yMax: $0.3) } })
    }

    private struct IntPoint { var x: Int, y: Int, on: Bool }

    /// Rounds to whole font units.
    private static func prepare(_ contour: FontModel.Contour) -> [IntPoint] {
        contour.points.map { IntPoint(x: Int($0.x.rounded()), y: Int($0.y.rounded()), on: $0.onCurve) }
    }

    private static func encode(_ contours: [[IntPoint]], box: (Int, Int, Int, Int), into w: inout ByteWriter) {
        w.i16(contours.count); w.i16(box.0); w.i16(box.1); w.i16(box.2); w.i16(box.3)
        var end = -1
        for c in contours { end += c.count; w.u16(end) }
        w.u16(0)
        var flags: [UInt8] = [], xs = ByteWriter(), ys = ByteWriter()
        var px = 0, py = 0
        for p in contours.flatMap({ $0 }) {
            var flag = p.on ? 1 : 0
            let dx = p.x - px, dy = p.y - py
            if dx == 0 { flag |= 0x10 } else if abs(dx) <= 255 { flag |= 2 | (dx > 0 ? 0x10 : 0); xs.u8(abs(dx)) } else { xs.i16(dx) }
            if dy == 0 { flag |= 0x20 } else if abs(dy) <= 255 { flag |= 4 | (dy > 0 ? 0x20 : 0); ys.u8(abs(dy)) } else { ys.i16(dy) }
            flags.append(UInt8(flag))
            px = p.x; py = p.y
        }
        var i = 0
        while i < flags.count {
            var run = 1
            while i + run < flags.count, flags[i + run] == flags[i], run < 256 { run += 1 }
            if run > 1 { w.u8(Int(flags[i]) | 8); w.u8(run - 1) } else { w.u8(Int(flags[i])) }
            i += run
        }
        w.append(xs.bytes); w.append(ys.bytes)
    }
}
