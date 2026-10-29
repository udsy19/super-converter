import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore

/// VectorDocument → binary CGM (ISO 8632-3), version 1 profile (formats §3.2, `CGMWriter`): one picture per page with
/// integer VDC (the page's longer side is 32 000 units, metric scaling so the physical size survives), polylines,
/// polygons and polygon sets (curves flattened to within 0.1 pt), ellipses (recognised from their four Béziers),
/// text, pictures as cell arrays, and a colour table (indexed colour; direct colour when the drawing has more than 255
/// colours or pictures). Text becomes outlines by default (O-VEC). What version 1 cannot hold is reported: gradients
/// become their mean colour, transparency is dropped, non-rectangular clips become their bounding rectangle.
public enum CGMWriter {
    public static func write(_ document: VectorDocument, options: VectorWriteOptions) throws -> VectorWriteResult {
        var doc = document
        var notes: [LossNote] = []
        if options.textAsOutlines, doc.containsText { doc = doc.outlinedText(); notes.append(LossNote(.textAsOutlines)) }
        guard !doc.pages.isEmpty else { throw ConversionError.failed("There are no pages to write.") }

        // Pass 1: primitives per page in page points, plus what the metafile descriptor must declare.
        var collector = Collector()
        let pages = doc.pages.map { page -> (VectorPage, [Primitive]) in
            collector.primitives = []
            collector.walk(page.nodes, transform: .identity, clip: nil)
            return (page, collector.primitives)
        }
        notes += collector.lossNotes.sorted { $0.detail < $1.detail }
        let colours = Set(pages.flatMap { page, prims in prims.flatMap(\.colours) + [page.background ?? .white] }.map(RGB.init))
        let indexed = colours.count <= 255 && !collector.hasPictures

        var out = CGMStream()
        out.element(0, 1, CGMStream.string(doc.title ?? options.title ?? "Drawing"))       // BEGIN METAFILE
        out.element(1, 1, CGMStream.int(1))                                              // METAFILE VERSION
        out.element(1, 2, CGMStream.string("Super Converter"))                           // METAFILE DESCRIPTION
        if indexed { out.element(1, 9, [UInt8(colours.count)]) }                          // MAXIMUM COLOUR INDEX
        out.element(1, 11, CGMStream.int(1) + CGMStream.int(-1) + CGMStream.int(0))      // METAFILE ELEMENT LIST: drawing set
        if !collector.fonts.isEmpty { out.element(1, 13, collector.fonts.flatMap(CGMStream.string)) } // FONT LIST

        for (number, (page, prims)) in pages.enumerated() {
            var picture = PictureEncoder(page: page, indexed: indexed, fonts: collector.fonts)
            if indexed { picture.table = Dictionary(uniqueKeysWithValues: colours.sorted().enumerated().map { ($1, $0 + 1) }) }
            picture.encode(prims, number: number + 1, into: &out)
        }
        out.element(0, 2, [])                                                            // END METAFILE
        return VectorWriteResult(data: Data(out.bytes), lossNotes: notes)
    }

    // MARK: Primitives

    struct RGB: Hashable, Comparable {
        let r: UInt8, g: UInt8, b: UInt8
        init(_ c: VectorColour) {
            func b8(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
            r = b8(c.red); g = b8(c.green); b = b8(c.blue)
        }
        static func < (x: RGB, y: RGB) -> Bool { (x.r, x.g, x.b) < (y.r, y.g, y.b) }
    }

    struct Line { var colour: VectorColour; var width: Double; var type: Int }

    enum Primitive {
        /// Closed outlines filled by the odd-even rule (CGM's only rule).
        case fill([[VectorPoint]], VectorColour, clip: CGRect?)
        case polyline([VectorPoint], Line, clip: CGRect?)
        /// Centre and two conjugate diameter end points.
        case ellipse(VectorPoint, VectorPoint, VectorPoint, fill: VectorColour?, edge: Line?, clip: CGRect?)
        /// Position, baseline and up directions (unit vectors in page space), cap height, font index (1-based).
        case text(String, VectorPoint, base: VectorPoint, up: VectorPoint, height: Double, font: Int, VectorColour, clip: CGRect?)
        /// The picture's corners: first cell (top left), end of the first row, last cell (bottom right).
        case cells(CGImage, p: VectorPoint, r: VectorPoint, q: VectorPoint, clip: CGRect?)

