import AppKit
import Compression
import CoreText
import SuperConverterCore
import VectorKit

// PostScript/EPS and CGM checks (WP-V). macOS 14 removed its PostScript interpreter (CGPSConverter converts nothing), so
// the vector pages are re-drawn by a small interpreter of exactly the operators PSWriter emits and compared by pixels
// with the model drawn directly; fonts are checked by rebuilding the Type 42 sfnts into a font CoreText loads; CGM is
// walked element by element.

// MARK: A reader for PSWriter's own output

/// Draws PSWriter's page operators into a bitmap: paths, fills, strokes, clips, transforms, shadings and images.
private struct SVTPostScript {
    enum Value { case number(Double), name(String), literal(String), array([Value]), dict([String: Value]), mark, bool(Bool), source([String]) }

    let text: [UInt8]
    var at = 0
    var stack: [Value] = []
    let ctx: CGContext
    struct State { var ctm: CGAffineTransform; var path = CGMutablePath(); var rgb: [CGFloat] = [0, 0, 0]; var width: CGFloat = 1 }
    var state: State
    var saved: [State] = []
    var unknown: Set<String> = []
    var glyphs = 0

    init(_ ps: String, size: VectorSize, scale: Double) {
        text = Array(ps.utf8)
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        state = State(ctm: CGAffineTransform(scaleX: scale, y: scale))
    }

    mutating func skipSpace() {
        while at < text.count {
            if text[at] == UInt8(ascii: "%") { while at < text.count, text[at] != 10 { at += 1 } } else if text[at] <= 32 { at += 1 } else { break }
        }
    }

    mutating func run() -> CGImage? {
        while true {
            skipSpace()
            guard at < text.count else { break }
            let c = text[at]
            if c == UInt8(ascii: "[") { stack.append(.mark); at += 1; continue }
            if c == UInt8(ascii: "]") { at += 1; collectArray(); continue }
            if c == UInt8(ascii: "<"), at + 1 < text.count, text[at + 1] == UInt8(ascii: "<") { stack.append(.mark); at += 2; continue }
            if c == UInt8(ascii: ">"), at + 1 < text.count, text[at + 1] == UInt8(ascii: ">") { at += 2; collectDict(); continue }
            var end = at
            while end < text.count, text[end] > 32, !"[]<>/".utf8.contains(text[end]) || end == at { end += 1 }
            let token = String(decoding: text[at..<end], as: UTF8.self)
            at = end
            if token.hasPrefix("/") { stack.append(.literal(String(token.dropFirst()))) }
            else if let n = Double(token) { stack.append(.number(n)) }
            else { execute(token) }
        }
        return ctx.makeImage()
    }

    mutating func collectArray() {
        var items: [Value] = []
        while let v = stack.popLast() { if case .mark = v { break }; items.insert(v, at: 0) }
        stack.append(.array(items))
    }

    mutating func collectDict() {
        var items: [Value] = []
        while let v = stack.popLast() { if case .mark = v { break }; items.insert(v, at: 0) }
        var d: [String: Value] = [:]
        for i in stride(from: 0, to: items.count - 1, by: 2) { if case .literal(let k) = items[i] { d[k] = items[i + 1] } }
        stack.append(.dict(d))
    }

    mutating func num() -> CGFloat { if case .number(let n)? = stack.popLast() { return CGFloat(n) }; return 0 }
    mutating func point() -> CGPoint { let y = num(), x = num(); return CGPoint(x: x, y: y).applying(state.ctm) }
    static func numbers(_ v: Value?) -> [CGFloat] { if case .array(let a)? = v { return a.compactMap { if case .number(let n) = $0 { CGFloat(n) } else { nil } } }; return [] }

