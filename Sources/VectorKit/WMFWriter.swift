import CoreGraphics
import Foundation
import SuperConverterCore

/// VectorDocument → Windows Metafile (formats §3.2, MS-WMF): one page with an Aldus placeable header, 16-bit logical
/// coordinates, curves flattened to polygons and polylines, solid pens and brushes, fill modes, rectangular clips, text
/// as EXTTEXTOUT in Windows-1252, pictures as STRETCHDIB. Gradients, see-through colours, groups with opacity and
/// pictures with alpha or a turn become pictures of what they cover (WMF bitmaps have no alpha), quality §6.
public enum WMFWriter {
    public static func write(_ document: VectorDocument, options: VectorWriteOptions) throws -> VectorWriteResult {
        guard var page = document.pages.first else { throw ConversionError.failed("There are no pages to write.") }
        var notes: Set<LossNote> = []
        if options.textAsOutlines, page.nodes.contains(where: \.containsText) {
            page.nodes = page.nodes.map(VectorOutlines.convert)
            notes.insert(LossNote(.textAsOutlines))
        }
        let canvas = WMFCanvas(size: page.size)
        var painter = MetafilePainter(page: page, density: options.density, canvas: canvas)
        painter.paint()
        notes.formUnion(painter.lossNotes); notes.formUnion(canvas.lossNotes)
        return VectorWriteResult(data: canvas.finish(), lossNotes: notes.sorted { $0.detail < $1.detail })
    }
}

/// The record stream of one WMF page. Logical units are 1/1440 in (twips) when the page fits 16 bits, else coarser,
/// y down from the top of the page; the placeable header says how many make an inch.
final class WMFCanvas: MetafileCanvas {
    let size: VectorSize
    /// Logical units per inch (the placeable header's `Inch`).
    let inch: Int
    private var unitsPerPoint: Double { Double(inch) / 72 }
    private var body = ByteWriter()
    private var maxRecordWords = 0
    private let objects = GDIObjects(firstHandle: 0)
    private(set) var lossNotes: Set<LossNote> = []
    let keepsAlpha = false

    init(size: VectorSize) {
        self.size = size
        let side = max(size.width, size.height, 1)
        inch = side * 20 <= 32000 ? 1440 : max(1, Int(32000 * 72 / side))
        let w = Int((size.width * Double(inch) / 72).rounded()), h = Int((size.height * Double(inch) / 72).rounded())
        record(0x0103) { $0.u16(8) }                   // META_SETMAPMODE MM_ANISOTROPIC
        record(0x020B) { $0.u16(0); $0.u16(0) }        // META_SETWINDOWORG (y, x)
        record(0x020C) { $0.u16(h); $0.u16(w) }        // META_SETWINDOWEXT (y, x)
        record(0x0102) { $0.u16(1) }                   // META_SETBKMODE TRANSPARENT
        record(0x012E) { $0.u16(24) }                  // META_SETTEXTALIGN TA_BASELINE | TA_LEFT
    }

    // MARK: Records

    /// One record (MS-WMF 2.3): size in 16-bit words, function, parameters padded to a whole word.
    private func record(_ function: Int, _ fill: (inout ByteWriter) -> Void) {
        var r = ByteWriter()
        r.u32(0); r.u16(function)
        fill(&r)
        if r.count % 2 == 1 { r.u8(0) }
        r.set32(0, r.count / 2)
        maxRecordWords = max(maxRecordWords, r.count / 2)
        body.append(r.bytes)
    }

    private func i16(_ v: Double) -> Int { Int(max(-32768, min(32767, v.rounded()))) }
    /// Page points → logical units.
    private func logical(_ p: VectorPoint) -> (Double, Double) { (p.x * unitsPerPoint, (size.height - p.y) * unitsPerPoint) }

    private func saveDC() { record(0x001E) { _ in }; objects.save() }
    private func restoreDC() { record(0x0127) { $0.u16(0xFFFF) }; objects.restore(delete: deleteObject) }
    private func deleteObject(_ h: Int) { record(0x01F0) { $0.u16(h) } }
    private func selectObject(_ h: Int) { record(0x012D) { $0.u16(h) } }

    // MARK: What WMF holds

