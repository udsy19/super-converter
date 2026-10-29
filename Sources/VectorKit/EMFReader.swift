import CoreGraphics
import Foundation
import SuperConverterCore

/// Enhanced Metafile → VectorDocument (formats §3.2): the ~70 records real files use. When an EMF+ stream is present
/// (dual files), its anti-aliased drawing is read instead of the GDI duplicates.
public enum EMFReader {
    public static func read(_ data: Data) throws -> VectorReadResult {
        let d = ByteReader(data)
        guard d.count >= 88, d.u32(0) == 1, d.u32(40) == 0x464D4520, d.u32(4) >= 80, d.u32(4) <= d.count else { throw ConversionError.damaged("emf") }
        let p = GDIPlayer()
        let device = CGSize(width: Double(d.i32(72)), height: Double(d.i32(76))), mm = CGSize(width: Double(d.i32(80)), height: Double(d.i32(84)))
        if device.width > 0, device.height > 0, mm.width > 0, mm.height > 0 {
            p.pixelsPerMM = (Double(device.width / mm.width), Double(device.height / mm.height))
        }
        var player = EMFPlayer(d: d, p: p)
        try player.run()
        let nodes = p.finish()
        // Device rectangle the page shows: the frame (0.01 mm) in device units, else the bounds.
        var rect = CGRect.zero
        let fl = Double(d.i32(24)), ft = Double(d.i32(28)), fr = Double(d.i32(32)), fb = Double(d.i32(36))
        if fr > fl, fb > ft {
            rect = CGRect(x: fl / 100 * p.pixelsPerMM.x, y: ft / 100 * p.pixelsPerMM.y, width: (fr - fl) / 100 * p.pixelsPerMM.x, height: (fb - ft) / 100 * p.pixelsPerMM.y)
        }
        let bl = Double(d.i32(8)), bt = Double(d.i32(12)), br = Double(d.i32(16)), bb = Double(d.i32(20))
        if rect.isEmpty, br >= bl, bb >= bt { rect = CGRect(x: bl, y: bt, width: br - bl + 1, height: bb - bt + 1) }
        let measured = nodes.compactMap(\.bounds)
        if rect.isEmpty || !(rect.width > 0 && rect.height > 0 && rect.width < 1e7 && rect.height < 1e7) {
            guard var box = measured.first else { throw ConversionError.damaged("emf") }
            for b in measured.dropFirst() { box = box.union(b) }
            rect = box
        }
        let s = 72.0 / 25.4 / p.pixelsPerMM.x, sy = 72.0 / 25.4 / p.pixelsPerMM.y
        let toPoints = VectorTransform(a: s, b: 0, c: 0, d: -sy, tx: -Double(rect.minX) * s, ty: Double(rect.maxY) * sy)
        let size = VectorSize(width: max(1, Double(rect.width) * s), height: max(1, Double(rect.height) * sy))
        let page = VectorPage(size: size, nodes: nodes.isEmpty ? [] : [.group(nodes, transform: toPoints, clip: nil, opacity: 1)])
        return VectorReadResult(document: VectorDocument(pages: [page]), lossNotes: p.lossNotes.sorted { $0.detail < $1.detail }, warnings: p.warnings + player.warnings)
    }
}

struct EMFPlayer {
    let d: ByteReader
    let p: GDIPlayer
    var warnings: [String] = []
    var plus: EMFPlusPlayer?
    var gdiAfterGetDC = false

    init(d: ByteReader, p: GDIPlayer) { self.d = d; self.p = p }

    mutating func run() throws {
        var o = 0
        var records = 0
        while o + 8 <= d.count {
            let type = d.u32(o), size = d.u32(o + 4)
            guard size >= 8, o + size <= d.count else {
                if records < 2 { throw ConversionError.damaged("emf") }
                warnings.append("The file ends early; what could be read was kept.")
                break
            }
            if type == 14 { break }
            record(type, o, size)
            records += 1
            o += (size + 3) & ~3
            if records > 5_000_000 { break }
        }
        if records < 2 { throw ConversionError.damaged("emf") }
        p.suppressDrawing = false
    }

