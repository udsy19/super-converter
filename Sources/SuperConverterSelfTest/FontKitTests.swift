import CoreGraphics
import CoreText
import Foundation
import SuperConverterCore
import FontKit

// FontKit's checks (WP-F). Fonts are built here from outlines (a quadratic and a cubic family with straight edges, counters,
// circles and an S-shaped curve), converted through the registered converters, read back and compared: outlines, advances,
// cmap, names, then text rendered by Core Text from the converted files (quality §7). System fonts are used too when present;
// those cases skip silently otherwise.

// MARK: - Fixtures

private typealias Contour = FontModel.Contour
private typealias P = FontModel.Contour.Point

private func fkDir(_ name: String = "font") -> URL {
    let url = scratch.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func contour(_ pts: [(Double, Double, Bool)]) -> Contour { Contour(points: pts.map { P($0.0, $0.1, onCurve: $0.2) }) }

/// A small family: .notdef, space, A (triangle with a counter), B (circle), C (S-shaped lens). U+1F600 shares C's outline.
private func fkSample(cubic: Bool) -> FontModel {
    let notdef = FontModel.Glyph(name: ".notdef", advance: 500, contours: [
        contour([(50, 0, true), (450, 0, true), (450, 700, true), (50, 700, true)]),
        contour([(100, 50, true), (100, 650, true), (400, 650, true), (400, 50, true)]),
    ])
    let space = FontModel.Glyph(name: "space", advance: 300)
    let a = FontModel.Glyph(name: "A", advance: 640, contours: [
        contour([(0, 0, true), (300, 700, true), (600, 0, true)]),
        contour([(200, 150, true), (400, 150, true), (300, 400, true)]),
    ])
    let circle: Contour
    let lens: Contour
    if cubic {
        let k = 0.5523 * 300
        circle = contour([(650, 350, true), (650, 350 + k, false), (350 + k, 650, false), (350, 650, true),
                          (350 - k, 650, false), (50, 350 + k, false), (50, 350, true),
                          (50, 350 - k, false), (350 - k, 50, false), (350, 50, true),
                          (350 + k, 50, false), (650, 350 - k, false)])
        lens = contour([(0, 0, true), (200, 600, false), (400, -300, false), (600, 300, true), (600, 400, true),
                        (400, -100, false), (200, 800, false), (0, 100, true)])
    } else {
        circle = contour([(650, 350, true), (650, 650, false), (350, 650, true), (50, 650, false), (50, 350, true),
                          (50, 50, false), (350, 50, true), (650, 50, false)])
        lens = contour([(0, 0, true), (300, 900, false), (600, 300, true), (600, 400, true), (300, -300, false), (0, 100, true)])
    }
    let b = FontModel.Glyph(name: "B", advance: 700, contours: [circle])
    let c = FontModel.Glyph(name: "C", advance: 650, contours: [lens])
    return FontModel(familyName: "Fk Sample", styleName: "Regular", unitsPerEm: 1000, ascent: 800, descent: -200,
                     outlineKind: cubic ? .cubic : .quadratic, glyphs: [notdef, space, a, b, c],
                     characterMap: [0x20: 1, 0x41: 2, 0x42: 3, 0x43: 4, 0x1F600: 4])
}

// MARK: - Running converters

private func fkConverter(_ id: EngineID) -> any Converter { FontKitModule.converters().first { $0.id == id }! }

@MainActor
private func fkRun(_ id: EngineID, _ from: StepEndpoint, _ to: StepEndpoint, input: StepValue, source: URL, sourceFormat: FormatID,
                   target: FormatID, options: OptionValues = OptionValues(), dir: URL) -> StepOutput? {
    let context = StepContext(workFolder: dir, source: source, sourceFormat: sourceFormat, targetFormat: target, options: options)
    let result = complete(60) { try await fkConverter(id).run(Step(id, from, to), input: input, context: context) }
    switch result {
    case .success(let out)?: return out
    case .failure(let error)?: check(false, "\(id.rawValue) \(sourceFormat)→\(target) failed: \(error)"); return nil
    case nil: check(false, "\(id.rawValue) timed out"); return nil
    }
}

private func fkReaderID(_ f: FormatID) -> EngineID {
    switch f {
    case "ttf", "otf": .sfntReader
    case "woff": .woffReader
    case "woff2": .woff2Reader
    case "eot": .eotReader
    default: .svgFontReader
    }
}

private func fkWriterID(_ f: FormatID) -> EngineID {
    switch f {
    case "ttf": .glyfBuilder
    case "otf": .cffBuilder
    case "woff": .woffWriter
    case "woff2": .woff2Writer
    case "eot": .eotWriter
    default: .svgFontWriter
    }
}

@MainActor
private func fkRead(_ url: URL, _ format: FormatID, dir: URL) -> (FontModel, [LossNote])? {
    guard let out = fkRun(fkReaderID(format), StepEndpoint.format(format), .fontModel, input: .file(url), source: url, sourceFormat: format,
                          target: "ttf", dir: dir), case .font(let m) = out.value else { return nil }
    return (m, out.lossNotes)
}

@MainActor
private func fkWrite(_ model: FontModel, _ format: FormatID, stem: String = "font", options: OptionValues = OptionValues(), dir: URL) -> URL? {
    let source = dir.appendingPathComponent("\(stem).src")
    guard let out = fkRun(fkWriterID(format), .fontModel, StepEndpoint.format(format), input: .font(model), source: source, sourceFormat: "ttf",
                          target: format, options: options, dir: dir), case .file(let url) = out.value else { return nil }
    return url
}

// MARK: - Geometry for the comparisons (independent of FontKit's own path code)

private func fkFlatten(_ c: Contour, cubic: Bool, steps: Int = 24) -> [CGPoint] {
    let pts = c.points
    guard pts.count >= 2 else { return [] }
    var poly: [CGPoint] = []
    func pt(_ p: P) -> CGPoint { CGPoint(x: p.x, y: p.y) }
    func quad(_ a: CGPoint, _ b: CGPoint, _ e: CGPoint) {
        for i in 1...steps { let t = CGFloat(i) / CGFloat(steps), u = 1 - t
            poly.append(CGPoint(x: u * u * a.x + 2 * u * t * b.x + t * t * e.x, y: u * u * a.y + 2 * u * t * b.y + t * t * e.y)) }
    }
    func cub(_ a: CGPoint, _ b: CGPoint, _ c2: CGPoint, _ e: CGPoint) {
        for i in 1...steps { let t = CGFloat(i) / CGFloat(steps), u = 1 - t
            poly.append(CGPoint(x: u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c2.x + t * t * t * e.x,
                                y: u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c2.y + t * t * t * e.y)) }
    }
    if cubic {
        var cur = pt(pts[0]); poly = [cur]
        var offs: [CGPoint] = []
        for p in pts.dropFirst() {
            if p.onCurve { if offs.count >= 2 { cub(cur, offs[0], offs[1], pt(p)) } else { poly.append(pt(p)) }; cur = pt(p); offs = [] }
            else { offs.append(pt(p)) }
        }
        if offs.count >= 2 { cub(cur, offs[0], offs[1], pt(pts[0])) }
    } else {
        // A contour may have no on-curve point at all: it then starts at the implied point between its last and first.
        let order: [P]
        let first: CGPoint
        if let start = pts.firstIndex(where: { $0.onCurve }) {
            order = Array(pts[(start + 1)...]) + Array(pts[..<start]); first = pt(pts[start])
        } else {
            order = pts; first = CGPoint(x: (pts[pts.count - 1].x + pts[0].x) / 2, y: (pts[pts.count - 1].y + pts[0].y) / 2)
        }
        var cur = first; poly = [cur]
        var off: CGPoint?
        for p in order + [P(first.x, first.y)] {
            if p.onCurve {
                if let o = off { quad(cur, o, pt(p)); off = nil } else { poly.append(pt(p)) }
                cur = pt(p)
            } else {
                if let o = off { let mid = CGPoint(x: (o.x + p.x) / 2, y: (o.y + p.y) / 2); quad(cur, o, mid); cur = mid }
                off = pt(p)
            }
        }
    }
    return poly
}

private func fkDistance(_ p: CGPoint, to poly: [CGPoint]) -> Double {
    var best = Double.infinity
    for i in 0..<poly.count {
        let a = poly[i], b = poly[(i + 1) % poly.count]
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        best = min(best, Double(hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))))
    }
    return best
}