    mutating func execute(_ op: String) {
        switch op {
        case "true": stack.append(.bool(true))
        case "false": stack.append(.bool(false))
        case "gsave": saved.append(state); state.path = state.path.mutableCopy()!; ctx.saveGState()
        case "grestore": if let s = saved.popLast() { state = s; ctx.restoreGState() }
        case "newpath": state.path = CGMutablePath()
        case "moveto": state.path.move(to: point())
        case "lineto": state.path.addLine(to: point())
        case "curveto": let c = point(), b = point(), a = point(); state.path.addCurve(to: c, control1: a, control2: b)
        case "closepath": state.path.closeSubpath()
        case "concat": let m = Self.numbers(stack.popLast()); if m.count == 6 { state.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(state.ctm) }
        case "setrgbcolor": let b = num(), g = num(), r = num(); state.rgb = [r, g, b]
        case "setlinewidth": state.width = num()
        case "setlinecap": ctx.setLineCap(CGLineCap(rawValue: Int32(num())) ?? .butt)
        case "setlinejoin": ctx.setLineJoin(CGLineJoin(rawValue: Int32(num())) ?? .miter)
        case "setmiterlimit": ctx.setMiterLimit(num())
        case "setdash":
            // In user space, like the line width: CG applies the CTM when stroking.
            let phase = num(), dash = Self.numbers(stack.popLast())
            ctx.setLineDash(phase: phase, lengths: dash)
        case "fill", "eofill":
            ctx.setFillColor(CGColor(srgbRed: state.rgb[0], green: state.rgb[1], blue: state.rgb[2], alpha: 1))
            ctx.addPath(state.path); ctx.fillPath(using: op == "eofill" ? .evenOdd : .winding); state.path = CGMutablePath()
        case "rectfill":
            let h = num(), w = num(), y = num(), x = num()
            ctx.setFillColor(CGColor(srgbRed: state.rgb[0], green: state.rgb[1], blue: state.rgb[2], alpha: 1))
            ctx.addPath(CGPath(rect: CGRect(x: x, y: y, width: w, height: h), transform: [state.ctm])); ctx.fillPath()
        case "stroke", "strokepath":
            // Stroke in user space: the width, dashes and joins scale with the CTM.
            var inverse = state.ctm.inverted()
            ctx.saveGState(); ctx.concatenate(state.ctm)
            ctx.setLineWidth(state.width)
            ctx.addPath(state.path.copy(using: &inverse)!)
            if op == "stroke" {
                ctx.setStrokeColor(CGColor(srgbRed: state.rgb[0], green: state.rgb[1], blue: state.rgb[2], alpha: 1)); ctx.strokePath()
                ctx.restoreGState(); state.path = CGMutablePath()
            } else {
                ctx.replacePathWithStrokedPath()
                let outline = ctx.path ?? CGMutablePath()
                ctx.restoreGState()
                var forward = state.ctm
                state.path = outline.mutableCopy(using: &forward) ?? CGMutablePath()
            }
        case "clip", "eoclip": ctx.addPath(state.path); ctx.clip(using: op == "eoclip" ? .evenOdd : .winding)
        case "shfill": if case .dict(let d)? = stack.popLast() { shade(d) }
        case "image": if case .dict(let d)? = stack.popLast() { image(d) }
        case "setcolorspace", "setfont", "setpagedevice", "scalefont", "pop": _ = stack.popLast()
        case "findfont": _ = stack.popLast(); stack.append(.literal("font"))
        case "glyphshow": _ = stack.popLast(); glyphs += 1; state.path = CGMutablePath()
        case "currentfile": stack.append(.source([]))
        case "filter": if case .literal(let f)? = stack.popLast(), case .source(let list)? = stack.popLast() { stack.append(.source(list + [f])) }
        case "showpage": break
        default: unknown.insert(op)
        }
    }

    static func colour(_ v: Value?) -> [CGFloat] { numbers(v) }