    func canFill(_ paint: VectorPaint) -> Bool { paint.opaqueColour != nil }
    func canStroke(_ stroke: VectorStroke) -> Bool { stroke.paint.opaqueColour != nil }

    func canDraw(_ run: VectorTextRun, transform: VectorTransform) -> Bool {
        run.fill.opaqueColour != nil && transform.isSimilarity && transform.determinant > 0
    }

    func canDraw(_ asset: ImageAsset, transform: VectorTransform) -> Bool {
        !asset.hasAlpha && !asset.frames.isEmpty && abs(transform.b) < 1e-9 && abs(transform.c) < 1e-9 && transform.a > 0 && transform.d > 0
    }

    // MARK: Clips

    /// WMF clips to rectangles only (the painter rasterises anything clipped to another shape).
    func canClip(_ segments: [PathSegment]) -> Bool { Self.isUprightRectangle(segments) }

    /// INTERSECTCLIPRECT inside SAVEDC.
    func pushClip(_ segments: [PathSegment]) {
        saveDC()
        guard let box = segments.controlBounds else { return }
        let a = logical(VectorPoint(Double(box.minX), Double(box.maxY))), b = logical(VectorPoint(Double(box.maxX), Double(box.minY)))
        record(0x0416) { $0.u16(i16(b.1)); $0.u16(i16(b.0)); $0.u16(i16(a.1)); $0.u16(i16(a.0)) }   // bottom, right, top, left
    }

    func popClip() { restoreDC() }

    static func isUprightRectangle(_ segments: [PathSegment]) -> Bool {
        var pts: [VectorPoint] = []
        for s in segments {
            switch s {
            case .move(let p): if !pts.isEmpty { return false }; pts.append(p)
            case .line(let p): pts.append(p)
            case .close: break
            default: return false
            }
        }
        if pts.count == 5, pts[4] == pts[0] { pts.removeLast() }
        guard pts.count == 4 else { return false }
        for i in 0..<4 {
            let p = pts[i], q = pts[(i + 1) % 4]
            if abs(p.x - q.x) > 1e-6 && abs(p.y - q.y) > 1e-6 { return false }
        }
        return true
    }

    // MARK: Paths

    func path(_ segments: [PathSegment], fill: VectorPaint?, stroke: VectorStroke?, rule: FillRule) {
        let figures = Self.flatten(segments, tolerance: 0.25 / unitsPerPoint).map { figure in
            (points: Self.deduplicated(figure.points.map { p -> (Int, Int) in let l = logical(p); return (i16(l.0), i16(l.1)) }), closed: figure.closed)
        }.filter { $0.points.count >= 2 }
        guard !figures.isEmpty else { return }
        objects.set("fill", rule == .evenOdd ? 1 : 2) { record(0x0106) { $0.u16(rule == .evenOdd ? 1 : 2) } }
        let colour = fill?.opaqueColour
        if let colour, stroke == nil || figures.allSatisfy(\.closed) {
            selectBrush(colour); selectPen(stroke)
            polyPolygon(figures.map(\.points))
            return
        }
        if let colour {
            selectBrush(colour); selectPen(nil)
            polyPolygon(figures.map(\.points))
        }
        guard stroke != nil else { return }
        selectBrush(nil); selectPen(stroke)
        let closed = figures.filter(\.closed).map(\.points)
        if !closed.isEmpty { polyPolygon(closed) }
        for figure in figures where !figure.closed {
            record(0x0325) { w in w.u16(figure.points.count); for p in figure.points { w.u16(p.0); w.u16(p.1) } }
        }
    }

    private func polyPolygon(_ polygons: [[(Int, Int)]]) {
        record(0x0538) { w in
            w.u16(polygons.count)
            for p in polygons { w.u16(p.count) }
            for p in polygons { for q in p { w.u16(q.0); w.u16(q.1) } }
        }
    }

    private func selectBrush(_ colour: VectorColour?) {
        let key = colour.map { "brush \($0.colorref)" } ?? "brush none"
        objects.select(.brush, key: key, create: { _ in
            record(0x02FC) { w in w.u16(colour == nil ? 1 : 0); w.u32(colour?.colorref ?? 0); w.u16(0) }   // BS_SOLID / BS_NULL
        }, select: selectObject, delete: deleteObject)
    }

