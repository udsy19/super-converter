import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore

/// The Windows GDI device context that EMF and WMF records drive: mapping modes, world transform, pens, brushes, fonts,
/// clipping, paths. It turns drawing calls into VectorNodes in device coordinates (y down); the readers wrap the result
/// in the transform that maps device units to points.
final class GDIPlayer {
    // MARK: Objects

    struct Pen {
        var visible = true
        var width = 0.0
        var colour = VectorColour.black
        var cap = LineCap.round
        var join = LineJoin.round
        var geometric = false
        var dash: [Double] = []
    }

    enum Brush {
        case none
        case solid(VectorColour)
        case approximated(VectorColour)
    }

    struct Font {
        var name = "Arial"
        var height = 0.0
        var escapement = 0.0
        var weight = 400
        var italic = false
    }

    enum Object {
        case pen(Pen)
        case brush(Brush)
        case font(Font)
        case region([CGRect])
        case other
    }

    // MARK: Device context

    struct DC {
        var mapMode = 1
        var windowOrg = CGPoint.zero, windowExt = CGSize(width: 1, height: 1)
        var viewportOrg = CGPoint.zero, viewportExt = CGSize(width: 1, height: 1)
        var world = VectorTransform.identity
        var pen = Pen(visible: true, width: 0, colour: .black, cap: .round, join: .round, geometric: false, dash: [])
        var brush = Brush.solid(.white)
        var font = Font()
        var textColour = VectorColour.black
        var bkColour = VectorColour.white
        var bkOpaque = false
        var fillRule = FillRule.evenOdd
        var textAlign = 0
        var current = CGPoint.zero
        var arcClockwise = false
        var miterLimit = 10.0
        var layerDepth = 1
    }

    struct Layer { var clip: [PathSegment]?; var nodes: [VectorNode] }

    var dc = DC()
    var saved: [DC] = []
    var objects: [Int: Object] = [:]
    var layers = [Layer(clip: nil, nodes: [])]
    var lossNotes: Set<LossNote> = []
    var warnings: [String] = []
    /// Device pixels per millimetre, for the fixed mapping modes (EMF header; WMF uses 1/25.4 of its units per inch).
    var pixelsPerMM = (x: 3.78, y: 3.78)
    /// WMF has no viewport mapping: logical units are the device units and the reader maps the window to the page.
    var usesPageMapping = true
    /// A rectangle in device units that bounds everything (for exclude-clip and region fills).
    var deviceBounds = CGRect(x: -100_000, y: -100_000, width: 200_000, height: 200_000)

    // Path bracket.
    var pathRecording = false
    var path: [PathSegment] = []
    var pendingLine: [PathSegment] = []
    var pendingPen: Pen?

    func note(_ kind: LossNote.Kind, _ detail: String) {
        lossNotes.insert(LossNote(kind, detail: detail))
        if !warnings.contains(detail) { warnings.append(detail) }
    }

    // MARK: Mapping

    /// Logical → device.
    func transform() -> VectorTransform {
        dc.world.then(pageTransform())
    }

    func pageTransform() -> VectorTransform {
        guard usesPageMapping else { return .identity }
        var sx = 1.0, sy = 1.0
        let mm = dc.mapMode
        switch mm {
        case 2: sx = pixelsPerMM.x * 0.1; sy = -pixelsPerMM.y * 0.1
        case 3: sx = pixelsPerMM.x * 0.01; sy = -pixelsPerMM.y * 0.01
        case 4: sx = pixelsPerMM.x * 0.254; sy = -pixelsPerMM.y * 0.254
        case 5: sx = pixelsPerMM.x * 0.0254; sy = -pixelsPerMM.y * 0.0254
        case 6: sx = pixelsPerMM.x * 25.4 / 1440; sy = -pixelsPerMM.y * 25.4 / 1440
        case 7, 8:
            let wx = dc.windowExt.width == 0 ? 1 : Double(dc.windowExt.width), wy = dc.windowExt.height == 0 ? 1 : Double(dc.windowExt.height)
            sx = Double(dc.viewportExt.width) / wx; sy = Double(dc.viewportExt.height) / wy
            if mm == 7 {
                let m = min(abs(sx), abs(sy))
                sx = sx < 0 ? -m : m; sy = sy < 0 ? -m : m
            }
        default: break
        }
        if !sx.isFinite || !sy.isFinite { sx = 1; sy = 1 }
        return VectorTransform(a: sx, b: 0, c: 0, d: sy, tx: Double(dc.viewportOrg.x) - Double(dc.windowOrg.x) * sx, ty: Double(dc.viewportOrg.y) - Double(dc.windowOrg.y) * sy)
    }