    /// The shading function as gradient stops (Type 2 between two colours, Type 3 stitching Type 2s).
    static func stops(_ f: [String: Value]) -> [(CGFloat, [CGFloat])] {
        if case .number(2)? = f["FunctionType"] { return [(0, colour(f["C0"])), (1, colour(f["C1"]))] }
        guard case .array(let parts)? = f["Functions"] else { return [] }
        let bounds = [0] + numbers(f["Bounds"]) + [1]
        var out: [(CGFloat, [CGFloat])] = []
        for (i, part) in parts.enumerated() { if case .dict(let p) = part { out.append((bounds[i], colour(p["C0"]))); out.append((bounds[i + 1], colour(p["C1"]))) } }
        return out
    }

    mutating func shade(_ d: [String: Value]) {
        guard case .dict(let f)? = d["Function"] else { return }
        let s = Self.stops(f), coords = Self.numbers(d["Coords"])
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: s.map { CGColor(srgbRed: $0.1[0], green: $0.1[1], blue: $0.1[2], alpha: 1) } as CFArray,
                                        locations: s.map(\.0)) else { return }
        ctx.saveGState(); ctx.concatenate(state.ctm)
        if coords.count == 4 {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: coords[0], y: coords[1]), end: CGPoint(x: coords[2], y: coords[3]), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else if coords.count == 6 {
            ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: coords[0], y: coords[1]), startRadius: coords[2], endCenter: CGPoint(x: coords[3], y: coords[4]),
                                   endRadius: coords[5], options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.restoreGState()
    }

    mutating func image(_ d: [String: Value]) {
        guard case .number(let w)? = d["Width"], case .number(let h)? = d["Height"], case .source(let filters)? = d["DataSource"] else { return }
        // The data starts after one white-space character; a line of it may start with "%", which is not a comment here.
        while at < text.count, text[at] <= 32 { at += 1 }
        guard let end = (at..<text.count - 1).first(where: { text[$0] == UInt8(ascii: "~") && text[$0 + 1] == UInt8(ascii: ">") }) else { return }
        var data = svtASCII85(Array(text[at..<end]))
        at = end + 2
        if filters.contains("FlateDecode") { data = svtInflate(data) ?? [] }
        if filters.contains("RunLengthDecode") { data = svtRunLength(data) }
        guard data.count >= Int(w * h) * 3, let provider = CGDataProvider(data: Data(data) as CFData),
              let picture = CGImage(width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: Int(w) * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        ctx.saveGState(); ctx.concatenate(state.ctm); ctx.interpolationQuality = .high
        ctx.draw(picture, in: CGRect(x: 0, y: 0, width: 1, height: 1)); ctx.restoreGState()
    }
}

func svtASCII85(_ chars: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [], group: [UInt32] = []
    for c in chars where c > 32 {
        if c == UInt8(ascii: "z") && group.isEmpty { out += [0, 0, 0, 0]; continue }
        group.append(UInt32(c) - 33)
        if group.count == 5 {
            let v = group.reduce(UInt32(0)) { $0 &* 85 &+ $1 }
            out += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]; group = []
        }
    }
    if !group.isEmpty {
        let n = group.count
        while group.count < 5 { group.append(84) }
        let v = group.reduce(UInt32(0)) { $0 &* 85 &+ $1 }
        out += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)].prefix(n - 1)
    }
    return out
}

/// A zlib stream's body (header and Adler-32 stripped) inflated.
func svtInflate(_ zlib: [UInt8]) -> [UInt8]? {
    guard zlib.count > 6, zlib[0] == 0x78 else { return nil }
    let body = Array(zlib[2..<(zlib.count - 4)])
    var out = [UInt8](repeating: 0, count: max(1 << 16, body.count * 40))
    let n = compression_decode_buffer(&out, out.count, body, body.count, nil, COMPRESSION_ZLIB)
    return n > 0 ? Array(out[0..<n]) : nil
}

func svtRunLength(_ data: [UInt8]) -> [UInt8] {
    var out: [UInt8] = [], i = 0
    while i < data.count {
        let n = Int(data[i]); i += 1
        if n == 128 { break }
        if n < 128 { out += data[i..<min(data.count, i + n + 1)]; i += n + 1 } else if i < data.count { out += [UInt8](repeating: data[i], count: 257 - n); i += 1 }
    }
    return out
}