    // MARK: Helpers

    func pt(_ o: Int) -> CGPoint { CGPoint(x: Double(d.i32(o)), y: Double(d.i32(o + 4))) }
    func rect(_ o: Int) -> CGRect {
        let l = Double(d.i32(o)), t = Double(d.i32(o + 4)), r = Double(d.i32(o + 8)), b = Double(d.i32(o + 12))
        return CGRect(x: min(l, r), y: min(t, b), width: abs(r - l), height: abs(b - t))
    }
    /// Rectangle with its right and bottom edges inclusive counted as exclusive (as GDI shapes use them).
    func points(_ o: Int, count: Int, wide: Bool, end: Int) -> [CGPoint] {
        let each = wide ? 4 : 8
        guard count >= 0, count <= (end - o) / each else { return [] }
        return (0..<count).map { i in wide ? CGPoint(x: Double(d.i16(o + i * 4)), y: Double(d.i16(o + i * 4 + 2))) : pt(o + i * 8) }
    }
    func device(_ q: CGPoint) -> VectorPoint { p.point(Double(q.x), Double(q.y)) }

    func bezier(_ pts: [CGPoint], from start: VectorPoint?) -> [PathSegment] {
        var segs: [PathSegment] = []
        var i = 0
        if let start { segs.append(.move(start)) } else if let f = pts.first { segs.append(.move(device(f))); i = 1 }
        while i + 2 < pts.count { segs.append(.cubic(device(pts[i]), device(pts[i + 1]), device(pts[i + 2]))); i += 3 }
        return segs
    }

    func lines(_ pts: [CGPoint], from start: VectorPoint?) -> [PathSegment] {
        var segs: [PathSegment] = []
        var i = 0
        if let start { segs.append(.move(start)) } else if let f = pts.first { segs.append(.move(device(f))); i = 1 }
        while i < pts.count { segs.append(.line(device(pts[i]))); i += 1 }
        return segs
    }

    // MARK: Records

