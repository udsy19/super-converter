import Foundation
import SuperConverterCore

/// Reads the outlines of a `CFF ` or `CFF2` table: INDEX structures, DICTs, charset, FDSelect and a Type 2 charstring
/// interpreter (subroutines, hint masks, flex, CFF2 `blend` at the default instance). Outlines come out as cubic contours.
struct CFFGlyphs {
    var contours: [[FontModel.Contour]]
    /// The glyph names the charset gives, nil where there is none.
    var names: [String?]
}

enum CFFReader {
    typealias Contour = FontModel.Contour

    struct Index { var items: [Range<Int>]; var end: Int }

    static func readIndex(_ d: [UInt8], at o: Int, v2: Bool) throws -> Index {
        let count = v2 ? try d.be32(o) : try d.be16(o)
        let head = v2 ? 4 : 2
        if count == 0 { return Index(items: [], end: o + head) }
        guard count < 1 << 20 else { throw FontError.damaged("CFF index size") }
        let offSize = try d.be8(o + head)
        guard (1...4).contains(offSize) else { throw FontError.damaged("CFF offSize") }
        let offsetsStart = o + head + 1
        func offset(_ i: Int) throws -> Int {
            var v = 0
            for k in 0..<offSize { v = v << 8 | (try d.be8(offsetsStart + i * offSize + k)) }
            return v
        }
        let base = offsetsStart + (count + 1) * offSize - 1
        var items: [Range<Int>] = []
        items.reserveCapacity(count)
        var previous = try offset(0)
        for i in 1...count {
            let next = try offset(i)
            guard next >= previous, base + next <= d.count else { throw FontError.damaged("CFF index offsets") }
            items.append((base + previous)..<(base + next))
            previous = next
        }
        return Index(items: items, end: base + previous)
    }

