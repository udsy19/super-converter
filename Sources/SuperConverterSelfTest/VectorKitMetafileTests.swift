import AppKit
import SuperConverterCore
import VectorKit

// EMF and WMF checks (WP-V): hand-built records through the readers (EMF+ dual records, placeable WMF, damaged files),
// and writer → reader round trips compared by rendered pixels.

/// Little-endian bytes for hand-built metafile records.
private struct MFBytes {
    var bytes: [UInt8] = []
    mutating func u16(_ v: Int) { bytes.append(UInt8(truncatingIfNeeded: v)); bytes.append(UInt8(truncatingIfNeeded: v >> 8)) }
    mutating func u32(_ v: Int) { u16(v); u16(v >> 16) }
    mutating func f32(_ v: Float) { u32(Int(v.bitPattern)) }
}

/// An EMF record from 32-bit parameter words.
private func emfRecord(_ type: Int, _ words: [Int]) -> [UInt8] {
    var b = MFBytes(); b.u32(type); b.u32(8 + words.count * 4); for w in words { b.u32(w) }; return b.bytes
}

/// A 100 × 100 pixel EMF at 96 dpi (szlDevice 960 = 254 mm) around `records`.
private func emfFile(_ records: [[UInt8]]) -> Data {
    let body = records.flatMap { $0 } + emfRecord(14, [0, 16, 20])
    var h = MFBytes()
    h.u32(1); h.u32(88); for v in [0, 0, 99, 99] { h.u32(v) }; for v in [0, 0, 2646, 2646] { h.u32(v) }
    h.u32(0x464D4520); h.u32(0x10000); h.u32(88 + body.count); h.u32(records.count + 2); h.u16(4); h.u16(0)
    h.u32(0); h.u32(0); h.u32(0); h.u32(960); h.u32(960); h.u32(254); h.u32(254)
    return Data(h.bytes + body)
}

/// An EMR_COMMENT carrying EMF+ records (`type`, `flags`, data).
private func emfPlusComment(_ plus: [(Int, Int, [UInt8])]) -> [UInt8] {
    var data = MFBytes()
    data.u32(0x2B464D45)
    for (type, flags, payload) in plus { data.u16(type); data.u16(flags); data.u32(12 + payload.count); data.u32(payload.count); data.bytes += payload }
    var r = MFBytes(); r.u32(70); r.u32(12 + data.bytes.count); r.u32(data.bytes.count); r.bytes += data.bytes
    return r.bytes
}

/// A WMF record from 16-bit parameter words.
private func wmfRecord(_ function: Int, _ words: [Int]) -> [UInt8] {
    var b = MFBytes(); b.u32(3 + words.count); b.u16(function); for w in words { b.u16(w) }; return b.bytes
}

/// A WMF with an optional placeable header (box in logical units, `inch` units per inch).
private func wmfFile(_ records: [[UInt8]], placeable: (Int, Int, Int)? = nil) -> Data {
    let body = records.flatMap { $0 } + wmfRecord(0, [])
    var out = MFBytes()
    if let (w, h, inch) = placeable {
        var head = MFBytes(); head.u32(0x9AC6CDD7); head.u16(0); head.u16(0); head.u16(0); head.u16(w); head.u16(h); head.u16(inch); head.u32(0)
        var sum = 0
        for i in 0..<10 { sum ^= Int(head.bytes[i * 2]) | Int(head.bytes[i * 2 + 1]) << 8 }
        head.u16(sum); out.bytes += head.bytes
    }
    out.u16(1); out.u16(9); out.u16(0x0300); out.u32(9 + body.count / 2); out.u16(4); out.u32(16); out.u16(0)
    return Data(out.bytes + body)
}