    mutating func record(_ type: Int, _ o: Int, _ size: Int) {
        let end = o + size
        if type != 54 && type != 27 { p.flushLine() }
        let isGDIDrawing = !(plus != nil && !gdiAfterGetDC)
        p.suppressDrawing = !isGDIDrawing
        switch type {
        // Polygons and polylines.
        case 2, 85: let n = d.u32(o + 24); let pts = points(o + 28, count: n, wide: type == 85, end: end); p.paint(bezier(pts, from: nil), fill: false, stroke: true)
        case 3, 86: let n = d.u32(o + 24); let pts = points(o + 28, count: n, wide: type == 86, end: end); p.paint(lines(pts, from: nil) + [.close], fill: true, stroke: true)
        case 4, 87: let n = d.u32(o + 24); let pts = points(o + 28, count: n, wide: type == 87, end: end); p.paint(lines(pts, from: nil), fill: false, stroke: true)
        case 5, 88:
            let n = d.u32(o + 24); let pts = points(o + 28, count: n, wide: type == 88, end: end)
            guard !pts.isEmpty else { break }
            p.paint(bezier(pts, from: device(p.dc.current)), fill: false, stroke: true)
            if pts.count >= 3 { p.dc.current = pts[(pts.count / 3) * 3 - 1] }
        case 6, 89:
            let n = d.u32(o + 24); let pts = points(o + 28, count: n, wide: type == 89, end: end)
            guard let last = pts.last else { break }
            p.paint(lines(pts, from: device(p.dc.current)), fill: false, stroke: true)
            p.dc.current = last
        case 7, 8, 90, 91:
            let wide = type >= 90
            let polys = d.u32(o + 24)
            guard polys > 0, polys <= (end - o - 32) / 4 else { break }
            let counts = (0..<polys).map { d.u32(o + 32 + $0 * 4) }
            var at = o + 32 + polys * 4
            var segs: [PathSegment] = []
            let polygon = type == 8 || type == 91
            for c in counts {
                let pts = points(at, count: c, wide: wide, end: end)
                at += c * (wide ? 4 : 8)
                guard !pts.isEmpty else { continue }
                segs += lines(pts, from: nil) + (polygon ? [.close] : [])
            }
            p.paint(segs, fill: polygon, stroke: true)
        case 56, 92: polyDraw(o, end, wide: type == 92)
        // Window, viewport, mapping.
        case 9: p.dc.windowExt = CGSize(width: Double(d.i32(o + 8)), height: Double(d.i32(o + 12)))
        case 10: p.dc.windowOrg = pt(o + 8)
        case 11: p.dc.viewportExt = CGSize(width: Double(d.i32(o + 8)), height: Double(d.i32(o + 12)))
        case 12: p.dc.viewportOrg = pt(o + 8)
        case 17: p.dc.mapMode = d.u32(o + 8)
        case 31:
            let xn = Double(d.i32(o + 8)), xd = Double(d.i32(o + 12)), yn = Double(d.i32(o + 16)), yd = Double(d.i32(o + 20))
            if xd != 0, yd != 0 { p.dc.viewportExt = CGSize(width: p.dc.viewportExt.width * xn / xd, height: p.dc.viewportExt.height * yn / yd) }
        case 32:
            let xn = Double(d.i32(o + 8)), xd = Double(d.i32(o + 12)), yn = Double(d.i32(o + 16)), yd = Double(d.i32(o + 20))
            if xd != 0, yd != 0 { p.dc.windowExt = CGSize(width: p.dc.windowExt.width * xn / xd, height: p.dc.windowExt.height * yn / yd) }
        case 35: p.dc.world = xform(o + 8)
        case 36:
            let x = xform(o + 8)
            switch d.u32(o + 32) {
            case 1: p.dc.world = .identity
            case 2: p.dc.world = x.then(p.dc.world)
            case 3: p.dc.world = p.dc.world.then(x)
            case 4: p.dc.world = x
            default: break
            }
        // State.
        case 18: p.dc.bkOpaque = d.u32(o + 8) == 2
        case 19: p.dc.fillRule = d.u32(o + 8) == 2 ? .nonZero : .evenOdd
        case 22: p.dc.textAlign = d.u32(o + 8)
        case 24: p.dc.textColour = GDIPlayer.colour(d.u32(o + 8))
        case 25: p.dc.bkColour = GDIPlayer.colour(d.u32(o + 8))
        case 27: p.moveTo(pt(o + 8))
        case 33: p.saveDC()
        case 34: p.restoreDC(d.i32(o + 8))
        case 57: p.dc.arcClockwise = d.u32(o + 8) == 2
        case 58: p.dc.miterLimit = Double(d.u32(o + 8))
        // Objects.
        case 37: selectObject(d.u32(o + 8))
        case 38:
            let pen = GDIPlayer.pen(style: d.u32(o + 12), width: Double(d.i32(o + 16)), colour: GDIPlayer.colour(d.u32(o + 24)), extended: false)
            p.objects[d.u32(o + 8)] = .pen(pen)
        case 95: extPen(o, end)
        case 39: brushIndirect(o)
        case 93, 94: dibBrush(o)
        case 40: p.objects[d.u32(o + 8)] = nil
        case 82: font(o, size)
        // Shapes.
        case 54: p.line(to: pt(o + 8))
        case 42: p.ellipse(rect(o + 8))
        case 43: p.rectangle(rect(o + 8))
        case 44: p.roundRect(rect(o + 8), corner: CGSize(width: Double(d.i32(o + 24)), height: Double(d.i32(o + 28))))
        case 45: p.arcShape(rect(o + 8), start: pt(o + 24), end: pt(o + 32), kind: .arc)
        case 46: p.arcShape(rect(o + 8), start: pt(o + 24), end: pt(o + 32), kind: .chord)
        case 47: p.arcShape(rect(o + 8), start: pt(o + 24), end: pt(o + 32), kind: .pie)
        case 55:
            let box = rect(o + 8), s = pt(o + 24), e = pt(o + 32)
            p.line(to: s)
            p.arcShape(box, start: s, end: e, kind: .arc)
            p.dc.current = e
        case 41: angleArc(o)
        case 15: pixel(o)
        // Paths and clips.
        case 59: p.pathRecording = true; p.path = []
        case 60: p.pathRecording = false
        case 61: if p.pathRecording, !p.path.isEmpty { p.path.append(.close) }
        case 62: let segs = p.path; p.path = []; p.pathRecording = false; p.paint(segs, fill: true, stroke: false)
        case 63: let segs = p.path; p.path = []; p.pathRecording = false; p.paint(segs, fill: true, stroke: true)
        case 64: let segs = p.path; p.path = []; p.pathRecording = false; p.paint(segs, fill: false, stroke: true)
        case 65, 66: break
        case 68: p.path = []; p.pathRecording = false
        case 67: selectClipPath(d.u32(o + 8))
        case 29: p.excludeClipRect(rect(o + 8))
        case 30: p.intersectClipRect(rect(o + 8))
        case 75: extSelectClipRgn(o, end)
        case 28, 26: if type == 26 { note("Clip offsets were ignored.") }
        case 71, 74: regionFill(o, end, type: type)
        // Pictures.
        case 76, 77, 78, 114, 116: blit(type, o, end)
        case 81: stretchDIBits(o, end)
        case 80: setDIBitsToDevice(o, end)
        case 118: gradient(o, end)
        // Text.
        case 83, 84: extTextOut(o, end, wide: type == 84)
        case 108: smallTextOut(o, end)
        // Comments (EMF+).
        case 70: comment(o, end)
        case 79: note("A parallelogram picture was not drawn.")
        case 96, 97: note("Some text was not drawn.")
        default: break
        }
        p.suppressDrawing = false
    }