    /// DICT operators: two-byte ones (12 x) are stored as 1200 + x.
    static func parseDict(_ d: [UInt8], _ range: Range<Int>) throws -> [Int: [Double]] {
        guard range.lowerBound >= 0, range.upperBound <= d.count, range.lowerBound <= range.upperBound else { throw FontError.damaged("CFF DICT range") }
        var result: [Int: [Double]] = [:]
        var operands: [Double] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let b0 = Int(d[i]); i += 1
            switch b0 {
            case 0...21:
                var op = b0
                if b0 == 12 { op = 1200 + (try d.be8(i)); i += 1 }
                result[op] = operands
                operands = []
            case 28: operands.append(Double(try d.beS16(i))); i += 2
            case 29: operands.append(Double(try d.beS32(i))); i += 4
            case 30:
                var text = ""
                var done = false
                while !done && i < range.upperBound {
                    let byte = Int(d[i]); i += 1
                    for nibble in [byte >> 4, byte & 15] {
                        switch nibble {
                        case 0...9: text += String(nibble)
                        case 10: text += "."
                        case 11: text += "E"
                        case 12: text += "E-"
                        case 14: text += "-"
                        case 15: done = true
                        default: break
                        }
                        if done { break }
                    }
                }
                operands.append(Double(text) ?? 0)
            case 32...246: operands.append(Double(b0 - 139))
            case 247...250: operands.append(Double((b0 - 247) * 256 + (try d.be8(i)) + 108)); i += 1
            case 251...254: operands.append(Double(-(b0 - 251) * 256 - (try d.be8(i)) - 108)); i += 1
            default: throw FontError.damaged("CFF DICT operand")
            }
        }
        return result
    }

    static func read(_ d: [UInt8], isV2: Bool) throws -> CFFGlyphs {
        let headerSize = try d.be8(2)
        var top: [Int: [Double]]
        var stringIndex = Index(items: [], end: 0)
        var globalSubrIndex: Index
        if isV2 {
            let topLength = try d.be16(3)
            top = try parseDict(d, headerSize..<(headerSize + topLength))
            globalSubrIndex = try readIndex(d, at: headerSize + topLength, v2: true)
        } else {
            let names = try readIndex(d, at: headerSize, v2: false)
            let tops = try readIndex(d, at: names.end, v2: false)
            guard let first = tops.items.first else { throw FontError.damaged("CFF without a top DICT") }
            top = try parseDict(d, first)
            stringIndex = try readIndex(d, at: tops.end, v2: false)
            globalSubrIndex = try readIndex(d, at: stringIndex.end, v2: false)
        }
        guard let csOffset = top[17]?.first else { throw FontError.damaged("CFF without charstrings") }
        let charStrings = try readIndex(d, at: Int(csOffset), v2: isV2)
        let glyphCount = charStrings.items.count

        func privateSubrs(_ dict: [Int: [Double]]) throws -> [Range<Int>] {
            guard let p = dict[18], p.count == 2 else { return [] }
            let size = Int(p[0]), offset = Int(p[1])
            let priv = try parseDict(d, offset..<(offset + size))
            guard let subrs = priv[19]?.first else { return [] }
            return try readIndex(d, at: offset + Int(subrs), v2: isV2).items
        }
        var fonts: [[Range<Int>]] = []
        var fdSelect: [Int]?
        if let fdArray = top[1236]?.first {
            let index = try readIndex(d, at: Int(fdArray), v2: isV2)
            for item in index.items { fonts.append(try privateSubrs(try parseDict(d, item))) }
            if let sel = top[1237]?.first { fdSelect = try readFDSelect(d, at: Int(sel), glyphs: glyphCount) }
        } else {
            fonts = [try privateSubrs(top)]
        }
        guard !fonts.isEmpty else { throw FontError.damaged("CFF without font DICTs") }

        var regionCounts: [Int] = []
        if isV2, let vstore = top[24]?.first { regionCounts = (try? readRegionCounts(d, at: Int(vstore))) ?? [] }

        var contours: [[Contour]] = []
        contours.reserveCapacity(glyphCount)
        for gid in 0..<glyphCount {
            let fd = fdSelect.map { gid < $0.count ? $0[gid] : 0 } ?? 0
            let runner = CharStringRunner(data: d, globalSubrs: globalSubrIndex.items,
                                          localSubrs: fonts[min(fd, fonts.count - 1)], isV2: isV2, regionCounts: regionCounts)
            do { try runner.run(charStrings.items[gid]) } catch { throw FontError.damaged("charstring \(gid)") }
            contours.append(runner.finish())
        }

        var names = [String?](repeating: nil, count: glyphCount)
        if !isV2 {
            let isCID = top[1230] != nil
            let sids = try readCharset(d, offset: Int(top[15]?.first ?? 0), glyphs: glyphCount)
            for gid in 1..<max(glyphCount, 1) where gid < sids.count {
                let sid = sids[gid]
                if isCID { names[gid] = "cid\(sid)" }
                else if sid < GlyphNameTables.cffStandard.count { names[gid] = GlyphNameTables.cffStandard[sid] }
                else if sid >= 391, sid - 391 < stringIndex.items.count {
                    names[gid] = String(decoding: d[stringIndex.items[sid - 391]], as: UTF8.self)
                }
            }
        }
        if glyphCount > 0 { names[0] = ".notdef" }
        return CFFGlyphs(contours: contours, names: names)
    }

    private static func readCharset(_ d: [UInt8], offset: Int, glyphs: Int) throws -> [Int] {
        if offset <= 2 { return offset == 0 ? Array(0..<glyphs) : Array(repeating: 0, count: glyphs) }
        var sids = [0]
        let format = try d.be8(offset)
        var o = offset + 1
        switch format {
        case 0:
            while sids.count < glyphs { sids.append(try d.be16(o)); o += 2 }
        case 1, 2:
            while sids.count < glyphs {
                let first = try d.be16(o)
                let left = format == 1 ? try d.be8(o + 2) : try d.be16(o + 2)
                o += format == 1 ? 3 : 4
                for k in 0...left where sids.count < glyphs { sids.append(first + k) }
            }
        default: throw FontError.damaged("charset format")
        }
        return sids
    }

    private static func readFDSelect(_ d: [UInt8], at o: Int, glyphs: Int) throws -> [Int] {
        let format = try d.be8(o)
        var out = [Int](repeating: 0, count: glyphs)
        switch format {
        case 0:
            for g in 0..<glyphs { out[g] = try d.be8(o + 1 + g) }
        case 3:
            let n = try d.be16(o + 1)
            for r in 0..<n {
                let first = try d.be16(o + 3 + r * 3), fd = try d.be8(o + 5 + r * 3)
                let next = try d.be16(o + 6 + r * 3)
                if first < next { for g in first..<min(next, glyphs) { out[g] = fd } }
            }
        case 4:
            let n = try d.be32(o + 1)
            guard n < 1 << 20 else { throw FontError.damaged("FDSelect ranges") }
            for r in 0..<n {
                let first = try d.be32(o + 5 + r * 6), fd = try d.be16(o + 9 + r * 6)
                let next = try d.be32(o + 11 + r * 6)
                if first < next { for g in first..<min(next, glyphs) { out[g] = fd } }
            }
        default: throw FontError.damaged("FDSelect format")
        }
        return out
    }

    private static func readRegionCounts(_ d: [UInt8], at o: Int) throws -> [Int] {
        let store = o + 2
        let count = try d.be16(store + 2 + 4)
        var out: [Int] = []
        for i in 0..<count {
            let dataOffset = try d.be32(store + 8 + i * 4)
            out.append(try d.be16(store + dataOffset + 4))
        }
        return out
    }
}