        var colours: [VectorColour] {
            switch self {
            case .fill(_, let c, _), .text(_, _, _, _, _, _, let c, _): [c]
            case .polyline(_, let line, _): [line.colour]
            case .ellipse(_, _, _, let fill, let edge, _): [fill, edge?.colour].compactMap { $0 }
            case .cells: []
            }
        }
    }

    /// Walks the model with the transforms applied (CGM has none), turning nodes into primitives.
    struct Collector {
        var primitives: [Primitive] = []
        var fonts: [String] = []
        var hasPictures = false
        var lossNotes: Set<LossNote> = []

        mutating func walk(_ nodes: [VectorNode], transform m: VectorTransform, clip: CGRect?) {
            for node in nodes {
                switch node {
                case .path(let segments, let fill, let stroke, _):
                    path(segments.transformed(by: m), original: segments, m: m, fill: fill, stroke: stroke, clip: clip)
                case .text(let run):
                    text(run, m: m, clip: clip)
                case .image(let asset, let t):
                    guard let image = asset.frames.first?.cgImage() else { continue }
                    let full = t.then(m)
                    hasPictures = true
                    if asset.hasAlpha { lossNotes.insert(LossNote(.transparencyFilled)) }
                    primitives.append(.cells(image, p: full.apply(VectorPoint(0, 1)), r: full.apply(VectorPoint(1, 1)), q: full.apply(VectorPoint(1, 0)), clip: clip))
                case .group(let children, let t, let groupClip, let opacity):
                    let inner = t.then(m)
                    if opacity < 0.999 { lossNotes.insert(LossNote(.otherLoss, detail: "CGM has no transparency; see-through objects are drawn opaque")) }
                    var newClip = clip
                    if let groupClip {
                        let mapped = groupClip.transformed(by: inner)
                        guard let box = mapped.controlBounds else { continue }
                        if !Self.isRectangle(mapped) { lossNotes.insert(LossNote(.otherLoss, detail: "CGM clips only to rectangles; shaped clips became their bounding box")) }
                        newClip = clip.map { $0.intersection(box) } ?? box
                        if newClip!.isNull || newClip!.isEmpty { continue }
                    }
                    walk(children, transform: inner, clip: newClip)
                }
            }
        }

        mutating func flat(_ paint: VectorPaint) -> VectorColour {
            switch paint {
            case .solid(let c):
                if c.alpha < 0.999 { lossNotes.insert(LossNote(.otherLoss, detail: "CGM has no transparency; see-through objects are drawn opaque")) }
                return c
            case .linear(_, _, let stops), .radial(_, _, let stops):
                lossNotes.insert(LossNote(.otherLoss, detail: "CGM version 1 has no gradients; they were filled with their mean colour"))
                guard !stops.isEmpty else { return .black }
                let n = Double(stops.count)
                return VectorColour(red: stops.map(\.colour.red).reduce(0, +) / n, green: stops.map(\.colour.green).reduce(0, +) / n,
                                    blue: stops.map(\.colour.blue).reduce(0, +) / n)
            case .rasterised(let asset):
                lossNotes.insert(LossNote(.otherLoss, detail: "CGM version 1 has no patterns; they were filled with their mean colour"))
                return Self.meanColour(asset)
            }
        }

