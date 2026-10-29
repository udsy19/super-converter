import CoreGraphics
import Foundation
import SuperConverterCore

/// VectorDocument → Enhanced Metafile (formats §3.2, MS-EMF): one page as paths in path brackets (poly-Béziers, geometric
/// pens with caps, joins, miter limits and dashes, solid brushes, fill modes), clips through SELECTCLIPPATH inside
/// SAVEDC/RESTOREDC, linear gradients as GRADIENTFILL bands under a rotated world transform, text as EXTTEXTOUTW with its
/// font, pictures as STRETCHDIBITS (ALPHABLEND when they have alpha). Radial gradients, see-through colours and groups
/// with opacity become pictures of just that object (quality §6).
public enum EMFWriter {
    public static func write(_ document: VectorDocument, options: VectorWriteOptions) throws -> VectorWriteResult {
        guard var page = document.pages.first else { throw ConversionError.failed("There are no pages to write.") }
        var notes: Set<LossNote> = []
        if options.textAsOutlines, page.nodes.contains(where: \.containsText) {
            page.nodes = page.nodes.map(VectorOutlines.convert)
            notes.insert(LossNote(.textAsOutlines))
        }
        let canvas = EMFCanvas(size: page.size)
        var painter = MetafilePainter(page: page, density: options.density, canvas: canvas)
        painter.paint()
        notes.formUnion(painter.lossNotes); notes.formUnion(canvas.lossNotes)
        return VectorWriteResult(data: canvas.finish(), lossNotes: notes.sorted { $0.detail < $1.detail })
    }
}

/// The record stream of one EMF page. Logical units are 1/100 pt, y down from the top of the page; MM_ANISOTROPIC with a
/// window of 75 and a viewport of 1 maps them exactly onto a 96-dpi reference device.
final class EMFCanvas: MetafileCanvas {
    static let unitsPerPoint = 100.0
    /// Reference device (EMR_HEADER szlDevice / szlMillimeters): exactly 96 pixels per inch.
    static let devicePixels = 960, deviceMillimetres = 254

    let size: VectorSize
    private var body = ByteWriter()
    private var records = 0
    private let objects = GDIObjects(firstHandle: 1)
    private(set) var lossNotes: Set<LossNote> = []
    let keepsAlpha = true

    init(size: VectorSize) {
        self.size = size
        record(17) { $0.u32(8) }                       // EMR_SETMAPMODE MM_ANISOTROPIC
        record(9) { $0.i32(75); $0.i32(75) }           // EMR_SETWINDOWEXTEX
        record(11) { $0.i32(1); $0.i32(1) }            // EMR_SETVIEWPORTEXTEX
        record(18) { $0.u32(1) }                       // EMR_SETBKMODE TRANSPARENT
        record(22) { $0.u32(24) }                      // EMR_SETTEXTALIGN TA_BASELINE | TA_LEFT
    }

    // MARK: Records

    /// One record: type, size, the body `fill` writes, padded to four bytes (MS-EMF 2.3).
    private func record(_ type: Int, _ fill: (inout ByteWriter) -> Void) {
        var r = ByteWriter()
        r.u32(type); r.u32(0)
        fill(&r)
        r.pad4()
        r.set32(4, r.count)
        body.append(r.bytes)
        records += 1
    }

    /// The page in device pixels, inclusive, as the records' bounds (readers use them only to cull).
    private var deviceBounds: (Int, Int, Int, Int) {
        (0, 0, max(0, Int((size.width * 96 / 72).rounded(.up)) - 1), max(0, Int((size.height * 96 / 72).rounded(.up)) - 1))
    }

    private func bounds(_ w: inout ByteWriter) {
        let b = deviceBounds
        w.i32(b.0); w.i32(b.1); w.i32(b.2); w.i32(b.3)
    }

    /// Page points → logical units.
    private func logical(_ p: VectorPoint) -> (Double, Double) { (p.x * Self.unitsPerPoint, (size.height - p.y) * Self.unitsPerPoint) }
    private func int(_ v: Double) -> Int { Int(max(-2_000_000_000, min(2_000_000_000, v.rounded()))) }

    /// Page points (y up) → logical units (y down).
    private var toLogical: VectorTransform { VectorTransform(a: Self.unitsPerPoint, b: 0, c: 0, d: -Self.unitsPerPoint, tx: 0, ty: size.height * Self.unitsPerPoint) }

