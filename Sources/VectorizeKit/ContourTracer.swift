import Foundation

/// A closed outline along pixel edges: one vertex per unit step, in pixel-corner coordinates (y down).
struct Loop {
    var xs: [Int32]
    var ys: [Int32]
    var count: Int { xs.count }
}

/// Traces the boundary of a binary mask into closed loops. The inside is on the right of every edge, so outer outlines run
/// clockwise on screen and holes the other way; where two pieces touch at a corner they stay separate loops.
final class ContourTracer {
    let width: Int
    let height: Int
    private let stride: Int
    private var out0: [Int32]
    private var out1: [Int32]
    private var done0: [Bool]
    private var done1: [Bool]
    private var touched: [Int32] = []

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        stride = width + 1
        let n = (width + 1) * (height + 1)
        out0 = [Int32](repeating: -1, count: n); out1 = out0
        done0 = [Bool](repeating: false, count: n); done1 = done0
    }

    private func add(_ from: Int, _ to: Int) {
        if out0[from] < 0 { out0[from] = Int32(to); touched.append(Int32(from)) }
        else { out1[from] = Int32(to) }
    }

    /// Loops of `mask` (width × height, nonzero = inside). Throws nothing; checks `isCancelled` every few rows.
    func trace(_ mask: [UInt8], isCancelled: () -> Bool) -> [Loop] {
        let w = width, h = height, s = stride
        for y in 0..<h {
            if y % 64 == 0, isCancelled() { clear(); return [] }
            for x in 0..<w where mask[y * w + x] != 0 {
                let v = y * s + x
                if y == 0 || mask[(y - 1) * w + x] == 0 { add(v, v + 1) }
                if x == w - 1 || mask[y * w + x + 1] == 0 { add(v + 1, v + 1 + s) }
                if y == h - 1 || mask[(y + 1) * w + x] == 0 { add(v + 1 + s, v + s) }
                if x == 0 || mask[y * w + x - 1] == 0 { add(v + s, v) }
            }
        }
        var loops: [Loop] = []
        for start in touched {
            for slot in 0..<2 {
                let first = slot == 0 ? out0[Int(start)] : out1[Int(start)]
                if first < 0 || (slot == 0 ? done0[Int(start)] : done1[Int(start)]) { continue }
                loops.append(walk(from: Int(start), slot: slot))
            }
        }
        clear()
        return loops
    }

    private func clear() {
        for v in touched { out0[Int(v)] = -1; out1[Int(v)] = -1; done0[Int(v)] = false; done1[Int(v)] = false }
        touched.removeAll(keepingCapacity: true)
    }

    private func walk(from start: Int, slot startSlot: Int) -> Loop {
        let s = stride
        var xs: [Int32] = [], ys: [Int32] = []
        var v = start, slot = startSlot
        while true {
            if slot == 0 { done0[v] = true } else { done1[v] = true }
            xs.append(Int32(v % s)); ys.append(Int32(v / s))
            let next = Int(slot == 0 ? out0[v] : out1[v])
            let dx = (next % s) - (v % s), dy = (next / s) - (v / s)
            // Prefer a right turn, then straight, then left (the inside is on the right).
            var bestSlot = -1, bestScore = 4
            for candidate in 0..<2 {
                let end = Int(candidate == 0 ? out0[next] : out1[next])
                if end < 0 { continue }
                let cx = (end % s) - (next % s), cy = (end / s) - (next / s)
                let score = (cx == -dy && cy == dx) ? 0 : (cx == dx && cy == dy) ? 1 : 2
                if score < bestScore { bestScore = score; bestSlot = candidate }
            }
            v = next
            slot = bestSlot
            if slot < 0 || (slot == 0 ? done0[v] : done1[v]) { break }
        }
        return Loop(xs: xs, ys: ys)
    }
}
