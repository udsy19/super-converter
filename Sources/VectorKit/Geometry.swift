import CoreGraphics
import Foundation
import SuperConverterCore

// Geometry helpers over the Core vector model: transforms, path conversion to and from CoreGraphics, bounds. Shared by
// every reader and writer in VectorKit and by the engines that import it (XPSKit, CADKit, TypesetKit).

public extension VectorTransform {
    init(_ t: CGAffineTransform) { self.init(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.tx, ty: t.ty) }
    var cg: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
    var isIdentity: Bool { self == .identity }

    static func translation(_ x: Double, _ y: Double) -> VectorTransform { VectorTransform(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y) }
    static func scale(_ x: Double, _ y: Double) -> VectorTransform { VectorTransform(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0) }

    /// `self` applied first, then `other` (PDF `cm` order: new = self × old is `old.then(self)`).
    func then(_ other: VectorTransform) -> VectorTransform { VectorTransform(cg.concatenating(other.cg)) }

    func apply(_ p: VectorPoint) -> VectorPoint { VectorPoint(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty) }

    var determinant: Double { a * d - b * c }

    var inverted: VectorTransform? {
        let det = determinant
        guard abs(det) > 1e-12 else { return nil }
        return VectorTransform(cg.inverted())
    }

    /// The uniform scale this transform applies to lengths (√|det|), and whether it is a similarity (no shear, equal
    /// scale on both axes) so strokes and circles survive being flattened into leaf coordinates.
    var lengthScale: Double { abs(determinant).squareRoot() }
    var isSimilarity: Bool {
        let s1 = (a * a + b * b).squareRoot(), s2 = (c * c + d * d).squareRoot()
        guard s1 > 1e-12, s2 > 1e-12 else { return false }
        return abs(s1 - s2) < 1e-6 * max(s1, s2) && abs(a * c + b * d) < 1e-6 * s1 * s2
    }
}

public extension VectorPoint {
    var cg: CGPoint { CGPoint(x: x, y: y) }
    init(_ p: CGPoint) { self.init(Double(p.x), Double(p.y)) }
}

public extension Array where Element == PathSegment {
    /// The segments with every point mapped through `t`.
    func transformed(by t: VectorTransform) -> [PathSegment] {
        if t.isIdentity { return self }
        return map { segment in
            switch segment {
            case .move(let p): .move(t.apply(p))
            case .line(let p): .line(t.apply(p))
            case .cubic(let a, let b, let c): .cubic(t.apply(a), t.apply(b), t.apply(c))
            case .quad(let a, let b): .quad(t.apply(a), t.apply(b))
            case .close: .close
            }
        }
    }

    var cgPath: CGPath {
        let path = CGMutablePath()
        var started = false
        for segment in self {
            switch segment {
            case .move(let p): path.move(to: p.cg); started = true
            case .line(let p): if started { path.addLine(to: p.cg) } else { path.move(to: p.cg); started = true }
            case .cubic(let a, let b, let c): if started { path.addCurve(to: c.cg, control1: a.cg, control2: b.cg) }
            case .quad(let a, let b): if started { path.addQuadCurve(to: b.cg, control: a.cg) }
            case .close: if started { path.closeSubpath() }
            }
        }
        return path
    }

    /// Bounds of the control polygon (cheap, never smaller than the curve).
    var controlBounds: CGRect? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ p: VectorPoint) { minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x); minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y) }
        for segment in self {
            switch segment {
            case .move(let p), .line(let p): add(p)
            case .cubic(let a, let b, let c): add(a); add(b); add(c)
            case .quad(let a, let b): add(a); add(b)
            case .close: break
            }
        }
        return minX.isFinite ? CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : nil
    }
}

public extension CGPath {
    /// The path as model segments (quadratic curves stay quadratic; arcs are already curves in CGPath).
    var segments: [PathSegment] {
        var out: [PathSegment] = []
        applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: out.append(.move(VectorPoint(p[0])))
            case .addLineToPoint: out.append(.line(VectorPoint(p[0])))
            case .addQuadCurveToPoint: out.append(.quad(VectorPoint(p[0]), VectorPoint(p[1])))
            case .addCurveToPoint: out.append(.cubic(VectorPoint(p[0]), VectorPoint(p[1]), VectorPoint(p[2])))
            case .closeSubpath: out.append(.close)
            @unknown default: break
            }
        }
        return out
    }
}

