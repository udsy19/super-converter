import AppKit
import ConvertKit
import SuperConverterCore
import VectorizeKit
import VectorKit
import XPSKit

// VectorKit's checks (WP-V): SVG, PDF, PostScript, CGM, SK/SK1 and AI on generated fixtures, compared by rendered pixels.
// Renders of a few cases are saved under $SUPERCONVERTER_SELFTEST_RENDERS when set, so they can be looked at.

struct SVTPixel { var r: Int, g: Int, b: Int, a: Int }

/// A raster copy of a CGImage as straight RGBA bytes.
struct SVTBitmap {
    let width: Int, height: Int
    var bytes: [UInt8]

    init?(_ image: CGImage?) {
        guard let image else { return nil }
        width = image.width; height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        if !ok { return nil }
    }

    /// Pixel at (x, y) counted from the top-left.
    func at(_ x: Int, _ y: Int) -> SVTPixel {
        let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
        return SVTPixel(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]), a: Int(bytes[i + 3]))
    }

    func near(_ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int, tolerance: Int = 12) -> Bool {
        let p = at(x, y)
        return abs(p.r - r) <= tolerance && abs(p.g - g) <= tolerance && abs(p.b - b) <= tolerance
    }

    /// Mean absolute difference per channel (0...255) against a bitmap of the same size.
    func meanDifference(_ other: SVTBitmap) -> Double {
        guard width == other.width, height == other.height else { return 255 }
        var total = 0
        for i in 0..<bytes.count { total += abs(Int(bytes[i]) - Int(other.bytes[i])) }
        return Double(total) / Double(bytes.count)
    }

    /// Fraction of pixels whose largest channel difference exceeds `threshold`.
    func mismatch(_ other: SVTBitmap, threshold: Int = 40) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        var bad = 0
        for p in 0..<(width * height) {
            var worst = 0
            for c in 0..<3 { worst = max(worst, abs(Int(bytes[p * 4 + c]) - Int(other.bytes[p * 4 + c]))) }
            if worst > threshold { bad += 1 }
        }
        return Double(bad) / Double(width * height)
    }
}

func svtSave(_ image: CGImage?, _ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["SUPERCONVERTER_SELFTEST_RENDERS"], let image else { return }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
}

/// Renders page 0 of a document so that one SVG px is one image pixel (the model is in points).
func svtRender(_ doc: VectorDocument, pxPerPoint: Double = 4.0 / 3.0) -> SVTBitmap? {
    guard let page = doc.pages.first else { return nil }
    return SVTBitmap(VectorDrawing.render(page, scale: pxPerPoint))
}

func svtSVG(_ body: String, size: Int = 100) -> Data {
    Data("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"\(size)\" height=\"\(size)\" viewBox=\"0 0 \(size) \(size)\">\(body)</svg>".utf8)
}

