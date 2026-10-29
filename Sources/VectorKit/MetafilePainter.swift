import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore

// What the EMF and WMF writers share: a page walked into page-space drawing calls, with whatever the target can't hold
// rasterised (quality §6: only that object, at the render density, with a loss note); the GDI object table; DIBs from
// pictures; the face and advances of a text run.

/// A metafile being written, as the painter sees it. Every call is in page points, y up.
protocol MetafileCanvas: AnyObject {
    /// Rasterised objects keep their alpha (EMF's AlphaBlend); otherwise they are drawn over what lies beneath (WMF).
    var keepsAlpha: Bool { get }
    func canFill(_ paint: VectorPaint) -> Bool
    func canStroke(_ stroke: VectorStroke) -> Bool
    /// Whether the run can be written as text under `transform` (local points → page points).
    func canDraw(_ run: VectorTextRun, transform: VectorTransform) -> Bool
    /// Whether the picture can be placed with `transform` (unit square → page points).
    func canDraw(_ asset: ImageAsset, transform: VectorTransform) -> Bool
    /// Whether the canvas can clip to `segments` (page points).
    func canClip(_ segments: [PathSegment]) -> Bool
    func pushClip(_ segments: [PathSegment])
    func popClip()
    func path(_ segments: [PathSegment], fill: VectorPaint?, stroke: VectorStroke?, rule: FillRule)
    func text(_ run: VectorTextRun, transform: VectorTransform)
    func image(_ asset: ImageAsset, transform: VectorTransform)
}

/// Walks a page into a `MetafileCanvas`: group transforms are flattened into page space, clips are pushed and popped,
/// and objects the canvas can't express become pictures of just that object.
struct MetafilePainter {
    let page: VectorPage
    /// Pixels per inch for rasterised objects (O-VEC render density).
    let density: Double
    let canvas: MetafileCanvas
    private(set) var lossNotes: Set<LossNote> = []
    /// What has been drawn so far in page points, nested in the open clips: the backdrop of a rasterised object on a
    /// canvas without alpha.
    private var levels: [(clip: [PathSegment]?, nodes: [VectorNode])] = [(nil, [])]

    init(page: VectorPage, density: Double, canvas: MetafileCanvas) {
        self.page = page; self.density = max(36, min(density, 2400)); self.canvas = canvas
    }

    mutating func paint() {
        if let background = page.background {
            draw(.path(PathBuilder.rect(x: 0, y: 0, width: page.size.width, height: page.size.height), fill: .solid(background), stroke: nil), .identity)
        }
        for node in page.nodes { draw(node, .identity) }
    }

    // MARK: Walking

    private mutating func draw(_ node: VectorNode, _ m: VectorTransform) {
        switch node {
        case .path(let segments, let fill, let stroke, let rule):
            guard !segments.isEmpty else { return }
            let pageFill = fill.map { Self.paint($0, m) }, pageStroke = stroke.map { Self.stroke($0, m) }
            let fillOK = pageFill.map(canvas.canFill) ?? true, strokeOK = pageStroke.map(canvas.canStroke) ?? true
            let pageSegments = segments.transformed(by: m)
            switch (fillOK, strokeOK) {
            case (true, true):
                canvas.path(pageSegments, fill: pageFill, stroke: pageStroke, rule: rule)
                record(node, m)
            case (true, false):
                if let pageFill {
                    canvas.path(pageSegments, fill: pageFill, stroke: nil, rule: rule)
                    record(.path(segments, fill: fill, stroke: nil, rule: rule), m)
                }
                rasterise(.path(segments, fill: nil, stroke: stroke, rule: rule), m, why: stroke!.paint)
            case (false, true):
                rasterise(.path(segments, fill: fill, stroke: nil, rule: rule), m, why: fill!)
                if let pageStroke {
                    canvas.path(pageSegments, fill: nil, stroke: pageStroke, rule: rule)
                    record(.path(segments, fill: nil, stroke: stroke, rule: rule), m)
                }
            case (false, false):
                rasterise(node, m, why: fill!)
            }
        case .text(let run):
            guard !run.text.isEmpty else { return }
            if canvas.canDraw(run, transform: m) { canvas.text(run, transform: m); record(node, m) }
            else { rasterise(node, m, note: LossNote(.otherLoss, detail: "Text the format can’t colour or turn that way became a picture.")) }
        case .image(let asset, let t):
            let placed = t.then(m)
            if canvas.canDraw(asset, transform: placed) { canvas.image(asset, transform: placed); record(node, m) }
            else { rasterise(node, m, note: LossNote(.otherLoss, detail: "See-through or turned pictures were flattened.")) }
        case .group(let children, let t, let clip, let opacity):
            guard opacity > 0 else { return }
            if opacity < 0.999 {
                rasterise(node, m, note: LossNote(.otherLoss, detail: "See-through groups became pictures."))
                return
            }
            let g = t.then(m)
            if let clip {
                // An empty clip path clips everything away.
                if clip.isEmpty { return }
                let pageClip = clip.transformed(by: g)
                if !canvas.canClip(pageClip) {
                    rasterise(node, m, note: LossNote(.otherLoss, detail: "Drawings clipped to a shape the format can’t clip to became pictures."))
                    return
                }
                canvas.pushClip(pageClip)
                levels.append((pageClip, []))
            }
            for child in children { draw(child, g) }
            if clip != nil {
                canvas.popClip()
                let top = levels.removeLast()
                if !top.nodes.isEmpty { levels[levels.count - 1].nodes.append(.group(top.nodes, transform: .identity, clip: top.clip, opacity: 1)) }
            }
        }
    }

