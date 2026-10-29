import AppKit
import SuperConverterCore
import VectorKit

/// A minimal PDF writer for fixtures: objects in order (1-based).
func svtPDF(objects: [String], streams: [Int: String] = [:]) -> Data {
    var out = Data("%PDF-1.7\n".utf8)
    var offsets: [Int] = []
    for (i, body) in objects.enumerated() {
        offsets.append(out.count)
        if let content = streams[i + 1] {
            out.append(Data("\(i + 1) 0 obj\n<< \(body) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream\nendobj\n".utf8))
        } else {
            out.append(Data("\(i + 1) 0 obj\n\(body)\nendobj\n".utf8))
        }
    }
    let xref = out.count
    out.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
    for o in offsets { out.append(Data(String(format: "%010d 00000 n \n", o).utf8)) }
    out.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
    return out
}

/// A one-page PDF (100 × 100) with the given content stream. `extra` objects start at number 5; an entry that starts with
/// "/" is a stream's dictionary body (its content comes from `extraStreams`), anything else is a plain object.
func svtSinglePagePDF(content: String, resources: String = "", extra: [String] = [], extraStreams: [Int: String] = [:]) -> Data {
    var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                   "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Contents 4 0 R /Resources << \(resources) >> >>", "/Type /Stream"]
    objects.append(contentsOf: extra)
    var streams = extraStreams
    streams[4] = content
    return svtPDF(objects: objects, streams: streams)
}