    private func saveDC() { record(33) { _ in }; objects.save() }
    private func restoreDC() { record(34) { $0.i32(-1) }; objects.restore(delete: deleteObject) }
    private func deleteObject(_ h: Int) { record(40) { $0.u32(h) } }
    private func selectObject(_ h: Int) { record(37) { $0.u32(h) } }

    /// EMR_MODIFYWORLDTRANSFORM MWT_LEFTMULTIPLY: `t` maps the coordinates that follow into the current logical space.
    private func leftMultiply(_ t: VectorTransform) {
        record(36) { w in for v in [t.a, t.b, t.c, t.d, t.tx, t.ty] { w.f32(v) }; w.u32(2) }
    }

    // MARK: What EMF holds

    func canFill(_ paint: VectorPaint) -> Bool {
        if paint.opaqueColour != nil { return true }
        if case .linear(_, _, let stops) = paint { return !stops.isEmpty && stops.allSatisfy { $0.colour.alpha >= 0.999 } }
        return false
    }

    func canStroke(_ stroke: VectorStroke) -> Bool { stroke.paint.opaqueColour != nil }
    func canDraw(_ run: VectorTextRun, transform: VectorTransform) -> Bool { run.fill.opaqueColour != nil && transform.inverted != nil }
    func canDraw(_ asset: ImageAsset, transform: VectorTransform) -> Bool { !asset.frames.isEmpty && transform.inverted != nil }

    // MARK: Clips

    func canClip(_ segments: [PathSegment]) -> Bool { true }

    func pushClip(_ segments: [PathSegment]) {
        saveDC()
        objects.set("fill", 2) { record(19) { $0.u32(2) } }   // the model clips with the nonzero rule
        writePath(segments)
        record(67) { $0.u32(1) }                                // EMR_SELECTCLIPPATH RGN_AND
    }

    func popClip() { restoreDC() }

    // MARK: Paths

    func path(_ segments: [PathSegment], fill: VectorPaint?, stroke: VectorStroke?, rule: FillRule) {
        if case .linear(let from, let to, let stops)? = fill {
            gradient(segments, from: from, to: to, stops: stops, rule: rule)
            if let stroke { path(segments, fill: nil, stroke: stroke, rule: rule) }
            return
        }
        let colour = fill?.opaqueColour
        if let colour {
            objects.select(.brush, key: "brush \(colour.colorref)", create: { h in
                record(39) { $0.u32(h); $0.u32(0); $0.u32(colour.colorref); $0.u32(0) }   // EMR_CREATEBRUSHINDIRECT BS_SOLID
            }, select: selectObject, delete: deleteObject)
        } else {
            objects.select(.brush, key: "brush none", stock: 0x8000_0005, create: { _ in }, select: selectObject, delete: deleteObject)
        }
        selectPen(stroke)
        objects.set("fill", rule == .evenOdd ? 1 : 2) { record(19) { $0.u32(rule == .evenOdd ? 1 : 2) } }
        writePath(segments)
        let type = colour != nil && stroke != nil ? 63 : colour != nil ? 62 : 64   // STROKEANDFILLPATH / FILLPATH / STROKEPATH
        record(type) { bounds(&$0) }
    }

    /// EMR_EXTCREATEPEN: a geometric pen with the stroke's width, caps, joins and dashes (user style), in logical units.
    private func selectPen(_ stroke: VectorStroke?) {
        guard let stroke, let colour = stroke.paint.opaqueColour else {
            objects.select(.pen, key: "pen none", stock: 0x8000_0008, create: { _ in }, select: selectObject, delete: deleteObject)
            return
        }
        let width = max(1, int(stroke.width * Self.unitsPerPoint))
        var dash = stroke.dash.map { max(1, int($0 * Self.unitsPerPoint)) }
        if dash.count % 2 == 1 { dash += dash }   // an odd pattern repeats, as SVG and PDF define it
        if dash.allSatisfy({ $0 <= 0 }) { dash = [] }
        if !dash.isEmpty, stroke.dashPhase != 0 { lossNotes.insert(LossNote(.otherLoss, detail: "Dash offsets were dropped.")) }
        let cap = stroke.cap == .round ? 0 : stroke.cap == .square ? 0x100 : 0x200
        let join = stroke.join == .round ? 0 : stroke.join == .bevel ? 0x1000 : 0x2000
        let style = 0x10000 | cap | join | (dash.isEmpty ? 0 : 7)
        objects.select(.pen, key: "pen \(style) \(width) \(colour.colorref) \(dash)", create: { h in
            record(95) { w in
                w.u32(h); w.u32(0); w.u32(0); w.u32(0); w.u32(0)
                w.u32(style); w.u32(width); w.u32(0); w.u32(colour.colorref); w.u32(0)
                w.u32(dash.count); for d in dash { w.u32(d) }
            }
        }, select: selectObject, delete: deleteObject)
        if stroke.join == .miter { objects.set("miter", max(1, Int(stroke.miterLimit.rounded()))) { record(58) { $0.u32(max(1, Int(stroke.miterLimit.rounded()))) } } }
    }