        mutating func path(_ segments: [PathSegment], original: [PathSegment], m: VectorTransform, fill: VectorPaint?, stroke: VectorStroke?, clip: CGRect?) {
            let line = stroke.flatMap { s -> Line? in
                s.width > 0 ? Line(colour: flat(s.paint), width: s.width * m.lengthScale, type: Self.lineType(s)) : nil
            }
            let fillColour = fill.map { flat($0) }
            guard fillColour != nil || line != nil else { return }
            if let (c, d1, d2) = Self.ellipse(original) {
                primitives.append(.ellipse(m.apply(c), m.apply(d1), m.apply(d2), fill: fillColour, edge: line, clip: clip))
                return
            }
            let subpaths = Self.flatten(segments)
            if let fillColour {
                let rings = subpaths.map(\.points).filter { $0.count >= 3 }
                if !rings.isEmpty { primitives.append(.fill(rings, fillColour, clip: clip)) }
            }
            if let line {
                for sub in subpaths where sub.points.count >= 2 {
                    primitives.append(.polyline(sub.closed ? sub.points + [sub.points[0]] : sub.points, line, clip: clip))
                }
            }
        }

        mutating func text(_ run: VectorTextRun, m: VectorTransform, clip: CGRect?) {
            let font = VectorDrawing.font(for: run)
            let name = CTFontCopyFamilyName(font) as String
            if !fonts.contains(name) { fonts.append(name) }
            let origin = m.apply(run.origin)
            func direction(_ x: Double, _ y: Double) -> VectorPoint {
                let v = m.apply(VectorPoint(run.origin.x + x, run.origin.y + y))
                let dx = v.x - origin.x, dy = v.y - origin.y, len = (dx * dx + dy * dy).squareRoot()
                return len > 0 ? VectorPoint(dx / len, dy / len) : VectorPoint(x, y)
            }
            let capHeight = Double(CTFontGetCapHeight(font)) > 0 ? Double(CTFontGetCapHeight(font)) : run.size * 0.7
            primitives.append(.text(run.text, origin, base: direction(1, 0), up: direction(0, 1), height: capHeight * m.lengthScale,
                                    font: fonts.firstIndex(of: name)! + 1, flat(run.fill), clip: clip))
        }

        /// Version 1's line types for a dash pattern: 2 dash, 3 dot, 4 dash-dot, 5 dash-dot-dot.
        static func lineType(_ s: VectorStroke) -> Int {
            let dash = s.dash.filter { $0 > 0 }
            guard dash.count >= 2 else { return 1 }
            if dash.count >= 6 { return 5 }
            if dash.count >= 4 { return 4 }
            return dash[0] <= s.width * 1.5 ? 3 : 2
        }

        /// The centre and conjugate diameter ends of a path that is exactly an ellipse drawn as four quarter Béziers (the
        /// shape PathBuilder, SVG and PDF readers produce), in the path's own coordinates.
        static func ellipse(_ s: [PathSegment]) -> (VectorPoint, VectorPoint, VectorPoint)? {
            guard s.count == 5 || s.count == 6, case .move(let p0) = s[0] else { return nil }
            var ends: [VectorPoint] = [p0], controls: [(VectorPoint, VectorPoint)] = []
            for seg in s[1...4] {
                guard case .cubic(let a, let b, let c) = seg else { return nil }
                ends.append(c); controls.append((a, b))
            }
            if s.count == 6 { guard case .close = s[5] else { return nil } }
            let c = VectorPoint((ends[0].x + ends[2].x) / 2, (ends[0].y + ends[2].y) / 2)
            let size = max(abs(ends[0].x - ends[2].x), abs(ends[0].y - ends[2].y), abs(ends[1].x - ends[3].x), abs(ends[1].y - ends[3].y))
            let tol = max(size * 1e-3, 1e-6)
            func near(_ a: VectorPoint, _ b: VectorPoint) -> Bool { abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol }
            guard size > 0, near(ends[4], ends[0]), near(VectorPoint((ends[1].x + ends[3].x) / 2, (ends[1].y + ends[3].y) / 2), c) else { return nil }
            let k = 0.5522847498307936
            for i in 0..<4 {
                let a = ends[i], b = ends[i + 1]
                let u = VectorPoint(a.x - c.x, a.y - c.y), v = VectorPoint(b.x - c.x, b.y - c.y)
                guard near(controls[i].0, VectorPoint(a.x + k * v.x, a.y + k * v.y)), near(controls[i].1, VectorPoint(b.x + k * u.x, b.y + k * u.y)) else { return nil }
            }
            return (c, ends[0], ends[1])
        }