/// Runs one converter step in a fresh work folder.
@MainActor func svtRun(_ step: Step, _ input: StepValue, source: String = "drawing", options: [String: String] = [:]) -> StepOutput? {
    guard let converter = Services.converters.converter(for: step.engine), converter.handles(step) else { return nil }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("svt-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ext: String = if case .format(let f) = step.from { f.rawValue } else { "bin" }
    let target: FormatID = if case .format(let f) = step.to { f } else { "bin" }
    let context = StepContext(workFolder: dir, source: dir.appendingPathComponent("\(source).\(ext)"), sourceFormat: FormatID(ext),
                              targetFormat: target, options: OptionValues(options.mapValues { .string($0) }), isFinalStep: true)
    if case .success(let out)? = complete(60, { try await converter.run(step, input: input, context: context) }) { return out }
    return nil
}

func registerVectorKitTests() {
    registerVectorKitMetafileTests()
    registerVectorKitSVGTests()
    registerVectorKitPDFTests()
    registerVectorKitPSTests()

    SelfTest.cases.append(("VectorKit.coverage", {
        VectorKitModule.install(); XPSKitModule.install(); VectorizeKitModule.install()
        let modules: Set<ModuleID> = [.vectorKit, .xpsKit, .vectorizeKit]
        let mine = Set(EngineID.allCases.filter { modules.contains($0.info.module) })
        let report = Coverage.verify(Services.converters.converters)
        let missing = report.missingEngines.filter(mine.contains), unused = report.unusedConverters.filter(mine.contains)
        let unhandled = report.unhandledSteps.filter { mine.contains($0.engine) }
        check(missing.isEmpty, "every WP-V engine registers: missing \(missing)")
        check(unused.isEmpty, "no WP-V converter is unused: \(unused)")
        check(unhandled.isEmpty, "every WP-V step is handled: \(unhandled.prefix(5))")
    }))

    SelfTest.cases.append(("VectorKit.pdfConverter", {
        VectorKitModule.install()
        let red = VectorColour(red: 1, green: 0, blue: 0)
        let pages = (1...3).map { i in VectorPage(size: VectorSize(width: 100 * Double(i), height: 80), nodes: [.path(PathBuilder.rect(x: 10, y: 10, width: 20, height: 20), fill: .solid(red), stroke: nil)]) }
        func pdf(_ out: StepOutput?) -> CGPDFDocument? { if case .file(let url)? = out?.value { CGPDFDocument(url as CFURL) } else { nil } }
        let picked = pdf(svtRun(Step(.cgPDF, .vectorDocument, "pdf"), .vector(VectorDocument(pages: pages)), options: ["pages": "2-3"]))
        check(picked?.numberOfPages == 2 && picked?.page(at: 1)?.getBoxRect(.mediaBox).width == 200, "drawing → PDF keeps the chosen pages")
        var px = Data()
        for _ in 0..<(40 * 20) { px.append(contentsOf: [0, 0, 255, 255]) }
        let asset = ImageAsset(frames: [ImageFrame(width: 40, height: 20, pixels: .rgba8(px, bytesPerRow: 160), hasAlpha: false)])
        let picture = pdf(svtRun(Step(.cgPDF, .imageAsset, "pdf"), .image(asset), options: ["pageSize": "a4"]))
        check(picture?.numberOfPages == 1 && abs((picture?.page(at: 1)?.getBoxRect(.mediaBox).height ?? 0) - 595.276) < 0.5, "picture → A4 landscape page")
        let png = ImageBridge.pngData(asset)!
        let book = Publication(layout: .fixed, spine: [PublicationItem(id: "p1", content: .page(resource: "i1")), PublicationItem(id: "p2", content: .page(resource: "i1"))],
                               resources: ["i1": PublicationResource(mediaType: "image/png", data: png)])
        let comic = pdf(svtRun(Step(.cgPDF, .publication, "pdf"), .publication(book)))
        check(comic?.numberOfPages == 2 && comic?.page(at: 1)?.getBoxRect(.mediaBox).width == 30, "comic → one PDF page per picture")
    }))

    SelfTest.cases.append(("VectorKit.skencil", {
        let sk = """
        ##Sketch 1 2
        document()
        layout('A4',0)
        layer('Layer 1',1,1,0,0,(0,0,0))
        fp((1,0,0))
        le()
        r(100,0,0,50,50,700)
        lp((0,0,1))
        lw(4)
        lc(2)
        b()
        bs(50,600,0)
        bs(250,600,0)
        bc(300,600,300,500,250,500,0)
        bs(50,500,0)
        bC()
        G()
        fp((0,0.5,0))
        le()
        e(30,0,0,30,400,600)
        G_()
        Fn('Helvetica')
        Fs(24)
        fp((0,0,0))
        txt('Caf\\xe9',(1,0,0,1,50,400))
        layer('Hidden',0,1,0,0,(0,0,0))
        fp((1,1,0))
        r(595,0,0,842,0,0)
        """
        guard let result = try? SKReader.read(Data(sk.utf8), dialect: .skencil) else { check(false, "the Skencil file reads"); return }
        let page = result.document.pages[0]
        check(abs(page.size.width - 595.276) < 0.01 && abs(page.size.height - 841.89) < 0.01, "A4 page")
        var texts: [String] = []
        func walk(_ nodes: [VectorNode]) { for n in nodes { if case .text(let run) = n { texts.append(run.text) }; if case .group(let c, _, _, _) = n { walk(c) } } }
        walk(page.nodes)
        check(texts == ["Café"], "text with a Latin-1 escape: \(texts)")
        guard let bitmap = svtRender(result.document, pxPerPoint: 1) else { check(false, "renders"); return }
        let h = bitmap.height
        check(bitmap.near(100, h - 725, 255, 0, 0), "red rectangle from the unit-square transform")
        check(bitmap.near(400, h - 600, 0, 128, 0), "green circle inside a group")
        check(bitmap.near(150, h - 600, 0, 0, 255, tolerance: 30), "blue stroke along the Bézier")
        check(bitmap.near(500, h - 100, 255, 255, 255), "the hidden layer isn’t drawn")
        check((try? SKReader.read(Data("not a drawing".utf8), dialect: .skencil)) == nil, "a file without the header is refused")
    }))

    SelfTest.cases.append(("VectorKit.sk1", {
        let sk1 = """
        ##sK1 1 2
        document()
        layout((200,100),0)
        layer('Layer 1',1,1,0,0,("RGB",0.0,0.0,0.0))
        fp(["CMYK",[0.0,1.0,1.0,0.0],1.0,"Red"])
        lp(("RGB",0.0,0.0,1.0))
        lw(2)
        ld((2,1))
        r(80,0,0,80,10,10)
        gl([(0,["RGB",[1.0,1.0,1.0],1.0,""]),(1,["RGB",[0.0,0.0,0.0],1.0,""])])
        pgl(-1,0,0)
        le()
        r(80,0,0,80,110,10,0.25,0.25)
        """
        guard let result = try? SKReader.read(Data(sk1.utf8), dialect: .sk1) else { check(false, "the sK1 file reads"); return }
        check(result.document.pages[0].size == VectorSize(width: 200, height: 100), "page size from a tuple")
        var dashes: [[Double]] = []
        for case .path(_, _, let s?, _) in result.document.pages[0].nodes { dashes.append(s.dash) }
        check(dashes == [[4, 2]], "dashes scale with the line width: \(dashes)")
        guard let bitmap = svtRender(result.document, pxPerPoint: 1) else { check(false, "renders"); return }
        check(bitmap.near(50, 50, 255, 0, 0), "CMYK red fill")
        let left = bitmap.at(118, 50), right = bitmap.at(182, 50)
        check(left.r > 200 && right.r < 60, "linear gradient runs white → black left to right: \(left.r) \(right.r)")
        check(bitmap.near(189, 89, 255, 255, 255) && bitmap.at(180, 80).r < 80, "rounded corner left empty")
    }))

    SelfTest.cases.append(("VectorKit.damagedInputNeverCrashes", {
        VectorKitModule.install()
        let readers: [String: EngineID] = ["pdf": .vectorKit, "ai": .aiReader, "svg": .svgReader, "svgz": .svgReader, "emf": .emfReader,
                                           "wmf": .wmfReader, "sk": .skencilReader, "sk1": .sk1Reader]
        let nesting: [String: [String]] = ["pdf": ["[", "<<", "q "], "ai": ["[", "<<"], "svg": ["<g>", "<svg>"], "sk": ["(", "[", "G()\n"], "sk1": ["(", "[", "G()\n"]]
        let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/Corpus/generated", isDirectory: true)
        var seeds: [FuzzSeed] = readers.keys.sorted().compactMap { ext in
            (try? Data(contentsOf: corpus.appendingPathComponent("sample.\(ext)"))).map { FuzzSeed(name: ext, ext: ext, bytes: [UInt8]($0), nesting: nesting[ext] ?? []) }
        }
        check(seeds.count == readers.count, "every corpus sample is there (\(seeds.count))")
        seeds += svtMetafileFuzzSeeds()
        // What the corpus samples don't reach: CSS, every paint server, masks, markers, nested viewports, `use`, text and
        // pictures in SVG; images, functions (sampled, calculator, stitching), patterns and fonts in PDF; groups, masks,
        // arcs and pictures in Skencil.
        let png = ImageBridgeFixture.redPNGBase64
        let svg = svtSVG("""
        <style>.a { fill: #0f0 } g > rect + rect { stroke: red } @media print { rect { fill: blue } } rect:first-child { opacity: 0.5 }</style>
        <defs>
          <linearGradient id="lg" x1="0" x2="0.2" spreadMethod="reflect" gradientTransform="rotate(20)"><stop offset="0" stop-color="red"/><stop offset="1" stop-color="hsl(120, 50%, 50%)"/></linearGradient>
          <radialGradient id="rg" href="#lg" r="0.3" fx="0.2" spreadMethod="repeat"/>
          <pattern id="p" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="skewX(10)"><rect width="4" height="4" fill="#f00"/></pattern>
          <clipPath id="cp" clipPathUnits="objectBoundingBox"><circle cx="0.5" cy="0.5" r="0.5"/></clipPath>
          <mask id="mk"><rect width="100" height="100" fill="url(#lg)"/></mask>
          <marker id="m" markerWidth="4" markerHeight="4" refX="2" refY="2" orient="auto"><path d="M0 0 L4 2 L0 4 z"/></marker>
          <symbol id="s" viewBox="0 0 10 10"><use href="#u"/></symbol>
          <g id="u"><rect class="a" width="10" height="10" rx="2"/><rect x="2" y="2" width="4" height="4"/></g>
          <path id="tp" d="M10 90 Q50 60 90 90"/>
        </defs>
        <g transform="translate(5,5) rotate(10 50 50) scale(0.9)" opacity="0.8">
          <rect x="0" y="0" width="40" height="30" fill="url(#lg)" stroke="url(#rg)" stroke-dasharray="4 2" clip-path="url(#cp)"/>
          <ellipse cx="70" cy="20" rx="20" ry="10" fill="url(#p)" mask="url(#mk)"/>
          <polyline points="5,50 30,60 50,45 70,70" fill="none" stroke="#000" marker-start="url(#m)" marker-mid="url(#m)" marker-end="url(#m)"/>
          <path d="M60 50 a15 10 30 1 0 20 10 S 90 80 70 90 T 50 95 Z" fill="rgba(0,0,255,0.5)" fill-rule="evenodd"/>
          <use href="#s" x="80" y="40" width="15" height="15"/>
          <svg x="0" y="70" width="30" height="30" viewBox="0 0 10 10" preserveAspectRatio="xMaxYMin slice"><circle cx="5" cy="5" r="6" fill="orange"/></svg>
          <text x="5" y="68" font-size="10" font-family="Helvetica" letter-spacing="1" text-anchor="middle">A<tspan dx="2 1" dy="-3" font-weight="bold">bc</tspan><textPath href="#tp">along</textPath></text>
          <image x="40" y="60" width="20" height="10" href="data:image/png;base64,\(png)" preserveAspectRatio="none"/>
          <switch><rect systemLanguage="fr" width="5" height="5"/><circle cx="95" cy="95" r="3"/></switch>
        </g>
        """)
        seeds.append(FuzzSeed(name: "svg-features", ext: "svg", bytes: [UInt8](svg), nesting: ["<g>", "<svg>", "<use href=\"#u\"/>"]))
        let pdf = svtSinglePagePDF(
            content: """
            q 0 0 50 50 re W n /Sh1 sh Q /Sh2 sh /Sh3 sh
            q 20 0 0 20 5 5 cm /Im1 Do Q q 20 0 0 20 30 5 cm /Im2 Do Q q 1 0 0 1 50 0 cm /Fm1 Do Q
            /Pattern cs /P1 scn 0 50 50 50 re f
            BT /F1 12 Tf 2 Tr 1 0 0 1 10 80 Tm 0.5 Tc 2 Tw 90 Tz 12 TL (Hi) Tj [(A) -120 (B)] TJ T* (C) ' 1 2 (D) " ET
            /CS1 cs 0.5 sc 60 60 20 20 re f /CS2 CS 1 SCN 1 J 2 j 4 M [3 1] 0 d 60 60 m 90 90 l 95 60 80 50 70 55 c S
            """,
            resources: "/Shading << /Sh1 5 0 R /Sh2 12 0 R /Sh3 13 0 R >> /XObject << /Im1 6 0 R /Im2 7 0 R /Fm1 8 0 R >> /Pattern << /P1 9 0 R >> " +
                "/Font << /F1 10 0 R >> /ColorSpace << /CS1 [/Separation /Spot /DeviceRGB 14 0 R] /CS2 [/Indexed /DeviceRGB 1 <ff000000ff00>] >>",
            extra: [
                "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 50 0] /Function 11 0 R /Extend [true true] >>",
                "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask 15 0 R /Decode [1 0 0 1 0 1]",
                "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace [/Indexed /DeviceRGB 1 <0000ffffff00>] /BitsPerComponent 1 /Mask [0 0]",
                "/Type /XObject /Subtype /Form /BBox [0 0 50 50] /Matrix [1 0 0 1 0 0] /Group << /S /Transparency >> /Resources << >>",
                "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 10 /YStep 10 /Resources << >>",
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar 65 /LastChar 68 /Widths [600 600 600 600] /Encoding << /Differences [65 /B /A] >> /ToUnicode 16 0 R >>",
                "/FunctionType 0 /Domain [0 1] /Range [0 1 0 1 0 1] /Size [2] /BitsPerSample 8",
                "<< /ShadingType 3 /ColorSpace /DeviceGray /Coords [50 50 0 50 50 40] /Function << /FunctionType 3 /Domain [0 1] /Functions [<< /FunctionType 2 /Domain [0 1] /C0 [0] /C1 [1] /N 2 >> << /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>] /Bounds [0.5] /Encode [0 1 0 1] >> >>",
                "<< /ShadingType 4 /ColorSpace /DeviceRGB /Background [0 1 0] >>",
                "/FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1]",
                "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8",
                "/Length1 0",
            ],
            extraStreams: [6: "\u{00}\u{00}\u{ff}\u{ff}\u{00}\u{00}\u{00}\u{ff}\u{00}\u{ff}\u{ff}\u{ff}", 7: "\u{40}\u{80}",
                           8: "0 1 0 rg 5 5 40 40 re f", 9: "1 0.5 0 rg 0 0 5 5 re f", 11: "\u{00}\u{ff}\u{80}\u{ff}\u{00}\u{40}",
                           14: "{ dup 0.5 mul exch 1 exch sub 2 copy add 3 1 roll }", 15: "\u{ff}\u{80}\u{40}\u{00}",
                           16: "/CIDInit /ProcSet findresource begin 1 begincodespacerange <00> <ff> endcodespacerange 2 beginbfchar <41> <0042> <42> <0041> endbfchar 1 beginbfrange <43> <44> <0063> endbfrange endcmap"])
        seeds.append(FuzzSeed(name: "pdf-features", ext: "pdf", bytes: [UInt8](pdf), nesting: ["[", "<<", "q ", "{ "]))
        let sk = """
        ##Sketch 1 2
        document()
        layout('letter',1)
        layer('Layer 1',1,1,0,0,(0,0,0))
        bm(1)
        \(png)
        -
        im((20,0,0,20,10,10),1)
        G()
        M()
        b()
        bs(0,0,0)
        bs(100,0,0)
        bs(50,80,0)
        bC()
        fp((0,0.5,0))
        e(30,0,0,30,50,40,0.5,2.5,2)
        e(30,0,0,30,50,40,0,3,1)
        M_()
        B()
        fp((1,0,0))
        r(20,0,0,20,200,200,0.3,0.3)
        B_()
        G_()
        lc(3)
        lj(2)
        ld((4,1,1,1))
        la1(None)
        gl([(0,(1,1,1)),(0.5,(0,0,1)),(1,(0,0,0))])
        pgr(0.3,0.7)
        r(50,0,0,50,300,300)
        dstyle('s')
        ds('s')
        Fn('Helvetica-Bold')
        Fs(18)
        txt('tab\\there \\u00e9\\101',(0.9,0.1,-0.1,0.9,100,500),1,2)
        phs((1,0,0),(0,0,1),0,1,10,0)
        guidelayer('Guides',1,0,0,1,(0,0,1))
        """
        seeds.append(FuzzSeed(name: "sk-features", ext: "sk", bytes: Array(sk.utf8), nesting: ["(", "[", "G()\n", "M()\n"]))

        let dir = scratch.appendingPathComponent("vectorkit-fuzz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        @MainActor func read(_ url: URL, _ ext: String) async throws -> StepOutput? {
            let format = FormatID(ext)
            guard let id = readers[ext], let converter = Services.converters.converter(for: id) else { return nil }
            let context = StepContext(workFolder: dir, source: url, sourceFormat: format, targetFormat: "pdf")
            return try await converter.run(Step(id, .format(format), .vectorDocument), input: .file(url), context: context)
        }
        let ran = fuzzNeverCrashes("VectorKit.damagedInputNeverCrashes", seeds: seeds, count: 130) { url, seed in _ = try await read(url, seed.ext) }
        check(ran == seeds.count * 130, "every damaged input was handled without a crash (\(ran))")

        // One hostile file per bug found: each trapped, recursed without bound, allocated far more than its bytes or ran
        // for minutes before its fix. Read once each; finishing is the check.
        let huge = "1000000000000000000000000000000"
        let calculator = "/FunctionType 4 /Domain [0 1] /Range [0 1 0 1 0 1]"
        var hostile = svtHostileMetafiles()
        hostile += [
            ("pdf-function-sizes", "pdf", svtSinglePagePDF(content: "/Sh1 sh /Sh2 sh /Sh3 sh /Sh4 sh", resources: "/Shading << /Sh1 5 0 R /Sh2 6 0 R /Sh3 7 0 R /Sh4 8 0 R >>", extra: [
                "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 50 0] /Function 9 0 R >>",
                "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 50 0] /Function 10 0 R >>",
                "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 50 0] /Function 11 0 R >>",
                "<< /ShadingType 2 /ColorSpace /DeviceGray /Coords [0 0 50 0] /Domain [0] /Function << /FunctionType 2 /Domain [0] /C0 [0] /C1 [1] /N 1 >> >>",
                "/FunctionType 0 /Domain [0 1] /Range [0 1 0 1 0 1] /Size [\(huge)] /BitsPerSample 8",
                "<< /FunctionType 3 /Domain [0 1] /Functions [10 0 R] /Encode [0 1] >>",
                calculator,
            ], extraStreams: [9: "abc", 11: "{ 1 " + (0..<31).map { "\(1 << $0) copy " }.joined() + "}"])),
            ("pdf-deep-calculator", "pdf", svtSinglePagePDF(content: "/Sh1 sh", resources: "/Shading << /Sh1 5 0 R >>", extra: [
                "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 50 0] /Function 6 0 R >>", calculator,
            ], extraStreams: [6: String(repeating: "{ ", count: 100_000)])),
            ("pdf-image-sizes", "pdf", svtSinglePagePDF(content: "q 10 0 0 10 0 0 cm /Im1 Do /Im2 Do Q", resources: "/XObject << /Im1 5 0 R /Im2 6 0 R >>", extra: [
                "/Type /XObject /Subtype /Image /Width 60000 /Height 1000 /ColorSpace /DeviceRGB /BitsPerComponent 8",
                "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /SMask 7 0 R",
                "/Type /XObject /Subtype /Image /Width 4294967296 /Height 4294967296 /ColorSpace /DeviceGray /BitsPerComponent 8",
            ], extraStreams: [5: "abcd", 6: "abcd", 7: "abcd"])),
            ("pdf-tiny-tiles", "pdf", svtSinglePagePDF(content: "/Pattern cs /P1 scn 0 0 100 100 re f", resources: "/Pattern << /P1 5 0 R >>", extra: [
                "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 10 10] /XStep 0.000000000000000000000000000001 /YStep 1 /Resources << >>",
            ], extraStreams: [5: "0 0 5 5 re f"])),
            ("pdf-huge-operands", "pdf", svtSinglePagePDF(
                content: "\(huge) Tr /CS1 cs \(huge) sc 0 0 10 10 re f BT /F1 12 Tf (AB) Tj /F2 12 Tf <00410042> Tj ET",
                resources: "/ColorSpace << /CS1 [/Indexed /DeviceRGB 1 <ff000000ff00>] >> /Font << /F1 5 0 R /F2 6 0 R >>", extra: [
                    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /FirstChar \(huge) /Widths [500] /Encoding << /Differences [\(huge) /A /B] >> >>",
                    "<< /Type /Font /Subtype /Type0 /BaseFont /Helvetica /Encoding /Identity-H /DescendantFonts [<< /Type /Font /Subtype /CIDFontType2 /BaseFont /Helvetica /W [\(huge) [500] 0 \(huge) 500] >>] >>",
                ])),
            ("pdf-unclosed-clips", "pdf", svtSinglePagePDF(content: String(repeating: "0 0 100 100 re W n ", count: 50_000) + "0 0 1 rg 0 0 50 50 re f")),
            ("sk-deep-tuple", "sk", Data(("##Sketch 1 2\nfp(" + String(repeating: "(", count: 50_000) + "\n").utf8)),
            ("sk-huge-numbers", "sk", Data("##Sketch 1 2\nlayer('L',1,1,0,0,(0,0,0))\nlc(1e300)\nlj(-1e300)\ne(30,0,0,30,50,40,0,3,1e300)\nim((1,0,0,1,0,0),1e300)\nr(10,0,0,10,0,0)\n".utf8)),
            ("sk-deep-groups", "sk", Data(("##Sketch 1 2\nlayer('L',1,1,0,0,(0,0,0))\n" + String(repeating: "G()\n", count: 50_000) + "r(10,0,0,10,0,0)\n").utf8)),
            ("svg-tiny-pattern", "svg", svtSVG("<defs><pattern id=\"p\" width=\"1e-300\" height=\"1e-300\" patternUnits=\"userSpaceOnUse\"><rect width=\"1\" height=\"1\"/></pattern></defs><rect width=\"100\" height=\"100\" fill=\"url(#p)\"/>")),
            ("svg-open-style", "svg", svtSVG("<style>rect{</style><rect width=\"10\" height=\"10\"/>")),
            ("svg-steep-gradient", "svg", svtSVG("<defs><linearGradient id=\"g\" x2=\"1e-150\" spreadMethod=\"reflect\"><stop offset=\"0\" stop-color=\"red\"/><stop offset=\"1\" stop-color=\"blue\"/></linearGradient></defs><rect width=\"100\" height=\"100\" fill=\"url(#g)\"/>")),
            ("svg-huge-text-path", "svg", svtSVG("<path id=\"tp\" d=\"M0 0 C 1e300 1e300 -1e300 1e300 5 5\"/><text font-size=\"10\"><textPath href=\"#tp\">abc</textPath></text>")),
            ("svg-infinite-size", "svg", Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1e999\" height=\"1e999\"><rect width=\"10\" height=\"10\"/></svg>".utf8)),
            ("svg-deep-nesting", "svg", svtSVG("<defs><clipPath id=\"c\"><rect width=\"90\" height=\"90\"/></clipPath></defs>"
                                                 + String(repeating: "<svg width=\"100\" height=\"100\"><g opacity=\"0.9\" clip-path=\"url(#c)\">", count: 195) + "<rect width=\"10\" height=\"10\"/>"
                                                 + String(repeating: "</g></svg>", count: 195))),
            ("svg-huge-font", "svg", svtSVG("<text x=\"5\" y=\"50\" font-size=\"1e999\" letter-spacing=\"1e308\">Hi</text><text x=\"5\" y=\"50\" font-size=\"1e300\">Hi</text>")),
            ("svg-use-fan-out", "svg", svtSVG("<defs>" + (0..<8).map { level in "<g id=\"l\(level)\">" + String(repeating: "<use href=\"#l\(level + 1)\"/>", count: 10) + "</g>" }.joined()
                                               + "<rect id=\"l8\" width=\"1\" height=\"1\"/></defs><use href=\"#l0\"/>")),
        ]
        for (name, ext, data) in hostile {
            let url = dir.appendingPathComponent("hostile.\(ext)")
            guard (try? data.write(to: url)) != nil else { check(false, "\(name) written"); continue }
            if Fuzz.trace { FileHandle.standardError.write(Data("hostile \(name)\n".utf8)) }
            switch complete(30, { try await read(url, ext) }) {
            case nil: check(false, "\(name) did not finish in 30 s")
            case .success(let out)?:
                // Every page that comes out has a size the steps after a reader can turn into pixels.
                if case .vector(let doc)? = out?.value {
                    check(doc.pages.allSatisfy { $0.size.width.isFinite && $0.size.height.isFinite && max($0.size.width, $0.size.height) <= 1e6 }, "\(name): sane page sizes")
                }
            case .failure?: break
            }
        }
    }))
}
