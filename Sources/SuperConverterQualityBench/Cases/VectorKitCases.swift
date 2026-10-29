import CoreGraphics
import Foundation
import PDFKit
import SuperConverterCore
import VectorKit
import XPSKit

/// VectorKit (quality §6): every reader and writer against an independent renderer where macOS has one (WebKit for SVG,
/// PDFKit for PDF and Illustrator files) and against each other through the vector model. The fixtures are one drawing,
/// 400 × 300 px (300 × 225 pt), compared at 800 × 600 (192 dpi). Thresholds: SSIM ≥ 0.98 for PDF/SVG/EPS-class targets,
/// ≥ 0.95 for EMF/WMF; round trips keep the path count, fill colours within ΔE00 0.5 and stroke widths within 0.01 pt;
/// text stays text (extracted text equals the source).
enum VectorKitCases {
    static let svg = "generated/sample.svg", pdf = "generated/sample-drawing.pdf"

    static let all: [BenchCase] = [
        // SVG → every vector target (the W3C-suite row of quality §6 on the committed drawing; the suite itself is in
        // the external corpus).
        BenchCase(id: "vectorkit.svg-pdf", category: .vector, fixture: svg, target: "pdf", checks: [
            .producesFormat("pdf"), .pdf(pages: 1, text: ["SUPER CONVERTER"]),
            VectorBench.looksLike(.independent, reference: .sourceIndependent, atLeast: 0.98), VectorBench.modelRoundTrip(),
        ]),
        BenchCase(id: "vectorkit.svg-emf", category: .vector, fixture: svg, target: "emf", checks: [
            .producesFormat("emf"), VectorBench.looksLike(.ours, reference: .sourceIndependent, atLeast: 0.95), VectorBench.textKept(),
        ]),
        BenchCase(id: "vectorkit.svg-wmf", category: .vector, fixture: svg, target: "wmf", checks: [
            .producesFormat("wmf"), VectorBench.looksLike(.ours, reference: .sourceIndependent, atLeast: 0.95), VectorBench.textKept(),
        ]),
        BenchCase(id: "vectorkit.svg-eps", category: .vector, fixture: svg, target: "eps", checks: [
            .producesFormat("eps"), VectorBench.postScript(eps: true, boundingBox: [0, 0, 300, 225], type42: true),
        ]),
        BenchCase(id: "vectorkit.svg-ps", category: .vector, fixture: svg, target: "ps", checks: [
            .producesFormat("ps"), VectorBench.postScript(eps: false, boundingBox: [0, 0, 300, 225], type42: true),
        ]),
        BenchCase(id: "vectorkit.svgz-svg", category: .vector, fixture: "generated/sample.svgz", target: "svg", checks: [
            .producesFormat("svg"), .textContains(["SUPER CONVERTER"]),
            VectorBench.looksLike(.independent, reference: .sourceIndependent, atLeast: 0.98), VectorBench.modelRoundTrip(),
        ]),
        // PDF → vector targets.
        BenchCase(id: "vectorkit.pdf-svg", category: .vector, fixture: pdf, target: "svg", checks: [
            .producesFormat("svg"), .textContains(["SUPER CONVERTER"]),
            VectorBench.looksLike(.independent, reference: .sourceIndependent, atLeast: 0.98), VectorBench.modelRoundTrip(),
        ]),
        BenchCase(id: "vectorkit.pdf-eps", category: .vector, fixture: pdf, target: "eps", checks: [
            .producesFormat("eps"), VectorBench.postScript(eps: true, boundingBox: [0, 0, 300, 225], type42: true),
        ]),
        BenchCase(id: "vectorkit.pdf-emf", category: .vector, fixture: pdf, target: "emf", checks: [
            .producesFormat("emf"), VectorBench.looksLike(.ours, reference: .sourceIndependent, atLeast: 0.95), VectorBench.textKept(),
        ]),
        BenchCase(id: "vectorkit.pdf-wmf", category: .vector, fixture: pdf, target: "wmf", checks: [
            .producesFormat("wmf"), VectorBench.looksLike(.ours, reference: .sourceIndependent, atLeast: 0.95), VectorBench.textKept(),
        ]),
        // Metafiles in: the reader's drawing, written by an independent-rendered target, against the reader's own render.
        BenchCase(id: "vectorkit.emf-pdf", category: .vector, fixture: "generated/sample.emf", target: "pdf", checks: [
            .producesFormat("pdf"), .pdf(pages: 1, text: ["SUPER CONVERTER"]), VectorBench.looksLike(.independent, reference: .sourceOurs, atLeast: 0.98),
        ]),
        BenchCase(id: "vectorkit.emf-svg", category: .vector, fixture: "generated/sample.emf", target: "svg", checks: [
            .producesFormat("svg"), .textContains(["SUPER CONVERTER"]), VectorBench.looksLike(.independent, reference: .sourceOurs, atLeast: 0.95),
        ]),
        BenchCase(id: "vectorkit.wmf-pdf", category: .vector, fixture: "generated/sample.wmf", target: "pdf", checks: [
            .producesFormat("pdf"), .pdf(pages: 1, text: ["SUPER CONVERTER"]), VectorBench.looksLike(.independent, reference: .sourceOurs, atLeast: 0.98),
        ]),
        BenchCase(id: "vectorkit.wmf-svg", category: .vector, fixture: "generated/sample.wmf", target: "svg", checks: [
            .producesFormat("svg"), .textContains(["SUPER CONVERTER"]), VectorBench.looksLike(.independent, reference: .sourceOurs, atLeast: 0.95),
        ]),
        // Skencil and sK1 draw the SVG fixture's picture: compared with WebKit's render of it.
        BenchCase(id: "vectorkit.sk-pdf", category: .vector, fixture: "generated/sample.sk", target: "pdf", route: [Step(.skencilReader, "sk", .vectorDocument), Step(.cgPDF, .vectorDocument, "pdf")], checks: [
            .producesFormat("pdf"), .pdf(pages: 1, text: ["SUPER CONVERTER"]), VectorBench.looksLike(.independent, reference: .fixture(svg), atLeast: 0.95),
        ]),
        BenchCase(id: "vectorkit.sk1-svg", category: .vector, fixture: "generated/sample.sk1", target: "svg", route: [Step(.sk1Reader, "sk1", .vectorDocument), Step(.svgWriter, .vectorDocument, "svg")], checks: [
            .producesFormat("svg"), .textContains(["SUPER CONVERTER"]), VectorBench.looksLike(.independent, reference: .fixture(svg), atLeast: 0.95),
        ]),
        // An Illustrator 9+ file is a PDF (the sniffer calls it PDF, so the route is given): against PDFKit's render.
        BenchCase(id: "vectorkit.ai-svg", category: .vector, fixture: "generated/sample.ai", target: "svg", route: [Step(.aiReader, "ai", .vectorDocument), Step(.svgWriter, .vectorDocument, "svg")], checks: [
            .producesFormat("svg"), .textContains(["SUPER CONVERTER"]), VectorBench.looksLike(.independent, reference: .sourceIndependent, atLeast: 0.98),
        ]),
        // CADKit hands VectorKit its plot (DXF → CGM/EPS/WMF) and takes VectorKit's drawings (SVG → DXF).
        BenchCase(id: "vectorkit.dxf-cgm", category: .vector, fixture: "generated/sample.dxf", target: "cgm", checks: [.producesFormat("cgm")]),
        BenchCase(id: "vectorkit.dxf-eps", category: .vector, fixture: "generated/sample.dxf", target: "eps", checks: [
            .producesFormat("eps"), VectorBench.postScript(eps: true, boundingBox: nil, type42: false),
        ]),
        BenchCase(id: "vectorkit.dxf-wmf", category: .vector, fixture: "generated/sample.dxf", target: "wmf", checks: [.producesFormat("wmf")]),
        BenchCase(id: "vectorkit.svg-dxf", category: .vector, fixture: svg, target: "dxf", checks: [.producesFormat("dxf"), .textContains(["LWPOLYLINE", "SUPER CONVERTER"])]),
        // Pictures to PostScript and PDF pages (they need ImageKit's decoder first: skipped until it is built).
        BenchCase(id: "vectorkit.png-eps", category: .vector, fixture: "generated/logo-alpha-128.png", target: "eps", checks: [
            .producesFormat("eps"), VectorBench.postScript(eps: true, boundingBox: [0, 0, 96, 96], type42: false),
        ]),
        BenchCase(id: "vectorkit.png-pdf", category: .vector, fixture: "generated/logo-alpha-128.png", target: "pdf", checks: [.producesFormat("pdf"), .pdf(pages: 1)]),
    ]
}

