import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore

/// EMF+ records carried in GDI comments: the anti-aliased drawing of dual-mode files (fills, strokes, paths, pictures,
/// strings, transforms, clips) with solid and linear-gradient brushes.
final class EMFPlusPlayer {
    let d: ByteReader
    let p: GDIPlayer

    enum PlusBrush {
        case solid(VectorColour)
        case linear(rect: CGRect, c0: VectorColour, c1: VectorColour, transform: VectorTransform, stops: [GradientStop])
        case approximated(VectorColour)
    }
    struct PlusPen { var width: Double; var brush: PlusBrush; var cap: LineCap; var join: LineJoin; var miter: Double; var dash: [Double] }
    struct PlusFont { var family: String; var em: Double; var unit: Int; var bold: Bool; var italic: Bool }
    enum PlusObject {
        case brush(PlusBrush), pen(PlusPen), path([PathSegment]), region(RegionShape), image(ImageAsset), font(PlusFont), other
    }
    indirect enum RegionShape { case rect(CGRect), path([PathSegment]), infinite, empty, and(RegionShape, RegionShape), other(RegionShape) }

    struct State { var world: VectorTransform; var unit: Int; var scale: Double; var layerDepth: Int }

    var objects: [Int: PlusObject] = [:]
    var partial: [Int: (type: Int, total: Int, data: [UInt8])] = [:]
    var world = VectorTransform.identity
    var pageUnit = 2
    var pageScale = 1.0
    var dpi = (x: 96.0, y: 96.0)
    var stack: [State] = []
    var gotDC = false

    init(d: ByteReader, p: GDIPlayer) { self.d = d; self.p = p }

    /// Plays the records of one comment; true when the stream asked for the following GDI records to be drawn (EmfPlusGetDC).
    func play(from start: Int, to end: Int) -> Bool {
        var o = start
        gotDC = false
        while o + 12 <= end {
            let type = d.u16(o), flags = d.u16(o + 2), size = d.u32(o + 4), dataSize = d.u32(o + 8)
            guard size >= 12, o + size <= end + 3, dataSize <= size - 12 else { break }
            record(type, flags, o + 12, min(o + 12 + dataSize, end))
            if type == 0x4002 { break }
            o += size
        }
        return gotDC
    }

    // MARK: Transforms

    func unitFactor(_ unit: Int) -> (Double, Double) {
        switch unit {
        case 3: return (dpi.x / 72, dpi.y / 72)
        case 4: return (dpi.x, dpi.y)
        case 5: return (dpi.x / 300, dpi.y / 300)
        case 6: return (dpi.x / 25.4, dpi.y / 25.4)
        default: return (1, 1)
        }
    }

    func transform() -> VectorTransform {
        let f = unitFactor(pageUnit)
        return world.then(.scale(pageScale * f.0, pageScale * f.1))
    }

    func argb(_ v: Int) -> VectorColour {
        VectorColour(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, alpha: Double((v >> 24) & 255) / 255)
    }

    func rectF(_ o: Int) -> CGRect { CGRect(x: d.f32(o), y: d.f32(o + 4), width: d.f32(o + 8), height: d.f32(o + 12)) }
    func rectI(_ o: Int) -> CGRect { CGRect(x: Double(d.i16(o)), y: Double(d.i16(o + 2)), width: Double(d.i16(o + 4)), height: Double(d.i16(o + 6))) }

    /// Points in float or compressed form.
    func points(_ o: Int, _ count: Int, compressed: Bool, end: Int) -> [VectorPoint] {
        let each = compressed ? 4 : 8
        guard count >= 0, count <= (end - o) / each else { return [] }
        return (0..<count).map { i in
            compressed ? VectorPoint(Double(d.i16(o + i * 4)), Double(d.i16(o + i * 4 + 2))) : VectorPoint(d.f32(o + i * 8), d.f32(o + i * 8 + 4))
        }
    }

    // MARK: Records