        /// Subpaths as point lists, curves flattened to within 0.1 pt of the curve.
        static func flatten(_ segments: [PathSegment]) -> [(points: [VectorPoint], closed: Bool)] {
            var out: [(points: [VectorPoint], closed: Bool)] = [], current: [VectorPoint] = []
            func finish(_ closed: Bool) { if !current.isEmpty { out.append((current, closed)) }; current = [] }
            func curve(_ p: [VectorPoint]) {
                let length = zip(p, p.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
                let n = max(1, min(256, Int((length / 0.4).squareRoot().rounded(.up))))
                for i in 1...n {
                    let t = Double(i) / Double(n), u = 1 - t
                    if p.count == 4 {
                        current.append(VectorPoint(u * u * u * p[0].x + 3 * u * u * t * p[1].x + 3 * u * t * t * p[2].x + t * t * t * p[3].x,
                                                   u * u * u * p[0].y + 3 * u * u * t * p[1].y + 3 * u * t * t * p[2].y + t * t * t * p[3].y))
                    } else {
                        current.append(VectorPoint(u * u * p[0].x + 2 * u * t * p[1].x + t * t * p[2].x, u * u * p[0].y + 2 * u * t * p[1].y + t * t * p[2].y))
                    }
                }
            }
            for segment in segments {
                switch segment {
                case .move(let p): finish(false); current = [p]
                case .line(let p): current.append(p)
                case .cubic(let a, let b, let c): if let last = current.last { curve([last, a, b, c]) } else { current = [c] }
                case .quad(let a, let b): if let last = current.last { curve([last, a, b]) } else { current = [b] }
                case .close: let start = current.first; finish(true); if let start { current = [start] }
                }
            }
            if current.count > 1 { finish(false) }
            return out
        }

        static func isRectangle(_ s: [PathSegment]) -> Bool {
            let points = flatten(s).flatMap(\.points)
            guard let box = s.controlBounds, points.count >= 4, points.count <= 5 else { return false }
            let eps = 1e-6 * max(1, Double(max(box.width, box.height)))
            return points.allSatisfy { (abs($0.x - Double(box.minX)) < eps || abs($0.x - Double(box.maxX)) < eps) &&
                                       (abs($0.y - Double(box.minY)) < eps || abs($0.y - Double(box.maxY)) < eps) }
        }

        static func meanColour(_ asset: ImageAsset) -> VectorColour {
            guard let image = asset.frames.first?.cgImage() else { return .black }
            var px = [UInt8](repeating: 0, count: 4)
            px.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
                ctx?.interpolationQuality = .medium
                ctx?.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return VectorColour(red: Double(px[0]) / 255, green: Double(px[1]) / 255, blue: Double(px[2]) / 255)
        }
    }

    // MARK: Encoding

    /// One picture: its descriptor, colour table and body, with attributes written only when they change.
    struct PictureEncoder {
        let page: VectorPage
        let indexed: Bool
        let fonts: [String]
        let scale: Double
        var table: [RGB: Int] = [:]
        private var state: [String: [UInt8]] = [:]

        init(page: VectorPage, indexed: Bool, fonts: [String]) {
            self.page = page; self.indexed = indexed; self.fonts = fonts
            scale = 32_000 / max(page.size.width, page.size.height, 1)
        }

        func vdc(_ v: Double) -> [UInt8] { CGMStream.int(Int((v * scale).rounded())) }
        func point(_ p: VectorPoint) -> [UInt8] { vdc(p.x) + vdc(p.y) }
        func colour(_ c: VectorColour) -> [UInt8] {
            let rgb = RGB(c)
            return indexed ? [UInt8(table[rgb] ?? 0)] : [rgb.r, rgb.g, rgb.b]
        }