/// The pictures and models the vector cases compare.
enum VectorBench {
    static let width = 800, height = 600

    /// Which picture of a file a comparison uses.
    enum Side {
        /// The output through an independent renderer (WebKit, PDFKit) when macOS has one for its format, else through
        /// our reader and `VectorDrawing`.
        case independent
        /// The output through our reader and `VectorDrawing`.
        case ours
        /// The source through an independent renderer.
        case sourceIndependent
        /// The source through our reader.
        case sourceOurs
        /// Another fixture (relative to Tests/Corpus) through an independent renderer.
        case fixture(String)
    }

    @MainActor static func raster(_ side: Side, _ ctx: CaseContext) async throws -> Raster {
        switch side {
        case .independent: return try await independent(try output(ctx), work: ctx.work)
        case .ours: return try ours(try output(ctx))
        case .sourceIndependent: return try await independent(ctx.source, work: ctx.work)
        case .sourceOurs: return try ours(ctx.source)
        case .fixture(let path): return try await independent(RepoRoot.corpus.appendingPathComponent(path), work: ctx.work)
        }
    }

    @MainActor static func output(_ ctx: CaseContext) throws -> URL { guard let url = ctx.output else { throw CheckFailure("no output") }; return url }

    /// SSIM of two pictures of the drawing (quality §6).
    static func looksLike(_ side: Side, reference: Side, atLeast: Double) -> Check {
        Check(name: "looks like the reference") { ctx in
            let a = try await raster(side, ctx), b = try await raster(reference, ctx)
            ctx.attach("output", raster: a, name: "output.png"); ctx.attach("reference", raster: b, name: "reference.png")
            guard let ssim = SSIM.ssim(a, b) else { throw CheckFailure("pictures too small for SSIM") }
            return [.ssim("ssim vs reference", ssim.mean, atLeast: atLeast)]
        }
    }

