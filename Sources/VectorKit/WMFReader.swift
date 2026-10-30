import CoreGraphics
import Foundation
import SuperConverterCore

/// Windows Metafile → VectorDocument (formats §3.2, MS-WMF): placeable and plain files, the records real files use
/// (shapes, polygons, pens, brushes, fonts, text, DIB blits, clip rectangles and regions, window mapping), played on the
/// same GDI device context as EMF. The window maps onto a fixed frame: the placeable header's box, else the first window
/// the file sets.
public enum WMFReader {
    public static func read(_ data: Data) throws -> VectorReadResult {
        let d = ByteReader(data)
        var start = 0
        var frame: CGRect?
        var pointsPerUnit = 0.75
        if d.u32(0) == 0x9AC6_CDD7 {
            // Placeable header (MS-WMF 2.3.2.3): bounding box in logical units and how many make an inch.
            let box = CGRect(x: Double(d.i16(6)), y: Double(d.i16(8)), width: Double(d.i16(10) - d.i16(6)), height: Double(d.i16(12) - d.i16(8))).standardized
            let inch = d.u16(14)
            if box.width > 0, box.height > 0, inch > 0 { frame = box; pointsPerUnit = 72 / Double(inch) }
            start = 22
        }
        guard d.has(start, 18), [1, 2].contains(d.u16(start)), d.u16(start + 2) == 9 else { throw ConversionError.damaged("wmf") }
        let first = start + 18
        if frame == nil, let window = firstWindow(d, from: first) {
            frame = window
            pointsPerUnit = max(abs(window.width), abs(window.height)) > 3000 ? 72.0 / 1440 : 0.75
        }

        let p = GDIPlayer()
        // The window maps onto a viewport the size of the frame, in the frame's own units.
        p.dc.mapMode = 8
        if let frame {
            p.dc.windowOrg = frame.origin; p.dc.windowExt = frame.size
            p.dc.viewportExt = CGSize(width: abs(frame.width), height: abs(frame.height))
        }
        p.hairline = 0.75 / pointsPerUnit
        var player = WMFPlayer(d: d, p: p)
        try player.run(from: first)
        let nodes = p.finish()

        var rect = frame.map { CGRect(x: 0, y: 0, width: abs($0.width), height: abs($0.height)) } ?? .zero
        if rect.isEmpty {
            let measured = nodes.compactMap(\.bounds)
            guard var box = measured.first else { throw ConversionError.damaged("wmf") }
            for b in measured.dropFirst() { box = box.union(b) }
            rect = box
        }
        let s = pointsPerUnit
        let toPoints = VectorTransform(a: s, b: 0, c: 0, d: -s, tx: -Double(rect.minX) * s, ty: Double(rect.maxY) * s)
        let size = VectorSize(width: max(1, Double(rect.width) * s), height: max(1, Double(rect.height) * s))
        let page = VectorPage(size: size, nodes: nodes.isEmpty ? [] : [.group(nodes, transform: toPoints, clip: nil, opacity: 1)])
        return VectorReadResult(document: VectorDocument(pages: [page]), lossNotes: p.lossNotes.sorted { $0.detail < $1.detail }, warnings: p.warnings + player.warnings)
    }

    /// The first SETWINDOWORG / SETWINDOWEXT of a file without a placeable header.
    private static func firstWindow(_ d: ByteReader, from start: Int) -> CGRect? {
        var o = start, origin: CGPoint?, extent: CGSize?
        while o + 6 <= d.count, origin == nil || extent == nil {
            let words = d.u32(o), function = d.u16(o + 4)
            guard words >= 3, o + words * 2 <= d.count, function != 0 else { break }
            if function == 0x020B, origin == nil { origin = CGPoint(x: Double(d.i16(o + 8)), y: Double(d.i16(o + 6))) }
            if function == 0x020C, extent == nil { extent = CGSize(width: Double(d.i16(o + 8)), height: Double(d.i16(o + 6))) }
            o += words * 2
        }
        guard let extent, extent.width != 0, extent.height != 0 else { return nil }
        return CGRect(origin: origin ?? .zero, size: extent)
    }
}