    func point(_ x: Double, _ y: Double) -> VectorPoint { transform().apply(VectorPoint(x, y)) }

    // MARK: Layers and clipping

    /// Set while an EMF+ stream is the authority, so the GDI duplicates in a dual-mode file are not drawn twice.
    var suppressDrawing = false

    func emit(_ node: VectorNode) { if !suppressDrawing { layers[layers.count - 1].nodes.append(node) } }

    func popLayer() {
        guard layers.count > 1 else { return }
        let top = layers.removeLast()
        if !top.nodes.isEmpty { layers[layers.count - 1].nodes.append(.group(top.nodes, transform: .identity, clip: top.clip, opacity: 1)) }
    }

    func saveDC() { dc.layerDepth = layers.count; saved.append(dc) }

    func restoreDC(_ relative: Int) {
        guard !saved.isEmpty else { return }
        var count = relative < 0 ? -relative : saved.count - relative + 1
        count = max(1, min(count, saved.count))
        var target = saved[saved.count - 1]
        for _ in 0..<count { target = saved.removeLast() }
        while layers.count > target.layerDepth { popLayer() }
        flushLine()
        dc = target
    }

    /// Clips to `segments` (device units) inside the current clip.
    func intersectClip(_ segments: [PathSegment]) {
        flushLine()
        layers.append(Layer(clip: segments, nodes: []))
    }

    func resetClip() {
        flushLine()
        while layers.count > 1 { popLayer() }
    }

    func intersectClipRect(_ r: CGRect) { intersectClip(rectSegments(r)) }

    func excludeClipRect(_ r: CGRect) {
        // The whole device with the rectangle cut out (opposite winding).
        let outer = rectSegments(deviceBounds)
        let hole = Array(rectSegments(r.standardized)).reversedRect()
        intersectClip(outer + hole)
    }

    func rectSegments(_ r: CGRect) -> [PathSegment] {
        let t = transform()
        let a = t.apply(VectorPoint(r.minX, r.minY)), b = t.apply(VectorPoint(r.maxX, r.minY)), c = t.apply(VectorPoint(r.maxX, r.maxY)), d = t.apply(VectorPoint(r.minX, r.maxY))
        return [.move(a), .line(b), .line(c), .line(d), .close]
    }

    // MARK: Painting

    func brushPaint() -> VectorPaint? {
        switch dc.brush {
        case .none: return nil
        case .solid(let c): return .solid(c)
        case .approximated(let c): return .solid(c)
        }
    }

    func strokeSpec() -> VectorStroke? {
        let p = dc.pen
        guard p.visible else { return nil }
        let scale = transform().lengthScale
        var width = p.geometric ? p.width * scale : 1.0
        if p.geometric, width < 1 { width = 1 }
        let base = max(width, 1)
        return VectorStroke(paint: .solid(p.colour), width: width, dash: p.dash.map { $0 * base }, dashPhase: 0,
                            cap: p.geometric ? p.cap : .butt, join: p.geometric ? p.join : .round, miterLimit: dc.miterLimit)
    }

    /// Paints device-space segments with the current brush and/or pen (or records them into an open path).
    func paint(_ segments: [PathSegment], fill: Bool, stroke: Bool) {
        if pathRecording { path.append(contentsOf: segments); return }
        flushLine()
        let f = fill ? brushPaint() : nil
        let s = stroke ? strokeSpec() : nil
        if f == nil, s == nil { return }
        emit(.path(segments, fill: f, stroke: s, rule: dc.fillRule))
    }