        /// Writes an attribute element unless the same value is already in force.
        mutating func attribute(_ cls: Int, _ id: Int, _ params: [UInt8], into out: inout CGMStream) {
            let key = "\(cls).\(id)"
            if state[key] == params { return }
            state[key] = params
            out.element(cls, id, params)
        }

        mutating func clip(_ rect: CGRect?, into out: inout CGMStream) {
            let r = rect ?? CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height)
            attribute(3, 5, point(VectorPoint(Double(r.minX), Double(r.minY))) + point(VectorPoint(Double(r.maxX), Double(r.maxY))), into: &out)
        }

        mutating func line(_ l: Line, into out: inout CGMStream) {
            attribute(5, 2, CGMStream.int(l.type), into: &out)
            attribute(5, 3, vdc(l.width), into: &out)
            attribute(5, 4, colour(l.colour), into: &out)
        }

        mutating func encode(_ prims: [Primitive], number: Int, into out: inout CGMStream) {
            out.element(0, 3, CGMStream.string("Page \(number)"))                          // BEGIN PICTURE
            // SCALING MODE metric; the factor (mm per VDC unit) is always floating point (ISO 8632-3 §8.3).
            out.element(2, 1, CGMStream.int(1) + CGMStream.float(25.4 / 72 / scale))
            out.element(2, 2, CGMStream.int(indexed ? 0 : 1))                             // COLOUR SELECTION MODE
            out.element(2, 3, CGMStream.int(0))                                           // LINE WIDTH SPECIFICATION MODE: absolute
            out.element(2, 5, CGMStream.int(0))                                           // EDGE WIDTH SPECIFICATION MODE: absolute
            out.element(2, 6, point(VectorPoint(0, 0)) + point(VectorPoint(page.size.width, page.size.height))) // VDC EXTENT
            let background = RGB(page.background ?? .white)
            out.element(2, 7, [background.r, background.g, background.b])                 // BACKGROUND COLOUR
            out.element(0, 4, [])                                                         // BEGIN PICTURE BODY
            if indexed {
                let entries = table.sorted { $0.value < $1.value }
                out.element(5, 34, [1] + entries.flatMap { [$0.key.r, $0.key.g, $0.key.b] }) // COLOUR TABLE from index 1
            }
            out.element(3, 6, CGMStream.int(1))                                           // CLIP INDICATOR on
            for prim in prims { primitive(prim, into: &out) }
            out.element(0, 5, [])                                                         // END PICTURE
        }

        mutating func primitive(_ prim: Primitive, into out: inout CGMStream) {
            switch prim {
            case .fill(let rings, let c, let clipRect):
                clip(clipRect, into: &out)
                attribute(5, 22, CGMStream.int(1), into: &out)                            // INTERIOR STYLE solid
                attribute(5, 23, colour(c), into: &out)
                attribute(5, 30, CGMStream.int(0), into: &out)                            // EDGE VISIBILITY off
                if rings.count == 1 {
                    out.element(4, 7, rings[0].flatMap(point))                            // POLYGON
                } else {
                    // POLYGON SET: each vertex with its edge flag (1 visible, 3 close visible).
                    out.element(4, 8, rings.flatMap { ring in ring.indices.flatMap { point(ring[$0]) + CGMStream.int($0 == ring.count - 1 ? 3 : 1) } })
                }
            case .polyline(let points, let l, let clipRect):
                clip(clipRect, into: &out)
                line(l, into: &out)
                out.element(4, 1, points.flatMap(point))
            case .ellipse(let c, let d1, let d2, let fill, let edge, let clipRect):
                clip(clipRect, into: &out)
                attribute(5, 22, CGMStream.int(fill == nil ? 4 : 1), into: &out)          // solid, or empty
                if let fill { attribute(5, 23, colour(fill), into: &out) }
                if let edge {
                    attribute(5, 27, CGMStream.int(edge.type), into: &out)
                    attribute(5, 28, vdc(edge.width), into: &out)
                    attribute(5, 29, colour(edge.colour), into: &out)
                }
                attribute(5, 30, CGMStream.int(edge == nil ? 0 : 1), into: &out)
                out.element(4, 17, point(c) + point(d1) + point(d2))
            case .text(let string, let origin, let base, let up, let height, let font, let c, let clipRect):
                clip(clipRect, into: &out)
                attribute(5, 10, CGMStream.int(font), into: &out)
                attribute(5, 14, colour(c), into: &out)
                attribute(5, 15, vdc(height), into: &out)
                let unit = 1000.0 / scale
                attribute(5, 16, vdc(up.x * unit) + vdc(up.y * unit) + vdc(base.x * unit) + vdc(base.y * unit), into: &out)
                out.element(4, 4, point(origin) + CGMStream.int(1) + CGMStream.string(string))
            case .cells(let image, let p, let r, let q, let clipRect):
                clip(clipRect, into: &out)
                out.element(4, 9, cellArray(image, p: p, r: r, q: q))
            }
        }