struct WMFPlayer {
    let d: ByteReader
    let p: GDIPlayer
    var warnings: [String] = []
    /// Object indices freed below `nextIndex`, lowest first, and the next index never used.
    var freed: [Int] = []
    var nextIndex = 0

    init(d: ByteReader, p: GDIPlayer) { self.d = d; self.p = p }

    mutating func run(from start: Int) throws {
        var o = start, records = 0
        while o + 6 <= d.count {
            let words = d.u32(o), function = d.u16(o + 4)
            guard words >= 3, o + words * 2 <= d.count else {
                if records < 1 { throw ConversionError.damaged("wmf") }
                warnings.append("The file ends early; what could be read was kept.")
                break
            }
            if function == 0 { break }
            record(function, o + 6, o + words * 2, words: words)
            records += 1
            o += words * 2
            if records > 5_000_000 { break }
        }
        if records < 1 { throw ConversionError.damaged("wmf") }
    }

    // MARK: Helpers

    /// A point stored (y, x), as most WMF records order their parameters.
    func yx(_ o: Int) -> CGPoint { CGPoint(x: Double(d.i16(o + 2)), y: Double(d.i16(o))) }
    /// A rectangle stored (bottom, right, top, left).
    func box(_ o: Int) -> CGRect {
        let b = Double(d.i16(o)), r = Double(d.i16(o + 2)), t = Double(d.i16(o + 4)), l = Double(d.i16(o + 6))
        return CGRect(x: min(l, r), y: min(t, b), width: abs(r - l), height: abs(b - t))
    }
    func points(_ o: Int, count: Int, end: Int) -> [CGPoint] {
        guard count >= 0, count <= (end - o) / 4 else { return [] }
        return (0..<count).map { CGPoint(x: Double(d.i16(o + $0 * 4)), y: Double(d.i16(o + $0 * 4 + 2))) }
    }
    func polygon(_ pts: [CGPoint], closed: Bool) -> [PathSegment] {
        guard let first = pts.first else { return [] }
        return [.move(p.point(Double(first.x), Double(first.y)))] + pts.dropFirst().map { .line(p.point(Double($0.x), Double($0.y))) } + (closed ? [.close] : [])
    }
    func note(_ text: String) { p.note(.otherLoss, text) }

    /// A new object takes the lowest free index (MS-WMF 3.1.4.1): the lowest one a DELETEOBJECT freed, else the next unused
    /// one. Kept as a sorted list rather than found by scanning the table, which a file of many small object records
    /// would make quadratic.
    mutating func add(_ object: GDIPlayer.Object) {
        let i = freed.isEmpty ? nextIndex : freed.removeFirst()
        if i == nextIndex { nextIndex += 1 }
        p.objects[i] = object
    }

    mutating func delete(_ i: Int) {
        guard p.objects.removeValue(forKey: i) != nil else { return }
        var lo = 0, hi = freed.count
        while lo < hi { let mid = (lo + hi) / 2; if freed[mid] < i { lo = mid + 1 } else { hi = mid } }
        freed.insert(i, at: lo)
    }

    // MARK: Records