    /// A LINETO that continues the previous one extends one stroked path.
    func line(to p: CGPoint) {
        let from = dc.current
        dc.current = p
        let a = point(Double(from.x), Double(from.y)), b = point(Double(p.x), Double(p.y))
        if pathRecording {
            if path.isEmpty { path.append(.move(a)) }
            path.append(.line(b)); return
        }
        if let last = pendingLine.last, case .line(let end) = last, end == a, pendingPen != nil, samePen(pendingPen!, dc.pen) { pendingLine.append(.line(b)); return }
        flushLine()
        pendingLine = [.move(a), .line(b)]
        pendingPen = dc.pen
    }

    func samePen(_ a: Pen, _ b: Pen) -> Bool { a.width == b.width && a.colour == b.colour && a.visible == b.visible && a.dash == b.dash }

    func flushLine() {
        guard !pendingLine.isEmpty else { return }
        let saved = dc.pen
        if let p = pendingPen { dc.pen = p }
        let segs = pendingLine
        pendingLine = []; pendingPen = nil
        if let s = strokeSpec() { emit(.path(segs, fill: nil, stroke: s, rule: dc.fillRule)) }
        dc.pen = saved
    }

    func moveTo(_ p: CGPoint) {
        dc.current = p
        if pathRecording { path.append(.move(point(Double(p.x), Double(p.y)))) }
    }

    // MARK: Shapes

    func rectangle(_ r: CGRect) {
        let r = r.standardized
        paint(rectSegments(r), fill: true, stroke: true)
    }

    func ellipse(_ r: CGRect) {
        let r = r.standardized
        let segs = PathBuilder.ellipse(cx: Double(r.midX), cy: Double(r.midY), rx: Double(r.width) / 2, ry: Double(r.height) / 2).transformed(by: transform())
        paint(segs, fill: true, stroke: true)
    }

    func roundRect(_ r: CGRect, corner: CGSize) {
        let r = r.standardized
        let rx = min(abs(Double(corner.width)) / 2, Double(r.width) / 2), ry = min(abs(Double(corner.height)) / 2, Double(r.height) / 2)
        guard rx > 0, ry > 0 else { rectangle(r); return }
        let k = 0.5522847498307936
        let x0 = Double(r.minX), y0 = Double(r.minY), x1 = Double(r.maxX), y1 = Double(r.maxY)
        func p(_ x: Double, _ y: Double) -> VectorPoint { VectorPoint(x, y) }
        let segs: [PathSegment] = [
            .move(p(x0 + rx, y0)), .line(p(x1 - rx, y0)),
            .cubic(p(x1 - rx + k * rx, y0), p(x1, y0 + ry - k * ry), p(x1, y0 + ry)),
            .line(p(x1, y1 - ry)),
            .cubic(p(x1, y1 - ry + k * ry), p(x1 - rx + k * rx, y1), p(x1 - rx, y1)),
            .line(p(x0 + rx, y1)),
            .cubic(p(x0 + rx - k * rx, y1), p(x0, y1 - ry + k * ry), p(x0, y1 - ry)),
            .line(p(x0, y0 + ry)),
            .cubic(p(x0, y0 + ry - k * ry), p(x0 + rx - k * rx, y0), p(x0 + rx, y0)),
            .close,
        ]
        paint(segs.transformed(by: transform()), fill: true, stroke: true)
    }

    /// Elliptical arc segments (logical units) from parametric angle t1 sweeping `sweep` radians, in cubic pieces.
    static func arcSegments(cx: Double, cy: Double, rx: Double, ry: Double, t1: Double, sweep: Double) -> [PathSegment] {
        let n = max(1, Int(ceil(abs(sweep) / (.pi / 2) - 1e-9)))
        let step = sweep / Double(n)
        let k = 4.0 / 3.0 * tan(step / 4)
        var out: [PathSegment] = []
        var a = t1
        for _ in 0..<n {
            let b = a + step
            let c1 = cos(a), s1 = sin(a), c2 = cos(b), s2 = sin(b)
            out.append(.cubic(VectorPoint(cx + rx * (c1 - k * s1), cy + ry * (s1 + k * c1)), VectorPoint(cx + rx * (c2 + k * s2), cy + ry * (s2 - k * c2)), VectorPoint(cx + rx * c2, cy + ry * s2)))
            a = b
        }
        return out
    }