/// The largest distance either outline has from the other.
private func fkDeviation(_ a: FontModel, _ b: FontModel, steps: Int = 48, glyphLimit: Int = .max) -> Double {
    var worst = 0.0
    for (ga, gb) in zip(a.glyphs, b.glyphs).prefix(glyphLimit) {
        let pa = ga.contours.map { fkFlatten($0, cubic: a.outlineKind == .cubic, steps: steps) }
        let pb = gb.contours.map { fkFlatten($0, cubic: b.outlineKind == .cubic, steps: steps) }
        guard pa.count == pb.count else { return .infinity }
        for (x, y) in zip(pa, pb) {
            for p in x { worst = max(worst, fkDistance(p, to: y)) }
            for p in y { worst = max(worst, fkDistance(p, to: x)) }
        }
    }
    return worst
}

// MARK: - Core Text rendering

private func fkCTFont(_ url: URL, size: CGFloat) -> CTFont? {
    guard let data = try? Data(contentsOf: url),
          let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor], let d = descriptors.first
    else { return nil }
    return CTFontCreateWithFontDescriptor(d, size, nil)
}

/// Gray coverage of `characters` drawn into a square bitmap.
private func fkRender(_ font: CTFont, _ characters: [UniChar], side: Int, origin: CGPoint) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: side * side)
    pixels.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setShouldSmoothFonts(false); ctx.setShouldAntialias(true)
        ctx.setFillColor(gray: 1, alpha: 1)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        var chars = characters
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: characters.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, characters.count)
        var x = origin.x
        var positions: [CGPoint] = []
        for a in advances { positions.append(CGPoint(x: x, y: origin.y)); x += a.width }
        CTFontDrawGlyphs(font, glyphs, positions, characters.count, ctx)
    }
    return pixels
}

