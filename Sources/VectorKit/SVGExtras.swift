import CoreGraphics
import Foundation
import SuperConverterCore

extension SVGInterpreter {
    // MARK: Images

    func loadImageData(_ href: String) -> (data: Data, isSVG: Bool)? {
        let text = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("data:") {
            guard let comma = text.firstIndex(of: ",") else { return nil }
            let header = text[text.index(text.startIndex, offsetBy: 5)..<comma].lowercased()
            let body = String(text[text.index(after: comma)...])
            let data: Data?
            if header.contains(";base64") { data = Data(base64Encoded: body.filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters) }
            else { data = body.removingPercentEncoding?.data(using: .utf8) }
            return data.map { ($0, header.contains("svg")) }
        }
        guard let base = baseURL, !text.contains("://") else { return nil }
        let dir = base.hasDirectoryPath ? base : base.deletingLastPathComponent()
        let decoded = text.removingPercentEncoding ?? text
        let url = dir.appendingPathComponent(decoded).standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(dir.standardizedFileURL.resolvingSymlinksInPath().path),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 200 << 20,
              let data = try? Data(contentsOf: url) else { return nil }
        return (data, url.pathExtension.lowercased().hasPrefix("svg"))
    }

    func renderImage(_ node: XNode, ctx: SVGContext, into out: inout [VectorNode]) {
        guard ctx.props["visibility"] != "hidden", let href = node.attr("href"), let loaded = loadImageData(href) else { return }
        let x = length(node.attr("x"), ctx.props, percentBase: ctx.vw), y = length(node.attr("y"), ctx.props, percentBase: ctx.vh)
        var w = node.attr("width").map { length($0, ctx.props, percentBase: ctx.vw) }
        var h = node.attr("height").map { length($0, ctx.props, percentBase: ctx.vh) }
        let intrinsic: CGSize
        let content: VectorNode
        if loaded.isSVG {
            guard useStack.count < 4, let nested = try? SVGReader.read(loaded.data, baseURL: nil), let page = nested.document.pages.first else { return }
            intrinsic = CGSize(width: page.size.width / 0.75, height: page.size.height / 0.75)
            // Page space (points, y up) → image space (px, y down, origin top-left).
            let toImage = VectorTransform(a: 1 / 0.75, b: 0, c: 0, d: -1 / 0.75, tx: 0, ty: page.size.height / 0.75)
            content = .group(page.nodes, transform: toImage, clip: nil, opacity: 1)
        } else {
            guard let asset = ImageBridge.asset(decoding: loaded.data), let frame = asset.frames.first else { return }
            intrinsic = CGSize(width: frame.width, height: frame.height)
            content = .image(asset, transform: VectorTransform(a: Double(intrinsic.width), b: 0, c: 0, d: -Double(intrinsic.height), tx: 0, ty: Double(intrinsic.height)))
        }
        let iw = Double(intrinsic.width), ih = Double(intrinsic.height)
        if w == nil, h == nil { w = iw; h = ih }
        else if w == nil { w = h! * iw / ih }
        else if h == nil { h = w! * ih / iw }
        guard let width = w, let height = h, width > 0, height > 0 else { return }
        let fit = viewBoxTransform(viewBox: CGRect(origin: .zero, size: intrinsic), preserveAspectRatio: node.attr("preserveAspectRatio"), width: width, height: height)
        let toPage = fit.then(.translation(x, y)).then(ctx.ctm)
        var placed = [Self.transformNode(content, by: toPage)]
        if (node.attr("preserveAspectRatio") ?? "").contains("slice") || loaded.isSVG {
            placed = [.group(placed, transform: .identity, clip: PathBuilder.rect(x: x, y: y, width: width, height: height).transformed(by: ctx.ctm), opacity: 1)]
        }
        out.append(contentsOf: placed)
    }

    /// Pre-multiplies a node's own placement by `t` (images by their transform, groups by theirs, everything else wrapped).
    static func transformNode(_ node: VectorNode, by t: VectorTransform) -> VectorNode {
        switch node {
        case .image(let asset, let own): return .image(asset, transform: own.then(t))
        case .group(let kids, let own, let clip, let opacity): return .group(kids, transform: own.then(t), clip: clip, opacity: opacity)
        default: return .group([node], transform: t, clip: nil, opacity: 1)
        }
    }

    // MARK: Masks