/// A Type 2 charstring interpreter that collects cubic contours.
final class CharStringRunner {
    typealias Point = FontModel.Contour.Point
    let data: [UInt8]
    let globalSubrs: [Range<Int>], localSubrs: [Range<Int>]
    let isV2: Bool
    let regionCounts: [Int]

    private var stack: [Double] = []
    private var transient = [Double](repeating: 0, count: 32)
    private var x = 0.0, y = 0.0
    private var current: [Point] = []
    private var done: [FontModel.Contour] = []
    private var stems = 0
    private var widthSeen = false
    private var ended = false
    private var vsindex = 0
    private var budget = 2_000_000

    init(data: [UInt8], globalSubrs: [Range<Int>], localSubrs: [Range<Int>], isV2: Bool, regionCounts: [Int]) {
        self.data = data; self.globalSubrs = globalSubrs; self.localSubrs = localSubrs; self.isV2 = isV2; self.regionCounts = regionCounts
    }

    func finish() -> [FontModel.Contour] { closeContour(); return done }

    private func closeContour() {
        defer { current = [] }
        guard current.count >= 2 else { return }
        if let first = current.first, let last = current.last, last.onCurve, last.x == first.x, last.y == first.y, current.count > 2 {
            current.removeLast()
        }
        done.append(FontModel.Contour(points: current))
    }

    private func moveTo(_ dx: Double, _ dy: Double) {
        closeContour()
        x += dx; y += dy
        current = [Point(x, y)]
    }
    private func lineTo(_ dx: Double, _ dy: Double) {
        if current.isEmpty { current = [Point(x, y)] }
        x += dx; y += dy
        current.append(Point(x, y))
    }
    private func curveTo(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
        if current.isEmpty { current = [Point(x, y)] }
        x += a; y += b
        current.append(Point(x, y, onCurve: false))
        x += c; y += d
        current.append(Point(x, y, onCurve: false))
        x += e; y += f
        current.append(Point(x, y))
    }

    /// The first stack-clearing operator may carry the glyph width as an extra leading operand (CFF 1 only).
    private func dropWidth(if extra: Bool) {
        if !widthSeen && !isV2 && extra && !stack.isEmpty { stack.removeFirst() }
        widthSeen = true
    }

    func run(_ range: Range<Int>) throws { try exec(range, depth: 0) }

    private func bias(_ count: Int) -> Int { count < 1240 ? 107 : count < 33900 ? 1131 : 32768 }