// MARK: CGM walking

private struct SVTCGMElement { let cls: Int, id: Int; let params: [UInt8] }

private func svtCGMElements(_ bytes: [UInt8]) -> [SVTCGMElement]? {
    var out: [SVTCGMElement] = [], i = 0
    func word(_ o: Int) -> Int { Int(bytes[o]) << 8 | Int(bytes[o + 1]) }
    while i + 1 < bytes.count {
        let head = word(i); i += 2
        var length = head & 31, params: [UInt8] = []
        if length == 31 {
            var more = true
            while more {
                guard i + 1 < bytes.count else { return nil }
                let p = word(i); i += 2
                more = p & 0x8000 != 0; length = p & 0x7FFF
                guard i + length <= bytes.count else { return nil }
                params += bytes[i..<i + length]; i += length
            }
        } else {
            guard i + length <= bytes.count else { return nil }
            params = Array(bytes[i..<i + length]); i += length
        }
        if i % 2 == 1 { i += 1 }
        out.append(SVTCGMElement(cls: head >> 12, id: head >> 5 & 0x7F, params: params))
    }
    return out
}

private func svtI16(_ p: [UInt8], _ o: Int) -> Int { Int(Int16(bitPattern: UInt16(p[o]) << 8 | UInt16(p[o + 1]))) }

// MARK: Fixtures

private func svtRed() -> VectorColour { VectorColour(red: 0.9, green: 0.1, blue: 0.1) }

/// A drawing with every construct PSWriter writes as vectors, plus one see-through group.
private func svtPSDrawing(translucent: Bool) -> VectorDocument {
    let blue = VectorColour(red: 0.1, green: 0.2, blue: 0.9), green = VectorColour(red: 0.1, green: 0.7, blue: 0.2)
    var nodes: [VectorNode] = [
        .path(PathBuilder.rect(x: 10, y: 10, width: 40, height: 30), fill: .solid(svtRed()), stroke: nil),
        .path(PathBuilder.rect(x: 60, y: 10, width: 50, height: 40) + PathBuilder.rect(x: 70, y: 20, width: 30, height: 20), fill: .solid(green), stroke: nil, rule: .evenOdd),
        .path([.move(VectorPoint(10, 60)), .line(VectorPoint(110, 60))], fill: nil,
              stroke: VectorStroke(paint: .solid(blue), width: 6, dash: [12, 6], dashPhase: 3, cap: .round)),
        .path([.move(VectorPoint(10, 90)), .line(VectorPoint(40, 70)), .line(VectorPoint(70, 90))], fill: nil,
              stroke: VectorStroke(paint: .solid(.black), width: 5, join: .bevel)),
        .path(PathBuilder.rect(x: 75, y: 65, width: 40, height: 30),
              fill: .linear(from: VectorPoint(75, 0), to: VectorPoint(115, 0), stops: [GradientStop(offset: 0, colour: svtRed()), GradientStop(offset: 0.5, colour: .white), GradientStop(offset: 1, colour: blue)]),
              stroke: nil),
        .group([.path(PathBuilder.ellipse(cx: 0, cy: 0, rx: 12, ry: 12), fill: .radial(centre: VectorPoint(0, 0), radius: 12, stops: [GradientStop(offset: 0, colour: .white), GradientStop(offset: 1, colour: green)]), stroke: nil)],
               transform: .translation(25, 120), clip: PathBuilder.rect(x: -12, y: -12, width: 24, height: 12), opacity: 1),
        .path([.move(VectorPoint(50, 110)), .quad(VectorPoint(70, 140), VectorPoint(90, 110))], fill: nil, stroke: VectorStroke(paint: .solid(blue), width: 2)),
    ]
    if translucent {
        nodes.append(.group([.path(PathBuilder.rect(x: 0, y: 0, width: 30, height: 30), fill: .solid(blue), stroke: nil)],
                            transform: .translation(20, 20), clip: nil, opacity: 0.5))
    }
    return VectorDocument(pages: [VectorPage(size: VectorSize(width: 120, height: 140), nodes: nodes)], title: "Drawing (test)")
}

