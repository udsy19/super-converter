import AppKit
import Compression
import SuperConverterCore
import VectorKit
import XPSKit

// XPSKit's checks (WP-V): packages built here (by hand and through the writer), read back and compared by rendered pixels.
// Renders go to $SUPERCONVERTER_SELFTEST_RENDERS when it is set, so they can be looked at.

private func crc(_ data: Data) -> UInt32 {
    var table = [UInt32](repeating: 0, count: 256)
    for i in 0..<256 { var c = UInt32(i); for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }; table[i] = c }
    var c: UInt32 = 0xFFFF_FFFF
    for b in data { c = table[Int((c ^ UInt32(b)) & 255)] ^ (c >> 8) }
    return c ^ 0xFFFF_FFFF
}

/// A ZIP archive built independently of the module under test. `lieAboutSize` writes a smaller declared size than the data.
private func makeZip(_ files: [(String, Data)], deflate: Bool = true, declaredSize: ((Int) -> Int)? = nil) -> Data {
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255)] }
    func le32(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)] }
    var body = [UInt8](), directory = [UInt8]()
    for (name, data) in files {
        var method = 0
        var payload = [UInt8](data)
        if deflate, data.count > 32 {
            var out = [UInt8](repeating: 0, count: data.count + 1024)
            let n = data.withUnsafeBytes { compression_encode_buffer(&out, out.count, $0.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB) }
            if n > 0 { method = 8; payload = Array(out[0..<n]) }
        }
        let size = declaredSize?(data.count) ?? data.count
        let nameBytes = Array(name.utf8)
        let offset = body.count
        body += le32(0x0403_4b50) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0) + le32(Int(crc(data))) + le32(payload.count) + le32(size) + le16(nameBytes.count) + le16(0) + nameBytes + payload
        directory += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(method) + le16(0) + le16(0) + le32(Int(crc(data))) + le32(payload.count) + le32(size)
        directory += le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + nameBytes
    }
    let end = le32(0x0605_4b50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(directory.count) + le32(body.count) + le16(0)
    return Data(body + directory + end)
}

private func xpsText(_ s: String) -> Data { Data(s.utf8) }

private let relsXML = """
<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="R0" Type="http://schemas.microsoft.com/xps/2005/06/fixedrepresentation" Target="/FixedDocumentSequence.fdseq"/></Relationships>
"""
private let seqXML = """
<FixedDocumentSequence xmlns="http://schemas.microsoft.com/xps/2005/06"><DocumentReference Source="/Documents/1/FixedDocument.fdoc"/></FixedDocumentSequence>
"""

/// A one-page package around `page` (the inner XML of a 200 × 200 px FixedPage) plus extra parts.
private func handPackage(_ page: String, extra: [(String, Data)] = [], width: Int = 200, height: Int = 200, rels: String = relsXML) -> Data {
    let fpage = "<FixedPage xmlns=\"http://schemas.microsoft.com/xps/2005/06\" xmlns:x=\"http://schemas.microsoft.com/winfx/2006/xaml\" Width=\"\(width)\" Height=\"\(height)\">\(page)</FixedPage>"
    return makeZip([("[Content_Types].xml", xpsText("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>")),
                    ("_rels/.rels", xpsText(rels)), ("FixedDocumentSequence.fdseq", xpsText(seqXML)),
                    ("Documents/1/FixedDocument.fdoc", xpsText("<FixedDocument xmlns=\"http://schemas.microsoft.com/xps/2005/06\"><PageContent Source=\"Pages/1.fpage\"/></FixedDocument>")),
                    ("Documents/1/Pages/1.fpage", xpsText(fpage))] + extra)
}

private struct Bitmap {
    let width: Int, height: Int
    var bytes: [UInt8]
    init?(_ image: CGImage?) {
        guard let image else { return nil }
        width = image.width; height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }
    func near(_ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int, tolerance: Int = 14) -> Bool {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return abs(Int(bytes[i]) - r) <= tolerance && abs(Int(bytes[i + 1]) - g) <= tolerance && abs(Int(bytes[i + 2]) - b) <= tolerance
    }
    func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) { let i = (y * width + x) * 4; return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])) }
    func meanDifference(_ o: Bitmap) -> Double {
        guard width == o.width, height == o.height else { return 255 }
        var t = 0
        for i in 0..<bytes.count { t += abs(Int(bytes[i]) - Int(o.bytes[i])) }
        return Double(t) / Double(bytes.count)
    }
    func mismatch(_ o: Bitmap) -> Double {
        guard width == o.width, height == o.height else { return 1 }
        var bad = 0
        for p in 0..<(width * height) { var w = 0; for c in 0..<3 { w = max(w, abs(Int(bytes[p * 4 + c]) - Int(o.bytes[p * 4 + c]))) }; if w > 40 { bad += 1 } }
        return Double(bad) / Double(width * height)
    }
}

