import Foundation
import SuperConverterCore

/// Skencil (`.sk`, "##Sketch 1 x") and sK1 (`.sk1`, "##sK1 1 x") drawings (formats §3.2, P3). Both are line-oriented text:
/// every line is a call with Python literal arguments (`fp((1,0,0))`, `r(100,0,0,50,10,10)`), properties first, then the
/// object they style, layers bottom to top (Skencil Developer's Guide, "File Format"). sK1 is Skencil's fork; it writes the
/// same calls with colours that name their space (`["CMYK", [c, m, y, k], alpha, name]`). Read from the published format
/// description and sample files; no Skencil or sK1 code (GPL) is used. Coordinates are PostScript points, y up, as in the
/// model.
public enum SKReader {
    public enum Dialect: Sendable { case skencil, sk1 }

    public static func read(_ data: Data, dialect: Dialect) throws -> VectorReadResult {
        let format: FormatID = dialect == .skencil ? "sk" : "sk1"
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw ConversionError.damaged(format) }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        let magic = dialect == .skencil ? "##Sketch" : "##sK1"
        guard let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), first.hasPrefix(magic) else {
            throw ConversionError.damaged(format)
        }
        var loader = Loader()
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let call = SKCall.parse(line) else { loader.warnings.append("Line \(index) couldn’t be read: \(line.prefix(60))"); continue }
            if call.name == "bm" {
                // Inline picture data follows as base64 lines up to a lone "-".
                var payload = ""
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces) != "-" { payload += lines[index].trimmingCharacters(in: .whitespaces); index += 1 }
                index += 1
                loader.bitmap(call, base64: payload)
                continue
            }
            loader.apply(call)
        }
        loader.closeAll()
        let nodes = loader.root
        if nodes.isEmpty && loader.warnings.count > 0 && loader.objectCount == 0 { throw ConversionError.damaged(format) }
        let page = VectorPage(size: loader.pageSize, background: nil, nodes: nodes)
        return VectorReadResult(document: VectorDocument(pages: [page]), lossNotes: Array(loader.lossNotes), warnings: loader.warnings)
    }

    // MARK: Loading

    /// Applies the calls in file order: properties collect into `style`, each object takes the style and resets it.
    struct Loader {
        struct Style {
            var fill: VectorPaint?
            var fillGradient: [GradientStop]?
            var fillGradientKind: (kind: String, args: [SKValue])?
            var line: VectorPaint? = .solid(.black)
            var lineWidth = 0.0
            var cap: LineCap = .butt
            var join: LineJoin = .miter
            var dash: [Double] = []
            var fontName = "Times-Roman"
            var fontSize = 12.0
        }

        var style = Style()
        var styles: [String: Style] = [:]
        /// Open containers (layers, groups, masks); the bottom one is the page.
        var stack: [(kind: String, nodes: [VectorNode])] = [("page", [])]
        /// Containers opened past `maxGroupNesting`: their objects join the container they would sit in.
        var flattened = 0
        var pageSize = VectorSize(width: 595.276, height: 841.89)
        var path: [PathSegment] = []
        var inBezier = false
        /// The next point starts a subpath (after `b()` or `bn()`).
        var subpathStarts = false
        var images: [String: ImageAsset] = [:]
        var lossNotes: Set<LossNote> = []
        var warnings: [String] = []
        var objectCount = 0
        var layerVisible = true

        var root: [VectorNode] { stack[0].nodes }

        mutating func emit(_ node: VectorNode) {
            objectCount += 1
            if layerVisible { stack[stack.count - 1].nodes.append(node) }
        }

        mutating func apply(_ call: SKCall) {
            let a = call.args
            if inBezier, !["bs", "bc", "bn", "bC"].contains(call.name) { finishBezier() }
            switch call.name {
            case "document", "dinfo", "grid", "guide": break
            case "layout":
                if let name = a.first?.string { pageSize = Self.paper(name) }
                else if let dims = a.first?.numbers, dims.count == 2 { pageSize = VectorSize(width: dims[0], height: dims[1]) }
                if a.count > 1, a[1].number == 1 { pageSize = VectorSize(width: pageSize.height, height: pageSize.width) }
            case "layer", "masterlayer", "page":
                closeTo("page")
                layerVisible = a.count > 1 ? (a[1].number ?? 1) != 0 : true
                stack.append(("layer", []))
            case "guidelayer":
                closeTo("page")
                layerVisible = false
                stack.append(("layer", []))
            // Properties.
            case "fp": style.fill = a.first.flatMap(colour).map { .solid($0) }; style.fillGradientKind = nil
            case "fe": style.fill = nil; style.fillGradientKind = nil
            case "lp": style.line = a.first.flatMap(colour).map { .solid($0) }
            case "le": style.line = nil
            case "lw": style.lineWidth = a.first?.number ?? 0
            case "lc": style.cap = [1: .butt, 2: .round, 3: .square][a.first?.number?.checkedInt ?? 1] ?? .butt
            case "lj": style.join = [0: .miter, 1: .round, 2: .bevel][a.first?.number?.checkedInt ?? 0] ?? .miter
            case "ld": style.dash = a.first?.numbers ?? []
            case "la1", "la2": lossNotes.insert(LossNote(.otherLoss, detail: "Arrowheads weren’t drawn"))
            case "Fn": style.fontName = a.first?.string ?? style.fontName
            case "Fs": style.fontSize = a.first?.number ?? style.fontSize
            case "gl": style.fillGradient = gradientStops(a.first)
            case "pgl", "pgr", "pgc":
                style.fillGradientKind = (call.name, a)
                if call.name == "pgc" { lossNotes.insert(LossNote(.otherLoss, detail: "A conical gradient was drawn as a radial one")) }
            case "phs", "pit":
                style.fill = .solid(VectorColour(red: 0.5, green: 0.5, blue: 0.5))
                style.fillGradientKind = nil
                lossNotes.insert(LossNote(.otherLoss, detail: "Hatched and tiled fills were drawn grey"))
            case "dstyle": if let name = a.first?.string { styles[name] = style }; style = Style()
            case "ds": if let name = a.first?.string, let named = styles[name] { style = named }
            // Objects.
            case "r": rectangle(a)
            case "e": ellipse(a)
            case "b": path = []; inBezier = true; subpathStarts = true
            case "bs":
                if let p = point(a, 0) { path.append(subpathStarts || path.last == .close ? .move(p) : .line(p)); subpathStarts = false }
            case "bc":
                if let c1 = point(a, 0), let c2 = point(a, 2), let p = point(a, 4) {
                    path.append(subpathStarts || path.last == .close ? .move(p) : .cubic(c1, c2, p)); subpathStarts = false
                }
            case "bn": subpathStarts = true
            case "bC": if !path.isEmpty { path.append(.close) }
            case "txt", "simple_text": text(a)
            case "im": image(a)
            case "eps":
                lossNotes.insert(LossNote(.imagesDropped, detail: "An embedded EPS picture was left out"))
                style = Style()
            case "G", "M", "B", "Bi": if stack.count < maxGroupNesting { stack.append((call.name, [])) } else { flattened += 1 }
            case "G_", "M_", "B_", "Bi_": if flattened > 0 { flattened -= 1 } else { closeGroup(call.name.dropLast().description) }
            default: warnings.append("“\(call.name)” isn’t read")
            }
        }

        // MARK: Objects

        mutating func finishBezier() {
            inBezier = false
            let segments = path
            path = []
            guard !segments.isEmpty else { style = Style(); return }
            emitShape(segments)
        }

        mutating func emitShape(_ segments: [PathSegment]) {
            let fill = fillPaint(for: segments)
            let stroke = style.line.map {
                VectorStroke(paint: $0, width: max(style.lineWidth, 0.1), dash: style.dash.map { $0 * max(style.lineWidth, 1) },
                             cap: style.cap, join: style.join)
            }
            if fill != nil || stroke != nil { emit(.path(segments, fill: fill, stroke: stroke)) } else { objectCount += 1 }
            style = Style()
        }

        /// The fill, with Skencil's object-relative gradients placed over the shape's bounds.
        func fillPaint(for segments: [PathSegment]) -> VectorPaint? {
            guard let kind = style.fillGradientKind, let stops = style.fillGradient, let box = segments.controlBounds else { return style.fill }
            let n = kind.args.compactMap(\.number)
            switch kind.kind {
            case "pgl":
                // Direction (dx, dy) through the centre, spanning the bounds' projection on it.
                var dx = n.count > 0 ? n[0] : 1, dy = n.count > 1 ? n[1] : 0
                let length = (dx * dx + dy * dy).squareRoot()
                if length > 0 { dx /= length; dy /= length } else { dx = 1; dy = 0 }
                let half = (Double(box.width) * abs(dx) + Double(box.height) * abs(dy)) / 2
                let cx = Double(box.midX), cy = Double(box.midY)
                // Skencil's direction points from the end colour to the start colour.
                return .linear(from: VectorPoint(cx + dx * half, cy + dy * half), to: VectorPoint(cx - dx * half, cy - dy * half), stops: stops)
            default:
                let fx = n.count > 0 ? n[0] : 0.5, fy = n.count > 1 ? n[1] : 0.5
                let c = VectorPoint(Double(box.minX) + fx * Double(box.width), Double(box.minY) + fy * Double(box.height))
                let corners = [(box.minX, box.minY), (box.maxX, box.minY), (box.minX, box.maxY), (box.maxX, box.maxY)]
                let r = corners.map { hypot(Double($0.0) - c.x, Double($0.1) - c.y) }.max() ?? 1
                return .radial(centre: c, radius: r, stops: stops)
            }
        }

        /// `r(m11, m21, m12, m22, v1, v2[, radius1, radius2])`: the unit square under a transform, corners rounded by radii
        /// relative to it.
        mutating func rectangle(_ a: [SKValue]) {
            guard let t = transform(a) else { style = Style(); return }
            let rx = a.count > 7 ? min(abs(a[6].number ?? 0), 0.5) : 0, ry = a.count > 7 ? min(abs(a[7].number ?? 0), 0.5) : 0
            var unit: [PathSegment]
            if rx > 0 && ry > 0 {
                let k = 0.5522847498307936
                let p = { VectorPoint($0, $1) }
                unit = [.move(p(rx, 0)), .line(p(1 - rx, 0)), .cubic(p(1 - rx + k * rx, 0), p(1, ry - k * ry), p(1, ry)),
                        .line(p(1, 1 - ry)), .cubic(p(1, 1 - ry + k * ry), p(1 - rx + k * rx, 1), p(1 - rx, 1)),
                        .line(p(rx, 1)), .cubic(p(rx - k * rx, 1), p(0, 1 - ry + k * ry), p(0, 1 - ry)),
                        .line(p(0, ry)), .cubic(p(0, ry - k * ry), p(rx - k * rx, 0), p(rx, 0)), .close]
            } else {
                unit = PathBuilder.rect(x: 0, y: 0, width: 1, height: 1)
            }
            emitShape(unit.transformed(by: t))
        }

        /// `e(m11, m21, m12, m22, v1, v2[, start, end, arc_type])`: the unit circle under a transform; arcs open (0), chord
        /// (1) or pie slice (2).
        mutating func ellipse(_ a: [SKValue]) {
            guard let t = transform(a) else { style = Style(); return }
            let start = a.count > 7 ? a[6].number ?? 0 : 0, end = a.count > 7 ? a[7].number ?? 0 : 0
            var unit: [PathSegment]
            if a.count > 7, abs(end - start) > 1e-9, abs(abs(end - start) - 2 * .pi) > 1e-9 {
                var sweep = end - start
                if sweep < 0 { sweep += 2 * .pi }
                let from = VectorPoint(cos(start), sin(start)), to = VectorPoint(cos(start + sweep), sin(start + sweep))
                unit = [.move(from)] + PathBuilder.arc(from: from, to: to, rx: 1, ry: 1, rotation: 0, large: sweep > .pi, sweep: true)
                let kind = a.count > 8 ? a[8].number?.checkedInt ?? 0 : 0
                if kind == 2 { unit += [.line(VectorPoint(0, 0)), .close] } else if kind == 1 { unit.append(.close) }
                if kind == 0 { style.fill = nil; style.fillGradientKind = nil }
            } else {
                unit = PathBuilder.ellipse(cx: 0, cy: 0, rx: 1, ry: 1)
            }
            emitShape(unit.transformed(by: t))
        }

        /// `txt(text, trafo[, halign, valign])`, trafo either (x, y) or the six numbers.
        mutating func text(_ a: [SKValue]) {
            guard let string = a.first?.string, a.count > 1, let numbers = a[1].numbers else { style = Style(); return }
            let fill = style.fill ?? style.fillGradient.flatMap { $0.first.map { VectorPaint.solid($0.colour) } } ?? .solid(.black)
            var run = VectorTextRun(text: string, fontName: style.fontName, size: style.fontSize, origin: VectorPoint(0, 0), fill: fill)
            if numbers.count == 2 {
                run.origin = VectorPoint(numbers[0], numbers[1])
                emit(.text(run))
            } else if numbers.count == 6 {
                let t = VectorTransform(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], tx: numbers[4], ty: numbers[5])
                if abs(t.a - 1) < 1e-9, abs(t.d - 1) < 1e-9, abs(t.b) < 1e-9, abs(t.c) < 1e-9 {
                    run.origin = VectorPoint(t.tx, t.ty)
                    emit(.text(run))
                } else {
                    emit(.group([.text(run)], transform: t, clip: nil, opacity: 1))
                }
            }
            if a.count > 2, (a[2].number ?? 0) != 0 { lossNotes.insert(LossNote(.formattingSimplified, detail: "Centred and right-aligned text was placed from its start")) }
            style = Style()
        }

        mutating func bitmap(_ call: SKCall, base64: String) {
            guard let id = call.args.first?.idKey else { return }
            if call.args.count > 1, let file = call.args[1].string {
                lossNotes.insert(LossNote(.imagesDropped, detail: "A linked picture (\(file)) wasn’t embedded"))
                return
            }
            if let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters), let asset = ImageBridge.asset(decoding: data) {
                images[id] = asset
            } else {
                lossNotes.insert(LossNote(.imagesDropped))
            }
        }

        /// `im(trafo, id)`: the picture's pixels at one unit each under the transform.
        mutating func image(_ a: [SKValue]) {
            guard a.count >= 2, let numbers = a[0].numbers, numbers.count == 6, let id = a[1].idKey, let asset = images[id], let frame = asset.frames.first else {
                lossNotes.insert(LossNote(.imagesDropped)); style = Style(); return
            }
            let t = VectorTransform(a: numbers[0], b: numbers[1], c: numbers[2], d: numbers[3], tx: numbers[4], ty: numbers[5])
            emit(.image(asset, transform: VectorTransform.scale(Double(frame.width), Double(frame.height)).then(t)))
            style = Style()
        }

        // MARK: Containers

        mutating func closeGroup(_ kind: String) {
            guard stack.count > 1, let top = stack.last, top.kind == kind else { return }
            stack.removeLast()
            switch kind {
            case "M":
                // A mask group: its first object is the clip, the rest are drawn inside it.
                guard let mask = top.nodes.first, case .path(let clip, _, _, _) = mask else {
                    stack[stack.count - 1].nodes.append(contentsOf: top.nodes); return
                }
                stack[stack.count - 1].nodes.append(.group(Array(top.nodes.dropFirst()), transform: .identity, clip: clip, opacity: 1))
            case "B", "Bi":
                lossNotes.insert(LossNote(.otherLoss, detail: "Blend groups were drawn as their steps only"))
                stack[stack.count - 1].nodes.append(.group(top.nodes, transform: .identity, clip: nil, opacity: 1))
            default:
                stack[stack.count - 1].nodes.append(.group(top.nodes, transform: .identity, clip: nil, opacity: 1))
            }
        }

        /// Closes open containers down to `kind` (a new layer closes the last one, and any group left open).
        mutating func closeTo(_ kind: String) {
            if inBezier { finishBezier() }
            while stack.count > 1, stack[stack.count - 1].kind != kind {
                let top = stack.removeLast()
                stack[stack.count - 1].nodes.append(contentsOf: top.nodes)
            }
            if kind == "page" { flattened = 0 }
        }

        mutating func closeAll() { closeTo("page") }

        // MARK: Values

        func transform(_ a: [SKValue]) -> VectorTransform? {
            let n = a.prefix(6).compactMap(\.number)
            guard n.count == 6 else { return nil }
            return VectorTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
        }

        func point(_ a: [SKValue], _ i: Int) -> VectorPoint? {
            guard a.count > i + 1, let x = a[i].number, let y = a[i + 1].number else { return nil }
            return VectorPoint(x, y)
        }

        /// An RGB triple (Skencil), or sK1's `[space, values, alpha, name]` / `(space, v1, v2, …)` with RGB, CMYK and grey.
        func colour(_ v: SKValue) -> VectorColour? {
            guard case .list(let items) = v else { return nil }
            if items.count == 3, let n = v.numbers { return VectorColour(red: n[0], green: n[1], blue: n[2]) }
            guard let space = items.first?.string?.uppercased() else { return nil }
            var values: [Double] = []
            var alpha = 1.0
            if items.count > 1, case .list = items[1] {
                values = items[1].numbers ?? []
                if items.count > 2, let a = items[2].number { alpha = a }
            } else {
                values = items.dropFirst().compactMap(\.number)
            }
            switch space {
            case "RGB" where values.count >= 3: return VectorColour(red: values[0], green: values[1], blue: values[2], alpha: alpha)
            case "CMYK" where values.count >= 4:
                let k = values[3]
                return VectorColour(red: (1 - values[0]) * (1 - k), green: (1 - values[1]) * (1 - k), blue: (1 - values[2]) * (1 - k), alpha: alpha)
            case "GRAY" where !values.isEmpty, "GREYSCALE" where !values.isEmpty, "GRAYSCALE" where !values.isEmpty: return VectorColour(red: values[0], green: values[0], blue: values[0], alpha: alpha)
            case "SPOT", "REGISTRATION":
                // [name, [r, g, b], [c, m, y, k]]-style spot colours: use their RGB part when present.
                if let rgb = items.dropFirst().first(where: { ($0.numbers?.count ?? 0) == 3 })?.numbers { return VectorColour(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: alpha) }
                return .black
            default: return nil
            }
        }

        func gradientStops(_ v: SKValue?) -> [GradientStop]? {
            guard case .list(let items)? = v else { return nil }
            let stops = items.compactMap { item -> GradientStop? in
                guard case .list(let pair) = item, pair.count >= 2, let offset = pair[0].number, let c = colour(pair[1]) else { return nil }
                return GradientStop(offset: offset, colour: c)
            }
            return stops.isEmpty ? nil : stops
        }

        static func paper(_ name: String) -> VectorSize {
            let mm = 72 / 25.4
            let sizes: [String: (Double, Double)] = [
                "a0": (841 * mm, 1189 * mm), "a1": (594 * mm, 841 * mm), "a2": (420 * mm, 594 * mm), "a3": (297 * mm, 420 * mm),
                "a4": (210 * mm, 297 * mm), "a5": (148 * mm, 210 * mm), "a6": (105 * mm, 148 * mm), "b4": (250 * mm, 353 * mm),
                "b5": (176 * mm, 250 * mm), "letter": (612, 792), "legal": (612, 1008), "tabloid": (792, 1224), "executive": (522, 756),
            ]
            let s = sizes[name.lowercased()] ?? sizes["a4"]!
            return VectorSize(width: s.0, height: s.1)
        }
    }
}