    mutating func record(_ function: Int, _ q: Int, _ end: Int, words: Int) {
        if function != 0x0213 && function != 0x0214 { p.flushLine() }
        switch function {
        // State.
        case 0x0201: p.dc.bkColour = GDIPlayer.colour(d.u32(q))
        case 0x0102: p.dc.bkOpaque = d.u16(q) == 2
        case 0x0106: p.dc.fillRule = d.u16(q) == 2 ? .nonZero : .evenOdd
        case 0x0209: p.dc.textColour = GDIPlayer.colour(d.u32(q))
        case 0x012E: p.dc.textAlign = d.u16(q)
        case 0x001E: p.saveDC()
        case 0x0127: p.restoreDC(d.i16(q))
        // The window; the viewport and mapping mode belong to the player, which maps the window onto the frame.
        case 0x020B: p.dc.windowOrg = yx(q)
        case 0x020C: p.dc.windowExt = CGSize(width: Double(d.i16(q + 2)), height: Double(d.i16(q)))
        case 0x020F:
            let off = yx(q)
            p.dc.windowOrg = CGPoint(x: p.dc.windowOrg.x + off.x, y: p.dc.windowOrg.y + off.y)
        case 0x0410:
            let yd = Double(d.i16(q)), yn = Double(d.i16(q + 2)), xd = Double(d.i16(q + 4)), xn = Double(d.i16(q + 6))
            if xd != 0, yd != 0 { p.dc.windowExt = CGSize(width: p.dc.windowExt.width * xn / xd, height: p.dc.windowExt.height * yn / yd) }
        // Objects.
        case 0x02FA:
            add(.pen(GDIPlayer.pen(style: d.u16(q), width: Double(d.i16(q + 2)), colour: GDIPlayer.colour(d.u32(q + 6)), extended: false)))
        case 0x02FC: add(.brush(p.brush(style: d.u16(q), colour: GDIPlayer.colour(d.u32(q + 2)))))
        case 0x02FB: font(q, end)
        case 0x0142:
            let colour = dib(at: q + 4, end).flatMap { MetafileDIB.decode(bmi: $0.info, bits: $0.bits)?.averageColour } ?? .black
            note("Pattern fills were drawn as one colour.")
            add(.brush(.approximated(colour)))
        case 0x01F9:
            note("Pattern fills were drawn as one colour.")
            add(.brush(.approximated(.black)))
        case 0x06FF: add(region(q, end).map { .region($0) } ?? .other)
        case 0x00F7: add(.other)
        case 0x01F0: delete(d.u16(q))
        case 0x012D:
            guard let object = p.objects[d.u16(q)] else { break }
            if case .region(let rects) = object { p.resetClip(); p.intersectClip(rects.flatMap(p.rectSegments)) } else { p.select(object) }
        // Lines and shapes.
        case 0x0214: p.moveTo(yx(q))
        case 0x0213: p.line(to: yx(q))
        case 0x041B: p.rectangle(box(q))
        case 0x0418: p.ellipse(box(q))
        case 0x061C: p.roundRect(box(q + 4), corner: CGSize(width: Double(d.i16(q + 2)), height: Double(d.i16(q))))
        case 0x0817: p.arcShape(box(q + 8), start: yx(q + 4), end: yx(q), kind: .arc)
        case 0x081A: p.arcShape(box(q + 8), start: yx(q + 4), end: yx(q), kind: .pie)
        case 0x0830: p.arcShape(box(q + 8), start: yx(q + 4), end: yx(q), kind: .chord)
        case 0x041F:
            let at = yx(q + 4), a = p.point(Double(at.x), Double(at.y)), s = p.transform().lengthScale
            p.emit(.path([.move(a), .line(VectorPoint(a.x + s, a.y)), .line(VectorPoint(a.x + s, a.y + s)), .line(VectorPoint(a.x, a.y + s)), .close],
                         fill: .solid(GDIPlayer.colour(d.u32(q))), stroke: nil, rule: .nonZero))
        case 0x0324: p.paint(polygon(points(q + 2, count: d.u16(q), end: end), closed: true), fill: true, stroke: true)
        case 0x0325: p.paint(polygon(points(q + 2, count: d.u16(q), end: end), closed: false), fill: false, stroke: true)
        case 0x0538:
            let n = d.u16(q)
            guard n > 0, q + 2 + n * 2 <= end else { break }
            var at = q + 2 + n * 2, segs: [PathSegment] = []
            for i in 0..<n {
                let count = d.u16(q + 2 + i * 2)
                segs += polygon(points(at, count: count, end: end), closed: true)
                at += count * 4
            }
            p.paint(segs, fill: true, stroke: true)
        // Clips and regions.
        case 0x0416: p.intersectClipRect(box(q))
        case 0x0415: p.excludeClipRect(box(q))
        case 0x012C:
            p.resetClip()
            if case .region(let rects)? = p.objects[d.u16(q)] { p.intersectClip(rects.flatMap(p.rectSegments)) }
        case 0x0228, 0x012B:
            guard case .region(let rects)? = p.objects[d.u16(q)] else { break }
            let saved = p.dc.brush
            if function == 0x0228, case .brush(let b)? = p.objects[d.u16(q + 2)] { p.dc.brush = b }
            let pen = p.dc.pen
            p.dc.pen.visible = false
            p.paint(rects.flatMap(p.rectSegments), fill: true, stroke: false)
            p.dc.brush = saved; p.dc.pen = pen
        case 0x0220: note("Clip offsets were ignored.")
        case 0x0429, 0x012A: note("A region outline or inversion was not drawn.")
        case 0x0419, 0x0548: note("Flood fills were not drawn.")
        // Text.
        case 0x0521:
            let n = d.u16(q)
            guard n > 0, d.has(q + 2, n) else { break }
            let at = q + 2 + ((n + 1) & ~1)
            let ref = yx(at)
            p.text(d.ansi(q + 2, chars: n), x: Double(ref.x), y: Double(ref.y), dx: [], opaqueRect: nil)
        case 0x0A32: extTextOut(q, end)
        // Pictures.
        case 0x061D: patBlt(d.u32(q), CGRect(x: Double(d.i16(q + 10)), y: Double(d.i16(q + 8)), width: Double(d.i16(q + 6)), height: Double(d.i16(q + 4))))
        case 0x0F43:
            // STRETCHDIB: rop, usage, src h/w/y/x, dest h/w/y/x, DIB.
            blit(dibAt: q + 22, end, src: (d.i16(q + 12), d.i16(q + 10), d.i16(q + 8), d.i16(q + 6)),
                 dest: CGRect(x: Double(d.i16(q + 20)), y: Double(d.i16(q + 18)), width: Double(d.i16(q + 16)), height: Double(d.i16(q + 14))))
        case 0x0B41:
            // DIBSTRETCHBLT, with or without a bitmap (then a pattern operation with a reserved word).
            if words == (function >> 8) + 3 {
                patBlt(d.u32(q), CGRect(x: Double(d.i16(q + 20)), y: Double(d.i16(q + 18)), width: Double(d.i16(q + 16)), height: Double(d.i16(q + 14))))
            } else {
                blit(dibAt: q + 20, end, src: (d.i16(q + 10), d.i16(q + 8), d.i16(q + 6), d.i16(q + 4)),
                     dest: CGRect(x: Double(d.i16(q + 18)), y: Double(d.i16(q + 16)), width: Double(d.i16(q + 14)), height: Double(d.i16(q + 12))))
            }
        case 0x0940:
            if words == (function >> 8) + 3 {
                patBlt(d.u32(q), CGRect(x: Double(d.i16(q + 16)), y: Double(d.i16(q + 14)), width: Double(d.i16(q + 12)), height: Double(d.i16(q + 10))))
            } else {
                let w = d.i16(q + 10), h = d.i16(q + 8)
                blit(dibAt: q + 16, end, src: (d.i16(q + 6), d.i16(q + 4), w, h),
                     dest: CGRect(x: Double(d.i16(q + 14)), y: Double(d.i16(q + 12)), width: Double(w), height: Double(h)))
            }
        case 0x0D33:
            // SETDIBTODEV: drawn 1:1 with its top-left at the destination.
            let w = d.i16(q + 12), h = d.i16(q + 10)
            blit(dibAt: q + 18, end, src: (d.i16(q + 8), d.i16(q + 6), w, h),
                 dest: CGRect(x: Double(d.i16(q + 16)), y: Double(d.i16(q + 14)), width: Double(w), height: Double(h)))
        case 0x0922, 0x0B23:
            if words == (function >> 8) + 3 {
                let o = function == 0x0922 ? q + 8 : q + 12
                patBlt(d.u32(q), CGRect(x: Double(d.i16(o + 8)), y: Double(d.i16(o + 6)), width: Double(d.i16(o + 4)), height: Double(d.i16(o + 2))))
            } else { note("An old-style bitmap was not drawn.") }
        default: break
        }
    }