    func note(_ text: String) { p.note(.otherLoss, text) }

    func xform(_ o: Int) -> VectorTransform {
        VectorTransform(a: d.f32(o), b: d.f32(o + 4), c: d.f32(o + 8), d: d.f32(o + 12), tx: d.f32(o + 16), ty: d.f32(o + 20))
    }

    func selectObject(_ handle: Int) {
        if handle & 0x80000000 != 0 {
            if let stock = GDIPlayer.stockObject(handle & 0x7FFFFFFF) { p.select(stock) }
            return
        }
        if let object = p.objects[handle] { p.select(object) }
    }

    // MARK: Objects

    func extPen(_ o: Int, _ end: Int) {
        let style = d.u32(o + 28), width = Double(d.u32(o + 32)), brushStyle = d.u32(o + 36)
        let colour = GDIPlayer.colour(d.u32(o + 40))
        let n = d.u32(o + 48)
        var dash: [Double] = []
        if style & 0xF == 7, n > 0, n <= (end - o - 52) / 4 { dash = (0..<n).map { Double(d.u32(o + 52 + $0 * 4)) / max(width, 1) } }
        var pen = GDIPlayer.pen(style: style, width: width, colour: colour, extended: true, userDash: dash)
        if brushStyle == 1 { pen.visible = false }
        p.objects[d.u32(o + 8)] = .pen(pen)
    }

    func brushIndirect(_ o: Int) {
        p.objects[d.u32(o + 8)] = .brush(p.brush(style: d.u32(o + 12), colour: GDIPlayer.colour(d.u32(o + 16))))
    }

    func dibBrush(_ o: Int) {
        let bmi = d.slice(o + d.u32(o + 16), d.u32(o + 20)), bits = d.slice(o + d.u32(o + 24), d.u32(o + 28))
        let colour = MetafileDIB.decode(bmi: bmi, bits: bits)?.averageColour ?? .black
        note("Pattern fills were drawn as one colour.")
        p.objects[d.u32(o + 8)] = .brush(.approximated(colour))
    }

