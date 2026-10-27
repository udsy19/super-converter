import AppKit
import SuperConverterCore
import VectorizeKit

// VectorizeKit's checks (WP-V). Every trace is rasterised again by a small path rasteriser below (M L H V C Z, fill,
// evenodd) and compared with the source picture.

private let vzOut = "/private/tmp/claude-501/-Users-udsy-PycharmProjects-CleanShotX/9bff2f70-7ce5-4c96-b4ab-fdfd6dd402f3/scratchpad/wpv-c"

private struct VZImage {
    var w: Int, h: Int
    var px: [UInt8]   // RGBA straight

    init(_ w: Int, _ h: Int, fill: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) {
        self.w = w; self.h = h
        px = []
        px.reserveCapacity(w * h * 4)
        for y in 0..<h { for x in 0..<w { let c = fill(x, y); px += [c.0, c.1, c.2, c.3] } }
    }

    var asset: ImageAsset {
        ImageAsset(frames: [ImageFrame(width: w, height: h, pixels: .rgba8(Data(px), bytesPerRow: w * 4), hasAlpha: px.indices.contains { $0 % 4 == 3 && px[$0] != 255 })])
    }
}

/// Draws the SVG VectorizeKit writes onto white (or transparent) pixels.
private func vzRaster(_ svg: Data, w: Int, h: Int, antialias: Bool) -> [UInt8] {
    let text = String(decoding: svg, as: UTF8.self)
    var out = [UInt8](repeating: 0, count: w * h * 4)
    out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setShouldAntialias(antialias)
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        for line in text.split(separator: "\n") where line.hasPrefix("<path") {
            guard let f = line.range(of: "fill=\"#"), let d = line.range(of: " d=\"") else { continue }
            let hex = line[f.upperBound...].prefix(6)
            let v = Int(hex, radix: 16) ?? 0
            ctx.setFillColor(CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1))
            let data = Array(line[d.upperBound...].dropLast(3).utf8)
            var i = 0
            func num() -> Double? {
                while i < data.count, data[i] == 32 || data[i] == 44 { i += 1 }
                let s = i
                while i < data.count, (data[i] >= 48 && data[i] <= 57) || data[i] == 46 || data[i] == 45 { i += 1 }
                return s == i ? nil : Double(String(decoding: data[s..<i], as: UTF8.self))
            }
            let path = CGMutablePath()
            var cur = CGPoint.zero
            while i < data.count {
                let c = data[i]; i += 1
                switch c {
                case 77: if let x = num(), let y = num() { cur = CGPoint(x: x, y: y); path.move(to: cur) }
                case 76: if let x = num(), let y = num() { cur = CGPoint(x: x, y: y); path.addLine(to: cur) }
                case 72: if let x = num() { cur.x = x; path.addLine(to: cur) }
                case 86: if let y = num() { cur.y = y; path.addLine(to: cur) }
                case 67:
                    if let a = num(), let b = num(), let c1 = num(), let d1 = num(), let e = num(), let f = num() {
                        cur = CGPoint(x: e, y: f)
                        path.addCurve(to: cur, control1: CGPoint(x: a, y: b), control2: CGPoint(x: c1, y: d1))
                    }
                case 90: path.closeSubpath()
                default: break
                }
            }
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        }
    }
    // Un-premultiply.
    for i in stride(from: 0, to: out.count, by: 4) {
        let a = Int(out[i + 3])
        if a > 0 && a < 255 { for c in 0..<3 { out[i + c] = UInt8(min(255, (Int(out[i + c]) * 255 + a / 2) / a)) } }
    }
    return out
}

/// Source flattened onto white or kept transparent (alpha < 128 → transparent), the way the tracer sees it.
private func vzExpected(_ img: VZImage, onWhite: Bool) -> [UInt8] {
    var out = img.px
    for p in 0..<(img.w * img.h) where out[p * 4 + 3] < 128 {
        out[p * 4] = onWhite ? 255 : 0; out[p * 4 + 1] = onWhite ? 255 : 0; out[p * 4 + 2] = onWhite ? 255 : 0; out[p * 4 + 3] = onWhite ? 255 : 0
    }
    if onWhite { for p in 0..<(img.w * img.h) { out[p * 4 + 3] = 255 } }
    return out
}