    private func exec(_ range: Range<Int>, depth: Int) throws {
        guard depth < 12 else { throw FontError.damaged("subroutine depth") }
        var i = range.lowerBound
        while i < range.upperBound && !ended {
            let b0 = Int(data[i]); i += 1
            budget -= 1
            guard budget > 0, stack.count <= 513 else { throw FontError.damaged("charstring too long") }
            switch b0 {
            case 32...246: stack.append(Double(b0 - 139))
            case 247...250: stack.append(Double((b0 - 247) * 256 + (try data.be8(i)) + 108)); i += 1
            case 251...254: stack.append(Double(-(b0 - 251) * 256 - (try data.be8(i)) - 108)); i += 1
            case 255: stack.append(Double(try data.beS32(i)) / 65536); i += 4
            case 28: stack.append(Double(try data.beS16(i))); i += 2
            case 1, 3, 18, 23:
                dropWidth(if: stack.count % 2 == 1)
                stems += stack.count / 2
                stack.removeAll()
            case 19, 20:
                dropWidth(if: stack.count % 2 == 1)
                stems += stack.count / 2
                stack.removeAll()
                i += (stems + 7) / 8
            case 21:
                dropWidth(if: stack.count > 2)
                if stack.count >= 2 { moveTo(stack[stack.count - 2], stack[stack.count - 1]) }
                stack.removeAll()
            case 22:
                dropWidth(if: stack.count > 1)
                if let dx = stack.last { moveTo(dx, 0) }
                stack.removeAll()
            case 4:
                dropWidth(if: stack.count > 1)
                if let dy = stack.last { moveTo(0, dy) }
                stack.removeAll()
            case 5:
                var k = 0
                while k + 1 < stack.count { lineTo(stack[k], stack[k + 1]); k += 2 }
                stack.removeAll()
            case 6, 7:
                var horizontal = b0 == 6
                for v in stack { if horizontal { lineTo(v, 0) } else { lineTo(0, v) }; horizontal.toggle() }
                stack.removeAll()
            case 8:
                var k = 0
                while k + 5 < stack.count { curveTo(stack[k], stack[k + 1], stack[k + 2], stack[k + 3], stack[k + 4], stack[k + 5]); k += 6 }
                stack.removeAll()
            case 24:
                var k = 0
                while k + 5 < stack.count - 2 { curveTo(stack[k], stack[k + 1], stack[k + 2], stack[k + 3], stack[k + 4], stack[k + 5]); k += 6 }
                if k + 1 < stack.count { lineTo(stack[k], stack[k + 1]) }
                stack.removeAll()
            case 25:
                var k = 0
                while k + 1 < stack.count - 6 { lineTo(stack[k], stack[k + 1]); k += 2 }
                if k + 5 < stack.count { curveTo(stack[k], stack[k + 1], stack[k + 2], stack[k + 3], stack[k + 4], stack[k + 5]) }
                stack.removeAll()
            case 26:
                var k = 0
                var dx1 = 0.0
                if stack.count % 2 == 1 { dx1 = stack[0]; k = 1 }
                while k + 3 < stack.count {
                    curveTo(dx1, stack[k], stack[k + 1], stack[k + 2], 0, stack[k + 3]); dx1 = 0; k += 4
                }
                stack.removeAll()
            case 27:
                var k = 0
                var dy1 = 0.0
                if stack.count % 2 == 1 { dy1 = stack[0]; k = 1 }
                while k + 3 < stack.count {
                    curveTo(stack[k], dy1, stack[k + 1], stack[k + 2], stack[k + 3], 0); dy1 = 0; k += 4
                }
                stack.removeAll()
            case 30, 31:
                var horizontal = b0 == 31
                var k = 0
                while stack.count - k >= 4 {
                    let last = stack.count - k == 5
                    let extra = last ? stack[k + 4] : 0
                    if horizontal { curveTo(stack[k], 0, stack[k + 1], stack[k + 2], extra, stack[k + 3]) }
                    else { curveTo(0, stack[k], stack[k + 1], stack[k + 2], stack[k + 3], extra) }
                    k += last ? 5 : 4
                    horizontal.toggle()
                }
                stack.removeAll()
            case 10, 29:
                guard let n = stack.popLast() else { throw FontError.damaged("subr operand") }
                let subrs = b0 == 10 ? localSubrs : globalSubrs
                let index = Int(n) + bias(subrs.count)
                guard index >= 0, index < subrs.count else { throw FontError.damaged("subr index") }
                try exec(subrs[index], depth: depth + 1)
            case 11: return
            case 14:
                dropWidth(if: stack.count == 1 || stack.count == 5)
                ended = true
            case 15:
                if let v = stack.popLast() { vsindex = Int(v) }
            case 16:
                guard let n = stack.popLast() else { throw FontError.damaged("blend operand") }
                let count = Int(n)
                let k = vsindex < regionCounts.count ? regionCounts[vsindex] : 0
                guard count >= 0, count * (k + 1) <= stack.count else { throw FontError.damaged("blend operands") }
                stack.removeLast(count * k)
            case 12:
                let b1 = try data.be8(i); i += 1
                try escape(b1)
            default:
                stack.removeAll()
            }
        }
    }