    enum ArcKind { case arc, chord, pie }

    /// ARC / CHORD / PIE: the box, and the two points whose rays from the centre mark the ends (drawn counterclockwise by default).
    func arcShape(_ box: CGRect, start: CGPoint, end: CGPoint, kind: ArcKind) {
        let r = box.standardized
        let cx = Double(r.midX), cy = Double(r.midY), rx = Double(r.width) / 2, ry = Double(r.height) / 2
        guard rx > 0, ry > 0 else { return }
        func angle(_ p: CGPoint) -> Double { atan2((Double(p.y) - cy) / ry, (Double(p.x) - cx) / rx) }
        let t1 = angle(start), t2 = angle(end)
        // Visually counterclockwise is increasing parametric angle only when the mapping flips y.
        let flips = transform().determinant < 0
        var increasing = (flips != dc.arcClockwise)
        var sweep = t2 - t1
        if increasing { while sweep <= 0 { sweep += 2 * .pi } } else { while sweep >= 0 { sweep -= 2 * .pi } }
        if abs(sweep) < 1e-9 { sweep = increasing ? 2 * .pi : -2 * .pi }
        increasing = sweep > 0
        let arc = Self.arcSegments(cx: cx, cy: cy, rx: rx, ry: ry, t1: t1, sweep: sweep)
        let startPoint = VectorPoint(cx + rx * cos(t1), cy + ry * sin(t1))
        var segs: [PathSegment]
        switch kind {
        case .arc: segs = [.move(startPoint)] + arc
        case .chord: segs = [.move(startPoint)] + arc + [.close]
        case .pie: segs = [.move(VectorPoint(cx, cy)), .line(startPoint)] + arc + [.close]
        }
        paint(segs.transformed(by: transform()), fill: kind != .arc, stroke: true)
    }

    // MARK: Text

    func fontSize(_ f: Font) -> Double {
        let scale = abs(transform().lengthScale)
        var h = abs(f.height)
        if h == 0 { h = 12 }
        // A positive height is the cell height (ascent + descent); the em is about 0.83 of it.
        let em = f.height > 0 ? h * 0.83 : h
        return em * scale
    }