private func mfColour(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> VectorColour { VectorColour(red: r, green: g, blue: b, alpha: a) }

/// An 8 × 8 picture: a red/blue checker, or a half-transparent green when `alpha`.
private func mfPicture(alpha: Bool) -> ImageAsset {
    var px = [UInt8]()
    for y in 0..<8 { for x in 0..<8 { px += alpha ? [0, 200, 0, 128] : ((x / 4 + y / 4) % 2 == 0 ? [255, 0, 0, 255] : [0, 0, 255, 255]) } }
    return ImageAsset(frames: [ImageFrame(width: 8, height: 8, pixels: .rgba8(Data(px), bytesPerRow: 32), hasAlpha: alpha)])
}

/// The round-trip drawing: fills, strokes, curves with a hole, dashes, a turned clipped group, both gradient kinds,
/// pictures (opaque and see-through), a group with opacity and text.
private func mfDrawing() -> VectorDocument {
    let rect = { (x: Double, y: Double, w: Double, h: Double) -> [PathSegment] in
        [.move(VectorPoint(x, y)), .line(VectorPoint(x + w, y)), .line(VectorPoint(x + w, y + h)), .line(VectorPoint(x, y + h)), .close]
    }
    let blob: [PathSegment] = [.move(VectorPoint(120, 20)), .cubic(VectorPoint(150, 0), VectorPoint(190, 30), VectorPoint(180, 60)),
                               .quad(VectorPoint(150, 90), VectorPoint(120, 60)), .close] + rect(140, 35, 15, 15)
    let rotation = VectorTransform(a: cos(0.5), b: sin(0.5), c: -sin(0.5), d: cos(0.5), tx: 60, ty: 170)
    let nodes: [VectorNode] = [
        .path(rect(10, 10, 80, 50), fill: .solid(mfColour(1, 0, 0)), stroke: VectorStroke(paint: .solid(mfColour(0, 0, 1)), width: 4, join: .round)),
        .path(blob, fill: .solid(mfColour(0, 0.6, 0)), stroke: nil, rule: .evenOdd),
        .path([.move(VectorPoint(10, 80)), .line(VectorPoint(190, 80))], fill: nil,
              stroke: VectorStroke(paint: .solid(.black), width: 3, dash: [8, 4], cap: .butt)),
        .group([.path(rect(-30, -20, 60, 40), fill: .solid(mfColour(1, 0.5, 0)), stroke: nil)], transform: rotation,
               clip: [.move(VectorPoint(-25, -15)), .line(VectorPoint(25, -15)), .line(VectorPoint(0, 18)), .close], opacity: 1),
        .path(rect(110, 100, 80, 40), fill: .linear(from: VectorPoint(110, 100), to: VectorPoint(190, 140),
                                                    stops: [GradientStop(offset: 0, colour: mfColour(0, 0, 1)), GradientStop(offset: 1, colour: mfColour(1, 1, 0))]), stroke: nil),
        .path(rect(110, 150, 40, 40), fill: .radial(centre: VectorPoint(130, 170), radius: 20,
                                                    stops: [GradientStop(offset: 0, colour: .white), GradientStop(offset: 1, colour: mfColour(0.5, 0, 0.5))]), stroke: nil),
        .image(mfPicture(alpha: false), transform: VectorTransform(a: 30, b: 0, c: 0, d: 30, tx: 160, ty: 150)),
        .image(mfPicture(alpha: true), transform: VectorTransform(a: 30, b: 0, c: 0, d: 30, tx: 70, ty: 20)),
        .group([.path(rect(40, 30, 40, 40), fill: .solid(mfColour(0.5, 0, 1)), stroke: nil)], transform: .identity, clip: nil, opacity: 0.5),
        .text(VectorTextRun(text: "Hello", fontName: "Helvetica", size: 18, origin: VectorPoint(20, 100), fill: .solid(.black))),
    ]
    return VectorDocument(pages: [VectorPage(size: VectorSize(width: 200, height: 200), background: .white, nodes: nodes)])
}

private func mfTexts(_ nodes: [VectorNode]) -> [String] {
    nodes.flatMap { node -> [String] in
        switch node {
        case .text(let run): [run.text]
        case .group(let children, _, _, _): mfTexts(children)
        default: []
        }
    }
}

func registerVectorKitMetafileTests() {
    SelfTest.cases.append(("VectorKit.metafile.emfRecords", {
        // A red brush, a hollow pen, a rectangle; a blue pen and a poly-Bézier; a dashed geometric pen line.
        let emf = emfFile([
            emfRecord(39, [1, 0, 0x0000FF, 0]), emfRecord(37, [1]), emfRecord(37, [0x80000008]),
            emfRecord(43, [10, 10, 50, 50]),
            emfRecord(38, [2, 0, 3, 0, 0xFF0000]), emfRecord(37, [2]),
            emfRecord(2, [0, 0, 0, 0, 4, 60, 80, 70, 60, 90, 100, 95, 80]),
            emfRecord(95, [3, 0, 0, 0, 0, 0x10000 | 0x200 | 7, 4, 0, 0x00FF00, 0, 2, 12, 4]), emfRecord(37, [3]),
            emfRecord(27, [10, 90]), emfRecord(54, [90, 90]),
        ])
        guard let result = try? EMFReader.read(emf), let bitmap = svtRender(result.document, pxPerPoint: 4.0 / 3.0) else { check(false, "EMF reads"); return }
        check(abs(result.document.pages[0].size.width - 75) < 0.5, "frame of 26.46 mm is 75 pt: \(result.document.pages[0].size)")
        check(bitmap.near(30, 30, 255, 0, 0), "red rectangle: \(bitmap.at(30, 30))")
        check(bitmap.near(5, 5, 255, 255, 255), "outside it is white")
        var dashed = false
        func walk(_ nodes: [VectorNode]) {
            for n in nodes {
                if case .path(_, _, let s?, _) = n, !s.dash.isEmpty, s.cap == .butt { dashed = true }
                if case .group(let c, _, _, _) = n { walk(c) }
            }
        }
        walk(result.document.pages[0].nodes)
        check(dashed, "the user-style geometric pen keeps its dashes and flat caps")
    }))

    SelfTest.cases.append(("VectorKit.metafile.emfPlusDual", {
        // EMF+ fills red; the GDI duplicate (blue) that follows without GetDC must not be drawn.
        var fill = MFBytes()
        fill.u32(0xFFFF0000); fill.u32(1); fill.f32(10); fill.f32(10); fill.f32(40); fill.f32(40)
        var header = MFBytes(); header.u32(0xDBC01002); header.u32(1); header.u32(96); header.u32(96)
        let emf = emfFile([
            emfPlusComment([(0x4001, 1, header.bytes), (0x400A, 0x8000, fill.bytes)]),
            emfRecord(39, [1, 0, 0xFF0000, 0]), emfRecord(37, [1]), emfRecord(43, [10, 10, 50, 50]),
            emfPlusComment([(0x4002, 0, [])]),
        ])
        guard let result = try? EMFReader.read(emf), let bitmap = svtRender(result.document, pxPerPoint: 4.0 / 3.0) else { check(false, "dual EMF reads"); return }
        check(bitmap.near(30, 30, 255, 0, 0), "the EMF+ drawing wins: \(bitmap.at(30, 30))")
    }))

    SelfTest.cases.append(("VectorKit.metafile.emfRoundTrip", {
        let doc = mfDrawing()
        guard let written = try? EMFWriter.write(doc, options: VectorWriteOptions()), let back = try? EMFReader.read(written.data) else { check(false, "EMF writes and reads back"); return }
        let page = back.document.pages[0]
        check(abs(page.size.width - 200) < 0.05 && abs(page.size.height - 200) < 0.05, "page size kept: \(page.size)")
        guard let a = svtRender(doc), let b = svtRender(back.document) else { check(false, "renders"); return }
        let mismatch = a.mismatch(b)
        check(mismatch < 0.02, "EMF round trip matches by pixels: \(mismatch)")
        check(b.near(80, 40, 255, 128, 0, tolerance: 30), "the turned, clipped group is drawn: \(b.at(80, 40))")
        check(mfTexts(page.nodes).joined() == "Hello", "text stays text: \(mfTexts(page.nodes))")
        check(written.lossNotes.contains { $0.kind == .shadingRasterised }, "the radial gradient became a picture with a note")
        check(written.lossNotes.contains { $0.detail.contains("groups") }, "so did the group with opacity")
        check(!written.lossNotes.contains { $0.detail.contains("pictures were flattened") }, "pictures with alpha stay as they are (AlphaBlend)")
        svtSave(VectorDrawing.render(page, scale: 2), "emf-roundtrip")

        var outlined = VectorWriteOptions(); outlined.textAsOutlines = true
        if let o = try? EMFWriter.write(doc, options: outlined), let r = try? EMFReader.read(o.data) {
            check(mfTexts(r.document.pages[0].nodes).isEmpty && o.lossNotes.contains { $0.kind == .textAsOutlines }, "text as outlines leaves no text")
        } else { check(false, "outlined EMF") }
    }))

    SelfTest.cases.append(("VectorKit.metafile.wmfRoundTrip", {
        let doc = mfDrawing()
        guard let written = try? WMFWriter.write(doc, options: VectorWriteOptions()), let back = try? WMFReader.read(written.data) else { check(false, "WMF writes and reads back"); return }
        let page = back.document.pages[0]
        check(abs(page.size.width - 200) < 0.1 && abs(page.size.height - 200) < 0.1, "page size from the placeable header: \(page.size)")
        guard let a = svtRender(doc), let b = svtRender(back.document) else { check(false, "renders"); return }
        let mismatch = a.mismatch(b)
        check(mismatch < 0.04, "WMF round trip matches by pixels: \(mismatch)")
        check(b.near(173, 207, 0, 153, 0, tolerance: 20), "even-odd blob filled: \(b.at(173, 207))")
        check(b.near(196, 211, 255, 255, 255, tolerance: 20), "and its hole left open: \(b.at(196, 211))")
        check(b.near(80, 40, 255, 128, 0, tolerance: 30), "the turned group clipped to a triangle (a picture): \(b.at(80, 40))")
        check(mfTexts(page.nodes).joined() == "Hello", "text stays text: \(mfTexts(page.nodes))")
        check(written.lossNotes.contains { $0.kind == .shadingRasterised }, "gradients became pictures with a note")
        check(written.lossNotes.contains { $0.detail.contains("Dash") }, "the dash pattern was simplified, with a note")
        svtSave(VectorDrawing.render(page, scale: 2), "wmf-roundtrip")

        // Text outside Windows-1252 is noted.
        let greek = VectorDocument(pages: [VectorPage(size: VectorSize(width: 100, height: 40), nodes: [
            .text(VectorTextRun(text: "αβγ", fontName: "Helvetica", size: 12, origin: VectorPoint(5, 10), fill: .solid(.black)))])])
        check((try? WMFWriter.write(greek, options: VectorWriteOptions()))?.lossNotes.contains { $0.detail.contains("1252") } == true, "non-1252 text is noted")
    }))

    SelfTest.cases.append(("VectorKit.metafile.wmfPlaceable", {
        // 1000 × 500 units at 1000 per inch: 72 × 36 pt. Red brush, null pen, the left half; a blue polyline; text.
        let wmf = wmfFile([
            wmfRecord(0x020B, [0, 0]), wmfRecord(0x020C, [500, 1000]),
            wmfRecord(0x02FC, [0, 0x00FF, 0x0000, 0]), wmfRecord(0x012D, [0]),
            wmfRecord(0x02FA, [5, 0, 0, 0, 0]), wmfRecord(0x012D, [1]),
            wmfRecord(0x041B, [500, 500, 0, 0]),
            wmfRecord(0x02FA, [0, 20, 0, 0, 0x00FF]), wmfRecord(0x012D, [2]),
            wmfRecord(0x0325, [2, 600, 250, 950, 250]),
            wmfRecord(0x01F0, [2]),
            wmfRecord(0x02FB, [0xFF9C, 0, 0, 0, 400, 0, 0, 0, 0, 0x7241, 0x6169, 0x006C]),
            wmfRecord(0x012D, [2]),
            wmfRecord(0x0A32, [450, 600, 2, 0, 0x6948]),
        ], placeable: (1000, 500, 1000))
        guard let result = try? WMFReader.read(wmf), let bitmap = svtRender(result.document, pxPerPoint: 2) else { check(false, "placeable WMF reads"); return }
        let size = result.document.pages[0].size
        check(abs(size.width - 72) < 0.01 && abs(size.height - 36) < 0.01, "page from the placeable box: \(size)")
        check(bitmap.near(20, 36, 255, 0, 0), "left half red: \(bitmap.at(20, 36))")
        check(bitmap.near(110, 60, 255, 255, 255), "right half white below the line: \(bitmap.at(110, 60))")
        check(bitmap.near(110, 36, 0, 0, 255, tolerance: 40), "the wide blue line: \(bitmap.at(110, 36))")
        check(mfTexts(result.document.pages[0].nodes) == ["Hi"], "EXTTEXTOUT text: \(mfTexts(result.document.pages[0].nodes))")
    }))

    SelfTest.cases.append(("VectorKit.metafile.damaged", {
        let garbage = Data((0..<200).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        check((try? EMFReader.read(garbage)) == nil, "garbage is not an EMF")
        check((try? WMFReader.read(garbage)) == nil, "nor a WMF")
        check((try? WMFReader.read(Data())) == nil, "an empty file is damaged")
        // A WMF cut off in the middle of its second drawing record keeps what came before, with a warning.
        let whole = wmfFile([wmfRecord(0x02FC, [0, 0x00FF, 0, 0]), wmfRecord(0x012D, [0]), wmfRecord(0x041B, [50, 50, 0, 0]),
                             wmfRecord(0x041B, [100, 100, 60, 60])], placeable: (100, 100, 96))
        let cut = whole.prefix(whole.count - 12)
        if let result = try? WMFReader.read(Data(cut)) {
            check(!result.warnings.isEmpty, "a cut-off WMF warns")
            check(!result.document.pages[0].nodes.isEmpty, "and keeps the drawing before the cut")
        } else { check(false, "a cut-off WMF still reads") }
        // An EMF whose second record claims more bytes than the file has.
        var emf = [UInt8](emfFile([emfRecord(43, [10, 10, 50, 50]), emfRecord(43, [60, 60, 90, 90])]))
        emf[88 + 4] = 0xFF
        check((try? EMFReader.read(Data(emf))) == nil || (try? EMFReader.read(Data(emf)))?.warnings.isEmpty == false, "a broken EMF record is caught")
    }))
}

/// Fuzz seeds for the metafile readers (`VectorKit.damagedInputNeverCrashes`): the writers' output of the round-trip
/// drawing (DIBs, AlphaBlend, text), GDI records the writers don't use (regions, gradients, poly-draws, arcs, an RLE
/// pattern brush, clips), an EMF+ stream with every object kind (brush, pen, path, nested region, raw bitmap, font) and
/// the records that draw with them, and a WMF with regions, poly-polygons, arcs, DIBs and clipped text.
func svtMetafileFuzzSeeds() -> [FuzzSeed] {
    var seeds: [FuzzSeed] = []
    if let emf = try? EMFWriter.write(mfDrawing(), options: VectorWriteOptions()) { seeds.append(FuzzSeed(name: "emf-written", ext: "emf", bytes: [UInt8](emf.data))) }
    if let wmf = try? WMFWriter.write(mfDrawing(), options: VectorWriteOptions()) { seeds.append(FuzzSeed(name: "wmf-written", ext: "wmf", bytes: [UInt8](wmf.data))) }

    func f(_ v: Float) -> Int { Int(v.bitPattern) }
    // A 2 × 2 BI_RLE8 DIB with two palette entries, as 32-bit words: header, palette, then the runs.
    let rle = [40, 2, 2, 1 | 8 << 16, 1, 0, 0, 0, 2, 0, 0x0000FF, 0x00FF00, 0x0000_0102, 0x0100_0002]
    let region = [32, 1, 2, 32, 10, 10, 60, 60, 10, 10, 30, 30, 40, 40, 60, 60]
    let gdi = emfFile([
        emfRecord(94, [5, 0, 32, 48, 80, 8] + rle), emfRecord(37, [5]),
        emfRecord(71, [0, 0, 99, 99, region.count * 4, 5] + region), emfRecord(75, [region.count * 4, 1] + region),
        emfRecord(8, [0, 0, 99, 99, 2, 6, 3, 3, 10, 10, 50, 10, 30, 40, 60, 60, 90, 60, 75, 90]),
        emfRecord(56, [0, 0, 99, 99, 4, 10, 10, 20, 30, 40, 30, 50, 10, 0x0204_0406]),
        emfRecord(118, [0, 0, 99, 99, 3, 1, 2, 0, 0, 0xFF00, 0xFF00, 100, 100, 0, 0xFF00, 50, 0, 0xFF00_0000, 0, 0, 1, 2]),
        emfRecord(41, [50, 50, 20, f(30), f(270)]), emfRecord(45, [10, 10, 90, 90, 90, 50, 50, 10]), emfRecord(47, [10, 10, 90, 90, 50, 90, 10, 50]),
        emfRecord(33, []), emfRecord(30, [20, 20, 80, 80]), emfRecord(29, [40, 40, 60, 60]),
        emfRecord(35, [f(1), 0, 0, f(1), f(5), 0]), emfRecord(42, [20, 20, 80, 80]), emfRecord(34, [-1]),
    ])
    seeds.append(FuzzSeed(name: "emf-gdi", ext: "emf", bytes: [UInt8](gdi)))

    var header = MFBytes(); header.u32(0xDBC01002); header.u32(1); header.u32(96); header.u32(96)
    var brush = MFBytes(); brush.u32(0xDBC01002); brush.u32(4); brush.u32(2 | 4); brush.u32(0)
    for v: Float in [0, 0, 50, 50] { brush.f32(v) }
    brush.u32(0xFFFF0000); brush.u32(0xFF0000FF); brush.u32(0); brush.u32(0)
    for v: Float in [1, 0, 0, 1, 0, 0] { brush.f32(v) }
    brush.u32(2); brush.f32(0); brush.f32(1); brush.u32(0xFFFF0000); brush.u32(0xFF0000FF)
    var pen = MFBytes(); pen.u32(0xDBC01002); pen.u32(0); pen.u32(0); pen.u32(2 | 8 | 0x10 | 0x100); pen.u32(0); pen.f32(2)
    pen.u32(2); pen.u32(1); pen.f32(4); pen.u32(2); pen.f32(3); pen.f32(1); pen.u32(0xDBC01002); pen.u32(0); pen.u32(0xFF00FF00)
    var path = MFBytes(); path.u32(0xDBC01002); path.u32(4); path.u32(0)
    for v: Float in [10, 10, 60, 10, 60, 60, 10, 60] { path.f32(v) }
    path.bytes += [0, 1, 1, 0x81]
    var region2 = MFBytes(); region2.u32(0xDBC01002); region2.u32(2); region2.u32(0); region2.u32(0x1000_0000)
    for v: Float in [5, 5, 80, 80] { region2.f32(v) }
    region2.u32(0x1000_0001); region2.u32(path.bytes.count); region2.bytes += path.bytes
    var image = MFBytes(); image.u32(0xDBC01002); image.u32(1); image.u32(2); image.u32(2); image.u32(8); image.u32(0x26200A); image.u32(0)
    image.bytes += [0, 0, 255, 255, 0, 255, 0, 128, 255, 0, 0, 255, 255, 255, 255, 0]
    var font = MFBytes(); font.u32(0xDBC01002); font.f32(12); font.u32(2); font.u32(1); font.u32(0); font.u32(0); font.u32(5)
    for c in "Arial".utf16 { font.u16(Int(c)) }
    func words(_ values: [Int]) -> [UInt8] { var b = MFBytes(); for v in values { b.u32(v) }; return b.bytes }
    let hi = Array("Hi".utf16).map(Int.init)
    let plus = emfFile([
        emfPlusComment([
            (0x4001, 1, header.bytes), (0x4008, 0x0100 | 1, brush.bytes), (0x4008, 0x0200 | 2, pen.bytes), (0x4008, 0x0300 | 3, path.bytes),
            (0x4008, 0x0400 | 4, region2.bytes), (0x4008, 0x0500 | 5, image.bytes), (0x4008, 0x0600 | 6, font.bytes),
            (0x4026, 0, words([1])), (0x402E, 0, words([f(5), f(5)])), (0x402F, 0x2000, words([f(1), f(1)])), (0x4030, 0, words([f(10)])),
            (0x4031, 2, words([f(1)])), (0x4033, 0x0100, words([f(0), f(0), f(90), f(90)])),
            (0x400A, 0x8000, words([0xFFFF0000, 1, f(10), f(10), f(40), f(40)])), (0x400B, 2, words([1, f(5), f(5), f(20), f(20)])),
            (0x400C, 1, words([1, 3, f(0), f(0), f(30), f(0), f(15), f(30)])), (0x400D, 0x2002, words([3, f(0), f(0), f(30), f(0), f(15), f(30)])),
            (0x400E, 0x8000, words([0xFF00FF00, f(50), f(50), f(20), f(10)])), (0x400F, 2, words([f(50), f(50), f(20), f(10)])),
            (0x4010, 0x8000, words([0xFF0000FF, f(30), f(120), f(20), f(20), f(40), f(40)])), (0x4011, 2, words([f(0), f(90), f(20), f(20), f(40), f(40)])),
            (0x4012, 2, words([f(45), f(-200), f(20), f(20), f(40), f(40)])), (0x4014, 3, words([1])), (0x4015, 3, words([2])),
            (0x4038, 3, words([1, 2])), (0x401A, 2, words([4, f(0), f(0), f(10), f(20), f(30), f(20), f(40), f(0)])),
            (0x4016, 0x8000, words([0xFF808080, f(0.5), 3, f(60), f(60), f(80), f(60), f(70), f(80)])),
            (0x4018, 2, words([f(0.5), 0, 0, 3, f(0), f(90), f(20), f(70), f(40), f(90)])),
            (0x401B, 5, words([0, 2, f(0), f(0), f(2), f(2), f(60), f(10), f(20), f(20)])),
            (0x401C, 5, words([0, 2, f(0), f(0), f(1), f(1), 3, f(10), f(60), f(30), f(60), f(10), f(80)])),
            (0x401D, 0x8006, words([0xFF000000, 0, hi.count, f(10), f(80), f(50), f(20), hi[0] | hi[1] << 16])),
            (0x4034, 0x0103, []), (0x4035, 0x0104, []), (0x402D, 0, words([f(1), 0, 0, f(1), f(1), f(1)])), (0x4027, 0, words([1])),
            (0x402B, 0, words([f(1), 0, 0, f(1), 0, 0])), (0x402C, 0, []), (0x4032, 0, []), (0x4004, 0, []),
        ]),
        emfRecord(43, [10, 10, 50, 50]), emfPlusComment([(0x4002, 0, [])]),
    ])
    seeds.append(FuzzSeed(name: "emf-plus", ext: "emf", bytes: [UInt8](plus)))

    // A 2 × 2 24-bit DIB as 16-bit words: the header, then two padded rows.
    let dib = [40, 0, 2, 0, 2, 0, 1, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00FF, 0xFF00, 0, 0, 0, 0xFF, 0xFFFF, 0]
    let wmf = wmfFile([
        wmfRecord(0x06FF, [0, 6, 0, 0, 34, 1, 2, 10, 10, 50, 50, 2, 10, 50, 10, 50, 2]), wmfRecord(0x012C, [0]),
        wmfRecord(0x02FC, [0, 0x00FF, 0, 0]), wmfRecord(0x0228, [0, 1]),
        wmfRecord(0x0538, [2, 3, 3, 10, 10, 50, 10, 30, 40, 60, 60, 90, 60, 75, 90]),
        wmfRecord(0x0817, [50, 90, 90, 50, 90, 90, 10, 10]), wmfRecord(0x081A, [10, 50, 50, 90, 90, 90, 10, 10]),
        wmfRecord(0x0830, [90, 50, 50, 10, 90, 90, 10, 10]), wmfRecord(0x061C, [10, 10, 80, 80, 20, 20]),
        wmfRecord(0x0F43, [0x0020, 0x00CC, 0, 2, 2, 0, 0, 40, 40, 50, 50] + dib),
        wmfRecord(0x0142, [3, 0] + dib), wmfRecord(0x012D, [2]), wmfRecord(0x041B, [60, 60, 20, 20]),
        wmfRecord(0x0A32, [20, 10, 2, 4, 0, 0, 90, 30, 0x6948, 8, 8]),
        wmfRecord(0x0416, [80, 80, 5, 5]), wmfRecord(0x0415, [30, 30, 20, 20]), wmfRecord(0x001E, []), wmfRecord(0x0127, [0xFFFF]),
    ], placeable: (100, 100, 96))
    seeds.append(FuzzSeed(name: "wmf-records", ext: "wmf", bytes: [UInt8](wmf)))
    return seeds
}

/// Hostile metafiles, one per bug the fuzzing and the review found: each trapped, recursed without bound, allocated far
/// more than its bytes or ran for minutes before its fix.
func svtHostileMetafiles() -> [(name: String, ext: String, data: Data)] {
    func f(_ v: Float) -> Int { Int(v.bitPattern) }
    // A 2 × 2 picture header claiming 30 000 × 1 333 pixels (40 M) over a single row of data.
    let tall = [40, 30000, 1333, 1 | 24 << 16, 0, 0, 0, 0, 0, 0] + [Int](repeating: 0, count: 22_500)
    var region = MFBytes(); region.u32(0xDBC01002); region.u32(1)
    for _ in 0..<100_000 { region.u32(0) }   // a run of "combine" nodes, each nesting the next
    var bitmap = MFBytes(); bitmap.u32(0xDBC01002); bitmap.u32(1); bitmap.u32(6000); bitmap.u32(6000); bitmap.u32(24000); bitmap.u32(0x26200A); bitmap.u32(0)
    return [
        ("emf-infinite-sweep", "emf", emfFile([emfRecord(41, [50, 50, 20, f(0), f(.infinity)]), emfRecord(41, [50, 50, 20, f(.nan), f(1e30)])])),
        ("emf-nested-clips", "emf", emfFile(Array(repeating: emfRecord(30, [0, 0, 90, 90]), count: 100_000) + [emfRecord(42, [10, 10, 50, 50])])),
        ("emf-tall-dib", "emf", emfFile([emfRecord(81, [0, 0, 99, 99, 0, 0, 0, 0, 30000, 1333, 80, 40, 120, tall.count * 4 - 40, 0, 0x00CC0020, 100, 100] + tall)])),
        ("emf-plus-deep-region", "emf", emfFile([emfPlusComment([(0x4008, 0x0400 | 1, region.bytes), (0x4035, 0x0101, [])]), emfRecord(42, [10, 10, 50, 50])])),
        ("emf-plus-empty-bitmap", "emf", emfFile([emfPlusComment([(0x4008, 0x0500 | 1, bitmap.bytes)]), emfRecord(42, [10, 10, 50, 50])])),
        ("wmf-many-objects", "wmf", wmfFile(Array(repeating: wmfRecord(0x00F7, []), count: 60_000), placeable: (100, 100, 96))),
    ]
}