    // MARK: Objects

    /// LOGFONT (MS-WMF 2.2.1.2): height, escapement, weight, italic, face name.
    mutating func font(_ q: Int, _ end: Int) {
        var f = GDIPlayer.Font()
        f.height = Double(d.i16(q))
        f.escapement = Double(d.i16(q + 4)) / 10
        f.weight = d.i16(q + 8)
        f.italic = d.u8(q + 10) != 0
        f.name = d.ansi(q + 18, chars: min(32, max(0, end - q - 18)), terminated: true)
        if f.name.isEmpty { f.name = "Arial" }
        add(.font(f))
    }

    /// A Region object (MS-WMF 2.2.1.5) as rectangles: its scans, else its bounds.
    func region(_ q: Int, _ end: Int) -> [CGRect]? {
        guard q + 22 <= end else { return nil }
        let scans = d.u16(q + 10)
        var rects: [CGRect] = []
        var at = q + 22
        for _ in 0..<scans {
            guard at + 6 <= end else { break }
            let count = d.u16(at), top = Double(d.i16(at + 2)), bottom = Double(d.i16(at + 4))
            at += 6
            for _ in 0..<(count / 2) where at + 4 <= end {
                let left = Double(d.i16(at)), right = Double(d.i16(at + 2))
                if right > left, bottom > top { rects.append(CGRect(x: left, y: top, width: right - left, height: bottom - top)) }
                at += 4
            }
            at += 2
        }
        if rects.isEmpty {
            let l = Double(d.i16(q + 14)), t = Double(d.i16(q + 16)), r = Double(d.i16(q + 18)), b = Double(d.i16(q + 20))
            if r > l, b > t { rects = [CGRect(x: l, y: t, width: r - l, height: b - t)] }
        }
        return rects
    }