    /// The output, re-read, has the source's painted paths in order with the same fills (ΔE00 ≤ 0.5) and stroke widths
    /// (± 0.01 pt), and the same text (quality §6 round trips).
    static func modelRoundTrip() -> Check {
        Check(name: "paths, fills, strokes and text round-trip") { ctx in
            let a = leaves(try model(ctx.source)), b = leaves(try model(try output(ctx)))
            guard a.paths.count == b.paths.count else { throw CheckFailure("path count \(b.paths.count), source \(a.paths.count)") }
            var worstE = 0.0, worstW = 0.0
            for (x, y) in zip(a.paths, b.paths) {
                if let cx = x.fill, let cy = y.fill { worstE = max(worstE, deltaE(cx, cy)) } else if (x.fill == nil) != (y.fill == nil) { throw CheckFailure("a fill appeared or vanished") }
                if let wx = x.stroke, let wy = y.stroke { worstW = max(worstW, abs(wx - wy)) } else if (x.stroke == nil) != (y.stroke == nil) { throw CheckFailure("a stroke appeared or vanished") }
            }
            return [.exact("path count difference", Double(b.paths.count - a.paths.count), equals: 0), .deltaE("worst fill ΔE00", worstE, atMost: 0.5),
                    Measurement(name: "worst stroke width difference", value: worstW, unit: "pt", limit: .atMost(0.01)),
                    .exact("text differs", a.text == b.text ? 0 : 1, equals: 0)]
        }
    }