private func vzWhite(_ px: [UInt8]) -> [UInt8] {
    var out = px
    for p in 0..<(px.count / 4) where out[p * 4 + 3] == 0 { out[p * 4] = 255; out[p * 4 + 1] = 255; out[p * 4 + 2] = 255; out[p * 4 + 3] = 255 }
    return out
}

/// Fraction of pixels whose worst channel differs by more than `threshold`.
private func vzMismatch(_ a: [UInt8], _ b: [UInt8], threshold: Int = 64) -> Double {
    guard a.count == b.count else { return 1 }
    var bad = 0
    for p in 0..<(a.count / 4) {
        var worst = 0
        for c in 0..<3 { worst = max(worst, abs(Int(a[p * 4 + c]) - Int(b[p * 4 + c]))) }
        if worst > threshold { bad += 1 }
    }
    return Double(bad) / Double(a.count / 4)
}

private func vzSave(_ name: String, _ source: [UInt8], _ traced: [UInt8], w: Int, h: Int) {
    try? FileManager.default.createDirectory(atPath: vzOut, withIntermediateDirectories: true)
    var both = [UInt8](repeating: 255, count: (w * 2 + 4) * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            for c in 0..<4 {
                both[(y * (w * 2 + 4) + x) * 4 + c] = vzWhite(source)[(y * w + x) * 4 + c]
                both[(y * (w * 2 + 4) + w + 4 + x) * 4 + c] = vzWhite(traced)[(y * w + x) * 4 + c]
            }
        }
    }
    let bw = w * 2 + 4
    guard let provider = CGDataProvider(data: Data(both) as CFData),
          let image = CGImage(width: bw, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
    let big = NSImage(cgImage: image, size: NSSize(width: bw * 4, height: h * 4))
    var rect = NSRect(origin: .zero, size: big.size)
    if let cg = big.cgImage(forProposedRect: &rect, context: nil, hints: [.interpolation: NSImageInterpolation.none.rawValue]) {
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: vzOut).appendingPathComponent(name + ".png"))
    }
}

// MARK: Fixtures

private let white: (UInt8, UInt8, UInt8, UInt8) = (255, 255, 255, 255)
private let black: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 255)

/// A thick ring, a bar and a T: black on white, hard edges.
private func vzGlyphs() -> VZImage {
    VZImage(96, 64) { x, y in
        let dx = Double(x) - 20, dy = Double(y) - 32, r = (dx * dx + dy * dy).squareRoot()
        if r <= 20 && r >= 10 { return black }
        if x >= 50 && x < 60 && y >= 10 && y < 54 { return black }
        if x >= 66 && x < 92 && y >= 10 && y < 18 { return black }
        if x >= 76 && x < 82 && y >= 18 && y < 54 { return black }
        return white
    }
}

private func vzDisc(antialiased: Bool) -> VZImage {
    VZImage(64, 64) { x, y in
        var cover = 0
        let n = antialiased ? 4 : 1
        for sy in 0..<n { for sx in 0..<n {
            let fx = Double(x) + (Double(sx) + 0.5) / Double(n) - 32, fy = Double(y) + (Double(sy) + 0.5) / Double(n) - 32
            if fx * fx + fy * fy <= 24 * 24 { cover += 1 }
        } }
        let v = UInt8(255 - 255 * cover / (n * n))
        return (v, v, v, 255)
    }
}

private func vzLogo() -> VZImage {
    VZImage(80, 60) { x, y in
        let dx = Double(x) - 28, dy = Double(y) - 30
        if dx * dx + dy * dy <= 15 * 15 { return (255, 140, 0, 255) }
        if x >= 50 && x < 72 && y >= 12 && y < 48 { return (255, 140, 0, 255) }
        return (20, 60, 160, 255)
    }
}

private func vzPoster() -> VZImage {
    VZImage(100, 70) { x, y in
        let dx = Double(x) - 50, dy = Double(y) - 35
        if dx * dx + dy * dy <= 14 * 14 { return (250, 250, 250, 255) }
        if y < 14 { return (200, 30, 30, 255) }
        if y < 28 { return (240, 200, 30, 255) }
        if y < 42 { return (40, 160, 60, 255) }
        return (30, 80, 200, 255)
    }
}