public enum PathBuilder {
    /// An ellipse (or circle) as four cubic Béziers, starting at the right-most point and running counter-clockwise.
    public static func ellipse(cx: Double, cy: Double, rx: Double, ry: Double) -> [PathSegment] {
        let k = 0.5522847498307936
        let p = { VectorPoint($0, $1) }
        return [
            .move(p(cx + rx, cy)),
            .cubic(p(cx + rx, cy + k * ry), p(cx + k * rx, cy + ry), p(cx, cy + ry)),
            .cubic(p(cx - k * rx, cy + ry), p(cx - rx, cy + k * ry), p(cx - rx, cy)),
            .cubic(p(cx - rx, cy - k * ry), p(cx - k * rx, cy - ry), p(cx, cy - ry)),
            .cubic(p(cx + k * rx, cy - ry), p(cx + rx, cy - k * ry), p(cx + rx, cy)),
            .close,
        ]
    }

    public static func rect(x: Double, y: Double, width: Double, height: Double) -> [PathSegment] {
        [.move(VectorPoint(x, y)), .line(VectorPoint(x + width, y)), .line(VectorPoint(x + width, y + height)), .line(VectorPoint(x, y + height)), .close]
    }

    /// An SVG elliptical arc from `from` to `to` as cubic Béziers (SVG 1.1 implementation notes F.6).
    public static func arc(from: VectorPoint, to: VectorPoint, rx rxIn: Double, ry ryIn: Double, rotation: Double, large: Bool, sweep: Bool) -> [PathSegment] {
        var rx = abs(rxIn), ry = abs(ryIn)
        if from == to { return [] }
        if rx == 0 || ry == 0 { return [.line(to)] }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { let s = lambda.squareRoot(); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den == 0 ? 0 : (max(0, num / den)).squareRoot()
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (from.x + to.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (from.y + to.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy, len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var delta = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        let n = max(1, Int(ceil(abs(delta) / (.pi / 2) - 1e-9)))
        let step = delta / Double(n)
        let t = 4.0 / 3.0 * tan(step / 4)
        var out: [PathSegment] = []
        var a1 = theta1
        for i in 0..<n {
            let a2 = a1 + step
            func point(_ a: Double) -> (Double, Double) { (cos(a), sin(a)) }
            let (c1, s1) = point(a1), (c2, s2) = point(a2)
            func map(_ x: Double, _ y: Double) -> VectorPoint {
                VectorPoint(cosPhi * rx * x - sinPhi * ry * y + cx, sinPhi * rx * x + cosPhi * ry * y + cy)
            }
            let end = i == n - 1 ? to : map(c2, s2)
            out.append(.cubic(map(c1 - t * s1, s1 + t * c1), map(c2 + t * s2, s2 - t * c2), end))
            a1 = a2
        }
        return out
    }
}

public extension VectorNode {
    /// The node's bounding box in its own coordinates (control-polygon bounds for paths; strokes widened; text estimated).
    var bounds: CGRect? {
        switch self {
        case .path(let segments, _, let stroke, _):
            guard let box = segments.controlBounds else { return nil }
            let w = (stroke?.width ?? 0) / 2
            return box.insetBy(dx: -w, dy: -w)
        case .text(let run):
            let width = Double(run.text.count) * run.size * 0.5
            return CGRect(x: run.origin.x, y: run.origin.y - run.size * 0.25, width: width, height: run.size)
        case .image(_, let t):
            return CGRect(x: 0, y: 0, width: 1, height: 1).applying(t.cg)
        case .group(let children, let t, _, _):
            let boxes = children.compactMap(\.bounds)
            guard var box = boxes.first else { return nil }
            for b in boxes.dropFirst() { box = box.union(b) }
            return box.applying(t.cg)
        }
    }
}

public extension VectorPage {
    /// Union of the nodes' bounds, or nil for an empty page.
    var contentBounds: CGRect? {
        let boxes = nodes.compactMap(\.bounds)
        guard var box = boxes.first else { return nil }
        for b in boxes.dropFirst() { box = box.union(b) }
        return box
    }

    /// Every path/text/image node, depth first, with the group transforms applied to nothing (counts only).
    var nodeCount: Int { nodes.reduce(0) { $0 + $1.leafCount } }
}

public extension VectorNode {
    var leafCount: Int {
        if case .group(let children, _, _, _) = self { return children.reduce(0) { $0 + $1.leafCount } }
        return 1
    }
}

public extension VectorColour {
    var cg: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    static let black = VectorColour(red: 0, green: 0, blue: 0)
    static let white = VectorColour(red: 1, green: 1, blue: 1)
}

extension Double {
    /// The value as an Int when it is finite and in range, else nil: a damaged file can hold any number where a count, an
    /// index or a mode belongs, and `Int(_:)` traps outside the range.
    var checkedInt: Int? { isFinite && magnitude < 0x1p62 ? Int(self) : nil }
}

/// How deep the readers nest groups (clips, layers, saved states, containers): a damaged file can open thousands, and
/// everything that walks the model (bounds, drawing, the writers) recurses through them.
let maxGroupNesting = 128