    /// BEGINPATH, the figures (MOVETOEX, POLYLINETO, POLYBEZIERTO, CLOSEFIGURE), ENDPATH.
    private func writePath(_ segments: [PathSegment]) {
        record(59) { _ in }
        var current: VectorPoint?, start: VectorPoint?
        var run: [VectorPoint] = [], runIsCurve = false
        func flush() {
            guard !run.isEmpty else { return }
            let pts = run.map(logical)
            let small = pts.allSatisfy { abs($0.0) < 32767 && abs($0.1) < 32767 }
            let type = runIsCurve ? (small ? 88 : 5) : (small ? 89 : 6)
            record(type) { w in
                bounds(&w); w.u32(pts.count)
                for p in pts { if small { w.u16(int(p.0)); w.u16(int(p.1)) } else { w.i32(int(p.0)); w.i32(int(p.1)) } }
            }
            run = []
        }
        func moveTo(_ p: VectorPoint) {
            flush()
            let l = logical(p)
            record(27) { $0.i32(int(l.0)); $0.i32(int(l.1)) }
            current = p; start = p
        }
        func add(_ pts: [VectorPoint], curve: Bool) {
            if current == nil, let first = pts.first { moveTo(first) }
            if runIsCurve != curve { flush(); runIsCurve = curve }
            run += pts; current = pts.last
        }
        var closed = false
        for segment in segments {
            // After a close the figure's start is current; anything but a move draws on from there.
            if closed, let start { if case .move = segment {} else { moveTo(start) } }
            closed = false
            switch segment {
            case .move(let p): moveTo(p)
            case .line(let p):
                if current == nil { moveTo(p) } else { add([p], curve: false) }
            case .cubic(let a, let b, let c): add([a, b, c], curve: true)
            case .quad(let c, let e):
                let s = current ?? c
                add([VectorPoint(s.x + 2 / 3 * (c.x - s.x), s.y + 2 / 3 * (c.y - s.y)), VectorPoint(e.x + 2 / 3 * (c.x - e.x), e.y + 2 / 3 * (c.y - e.y)), e], curve: true)
            case .close:
                guard current != nil else { continue }
                flush()
                record(61) { _ in }
                closed = true
            }
        }
        flush()
        record(60) { _ in }
    }

    // MARK: Gradients