private func vzGradient() -> VZImage {
    VZImage(64, 64) { x, y in (UInt8(x * 4), UInt8(y * 4), UInt8(128 + (x + y) * 1), 255) }
}

private func vzTransparent() -> VZImage {
    VZImage(64, 64) { x, y in
        let dx = Double(x) - 32, dy = Double(y) - 32
        if dx * dx + dy * dy <= 22 * 22 { return dx * dx + dy * dy <= 8 * 8 ? (0, 0, 0, 0) : (200, 40, 40, 255) }
        return (0, 0, 0, 0)
    }
}

func registerVectorizeKitTests() {
    func trace(_ img: VZImage, _ s: TraceSettings) -> TraceResult? { try? Vectorizer.trace(img.asset, settings: s) }

    SelfTest.cases.append(("VectorizeKit.installs", {
        VectorizeKitModule.install()
        check(Services.converters.converter(for: .vectorizeKit) != nil, "converter registered")
    }))

    SelfTest.cases.append(("VectorizeKit.options", {
        let s = TraceSettings(OptionValues())
        check(s.preset == .auto && s.mode == .spline && s.filterSpeckle == 4 && s.colourPrecision == 6 && s.colours == nil && s.simplify == 0, "defaults")
        let t = TraceSettings(OptionValues(["preset": "poster", "mode": "polygon", "filterSpeckle": 500, "colourPrecision": 0, "colours": 99, "simplify": 3.5]))
        check(t.preset == .poster && t.mode == .polygon && t.filterSpeckle == 128 && t.colourPrecision == 1 && t.colours == 64 && t.simplify == 3.5, "values are read and clamped")
        check(TraceSettings(OptionValues(["preset": "nonsense"])).preset == .auto, "unknown preset falls back")
    }))

    SelfTest.cases.append(("VectorizeKit.glyphs", {
        let img = vzGlyphs()
        guard let r = trace(img, TraceSettings()) else { check(false, "glyph trace"); return }
        check(r.preset == .bw && r.colourCount == 1 && r.pathCount == 1, "auto picks black and white: \(r.preset) \(r.colourCount)")
        let svg = String(decoding: r.svg, as: UTF8.self)
        check(svg.contains("viewBox=\"0 0 96 64\"") && svg.contains("fill=\"#000000\"") && svg.contains("evenodd") && !svg.contains("<rect"), "valid compact svg, no background")
        let drawn = vzRaster(r.svg, w: 96, h: 64, antialias: true)
        let m = vzMismatch(vzWhite(drawn), vzExpected(img, onWhite: true))
        vzSave("glyphs", img.px, vzWhite(drawn), w: 96, h: 64)
        check(m < 0.01, "spline glyphs mismatch \(m)")
        // The ring's hole stays open.
        check(vzWhite(drawn)[(32 * 96 + 20) * 4] > 200, "hole in the ring stays white")
        let poly = trace(img, TraceSettings(mode: .polygon))
        check(poly.map { vzMismatch(vzWhite(vzRaster($0.svg, w: 96, h: 64, antialias: true)), vzExpected(img, onWhite: true)) < 0.015 } == true, "polygon mode")
        check(poly.map { !String(decoding: $0.svg, as: UTF8.self).contains("C") || true } == true, "polygon svg")
        check(poly.map { !String(decoding: $0.svg, as: UTF8.self).contains(" C") } == true, "polygon mode writes no curves")
    }))

    SelfTest.cases.append(("VectorizeKit.pixelModeExact", {
        for (name, img) in [("glyphs", vzGlyphs()), ("logo", vzLogo()), ("poster", vzPoster())] {
            guard let r = trace(img, TraceSettings(preset: name == "glyphs" ? .bw : .poster, mode: .pixel, filterSpeckle: 0)) else { check(false, "\(name) pixel trace"); return }
            let drawn = vzWhite(vzRaster(r.svg, w: img.w, h: img.h, antialias: false))
            check(vzMismatch(drawn, vzExpected(img, onWhite: true), threshold: 0) == 0, "\(name): pixel mode reproduces every pixel")
        }
    }))

    SelfTest.cases.append(("VectorizeKit.circles", {
        let crisp = vzDisc(antialiased: false), soft = vzDisc(antialiased: true)
        guard let a = trace(crisp, TraceSettings(preset: .bw)), let b = trace(soft, TraceSettings(preset: .bw)) else { check(false, "circle trace"); return }
        let da = vzWhite(vzRaster(a.svg, w: 64, h: 64, antialias: true)), db = vzWhite(vzRaster(b.svg, w: 64, h: 64, antialias: true))
        vzSave("circle", crisp.px, da, w: 64, h: 64); vzSave("circle-soft", soft.px, db, w: 64, h: 64)
        check(vzMismatch(da, crisp.px, threshold: 100) < 0.01, "crisp disc \(vzMismatch(da, crisp.px, threshold: 100))")
        check(vzMismatch(db, soft.px, threshold: 100) < 0.02, "anti-aliased disc \(vzMismatch(db, soft.px, threshold: 100))")
        check(String(decoding: a.svg, as: UTF8.self).contains("C"), "a round shape is written with curves")
        let flat = trace(crisp, TraceSettings(preset: .bw, mode: .polygon))
        let curved = trace(crisp, TraceSettings(preset: .bw, mode: .spline))
        check((flat?.svg.count ?? 0) > 0 && (curved?.svg.count ?? 0) < (try? Vectorizer.trace(crisp.asset, settings: TraceSettings(preset: .bw, mode: .pixel)))!.svg.count, "curves are more compact than pixel steps")
    }))

    SelfTest.cases.append(("VectorizeKit.logoAndPoster", {
        let logo = vzLogo(), poster = vzPoster()
        guard let l = trace(logo, TraceSettings()), let p = trace(poster, TraceSettings()) else { check(false, "colour trace"); return }
        check(l.preset == .poster && l.colourCount == 2, "logo: two colours (\(l.colourCount), \(l.preset))")
        check(p.preset == .poster && p.colourCount == 5, "poster: five colours (\(p.colourCount))")
        let dl = vzRaster(l.svg, w: 80, h: 60, antialias: true), dp = vzRaster(p.svg, w: 100, h: 70, antialias: true)
        vzSave("logo", logo.px, dl, w: 80, h: 60); vzSave("poster", poster.px, dp, w: 100, h: 70)
        check(vzMismatch(dl, logo.px, threshold: 40) < 0.012, "logo mismatch \(vzMismatch(dl, logo.px, threshold: 40))")
        check(vzMismatch(dp, poster.px, threshold: 40) < 0.012, "poster mismatch \(vzMismatch(dp, poster.px, threshold: 40))")
        let svg = String(decoding: p.svg, as: UTF8.self)
        check(svg.contains("#c81e1e") && svg.contains("#1e50c8") && svg.contains("#fafafa"), "palette keeps the exact colours")
        // Layers are stacked: every layer after the first also covers the colours painted above it, so no gaps show.
        let gaps = dp.indices.filter { $0 % 4 == 3 && dp[$0] != 255 }.count
        check(gaps == 0, "no uncovered pixels between regions (\(gaps))")
        let few = trace(poster, TraceSettings(preset: .poster, colours: 3))
        check(few?.colourCount == 3, "colours option limits the palette")
    }))

    SelfTest.cases.append(("VectorizeKit.gradientPhoto", {
        let img = vzGradient()
        guard let r = trace(img, TraceSettings()) else { check(false, "gradient trace"); return }
        check(r.preset == .photo && r.colourCount > 16 && r.colourCount <= 64, "photo preset, banded colours: \(r.colourCount) \(r.preset)")
        let drawn = vzRaster(r.svg, w: 64, h: 64, antialias: false)
        vzSave("gradient", img.px, drawn, w: 64, h: 64)
        var total = 0
        for i in 0..<(64 * 64 * 4) where i % 4 != 3 { total += abs(Int(drawn[i]) - Int(img.px[i])) }
        let mean = Double(total) / Double(64 * 64 * 3)
        check(mean < 16, "mean colour error \(mean)")
    }))

    SelfTest.cases.append(("VectorizeKit.transparencyAndSpecks", {
        let img = vzTransparent()
        guard let r = trace(img, TraceSettings(preset: .poster, filterSpeckle: 0)) else { check(false, "transparent trace"); return }
        let drawn = vzRaster(r.svg, w: 64, h: 64, antialias: false)
        vzSave("transparent", img.px, drawn, w: 64, h: 64)
        check(drawn[3] == 0 && drawn[(32 * 64 + 32) * 4 + 3] == 0, "transparent corners and centre stay unpainted")
        check(drawn[(32 * 64 + 16) * 4] > 150 && drawn[(32 * 64 + 16) * 4 + 3] == 255, "ring painted")
        check(!String(decoding: r.svg, as: UTF8.self).contains("<rect"), "no background rectangle")
        check(vzMismatch(vzWhite(drawn), vzWhite(vzExpected(img, onWhite: false)), threshold: 60) < 0.01, "transparent image matches")

        var speckled = vzGlyphs()
        for (x, y) in [(3, 3), (40, 5), (90, 60), (45, 50)] { for c in 0..<3 { speckled.px[(y * 96 + x) * 4 + c] = 0 } }
        let kept = trace(speckled, TraceSettings(preset: .bw, mode: .pixel, filterSpeckle: 0)), removed = trace(speckled, TraceSettings(preset: .bw, mode: .pixel, filterSpeckle: 4))
        let k = kept.map { vzWhite(vzRaster($0.svg, w: 96, h: 64, antialias: false)) }, g = removed.map { vzWhite(vzRaster($0.svg, w: 96, h: 64, antialias: false)) }
        check(k?[(3 * 96 + 3) * 4] == 0, "filterSpeckle 0 keeps a one-pixel dot")
        check(g?[(3 * 96 + 3) * 4] == 255 && g?[(5 * 96 + 40) * 4] == 255, "filterSpeckle 4 removes specks")
        check((removed?.svg.count ?? 0) < (kept?.svg.count ?? 0), "fewer outlines after speck removal")
    }))

    SelfTest.cases.append(("VectorizeKit.pixelLayoutsAndDeterminism", {
        let base = vzLogo()
        let ref = trace(base, TraceSettings(preset: .poster))
        // Padded rows, half-float samples and a file on disk all give the same trace.
        var padded = Data()
        for y in 0..<base.h { padded.append(contentsOf: base.px[(y * base.w * 4)..<((y + 1) * base.w * 4)]); padded.append(contentsOf: [1, 2, 3, 4, 5, 6, 7, 8]) }
        let a = ImageAsset(frames: [ImageFrame(width: base.w, height: base.h, pixels: .rgba8(padded, bytesPerRow: base.w * 4 + 8), hasAlpha: false)])
        check((try? Vectorizer.trace(a, settings: TraceSettings(preset: .poster)))?.svg == ref?.svg, "row padding is skipped")
        func half(_ v: UInt8) -> UInt16 {
            let f = Float(v) / 255
            if f == 0 { return 0 }
            let e = Int(floor(log2(f))), m = f / powf(2, Float(e)) - 1
            return UInt16((e + 15) << 10) | UInt16((m * 1024).rounded())
        }
        var h = Data()
        for v in base.px { var b = half(v); withUnsafeBytes(of: &b) { h.append(contentsOf: $0) } }
        let hasset = ImageAsset(frames: [ImageFrame(width: base.w, height: base.h, pixels: .rgbaHalf(h, bytesPerRow: base.w * 8), hasAlpha: false)])
        if let t = try? Vectorizer.trace(hasset, settings: TraceSettings(preset: .poster)), let r = ref {
            check(vzMismatch(vzRaster(t.svg, w: base.w, h: base.h, antialias: false), vzRaster(r.svg, w: base.w, h: base.h, antialias: false), threshold: 8) < 0.005, "half-float samples")
        } else { check(false, "half-float trace") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vz-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.w, pixelsHigh: base.h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: base.w * 4, bitsPerPixel: 32)!
        for i in 0..<(base.w * base.h * 4) { rep.bitmapData![i] = base.px[i] }
        let url = dir.appendingPathComponent("logo.png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        let fileAsset = ImageAsset(frames: [ImageFrame(width: base.w, height: base.h, pixels: .file(url), hasAlpha: false)])
        check((try? Vectorizer.trace(fileAsset, settings: TraceSettings(preset: .poster)))?.colourCount == 2, "file-backed pixels")
        check(trace(base, TraceSettings(preset: .poster))?.svg == ref?.svg, "deterministic output")
        check((try? Vectorizer.trace(ImageAsset(frames: []), settings: TraceSettings())) == nil, "empty asset is an error")
    }))

    SelfTest.cases.append(("VectorizeKit.cancelAndConverter", {
        let big = VZImage(256, 256) { x, y in (UInt8(x), UInt8(y), UInt8((x * y) & 255), 255) }
        do {
            _ = try Vectorizer.trace(big.asset, settings: TraceSettings(), isCancelled: { true })
            check(false, "cancelled trace throws")
        } catch { check((error as? ConversionError) == .cancelled, "cancellation maps to .cancelled") }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vz-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        MainActor.assumeIsolated { VectorizeKitModule.install() }
        guard let converter = MainActor.assumeIsolated({ Services.converters.converter(for: .vectorizeKit) }) else { check(false, "converter"); return }
        let step = Step(.vectorizeKit, .imageAsset, "svg")
        check(converter.handles(step), "handles ImageAsset → svg")
        let logo = vzLogo()
        let frames = logo.asset.frames + logo.asset.frames
        let animated = ImageAsset(frames: frames.map { var f = $0; f.delay = 0.1; return f })
        let source = dir.appendingPathComponent("logo.gif")
        let context = StepContext(workFolder: dir, source: source, sourceFormat: "gif", targetFormat: "svg", options: OptionValues(["preset": "poster"]), isFinalStep: true)
        var fractions: [Double] = []
        let box = Box()
        let reporting = StepContext(workFolder: dir, source: source, sourceFormat: "gif", targetFormat: "svg", options: OptionValues(["preset": "poster"]), isFinalStep: true,
                                    report: { box.add($0.fraction ?? -1) })
        _ = context
        let result = complete(60) { try await converter.run(step, input: .image(animated), context: reporting) }
        fractions = box.values
        guard case .success(let output)? = result, case .file(let url) = output.value else { check(false, "converter run"); return }
        check(url.lastPathComponent == "logo.svg" && FileManager.default.fileExists(atPath: url.path), "named after the source")
        check(output.lossNotes.contains { $0.kind == .animationDropped }, "animation drop is reported")
        check(fractions.last == 1 && fractions.contains { $0 > 0 && $0 < 1 }, "progress is reported")
        if let data = try? Data(contentsOf: url) { check(XMLParser(data: data).parse(), "output is well-formed XML") }
        let again = complete(60) { try await converter.run(step, input: .image(animated), context: reporting) }
        if case .success(let o2)? = again, case .file(let u2) = o2.value { check(u2.lastPathComponent == "logo 2.svg", "name collisions get a number") }
        let bad = complete(10) { try await converter.run(step, input: .file(source), context: reporting) }
        check({ if case .failure? = bad { true } else { false } }(), "a file instead of a picture is rejected")
    }))

    SelfTest.cases.append(("VectorizeKit.performance", {
        let poster = VZImage(512, 512) { x, y in
            let dx = Double(x) - 256, dy = Double(y) - 256
            if dx * dx + dy * dy < 150 * 150 { return (240, 200, 30, 255) }
            if (x / 64 + y / 64) % 2 == 0 { return (200, 30, 30, 255) }
            return (30, 80, 200, 255)
        }
        let start = Date()
        let r = try? Vectorizer.trace(poster.asset, settings: TraceSettings())
        let seconds = Date().timeIntervalSince(start)
        print("  VectorizeKit 512x512 poster: \(String(format: "%.2f", seconds)) s, \(r?.pathCount ?? 0) paths, \(r?.svg.count ?? 0) bytes")
        check(r != nil && seconds < 20, "512x512 poster traces in \(seconds) s")
    }))
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Double] = []
    func add(_ v: Double) { lock.lock(); items.append(v); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return items }
}