        /// CELL ARRAY in packed direct colour, rows padded to a word; large pictures are reduced to 1024 cells a side.
        func cellArray(_ image: CGImage, p: VectorPoint, r: VectorPoint, q: VectorPoint) -> [UInt8] {
            let reduce = min(1, 1024 / Double(max(image.width, image.height)))
            let nx = max(1, Int(Double(image.width) * reduce)), ny = max(1, Int(Double(image.height) * reduce))
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let rgb: [UInt8]
            if let ctx = CGContext(data: nil, width: nx, height: ny, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: nx, height: ny))
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: nx, height: ny))
                rgb = PSImages.rgbBytes(ctx.makeImage()!, space: space).map { [UInt8]($0) } ?? []
            } else { rgb = [] }
            var params = point(p) + point(q) + point(r) + CGMStream.int(nx) + CGMStream.int(ny) + CGMStream.int(0) + CGMStream.int(1)
            for row in 0..<ny {
                let start = row * nx * 3
                params += rgb.count >= start + nx * 3 ? Array(rgb[start..<start + nx * 3]) : [UInt8](repeating: 255, count: nx * 3)
                if (nx * 3) % 2 == 1 { params.append(0) }
            }
            return params
        }
    }
}

/// Binary CGM element encoding (ISO 8632-3 §5): big-endian words, the short form for parameter lists under 31 bytes,
/// the long form in partitions otherwise; every element starts on a word boundary.
struct CGMStream {
    var bytes: [UInt8] = []

    mutating func element(_ cls: Int, _ id: Int, _ params: [UInt8]) {
        let head = cls << 12 | id << 5
        if params.count < 31 {
            word(head | params.count)
            bytes += params
            if params.count % 2 == 1 { bytes.append(0) }
            return
        }
        word(head | 31)
        var at = 0
        repeat {
            let length = min(32_766, params.count - at)
            word((at + length < params.count ? 0x8000 : 0) | length)
            bytes += params[at..<at + length]
            at += length
        } while at < params.count
        if params.count % 2 == 1 { bytes.append(0) }
    }

    private mutating func word(_ v: Int) { bytes.append(UInt8(v >> 8 & 0xFF)); bytes.append(UInt8(v & 0xFF)) }

    /// A 16-bit signed integer (the default integer, index, enumeration and VDC precision).
    static func int(_ v: Int) -> [UInt8] {
        let c = UInt16(bitPattern: Int16(max(-32_768, min(32_767, v))))
        return [UInt8(c >> 8), UInt8(c & 0xFF)]
    }

    /// A 32-bit IEEE float.
    static func float(_ v: Double) -> [UInt8] {
        let b = Float(v).bitPattern
        return [UInt8(b >> 24), UInt8(b >> 16 & 0xFF), UInt8(b >> 8 & 0xFF), UInt8(b & 0xFF)]
    }

    /// A string: a length byte (or 255 and a 16-bit length) and ISO 8859-1 characters (others become "?").
    static func string(_ s: String) -> [UInt8] {
        let chars = s.unicodeScalars.prefix(32_767).map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }
        return (chars.count < 255 ? [UInt8(chars.count)] : [255] + int(chars.count)) + chars
    }
}