private func svtAsset(_ w: Int, _ h: Int, alpha: Bool = false) -> ImageAsset {
    var bytes = [UInt8]()
    for y in 0..<h { for x in 0..<w { bytes += [UInt8(x * 255 / max(1, w - 1)), UInt8(y * 255 / max(1, h - 1)), 128, alpha && x == 0 ? 0 : 255] } }
    return ImageAsset(frames: [ImageFrame(width: w, height: h, pixels: .rgba8(Data(bytes), bytesPerRow: w * 4), hasAlpha: alpha)])
}

/// The PostScript section of a file (inside a DOS EPS binary header when there is one).
private func svtPSText(_ data: Data) -> String {
    let b = [UInt8](data)
    if b.count > 30, b[0] == 0xC5, b[1] == 0xD0 {
        let offset = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
        let length = Int(b[8]) | Int(b[9]) << 8 | Int(b[10]) << 16 | Int(b[11]) << 24
        return String(decoding: b[offset..<offset + length], as: UTF8.self)
    }
    return String(decoding: b, as: UTF8.self)
}

/// The image data of the first `image` in a file, decoded through its filters.
private func svtFirstImageData(_ ps: String) -> [UInt8]? {
    guard let op = ps.range(of: ">> image\n"), let end = ps.range(of: "~>", range: op.upperBound..<ps.endIndex) else { return nil }
    let header = ps[ps.startIndex..<op.lowerBound]
    let raw = svtASCII85(Array(ps[op.upperBound..<end.lowerBound].utf8))
    if header.hasSuffix("/FlateDecode filter ") { return svtInflate(raw) }
    if header.hasSuffix("/RunLengthDecode filter ") { return svtRunLength(raw) }
    return raw
}

