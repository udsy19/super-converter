import CoreGraphics
import Foundation
import SuperConverterCore
import CADKit
import RenderKit

// CADKit's checks (WP-C). DXF fixtures are generated here as text (and re-encoded as binary DXF); the plot is checked on its
// geometry, and on pixels rendered through RenderKit's VectorRasterizer.

// MARK: Fixture builders

private func rec(_ type: String, _ pairs: [(Int, String)]) -> String {
    "0\n\(type)\n" + pairs.map { "\($0.0)\n\($0.1)\n" }.joined()
}

private func entity(_ type: String, layer: String = "0", _ pairs: [(Int, String)]) -> String { rec(type, [(8, layer)] + pairs) }

private func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, layer: String = "0", extra: [(Int, String)] = []) -> String {
    entity("LINE", layer: layer, extra + [(10, "\(x1)"), (20, "\(y1)"), (30, "0"), (11, "\(x2)"), (21, "\(y2)"), (31, "0")])
}

private func circle(_ x: Double, _ y: Double, _ r: Double, layer: String = "0", extra: [(Int, String)] = []) -> String {
    entity("CIRCLE", layer: layer, extra + [(10, "\(x)"), (20, "\(y)"), (30, "0"), (40, "\(r)")])
}

/// The 100 × 60 frame most plots use, so the extents (and so the page mapping) are known.
private let frame = line(0, 0, 100, 0) + line(100, 0, 100, 60) + line(100, 60, 0, 60) + line(0, 60, 0, 0)

private func layerRecord(_ name: String, colour: Int = 7, lineType: String = "CONTINUOUS", flags: Int = 0) -> String {
    rec("LAYER", [(2, name), (70, String(flags)), (62, String(colour)), (6, lineType)])
}

private func dxf(version: String = "AC1027", units: Int? = nil, tables: String = "", blocks: String = "", entities: String, objects: String = "") -> String {
    var s = "0\nSECTION\n2\nHEADER\n9\n$ACADVER\n1\n\(version)\n"
    if let units { s += "9\n$INSUNITS\n70\n\(units)\n" }
    s += "0\nENDSEC\n"
    if !tables.isEmpty { s += "0\nSECTION\n2\nTABLES\n" + tables + "0\nENDSEC\n" }
    if !blocks.isEmpty { s += "0\nSECTION\n2\nBLOCKS\n" + blocks + "0\nENDSEC\n" }
    s += "0\nSECTION\n2\nENTITIES\n" + entities + "0\nENDSEC\n"
    if !objects.isEmpty { s += "0\nSECTION\n2\nOBJECTS\n" + objects + "0\nENDSEC\n" }
    return s + "0\nEOF\n"
}

private func table(_ name: String, _ records: String) -> String { "0\nTABLE\n2\n\(name)\n70\n0\n" + records + "0\nENDTAB\n" }

private func block(_ name: String, base: (Double, Double) = (0, 0), _ entities: String) -> String {
    rec("BLOCK", [(8, "0"), (2, name), (70, "0"), (10, "\(base.0)"), (20, "\(base.1)"), (30, "0")]) + entities + rec("ENDBLK", [(8, "0")])
}

/// ASCII DXF text → the binary form (R13+ 2-byte codes), for the reader's binary path.
private func binaryDXF(_ ascii: String) -> Data {
    var out = Data("AutoCAD Binary DXF\r\n\u{1A}\0".utf8)
    let lines = ascii.components(separatedBy: "\n")
    var i = 0
    func le16(_ v: Int) { out.append(UInt8(v & 255)); out.append(UInt8(v >> 8 & 255)) }
    while i + 1 < lines.count {
        guard let code = Int(lines[i].trimmingCharacters(in: .whitespaces)) else { break }
        let value = lines[i + 1]
        i += 2
        le16(code)
        switch code {
        case 10...59, 110...149, 210...239, 460...469, 1010...1059:
            var bits = (Double(value) ?? 0).bitPattern
            for _ in 0..<8 { out.append(UInt8(bits & 255)); bits >>= 8 }
        case 60...79, 170...179, 270...289, 370...389, 400...409, 1060...1070:
            le16(Int(value) ?? 0)
        case 90...99, 420...429, 440...459, 1071:
            var v = UInt32(bitPattern: Int32(value) ?? 0)
            for _ in 0..<4 { out.append(UInt8(v & 255)); v >>= 8 }
        case 290...299:
            out.append(UInt8(Int(value) ?? 0))
        default:
            out.append(contentsOf: Array(value.utf8)); out.append(0)
        }
    }
    return out
}

@MainActor private func read(_ text: String) -> CADDrawing? {
    let url = scratch.appendingPathComponent("fixture-\(UUID().uuidString).dxf")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
    guard case .cad(let drawing)? = fixtureRun(CADKitModuleTests.converter(.dxfReader), from: "dxf", to: .cadDrawing, input: .file(url))?.value else {
        check(false, "DXF didn't read"); return nil
    }
    return drawing
}

/// Unwraps `.styled` for assertions about the entity itself.
private func bare(_ e: CADDrawing.Entity) -> CADDrawing.Entity { if case .styled(let inner, _) = e { return bare(inner) }; return e }

// MARK: Plot and pixels

private func plotOptions(longSide: Double = 1000) -> CADPlotOptions { var o = CADPlotOptions(); o.longSide = longSide; return o }