    private mutating func record(_ node: VectorNode, _ m: VectorTransform) {
        levels[levels.count - 1].nodes.append(m.isIdentity ? node : .group([node], transform: m, clip: nil, opacity: 1))
    }

    /// The drawing so far (with `node` on top, inside the open clips), folded into page-space nodes.
    private func backdrop(with node: VectorNode) -> [VectorNode] {
        var folded = levels
        folded[folded.count - 1].nodes.append(node)
        while folded.count > 1 {
            let top = folded.removeLast()
            folded[folded.count - 1].nodes.append(.group(top.nodes, transform: .identity, clip: top.clip, opacity: 1))
        }
        return folded[0].nodes
    }

    // MARK: Rasterising

    private mutating func rasterise(_ node: VectorNode, _ m: VectorTransform, why paint: VectorPaint) {
        switch paint {
        case .linear, .radial: rasterise(node, m, note: LossNote(.shadingRasterised, detail: "Gradients the format can’t hold became pictures."))
        case .rasterised: rasterise(node, m, note: LossNote(.shadingRasterised, detail: "Patterns became pictures."))
        case .solid: rasterise(node, m, note: LossNote(.otherLoss, detail: "See-through colours became pictures."))
        }
    }

    /// Draws `node` (under `m`) as a picture of its page-space bounds at the render density.
    private mutating func rasterise(_ node: VectorNode, _ m: VectorTransform, note: LossNote) {
        let placed: VectorNode = .group([node], transform: m, clip: nil, opacity: 1)
        // Text is measured by its outlines, not estimated; strokes and joins get a point of slack.
        guard var box = VectorOutlines.convert(placed).bounds?.insetBy(dx: -1, dy: -1) else { return }
        box = box.intersection(CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height))
        for level in levels { if let clip = level.clip, let clipBox = clip.controlBounds { box = box.intersection(clipBox) } }
        guard !box.isNull, box.width > 0, box.height > 0 else { return }
        // Whole pixels at the density, at most 8192 on a side.
        let scale = min(density / 72, 8192 / Double(max(box.width, box.height)))
        let x0 = (Double(box.minX) * scale).rounded(.down) / scale, y0 = (Double(box.minY) * scale).rounded(.down) / scale
        let x1 = (Double(box.maxX) * scale).rounded(.up) / scale, y1 = (Double(box.maxY) * scale).rounded(.up) / scale
        let content = canvas.keepsAlpha ? [placed] : backdrop(with: placed)
        let picture = VectorPage(size: VectorSize(width: x1 - x0, height: y1 - y0),
                                 nodes: [.group(content, transform: .translation(-x0, -y0), clip: nil, opacity: 1)])
        guard let image = VectorDrawing.render(picture, scale: scale, background: canvas.keepsAlpha ? nil : (page.background ?? .white)),
              let asset = ImageBridge.asset(image) else { return }
        canvas.image(asset, transform: VectorTransform(a: x1 - x0, b: 0, c: 0, d: y1 - y0, tx: x0, ty: y0))
        record(node, m)
        lossNotes.insert(note)
    }

    // MARK: Paint in page space

    /// A paint under `m`: linear gradients exactly (the colour ramp is an affine function of position), radial ones with
    /// the radius scaled by the transform's length scale.
    static func paint(_ paint: VectorPaint, _ m: VectorTransform) -> VectorPaint {
        switch paint {
        case .solid, .rasterised: return paint
        case .linear(let from, let to, let stops):
            let a = m.apply(from), dx = to.x - from.x, dy = to.y - from.y, length2 = dx * dx + dy * dy
            guard length2 > 1e-18, let inverse = m.inverted else { return .linear(from: a, to: m.apply(to), stops: stops) }
            // The ramp's gradient in page space is the inverse transpose of the linear part applied to d / |d|².
            let gx = (inverse.a * dx + inverse.b * dy) / length2, gy = (inverse.c * dx + inverse.d * dy) / length2
            let g2 = gx * gx + gy * gy
            guard g2 > 1e-18 else { return .linear(from: a, to: m.apply(to), stops: stops) }
            return .linear(from: a, to: VectorPoint(a.x + gx / g2, a.y + gy / g2), stops: stops)
        case .radial(let centre, let radius, let stops):
            return .radial(centre: m.apply(centre), radius: radius * m.lengthScale, stops: stops)
        }
    }

    static func stroke(_ stroke: VectorStroke, _ m: VectorTransform) -> VectorStroke {
        let s = m.lengthScale
        var out = stroke
        out.paint = paint(stroke.paint, m)
        out.width = stroke.width * s
        out.dash = stroke.dash.map { $0 * s }
        out.dashPhase = stroke.dashPhase * s
        return out
    }
}