    /// The output, re-read by our reader, says what the source says (text stays text unless outlines were asked for).
    static func textKept() -> Check {
        Check(name: "text kept") { ctx in
            let a = leaves(try model(ctx.source)).text, b = leaves(try model(try output(ctx))).text
            guard !a.isEmpty else { throw CheckFailure("the source has no text") }
            guard a == b else { throw CheckFailure("text \(b), source \(a)") }
            return [.exact("text differs", 0, equals: 0)]
        }
    }

    /// DSC structure of a PostScript output: the header, the bounding box, one page per `%%Page`, `%%EOF`, and Type 42
    /// fonts when the drawing has text.
    static func postScript(eps: Bool, boundingBox: [Int]?, type42: Bool) -> Check {
        Check(name: eps ? "EPS 3.0 structure" : "PostScript 3 structure") { ctx in
            let data = try Data(contentsOf: try output(ctx))
            var bytes = data
            // A DOS EPS binary header points at the PostScript section.
            if data.prefix(4) == Data([0xC5, 0xD0, 0xD3, 0xC6]), data.count > 12 {
                let start = Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24
                let length = Int(data[8]) | Int(data[9]) << 8 | Int(data[10]) << 16 | Int(data[11]) << 24
                bytes = data.subdata(in: start..<min(data.count, start + length))
            }
            let text = String(decoding: bytes, as: UTF8.self)
            let header = text.prefix(while: { $0 != "\n" && $0 != "\r" })
            guard header.hasPrefix("%!PS-Adobe-3.0"), !eps || header.contains("EPSF-3.0") else { throw CheckFailure("header is \(header)") }
            guard text.contains("%%EOF") else { throw CheckFailure("no %%EOF") }
            if let boundingBox {
                guard let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("%%BoundingBox:") }) else { throw CheckFailure("no %%BoundingBox") }
                let numbers = line.dropFirst(14).split(separator: " ").compactMap { Int($0) }
                guard numbers == boundingBox else { throw CheckFailure("bounding box \(numbers), expected \(boundingBox)") }
            }
            var out: [Measurement] = [.count("pages", text.components(separatedBy: "%%Page:").count - 1, atLeast: 1)]
            if type42 { out.append(.exact("Type 42 font embedded", text.contains("/FontType 42") ? 1 : 0, equals: 1)) }
            return out
        }
    }

    // MARK: Pictures

    /// PDFKit for PDF and Illustrator files, WebKit for SVG, our reader for the rest.
    @MainActor static func independent(_ url: URL, work: URL) async throws -> Raster {
        switch url.pathExtension.lowercased() {
        case "pdf", "ai":
            guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { throw CheckFailure("\(url.lastPathComponent) doesn’t open in PDFKit") }
            return try withExtendedLifetime(document) { try draw(size: page.bounds(for: .mediaBox).size) { context in page.draw(with: .mediaBox, to: context) } }
        case "svg":
            return try await webKit(String(decoding: try Data(contentsOf: url), as: UTF8.self), work: work)
        default:
            return try ours(url)
        }
    }

    /// Our reader's drawing, drawn by VectorDrawing.
    static func ours(_ url: URL) throws -> Raster {
        guard let page = try model(url).pages.first else { throw CheckFailure("no page") }
        return try draw(size: CGSize(width: page.size.width, height: page.size.height)) { VectorDrawing.draw(page, in: $0) }
    }

    /// A page of `size` points drawn into the comparison bitmap on white.
    static func draw(size: CGSize, _ body: (CGContext) -> Void) throws -> Raster {
        guard size.width > 0, size.height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CheckFailure("the page can’t be drawn")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        body(context)
        guard let image = context.makeImage(), let raster = Raster(image) else { throw CheckFailure("the page can’t be drawn") }
        return raster
    }

    /// WebKit's render of SVG markup, laid out at 400 × 300 CSS px and captured at 2×.
    @MainActor static func webKit(_ markup: String, work: URL) async throws -> Raster {
        var svg = markup
        if let start = svg.range(of: "<svg") { svg = String(svg[start.lowerBound...]) }
        let html = "<!DOCTYPE html><html><head><style>html,body{margin:0;background:#fff}svg{display:block;width:400px;height:300px}</style></head><body>\(svg)</body></html>"
        let folder = work.appendingPathComponent("webkit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = folder.appendingPathComponent("drawing.html")
        try Data(html.utf8).write(to: page)
        let run = await Pipeline.convertSteps(page, steps: [Step(.webKitSnapshot, "html", "png")], target: "png",
                                              options: OptionValues(["screenWidth": 400, "scale": 2]), into: folder)
        guard case .converted(let result) = run.outcome, let png = result.outputs.first, let full = Raster(contentsOf: png) else {
            throw CheckFailure("WebKit couldn’t render the SVG: \(run.outcome)")
        }
        guard full.width >= width, full.height >= height else { throw CheckFailure("WebKit's render is \(full.width)x\(full.height)") }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height { for i in 0..<(width * 3) { rgb[y * width * 3 + i] = full.rgb[y * full.width * 3 + i] } }
        return Raster(width: width, height: height, rgb: rgb)
    }

    // MARK: Models

    static func model(_ url: URL) throws -> VectorDocument {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "pdf": return try PDFReader.read(url).document
        case "ai": return try AIReader.read(url).document
        case "svg", "svgz": return try SVGReader.read(data, baseURL: url).document
        case "emf": return try EMFReader.read(data).document
        case "wmf": return try WMFReader.read(data).document
        case "xps": return try XPSReader.read(url).document
        case "sk": return try SKReader.read(data, dialect: .skencil).document
        case "sk1": return try SKReader.read(data, dialect: .sk1).document
        default: throw CheckFailure("no vector reader for .\(url.pathExtension)")
        }
    }

    struct PaintedPath { var fill: VectorColour?; var stroke: Double? }

    /// The painted paths in drawing order (fill as its colour or first gradient stop; stroke width in page points) and the
    /// words of the text runs.
    static func leaves(_ document: VectorDocument) -> (paths: [PaintedPath], text: [String]) {
        var paths: [PaintedPath] = [], text: [String] = []
        func colour(_ paint: VectorPaint?) -> VectorColour? {
            switch paint {
            case .solid(let c)?: c
            case .linear(_, _, let stops)?, .radial(_, _, let stops)?: stops.min { $0.offset < $1.offset }?.colour
            default: nil
            }
        }
        func walk(_ nodes: [VectorNode], scale: Double) {
            for node in nodes {
                switch node {
                case .path(_, let fill, let stroke, _): paths.append(PaintedPath(fill: colour(fill), stroke: stroke.map { $0.width * scale }))
                case .text(let run): text += run.text.split(separator: " ").map(String.init)
                case .group(let children, let t, _, _): walk(children, scale: scale * t.lengthScale)
                case .image: break
                }
            }
        }
        for page in document.pages { walk(page.nodes, scale: 1) }
        return (paths, text)
    }

    static func deltaE(_ a: VectorColour, _ b: VectorColour) -> Double {
        func lab(_ c: VectorColour) -> Lab? {
            DeltaE.lab(of: Raster(width: 1, height: 1, red: UInt8((c.red * 255).rounded()), green: UInt8((c.green * 255).rounded()), blue: UInt8((c.blue * 255).rounded())))?.first
        }
        guard let x = lab(a), let y = lab(b) else { return .infinity }
        return DeltaE.ciede2000(x, y)
    }
}