private struct Sheet {
    let image: CGImage
    let page: VectorPage
    let pixels: [UInt8]
    /// Pixel of a point of the 100 × 60 frame (origin bottom-left), given the margin the plotter uses (2 % of the long side).
    func px(_ x: Double, _ y: Double, longSide: Double = 1000) -> (Int, Int) {
        let m = longSide * 0.02, k = (page.size.width - 2 * m) / 100
        return (Int(m + x * k), image.height - 1 - Int(m + y * k))
    }
    func rgb(_ p: (Int, Int)) -> (Int, Int, Int) {
        let x = min(max(p.0, 0), image.width - 1), y = min(max(p.1, 0), image.height - 1)
        let i = (y * image.width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }
    /// Darkest pixel within `radius` pixels of `p`: lines are thin, so a probe looks around the expected spot.
    func darkest(_ p: (Int, Int), radius: Int = 3) -> Int {
        var best = 765
        for dy in -radius...radius { for dx in -radius...radius { let c = rgb((p.0 + dx, p.1 + dy)); best = min(best, c.0 + c.1 + c.2) } }
        return best
    }
    func isWhite(_ p: (Int, Int)) -> Bool { let c = rgb(p); return c.0 > 245 && c.1 > 245 && c.2 > 245 }
}

@MainActor private func sheet(_ drawing: CADDrawing, options: CADPlotOptions = plotOptions(), pageIndex: Int = 0) -> Sheet? {
    let plotted = CADPlotter.plot(drawing, options: options)
    guard plotted.document.pages.indices.contains(pageIndex) else { check(false, "no page \(pageIndex)"); return nil }
    let page = plotted.document.pages[pageIndex]
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let image = try? VectorRasterizer.render(page, width: Int(page.size.width), height: Int(page.size.height), space: space, transparent: false) else {
        check(false, "plot didn't render"); return nil
    }
    var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
        guard let c = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    check(drawn, "pixels read back")
    return Sheet(image: image, page: page, pixels: buffer)
}

private func textRuns(_ nodes: [VectorNode]) -> [VectorTextRun] {
    nodes.flatMap { node -> [VectorTextRun] in
        switch node {
        case .text(let r): [r]
        case .group(let children, _, _, _): textRuns(children)
        default: []
        }
    }
}

private func groupCount(_ nodes: [VectorNode], clipped: Bool) -> Int {
    nodes.reduce(0) { total, node in
        if case .group(let children, _, let clip, _) = node { return total + ((clip != nil) == clipped ? 1 : 0) + groupCount(children, clipped: clipped) }
        return total
    }
}

private func strokes(_ nodes: [VectorNode]) -> [VectorStroke] {
    nodes.flatMap { node -> [VectorStroke] in
        switch node {
        case .path(_, _, let s, _): s.map { [$0] } ?? []
        case .group(let children, _, _, _): strokes(children)
        default: []
        }
    }
}

enum CADKitModuleTests {
    @MainActor static func converter(_ id: EngineID) -> any Converter {
        CADKitModule.install()
        return Services.converters.converter(for: id)!
    }
}

func registerCADKitTests() {
    SelfTest.cases.append(("CADKit.installsAndRegisters", {
        CADKitModule.install()
        let ids: [EngineID] = [.dxfReader, .cadKit, .dxfWriter, .dwfReader]
        check(ids.allSatisfy { Services.converters.converter(for: $0) != nil }, "all four CADKit engines register")
        check(ids.allSatisfy { id in EngineID.allCases.contains(id) && id.info.module == .cadKit }, "and belong to CADKit in the matrix")
    }))

    SelfTest.cases.append(("CADKit.colourTable", {
        let table = (1...255).map { ACIProbe.rgb($0) }
        check(table[0] == [255, 0, 0] && table[1] == [255, 255, 0] && table[6] == [255, 255, 255] && table[7] == [128, 128, 128], "ACI 1–8")
        check(table[9] == [255, 0, 0] && table[10] == [255, 127, 127] && table[11] == [204, 0, 0] && table[12] == [204, 102, 102], "ACI 10–13")
        check(table[19] == [255, 63, 0] && table[254] == [255, 255, 255] && table[249] == [51, 51, 51], "ACI 20, 255, 250: \(table[19])")
    }))

    SelfTest.cases.append(("CADKit.readsEntitySet", {
        let tables = table("LAYER", layerRecord("WALLS", colour: 1) + layerRecord("HIDDEN", colour: -3) + layerRecord("FROZEN", flags: 1))
            + table("LTYPE", rec("LTYPE", [(2, "DASHED"), (70, "0"), (73, "2"), (40, "0.75"), (49, "0.5"), (49, "-0.25")]))
            + table("STYLE", rec("STYLE", [(2, "ROMAN"), (3, "arial.ttf"), (40, "0"), (41, "0.8"), (50, "15")]))
        var body = line(0, 0, 10, 0, layer: "WALLS")
        body += circle(5, 5, 2)
        body += entity("ARC", [(10, "0"), (20, "0"), (40, "5"), (50, "30"), (51, "120")])
        body += entity("LWPOLYLINE", [(90, "3"), (70, "1"), (10, "0"), (20, "0"), (42, "0.5"), (10, "4"), (20, "0"), (10, "4"), (20, "3")])
        body += entity("POLYLINE", [(66, "1"), (70, "0")]) + entity("VERTEX", [(10, "0"), (20, "0"), (42, "1")]) + entity("VERTEX", [(10, "2"), (20, "0")]) + rec("SEQEND", [(8, "0")])
        body += entity("ELLIPSE", [(10, "0"), (20, "0"), (30, "0"), (11, "4"), (21, "0"), (31, "0"), (40, "0.5"), (41, "0"), (42, "6.283185307")])
        body += entity("SPLINE", [(70, "8"), (71, "3"), (72, "8"), (73, "4"), (40, "0"), (40, "0"), (40, "0"), (40, "0"), (40, "1"), (40, "1"), (40, "1"), (40, "1"),
                                  (10, "0"), (20, "0"), (10, "1"), (20, "2"), (10, "3"), (20, "2"), (10, "4"), (20, "0")])
        body += entity("TEXT", [(10, "1"), (20, "1"), (30, "0"), (40, "2"), (1, "Room %%c20"), (7, "ROMAN"), (72, "1"), (11, "3"), (21, "1"), (31, "0"), (73, "0")])
        body += entity("MTEXT", [(10, "0"), (20, "9"), (30, "0"), (40, "1"), (41, "6"), (71, "5"), (1, "Line one\\PLine {\\fArial|b1;two}")])
        body += entity("POINT", [(10, "1"), (20, "1"), (30, "0")])
        body += entity("SOLID", [(10, "0"), (20, "0"), (11, "2"), (21, "0"), (12, "0"), (22, "2"), (13, "2"), (23, "2")])
        body += entity("3DFACE", [(10, "0"), (20, "0"), (30, "0"), (11, "1"), (21, "0"), (31, "1"), (12, "1"), (22, "1"), (32, "1"), (13, "1"), (23, "1"), (33, "1")])
        body += entity("3DSOLID", [(10, "0")])
        body += circle(1, 1, 1, extra: [(62, "3"), (6, "DASHED"), (370, "50")])
        guard let d = read(dxf(units: 4, tables: tables, entities: body)) else { return }
        check(d.unit == .millimetres && d.sourceVersion == "AC1027", "header: units and version")
        check(d.layers.map(\.name) == ["WALLS", "HIDDEN", "FROZEN"] && d.layers[0].colourIndex == 1, "layers")
        check(!d.layers[1].isVisible && !d.layers[2].isVisible && d.layers[0].isVisible, "off and frozen layers are hidden")
        check(d.lineTypes.first?.pattern == [0.5, -0.25], "linetype pattern")
        check(d.textStyles.first?.font == "arial.ttf" && d.textStyles.first?.widthFactor == 0.8 && d.textStyles.first?.oblique == 15, "text style")
        check(d.modelSpace.count == 13, "entities read (3DSOLID dropped): \(d.modelSpace.count)")
        if case .arc(_, let r, let a, let b, _) = bare(d.modelSpace[2]) { check(r == 5 && a == 30 && b == 120, "arc") } else { check(false, "arc entity") }
        if case .polyline(let pts, let closed, let bulges, _) = bare(d.modelSpace[3]) { check(pts.count == 3 && closed && bulges == [0.5, 0, 0], "LWPOLYLINE with bulge") } else { check(false, "lwpolyline") }
        if case .polyline(let pts, _, let bulges, _) = bare(d.modelSpace[4]) { check(pts.count == 2 && bulges == [1, 0], "POLYLINE vertices") } else { check(false, "polyline") }
        if case .spline(let degree, let cp, let knots, _, _) = bare(d.modelSpace[6]) { check(degree == 3 && cp.count == 4 && knots.count == 8, "spline") } else { check(false, "spline") }
        if case .text(let s, let at, let h, _, let style, let align, _, _) = bare(d.modelSpace[7]) {
            check(s == "Room %%c20" && at.x == 3 && at.y == 1 && h == 2 && style == "ROMAN" && align == .baselineCentre, "TEXT keeps alignment point")
        } else { check(false, "text") }
        if case .multilineText(_, _, _, let w, _, let attach, _, _) = bare(d.modelSpace[8]) { check(w == 6 && attach == 5, "MTEXT width and attachment") } else { check(false, "mtext") }
        if case .solid(let pts, _) = bare(d.modelSpace[10]) { check(pts.count == 4 && pts[2].x == 2 && pts[2].y == 2 && pts[3].x == 0 && pts[3].y == 2, "SOLID outline order 1,2,4,3") } else { check(false, "solid") }
        if case .styled(let inner, let a) = d.modelSpace[12] {
            check(a.colourIndex == 3 && a.lineType == "DASHED" && a.lineWeight == 0.5, "entity colour, linetype, lineweight")
            if case .circle = inner {} else { check(false, "styled circle") }
        } else { check(false, "styled entity") }
    }))

    SelfTest.cases.append(("CADKit.readsBinaryDXF", {
        let text = dxf(entities: line(1, 2, 3, 4) + circle(5, 6, 7) + entity("TEXT", [(10, "0"), (20, "0"), (40, "1"), (1, "héllo")]))
        guard let d = read(text) else { return }
        let url = scratch.appendingPathComponent("binary-\(UUID().uuidString).dxf")
        try? binaryDXF(text).write(to: url)
        guard case .cad(let b)? = fixtureRun(CADKitModuleTests.converter(.dxfReader), from: "dxf", to: .cadDrawing, input: .file(url))?.value else { return check(false, "binary DXF didn't read") }
        check(b.modelSpace == d.modelSpace && b.modelSpace.count == 3, "binary and ASCII DXF read the same entities")
        check(DXFProbe.isBinary(try! Data(contentsOf: url)), "binary sentinel recognised")
        let broken = scratch.appendingPathComponent("broken-\(UUID().uuidString).dxf")
        try? "not a dxf at all".write(to: broken, atomically: true, encoding: .utf8)
        _ = fixtureRun(CADKitModuleTests.converter(.dxfReader), from: "dxf", to: .cadDrawing, input: .file(broken), expectingFailure: true)
    }))

    SelfTest.cases.append(("CADKit.blocksInsertsAndArrays", {
        let blocks = block("BOX", base: (1, 1), line(1, 1, 3, 1) + line(3, 1, 3, 2))
            + block("*D1", circle(0, 0, 1))
            + block("*Model_Space", "") + block("*Paper_Space", "")
        let body = entity("INSERT", [(2, "BOX"), (10, "10"), (20, "20"), (30, "0"), (41, "2"), (42, "2"), (43, "1"), (50, "90"), (70, "3"), (71, "2"), (44, "5"), (45, "4")])
            + entity("DIMENSION", [(2, "*D1"), (70, "0")]) + entity("DIMENSION", [(2, ""), (70, "0")])
        guard let d = read(dxf(blocks: blocks, entities: body)) else { return }
        check(d.blocks.map(\.name) == ["BOX", "*D1"], "blocks (model/paper blocks are not blocks): \(d.blocks.map(\.name))")
        check(d.blocks[0].base.x == 1 && d.blocks[0].entities.count == 2, "block base and content")
        let inserts = d.modelSpace.filter { if case .insert = bare($0) { true } else { false } }
        check(inserts.count == 7, "3 × 2 array plus the dimension block: \(inserts.count)")
        // Plot: BOX at (10,20) rotated 90° with scale 2 → its base (1,1) lands on (10,20); the first segment (1,1)→(3,1)
        // runs 4 units up (rotated x axis is +y).
        let probe = CADDrawing(layers: [.init(name: "0")], blocks: d.blocks, modelSpace: [
            .insert(block: "BOX", at: .init(10, 20), scale: .init(2, 2, 1), rotation: 90, layer: "0"),
            .line(.init(0, 0), .init(0, 0), layer: "0"), .line(.init(100, 60), .init(100, 60), layer: "0")])
        let plotted = CADPlotter.plot(probe, options: plotOptions())
        var points: [VectorPoint] = []
        for case .path(let segs, _, _, _) in plotted.document.pages[0].nodes { for case .move(let p) in segs { points.append(p) }; for case .line(let p) in segs { points.append(p) } }
        let m = 20.0, k = (plotted.document.pages[0].size.width - 2 * m) / 100
        let base = VectorPoint(m + 10 * k, m + 20 * k), end = VectorPoint(m + 10 * k, m + 24 * k)
        check(points.contains { abs($0.x - base.x) < 0.01 && abs($0.y - base.y) < 0.01 }, "insert base lands on the insertion point")
        check(points.contains { abs($0.x - end.x) < 0.01 && abs($0.y - end.y) < 0.01 }, "rotated, scaled block geometry")
    }))

    SelfTest.cases.append(("CADKit.rendersGeometry", {
        // Frame 100 × 60, a circle r = 10 at (50, 30), a diagonal; checked on pixels.
        let body = frame + circle(50, 30, 10) + line(0, 0, 100, 60)
        guard let d = read(dxf(entities: body)), let s = sheet(d) else { return }
        check(s.isWhite((2, 2)), "background is white")
        check(s.darkest(s.px(50, 40)) < 650, "circle ring at the top")
        check(s.darkest(s.px(40, 30)) < 650, "circle ring at the left")
        check(s.darkest(s.px(60, 30)) < 650, "circle ring at the right")
        check(s.isWhite(s.px(50, 33)), "circle is hollow")
        check(s.darkest(s.px(25, 15)) < 650, "diagonal passes through (25, 15)")
        check(s.darkest(s.px(0, 30)) < 650 && s.darkest(s.px(100, 30)) < 650, "frame sides")
        check(abs(s.page.size.width / s.page.size.height - (100 * ((1000 - 40) / 100) + 40) / (60 * ((1000 - 40) / 100) + 40)) < 0.001, "page keeps the drawing's shape")
        check(abs(max(s.page.size.width, s.page.size.height) - 1000) < 0.01, "long side as asked")
    }))

    SelfTest.cases.append(("CADKit.arcDirectionAndBulges", {
        // ARC from 0° to 90° (counter-clockwise) about (0,0) r=30 hits (30,0) and (0,30), not (-30,0); a bulge of 1 is a half circle.
        let body = frame + entity("ARC", [(10, "20"), (20, "10"), (40, "30"), (50, "0"), (51, "90")])
            + entity("LWPOLYLINE", [(90, "2"), (70, "0"), (10, "60"), (20, "50"), (42, "1"), (10, "80"), (20, "50")])
        guard let d = read(dxf(entities: body)), let s = sheet(d) else { return }
        check(s.darkest(s.px(50, 10)) < 650, "arc end at 0°")
        check(s.darkest(s.px(20, 40)) < 650, "arc end at 90°")
        check(s.darkest(s.px(20 + 30 * cos(.pi / 4), 10 + 30 * sin(.pi / 4))) < 650, "arc midpoint at 45°")
        check(s.isWhite(s.px(10, 20)), "arc doesn't wrap the other way")
        // The bulge from (60,50) to (80,50), positive = counter-clockwise: the arc dips below the chord (midpoint (70, 40)).
        check(s.darkest(s.px(70, 40)) < 650, "positive bulge bows to the right of the direction of travel")
    }))

    SelfTest.cases.append(("CADKit.extrusionMirrorsArcs", {
        // An arc whose normal is −Z is the mirror image: centre (−20, 10) in OCS is (20, 10) in world; 0°–90° becomes 90°–180°.
        let body = frame + entity("ARC", [(10, "-60"), (20, "30"), (30, "0"), (40, "20"), (50, "0"), (51, "90"), (210, "0"), (220, "0"), (230, "-1")])
        guard let d = read(dxf(entities: body)) else { return }
        if case .arc(let c, let r, let a, let b, _) = bare(d.modelSpace[4]) {
            check(c.x == 60 && c.y == 30 && r == 20 && a == 90 && b == 180, "mirrored arc: \(c) \(a) \(b)")
        } else { check(false, "arc missing") }
    }))

    SelfTest.cases.append(("CADKit.layersColoursAndVisibility", {
        let tables = table("LAYER", layerRecord("RED", colour: 1) + layerRecord("BLUE", colour: 5) + layerRecord("OFF", colour: -1) + layerRecord("FROZEN", colour: 1, flags: 1))
        let blocks = block("B", line(10, 10, 10, 50, layer: "0"))
        let body = frame
            + line(20, 10, 20, 50, layer: "RED")
            + line(30, 10, 30, 50, layer: "BLUE")
            + line(40, 10, 40, 50, layer: "OFF")
            + line(50, 10, 50, 50, layer: "FROZEN")
            + line(60, 10, 60, 50, layer: "RED", extra: [(62, "3")])
            + line(70, 10, 70, 50, layer: "RED", extra: [(62, "256")])
            + line(80, 10, 80, 50, layer: "0", extra: [(420, "\(0x00FF00 + 0x0000FF * 0)")])
            + entity("INSERT", layer: "BLUE", [(2, "B"), (10, "5"), (20, "0"), (30, "0")])
        guard let d = read(dxf(tables: tables, blocks: blocks, entities: body)), let s = sheet(d) else { return }
        func at(_ x: Double) -> (Int, Int, Int) {
            let p = s.px(x, 30)
            var best = (255, 255, 255)
            for dx in -2...2 { let c = s.rgb((p.0 + dx, p.1)); if c.0 + c.1 + c.2 < best.0 + best.1 + best.2 { best = c } }
            return best
        }
        check(at(20).0 - at(20).1 > 60 && at(20).1 == at(20).2, "layer colour 1 is red: \(at(20))")
        check(at(30).2 - at(30).0 > 60 && at(30).0 == at(30).1, "layer colour 5 is blue: \(at(30))")
        check(at(40) == (255, 255, 255) && at(50) == (255, 255, 255), "off and frozen layers aren't drawn")
        check(at(60).1 - at(60).0 > 60 && at(60).0 == at(60).2, "entity colour 3 is green: \(at(60))")
        check(at(70).0 - at(70).1 > 60, "BYLAYER (256) takes the layer's red: \(at(70))")
        check(at(80).1 - at(80).0 > 60, "true colour: \(at(80))")
        check(at(15).2 - at(15).0 > 60, "layer 0 inside a block takes the INSERT's layer colour: \(at(15))")
    }))

    SelfTest.cases.append(("CADKit.backgroundAndMonochrome", {
        let tables = table("LAYER", layerRecord("RED", colour: 1))
        let body = frame + line(50, 10, 50, 50, layer: "RED") + line(30, 10, 30, 50, layer: "0")
        guard let d = read(dxf(tables: tables, entities: body)) else { return }
        var dark = plotOptions(); dark.background = VectorColour(red: 0, green: 0, blue: 0)
        guard let s = sheet(d, options: dark) else { return }
        let white = s.rgb(s.px(30, 30))
        check(s.rgb((2, 2)) == (0, 0, 0) && white.0 > 60 && white.0 == white.2, "black background turns ACI 7 white: \(white)")
        var mono = plotOptions(); mono.monochrome = true
        guard let m = sheet(d, options: mono) else { return }
        let c = m.rgb(m.px(50, 30))
        check(c.0 < 230 && c.0 == c.1 && c.1 == c.2, "monochrome prints every colour black: \(c)")
    }))

    SelfTest.cases.append(("CADKit.linetypesAndWeights", {
        let tables = table("LTYPE", rec("LTYPE", [(2, "DASHED"), (70, "0"), (73, "2"), (40, "10"), (49, "6"), (49, "-4")]))
            + table("LAYER", layerRecord("D", lineType: "DASHED"))
        let body = frame + line(10, 30, 90, 30, layer: "D") + line(10, 40, 90, 40, extra: [(370, "100")]) + line(10, 20, 90, 20)
        guard let d = read(dxf(tables: tables, entities: body)) else { return }
        let plotted = CADPlotter.plot(d, options: plotOptions())
        let all = strokes(plotted.document.pages[0].nodes)
        let dashed = all.filter { !$0.dash.isEmpty }
        let k = (plotted.document.pages[0].size.width - 40) / 100
        check(dashed.count == 1 && abs(dashed[0].dash[0] - 6 * k) < 0.01 && abs(dashed[0].dash[1] - 4 * k) < 0.01, "layer linetype becomes a scaled dash array")
        check(all.contains { abs($0.width - 1.0 * 72 / 25.4) < 0.01 }, "lineweight 1.00 mm in points")
        check(all.contains { abs($0.width - 0.25 * 72 / 25.4) < 0.5 }, "default weight 0.25 mm (floor 0.5 pt)")
        var thin = plotOptions(); thin.thinLines = true
        check(strokes(CADPlotter.plot(d, options: thin).document.pages[0].nodes).allSatisfy { $0.width == 0.5 }, "thin lines option")
    }))

    SelfTest.cases.append(("CADKit.textAndMText", {
        let tables = table("STYLE", rec("STYLE", [(2, "ARIALSTYLE"), (3, "arial.ttf"), (41, "1")]) + rec("STYLE", [(2, "SHXSTYLE"), (3, "romans.shx"), (41, "1")]))
        let body = frame
            + entity("TEXT", [(10, "10"), (20, "10"), (30, "0"), (40, "5"), (1, "Dia %%c20 90%%d"), (7, "ARIALSTYLE")])
            + entity("TEXT", [(10, "10"), (20, "30"), (30, "0"), (40, "5"), (1, "Rot"), (50, "90"), (7, "SHXSTYLE")])
            + entity("MTEXT", [(10, "50"), (20, "50"), (30, "0"), (40, "4"), (41, "0"), (71, "1"), (1, "{\\fArial|b1;Hello}\\PSecond \\Sone^two; line")])
        guard let d = read(dxf(tables: tables, entities: body)) else { return }
        let plotted = CADPlotter.plot(d, options: plotOptions())
        let runs = textRuns(plotted.document.pages[0].nodes)
        check(runs.map(\.text) == ["Dia Ø20 90°", "Rot", "Hello", "Second one/two line"], "text, control codes and MTEXT codes: \(runs.map(\.text))")
        check(runs[0].fontName == "Arial" && runs[1].fontName == "Helvetica", "TrueType styles keep their font, SHX falls back")
        let k = (plotted.document.pages[0].size.width - 40) / 100
        check(abs(runs[0].size - 5 * k) < 0.01, "text height scales with the drawing")
        check(plotted.lossNotes.contains { $0.kind == .fontsReplaced }, "SHX fonts are reported")
        // Rotation lives in the group transform: 90° turns the x axis onto +y.
        for case .group(let kids, let t, _, _) in plotted.document.pages[0].nodes {
            if case .text(let r)? = kids.first, r.text == "Rot" { check(abs(t.a) < 1e-9 && abs(t.b - 1) < 1e-9, "TEXT rotation") }
        }
        // Centre alignment moves the origin left by half the width.
        let centred = CADDrawing(layers: [.init(name: "0")], modelSpace: [
            .text("Mid", at: .init(50, 50), height: 10, rotation: 0, style: "STANDARD", align: .baselineCentre, widthFactor: 1, layer: "0"),
            .text("Mid", at: .init(50, 50), height: 10, rotation: 0, style: "STANDARD", align: .baselineLeft, widthFactor: 1, layer: "0")])
        let c = CADPlotter.plot(centred, options: plotOptions()).document.pages[0].nodes
        var xs: [Double] = []
        for case .group(_, let t, _, _) in c { xs.append(t.tx) }
        check(xs.count == 2 && xs[0] < xs[1], "centred text starts left of left-aligned text")
    }))

    SelfTest.cases.append(("CADKit.hatches", {
        // A solid square with a square hole, and a pattern-hatched square.
        func hatchPath(_ pts: [(Double, Double)]) -> [(Int, String)] {
            [(92, "7"), (93, "\(pts.count)")] + pts.flatMap { [(10, "\($0.0)"), (20, "\($0.1)")] }
        }
        func hatch(solid: Bool, loops: [[(Double, Double)]], lines: [(Double, Double, Double, Double, Double)] = []) -> String {
            var pairs: [(Int, String)] = [(10, "0"), (20, "0"), (30, "0"), (2, solid ? "SOLID" : "ANSI31"), (70, solid ? "1" : "0"), (71, "0"), (91, "\(loops.count)")]
            for loop in loops {
                pairs += [(92, "2"), (72, "0"), (73, "1"), (93, "\(loop.count)")] + loop.flatMap { [(10, "\($0.0)"), (20, "\($0.1)")] } + [(97, "0")]
            }
            pairs += [(75, "0"), (76, "1")]
            if !solid {
                pairs += [(52, "0"), (41, "1"), (77, "0"), (78, "\(lines.count)")]
                for l in lines { pairs += [(53, "\(l.0)"), (43, "\(l.1)"), (44, "\(l.2)"), (45, "\(l.3)"), (46, "\(l.4)"), (79, "0")] }
            }
            pairs += [(98, "0")]
            return entity("HATCH", pairs)
        }
        let outer: [(Double, Double)] = [(10, 10), (50, 10), (50, 50), (10, 50)]
        let hole: [(Double, Double)] = [(20, 20), (40, 20), (40, 40), (20, 40)]
        let patterned: [(Double, Double)] = [(60, 10), (90, 10), (90, 50), (60, 50)]
        let body = frame + hatch(solid: true, loops: [outer, hole]) + hatch(solid: false, loops: [patterned], lines: [(45, 0, 0, -2.0, 2.0)])
        guard let d = read(dxf(tables: table("LAYER", layerRecord("0", colour: 1)), entities: body)), let s = sheet(d) else { return }
        if case .hatch(let loops, _, let solid, let lines, _) = bare(d.modelSpace[4]) { check(loops.count == 2 && solid && lines.isEmpty, "solid hatch with island") } else { check(false, "hatch entity") }
        if case .hatch(_, _, let solid, let lines, _) = bare(d.modelSpace[5]) { check(!solid && lines.count == 1 && lines[0].angle == 45, "pattern hatch keeps its lines") } else { check(false, "pattern hatch entity") }
        let ring = s.rgb(s.px(15, 30)), inHole = s.rgb(s.px(30, 30))
        check(ring.0 > 200 && ring.1 < 80, "hatch ring is filled: \(ring)")
        check(inHole.0 > 245 && inHole.1 > 245 && inHole.2 > 245, "island leaves a hole: \(inHole)")
        // The 45° pattern is clipped to its square: inked inside, nothing outside.
        var inked = 0, outside = 0
        for y in stride(from: 12.0, to: 49.0, by: 0.7) { for x in stride(from: 62.0, to: 89.0, by: 0.7) where s.darkest(s.px(x, y), radius: 0) < 700 { inked += 1 } }
        for y in stride(from: 12.0, to: 49.0, by: 0.7) { for x in stride(from: 52.0, to: 58.0, by: 0.7) where s.darkest(s.px(x, y), radius: 0) < 700 { outside += 1 } }
        check(inked > 40, "pattern lines drawn inside the boundary (\(inked))")
        check(outside == 0, "and none outside (\(outside))")
    }))

    SelfTest.cases.append(("CADKit.zoomToExtentsIgnoresStrays", {
        var body = frame
        for i in 0..<400 { body += line(Double(i % 100), 5, Double(i % 100) + 0.5, 55) }
        body += line(0, 0, 1_000_000, 1_000_000)
        guard let d = read(dxf(entities: body)) else { return }
        let zoomed = CADPlotter.plot(d, options: plotOptions()).document.pages[0].size
        check(zoomed.width / zoomed.height < 3 && zoomed.width / zoomed.height > 0.3, "stray entity ignored: page \(zoomed)")
        var full = plotOptions(); full.autoZoom = false
        let all = CADPlotter.plot(d, options: full).document.pages[0].size
        check(abs(all.width / all.height - 1) < 0.01, "without zoom the stray sets the extents")
    }))

    SelfTest.cases.append(("CADKit.paperSizesAndBackground", {
        guard let d = read(dxf(entities: frame)) else { return }
        var o = plotOptions(); o.paper = "a4"
        let size = CADPlotter.plot(d, options: o).document.pages[0].size
        check(abs(size.width - 297 * 72 / 25.4) < 0.01 && abs(size.height - 210 * 72 / 25.4) < 0.01, "A4 landscape for a wide drawing")
        o.background = CADPlotOptions(OptionValues(["background": "#102030"]), rasterTarget: false).background
        check(CADPlotter.plot(d, options: o).document.pages[0].background == VectorColour(red: 16.0 / 255, green: 32.0 / 255, blue: 48.0 / 255), "background colour")
        var raster = OptionValues(["width": 2000]); raster["colours"] = "mono"
        let r = CADPlotOptions(raster, rasterTarget: true)
        check(abs(r.longSide - 1500) < 0.01 && r.monochrome, "raster size becomes points at 96 dpi")
    }))

    SelfTest.cases.append(("CADKit.layoutsAndViewports", {
        let objects = rec("LAYOUT", [(5, "50"), (100, "AcDbPlotSettings"), (1, ""), (44, "200"), (45, "100"), (72, "1"), (100, "AcDbLayout"), (1, "Sheet A"), (330, "51")])
        let tables = table("BLOCK_RECORD", rec("BLOCK_RECORD", [(5, "51"), (2, "*Paper_Space")]))
        // Model space: a 100 × 60 frame; the viewport shows its lower-left 50 × 30 quarter in a 100 × 60 window on the sheet.
        let vp = entity("VIEWPORT", [(67, "1"), (10, "100"), (20, "50"), (30, "0"), (40, "100"), (41, "60"), (68, "1"), (69, "2"), (12, "25"), (22, "15"), (45, "30")])
        let paperFrame = entity("LINE", [(67, "1"), (10, "0"), (20, "0"), (11, "200"), (21, "0"), (31, "0")])
        guard let d = read(dxf(tables: tables, entities: frame + circle(25, 15, 5) + paperFrame + vp, objects: objects)) else { return }
        check(d.layouts.count == 1 && d.layouts[0].name == "Sheet A", "layout from the LAYOUT object")
        check(d.layouts[0].paperSize == VectorSize(width: 200, height: 100), "paper size (mm)")
        check(d.layouts[0].entities.count == 2, "paper-space entities belong to the layout: \(d.layouts[0].entities.count)")
        var o = plotOptions(); o.allLayouts = true
        let plotted = CADPlotter.plot(d, options: o)
        check(plotted.document.pages.count == 1, "one page per layout")
        check(abs(plotted.document.pages[0].size.width / plotted.document.pages[0].size.height - 2) < 0.001, "page is the paper")
        check(groupCount(plotted.document.pages[0].nodes, clipped: true) == 1, "the viewport is a clipped group")
        guard let s = sheet(d, options: o) else { return }
        // Viewport (100 × 60 at (100, 50)) shows model (25, 15) at its centre: the circle (r = 5 → 10 on paper) is there.
        let k = s.page.size.width / 200
        let px = { (x: Double, y: Double) in (Int(x * k), s.image.height - 1 - Int(y * k)) }
        check(s.darkest(px(110, 50), radius: 3) < 650, "model geometry appears inside the viewport")
        check(s.isWhite(px(40, 50)), "and not outside it")
        // Without allLayouts the model space is plotted.
        let model = CADPlotter.plot(d, options: plotOptions())
        check(model.document.pages.count == 1 && model.document.pages[0].size.width < model.document.pages[0].size.height * 2, "model space by default")
    }))

    SelfTest.cases.append(("CADKit.plotsViaConverter", {
        let url = scratch.appendingPathComponent("plot-\(UUID().uuidString).dxf")
        try? dxf(entities: frame + circle(50, 30, 10)).write(to: url, atomically: true, encoding: .utf8)
        guard case .cad(let d)? = fixtureRun(CADKitModuleTests.converter(.dxfReader), from: "dxf", to: .cadDrawing, input: .file(url))?.value,
              case .vector(let doc)? = fixtureRun(CADKitModuleTests.converter(.cadKit), from: .cadDrawing, to: .vectorDocument, input: .cad(d))?.value else {
            return check(false, "DXF → CADDrawing → VectorDocument")
        }
        check(doc.pages.count == 1 && !doc.pages[0].nodes.isEmpty, "converter output has a page with nodes")
        _ = fixtureRun(CADKitModuleTests.converter(.dwfReader), from: "dwf", to: .cadDrawing, input: .file(url), expectingFailure: true)
    }))

    SelfTest.cases.append(("CADKit.dxfWriterRoundTrip", {
        let tables = table("LAYER", layerRecord("WALLS", colour: 1) + layerRecord("DIMS", colour: 3, lineType: "DASHED"))
            + table("LTYPE", rec("LTYPE", [(2, "DASHED"), (70, "0"), (73, "2"), (40, "1"), (49, "0.5"), (49, "-0.5")]))
        let blocks = block("BOX", line(0, 0, 1, 0) + line(1, 0, 1, 1))
        let body = frame + line(1, 2, 3, 4, layer: "WALLS") + circle(5, 5, 2, layer: "DIMS")
            + entity("ARC", layer: "WALLS", [(10, "0"), (20, "0"), (40, "5"), (50, "10"), (51, "80")])
            + entity("LWPOLYLINE", [(90, "3"), (70, "1"), (10, "0"), (20, "0"), (42, "0.5"), (10, "4"), (20, "0"), (10, "4"), (20, "3")])
            + entity("ELLIPSE", [(10, "5"), (20, "5"), (30, "0"), (11, "4"), (21, "0"), (31, "0"), (40, "0.5"), (41, "0"), (42, "6.283185307179586")])
            + entity("TEXT", [(10, "1"), (20, "1"), (30, "0"), (40, "2"), (1, "Größe"), (7, "STANDARD")])
            + entity("MTEXT", [(10, "0"), (20, "9"), (30, "0"), (40, "1"), (41, "6"), (71, "1"), (1, "one\\Ptwo")])
            + entity("INSERT", [(2, "BOX"), (10, "10"), (20, "20"), (30, "0"), (41, "2"), (42, "2"), (43, "1"), (50, "30")])
            + circle(1, 1, 1, extra: [(62, "3"), (370, "50")])
        guard let source = read(dxf(tables: tables, blocks: blocks, entities: body)) else { return }
        for version in ["12", "14", "2000", "2004", "2007", "2010", "2013", "2018"] {
            let written = DXFWriter.write(source, version: DXFVersion(option: version))
            let text = String(decoding: written.data, as: UTF8.self)
            let expectedCode = ["12": "AC1009", "14": "AC1014", "2000": "AC1015", "2004": "AC1018", "2007": "AC1021", "2010": "AC1024", "2013": "AC1027", "2018": "AC1032"][version]!
            check(text.contains("$ACADVER\n1\n\(expectedCode)\n") && text.hasSuffix("0\nEOF\n"), "R\(version): version code and EOF")
            let url = scratch.appendingPathComponent("rt-\(version)-\(UUID().uuidString).dxf")
            try? written.data.write(to: url)
            guard case .cad(let back)? = fixtureRun(CADKitModuleTests.converter(.dxfReader), from: "dxf", to: .cadDrawing, input: .file(url))?.value else {
                check(false, "R\(version) output didn't re-read"); continue
            }
            let isR12 = version == "12"
            check(back.layers.map(\.name).contains("WALLS") && back.layers.first { $0.name == "WALLS" }?.colourIndex == 1, "R\(version): layers")
            check(back.blocks.map(\.name) == ["BOX"] && back.blocks[0].entities.count == 2, "R\(version): blocks \(back.blocks.map(\.name))")
            check(back.lineTypes.first { $0.name == "DASHED" }?.pattern == [0.5, -0.5], "R\(version): linetype")
            check(back.modelSpace.count == source.modelSpace.count + (isR12 ? 1 : 0), "R\(version): entity count \(back.modelSpace.count) vs \(source.modelSpace.count)")
            if case .text(let s, _, _, _, _, _, _, _) = bare(back.modelSpace.first { if case .text = bare($0) { true } else { false } } ?? .point(.init(0, 0), layer: "0")) {
                check(s == "Größe", "R\(version): non-ASCII text survives")
            } else { check(false, "R\(version): text entity") }
            if let styled = back.modelSpace.last, case .styled(_, let a) = styled { check(a.colourIndex == 3 && (isR12 || a.lineWeight == 0.5), "R\(version): entity colour/weight") } else { check(false, "R\(version): styled circle") }
            // Geometry round trip: same pixels.
            if let a = sheet(source), let b = sheet(back) {
                var different = 0
                if a.pixels.count == b.pixels.count { for i in stride(from: 0, to: a.pixels.count, by: 4) where abs(Int(a.pixels[i + 1]) - Int(b.pixels[i + 1])) > 40 { different += 1 } } else { different = Int.max }
                check(different < (isR12 ? 400 : 50), "R\(version): plot after the round trip matches (\(different) pixels differ)")
            }
            if !isR12 {
                // Handles unique, ENTITIES owner handles resolve.
                let rows = text.components(separatedBy: "\n")
                let handles = stride(from: 0, to: rows.count - 1, by: 2).filter { rows[$0] == "5" }.map { rows[$0 + 1] }
                check(Set(handles).count == handles.count, "R\(version): handles are unique (\(handles.count))")
            }
        }
    }))

    SelfTest.cases.append(("CADKit.dxfWriterFromVectorArtwork", {
        // A red filled square with a blue stroke, a curve and a text run, as VectorKit would hand them over.
        let red = VectorColour(red: 1, green: 0, blue: 0), blue = VectorColour(red: 0, green: 0, blue: 1)
        let square: [PathSegment] = [.move(VectorPoint(72, 72)), .line(VectorPoint(144, 72)), .line(VectorPoint(144, 144)), .line(VectorPoint(72, 144)), .close]
        let curve: [PathSegment] = [.move(VectorPoint(0, 0)), .cubic(VectorPoint(10, 40), VectorPoint(50, 40), VectorPoint(72, 0))]
        let doc = VectorDocument(pages: [VectorPage(size: VectorSize(width: 200, height: 200), nodes: [
            .path(square, fill: .solid(red), stroke: VectorStroke(paint: .solid(blue), width: 2)),
            .path(curve, fill: nil, stroke: VectorStroke(paint: .solid(blue), width: 1)),
            .text(VectorTextRun(text: "Hi", fontName: "Helvetica", size: 12, origin: VectorPoint(10, 180), fill: .solid(blue)))])])
        let url = scratch.appendingPathComponent("art-\(UUID().uuidString).svg")
        try? "x".write(to: url, atomically: true, encoding: .utf8)
        guard case .file(let out)? = fixtureRun(CADKitModuleTests.converter(.dxfWriter), from: .vectorDocument, to: "dxf", input: .vector(doc),
                                                options: OptionValues(["dxfUnits": "mm", "dxfVersion": "2018"]))?.value,
              let data = try? Data(contentsOf: out), case .cad(let back)? = fixtureRun(CADKitModuleTests.converter(.dxfReader), from: "dxf", to: .cadDrawing, input: .file(out))?.value else {
            return check(false, "vector → DXF")
        }
        check(String(decoding: data, as: UTF8.self).contains("AC1032") && back.unit == .millimetres, "R2018 in millimetres")
        let mm = 25.4 / 72
        var hatches = 0, polylines = 0, texts = 0
        for e in back.modelSpace {
            switch bare(e) {
            case .hatch(let loops, _, let solid, _, _):
                hatches += 1
                check(solid && loops.count == 1 && abs(loops[0][0].x - 72 * mm) < 1e-6 && abs(loops[0][2].y - 144 * mm) < 1e-6, "filled square becomes a solid hatch in mm")
            case .polyline: polylines += 1
            case .text(let s, let at, let h, _, _, _, _, _): texts += 1; check(s == "Hi" && abs(at.x - 10 * mm) < 1e-6 && abs(h - 12 * mm) < 1e-6, "text run")
            default: break
            }
        }
        check(hatches == 1 && polylines == 2 && texts == 1, "hatch \(hatches), polylines \(polylines), text \(texts)")
        if case .styled(_, let a)? = back.modelSpace.dropFirst().first { check(a.trueColour == 0xFF0000 || a.trueColour == 0x0000FF, "true colour kept") }
    }))
}

/// Access to internals the checks need without widening CADKit's public surface.
private enum ACIProbe { static func rgb(_ i: Int) -> [Int] { let c = CADKitProbe.aci(i); return [c.0, c.1, c.2] } }
private enum DXFProbe { static func isBinary(_ d: Data) -> Bool { CADKitProbe.isBinaryDXF(d) } }