    /// CREATEPENINDIRECT: width, caps and joins; WMF has no dash lengths, so a dashed stroke becomes PS_DASH.
    private func selectPen(_ stroke: VectorStroke?) {
        guard let stroke, let colour = stroke.paint.opaqueColour else {
            objects.select(.pen, key: "pen none", create: { _ in
                record(0x02FA) { w in w.u16(5); w.u16(0); w.u16(0); w.u32(0) }   // PS_NULL
            }, select: selectObject, delete: deleteObject)
            return
        }
        let width = max(1, i16(stroke.width * unitsPerPoint))
        let dashed = stroke.dash.contains { $0 > 0 }
        if dashed { lossNotes.insert(LossNote(.otherLoss, detail: "Dash patterns were simplified to the standard dash.")) }
        let cap = stroke.cap == .round ? 0 : stroke.cap == .square ? 0x100 : 0x200
        let join = stroke.join == .round ? 0 : stroke.join == .bevel ? 0x1000 : 0x2000
        let style = (dashed ? 1 : 0) | cap | join
        objects.select(.pen, key: "pen \(style) \(width) \(colour.colorref)", create: { _ in
            record(0x02FA) { w in w.u16(style); w.u16(width); w.u16(0); w.u32(colour.colorref) }
        }, select: selectObject, delete: deleteObject)
    }

    /// Figures as polylines: curves split until each piece is within `tolerance` of a chord.
    static func flatten(_ segments: [PathSegment], tolerance: Double) -> [(points: [VectorPoint], closed: Bool)] {
        var out: [(points: [VectorPoint], closed: Bool)] = []
        var figure: [VectorPoint] = []
        func finish(closed: Bool) { if !figure.isEmpty { out.append((figure, closed)) }; figure = [] }
        func cubic(_ p0: VectorPoint, _ p1: VectorPoint, _ p2: VectorPoint, _ p3: VectorPoint, depth: Int) {
            // Distance of the control points from the chord bounds the curve's.
            let dx = p3.x - p0.x, dy = p3.y - p0.y, len = max((dx * dx + dy * dy).squareRoot(), 1e-12)
            let d1 = abs((p1.x - p0.x) * dy - (p1.y - p0.y) * dx) / len, d2 = abs((p2.x - p0.x) * dy - (p2.y - p0.y) * dx) / len
            let near = len < 1e-9 ? max(hypot(p1.x - p0.x, p1.y - p0.y), hypot(p2.x - p0.x, p2.y - p0.y)) : max(d1, d2)
            if near <= tolerance || depth >= 16 { figure.append(p3); return }
            func mid(_ a: VectorPoint, _ b: VectorPoint) -> VectorPoint { VectorPoint((a.x + b.x) / 2, (a.y + b.y) / 2) }
            let a = mid(p0, p1), b = mid(p1, p2), c = mid(p2, p3), ab = mid(a, b), bc = mid(b, c), m = mid(ab, bc)
            cubic(p0, a, ab, m, depth: depth + 1); cubic(m, bc, c, p3, depth: depth + 1)
        }
        for segment in segments {
            switch segment {
            case .move(let p): finish(closed: false); figure = [p]
            case .line(let p): figure.append(p)
            case .cubic(let a, let b, let c): cubic(figure.last ?? a, a, b, c, depth: 0)
            case .quad(let c, let e):
                let s = figure.last ?? c
                cubic(s, VectorPoint(s.x + 2 / 3 * (c.x - s.x), s.y + 2 / 3 * (c.y - s.y)), VectorPoint(e.x + 2 / 3 * (c.x - e.x), e.y + 2 / 3 * (c.y - e.y)), e, depth: 0)
            case .close:
                let start = figure.first
                finish(closed: true)
                if let start { figure = [start] }
            }
        }
        if figure.count > 1 { finish(closed: false) }
        return out
    }

    private static func deduplicated(_ points: [(Int, Int)]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for p in points where out.last.map({ $0 != p }) ?? true { out.append(p) }
        return out
    }

    // MARK: Text

