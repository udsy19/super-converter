import Foundation
import SuperConverterCore

/// Reads `glyf`/`loca` into quadratic contours; composite glyphs are flattened with their transforms applied.
struct GlyfReader {
    typealias Point = FontModel.Contour.Point

    let glyf: [UInt8]
    let offsets: [Int]
    private(set) var hasInstructions = false
    private var cache: [Int: [[Point]]] = [:]

    init(glyf: [UInt8], loca: [UInt8], longOffsets: Bool, glyphCount: Int) throws {
        self.glyf = glyf
        var offsets: [Int] = []
        offsets.reserveCapacity(glyphCount + 1)
        for i in 0...glyphCount {
            offsets.append(longOffsets ? try loca.be32(i * 4) : try loca.be16(i * 2) * 2)
        }
        self.offsets = offsets
    }

    mutating func contours(of gid: Int) throws -> [FontModel.Contour] {
        try resolve(gid, depth: 0).map { FontModel.Contour(points: $0) }
    }

    /// The glyph's own `xMin` from its header (nil for an empty glyph).
    func headerXMin(of gid: Int) -> Int? {
        guard gid + 1 < offsets.count, offsets[gid + 1] > offsets[gid], offsets[gid] + 4 <= glyf.count else { return nil }
        return try? glyf.beS16(offsets[gid] + 2)
    }

    private mutating func resolve(_ gid: Int, depth: Int) throws -> [[Point]] {
        if let hit = cache[gid] { return hit }
        guard gid >= 0, gid + 1 < offsets.count else { return [] }
        let start = offsets[gid], end = min(offsets[gid + 1], glyf.count)
        guard end > start + 10 else { return [] }
        let glyph = try glyf.slice(start, end - start)
        let count = try glyph.beS16(0)
        var result: [[Point]]
        if count >= 0 {
            result = try simple(glyph, contours: count)
        } else {
            guard depth < 8 else { throw FontError.damaged("composite depth") }
            result = try composite(glyph, depth: depth)
        }
        cache[gid] = result
        return result
    }

    private mutating func simple(_ g: [UInt8], contours n: Int) throws -> [[Point]] {
        guard n > 0 else { return [] }
        var ends: [Int] = []
        for i in 0..<n { ends.append(try g.be16(10 + i * 2)) }
        let pointCount = (ends.last ?? -1) + 1
        guard pointCount > 0, pointCount <= 0xFFFF else { return [] }
        let instructionLength = try g.be16(10 + n * 2)
        if instructionLength > 0 { hasInstructions = true }
        var o = 12 + n * 2 + instructionLength
        var flags: [Int] = []
        flags.reserveCapacity(pointCount)
        while flags.count < pointCount {
            let f = try g.be8(o); o += 1
            flags.append(f)
            if f & 8 != 0 {
                let repeats = try g.be8(o); o += 1
                for _ in 0..<repeats where flags.count < pointCount { flags.append(f) }
            }
        }
        var xs = [Int](repeating: 0, count: pointCount), ys = xs
        var v = 0
        for i in 0..<pointCount {
            let f = flags[i]
            if f & 2 != 0 { let d = try g.be8(o); o += 1; v += f & 0x10 != 0 ? d : -d }
            else if f & 0x10 == 0 { v += try g.beS16(o); o += 2 }
            xs[i] = v
        }
        v = 0
        for i in 0..<pointCount {
            let f = flags[i]
            if f & 4 != 0 { let d = try g.be8(o); o += 1; v += f & 0x20 != 0 ? d : -d }
            else if f & 0x20 == 0 { v += try g.beS16(o); o += 2 }
            ys[i] = v
        }
        var contours: [[Point]] = []
        var first = 0
        for end in ends {
            guard end >= first, end < pointCount else { throw FontError.damaged("contour ends") }
            contours.append((first...end).map { Point(Double(xs[$0]), Double(ys[$0]), onCurve: flags[$0] & 1 != 0) })
            first = end + 1
        }
        return contours
    }

    private mutating func composite(_ g: [UInt8], depth: Int) throws -> [[Point]] {
        var result: [[Point]] = []
        var o = 10
        while true {
            let flags = try g.be16(o), component = try g.be16(o + 2)
            o += 4
            var arg1 = 0, arg2 = 0
            if flags & 1 != 0 {
                arg1 = flags & 2 != 0 ? try g.beS16(o) : try g.be16(o)
                arg2 = flags & 2 != 0 ? try g.beS16(o + 2) : try g.be16(o + 2)
                o += 4
            } else {
                let a = try g.be8(o), b = try g.be8(o + 1)
                arg1 = flags & 2 != 0 ? (a >= 128 ? a - 256 : a) : a
                arg2 = flags & 2 != 0 ? (b >= 128 ? b - 256 : b) : b
                o += 2
            }
            var xx = 1.0, xy = 0.0, yx = 0.0, yy = 1.0
            func f2dot14(_ at: Int) throws -> Double { Double(try g.beS16(at)) / 16384 }
            if flags & 8 != 0 { xx = try f2dot14(o); yy = xx; o += 2 }
            else if flags & 0x40 != 0 { xx = try f2dot14(o); yy = try f2dot14(o + 2); o += 4 }
            else if flags & 0x80 != 0 { xx = try f2dot14(o); xy = try f2dot14(o + 2); yx = try f2dot14(o + 4); yy = try f2dot14(o + 6); o += 8 }
            var child = try resolve(component, depth: depth + 1).map { c in
                c.map { Point(xx * $0.x + yx * $0.y, xy * $0.x + yy * $0.y, onCurve: $0.onCurve) }
            }
            var dx = 0.0, dy = 0.0
            if flags & 2 != 0 {
                dx = Double(arg1); dy = Double(arg2)
                if flags & 0x800 != 0 && flags & 0x1000 == 0 {
                    let sx = dx, sy = dy
                    dx = xx * sx + yx * sy; dy = xy * sx + yy * sy
                }
            } else {
                let parent = result.flatMap { $0 }, moved = child.flatMap { $0 }
                if arg1 >= 0, arg1 < parent.count, arg2 >= 0, arg2 < moved.count {
                    dx = parent[arg1].x - moved[arg2].x; dy = parent[arg1].y - moved[arg2].y
                }
            }
            if dx != 0 || dy != 0 { child = child.map { $0.map { Point($0.x + dx, $0.y + dy, onCurve: $0.onCurve) } } }
            result += child
            guard result.reduce(0, { $0 + $1.count }) < 200_000 else { throw FontError.damaged("composite glyph too large") }
            if flags & 0x20 == 0 { if flags & 0x100 != 0 { hasInstructions = true }; break }
        }
        return result
    }
}