    private func escape(_ op: Int) throws {
        func pop() throws -> Double { guard let v = stack.popLast() else { throw FontError.damaged("stack underflow") }; return v }
        switch op {
        case 34:
            guard stack.count >= 7 else { throw FontError.damaged("hflex") }
            let a = stack
            curveTo(a[0], 0, a[1], a[2], a[3], 0)
            curveTo(a[4], 0, a[5], -a[2], a[6], 0)
            stack.removeAll()
        case 35:
            guard stack.count >= 12 else { throw FontError.damaged("flex") }
            let a = stack
            curveTo(a[0], a[1], a[2], a[3], a[4], a[5])
            curveTo(a[6], a[7], a[8], a[9], a[10], a[11])
            stack.removeAll()
        case 36:
            guard stack.count >= 9 else { throw FontError.damaged("hflex1") }
            let a = stack
            curveTo(a[0], a[1], a[2], a[3], a[4], 0)
            curveTo(a[5], 0, a[6], a[7], a[8], -(a[1] + a[3] + a[7]))
            stack.removeAll()
        case 37:
            guard stack.count >= 11 else { throw FontError.damaged("flex1") }
            let a = stack
            let dx = a[0] + a[2] + a[4] + a[6] + a[8], dy = a[1] + a[3] + a[5] + a[7] + a[9]
            curveTo(a[0], a[1], a[2], a[3], a[4], a[5])
            if abs(dx) > abs(dy) { curveTo(a[6], a[7], a[8], a[9], a[10], -dy) } else { curveTo(a[6], a[7], a[8], a[9], -dx, a[10]) }
            stack.removeAll()
        case 3: let b = try pop(), a = try pop(); stack.append(a != 0 && b != 0 ? 1 : 0)
        case 4: let b = try pop(), a = try pop(); stack.append(a != 0 || b != 0 ? 1 : 0)
        case 5: stack.append(try pop() == 0 ? 1 : 0)
        case 9: stack.append(abs(try pop()))
        case 10: let b = try pop(), a = try pop(); stack.append(a + b)
        case 11: let b = try pop(), a = try pop(); stack.append(a - b)
        case 12: let b = try pop(), a = try pop(); stack.append(b == 0 ? 0 : a / b)
        case 14: stack.append(-(try pop()))
        case 15: let b = try pop(), a = try pop(); stack.append(a == b ? 1 : 0)
        case 18: _ = try pop()
        case 20: let i = Int(try pop()), v = try pop(); if i >= 0 && i < 32 { transient[i] = v }
        case 21: let i = Int(try pop()); stack.append(i >= 0 && i < 32 ? transient[i] : 0)
        case 22: let v2 = try pop(), v1 = try pop(), s2 = try pop(), s1 = try pop(); stack.append(v1 <= v2 ? s1 : s2)
        case 23: stack.append(0.5)
        case 24: let b = try pop(), a = try pop(); stack.append(a * b)
        case 26: stack.append(max(0, try pop()).squareRoot())
        case 27: let a = try pop(); stack.append(a); stack.append(a)
        case 28: let b = try pop(), a = try pop(); stack.append(b); stack.append(a)
        case 29:
            let n = Int(try pop())
            guard !stack.isEmpty else { throw FontError.damaged("index") }
            let k = n < 0 ? 0 : min(n, stack.count - 1)
            stack.append(stack[stack.count - 1 - k])
        case 30:
            let j = Int(try pop()), n = Int(try pop())
            guard n > 0, n <= stack.count else { break }
            var part = Array(stack.suffix(n))
            stack.removeLast(n)
            let shift = ((j % n) + n) % n
            part = Array(part.suffix(shift)) + Array(part.prefix(n - shift))
            stack.append(contentsOf: part)
        default:
            stack.removeAll()
        }
    }
}