    /// CREATEFONTINDIRECT with the run's size and turn (escapement), EXTTEXTOUT with per-character advances.
    func text(_ run: VectorTextRun, transform m: VectorTransform) {
        guard let colour = run.fill.opaqueColour else { return }
        if let note = MetafileText.embeddedFontNote(run) { lossNotes.insert(note) }
        var bytes: [UInt8] = []
        for ch in run.text.utf16 {
            if let encoded = String(utf16CodeUnits: [ch], count: 1).data(using: .windowsCP1252), encoded.count == 1 { bytes.append(encoded[0]) }
            else {
                bytes.append(0x3F)
                lossNotes.insert(LossNote(.otherLoss, detail: "Characters outside Windows-1252 became “?” in WMF text."))
            }
        }
        let scale = m.lengthScale * unitsPerPoint
        let height = max(1, i16(run.size * scale))
        let escapement = Int((atan2(m.b, m.a) * 1800 / .pi).rounded())
        let face = MetafileText.face(run)
        objects.select(.font, key: "font \(face.family) \(face.bold) \(face.italic) \(height) \(escapement)", create: { _ in
            record(0x02FB) { w in
                w.u16(-height); w.u16(0); w.u16(escapement); w.u16(escapement); w.u16(face.bold ? 700 : 400)
                w.u8(face.italic ? 1 : 0); w.u8(0); w.u8(0); w.u8(0)   // italic, underline, strike-out, ANSI_CHARSET
                w.u8(0); w.u8(0); w.u8(4); w.u8(0)                     // precision, clipping, ANTIALIASED_QUALITY, pitch
                let name = [UInt8]((face.family.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data()).prefix(31))
                for i in 0..<32 { w.u8(i < name.count ? Int(name[i]) : 0) }
            }
        }, select: selectObject, delete: deleteObject)
        objects.set("textColour", colour.colorref) { record(0x0209) { $0.u32(colour.colorref) } }
        let ref = logical(m.apply(run.origin))
        let dx = MetafileText.integerAdvances(MetafileText.advances(run), scale: scale)
        record(0x0A32) { w in
            w.u16(i16(ref.1)); w.u16(i16(ref.0)); w.u16(bytes.count); w.u16(0)
            w.append(bytes); if bytes.count % 2 == 1 { w.u8(0) }
            for d in dx { w.u16(Int(max(-32768, min(32767, d)))) }
        }
    }

    // MARK: Pictures

    /// STRETCHDIB with a 24-bit DIB into the picture's upright rectangle.
    func image(_ asset: ImageAsset, transform m: VectorTransform) {
        guard let dib = MetafileDIB.encode(asset, alpha: false) else { return }
        let top = logical(m.apply(VectorPoint(0, 1))), bottom = logical(m.apply(VectorPoint(1, 0)))
        let x = i16(top.0), y = i16(top.1)
        let w = max(1, i16(bottom.0) - x), h = max(1, i16(bottom.1) - y)
        record(0x0F43) { r in
            r.u32(0x00CC_0020); r.u16(0)                           // SRCCOPY, DIB_RGB_COLORS
            r.u16(dib.height); r.u16(dib.width); r.u16(0); r.u16(0)
            r.u16(h); r.u16(w); r.u16(y); r.u16(x)
            r.append(dib.info); r.append(dib.bits)
        }
    }

    // MARK: Header and end

    /// The placeable header (with its checksum), META_HEADER, the records and META_EOF.
    func finish() -> Data {
        record(0x0000) { _ in }
        let w = Int((size.width * unitsPerPoint).rounded()), h = Int((size.height * unitsPerPoint).rounded())
        var placeable = ByteWriter()
        placeable.u32(0x9AC6_CDD7); placeable.u16(0)
        placeable.u16(0); placeable.u16(0); placeable.u16(min(w, 32767)); placeable.u16(min(h, 32767))
        placeable.u16(inch); placeable.u32(0)
        var checksum = 0
        for i in 0..<10 { checksum ^= Int(placeable.bytes[i * 2]) | Int(placeable.bytes[i * 2 + 1]) << 8 }
        placeable.u16(checksum)
        var header = ByteWriter()
        header.u16(1); header.u16(9); header.u16(0x0300)
        header.u32(9 + body.count / 2); header.u16(objects.tableSize); header.u32(maxRecordWords); header.u16(0)
        return Data(placeable.bytes + header.bytes + body.bytes)
    }
}
