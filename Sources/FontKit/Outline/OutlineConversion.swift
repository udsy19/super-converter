import Foundation
import SuperConverterCore

/// Quadratic ↔ cubic outline conversion (formats §3.2): quadratic to cubic is exact; cubic to quadratic uses cu2qu within
/// a tolerance. Both reverse the winding direction, as TrueType and PostScript fonts wind outer contours oppositely.
enum OutlineConversion {
    static func cubic(_ model: FontModel) -> FontModel {
        guard model.outlineKind == .quadratic else { return model }
        var out = model
        out.outlineKind = .cubic
        out.glyphs = model.glyphs.map { glyph in
            var g = glyph
            g.contours = glyph.contours.compactMap { c in
                guard let path = Outlines.quadraticPath(c) else { return nil }
                return Outlines.cubicContour(path.reversed())
            }
            return g
        }
        return out
    }

    /// `toleranceUnits` is the largest deviation in font units. Control points are rounded to whole units afterwards (the
    /// `glyf` table stores integers), which can add up to about 0.71, so the spline fit uses what is left of the budget.
    static func quadratic(_ model: FontModel, toleranceUnits: Double) -> FontModel {
        guard model.outlineKind == .cubic else { return model }
        let fit = max(toleranceUnits - 0.72, toleranceUnits * 0.25)
        var out = model
        out.outlineKind = .quadratic
        out.glyphs = model.glyphs.map { glyph in
            var g = glyph
            g.contours = glyph.contours.compactMap { c in
                guard let path = Outlines.cubicPath(c) else { return nil }
                return Outlines.dropImpliedPoints(Outlines.quadraticContour(quadraticPath(path, fit: fit).reversed()))
            }
            return g
        }
        return out
    }

    private static func quadraticPath(_ path: OutlinePath, fit: Double) -> OutlinePath {
        var segs: [Seg] = []
        var current = path.start
        for s in path.segs {
            switch s {
            case .line, .quad:
                segs.append(s)
            case .cubic(let c1, let c2, let p):
                if let offs = Cu2Qu.approximate(current, c1, c2, p, tolerance: fit) {
                    for (i, off) in offs.enumerated() {
                        if i < offs.count - 1 {
                            let nextOff = offs[i + 1]
                            segs.append(.quad(off, Pt((off.x + nextOff.x) / 2, (off.y + nextOff.y) / 2)))
                        } else {
                            segs.append(.quad(off, p))
                        }
                    }
                } else {
                    for k in 1...16 { segs.append(.line(point(current, c1, c2, p, Double(k) / 16))) }
                }
            }
            current = s.end
        }
        return OutlinePath(start: path.start, segs: segs)
    }

    private static func point(_ p0: Pt, _ p1: Pt, _ p2: Pt, _ p3: Pt, _ t: Double) -> Pt {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return Pt(a * p0.x + b * p1.x + c * p2.x + d * p3.x, a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }
}