    /// Draws `text` with its reference point at logical (x, y); `dx` are per-character advances in logical units.
    func text(_ text: String, x: Double, y: Double, dx: [Double], opaqueRect: CGRect?, clipRect: CGRect? = nil) {
        guard !text.isEmpty else { return }
        flushLine()
        let size = fontSize(dc.font)
        guard size > 0.01, size.isFinite else { return }
        let t = transform()
        var ref = VectorPoint(x, y)
        if dc.textAlign & 1 != 0 { ref = VectorPoint(Double(dc.current.x), Double(dc.current.y)) }
        let ct = VectorDrawing.font(named: GDIPlayer.fontName(dc.font), size: size)
        let chars = Array(text)
        // Advance of each character: the file's, or the font's.
        var natural: [Double] = []
        let attrs: [CFString: Any] = [kCTFontAttributeName: ct]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary))
        let naturalWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        let scaleX = max(abs(t.a), 1e-9)
        let deviceDx = dx.map { abs($0) * scaleX }
        let usable = deviceDx.count >= chars.count && chars.count > 0
        let fileWidth = usable ? deviceDx.prefix(chars.count).reduce(0, +) : naturalWidth
        let width = usable ? fileWidth : naturalWidth
        if usable { natural = Array(deviceDx.prefix(chars.count)) }

        // Horizontal and vertical alignment.
        let h = dc.textAlign & 6, v = dc.textAlign & 24
        var origin = t.apply(ref)
        let ascent = Double(CTFontGetAscent(ct)), descent = Double(CTFontGetDescent(ct))
        // Direction of the baseline on the device: the mapped x axis rotated counterclockwise by the escapement.
        let ex = VectorPoint(t.a, t.b)
        let base = atan2(ex.y, ex.x)
        let angle = base - dc.font.escapement * .pi / 180
        let dir = (cos(angle), sin(angle))
        let up = (sin(angle), -cos(angle))        // perpendicular, toward the visual top of the text
        var shiftAlong = 0.0
        if h == 2 { shiftAlong = -width } else if h == 6 { shiftAlong = -width / 2 }
        var shiftUp = 0.0
        if v == 0 { shiftUp = -ascent } else if v == 8 { shiftUp = descent }
        origin = VectorPoint(origin.x + dir.0 * shiftAlong + up.0 * shiftUp, origin.y + dir.1 * shiftAlong + up.1 * shiftUp)
        let rot = VectorTransform(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle), tx: 0, ty: 0)
        let place = VectorTransform.scale(1, -1).then(rot).then(.translation(origin.x, origin.y))

        if dc.bkOpaque || opaqueRect != nil {
            var box: [PathSegment]
            if let r = opaqueRect { box = rectSegments(r) }
            else {
                let ox = origin.x, oy = origin.y
                let p0 = VectorPoint(0, -(ascent)), p1 = VectorPoint(width, -ascent), p2 = VectorPoint(width, descent), p3 = VectorPoint(0, descent)
                let localT = VectorTransform.identity.then(rot).then(.translation(ox, oy))
                box = [.move(localT.apply(p0)), .line(localT.apply(p1)), .line(localT.apply(p2)), .line(localT.apply(p3)), .close]
            }
            emit(.path(box, fill: .solid(dc.bkColour), stroke: nil, rule: .nonZero))
        }
        var runs: [VectorNode] = []
        let fontName = GDIPlayer.fontName(dc.font)
        let fill = VectorPaint.solid(dc.textColour)
        let closeEnough = !usable || abs(naturalWidth - fileWidth) <= 0.04 * max(fileWidth, 1)
        if closeEnough || chars.count > 2000 {
            runs.append(.text(VectorTextRun(text: text, fontName: fontName, size: size, origin: VectorPoint(0, 0), fill: fill)))
        } else {
            var pen = 0.0
            for (i, ch) in chars.enumerated() {
                if ch != " " { runs.append(.text(VectorTextRun(text: String(ch), fontName: fontName, size: size, origin: VectorPoint(pen, 0), fill: fill))) }
                pen += natural[i]
            }
        }
        emit(.group(runs, transform: place, clip: clipRect.map { rectSegments($0).transformed(by: place.inverted ?? .identity) }, opacity: 1))
    }

    static func fontName(_ f: Font) -> String {
        GDIFontNames.postScriptName(families: f.name, bold: f.weight >= 600, italic: f.italic)
    }

    // MARK: Images

    /// Draws a decoded picture into the logical rectangle (x, y, w, h); negative extents flip it.
    func draw(_ image: MetafileDIB.Image, x: Double, y: Double, w: Double, h: Double) {
        flushLine()
        guard let asset = image.asset, w != 0, h != 0 else { return }
        // Unit square (v up) → logical: top of the bitmap at y.
        let place = VectorTransform(a: w, b: 0, c: 0, d: -h, tx: x, ty: y + h)
        emit(.image(asset, transform: place.then(transform())))
    }

    // MARK: Final assembly

    func finish() -> [VectorNode] {
        flushLine()
        while layers.count > 1 { popLayer() }
        return layers[0].nodes
    }

    // MARK: Stock objects

    static func stockObject(_ index: Int) -> Object? {
        switch index {
        case 0: .brush(.solid(.white))
        case 1: .brush(.solid(VectorColour(red: 0.75, green: 0.75, blue: 0.75)))
        case 2: .brush(.solid(VectorColour(red: 0.5, green: 0.5, blue: 0.5)))
        case 3: .brush(.solid(VectorColour(red: 0.25, green: 0.25, blue: 0.25)))
        case 4: .brush(.solid(.black))
        case 5: .brush(.none)
        case 6: .pen(Pen(visible: true, width: 0, colour: .white, cap: .round, join: .round, geometric: false, dash: []))
        case 7: .pen(Pen(visible: true, width: 0, colour: .black, cap: .round, join: .round, geometric: false, dash: []))
        case 8: .pen(Pen(visible: false, width: 0, colour: .black, cap: .round, join: .round, geometric: false, dash: []))
        case 10...17, 19: .font(Font(name: "Arial", height: -13, escapement: 0, weight: 400, italic: false))
        case 18: .brush(.solid(.white))
        default: nil
        }
    }

    func select(_ object: Object) {
        switch object {
        case .pen(let p): flushLine(); dc.pen = p
        case .brush(let b): dc.brush = b
        case .font(let f): dc.font = f
        case .region, .other: break
        }
    }

    /// COLORREF 0x00BBGGRR.
    static func colour(_ v: Int) -> VectorColour {
        VectorColour(red: Double(v & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double((v >> 16) & 255) / 255)
    }

    /// Pen from a style word and width: the dash pattern and line style bits GDI uses.
    static func pen(style: Int, width: Double, colour: VectorColour, extended: Bool, userDash: [Double] = []) -> Pen {
        let kind = style & 0xF
        var pen = Pen()
        pen.colour = colour
        pen.visible = kind != 5
        pen.geometric = extended ? (style & 0x30000) == 0x10000 : false
        if !extended { pen.geometric = width > 1 }
        pen.width = width
        switch style & 0xF00 { case 0x100: pen.cap = .square; case 0x200: pen.cap = .butt; default: pen.cap = .round }
        switch style & 0xF000 { case 0x1000: pen.join = .bevel; case 0x2000: pen.join = .miter; default: pen.join = .round }
        switch kind {
        case 1: pen.dash = [6, 2]
        case 2: pen.dash = [1, 2]
        case 3: pen.dash = [6, 2, 1, 2]
        case 4: pen.dash = [6, 2, 1, 2, 1, 2]
        case 7: pen.dash = userDash
        default: break
        }
        return pen
    }
}