extension VectorPaint {
    /// A solid colour with no transparency: what a GDI pen or brush holds.
    var opaqueColour: VectorColour? {
        if case .solid(let c) = self, c.alpha >= 0.999 { return c }
        return nil
    }
}

extension VectorColour {
    /// COLORREF 0x00BBGGRR.
    var colorref: Int {
        func byte(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return byte(red) | byte(green) << 8 | byte(blue) << 16
    }
}

// MARK: - GDI object table

/// The object table of a metafile being written (MS-EMF 3.1.1, MS-WMF 3.1.4.1: a new object takes the lowest free index),
/// and the selected objects and DC values mirrored across SAVEDC/RESTOREDC, so a record is written only when something
/// changes and an object is deleted only once nothing selects it any more.
final class GDIObjects {
    enum Kind: Hashable { case pen, brush, font }
    struct Selected { let key: String; let handle: Int? }
    struct State { var selected: [Kind: Selected] = [:]; var values: [String: Int] = [:] }

    private var state = State()
    private var saved: [State] = []
    private var live: Set<Int> = []
    private let first: Int
    /// One past the highest index ever used.
    private(set) var tableSize = 0

    init(firstHandle: Int) { first = firstHandle; tableSize = firstHandle }

    /// Makes the object `key` current: a stock object (`stock`), or a new one `create` writes into a free index; `select`
    /// writes the selection and `delete` removes an object nothing selects any more.
    func select(_ kind: Kind, key: String, stock: Int? = nil, create: (Int) -> Void, select: (Int) -> Void, delete: (Int) -> Void) {
        if state.selected[kind]?.key == key { return }
        let old = state.selected[kind]?.handle
        var handle: Int?
        if let stock { select(stock) } else {
            var h = first
            while live.contains(h) { h += 1 }
            live.insert(h); tableSize = max(tableSize, h + 1)
            create(h); select(h); handle = h
        }
        state.selected[kind] = Selected(key: key, handle: handle)
        if let old { release(old, delete) }
    }

    /// Writes a DC value (fill mode, text colour, …) only when it changes.
    func set(_ name: String, _ value: Int, write: () -> Void) {
        if state.values[name] != value { write(); state.values[name] = value }
    }