/// Page 0 rendered with one image pixel per XPS pixel (96 dpi).
private func render(_ doc: VectorDocument) -> CGImage? { doc.pages.first.flatMap { VectorDrawing.render($0, scale: 4.0 / 3.0) } }

private func save(_ image: CGImage?, _ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["SUPERCONVERTER_SELFTEST_RENDERS"], let image else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
}

private func png(_ r: UInt8, _ g: UInt8, _ b: UInt8, size: Int = 4) -> Data {
    var px = Data()
    for _ in 0..<(size * size) { px.append(contentsOf: [r, g, b, 255]) }
    let asset = ImageAsset(frames: [ImageFrame(width: size, height: size, pixels: .rgba8(px, bytesPerRow: size * 4), hasAlpha: false)])
    return ImageBridge.pngData(asset)!
}

private let arialURL = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")

func registerXPSKitTests() {
    SelfTest.cases.append(("XPSKit.installs", {
        XPSKitModule.install()
        check(Services.converters.converter(for: .xpsKit) != nil && Services.converters.converter(for: .xpsWriter) != nil, "both engines registered")
    }))

    SelfTest.cases.append(("XPSKit.roundTrip", {
        let red = VectorColour(red: 1, green: 0, blue: 0), blue = VectorColour(red: 0, green: 0, blue: 1), green = VectorColour(red: 0, green: 0.6, blue: 0)
        var px = Data()
        for y in 0..<8 { for x in 0..<8 { px.append(contentsOf: [UInt8(x * 32), UInt8(y * 32), 200, 255]) } }
        let asset = ImageAsset(frames: [ImageFrame(width: 8, height: 8, pixels: .rgba8(px, bytesPerRow: 32), hasAlpha: false)])
        let doc = VectorDocument(pages: [VectorPage(size: VectorSize(width: 150, height: 112.5), nodes: [
            .path(PathBuilder.rect(x: 10, y: 10, width: 60, height: 40), fill: .solid(red),
                  stroke: VectorStroke(paint: .solid(blue), width: 4, dash: [6, 3], cap: .round, join: .round)),
            .path(PathBuilder.ellipse(cx: 110, cy: 80, rx: 25, ry: 20), fill: .linear(from: VectorPoint(85, 80), to: VectorPoint(135, 80),
                  stops: [GradientStop(offset: 0, colour: red), GradientStop(offset: 1, colour: blue)]), stroke: nil),
            .group([.path(PathBuilder.rect(x: 0, y: 60, width: 70, height: 50), fill: .radial(centre: VectorPoint(35, 85), radius: 30,
                  stops: [GradientStop(offset: 0, colour: .white), GradientStop(offset: 1, colour: green)]), stroke: nil)],
                   transform: .identity, clip: PathBuilder.ellipse(cx: 35, cy: 85, rx: 22, ry: 17), opacity: 0.8),
            .path(PathBuilder.rect(x: 80, y: 5, width: 20, height: 20) + PathBuilder.rect(x: 85, y: 10, width: 10, height: 10), fill: .solid(.black), stroke: nil, rule: .evenOdd),
            .group([.path(PathBuilder.rect(x: -8, y: -4, width: 16, height: 8), fill: .solid(green), stroke: nil)],
                   transform: VectorTransform(a: cos(0.5), b: sin(0.5), c: -sin(0.5), d: cos(0.5), tx: 60, ty: 80), clip: nil, opacity: 1),
            .image(asset, transform: VectorTransform(a: 30, b: 0, c: 0, d: 30, tx: 112, ty: 5)),
        ])])
        guard let written = try? XPSWriter.write(doc, options: VectorWriteOptions()), let back = try? XPSReader.read(data: written.data),
              let a = Bitmap(render(doc)), let b = Bitmap(render(back.document)) else { check(false, "xps round trip"); return }
        save(render(doc), "xps-source"); save(render(back.document), "xps-roundtrip")
        check(back.document.pages[0].size == doc.pages[0].size, "page size \(back.document.pages[0].size)")
        check(a.meanDifference(b) < 2.0, "mean difference \(a.meanDifference(b))")
        check(a.mismatch(b) < 0.03, "mismatching pixels \(a.mismatch(b))")
        check(b.near(30, 105, 255, 0, 0, tolerance: 30) || b.near(35, 100, 255, 0, 0, tolerance: 30), "red fill present")
        check(b.near(100, 125, 255, 255, 255, tolerance: 6), "even-odd hole stays empty")
    }))

    SelfTest.cases.append(("XPSKit.handWritten", {
        let png = png(255, 128, 0)
        let page = """
        <FixedPage.Resources><ResourceDictionary><SolidColorBrush x:Key="b" Color="#FF0000FF"/><PathGeometry x:Key="g" Figures="M 100,10 L 140,10 140,50 100,50 Z"/></ResourceDictionary></FixedPage.Resources>
        <Path Data="M 10,10 h 40 v 40 h -40 z" Fill="#FFFF0000"/>
        <Path Fill="{StaticResource b}" Data="{StaticResource g}"/>
        <Path Data="F1 M 10,70 A 20,20 0 1 1 50,70 A 20,20 0 1 1 10,70 Z" Fill="sc#1,0,1,0"/>
        <Path Data="M 70,60 L 130,60 130,100 70,100 Z" Stroke="#FF000000" StrokeThickness="4" StrokeDashArray="3 1" StrokeLineJoin="Round"><Path.Fill>
          <LinearGradientBrush MappingMode="RelativeToBoundingBox" StartPoint="0,0" EndPoint="1,0"><LinearGradientBrush.GradientStops><GradientStop Color="#FFFF0000" Offset="0"/><GradientStop Color="#FF0000FF" Offset="1"/></LinearGradientBrush.GradientStops></LinearGradientBrush></Path.Fill></Path>
        <Canvas RenderTransform="0,1,-1,0,190,110" Opacity="1"><Path Data="M 0,0 L 40,0 L 40,20 L 0,20 Z" Fill="#FF00AAAA"/></Canvas>
        <Path Data="M 10,120 L 60,120 60,170 10,170 Z"><Path.Fill><ImageBrush ImageSource="/Resources/o.png" Viewbox="0,0,4,4" Viewport="10,120,50,50" ViewboxUnits="Absolute" ViewportUnits="Absolute"/></Path.Fill></Path>
        <Path Data="M 80,120 L 120,120 120,160 80,160 Z" Fill="#FF123456" Clip="M 80,120 L 100,120 100,160 80,160 Z" NavigateUri="http://example.com"/>
        <Glyphs UnicodeString="Hi" FontUri="/Resources/Fonts/Missing.ttf" FontRenderingEmSize="30" OriginX="130" OriginY="150" Fill="#FF000000"/>
        """
        guard let result = try? XPSReader.read(data: handPackage(page, extra: [("Resources/o.png", png)])), let bmp = Bitmap(render(result.document)) else { check(false, "hand written parse"); return }
        save(render(result.document), "xps-hand")
        check(result.document.pages[0].size == VectorSize(width: 150, height: 150), "size in points")
        check(bmp.near(30, 30, 255, 0, 0), "relative path fill")
        check(bmp.near(120, 30, 0, 0, 255), "resource brush and geometry")
        check(bmp.near(30, 70, 0, 255, 0, tolerance: 20), "arcs and scRGB colour")
        check(bmp.at(75, 80).r > 230 && bmp.at(125, 80).b > 230 || bmp.at(80, 80).r > 200, "relative gradient runs across the bounding box")
        check(bmp.near(180, 130, 0, 170, 170), "canvas rotation")
        check(bmp.near(35, 145, 255, 128, 0), "image brush")
        check(bmp.near(90, 140, 0x12, 0x34, 0x56) && bmp.near(110, 140, 255, 255, 255), "clip")
        check(result.lossNotes.contains { $0.kind == .hyperlinksDropped }, "links reported")
        var textRuns = 0
        func walk(_ nodes: [VectorNode]) { for n in nodes { if case .text(let r) = n { textRuns += 1; check(r.text == "Hi" && r.fontName == "Missing", "text run kept with font name") }; if case .group(let k, _, _, _) = n { walk(k) } } }
        walk(result.document.pages[0].nodes)
        check(textRuns == 1, "glyphs without a font program stay text")
    }))

    SelfTest.cases.append(("XPSKit.fonts", {
        guard let ttf = try? Data(contentsOf: arialURL) else { return }
        // A hand-made obfuscated font part: XOR of the first 32 bytes with the reversed GUID bytes.
        let guid = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"
        let hex = guid.replacingOccurrences(of: "-", with: "")
        var key: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); key.append(UInt8(hex[i..<j], radix: 16)!); i = j }
        key.reverse()
        var obfuscated = ttf
        for k in 0..<32 { obfuscated[k] ^= key[k % 16] }
        let part = "Resources/Fonts/\(guid).odttf"
        let page = "<Glyphs UnicodeString=\"HHH\" FontUri=\"/\(part)\" FontRenderingEmSize=\"60\" OriginX=\"10\" OriginY=\"80\" Fill=\"#FF000000\"/>"
        guard let result = try? XPSReader.read(data: handPackage(page, extra: [(part, obfuscated)])), let bmp = Bitmap(render(result.document)) else { check(false, "font parse"); return }
        save(render(result.document), "xps-font")
        var dark = 0
        for y in 30..<85 { for x in 10..<130 where bmp.at(x, y).r < 100 { dark += 1 } }
        check(dark > 600, "embedded obfuscated font drawn (\(dark) dark pixels)")
        // The program maps "HHH" itself and the run has no explicit positions: it stays text, in that program (quality §6).
        var runs: [VectorTextRun] = []
        func walk(_ nodes: [VectorNode]) { for n in nodes { if case .text(let r) = n { runs.append(r) }; if case .group(let k, _, _, _) = n { walk(k) } } }
        walk(result.document.pages[0].nodes)
        check(runs.count == 1 && runs[0].text == "HHH" && runs[0].fontData != nil && !result.lossNotes.contains { $0.kind == .textAsOutlines }, "text stays text in the embedded font")
        // Glyph indices the character map doesn't give (here: a shifted glyph) can only be drawn as outlines.
        let shifted = page.replacingOccurrences(of: "Fill=", with: "Indices=\";;,,10\" Fill=")
        let moved = try? XPSReader.read(data: handPackage(shifted, extra: [(part, obfuscated)]))
        check(moved?.lossNotes.contains { $0.kind == .textAsOutlines } == true, "positioned glyphs become outlines, reported")
        // Writer: a run carrying its font program travels as an obfuscated part and comes back drawn the same.
        let doc = VectorDocument(pages: [VectorPage(size: VectorSize(width: 150, height: 75), nodes: [
            .text(VectorTextRun(text: "HHH", fontName: "ArialMT", size: 45, origin: VectorPoint(7.5, 15), fill: .solid(.black), fontData: ttf))])])
        guard let written = try? XPSWriter.write(doc, options: VectorWriteOptions()), let back = try? XPSReader.read(data: written.data), let b2 = Bitmap(render(back.document)) else { check(false, "font write"); return }
        var dark2 = 0
        for y in 0..<100 { for x in 0..<200 where b2.at(x, y).r < 100 { dark2 += 1 } }
        check(abs(dark2 - dark) < dark / 4, "written font draws like the hand-made one (\(dark2) vs \(dark))")
        check(written.data.range(of: ttf.prefix(32)) == nil, "the font program is obfuscated in the package")
        // Outlines requested: no font part, no loss of drawing.
        let outlined = try? XPSWriter.write(doc, options: VectorWriteOptions(textAsOutlines: true))
        check(outlined?.lossNotes.contains { $0.kind == .textAsOutlines } == true, "text as outlines is reported")
    }))

    SelfTest.cases.append(("XPSKit.packages", {
        let page = "<Path Data=\"M 0,0 L 100,0 100,100 0,100 Z\" Fill=\"#FF00FF00\"/>"
        // OpenXPS relationship type and a DWFx-style package name.
        let open = relsXML.replacingOccurrences(of: "http://schemas.microsoft.com/xps/2005/06/fixedrepresentation", with: "http://schemas.openxps.org/oxps/v1.0/fixedrepresentation")
        for (label, rels) in [("xps", relsXML), ("openxps", open), ("no relationships", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"/>")] {
            guard let r = try? XPSReader.read(data: handPackage(page, rels: rels)), let bmp = Bitmap(render(r.document)) else { check(false, "\(label) package reads"); continue }
            check(bmp.near(40, 40, 0, 255, 0) && bmp.near(150, 150, 255, 255, 255), "\(label) content")
        }
        let dir = scratch.appendingPathComponent("xps-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("drawing.dwfx")
        try? handPackage(page).write(to: file)
        check((try? XPSReader.read(file))?.document.pages.count == 1, "a .dwfx file reads like XPS")
        // Two pages in order, through the converters, with a page range on the way out.
        let two = VectorDocument(pages: [VectorPage(size: VectorSize(width: 75, height: 75), nodes: [.path(PathBuilder.rect(x: 0, y: 0, width: 75, height: 75), fill: .solid(VectorColour(red: 1, green: 0, blue: 0)), stroke: nil)]),
                                         VectorPage(size: VectorSize(width: 90, height: 60), nodes: [.path(PathBuilder.rect(x: 0, y: 0, width: 90, height: 60), fill: .solid(VectorColour(red: 0, green: 0, blue: 1)), stroke: nil)])])
        guard let both = try? XPSWriter.write(two, options: VectorWriteOptions()), let back = try? XPSReader.read(data: both.data) else { check(false, "two pages"); return }
        check(back.document.pages.map(\.size) == two.pages.map(\.size), "page sizes and order survive")
        MainActor.assumeIsolated {
            XPSKitModule.install()
            let source = dir.appendingPathComponent("two.xps")
            let context = StepContext(workFolder: dir, source: source, sourceFormat: "xps", targetFormat: "xps", options: OptionValues(["pages": "2"]), isFinalStep: true)
            guard let writer = Services.converters.converter(for: .xpsWriter), let reader = Services.converters.converter(for: .xpsKit) else { check(false, "converters"); return }
            check(writer.handles(Step(.xpsWriter, .vectorDocument, "xps")) && reader.handles(Step(.xpsKit, "xps", .vectorDocument)), "converters handle their steps")
            if case .success(let out)? = complete(30, { try await writer.run(Step(.xpsWriter, .vectorDocument, "xps"), input: .vector(two), context: context) }), case .file(let url) = out.value {
                check((try? XPSReader.read(url))?.document.pages.count == 1, "page range written")
            } else { check(false, "writer step ran") }
            if case .success(let out)? = complete(30, { try await reader.run(Step(.xpsKit, "xps", .vectorDocument), input: .file(file.deletingLastPathComponent().appendingPathComponent("drawing.dwfx")), context: context) }), case .vector(let doc) = out.value {
                check(doc.pages.count == 1, "reader step ran")
            } else { check(false, "reader step ran") }
        }
        try? FileManager.default.removeItem(at: dir)
    }))

    SelfTest.cases.append(("XPSKit.damaged", {
        let good = handPackage("<Path Data=\"M 0,0 L 10,0 10,10 Z\" Fill=\"#FF000000\"/>")
        check((try? XPSReader.read(data: Data())) == nil, "empty rejected")
        check((try? XPSReader.read(data: Data("PK garbage that is not a package at all".utf8))) == nil, "garbage rejected")
        for cut in [10, good.count / 2, good.count - 30] { check((try? XPSReader.read(data: good.prefix(cut))) == nil, "truncated at \(cut) rejected") }
        var flipped = good
        for k in stride(from: 40, to: min(flipped.count, 400), by: 7) { flipped[k] ^= 0xFF }
        _ = try? XPSReader.read(data: flipped)
        // A declared size of 1 GB is refused before anything is inflated; a lying small size fails the length check.
        let bomb = makeZip([("Documents/1/Pages/1.fpage", Data(repeating: 0x20, count: 4096))], declaredSize: { _ in 1 << 30 })
        check((try? XPSReader.read(data: bomb)) == nil, "oversized declared entry rejected")
        let lying = makeZip([("Documents/1/Pages/1.fpage", Data(repeating: 0x20, count: 4096))], declaredSize: { _ in 16 })
        check((try? XPSReader.read(data: lying)) == nil, "size mismatch rejected")
        var deep = "<Path Data=\"M 0,0 L 1,1\" Fill=\"#FF000000\"/>"
        for _ in 0..<300 { deep = "<Canvas>\(deep)</Canvas>" }
        _ = try? XPSReader.read(data: handPackage(deep))
        let junk = handPackage("<Path Data=\"M 1,2 L oops C\" Stroke=\"nonsense\"/><Glyphs UnicodeString=\"x\"/><Path Data=\"F1\"/>")
        check((try? XPSReader.read(data: junk)) != nil, "bad values are skipped, not fatal")
    }))
}