    func applyMask(_ value: String, to produced: [VectorNode], ctx: SVGContext, node: XNode) -> [VectorNode] {
        guard let mask = reference(value), mask.name == "mask" else { return produced }
        let boxes = produced.compactMap(\.bounds)
        guard var bounds = boxes.first else { return produced }
        for b in boxes.dropFirst() { bounds = bounds.union(b) }
        let userBox = userBounds(of: produced, ctx: ctx)
        let objectBox = (mask.attr("maskUnits") ?? "objectBoundingBox") == "objectBoundingBox"
        let ubw = Double(userBox.width), ubh = Double(userBox.height), ubx = Double(userBox.minX), uby = Double(userBox.minY)
        func frac(_ key: String, _ def: Double, base: Double, size: Double, origin: Double) -> Double {
            let l = SVGValues.length(mask.attr(key)) ?? SVGValues.Length(value: def * 100, unit: "%")
            if objectBox { return origin + (l.isPercent ? l.value / 100 : l.value) * size }
            return Self.px(l, fontSize: 16, percentBase: base)
        }
        let rx = frac("x", -0.1, base: ctx.vw, size: ubw, origin: ubx)
        let ry = frac("y", -0.1, base: ctx.vh, size: ubh, origin: uby)
        var rw = frac("width", 1.2, base: ctx.vw, size: ubw, origin: 0)
        var rh = frac("height", 1.2, base: ctx.vh, size: ubh, origin: 0)
        if !objectBox {
            rw = Self.px(SVGValues.length(mask.attr("width")) ?? .init(value: 120, unit: "%"), fontSize: 16, percentBase: ctx.vw)
            rh = Self.px(SVGValues.length(mask.attr("height")) ?? .init(value: 120, unit: "%"), fontSize: 16, percentBase: ctx.vh)
        }
        let regionUser = CGRect(x: rx, y: ry, width: rw, height: rh)
        var region = regionUser.applying(ctx.ctm.cg).intersection(bounds.insetBy(dx: -1, dy: -1))
        if region.isNull || region.width < 0.5 || region.height < 0.5 { return [] }
        region = region.integral

        var maskCtm = ctx.ctm
        if (mask.attr("maskContentUnits") ?? "userSpaceOnUse") == "objectBoundingBox" {
            maskCtm = VectorTransform(a: ubw, b: 0, c: 0, d: ubh, tx: ubx, ty: uby).then(ctx.ctm)
        }
        var maskProps = computeProps(mask, parent: ctx.props)
        maskProps["mask"] = nil; maskProps["opacity"] = nil; maskProps["clip-path"] = nil
        var maskNodes: [VectorNode] = []
        let savedStack = useStack
        renderChildren(of: mask, ctx: SVGContext(ctm: maskCtm, props: maskProps, viewport: ctx.viewport), into: &maskNodes)
        useStack = savedStack

        let regionW = Double(region.width), regionH = Double(region.height)
        let scale = min(3.0, 4096 / max(regionW, regionH))
        func bitmap(_ nodes: [VectorNode]) -> CGImage? {
            let shifted = VectorNode.group(nodes, transform: .translation(-Double(region.minX), -Double(region.minY)), clip: nil, opacity: 1)
            return VectorDrawing.render(VectorPage(size: VectorSize(width: regionW, height: regionH), nodes: [shifted]), scale: scale, background: nil)
        }
        guard let content = bitmap(produced), let maskImage = bitmap(maskNodes) else { return produced }
        let w = content.width, h = content.height
        var contentPixels = [UInt8](repeating: 0, count: w * h * 4), maskPixels = contentPixels
        func fill(_ image: CGImage, _ buffer: inout [UInt8]) {
            buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                if let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) { c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)) }
            }
        }
        fill(content, &contentPixels); fill(maskImage, &maskPixels)
        // Luminance of the mask (premultiplied, so black-on-transparent contributes nothing) scales the content alpha.
        for p in stride(from: 0, to: w * h * 4, by: 4) {
            let lum = (0.2125 * Double(maskPixels[p]) + 0.7154 * Double(maskPixels[p + 1]) + 0.0721 * Double(maskPixels[p + 2])) / 255
            for c in 0..<4 { contentPixels[p + c] = UInt8(max(0, min(255, (Double(contentPixels[p + c]) * lum).rounded()))) }
        }
        var straight = contentPixels
        for p in stride(from: 0, to: w * h * 4, by: 4) {
            let a = Int(straight[p + 3])
            if a > 0 && a < 255 { for c in 0..<3 { straight[p + c] = UInt8(min(255, (Int(straight[p + c]) * 255 + a / 2) / a)) } }
        }
        let asset = ImageAsset(frames: [ImageFrame(width: w, height: h, pixels: .rgba8(Data(straight), bytesPerRow: w * 4), hasAlpha: true)])
        note(.otherLoss, "A mask became a picture")
        return [.image(asset, transform: VectorTransform(a: regionW, b: 0, c: 0, d: regionH, tx: Double(region.minX), ty: Double(region.minY)))]
    }

    // MARK: Markers

    func markers(for segments: [PathSegment], node: XNode, ctx: SVGContext) -> [VectorNode] {
        let props = ctx.props
        let startRef = props["marker-start"], midRef = props["marker-mid"], endRef = props["marker-end"]
        guard [startRef, midRef, endRef].contains(where: { $0 != nil && $0 != "none" }) else { return [] }
        struct Vertex { var p: VectorPoint; var inDir: VectorPoint?; var outDir: VectorPoint? }
        var vertices: [Vertex] = []
        var cur = VectorPoint(0, 0), start = VectorPoint(0, 0)
        func dir(_ a: VectorPoint, _ b: VectorPoint) -> VectorPoint? { (a.x == b.x && a.y == b.y) ? nil : VectorPoint(b.x - a.x, b.y - a.y) }
        for s in segments {
            switch s {
            case .move(let p): vertices.append(Vertex(p: p)); cur = p; start = p
            case .line(let p): let d = dir(cur, p); vertices[vertices.count - 1].outDir = d; vertices.append(Vertex(p: p, inDir: d)); cur = p
            case .quad(let c, let p):
                vertices[vertices.count - 1].outDir = dir(cur, c) ?? dir(cur, p); vertices.append(Vertex(p: p, inDir: dir(c, p) ?? dir(cur, p))); cur = p
            case .cubic(let c1, let c2, let p):
                vertices[vertices.count - 1].outDir = dir(cur, c1) ?? dir(cur, c2) ?? dir(cur, p)
                vertices.append(Vertex(p: p, inDir: dir(c2, p) ?? dir(c1, p) ?? dir(cur, p))); cur = p
            case .close:
                let d = dir(cur, start)
                if !vertices.isEmpty { vertices[vertices.count - 1].outDir = d }
                vertices.append(Vertex(p: start, inDir: d)); cur = start
            }
        }
        guard !vertices.isEmpty else { return [] }
        let strokeWidth = length(props["stroke-width"], props, percentBase: ctx.vw, default: 1)
        var out: [VectorNode] = []
        func angle(_ v: Vertex) -> Double {
            func a(_ d: VectorPoint) -> Double { atan2(d.y, d.x) }
            switch (v.inDir, v.outDir) {
            case (let i?, let o?):
                let ai = a(i), ao = a(o)
                var diff = ao - ai
                while diff > .pi { diff -= 2 * .pi }
                while diff < -.pi { diff += 2 * .pi }
                return ai + diff / 2
            case (let i?, nil): return a(i)
            case (nil, let o?): return a(o)
            default: return 0
            }
        }
        for (index, v) in vertices.enumerated() {
            let isFirst = index == 0, isLast = index == vertices.count - 1
            let ref = isFirst ? startRef : isLast ? endRef : midRef
            guard let ref, ref != "none", let marker = reference(ref), marker.name == "marker" else { continue }
            out.append(contentsOf: instantiateMarker(marker, at: v.p, angle: angle(v), isStart: isFirst, strokeWidth: strokeWidth, ctx: ctx))
        }
        return out
    }

    func instantiateMarker(_ marker: XNode, at point: VectorPoint, angle autoAngle: Double, isStart: Bool, strokeWidth: Double, ctx: SVGContext) -> [VectorNode] {
        let mw = length(marker.attr("markerWidth"), ctx.props, percentBase: ctx.vw, default: 3)
        let mh = length(marker.attr("markerHeight"), ctx.props, percentBase: ctx.vh, default: 3)
        guard mw > 0, mh > 0 else { return [] }
        let vbNumbers = SVGValues.numberList(marker.attr("viewBox"))
        let vb = vbNumbers.count == 4 && vbNumbers[2] > 0 && vbNumbers[3] > 0 ? CGRect(x: vbNumbers[0], y: vbNumbers[1], width: vbNumbers[2], height: vbNumbers[3]) : nil
        let fit = viewBoxTransform(viewBox: vb, preserveAspectRatio: marker.attr("preserveAspectRatio"), width: mw, height: mh)
        let vbW: Double = vb.map { Double($0.width) } ?? mw, vbH: Double = vb.map { Double($0.height) } ?? mh
        let refX = length(marker.attr("refX"), ctx.props, percentBase: vbW), refY = length(marker.attr("refY"), ctx.props, percentBase: vbH)
        let ref = fit.apply(VectorPoint(refX, refY))
        var degrees = autoAngle * 180 / .pi
        switch marker.attr("orient") ?? "0" {
        case "auto": break
        case "auto-start-reverse": if isStart { degrees += 180 }
        case let value: degrees = Double(value.replacingOccurrences(of: "deg", with: "")) ?? 0
        }
        let scale = (marker.attr("markerUnits") ?? "strokeWidth") == "strokeWidth" ? strokeWidth : 1
        let r = degrees * .pi / 180
        let place = VectorTransform.translation(-ref.x, -ref.y).then(.scale(scale, scale))
            .then(VectorTransform(a: cos(r), b: sin(r), c: -sin(r), d: cos(r), tx: 0, ty: 0)).then(.translation(point.x, point.y)).then(ctx.ctm)
        var props = computeProps(marker, parent: Self.rootProps)
        props["transform"] = nil
        var inner: [VectorNode] = []
        guard useStack.count < 8 else { return [] }
        useStack.append(marker)
        defer { _ = useStack.popLast() }
        renderChildren(of: marker, ctx: SVGContext(ctm: fit.then(place), props: props, viewport: CGSize(width: vbW, height: vbH)), into: &inner)
        guard !inner.isEmpty else { return [] }
        let overflow = marker.attr("overflow") ?? props["overflow"] ?? "hidden"
        if overflow == "visible" || overflow == "auto" { return inner }
        return [.group(inner, transform: .identity, clip: PathBuilder.rect(x: 0, y: 0, width: mw, height: mh).transformed(by: place), opacity: 1)]
    }
}