    func save() { saved.append(state) }

    /// After RESTOREDC: the saved selection is back; objects only the dropped state selected are deleted.
    func restore(delete: (Int) -> Void) {
        guard let back = saved.popLast() else { return }
        let dropped = state.selected.values.compactMap(\.handle)
        state = back
        for h in dropped { release(h, delete) }
    }

    private func release(_ h: Int, _ delete: (Int) -> Void) {
        guard live.contains(h), !([state] + saved).contains(where: { $0.selected.values.contains { $0.handle == h } }) else { return }
        delete(h); live.remove(h)
    }
}

// MARK: - Pictures and text

extension MetafileDIB {
    /// A DIB of the asset's first frame (MS-WMF 2.2.2.9): BITMAPINFOHEADER and bottom-up rows, 32-bit premultiplied BGRA
    /// when `alpha` (what AlphaBlend takes), else 24-bit BGR over white.
    static func encode(_ asset: ImageAsset, alpha: Bool) -> (info: [UInt8], bits: [UInt8], width: Int, height: Int)? {
        guard let image = asset.frames.first?.cgImage() else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bgra.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            if !alpha { ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let bpp = alpha ? 32 : 24
        let stride = ((w * bpp + 31) / 32) * 4
        var bits = [UInt8](repeating: 0, count: stride * h)
        for row in 0..<h {
            // The context's first row is the top; a DIB with a positive height starts at the bottom.
            let src = (h - 1 - row) * w * 4, dst = row * stride
            for x in 0..<w {
                if alpha { for c in 0..<4 { bits[dst + x * 4 + c] = bgra[src + x * 4 + c] } }
                else { for c in 0..<3 { bits[dst + x * 3 + c] = bgra[src + x * 4 + c] } }
            }
        }
        var info = ByteWriter()
        info.u32(40); info.i32(w); info.i32(h); info.u16(1); info.u16(bpp); info.u32(0); info.u32(bits.count)
        info.i32(3780); info.i32(3780); info.u32(0); info.u32(0)
        return (info.bytes, bits, w, h)
    }
}

/// A text run as GDI fonts describe it.
enum MetafileText {
    struct Face { var family: String; var bold: Bool; var italic: Bool }

    static func face(_ run: VectorTextRun) -> Face {
        let font = VectorDrawing.font(for: run)
        let traits = CTFontGetSymbolicTraits(font)
        return Face(family: CTFontCopyFamilyName(font) as String, bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic))
    }

    /// The advance of each UTF-16 code unit of the run in points (a glyph's advance goes to the first unit it came from).
    static func advances(_ run: VectorTextRun) -> [Double] {
        let units = run.text.utf16.count
        var out = [Double](repeating: 0, count: units)
        let attributes: [CFString: Any] = [kCTFontAttributeName: VectorDrawing.font(for: run)]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, run.text as CFString, attributes as CFDictionary))
        for ctRun in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(ctRun)
            guard count > 0 else { continue }
            var advances = [CGSize](repeating: .zero, count: count), indices = [CFIndex](repeating: 0, count: count)
            CTRunGetAdvances(ctRun, CFRange(location: 0, length: 0), &advances)
            CTRunGetStringIndices(ctRun, CFRange(location: 0, length: 0), &indices)
            for i in 0..<count where indices[i] >= 0 && indices[i] < units { out[indices[i]] += Double(advances[i].width) }
        }
        return out
    }

    /// Integer advances in device units whose running sum never drifts more than half a unit from the exact positions.
    static func integerAdvances(_ advances: [Double], scale: Double) -> [Int] {
        var out: [Int] = [], exact = 0.0, placed = 0
        for a in advances {
            exact += a * scale
            let next = Int(exact.rounded())
            out.append(next - placed); placed = next
        }
        return out
    }

    /// A note when the run's embedded font can't travel with a metafile.
    static func embeddedFontNote(_ run: VectorTextRun) -> LossNote? {
        run.fontData == nil ? nil : LossNote(.fontsReplaced, detail: "Embedded fonts can’t be stored in a metafile; the installed font of the same name is named instead.")
    }
}