    /// A linear gradient fill: the shape becomes the clip, the world turns so the gradient runs along x, and GRADIENTFILL
    /// paints one band per pair of stops plus the padded ends (MS-EMF 2.3.5.12, GRADIENT_FILL_RECT_H).
    private func gradient(_ segments: [PathSegment], from: VectorPoint, to: VectorPoint, stops unsorted: [GradientStop], rule: FillRule) {
        let stops = unsorted.sorted { $0.offset < $1.offset }
        guard let firstStop = stops.first, let lastStop = stops.last, let box = segments.controlBounds else { return }
        saveDC()
        objects.set("fill", rule == .evenOdd ? 1 : 2) { record(19) { $0.u32(rule == .evenOdd ? 1 : 2) } }
        writePath(segments)
        record(67) { $0.u32(1) }
        let f = logical(from), t = logical(to)
        let dx = t.0 - f.0, dy = t.1 - f.1, length = (dx * dx + dy * dy).squareRoot()
        let (cosA, sinA) = length > 1e-9 ? (dx / length, dy / length) : (1.0, 0.0)
        // Gradient frame (u along the ramp from its start, v across) → logical.
        let frame = VectorTransform(a: cosA, b: sinA, c: -sinA, d: cosA, tx: f.0, ty: f.1)
        leftMultiply(frame)
        let inverse = frame.inverted ?? .identity
        let corners = [VectorPoint(Double(box.minX), Double(box.minY)), VectorPoint(Double(box.maxX), Double(box.minY)),
                       VectorPoint(Double(box.maxX), Double(box.maxY)), VectorPoint(Double(box.minX), Double(box.maxY))]
            .map { p -> VectorPoint in let l = logical(p); return inverse.apply(VectorPoint(l.0, l.1)) }
        let minU = (corners.map(\.x).min() ?? 0).rounded(.down) - 1, maxU = (corners.map(\.x).max() ?? 0).rounded(.up) + 1
        let minV = (corners.map(\.y).min() ?? 0).rounded(.down) - 1, maxV = (corners.map(\.y).max() ?? 0).rounded(.up) + 1
        var bands: [(Double, Double, VectorColour, VectorColour)] = []
        let at = stops.map { max(0, min(1, $0.offset)) * length }
        if length <= 1e-9 { bands.append((minU, maxU, lastStop.colour, lastStop.colour)) } else {
            if minU < at[0] { bands.append((minU, at[0], firstStop.colour, firstStop.colour)) }
            for i in 0..<(stops.count - 1) where at[i + 1] > at[i] && at[i + 1] > minU && at[i] < maxU {
                bands.append((at[i], at[i + 1], stops[i].colour, stops[i + 1].colour))
            }
            if maxU > at[at.count - 1] { bands.append((at[at.count - 1], maxU, lastStop.colour, lastStop.colour)) }
        }
        record(118) { w in
            bounds(&w); w.u32(bands.count * 2); w.u32(bands.count); w.u32(0)
            func vertex(_ x: Double, _ y: Double, _ c: VectorColour) {
                w.i32(int(x)); w.i32(int(y))
                for v in [c.red, c.green, c.blue] { w.u16(Int((max(0, min(1, v)) * 65280).rounded())) }
                w.u16(0)
            }
            for band in bands { vertex(band.0, minV, band.2); vertex(band.1, maxV, band.3) }
            for i in 0..<bands.count { w.u32(2 * i); w.u32(2 * i + 1) }
        }
        restoreDC()
    }

    // MARK: Text

    /// EXTTEXTOUTW at the baseline with per-character advances; a turned, scaled or slanted run is drawn under a world
    /// transform so it keeps its shape.
    func text(_ run: VectorTextRun, transform m: VectorTransform) {
        guard let colour = run.fill.opaqueColour else { return }
        if let note = MetafileText.embeddedFontNote(run) { lossNotes.insert(note) }
        let k = Self.unitsPerPoint
        // Text space: logical units of the run's own font, y down, origin at the run's origin.
        let local = VectorTransform(a: 1 / k, b: 0, c: 0, d: -1 / k, tx: run.origin.x, ty: run.origin.y)
        let a = local.then(m).then(toLogical)
        let plain = abs(a.a - 1) < 1e-6 && abs(a.d - 1) < 1e-6 && abs(a.b) < 1e-6 && abs(a.c) < 1e-6
        if !plain { saveDC(); leftMultiply(VectorTransform(a: a.a, b: a.b, c: a.c, d: a.d, tx: a.tx, ty: a.ty)) }
        let face = MetafileText.face(run)
        let height = max(1, int(run.size * k))
        objects.select(.font, key: "font \(face.family) \(face.bold) \(face.italic) \(height)", create: { h in
            record(82) { w in
                w.u32(h)
                w.i32(-height); w.i32(0); w.i32(0); w.i32(0); w.i32(face.bold ? 700 : 400)
                w.u8(face.italic ? 1 : 0); w.u8(0); w.u8(0); w.u8(1)   // italic, underline, strike-out, DEFAULT_CHARSET
                w.u8(0); w.u8(0); w.u8(4); w.u8(0)                     // precision, clipping, ANTIALIASED_QUALITY, pitch
                let name = Array(face.family.utf16.prefix(31))
                for i in 0..<32 { w.u16(i < name.count ? Int(name[i]) : 0) }
            }
        }, select: selectObject, delete: deleteObject)
        objects.set("textColour", colour.colorref) { record(24) { $0.u32(colour.colorref) } }
        let units = Array(run.text.utf16)
        let dx = MetafileText.integerAdvances(MetafileText.advances(run), scale: k)
        let ref = plain ? (int(a.tx), int(a.ty)) : (0, 0)
        record(84) { w in
            bounds(&w); w.u32(plain ? 1 : 2); w.f32(0); w.f32(0)
            w.i32(ref.0); w.i32(ref.1); w.u32(units.count); w.u32(76); w.u32(0)
            w.i32(0); w.i32(0); w.i32(-1); w.i32(-1)
            let dxAt = 76 + ((units.count * 2 + 3) & ~3)
            w.u32(dxAt)
            for u in units { w.u16(Int(u)) }
            w.pad4()
            for d in dx { w.i32(d) }
        }
        if !plain { restoreDC() }
    }