    func font(_ o: Int, _ size: Int) {
        var f = GDIPlayer.Font()
        f.height = Double(d.i32(o + 12))
        f.escapement = Double(d.i32(o + 20)) / 10
        f.weight = d.i32(o + 28)
        f.italic = d.u8(o + 32) != 0
        f.name = d.utf16(o + 40, chars: 32, terminated: true)
        if f.name.isEmpty { f.name = "Arial" }
        p.objects[d.u32(o + 8)] = .font(f)
    }

    // MARK: Drawing helpers

    func polyDraw(_ o: Int, _ end: Int, wide: Bool) {
        let n = d.u32(o + 24)
        let pts = points(o + 28, count: n, wide: wide, end: end)
        let typesAt = o + 28 + n * (wide ? 4 : 8)
        guard pts.count == n, typesAt + n <= end else { return }
        var segs: [PathSegment] = []
        var i = 0
        var cur = device(p.dc.current)
        while i < n {
            let t = d.u8(typesAt + i)
            let kind = t & ~1
            if kind == 6 { cur = device(pts[i]); segs.append(.move(cur)); p.dc.current = pts[i]; i += 1 }
            else if kind == 2 { cur = device(pts[i]); segs.append(.line(cur)); p.dc.current = pts[i]; if t & 1 != 0 { segs.append(.close) }; i += 1 }
            else if kind == 4, i + 2 < n {
                cur = device(pts[i + 2]); segs.append(.cubic(device(pts[i]), device(pts[i + 1]), cur)); p.dc.current = pts[i + 2]
                if d.u8(typesAt + i + 2) & 1 != 0 { segs.append(.close) }
                i += 3
            } else { i += 1 }
        }
        p.paint(segs, fill: false, stroke: true)
    }

    func angleArc(_ o: Int) {
        let c = pt(o + 8), r = Double(d.u32(o + 16)), a0 = d.f32(o + 20), sweep = d.f32(o + 24)
        let t0 = a0 * .pi / 180, ts = sweep * .pi / 180
        // GDI angles run counterclockwise on screen; in a y-down mapping that is the negative parametric direction.
        let sign = p.transform().determinant < 0 ? 1.0 : -1.0
        let start = CGPoint(x: Double(c.x) + r * cos(sign * t0), y: Double(c.y) + r * sin(sign * t0))
        p.line(to: start)
        let arc = GDIPlayer.arcSegments(cx: Double(c.x), cy: Double(c.y), rx: r, ry: r, t1: sign * t0, sweep: sign * ts)
        p.paint(([.move(VectorPoint(Double(start.x), Double(start.y)))] + arc).transformed(by: p.transform()), fill: false, stroke: true)
        let endAngle = sign * (t0 + ts)
        p.dc.current = CGPoint(x: Double(c.x) + r * cos(endAngle), y: Double(c.y) + r * sin(endAngle))
    }

    func pixel(_ o: Int) {
        let q = pt(o + 8)
        let colour = GDIPlayer.colour(d.u32(o + 16))
        let a = device(q), s = p.transform().lengthScale
        p.emit(.path([.move(a), .line(VectorPoint(a.x + s, a.y)), .line(VectorPoint(a.x + s, a.y + s)), .line(VectorPoint(a.x, a.y + s)), .close], fill: .solid(colour), stroke: nil, rule: .nonZero))
    }

    // MARK: Clipping and regions

    func regionRects(_ o: Int, _ bytes: Int) -> [CGRect]? {
        guard bytes >= 32, d.has(o, bytes), d.u32(o) >= 32 else { return nil }
        let n = d.u32(o + 8)
        guard n >= 0, n <= (bytes - 32) / 16 else { return nil }
        return (0..<n).map { rect(o + 32 + $0 * 16) }
    }

    func rectsPath(_ rects: [CGRect]) -> [PathSegment] { rects.flatMap { p.rectSegments($0) } }

