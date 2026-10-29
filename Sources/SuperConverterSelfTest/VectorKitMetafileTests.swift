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