private func fkIoU(_ a: [UInt8], _ b: [UInt8]) -> Double {
    var inter = 0, union = 0
    for (x, y) in zip(a, b) { let p = x > 127, q = y > 127; if p && q { inter += 1 }; if p || q { union += 1 } }
    return union == 0 ? 1 : Double(inter) / Double(union)
}

private func fkMaxDiff(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0 }

// MARK: - Cases

func registerFontKitTests() {
    SelfTest.cases.append(("FontKit.installs", {
        FontKitModule.install()
        let ids = Set(FontKitModule.converters().map(\.id))
        check(ids == [.sfntReader, .woffReader, .woff2Reader, .eotReader, .svgFontReader, .glyfBuilder, .cffBuilder, .woffWriter,
                      .woff2Writer, .eotWriter, .svgFontWriter], "FontKit converts with all eleven engines it owns")
        for engine in EngineID.allCases where engine.info.module == .fontKit {
            check(Services.converters.converter(for: engine) != nil, "\(engine.rawValue) is registered")
        }
    }))

    SelfTest.cases.append(("FontKit.quadraticRoundTrip", {
        let dir = fkDir()
        let model = fkSample(cubic: false)
        guard let ttf = fkWrite(model, "ttf", dir: dir), let (back, _) = fkRead(ttf, "ttf", dir: dir) else { return }
        check(back.outlineKind == .quadratic, "TrueType outlines read back as quadratic")
        check(back.unitsPerEm == 1000 && back.ascent == 800 && back.descent == -200, "metrics survive: \(back.unitsPerEm) \(back.ascent) \(back.descent)")
        check(back.familyName == "Fk Sample" && back.styleName == "Regular", "names survive: \(back.familyName) / \(back.styleName)")
        check(back.glyphs.map(\.name) == model.glyphs.map(\.name), "glyph names survive: \(back.glyphs.map(\.name))")
        check(back.glyphs.map(\.advance) == model.glyphs.map(\.advance), "advances survive")
        check(back.characterMap == model.characterMap, "cmap survives, astral included: \(back.characterMap)")
        check(back.glyphs.map(\.contours.count) == model.glyphs.map(\.contours.count), "contour counts survive")
        check(fkDeviation(model, back) < 1e-9, "outlines are identical (\(fkDeviation(model, back)))")
        check(ttf.pathExtension == "ttf", "the file is named for its format")
    }))

    SelfTest.cases.append(("FontKit.cubicRoundTrip", {
        let dir = fkDir()
        let model = fkSample(cubic: true)
        guard let otf = fkWrite(model, "otf", dir: dir), let (back, _) = fkRead(otf, "otf", dir: dir) else { return }
        check(back.outlineKind == .cubic, "CFF outlines read back as cubic")
        check(back.glyphs.map(\.name) == model.glyphs.map(\.name), "CFF charset names survive: \(back.glyphs.map(\.name))")
        check(back.glyphs.map(\.advance) == model.glyphs.map(\.advance), "advances survive")
        check(back.characterMap == model.characterMap, "cmap survives")
        check(fkDeviation(model, back) < 1e-3, "outlines are identical (\(fkDeviation(model, back)))")
        check(back.tables["head"] != nil && back.tables["OS/2"] != nil && back.tables["name"] != nil, "head, OS/2 and name are carried")
        if let font = fkCTFont(otf, size: 100) {
            check(CTFontGetGlyphCount(font) == 5, "Core Text loads the CFF font")
        } else { check(false, "Core Text could not load the OpenType font") }
    }))

    SelfTest.cases.append(("FontKit.quadraticToCubicIsExact", {
        let dir = fkDir()
        let model = fkSample(cubic: false)
        guard let ttf = fkWrite(model, "ttf", stem: "q", dir: dir),
              let (loaded, _) = fkRead(ttf, "ttf", dir: dir),
              let otf = fkWrite(loaded, "otf", stem: "q", dir: dir), let (cubic, _) = fkRead(otf, "otf", dir: dir) else { return }
        check(cubic.outlineKind == .cubic, "TTF → OTF yields CFF")
        check(fkDeviation(loaded, cubic) < 1e-3, "quadratic → cubic keeps the curve exactly (\(fkDeviation(loaded, cubic)))")
        guard let a = fkCTFont(ttf, size: 100), let b = fkCTFont(otf, size: 100) else { check(false, "Core Text loads both"); return }
        let text: [UniChar] = Array("ABC A".utf16)
        for size in [CGFloat(12), 24, 72] {
            let fa = CTFontCreateCopyWithAttributes(a, size, nil, nil), fb = CTFontCreateCopyWithAttributes(b, size, nil, nil)
            let ra = fkRender(fa, text, side: 256, origin: CGPoint(x: 8, y: 60)), rb = fkRender(fb, text, side: 256, origin: CGPoint(x: 8, y: 60))
            check(ra.contains { $0 > 0 }, "text renders at \(size) px")
            check(fkMaxDiff(ra, rb) <= 2, "TTF and OTF text are pixel-identical at \(size) px (max difference \(fkMaxDiff(ra, rb)))")
        }
    }))

    SelfTest.cases.append(("FontKit.cubicToQuadraticWithinTolerance", {
        let dir = fkDir()
        let model = fkSample(cubic: true)
        guard let otf = fkWrite(model, "otf", stem: "c", dir: dir), let (loaded, _) = fkRead(otf, "otf", dir: dir),
              let ttf = fkWrite(loaded, "ttf", stem: "c", dir: dir), let (quad, _) = fkRead(ttf, "ttf", dir: dir) else { return }
        check(quad.outlineKind == .quadratic, "OTF → TTF yields glyf")
        let deviation = fkDeviation(loaded, quad)
        check(deviation <= 1.0, "cu2qu stays within 1 unit per 1000 em (\(deviation))")
        check(quad.glyphs.map(\.advance) == loaded.glyphs.map(\.advance) && quad.characterMap == loaded.characterMap, "metrics and cmap identical")
        let loose = fkWrite(loaded, "ttf", stem: "loose", options: OptionValues(["curveTolerance": .double(5)]), dir: dir).flatMap { fkRead($0, "ttf", dir: dir)?.0 }
        let tight = fkWrite(loaded, "ttf", stem: "tight", options: OptionValues(["curveTolerance": .double(0.1)]), dir: dir).flatMap { fkRead($0, "ttf", dir: dir)?.0 }
        if let loose, let tight {
            let n: (FontModel) -> Int = { $0.glyphs.reduce(0) { $0 + $1.contours.reduce(0) { $0 + $1.points.count } } }
            check(n(loose) < n(tight), "tolerance trades points for accuracy (\(n(loose)) < \(n(tight)))")
            check(fkDeviation(loaded, tight) < 0.8, "a tight tolerance is honoured, to rounding (\(fkDeviation(loaded, tight)))")
        }
        guard let a = fkCTFont(otf, size: 100), let b = fkCTFont(ttf, size: 100) else { check(false, "Core Text loads both"); return }
        let text: [UniChar] = Array("ABC".utf16)
        // The synthetic glyphs are few and thin, so the bar is lower than the 0.995 the real-font case below holds to.
        for size in [CGFloat(64), 96] {
            let ra = fkRender(CTFontCreateCopyWithAttributes(a, size, nil, nil), text, side: 256, origin: CGPoint(x: 6, y: 60))
            let rb = fkRender(CTFontCreateCopyWithAttributes(b, size, nil, nil), text, side: 256, origin: CGPoint(x: 6, y: 60))
            check(fkIoU(ra, rb) >= 0.99, "OTF and TTF text overlap ≥ 0.99 at \(size) px (\(fkIoU(ra, rb)))")
        }
    }))

    SelfTest.cases.append(("FontKit.webFormatsRoundTrip", {
        let dir = fkDir()
        let model = fkSample(cubic: false)
        guard let ttf = fkWrite(model, "ttf", dir: dir), let (original, _) = fkRead(ttf, "ttf", dir: dir) else { return }
        for format: FormatID in ["woff", "woff2", "eot"] {
            guard let file = fkWrite(original, format, stem: "web", dir: dir), let (back, _) = fkRead(file, format, dir: dir) else { continue }
            check(back.glyphs == original.glyphs, "\(format): glyph outlines, names and advances survive")
            check(back.characterMap == original.characterMap, "\(format): cmap survives")
            check(back.familyName == original.familyName && back.unitsPerEm == original.unitsPerEm, "\(format): names and unitsPerEm survive")
            let size = (try? Data(contentsOf: file).count) ?? 0
            check(size > 0, "\(format) file written")
            check(fkCTFont(file, size: 50) != nil || format == "eot", "Core Text can load the \(format) file")
        }
        if let otf = fkWrite(fkSample(cubic: true), "otf", stem: "w", dir: dir), let (c, _) = fkRead(otf, "otf", dir: dir) {
            for format: FormatID in ["woff", "woff2"] {
                guard let file = fkWrite(c, format, stem: "cffweb", dir: dir), let (back, _) = fkRead(file, format, dir: dir) else { continue }
                check(back.outlineKind == .cubic && fkDeviation(c, back) < 1e-3, "\(format) carries CFF outlines")
            }
        }
    }))

    SelfTest.cases.append(("FontKit.woffTablesAreValid", {
        let dir = fkDir()
        guard let woff = fkWrite(fkSample(cubic: false), "woff", dir: dir), let data = try? Data(contentsOf: woff) else { return }
        let b = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
        check(String(decoding: b[0..<4], as: UTF8.self) == "wOFF", "WOFF signature")
        check(u32(8) == b.count, "WOFF length field matches the file")
        let tableCount = Int(b[12]) << 8 | Int(b[13])
        var previousTag = ""
        for i in 0..<tableCount {
            let e = 44 + i * 20
            let tag = String(decoding: b[e..<(e + 4)], as: UTF8.self)
            check(tag > previousTag, "table directory is sorted (\(tag))"); previousTag = tag
            check(u32(e + 4) % 4 == 0, "table \(tag) is 4-byte aligned")
            if u32(e + 8) < u32(e + 12) { check(b[u32(e + 4)] & 0x0F == 8, "table \(tag) starts with a zlib header") }
        }
    }))

    SelfTest.cases.append(("FontKit.eotVariants", {
        let dir = fkDir()
        guard let ttf = fkWrite(fkSample(cubic: false), "ttf", dir: dir), let (model, _) = fkRead(ttf, "ttf", dir: dir),
              let eot = fkWrite(model, "eot", dir: dir), var bytes = try? [UInt8](Data(contentsOf: eot)) else { return }
        func le32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        check(le32(0) == bytes.count, "EOT size field matches the file")
        check(le32(8) == 0x00020001, "EOT version 2.1")
        check(bytes[34] == 0x4C && bytes[35] == 0x50, "EOT magic number")
        let dataSize = le32(4)
        let start = bytes.count - dataSize
        for i in start..<bytes.count { bytes[i] ^= 0x50 }
        bytes[15] |= 0x10
        let xorFile = dir.appendingPathComponent("xor.eot")
        try? Data(bytes).write(to: xorFile)
        if let (back, _) = fkRead(xorFile, "eot", dir: dir) { check(back.glyphs == model.glyphs, "XOR-obfuscated EOT reads back") }
        bytes[15] &= ~0x10; bytes[12] |= 0x04
        let mtx = dir.appendingPathComponent("mtx.eot")
        try? Data(bytes).write(to: mtx)
        let context = StepContext(workFolder: dir, source: mtx, sourceFormat: "eot", targetFormat: "ttf")
        let result = complete(10) { try await fkConverter(.eotReader).run(Step(.eotReader, "eot", .fontModel), input: .file(mtx), context: context) }
        if case .failure(let error)? = result, case ConversionError.failed(let message) = error {
            check(message.contains("MicroType"), "MTX-compressed EOT gets a clear message: \(message)")
        } else { check(false, "MTX-compressed EOT should fail with a message") }
    }))

    SelfTest.cases.append(("FontKit.svgFontBothWays", {
        let dir = fkDir()
        for cubic in [false, true] {
            let model = fkSample(cubic: cubic)
            guard let svg = fkWrite(model, "svg", stem: cubic ? "c" : "q", dir: dir), let text = try? String(contentsOf: svg, encoding: .utf8) else { continue }
            check(text.contains("<font ") && text.contains("units-per-em=\"1000\"") && text.contains("<missing-glyph"), "SVG font structure (\(cubic ? "cubic" : "quadratic"))")
            check((try? XMLDocument(data: Data(text.utf8), options: [])) != nil, "SVG font is well-formed XML")
            guard let (back, _) = fkRead(svg, "svg", dir: dir) else { continue }
            check(back.glyphs.count == 6 && back.glyphs[0].name == ".notdef" && back.glyphs[2].name == "A", "SVG glyphs: \(back.glyphs.map(\.name))")
            check(back.characterMap[0x41] != nil && back.characterMap[0x1F600] != nil, "cmap survives, astral included")
            check(back.outlineKind == (cubic ? .cubic : .quadratic), "outline kind follows the path commands")
            let a = back.characterMap[0x41].map { back.glyphs[$0] }, b = back.characterMap[0x42].map { back.glyphs[$0] }
            if let a, let b, let oa = model.characterMap[0x41].map({ model.glyphs[$0] }), let ob = model.characterMap[0x42].map({ model.glyphs[$0] }) {
                let m1 = FontModel(familyName: "x", outlineKind: back.outlineKind, glyphs: [a, b])
                let m2 = FontModel(familyName: "x", outlineKind: model.outlineKind, glyphs: [oa, ob])
                check(fkDeviation(m1, m2) < 1e-2, "SVG outlines match the source (\(fkDeviation(m1, m2)))")
                check(a.advance == oa.advance && b.advance == ob.advance, "advances survive")
            }
            if let ttf = fkWrite(back, "ttf", stem: "fromsvg", dir: dir) {
                check(fkCTFont(ttf, size: 40) != nil, "a font made from an SVG font loads")
            }
        }
        let drawing = dir.appendingPathComponent("drawing.svg")
        try? Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"4\" height=\"4\"/></svg>".utf8).write(to: drawing)
        let context = StepContext(workFolder: dir, source: drawing, sourceFormat: "svg", targetFormat: "ttf")
        let result = complete(10) { try await fkConverter(.svgFontReader).run(Step(.svgFontReader, "svg", .fontModel), input: .file(drawing), context: context) }
        if case .failure(let error)? = result, case ConversionError.failed(let message) = error {
            check(message.contains("doesn’t contain a font"), "a drawing without a font gets a clear message: \(message)")
        } else { check(false, "a plain drawing should fail with a message") }
    }))

    SelfTest.cases.append(("FontKit.cmapAndHmtxBuilding", {
        var model = fkSample(cubic: false)
        var map: [UInt32: Int] = [0x20: 1]
        for c in 0x41...0x5A { map[UInt32(c)] = 2 + (c % 3) }
        for c in 0x300...0x30F { map[UInt32(c)] = 4 }
        map[0xFFFD] = 3; map[0x1F600] = 2; map[0x10FFFF] = 3
        model.characterMap = map
        model.glyphs[3].advance = 640; model.glyphs[4].advance = 640
        let dir = fkDir()
        guard let ttf = fkWrite(model, "ttf", dir: dir), let (back, _) = fkRead(ttf, "ttf", dir: dir) else { return }
        check(back.characterMap == map, "a mixed cmap round-trips (\(back.characterMap.count) of \(map.count))")
        check(back.glyphs.map(\.advance) == model.glyphs.map(\.advance), "advances round-trip with a short hmtx: \(back.glyphs.map(\.advance))")
    }))

    SelfTest.cases.append(("FontKit.subsetting", {
        let dir = fkDir()
        guard let ttf = fkWrite(fkSample(cubic: false), "ttf", dir: dir), let (model, _) = fkRead(ttf, "ttf", dir: dir) else { return }
        var kerned = model
        kerned.tables["kern"] = Data([0, 0, 0, 0])
        let custom = OptionValues(["subset": .string("custom"), "subsetText": .string("AC")])
        guard let small = fkWrite(kerned, "woff", stem: "sub", options: custom, dir: dir), let (back, _) = fkRead(small, "woff", dir: dir) else { return }
        check(back.glyphs.map(\.name) == [".notdef", "A", "C"], "custom subset keeps .notdef and the asked characters: \(back.glyphs.map(\.name))")
        check(back.characterMap == [0x41: 1, 0x43: 2], "cmap is renumbered: \(back.characterMap)")
        check(back.tables["kern"] == nil, "glyph-indexed tables are dropped from a subset")
        guard let latin = fkWrite(model, "ttf", stem: "latin", options: OptionValues(["subset": .string("latin")]), dir: dir),
              let (l, _) = fkRead(latin, "ttf", dir: dir) else { return }
        check(l.characterMap.keys.sorted() == [0x20, 0x41, 0x42, 0x43], "the Latin subset keeps the Latin characters: \(l.characterMap.keys.sorted())")
        check(!l.characterMap.keys.contains(0x1F600), "the Latin subset drops emoji")
    }))

    SelfTest.cases.append(("FontKit.verticalMetricsFix", {
        let dir = fkDir()
        var model = fkSample(cubic: false)
        model.ascent = 900; model.descent = -300
        guard let ttf = fkWrite(model, "ttf", stem: "plain", dir: dir), let (plain, _) = fkRead(ttf, "ttf", dir: dir),
              let fixed = fkWrite(plain, "ttf", stem: "fixed", options: OptionValues(["verticalMetricsFix": true]), dir: dir),
              let (back, _) = fkRead(fixed, "ttf", dir: dir) else { return }
        func be16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) << 8 | Int(d[d.startIndex + o + 1]) }
        guard let os2 = back.tables["OS/2"], os2.count >= 78 else { check(false, "OS/2 present"); return }
        check(be16(os2, 68) == 900 && (be16(os2, 70) == 0xFED4), "typographic metrics follow hhea (\(be16(os2, 68)), \(be16(os2, 70)))")
        check(be16(os2, 74) >= 900, "Windows ascent covers the ascent")
        check(be16(os2, 62) & 0x80 != 0, "USE_TYPO_METRICS is set")
    }))

    SelfTest.cases.append(("FontKit.systemTrueTypeFonts", {
        let dir = fkDir()
        var tested = 0
        for name in ["Monaco.ttf", "Geneva.ttf"] {
            let url = URL(fileURLWithPath: "/System/Library/Fonts/\(name)")
            guard FileManager.default.fileExists(atPath: url.path), let (model, _) = fkRead(url, "ttf", dir: dir) else { continue }
            tested += 1
            check(model.glyphs.count > 100 && !model.characterMap.isEmpty, "\(name): read \(model.glyphs.count) glyphs")
            guard let otf = fkWrite(model, "otf", stem: "sys-" + name, dir: dir), let (cubic, _) = fkRead(otf, "otf", dir: dir) else { continue }
            check(cubic.glyphs.count == model.glyphs.count && cubic.characterMap == model.characterMap, "\(name): TTF → OTF keeps glyphs and cmap")
            check(cubic.glyphs.map(\.advance) == model.glyphs.map(\.advance), "\(name): advances identical")
            guard let a = fkCTFont(url, size: 100), let b = fkCTFont(otf, size: 100) else { check(false, "\(name): Core Text loads original and OTF"); continue }
            let sample: [UniChar] = Array("Hamburgefonstiv, 0123 QRS&@gjy".utf16)
            for size: CGFloat in [12, 24, 72] {
                let origin = CGPoint(x: 4, y: 40)
                let ra = fkRender(CTFontCreateCopyWithAttributes(a, size, nil, nil), sample, side: 640, origin: origin)
                let rb = fkRender(CTFontCreateCopyWithAttributes(b, size, nil, nil), sample, side: 640, origin: origin)
                check(fkIoU(ra, rb) >= 0.999 || fkMaxDiff(ra, rb) <= 24, "\(name): converted text matches at \(size) px (IoU \(fkIoU(ra, rb)))")
            }
            guard let ttf = fkWrite(cubic, "ttf", stem: "back-" + name, dir: dir), let (quad, _) = fkRead(ttf, "ttf", dir: dir) else { continue }
            check(fkDeviation(model, quad, steps: 24, glyphLimit: 30) <= 1.0, "\(name): TTF → OTF → TTF stays within 1 unit")
            for format: FormatID in ["woff", "woff2", "eot"] {
                guard let file = fkWrite(model, format, stem: "web-" + name, dir: dir), let (back, _) = fkRead(file, format, dir: dir) else { continue }
                // Hinting is dropped (with a note) and composite glyphs are flattened with their offsets rounded to whole units.
                check(back.glyphs.map(\.name) == model.glyphs.map(\.name) && back.glyphs.map(\.advance) == model.glyphs.map(\.advance)
                      && back.characterMap == model.characterMap, "\(name): \(format) round trip keeps names, advances and cmap")
                check(fkDeviation(model, back, steps: 4, glyphLimit: 400) <= 0.7072, "\(name): \(format) round trip keeps outlines to the rounding of whole units")
            }
        }
        if tested == 0 { print("  (no system TrueType fonts found; skipped)") }
    }))

    SelfTest.cases.append(("FontKit.systemCFFFont", {
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Fonts"))?.filter { $0.hasSuffix(".otf") }.sorted() ?? []
        let dir = fkDir()
        var tested = 0
        for name in candidates {
            let url = URL(fileURLWithPath: "/System/Library/Fonts/\(name)")
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size < 4_000_000,
                  let (model, _) = fkRead(url, "otf", dir: dir), model.outlineKind == .cubic,
                  model.glyphs.contains(where: { !$0.contours.isEmpty }), model.glyphs.count > 20 else { continue }
            tested += 1
            guard let ttf = fkWrite(model, "ttf", stem: "cff-" + name, dir: dir), let (quad, _) = fkRead(ttf, "ttf", dir: dir) else { continue }
            check(fkDeviation(model, quad, steps: 24, glyphLimit: 30) <= 1.0, "\(name): OTF → TTF within 1 unit")
            guard let a = fkCTFont(url, size: 100), let b = fkCTFont(ttf, size: 100) else { check(false, "\(name): Core Text loads both"); continue }
            let chars = Array(model.characterMap.keys.filter { $0 > 0x20 && $0 < 0x2000 }.sorted().prefix(24)).map { UniChar($0) }
            for size in [CGFloat(24), 72] {
                let ra = fkRender(CTFontCreateCopyWithAttributes(a, size, nil, nil), chars, side: 900, origin: CGPoint(x: 4, y: 100))
                let rb = fkRender(CTFontCreateCopyWithAttributes(b, size, nil, nil), chars, side: 900, origin: CGPoint(x: 4, y: 100))
                check(fkIoU(ra, rb) >= 0.995, "\(name): CFF and converted TrueType text overlap ≥ 0.995 at \(size) px (\(fkIoU(ra, rb)))")
            }
            if tested >= 2 { break }
        }
        if tested == 0 { print("  (no system CFF fonts found; skipped)") }
    }))

    SelfTest.cases.append(("FontKit.everyFontRouteRuns", {
        FontKitModule.install()
        let dir = fkDir()
        var sources: [FormatID: URL] = [:]
        let quad = fkSample(cubic: false)
        for format: FormatID in ["ttf", "otf", "woff", "woff2", "eot", "svg"] {
            let model = format == "otf" ? fkSample(cubic: true) : quad
            if let url = fkWrite(model, format, stem: "src", dir: dir) { sources[format] = url }
        }
        var ran = 0
        for route in FormatMatrix.routes {
            guard let steps = route.builtin, steps.allSatisfy({ $0.engine.info.module == .fontKit }), let source = sources[route.from] else { continue }
            let routeDir = fkDir("route")
            var value = StepValue.file(source)
            var ok = true
            for (i, step) in steps.enumerated() {
                let context = StepContext(workFolder: routeDir, source: source, sourceFormat: route.from, targetFormat: route.to, isFinalStep: i == steps.count - 1)
                guard let converter = Services.converters.converter(for: step.engine), converter.handles(step) else { check(false, "no converter handles \(step)"); ok = false; break }
                switch complete(60, { try await converter.run(step, input: value, context: context) }) {
                case .success(let out)?: value = out.value
                case .failure(let error)?: check(false, "\(route.from)→\(route.to) \(step): \(error)"); ok = false
                case nil: check(false, "\(route.from)→\(route.to) timed out"); ok = false
                }
                if !ok { break }
            }
            if ok, case .file(let out) = value {
                ran += 1
                check(out.pathExtension == route.to.rawValue && ((try? Data(contentsOf: out).count) ?? 0) > 50, "\(route.from)→\(route.to) produced a \(route.to) file")
                if route.to != "svg" && route.to != "eot" { check(fkCTFont(out, size: 40) != nil, "\(route.from)→\(route.to): Core Text loads the result") }
            } else if ok { check(false, "\(route.from)→\(route.to) did not end in a file") }
        }
        check(ran >= 30, "all font routes ran (\(ran))")
    }))

    SelfTest.cases.append(("FontKit.damagedInputNeverCrashes", {
        let dir = fkDir()
        var rng = SystemRandomNumberGenerator()
        var seeds: [(FormatID, [UInt8])] = []
        for format: FormatID in ["ttf", "otf", "woff", "woff2", "eot", "svg"] {
            let model = format == "otf" ? fkSample(cubic: true) : fkSample(cubic: false)
            if let url = fkWrite(model, format, stem: "fuzz", dir: dir), let data = try? Data(contentsOf: url) { seeds.append((format, [UInt8](data))) }
        }
        var attempts = 0
        for (format, bytes) in seeds {
            for _ in 0..<120 {
                var copy = bytes
                switch Int.random(in: 0..<3, using: &rng) {
                case 0: copy = Array(copy.prefix(Int.random(in: 0..<copy.count, using: &rng)))
                case 1: for _ in 0..<8 { copy[Int.random(in: 0..<copy.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng) }
                default: for _ in 0..<2 { copy[Int.random(in: 0..<copy.count, using: &rng)] ^= 0xFF }
                }
                let url = dir.appendingPathComponent("fuzz-in.\(format.rawValue)")
                try? Data(copy).write(to: url)
                let context = StepContext(workFolder: dir, source: url, sourceFormat: format, targetFormat: "ttf")
                let id = fkReaderID(format)
                _ = complete(30) { try? await fkConverter(id).run(Step(id, StepEndpoint.format(format), .fontModel), input: .file(url), context: context) }
                attempts += 1
            }
        }
        check(attempts == 720, "every damaged input was handled without a crash (\(attempts))")
    }))
}