    func extSelectClipRgn(_ o: Int, _ end: Int) {
        let cb = d.u32(o + 8), mode = d.u32(o + 12)
        if cb == 0 { if mode == 5 { p.resetClip() }; return }
        guard let rects = regionRects(o + 16, cb) else { return }
        switch mode {
        case 1: p.intersectClip(rectsPath(rects))
        case 4: for r in rects { p.excludeClipRect(r) }
        default:
            if mode != 5 { note("A clip combination was approximated.") }
            p.resetClip(); p.intersectClip(rectsPath(rects))
        }
    }

    func selectClipPath(_ mode: Int) {
        let segs = p.path
        p.path = []; p.pathRecording = false
        guard !segs.isEmpty else { return }
        if mode == 5 { p.resetClip() }
        else if mode != 1 { note("A clip combination was approximated.") }
        p.intersectClip(segs)
    }

    func regionFill(_ o: Int, _ end: Int, type: Int) {
        let rects: [CGRect]?
        var brush: GDIPlayer.Brush?
        if type == 71 {
            rects = regionRects(o + 32, d.u32(o + 24))
            if let obj = p.objects[d.u32(o + 28)], case .brush(let b) = obj { brush = b }
            else if let stock = GDIPlayer.stockObject(d.u32(o + 28) & 0x7FFFFFFF), case .brush(let b) = stock { brush = b }
        } else { rects = regionRects(o + 28, d.u32(o + 24)) }
        guard let rects else { return }
        let saved = p.dc.brush
        if let brush { p.dc.brush = brush }
        p.paint(rectsPath(rects), fill: true, stroke: false)
        p.dc.brush = saved
    }

    // MARK: Pictures

    func blit(_ type: Int, _ o: Int, _ end: Int) {
        let xd = Double(d.i32(o + 24)), yd = Double(d.i32(o + 28)), cxd = Double(d.i32(o + 32)), cyd = Double(d.i32(o + 36))
        let rop = d.u32(o + 40)
        let offBmi = d.u32(o + 84), cbBmi = d.u32(o + 88), offBits = d.u32(o + 92), cbBits = d.u32(o + 96)
        let xs = d.i32(o + 44), ys = d.i32(o + 48)
        if cbBmi == 0 || offBmi == 0 {
            // No source bitmap: a pattern or solid operation on the destination.
            let box = CGRect(x: xd, y: yd, width: cxd, height: cyd)
            let saved = p.dc.brush, savedPen = p.dc.pen
            switch rop {
            case 0x00F00021: break
            case 0x00000042: p.dc.brush = .solid(.black)
            case 0x00FF0062: p.dc.brush = .solid(.white)
            default: return
            }
            p.dc.pen.visible = false
            p.rectangle(box)
            p.dc.brush = saved; p.dc.pen = savedPen
            return
        }
        guard d.has(o + offBmi, cbBmi), d.has(o + offBits, cbBits) else { return }
        var alpha = 1.0
        var honour = false
        var keyColour: VectorColour?
        if type == 114 { honour = (rop >> 24) & 255 == 1; alpha = Double((rop >> 16) & 255) / 255 }
        if type == 116 { keyColour = GDIPlayer.colour(rop) }
        guard var img = MetafileDIB.decode(bmi: d.slice(o + offBmi, cbBmi), bits: d.slice(o + offBits, cbBits), honourAlpha: honour) else { return }
        let cxs = type == 76 ? img.width : d.i32(o + 100), cys = type == 76 ? img.height : d.i32(o + 104)
        guard let cropped = img.source(x: xs, y: ys, w: type == 76 ? img.width - xs : cxs, h: type == 76 ? img.height - ys : cys) else { return }
        img = cropped
        if let key = keyColour, img.embedded == nil { img = chromaKey(img, key) }
        let wasSuppressed = p.suppressDrawing
        if alpha < 0.999 {
            let before = p.layers[p.layers.count - 1].nodes.count
            p.draw(img, x: xd, y: yd, w: cxd, h: cyd)
            if !wasSuppressed, p.layers[p.layers.count - 1].nodes.count > before, let last = p.layers[p.layers.count - 1].nodes.popLast() {
                p.layers[p.layers.count - 1].nodes.append(.group([last], transform: .identity, clip: nil, opacity: alpha))
            }
        } else { p.draw(img, x: xd, y: yd, w: cxd, h: cyd) }
        if type == 78 { note("A mask on a picture was ignored.") }
    }