// MARK: Python literal calls

/// One argument: a number, a string, None, or a tuple/list (keyword arguments keep only their value).
indirect enum SKValue: Equatable {
    case number(Double), string(String), list([SKValue]), none

    var number: Double? { if case .number(let n) = self { n } else { nil } }
    var string: String? { if case .string(let s) = self { s } else { nil } }
    /// Every element as a number, or nil when one isn't.
    var numbers: [Double]? {
        guard case .list(let items) = self else { return nil }
        let n = items.compactMap(\.number)
        return n.count == items.count ? n : nil
    }
    /// An object id written as a number or a string.
    var idKey: String? {
        switch self {
        case .number(let n): n.checkedInt.map { String($0) }
        case .string(let s): s
        default: nil
        }
    }
}

struct SKCall {
    var name: String
    var args: [SKValue]

    /// `name(arg, arg, key=arg)`; nil when the line isn't a call.
    static func parse(_ line: String) -> SKCall? {
        let chars = Array(line.unicodeScalars)
        var i = 0
        var name = ""
        while i < chars.count, CharacterSet.alphanumerics.contains(chars[i]) || chars[i] == "_" { name.unicodeScalars.append(chars[i]); i += 1 }
        guard !name.isEmpty, i < chars.count, chars[i] == "(" else { return nil }
        i += 1
        var args: [SKValue] = []
        while true {
            skipSpace(chars, &i)
            guard i < chars.count else { return nil }
            if chars[i] == ")" { break }
            // key=value: drop the key.
            var j = i
            while j < chars.count, CharacterSet.alphanumerics.contains(chars[j]) || chars[j] == "_" { j += 1 }
            if j > i, j < chars.count, chars[j] == "=", CharacterSet.letters.contains(chars[i]) { i = j + 1 }
            guard let value = parseValue(chars, &i, depth: 0) else { return nil }
            args.append(value)
            skipSpace(chars, &i)
            if i < chars.count, chars[i] == "," { i += 1 }
        }
        return SKCall(name: name, args: args)
    }