    // MARK: Pictures

    /// The DIB that runs from `at` to the end of the record, split into its header (with colour table) and pixels.
    func dib(at: Int, _ end: Int) -> (info: [UInt8], bits: [UInt8])? {
        let bytes = d.slice(at, end - at)
        guard bytes.count > 12 else { return nil }
        let infoLength = MetafileDIB.infoLength(ByteReader(bytes: bytes))
        guard infoLength > 0, infoLength <= bytes.count else { return nil }
        return (Array(bytes[0..<infoLength]), Array(bytes[infoLength...]))
    }

    /// Draws the source rectangle (x, y, w, h) of a DIB into `dest` (logical units; negative extents flip).
    func blit(dibAt at: Int, _ end: Int, src: (Int, Int, Int, Int), dest: CGRect) {
        guard let parts = dib(at: at, end), let img = MetafileDIB.decode(bmi: parts.info, bits: parts.bits),
              let part = img.source(x: src.0, y: src.1, w: src.2, h: src.3) else { return }
        p.draw(part, x: Double(dest.origin.x), y: Double(dest.origin.y), w: Double(dest.size.width), h: Double(dest.size.height))
    }

    /// A blit without a source: PATCOPY with the brush, BLACKNESS, WHITENESS; other operations are skipped.
    func patBlt(_ rop: Int, _ rect: CGRect) {
        let saved = p.dc.brush, pen = p.dc.pen
        switch rop {
        case 0x00F0_0021: break
        case 0x0000_0042: p.dc.brush = .solid(.black)
        case 0x00FF_0062: p.dc.brush = .solid(.white)
        default: return
        }
        p.dc.pen.visible = false
        p.rectangle(rect)
        p.dc.brush = saved; p.dc.pen = pen
    }

    // MARK: Text

    /// EXTTEXTOUT: y, x, count, options, the rectangle when ETO_OPAQUE or ETO_CLIPPED, the string, optional advances.
    func extTextOut(_ q: Int, _ end: Int) {
        let ref = yx(q), n = d.u16(q + 4), options = d.u16(q + 6)
        var at = q + 8
        var rect: CGRect?
        if options & 6 != 0 {
            let l = Double(d.i16(at)), t = Double(d.i16(at + 2)), r = Double(d.i16(at + 4)), b = Double(d.i16(at + 6))
            rect = CGRect(x: min(l, r), y: min(t, b), width: abs(r - l), height: abs(b - t))
            at += 8
        }
        guard n > 0, d.has(at, n), at + n <= end else { return }
        let text = d.ansi(at, chars: n)
        let dxAt = at + ((n + 1) & ~1)
        let dx = dxAt + n * 2 <= end ? (0..<n).map { Double(d.i16(dxAt + $0 * 2)) } : []
        p.text(text, x: Double(ref.x), y: Double(ref.y), dx: dx, opaqueRect: options & 2 != 0 ? rect : nil, clipRect: options & 4 != 0 ? rect : nil)
    }
}