    func chromaKey(_ img: MetafileDIB.Image, _ key: VectorColour) -> MetafileDIB.Image {
        var out = img
        let r = UInt8((key.red * 255).rounded()), g = UInt8((key.green * 255).rounded()), b = UInt8((key.blue * 255).rounded())
        for i in 0..<(out.rgba.count / 4) where out.rgba[i * 4] == r && out.rgba[i * 4 + 1] == g && out.rgba[i * 4 + 2] == b { out.rgba[i * 4 + 3] = 0; out.hasAlpha = true }
        return out
    }

    func stretchDIBits(_ o: Int, _ end: Int) {
        let xd = Double(d.i32(o + 24)), yd = Double(d.i32(o + 28)), xs = d.i32(o + 32), ys = d.i32(o + 36), cxs = d.i32(o + 40), cys = d.i32(o + 44)
        let offBmi = d.u32(o + 48), cbBmi = d.u32(o + 52), offBits = d.u32(o + 56), cbBits = d.u32(o + 60)
        let cxd = Double(d.i32(o + 72)), cyd = Double(d.i32(o + 76))
        guard cbBmi > 0, d.has(o + offBmi, cbBmi), d.has(o + offBits, cbBits), d.u32(o + 64) == 0 else { return }
        guard let img = MetafileDIB.decode(bmi: d.slice(o + offBmi, cbBmi), bits: d.slice(o + offBits, cbBits)),
              let part = img.source(x: xs, y: ys, w: cxs, h: cys) else { return }
        p.draw(part, x: xd, y: yd, w: cxd, h: cyd)
    }

    func setDIBitsToDevice(_ o: Int, _ end: Int) {
        let xd = Double(d.i32(o + 24)), yd = Double(d.i32(o + 28)), xs = d.i32(o + 32), ys = d.i32(o + 36), cxs = d.i32(o + 40), cys = d.i32(o + 44)
        let offBmi = d.u32(o + 48), cbBmi = d.u32(o + 52), offBits = d.u32(o + 56), cbBits = d.u32(o + 60)
        guard cbBmi > 0, d.has(o + offBmi, cbBmi), d.has(o + offBits, cbBits) else { return }
        guard let img = MetafileDIB.decode(bmi: d.slice(o + offBmi, cbBmi), bits: d.slice(o + offBits, cbBits)),
              let part = img.source(x: xs, y: ys, w: cxs, h: cys) else { return }
        // Drawn 1:1 with its top-left at the destination.
        p.draw(part, x: xd, y: yd, w: Double(part.width), h: Double(part.height))
    }