    func record(_ type: Int, _ flags: Int, _ o: Int, _ end: Int) {
        let compressed = flags & 0x4000 != 0
        switch type {
        case 0x4001:
            dpi = (Double(max(d.u32(o + 8), 1)), Double(max(d.u32(o + 12), 1)))
            world = .identity; pageUnit = 2; pageScale = 1
        case 0x4004: gotDC = true
        case 0x4008: object(flags, o, end)
        case 0x400A:
            let brush = brushFrom(flags, at: o), n = d.u32(o + 4)
            let each = compressed ? 8 : 16
            guard n >= 0, n <= (end - o - 8) / each else { return }
            for i in 0..<n {
                let r = compressed ? rectI(o + 8 + i * each) : rectF(o + 8 + i * each)
                fill(rectPath(r), brush)
            }
        case 0x400B:
            guard let pen = pen(flags & 0xFF) else { return }
            let n = d.u32(o), each = compressed ? 8 : 16
            guard n >= 0, n <= (end - o - 4) / each else { return }
            for i in 0..<n { stroke(rectPath(compressed ? rectI(o + 4 + i * each) : rectF(o + 4 + i * each)), pen) }
        case 0x400C:
            let brush = brushFrom(flags, at: o), n = d.u32(o + 4)
            let pts = points(o + 8, n, compressed: compressed, end: end)
            fill(poly(pts, closed: true), brush)
        case 0x400D:
            guard let pen = pen(flags & 0xFF) else { return }
            let pts = points(o + 4, d.u32(o), compressed: compressed, end: end)
            stroke(poly(pts, closed: flags & 0x2000 != 0), pen)
        case 0x400E: fill(ellipsePath(compressed ? rectI(o + 4) : rectF(o + 4)), brushFrom(flags, at: o))
        case 0x400F: if let pen = pen(flags & 0xFF) { stroke(ellipsePath(compressed ? rectI(o) : rectF(o)), pen) }
        case 0x4010:
            let brush = brushFrom(flags, at: o)
            fill(piePath(compressed ? rectI(o + 12) : rectF(o + 12), start: d.f32(o + 4), sweep: d.f32(o + 8), pie: true), brush)
        case 0x4011:
            if let pen = pen(flags & 0xFF) { stroke(piePath(compressed ? rectI(o + 8) : rectF(o + 8), start: d.f32(o), sweep: d.f32(o + 4), pie: true), pen) }
        case 0x4012:
            if let pen = pen(flags & 0xFF) { stroke(piePath(compressed ? rectI(o + 8) : rectF(o + 8), start: d.f32(o), sweep: d.f32(o + 4), pie: false), pen) }
        case 0x4014:
            if case .path(let segs)? = objects[flags & 0xFF] { fill(segs, brushFrom(flags, at: o)) }
        case 0x4015:
            if case .path(let segs)? = objects[flags & 0xFF], let pen = pen(d.u32(o)) { stroke(segs, pen) }
        case 0x4038:
            if case .path(let segs)? = objects[flags & 0xFF] {
                fill(segs, brushFrom(flags, at: o))
                if let pen = pen(d.u32(o + 4)) { stroke(segs, pen) }
            }
        case 0x401A:
            guard let pen = pen(flags & 0xFF) else { return }
            let pts = points(o + 4, d.u32(o), compressed: compressed, end: end)
            guard let first = pts.first else { return }
            var segs: [PathSegment] = [.move(first)]
            var i = 1
            while i + 2 < pts.count { segs.append(.cubic(pts[i], pts[i + 1], pts[i + 2])); i += 3 }
            stroke(segs, pen)
        case 0x4016, 0x4017:
            let brush = type == 0x4016 ? brushFrom(flags, at: o) : nil
            let base = type == 0x4016 ? o + 4 : o
            let tension = d.f32(base), n = d.u32(base + 4)
            let pts = points(base + 8, n, compressed: compressed, end: end)
            let segs = spline(pts, tension: tension, closed: true)
            if let brush { fill(segs, brush) } else if let pen = pen(flags & 0xFF) { stroke(segs, pen) }
        case 0x4018:
            guard let pen = pen(flags & 0xFF) else { return }
            let tension = d.f32(o), n = d.u32(o + 12)
            stroke(spline(points(o + 16, n, compressed: compressed, end: end), tension: tension, closed: false), pen)
        case 0x401B: drawImage(flags, o, end)
        case 0x401C: drawImagePoints(flags, o, end)
        case 0x401D: drawString(flags, o, end)
        case 0x4026: stack.append(State(world: world, unit: pageUnit, scale: pageScale, layerDepth: p.layers.count))
        case 0x4027:
            if let s = stack.popLast() { restore(s) }
        case 0x4028: stack.append(State(world: world, unit: pageUnit, scale: pageScale, layerDepth: p.layers.count))
        case 0x4029: stack.append(State(world: world, unit: pageUnit, scale: pageScale, layerDepth: p.layers.count))
        case 0x402A:
            if let s = stack.popLast() { restore(s) }
        case 0x402B: world = matrix(o)
        case 0x402C: world = .identity
        case 0x402D: combine(matrix(o), append: flags & 0x2000 != 0)
        case 0x402E: combine(.translation(d.f32(o), d.f32(o + 4)), append: flags & 0x2000 != 0)
        case 0x402F: combine(.scale(d.f32(o), d.f32(o + 4)), append: flags & 0x2000 != 0)
        case 0x4030:
            let r = d.f32(o) * .pi / 180
            combine(VectorTransform(a: cos(r), b: sin(r), c: -sin(r), d: cos(r), tx: 0, ty: 0), append: flags & 0x2000 != 0)
        case 0x4031: pageUnit = flags & 0xFF; pageScale = d.f32(o)
        case 0x4032: p.resetClip()
        case 0x4033: clip(rectPath(compressed ? rectI(o) : rectF(o)), mode: (flags >> 8) & 15)
        case 0x4034:
            if case .path(let segs)? = objects[flags & 0xFF] { clip(segs.transformed(by: transform()), mode: (flags >> 8) & 15, deviceSpace: true) }
        case 0x4035:
            if case .region(let shape)? = objects[flags & 0xFF] { clipRegion(shape, mode: (flags >> 8) & 15) }
        default: break
        }
    }