    private static func skipSpace(_ c: [Unicode.Scalar], _ i: inout Int) { while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 } }

    private static func parseValue(_ c: [Unicode.Scalar], _ i: inout Int, depth: Int) -> SKValue? {
        skipSpace(c, &i)
        guard i < c.count else { return nil }
        let ch = c[i]
        if ch == "(" || ch == "[" {
            // Real files nest tuples a few levels (gradient stops, sK1 colours); deeper is damage.
            guard depth < 32 else { return nil }
            let close: Unicode.Scalar = ch == "(" ? ")" : "]"
            i += 1
            var items: [SKValue] = []
            while true {
                skipSpace(c, &i)
                guard i < c.count else { return nil }
                if c[i] == close { i += 1; break }
                guard let v = parseValue(c, &i, depth: depth + 1) else { return nil }
                items.append(v)
                skipSpace(c, &i)
                if i < c.count, c[i] == "," { i += 1 }
            }
            return .list(items)
        }
        if ch == "'" || ch == "\"" { return parseString(c, &i) }
        if ch == "u" || ch == "b", i + 1 < c.count, c[i + 1] == "'" || c[i + 1] == "\"" { i += 1; return parseString(c, &i) }
        var token = ""
        while i < c.count, !",)] \t".unicodeScalars.contains(c[i]) { token.unicodeScalars.append(c[i]); i += 1 }
        if token == "None" { return SKValue.none }
        if let n = Double(token) { return .number(n) }
        if token.hasPrefix("0x"), let n = Int(token.dropFirst(2), radix: 16) { return .number(Double(n)) }
        return token.isEmpty ? nil : .string(token)
    }

    /// A Python string literal with `\n`, `\t`, `\\`, quote, `\xhh`, octal and `\uhhhh` escapes; byte escapes are Latin-1
    /// (what Skencil's Python 2 `repr` writes).
    private static func parseString(_ c: [Unicode.Scalar], _ i: inout Int) -> SKValue? {
        let quote = c[i]
        i += 1
        var out = String.UnicodeScalarView()
        while i < c.count, c[i] != quote {
            if c[i] == "\\", i + 1 < c.count {
                i += 1
                let e = c[i]
                switch e {
                case "n": out.append("\n"); i += 1
                case "t": out.append("\t"); i += 1
                case "r": i += 1
                case "x", "u":
                    let width = e == "x" ? 2 : 4
                    let hex = String(String.UnicodeScalarView(c[(i + 1)..<min(c.count, i + 1 + width)]))
                    if let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) { out.append(s) }
                    i += 1 + width
                case "0"..."7":
                    var digits = ""
                    while i < c.count, digits.count < 3, ("0"..."7").contains(c[i]) { digits.unicodeScalars.append(c[i]); i += 1 }
                    if let v = UInt32(digits, radix: 8), let s = Unicode.Scalar(v) { out.append(s) }
                default: out.append(e); i += 1
                }
            } else {
                out.append(c[i]); i += 1
            }
        }
        guard i < c.count else { return nil }
        i += 1
        return .string(String(out))
    }
}
