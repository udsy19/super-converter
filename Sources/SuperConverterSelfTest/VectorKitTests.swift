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
}