extension Array where Element == PathSegment {
    /// A closed rectangle path (move, 3 lines, close) written the other way round, so it cuts a hole under the nonzero rule.
    func reversedRect() -> [PathSegment] {
        var pts: [VectorPoint] = []
        for s in self { if case .move(let p) = s { pts.append(p) } else if case .line(let p) = s { pts.append(p) } }
        guard pts.count == 4 else { return self }
        return [.move(pts[0]), .line(pts[3]), .line(pts[2]), .line(pts[1]), .close]
    }
}

/// PostScript names for Windows face names (Arial, Times New Roman, …), with the system's own fallbacks.
enum GDIFontNames {
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func postScriptName(families: String, bold: Bool, italic: Bool) -> String {
        let key = "\(families)|\(bold)|\(italic)"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let aliases = ["ms sans serif": "Helvetica", "ms shell dlg": "Helvetica", "system": "Helvetica", "tahoma": "Helvetica", "segoe ui": "Helvetica Neue",
                       "calibri": "Helvetica Neue", "cambria": "Times", "times new roman": "Times New Roman", "courier new": "Courier New",
                       "symbol": "Symbol", "wingdings": "Zapf Dingbats", "microsoft sans serif": "Helvetica", "verdana": "Verdana"]
        var name = families.trimmingCharacters(in: .whitespaces)
        if let alias = aliases[name.lowercased()] { name = alias }
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        var font = CTFontCreateWithName(name as CFString, 12, nil)
        let found = (CTFontCopyFamilyName(font) as String).caseInsensitiveCompare(name) == .orderedSame
            || (CTFontCopyFullName(font) as String).caseInsensitiveCompare(name) == .orderedSame
        if !found { font = CTFontCreateWithName("Helvetica" as CFString, 12, nil) }
        var result = CTFontCopyPostScriptName(font) as String
        if !traits.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(font, 12, nil, traits, traits) { result = CTFontCopyPostScriptName(styled) as String }
        cache[key] = result
        return result
    }
}