    func restore(_ s: State) {
        world = s.world; pageUnit = s.unit; pageScale = s.scale
        while p.layers.count > s.layerDepth { p.popLayer() }
    }

    func matrix(_ o: Int) -> VectorTransform {
        VectorTransform(a: d.f32(o), b: d.f32(o + 4), c: d.f32(o + 8), d: d.f32(o + 12), tx: d.f32(o + 16), ty: d.f32(o + 20))
    }

    func combine(_ m: VectorTransform, append: Bool) { world = append ? world.then(m) : m.then(world) }

    // MARK: Geometry

    func rectPath(_ r: CGRect) -> [PathSegment] {
        PathBuilder.rect(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
    }
    func ellipsePath(_ r: CGRect) -> [PathSegment] { PathBuilder.ellipse(cx: Double(r.midX), cy: Double(r.midY), rx: Double(r.width) / 2, ry: Double(r.height) / 2) }
    func poly(_ pts: [VectorPoint], closed: Bool) -> [PathSegment] {
        guard let f = pts.first else { return [] }
        return [.move(f)] + pts.dropFirst().map { PathSegment.line($0) } + (closed ? [.close] : [])
    }
    func piePath(_ r: CGRect, start: Double, sweep: Double, pie: Bool) -> [PathSegment] {
        let cx = Double(r.midX), cy = Double(r.midY), rx = Double(r.width) / 2, ry = Double(r.height) / 2
        guard rx > 0, ry > 0 else { return [] }
        // GDI+ angles are measured clockwise from the x axis, in the (y-down) drawing space.
        let a0 = start * .pi / 180, sw = max(-2 * .pi, min(2 * .pi, sweep * .pi / 180))
        // Convert the angle to the parametric angle of the ellipse.
        let t0 = atan2(sin(a0) / ry, cos(a0) / rx)
        let t1 = atan2(sin(a0 + sw) / ry, cos(a0 + sw) / rx)
        var delta = t1 - t0
        if sw > 0 { while delta < 0 { delta += 2 * .pi } } else { while delta > 0 { delta -= 2 * .pi } }
        if abs(sw) >= 2 * .pi - 1e-9 { delta = sw }
        let arc = GDIPlayer.arcSegments(cx: cx, cy: cy, rx: rx, ry: ry, t1: t0, sweep: delta)
        let s = VectorPoint(cx + rx * cos(t0), cy + ry * sin(t0))
        return pie ? [.move(VectorPoint(cx, cy)), .line(s)] + arc + [.close] : [.move(s)] + arc
    }

    /// Cardinal spline through the points as cubic Béziers.
    func spline(_ pts: [VectorPoint], tension: Double, closed: Bool) -> [PathSegment] {
        let n = pts.count
        guard n >= 2 else { return [] }
        func tangent(_ i: Int) -> VectorPoint {
            let prev = closed ? pts[(i + n - 1) % n] : pts[max(i - 1, 0)], next = closed ? pts[(i + 1) % n] : pts[min(i + 1, n - 1)]
            return VectorPoint(tension * (next.x - prev.x) / 2, tension * (next.y - prev.y) / 2)
        }
        var segs: [PathSegment] = [.move(pts[0])]
        let count = closed ? n : n - 1
        for i in 0..<count {
            let j = (i + 1) % n
            let t0 = tangent(i), t1 = tangent(j)
            segs.append(.cubic(VectorPoint(pts[i].x + t0.x / 1.5, pts[i].y + t0.y / 1.5), VectorPoint(pts[j].x - t1.x / 1.5, pts[j].y - t1.y / 1.5), pts[j]))
        }
        if closed { segs.append(.close) }
        return segs
    }

    // MARK: Painting

    func brushFrom(_ flags: Int, at o: Int) -> PlusBrush? {
        if flags & 0x8000 != 0 { return .solid(argb(d.u32(o))) }
        if case .brush(let b)? = objects[d.u32(o)] { return b }
        return nil
    }

    func pen(_ id: Int) -> PlusPen? { if case .pen(let pen)? = objects[id] { pen } else { nil } }

    func paint(_ brush: PlusBrush, t: VectorTransform) -> VectorPaint {
        switch brush {
        case .solid(let c), .approximated(let c): return .solid(c)
        case .linear(let rect, let c0, let c1, let bt, let stops):
            let m = bt.then(t)
            let from = m.apply(VectorPoint(Double(rect.minX), Double(rect.minY))), to = m.apply(VectorPoint(Double(rect.maxX), Double(rect.minY)))
            return .linear(from: from, to: to, stops: stops.isEmpty ? [GradientStop(offset: 0, colour: c0), GradientStop(offset: 1, colour: c1)] : stops)
        }
    }

    func fill(_ segs: [PathSegment], _ brush: PlusBrush?) {
        guard let brush, !segs.isEmpty else { return }
        let t = transform()
        p.emit(.path(segs.transformed(by: t), fill: paint(brush, t: t), stroke: nil, rule: .nonZero))
    }

    func stroke(_ segs: [PathSegment], _ pen: PlusPen) {
        guard !segs.isEmpty else { return }
        let t = transform()
        let width = max(pen.width * t.lengthScale, 1)
        var colourPaint = paint(pen.brush, t: t)
        if case .linear(_, _, let stops) = colourPaint, let c = stops.first?.colour { colourPaint = .solid(c) }
        p.emit(.path(segs.transformed(by: t), fill: nil,
                     stroke: VectorStroke(paint: colourPaint, width: width, dash: pen.dash.map { $0 * width }, cap: pen.cap, join: pen.join, miterLimit: pen.miter), rule: .nonZero))
    }

    // MARK: Clip

    func clip(_ segs: [PathSegment], mode: Int, deviceSpace: Bool = false) {
        let device = deviceSpace ? segs : segs.transformed(by: transform())
        switch mode {
        case 1: p.intersectClip(device)
        case 4:
            p.intersectClip(rectOuter() + device.reversedPolygon())
        default:
            if mode != 0 { p.note(.otherLoss, "A clip combination was approximated.") }
            p.resetClip(); p.intersectClip(device)
        }
    }

    func rectOuter() -> [PathSegment] { PathBuilder.rect(x: Double(p.deviceBounds.minX), y: Double(p.deviceBounds.minY), width: Double(p.deviceBounds.width), height: Double(p.deviceBounds.height)) }

    func clipRegion(_ shape: RegionShape, mode: Int) {
        switch shape {
        case .infinite: if mode == 0 { p.resetClip() }
        case .empty: p.intersectClip([])
        case .rect(let r): clip(rectPath(r), mode: mode)
        case .path(let s): clip(s, mode: mode)
        case .and(let a, let b): clipRegion(a, mode: mode); clipRegion(b, mode: 1)
        case .other(let first): p.note(.otherLoss, "A clip combination was approximated."); clipRegion(first, mode: mode)
        }
    }

    // MARK: Objects

    func object(_ flags: Int, _ o: Int, _ end: Int) {
        let id = flags & 0xFF, type = (flags >> 8) & 0x7F
        var data = d.slice(o, end - o)
        if flags & 0x8000 != 0 {
            guard data.count >= 4 else { return }
            let total = ByteReader(bytes: data).u32(0)
            var entry = partial[id] ?? (type, total, [])
            entry.data += data.dropFirst(4)
            if entry.data.count < min(total, 1 << 28) { partial[id] = entry; return }
            partial[id] = nil
            data = entry.data
        }
        let r = ByteReader(bytes: data)
        switch type {
        case 1: if let b = brush(r, 0) { objects[id] = .brush(b.0) }
        case 2: if let pen = penObject(r) { objects[id] = .pen(pen) }
        case 3: objects[id] = .path(pathObject(r))
        case 4: if let shape = region(r, 8, count: r.u32(4)) { objects[id] = .region(shape.0) }
        case 5: if let image = imageObject(r) { objects[id] = .image(image) } else { p.note(.imagesDropped, "A picture in an unsupported format was not drawn.") }
        case 6:
            let length = r.u32(24)
            guard length >= 0, length <= 256 else { return }
            let style = r.u32(12)
            objects[id] = .font(PlusFont(family: r.utf16(28, chars: length, terminated: true), em: r.f32(4), unit: r.u32(8), bold: style & 1 != 0, italic: style & 2 != 0))
        default: objects[id] = .other
        }
    }

    func colour(_ r: ByteReader, _ o: Int) -> VectorColour { argb(r.u32(o)) }

    func brush(_ r: ByteReader, _ o: Int) -> (PlusBrush, Int)? {
        let kind = r.u32(o + 4)
        switch kind {
        case 0: return (.solid(colour(r, o + 8)), o + 12)
        case 1: // hatch: foreground, background
            let f = colour(r, o + 12), b = colour(r, o + 16)
            p.note(.otherLoss, "Hatched fills were drawn as tints.")
            return (.approximated(VectorColour(red: (f.red + b.red) / 2, green: (f.green + b.green) / 2, blue: (f.blue + b.blue) / 2)), o + 20)
        case 4:
            let flags = r.u32(o + 8)
            let rect = CGRect(x: r.f32(o + 16), y: r.f32(o + 20), width: r.f32(o + 24), height: r.f32(o + 28))
            let c0 = colour(r, o + 32), c1 = colour(r, o + 36)
            var at = o + 48
            var bt = VectorTransform.identity
            if flags & 2 != 0 { bt = VectorTransform(a: r.f32(at), b: r.f32(at + 4), c: r.f32(at + 8), d: r.f32(at + 12), tx: r.f32(at + 16), ty: r.f32(at + 20)); at += 24 }
            var stops: [GradientStop] = []
            if flags & 8 != 0 {
                let n = r.u32(at)
                if n > 0, n <= 256 { for i in 0..<n {
                    let pos = r.f32(at + 4 + i * 4), f = r.f32(at + 4 + n * 4 + i * 4)
                    stops.append(GradientStop(offset: pos, colour: VectorColour(red: c0.red + (c1.red - c0.red) * f, green: c0.green + (c1.green - c0.green) * f,
                                                                                 blue: c0.blue + (c1.blue - c0.blue) * f, alpha: c0.alpha + (c1.alpha - c0.alpha) * f)))
                } }
                at += 4 + n * 8
            } else if flags & 4 != 0 {
                let n = r.u32(at)
                if n > 0, n <= 256 { for i in 0..<n { stops.append(GradientStop(offset: r.f32(at + 4 + i * 4), colour: colour(r, at + 4 + n * 4 + i * 4))) } }
                at += 4 + n * 8
            }
            return (.linear(rect: rect, c0: c0, c1: c1, transform: bt, stops: stops), at)
        case 3:
            p.note(.shadingRasterised, "A path gradient was drawn as its centre colour.")
            return (.approximated(colour(r, o + 16)), o + 20)
        default:
            p.note(.otherLoss, "A texture brush was drawn as one colour.")
            return (.approximated(.black), o + 8)
        }
    }

    func penObject(_ r: ByteReader) -> PlusPen? {
        let flags = r.u32(12)
        var at = 24
        var cap = LineCap.butt, join = LineJoin.miter, miter = 10.0
        var dash: [Double] = []
        if flags & 1 != 0 { at += 24 }
        if flags & 2 != 0 { cap = [LineCap.butt, .square, .round, .round][max(0, min(3, r.u32(at)))]; at += 4 }
        if flags & 4 != 0 { at += 4 }
        if flags & 8 != 0 { join = [LineJoin.miter, .bevel, .round, .miter][max(0, min(3, r.u32(at)))]; at += 4 }
        if flags & 0x10 != 0 { miter = r.f32(at); at += 4 }
        if flags & 0x20 != 0 {
            switch r.u32(at) { case 1: dash = [3, 1]; case 2: dash = [1, 1]; case 3: dash = [3, 1, 1, 1]; case 4: dash = [3, 1, 1, 1, 1, 1]; default: break }
            at += 4
        }
        if flags & 0x40 != 0 { at += 4 }
        if flags & 0x80 != 0 { at += 4 }
        if flags & 0x100 != 0 {
            let n = r.u32(at)
            guard n >= 0, n <= 64 else { return nil }
            dash = (0..<n).map { max(r.f32(at + 4 + $0 * 4), 0.01) }
            at += 4 + n * 4
        }
        if flags & 0x200 != 0 { at += 4 }
        if flags & 0x400 != 0 { at += 4 + r.u32(at) * 4 }
        if flags & 0x800 != 0 { at += 4 + r.u32(at) }
        if flags & 0x1000 != 0 { at += 4 + r.u32(at) }
        guard let (b, _) = brush(r, at) else { return nil }
        return PlusPen(width: r.f32(20), brush: b, cap: cap, join: join, miter: miter, dash: dash)
    }

    func pathObject(_ r: ByteReader) -> [PathSegment] {
        let n = r.u32(4), flags = r.u32(8)
        let compressed = flags & 0x4000 != 0
        let each = compressed ? 4 : 8
        guard n > 0, n <= (r.count - 12) / (each + 1) else { return [] }
        let types = 12 + n * each
        var segs: [PathSegment] = []
        var pending: [VectorPoint] = []
        for i in 0..<n {
            let pt = compressed ? VectorPoint(Double(r.i16(12 + i * 4)), Double(r.i16(14 + i * 4))) : VectorPoint(r.f32(12 + i * 8), r.f32(16 + i * 8))
            let t = r.u8(types + i)
            switch t & 0xF {
            case 0: segs.append(.move(pt)); pending = []
            case 1: segs.append(.line(pt))
            case 3:
                pending.append(pt)
                if pending.count == 3 { segs.append(.cubic(pending[0], pending[1], pending[2])); pending = [] }
            default: break
            }
            if t & 0x80 != 0 { segs.append(.close) }
        }
        return segs
    }

    func region(_ r: ByteReader, _ o: Int, count: Int) -> (RegionShape, Int)? {
        guard r.has(o, 4) else { return nil }
        let type = r.u32(o)
        switch type {
        case 0x10000000: return (.rect(CGRect(x: r.f32(o + 4), y: r.f32(o + 8), width: r.f32(o + 12), height: r.f32(o + 16))), o + 20)
        case 0x10000001:
            let size = r.u32(o + 4)
            guard size >= 12, r.has(o + 8, size) else { return nil }
            return (.path(pathObject(ByteReader(bytes: r.slice(o + 8, size)))), o + 8 + size)
        case 0x10000002: return (.empty, o + 4)
        case 0x10000003: return (.infinite, o + 4)
        case 0...4:
            guard let (a, next) = region(r, o + 4, count: 0), let (b, end) = region(r, next, count: 0) else { return nil }
            return (type == 0 ? .and(a, b) : .other(a), end)
        default: return nil
        }
    }

    func imageObject(_ r: ByteReader) -> ImageAsset? {
        guard r.u32(4) == 1 else { return nil }
        let w = r.i32(8), h = r.i32(12), stride = r.i32(16), format = r.u32(20), kind = r.u32(24)
        if kind == 1 { return ImageBridge.asset(decoding: Data(r.slice(28, r.count - 28))) }
        guard w > 0, h > 0, w * h <= 40_000_000, stride >= 0 else { return nil }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        var hasAlpha = false
        let bits = 28
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                switch format {
                case 0x26200A, 0x000E200B, 0x00022009:
                    let src = bits + y * stride + x * 4
                    var a = format == 0x00022009 ? 255 : r.u8(src + 3)
                    var cr = r.u8(src + 2), cg = r.u8(src + 1), cb = r.u8(src)
                    if format == 0x000E200B, a > 0, a < 255 { cr = min(255, cr * 255 / a); cg = min(255, cg * 255 / a); cb = min(255, cb * 255 / a) }
                    if a != 255 { hasAlpha = true }
                    if !r.has(src, 4) { a = 255 }
                    out[o] = UInt8(cr); out[o + 1] = UInt8(cg); out[o + 2] = UInt8(cb); out[o + 3] = UInt8(a)
                case 0x00021808:
                    let src = bits + y * stride + x * 3
                    out[o] = UInt8(r.u8(src + 2)); out[o + 1] = UInt8(r.u8(src + 1)); out[o + 2] = UInt8(r.u8(src))
                default: return nil
                }
            }
        }
        return ImageAsset(frames: [ImageFrame(width: w, height: h, pixels: .rgba8(Data(out), bytesPerRow: w * 4), hasAlpha: hasAlpha)])
    }

    // MARK: Pictures and text

    func drawImage(_ flags: Int, _ o: Int, _ end: Int) {
        guard case .image(let asset)? = objects[flags & 0xFF], let frame = asset.frames.first else { return }
        let src = rectF(o + 8)
        let dest = flags & 0x4000 != 0 ? rectI(o + 24) : rectF(o + 24)
        place(asset, frame: frame, src: src, ul: VectorPoint(Double(dest.minX), Double(dest.minY)), ur: VectorPoint(Double(dest.maxX), Double(dest.minY)), ll: VectorPoint(Double(dest.minX), Double(dest.maxY)))
    }

    func drawImagePoints(_ flags: Int, _ o: Int, _ end: Int) {
        guard case .image(let asset)? = objects[flags & 0xFF], let frame = asset.frames.first else { return }
        let src = rectF(o + 8)
        let pts = points(o + 28, 3, compressed: flags & 0x4000 != 0, end: end)
        guard pts.count == 3 else { return }
        place(asset, frame: frame, src: src, ul: pts[0], ur: pts[1], ll: pts[2])
    }

    func place(_ asset: ImageAsset, frame: ImageFrame, src: CGRect, ul: VectorPoint, ur: VectorPoint, ll: VectorPoint) {
        var u0 = 0.0, v0 = 0.0, u1 = 1.0, v1 = 1.0
        let w = Double(frame.width), h = Double(frame.height)
        if src.width > 0, src.height > 0, !(src.minX <= 0 && src.minY <= 0 && src.maxX >= w && src.maxY >= h) {
            // Crop through a clip on the unit square: keep the whole bitmap and clip to the source window.
            u0 = max(0, Double(src.minX) / w); u1 = min(1, Double(src.maxX) / w); v0 = max(0, Double(src.minY) / h); v1 = min(1, Double(src.maxY) / h)
            if u1 <= u0 || v1 <= v0 { return }
        }
        // Map the source window onto the destination parallelogram: image space (u right, v down) → destination.
        let ex = VectorPoint((ur.x - ul.x) / (u1 - u0), (ur.y - ul.y) / (u1 - u0)), ey = VectorPoint((ll.x - ul.x) / (v1 - v0), (ll.y - ul.y) / (v1 - v0))
        let origin = VectorPoint(ul.x - ex.x * u0 - ey.x * v0, ul.y - ex.y * u0 - ey.y * v0)
        // Unit square has v up: image row v (down) = 1 - vUp.
        let m = VectorTransform(a: ex.x, b: ex.y, c: -ey.x, d: -ey.y, tx: origin.x + ey.x, ty: origin.y + ey.y)
        let t = transform()
        var node = VectorNode.image(asset, transform: m.then(t))
        if u0 > 0 || v0 > 0 || u1 < 1 || v1 < 1 {
            let window = [VectorPoint(u0, v0), VectorPoint(u1, v0), VectorPoint(u1, v1), VectorPoint(u0, v1)].map { q in
                VectorPoint(origin.x + ex.x * q.x + ey.x * q.y, origin.y + ex.y * q.x + ey.y * q.y)
            }
            node = .group([node], transform: .identity, clip: [.move(window[0]), .line(window[1]), .line(window[2]), .line(window[3]), .close].transformed(by: t), opacity: 1)
        }
        p.emit(node)
    }

    func drawString(_ flags: Int, _ o: Int, _ end: Int) {
        guard case .font(let font)? = objects[flags & 0xFF] else { return }
        let brush = flags & 0x8000 != 0 ? PlusBrush.solid(argb(d.u32(o))) : { if case .brush(let b)? = objects[d.u32(o)] { return b }; return PlusBrush.solid(.black) }()
        let n = d.u32(o + 8)
        guard n > 0, n <= 100_000, d.has(o + 28, n * 2) else { return }
        let text = d.utf16(o + 28, chars: n)
        let layout = rectF(o + 12)
        let t = transform()
        var em = font.em
        let f = unitFactor(font.unit)
        let deviceEm: Double
        switch font.unit {
        case 0, 2: deviceEm = em * t.lengthScale
        default: em *= f.1; deviceEm = em
        }
        guard deviceEm > 0.01 else { return }
        let name = GDIFontNames.postScriptName(families: font.family, bold: font.bold, italic: font.italic)
        let ct = VectorRenderer.font(named: name, size: deviceEm)
        let origin = t.apply(VectorPoint(Double(layout.minX), Double(layout.minY)))
        let angle = atan2(t.b, t.a)
        let ascent = Double(CTFontGetAscent(ct))
        let base = VectorPoint(origin.x - sin(angle) * ascent, origin.y + cos(angle) * ascent)
        let place = VectorTransform.scale(1, -1).then(VectorTransform(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle), tx: 0, ty: 0)).then(.translation(base.x, base.y))
        var fill = VectorPaint.solid(.black)
        if case .solid(let c) = brush { fill = .solid(c) } else if case .approximated(let c) = brush { fill = .solid(c) } else if case .linear(_, let c0, _, _, _) = brush { fill = .solid(c0) }
        p.emit(.group([.text(VectorTextRun(text: text, fontName: name, size: deviceEm, origin: VectorPoint(0, 0), fill: fill))], transform: place, clip: nil, opacity: 1))
    }
}

extension Array where Element == PathSegment {
    /// The polygon written in the opposite direction (a hole under the nonzero rule).
    func reversedPolygon() -> [PathSegment] {
        var pts: [VectorPoint] = []
        for s in self { switch s { case .move(let p), .line(let p): pts.append(p); default: break } }
        guard pts.count > 1 else { return self }
        var rev: [VectorPoint] = []
        for q in pts.reversed() { rev.append(q) }
        var out: [PathSegment] = [.move(rev[0])]
        for q in rev.dropFirst() { out.append(.line(q)) }
        out.append(.close)
        return out
    }
}