    func gradient(_ o: Int, _ end: Int) {
        let nv = d.u32(o + 24), nt = d.u32(o + 28), mode = d.u32(o + 32)
        guard nv >= 2, nv <= (end - o - 36) / 16, nt >= 0 else { return }
        func vertex(_ i: Int) -> (Double, Double, VectorColour) {
            let b = o + 36 + i * 16
            return (Double(d.i32(b)), Double(d.i32(b + 4)),
                    VectorColour(red: Double(d.u16(b + 8)) / 65280, green: Double(d.u16(b + 10)) / 65280, blue: Double(d.u16(b + 12)) / 65280))
        }
        var at = o + 36 + nv * 16
        let t = p.transform()
        for _ in 0..<nt {
            if mode == 2 {
                guard at + 12 <= end else { return }
                let idx = (0..<3).map { d.u32(at + $0 * 4) }
                at += 12
                guard idx.allSatisfy({ $0 < nv }) else { continue }
                let v = idx.map(vertex)
                let avg = VectorColour(red: (v[0].2.red + v[1].2.red + v[2].2.red) / 3, green: (v[0].2.green + v[1].2.green + v[2].2.green) / 3, blue: (v[0].2.blue + v[1].2.blue + v[2].2.blue) / 3)
                p.emit(.path([.move(t.apply(VectorPoint(v[0].0, v[0].1))), .line(t.apply(VectorPoint(v[1].0, v[1].1))), .line(t.apply(VectorPoint(v[2].0, v[2].1))), .close],
                             fill: .solid(avg), stroke: nil, rule: .nonZero))
                p.note(.shadingRasterised, "Triangle gradients were drawn as flat colours.")
            } else {
                guard at + 8 <= end else { return }
                let i0 = d.u32(at), i1 = d.u32(at + 4)
                at += 8
                guard i0 < nv, i1 < nv else { continue }
                let a = vertex(i0), b = vertex(i1)
                let x0 = min(a.0, b.0), x1 = max(a.0, b.0), y0 = min(a.1, b.1), y1 = max(a.1, b.1)
                let (c0, c1) = mode == 0 ? (a.0 <= b.0 ? (a.2, b.2) : (b.2, a.2)) : (a.1 <= b.1 ? (a.2, b.2) : (b.2, a.2))
                let box = [VectorPoint(x0, y0), VectorPoint(x1, y0), VectorPoint(x1, y1), VectorPoint(x0, y1)].map { t.apply($0) }
                let from = mode == 0 ? t.apply(VectorPoint(x0, y0)) : t.apply(VectorPoint(x0, y0))
                let to = mode == 0 ? t.apply(VectorPoint(x1, y0)) : t.apply(VectorPoint(x0, y1))
                p.emit(.path([.move(box[0]), .line(box[1]), .line(box[2]), .line(box[3]), .close],
                             fill: .linear(from: from, to: to, stops: [GradientStop(offset: 0, colour: c0), GradientStop(offset: 1, colour: c1)]), stroke: nil, rule: .nonZero))
            }
        }
    }

    // MARK: Text

    func extTextOut(_ o: Int, _ end: Int, wide: Bool) {
        let x = Double(d.i32(o + 36)), y = Double(d.i32(o + 40))
        let n = d.u32(o + 44), offString = d.u32(o + 48), options = d.u32(o + 52), offDx = d.u32(o + 72)
        guard n > 0, n <= 100_000, d.has(o + offString, n * (wide ? 2 : 1)) else { return }
        let text = wide ? d.utf16(o + offString, chars: n) : d.ansi(o + offString, chars: n)
        var dx: [Double] = []
        if offDx > 0, d.has(o + offDx, n * 4) {
            let step = options & 0x2000 != 0 ? 2 : 1
            dx = (0..<n).map { Double(d.i32(o + offDx + $0 * 4 * step)) }
        }
        let box = rect(o + 56)
        p.text(text, x: x, y: y, dx: dx, opaqueRect: options & 2 != 0 ? box : nil, clipRect: options & 4 != 0 ? box : nil)
    }

    func smallTextOut(_ o: Int, _ end: Int) {
        let x = Double(d.i32(o + 8)), y = Double(d.i32(o + 12)), n = d.u32(o + 16), options = d.u32(o + 20)
        var at = o + 36
        if options & 0x100 == 0 { at += 16 }
        let small = options & 0x200 != 0
        guard n > 0, n <= 100_000, d.has(at, n * (small ? 1 : 2)) else { return }
        p.text(small ? d.ansi(at, chars: n) : d.utf16(at, chars: n), x: x, y: y, dx: [], opaqueRect: nil)
    }

    // MARK: Comments

    mutating func comment(_ o: Int, _ end: Int) {
        let dataSize = d.u32(o + 8)
        guard dataSize >= 4, d.u32(o + 12) == 0x2B464D45, o + 12 + dataSize <= end else { return }
        if plus == nil { plus = EMFPlusPlayer(d: d, p: p) }
        p.suppressDrawing = false
        gdiAfterGetDC = plus!.play(from: o + 16, to: o + 12 + dataSize)
    }
}