func registerVectorKitPSTests() {
    SelfTest.cases.append(("VectorKit.ps.structure", {
        guard let ps = try? PSWriter.write(svtPSDrawing(translucent: false), options: VectorWriteOptions(), eps: false),
              let eps = try? PSWriter.write(VectorDocument(pages: svtPSDrawing(translucent: false).pages + svtPSDrawing(translucent: false).pages), options: VectorWriteOptions(), eps: true)
        else { check(false, "PostScript written"); return }
        let text = String(decoding: ps.data, as: UTF8.self), epsText = String(decoding: eps.data, as: UTF8.self)
        check(text.hasPrefix("%!PS-Adobe-3.0\n") && epsText.hasPrefix("%!PS-Adobe-3.0 EPSF-3.0\n"), "DSC headers")
        check(text.contains("%%BoundingBox: 0 0 120 140\n") && text.contains("%%HiResBoundingBox: 0 0 120 140\n"), "bounding boxes")
        check(text.contains("%%Pages: 1\n") && epsText.contains("%%Pages: 1\n") && text.hasSuffix("%%EOF\n"), "pages and EOF; EPS keeps one page")
        check(text.contains("%%Title: (Drawing \\(test\\))"), "title escaped")
        check(text.contains("setpagedevice") && !epsText.contains("setpagedevice"), "only PostScript sets the page device")
        check(text.contains("eofill") && text.contains("12 6] 3 setdash") && text.contains("1 setlinecap") && text.contains("2 setlinejoin"), "fill rule, dash with phase, cap, join")
        check(text.contains("/ShadingType 2") && text.contains("/ShadingType 3") && text.contains("/FunctionType 3"), "shadings with stitching functions")
        check(text.components(separatedBy: "gsave").count == text.components(separatedBy: "grestore").count, "gsave and grestore balance")
        check(ps.data.allSatisfy { $0 < 128 }, "7-bit clean")
        check(ps.lossNotes.isEmpty, "nothing lost for an opaque drawing")
    }))

    SelfTest.cases.append(("VectorKit.ps.pixels", {
        for translucent in [false, true] {
            let doc = svtPSDrawing(translucent: translucent)
            guard let ps = try? PSWriter.write(doc, options: VectorWriteOptions(density: 300), eps: true) else { check(false, "written"); continue }
            var interpreter = SVTPostScript(String(decoding: ps.data, as: UTF8.self), size: doc.pages[0].size, scale: 2)
            guard let drawn = SVTBitmap(interpreter.run()), let expected = svtRender(doc, pxPerPoint: 2) else { check(false, "rendered"); continue }
            check(interpreter.unknown.isEmpty, "only known operators: \(interpreter.unknown.sorted())")
            check(drawn.near(30, 280 - 50, 230, 26, 26) && drawn.near(152, 280 - 160, 230, 26, 26, tolerance: 40) && drawn.near(190, 280 - 160, 255, 255, 255, tolerance: 20), "content drawn, not a blank page")
            let mismatch = drawn.mismatch(expected)
            check(mismatch < 0.01, "PostScript draws like the model (translucent: \(translucent)): \(mismatch)")
            check(translucent == ps.lossNotes.contains { $0.kind == .layersFlattened }, "flattening noted only when needed")
            if translucent { check(drawn.near(50, 280 - 60, Int(0.5 * 255), Int(0.15 * 255), Int(0.5 * 255), tolerance: 20), "half-transparent blue over red") }
        }
    }))

    SelfTest.cases.append(("VectorKit.ps.type42", {
        let run = VectorTextRun(text: "Hello", fontName: "Helvetica", size: 24, origin: VectorPoint(10, 20), fill: .solid(.black))
        let doc = VectorDocument(pages: [VectorPage(size: VectorSize(width: 200, height: 60), nodes: [.text(run)])])
        guard let ps = try? PSWriter.write(doc, options: VectorWriteOptions(), eps: true) else { check(false, "written"); return }
        let text = String(decoding: ps.data, as: UTF8.self)
        check(text.contains("/FontType 42 def") && text.contains("%%BeginResource: font SC0001+Helvetica"), "Type 42 font embedded")
        check(text.components(separatedBy: "glyphshow").count - 1 == 5, "five glyphs shown")
        check(ps.lossNotes.isEmpty, "text kept as text")
        // The sfnts strings put back together (each without its pad byte) are a font CoreText draws from.
        guard let start = text.range(of: "/sfnts [\n"), let end = text.range(of: "] def", range: start.upperBound..<text.endIndex) else { check(false, "sfnts"); return }
        var sfnt = Data()
        for part in text[start.upperBound..<end.lowerBound].split(separator: ">") {
            let hex = part.filter(\.isHexDigit)
            var bytes = [UInt8]()
            var i = hex.startIndex
            while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) { bytes.append(UInt8(hex[i..<j], radix: 16)!); i = j }
            if !bytes.isEmpty { sfnt.append(contentsOf: bytes.dropLast()) }
        }
        guard let provider = CGDataProvider(data: sfnt as CFData), let cgFont = CGFont(provider) else { check(false, "subset font loads"); return }
        let font = CTFontCreateWithGraphicsFont(cgFont, 24, nil, nil)
        let original = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        var chars: [UniChar] = Array("HZ".utf16), ids = [CGGlyph](repeating: 0, count: 2)
        CTFontGetGlyphsForCharacters(original, &chars, &ids, 2)
        check(CTFontCreatePathForGlyph(font, ids[0], nil).map { !$0.isEmpty } == true, "a shown glyph keeps its outline")
        check(CTFontCreatePathForGlyph(font, ids[1], nil).map(\.isEmpty) ?? true, "an unused glyph is emptied (subset)")
        check(sfnt.count < 200_000, "subset is small: \(sfnt.count) bytes")
        let outlined = try? PSWriter.write(doc, options: VectorWriteOptions(textAsOutlines: true), eps: true)
        check(outlined.map { !String(decoding: $0.data, as: UTF8.self).contains("glyphshow") && $0.lossNotes.contains { $0.kind == .textAsOutlines } } == true, "text as outlines on request")
    }))

    SelfTest.cases.append(("VectorKit.ps.raster", {
        let asset = svtAsset(7, 5)
        guard let flate = try? PSWriter.write(image: asset, options: OptionValues(), eps: true, title: "pic"),
              let rle = try? PSWriter.write(image: asset, options: OptionValues(["level": "2"]), eps: false, title: "pic"),
              let jpeg = try? PSWriter.write(image: svtAsset(32, 24), options: OptionValues(["encoding": "jpeg", "preview": "tiff"]), eps: true, title: "pic")
        else { check(false, "raster pages written"); return }
        let flateText = svtPSText(flate.data), rleText = svtPSText(rle.data)
        var expected = [UInt8]()
        if case .rgba8(let data, _) = asset.frames[0].pixels { for p in stride(from: 0, to: data.count, by: 4) { expected += data[p..<p + 3] } }
        check(flateText.contains("%%LanguageLevel: 3") && flateText.contains("/ICCBased") && flateText.contains("/FlateDecode"), "Level 3: ICCBased and Flate")
        check(svtFirstImageData(flateText) == expected, "Flate pixels exact")
        check(rleText.contains("%%LanguageLevel: 2") && !rleText.contains("ICCBased") && rleText.contains("/RunLengthDecode"), "Level 2: DeviceRGB and run-length")
        check(svtFirstImageData(rleText) == expected, "run-length pixels exact")
        check(flateText.contains("%%BoundingBox: 0 0 6 4\n") && flateText.contains("%%HiResBoundingBox: 0 0 5.25 3.75\n"), "1 px = 0.75 pt")
        let b = [UInt8](jpeg.data)
        check(b.count > 30 && b[0...3] == [0xC5, 0xD0, 0xD3, 0xC6], "DOS EPS header")
        let tiffOffset = Int(b[20]) | Int(b[21]) << 8 | Int(b[22]) << 16, tiffLength = Int(b[24]) | Int(b[25]) << 8 | Int(b[26]) << 16
        let tiff = tiffOffset + tiffLength <= b.count ? Data(b[tiffOffset..<tiffOffset + tiffLength]) : Data()
        let preview = CGImageSourceCreateWithData(tiff as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        check(preview?.width == 32 && preview?.height == 24, "TIFF preview decodes")
        let jpegText = svtPSText(jpeg.data)
        let jpegBytes = svtFirstImageData(jpegText) ?? []
        let decoded = CGImageSourceCreateWithData(Data(jpegBytes) as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        check(jpegText.contains("/DCTDecode") && decoded?.width == 32, "JPEG through DCTDecode")
        let page = try? PSWriter.write(image: svtAsset(100, 50, alpha: true), options: OptionValues(["pageSize": "a4"]), eps: false, title: nil)
        check(page.map { svtPSText($0.data).contains("[595.276 841.89]") || svtPSText($0.data).contains("[841.89 595.276]") } == true, "A4 page")
        check(page?.lossNotes.contains { $0.kind == .transparencyFilled } == true, "alpha noted")
    }))

    SelfTest.cases.append(("VectorKit.cgm.structure", {
        let run = VectorTextRun(text: "CGM", fontName: "Helvetica", size: 12, origin: VectorPoint(10, 120), fill: .solid(.black))
        var doc = svtPSDrawing(translucent: false)
        doc.pages[0].nodes.append(.text(run))
        doc.pages[0].nodes.append(.image(svtAsset(3, 2), transform: VectorTransform(a: 30, b: 0, c: 0, d: 20, tx: 80, ty: 100)))
        guard let kept = try? CGMWriter.write(doc, options: VectorWriteOptions()),
              let outlined = try? CGMWriter.write(VectorDocument(pages: [doc.pages[0], doc.pages[0]]), options: VectorWriteOptions(textAsOutlines: true)),
              let elements = svtCGMElements([UInt8](kept.data)), let outlineElements = svtCGMElements([UInt8](outlined.data))
        else { check(false, "CGM written and walks"); return }
        func count(_ list: [SVTCGMElement], _ cls: Int, _ id: Int) -> Int { list.filter { $0.cls == cls && $0.id == id }.count }
        check(elements.first.map { $0.cls == 0 && $0.id == 1 } == true && elements.last.map { $0.cls == 0 && $0.id == 2 } == true, "BEGIN and END METAFILE")
        check(count(elements, 0, 3) == 1 && count(outlineElements, 0, 3) == 2, "a picture per page")
        check(count(elements, 4, 7) == 2 && count(elements, 4, 8) == 1, "polygons and the even-odd polygon set")
        check(count(elements, 4, 17) == 1, "the circle is an ellipse element")
        check(count(elements, 4, 1) == 3, "polylines for the strokes")
        check(count(elements, 4, 4) == 1 && count(outlineElements, 4, 4) == 0, "text kept, or outlined on request")
        check(count(elements, 4, 9) == 1 && count(elements, 2, 2) == 1, "picture as a cell array in direct colour")
        if let extent = elements.first(where: { $0.cls == 2 && $0.id == 6 }) {
            check([0, 2, 4, 6].map { svtI16(extent.params, $0) } == [0, 0, 27429, 32000], "VDC extent: the longer side is 32 000")
        } else { check(false, "VDC extent") }
        // The red rectangle at (10, 10, 40, 30) in VDC (× 32000 / 140).
        if let rect = elements.first(where: { $0.cls == 4 && $0.id == 7 }) {
            let k = 32000.0 / 140
            check([0, 2, 4, 6].map { svtI16(rect.params, $0) } == [10, 10, 50, 10].map { Int(($0 * k).rounded()) }, "polygon in VDC")
        } else { check(false, "polygon") }
        check(kept.lossNotes.contains { $0.detail.contains("gradients") }, "gradients noted")
        let indexed = try? CGMWriter.write(svtPSDrawing(translucent: false), options: VectorWriteOptions())
        let indexedElements = indexed.flatMap { svtCGMElements([UInt8]($0.data)) } ?? []
        check(count(indexedElements, 5, 34) == 1 && count(indexedElements, 1, 9) == 1, "colour table without pictures")
        MainActor.assumeIsolated {
            VectorKitModule.install()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svt-cgm-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let context = StepContext(workFolder: dir, source: dir.appendingPathComponent("drawing.svg"), sourceFormat: "svg", targetFormat: "cgm", isFinalStep: true)
            guard let cgm = Services.converters.converter(for: .cgmWriter), let ps = Services.converters.converter(for: .psWriter) else { check(false, "converters registered"); return }
            check(ps.handles(Step(.psWriter, .vectorDocument, "eps")) && ps.handles(Step(.psWriter, .imageAsset, "ps")), "PSWriter handles drawings and pictures")
            if case .success(let out)? = complete(30, { try await cgm.run(Step(.cgmWriter, .vectorDocument, "cgm"), input: .vector(doc), context: context) }),
               case .file(let url) = out.value, let data = try? Data(contentsOf: url) {
                check(count(svtCGMElements([UInt8](data)) ?? [], 4, 4) == 0, "CGM outlines text by default")
            } else { check(false, "CGM step ran") }
            let epsContext = StepContext(workFolder: dir, source: dir.appendingPathComponent("photo.png"), sourceFormat: "png", targetFormat: "eps", isFinalStep: true)
            if case .success(let out)? = complete(30, { try await ps.run(Step(.psWriter, .imageAsset, "eps"), input: .image(svtAsset(4, 4)), context: epsContext) }),
               case .file(let url) = out.value, let data = try? Data(contentsOf: url) {
                check(url.pathExtension == "eps" && String(decoding: data, as: UTF8.self).hasPrefix("%!PS-Adobe-3.0 EPSF-3.0"), "EPS step ran")
            } else { check(false, "EPS step ran") }
        }
    }))
}