func registerVectorKitPDFTests() {
    SelfTest.cases.append(("VectorKit.pdf.operators", {
        let pdf = svtSinglePagePDF(content: """
        1 0 0 rg 10 10 30 30 re f
        0 0 1 RG 4 w 50 20 m 90 20 l S
        0 1 0 0 k 60 60 30 30 re f
        0.5 g 10 60 20 20 re f
        q 1 0 0 1 0 0 cm 0 0 0 rg [6 6] 0 d 2 w 5 95 m 95 95 l S Q
        q 10 50 m 40 50 l 40 58 l h W n 0 1 1 rg 0 0 100 100 re f Q
        """)
        guard let result = try? PDFReader.read(data: pdf), let bmp = svtRender(result.document, pxPerPoint: 1) else { check(false, "pdf operators parse"); return }
        svtSave(VectorDrawing.render(result.document.pages[0], scale: 2), "pdf-operators")
        check(result.document.pages[0].size == VectorSize(width: 100, height: 100), "page size")
        check(bmp.near(25, 75, 255, 0, 0), "red rect (y flipped to top-left)")
        check(bmp.near(70, 80, 0, 0, 255), "blue stroke")
        check(bmp.at(75, 25).r > 200 && bmp.at(75, 25).g < 80 && bmp.at(75, 25).b > 80, "cmyk magenta")
        check(bmp.near(20, 30, 128, 128, 128, tolerance: 4), "gray fill")
        check(bmp.near(35, 46, 0, 255, 255), "clipped fill inside triangle")
        check(bmp.near(15, 46, 255, 255, 255), "clip excludes outside")
        check(bmp.near(8, 5, 0, 0, 255) && bmp.near(14, 5, 255, 255, 255), "dashed line on then off")
    }))

    SelfTest.cases.append(("VectorKit.pdf.shadingFormPattern", {
        let pdf = svtSinglePagePDF(
            content: """
            q 0 0 50 50 re W n /Sh1 sh Q
            q 1 0 0 1 50 0 cm /Fm1 Do Q
            /Pattern cs /P1 scn 0 50 50 50 re f
            """,
            resources: "/Shading << /Sh1 5 0 R >> /XObject << /Fm1 6 0 R >> /Pattern << /P1 7 0 R >>",
            extra: [
                "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 50 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> /Extend [true true] >>",
                "/Type /XObject /Subtype /Form /BBox [0 0 50 50] /Matrix [1 0 0 1 0 0] /Resources << >>",
                "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << >>",
            ],
            extraStreams: [6: "0 1 0 rg 5 5 40 40 re f", 7: "1 0.5 0 rg 0 0 5 5 re f 0 0 0 rg 5 5 5 5 re f"])
        guard let result = try? PDFReader.read(data: pdf), let bmp = svtRender(result.document, pxPerPoint: 1) else { check(false, "pdf shading parse"); return }
        svtSave(VectorDrawing.render(result.document.pages[0], scale: 3), "pdf-shading")
        check(bmp.at(2, 75).r > 230 && bmp.at(2, 75).b < 30, "axial gradient start")
        check(bmp.at(47, 75).b > 230 && bmp.at(47, 75).r < 30, "axial gradient end")
        check(bmp.near(75, 75, 0, 255, 0), "form xobject translated")
        check(bmp.near(52, 52, 255, 255, 255), "form bbox clips")
        check(bmp.near(2, 47, 255, 128, 0, tolerance: 30), "tiling pattern cell A")
        check(bmp.near(7, 42, 0, 0, 0), "tiling pattern cell B")
        check(bmp.near(2, 42, 255, 255, 255), "tiling gap")
    }))

    SelfTest.cases.append(("VectorKit.pdf.writerRoundTrip", {
        var pixels = Data()
        for y in 0..<4 { for x in 0..<4 { pixels.append(contentsOf: [UInt8(x * 80), UInt8(y * 80), 128, 255]) } }
        let asset = ImageAsset(frames: [ImageFrame(width: 4, height: 4, pixels: .rgba8(pixels, bytesPerRow: 16), hasAlpha: false)])
        let red = VectorColour(red: 1, green: 0, blue: 0), blue = VectorColour(red: 0, green: 0, blue: 1)
        let doc = VectorDocument(pages: [VectorPage(size: VectorSize(width: 150, height: 100), nodes: [
            .path(PathBuilder.rect(x: 10, y: 10, width: 60, height: 40), fill: .solid(red), stroke: VectorStroke(paint: .solid(blue), width: 4, join: .round)),
            .path(PathBuilder.ellipse(cx: 110, cy: 70, rx: 25, ry: 20), fill: .linear(from: VectorPoint(85, 70), to: VectorPoint(135, 70),
                  stops: [GradientStop(offset: 0, colour: red), GradientStop(offset: 1, colour: blue)]), stroke: nil),
            .group([.path(PathBuilder.rect(x: 0, y: 60, width: 70, height: 40), fill: .solid(VectorColour(red: 0, green: 0.6, blue: 0)), stroke: nil)],
                   transform: .identity, clip: PathBuilder.ellipse(cx: 35, cy: 80, rx: 20, ry: 15), opacity: 0.6),
            .text(VectorTextRun(text: "PDF text", fontName: "Helvetica", size: 14, origin: VectorPoint(80, 20), fill: .solid(.black))),
            .image(asset, transform: VectorTransform(a: 30, b: 0, c: 0, d: 30, tx: 110, ty: 10)),
        ])], title: "Fixture")
        guard let written = try? PDFWriter.write(doc, options: VectorWriteOptions()), let back = try? PDFReader.read(data: written.data),
              let a = svtRender(doc, pxPerPoint: 2), let b = svtRender(back.document, pxPerPoint: 2) else { check(false, "pdf round trip"); return }
        svtSave(VectorDrawing.render(back.document.pages[0], scale: 2), "pdf-roundtrip")
        check(back.document.pages[0].size == doc.pages[0].size, "size survives")
        check(back.document.title == "Fixture", "title survives")
        check(a.meanDifference(b) < 1.5, "pdf → vector render difference \(a.meanDifference(b))")
        check(a.mismatch(b) < 0.02, "pdf → vector mismatching pixels \(a.mismatch(b))")
        var hasImage = false
        func walk(_ nodes: [VectorNode]) { for n in nodes { if case .image = n { hasImage = true }; if case .group(let k, _, _, _) = n { walk(k) } } }
        walk(back.document.pages[0].nodes)
        check(hasImage, "picture survives as a picture")
        let outlined = try? PDFWriter.write(doc, options: VectorWriteOptions(textAsOutlines: true))
        check(outlined?.lossNotes.contains { $0.kind == .textAsOutlines } == true, "text as outlines option")
    }))

    SelfTest.cases.append(("VectorKit.pdf.svgPdfSvg", {
        let svg = svtSVG("""
        <defs><radialGradient id="r"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#2040c0"/></radialGradient></defs>
        <rect x="5" y="5" width="90" height="90" fill="url(#r)"/>
        <path d="M10 90 Q 50 10 90 90" fill="none" stroke="#c02020" stroke-width="5" stroke-linecap="round"/>
        <circle cx="30" cy="30" r="10" fill="#20c040" fill-opacity="0.5"/>
        <text x="20" y="55" font-family="Helvetica" font-size="16" fill="#000">Hello</text>
        """)
        guard let first = try? SVGReader.read(svg), let pdf = try? PDFWriter.write(first.document, options: VectorWriteOptions()),
              let mid = try? PDFReader.read(data: pdf.data), let svg2 = try? SVGWriter.write(mid.document, options: VectorWriteOptions()),
              let last = try? SVGReader.read(svg2.data), let a = svtRender(first.document), let b = svtRender(last.document) else { check(false, "svg pdf svg"); return }
        svtSave(VectorDrawing.render(last.document.pages[0], scale: 4.0 / 3.0), "svg-pdf-svg")
        check(a.meanDifference(b) < 1.5, "svg → pdf → svg difference \(a.meanDifference(b))")
        check(a.mismatch(b) < 0.02, "svg → pdf → svg mismatch \(a.mismatch(b))")
        // quality §6 "Text kept": the embedded subset font maps its own characters, so the words stay text, in that program.
        let runs = mid.document.pages[0].nodes.compactMap { if case .text(let run) = $0 { run } else { nil } }
        check(runs.map(\.text).joined() == "Hello" && runs.allSatisfy { $0.fontData != nil && !$0.fontName.contains("+") }, "text stays text in its embedded font: \(runs.map(\.fontName))")
        check(!mid.lossNotes.contains { $0.kind == .textAsOutlines }, "no outlines note")
    }))

    SelfTest.cases.append(("VectorKit.pdf.robustness", {
        check((try? PDFReader.read(data: Data("%PDF-1.4 garbage".utf8))) == nil, "garbage rejected")
        check((try? PDFReader.read(data: Data())) == nil, "empty rejected")
        check((try? AIReader.read(URL(fileURLWithPath: "/nonexistent.ai"))) == nil, "missing file rejected")
        // A content stream that ends mid-operator and recursion through forms must not hang or crash.
        let pdf = svtSinglePagePDF(content: "q 1 0 0 rg 10 10 30 re /Fm1 Do 5 5", resources: "/XObject << /Fm1 5 0 R >>",
                                   extra: ["/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << /XObject << /Fm1 5 0 R >> >>"], extraStreams: [5: "0 0 1 rg 0 0 50 50 re f /Fm1 Do"])
        check((try? PDFReader.read(data: pdf)) != nil, "form recursion and truncated operators survive")
    }))
}