    // MARK: Pictures

    /// STRETCHDIBITS, or ALPHABLEND with a premultiplied 32-bit DIB when the picture has alpha; a picture that is not
    /// upright and unflipped is placed by a world transform.
    func image(_ asset: ImageAsset, transform m: VectorTransform) {
        let alpha = asset.hasAlpha
        guard let dib = MetafileDIB.encode(asset, alpha: alpha) else { return }
        let iw = Double(dib.width), ih = Double(dib.height)
        // Pixels (y down from the top row) → the unit square (y up) → page → logical.
        let pixels = VectorTransform(a: 1 / iw, b: 0, c: 0, d: -1 / ih, tx: 0, ty: 1)
        let a = pixels.then(m).then(toLogical)
        let upright = abs(a.b) < 1e-9 && abs(a.c) < 1e-9 && a.a > 0 && a.d > 0
        var dest = (x: 0, y: 0, w: dib.width, h: dib.height)
        if upright {
            let x0 = int(a.tx), y0 = int(a.ty)
            dest = (x0, y0, max(1, int(a.tx + a.a * iw) - x0), max(1, int(a.ty + a.d * ih) - y0))
        } else {
            saveDC(); leftMultiply(a)
        }
        if alpha {
            record(114) { w in
                bounds(&w); w.i32(dest.x); w.i32(dest.y); w.i32(dest.w); w.i32(dest.h)
                w.u8(0); w.u8(0); w.u8(255); w.u8(1)           // AC_SRC_OVER, constant alpha 255, AC_SRC_ALPHA
                w.i32(0); w.i32(0)
                for v in [1.0, 0, 0, 1, 0, 0] { w.f32(v) }
                w.u32(0); w.u32(0)
                w.u32(108); w.u32(dib.info.count); w.u32(108 + dib.info.count); w.u32(dib.bits.count)
                w.i32(dib.width); w.i32(dib.height)
                w.append(dib.info); w.append(dib.bits)
            }
        } else {
            record(81) { w in
                bounds(&w); w.i32(dest.x); w.i32(dest.y); w.i32(0); w.i32(0); w.i32(dib.width); w.i32(dib.height)
                w.u32(80); w.u32(dib.info.count); w.u32(80 + dib.info.count); w.u32(dib.bits.count)
                w.u32(0); w.u32(0x00CC_0020)                   // DIB_RGB_COLORS, SRCCOPY
                w.i32(dest.w); w.i32(dest.h)
                w.append(dib.info); w.append(dib.bits)
            }
        }
        if !upright { restoreDC() }
    }

    // MARK: Header and end

    /// EMR_HEADER (with the pixel-format and micrometre extensions), the records, EMR_EOF.
    func finish() -> Data {
        record(14) { $0.u32(0); $0.u32(16); $0.u32(20) }
        var h = ByteWriter()
        let b = deviceBounds
        let frameW = Int((size.width * 2540 / 72).rounded()), frameH = Int((size.height * 2540 / 72).rounded())
        h.u32(1); h.u32(108)
        h.i32(b.0); h.i32(b.1); h.i32(b.2); h.i32(b.3)
        h.i32(0); h.i32(0); h.i32(frameW); h.i32(frameH)
        h.u32(0x464D4520); h.u32(0x10000)
        h.u32(108 + body.count); h.u32(records + 1)
        h.u16(objects.tableSize); h.u16(0)
        h.u32(0); h.u32(0); h.u32(0)
        h.i32(Self.devicePixels); h.i32(Self.devicePixels); h.i32(Self.deviceMillimetres); h.i32(Self.deviceMillimetres)
        h.u32(0); h.u32(0); h.u32(0)
        h.i32(Self.deviceMillimetres * 1000); h.i32(Self.deviceMillimetres * 1000)
        return Data(h.bytes + body.bytes)
    }
}
