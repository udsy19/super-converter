import CoreGraphics
import Foundation
import PDFKit
import SuperConverterCore

/// The reusable checks cases are made of. A kit's cases combine these; a new metric a kit needs goes here, once.
extension Check {
    /// The first output is non-empty and the sniffer identifies it as `format` (content first, extension second).
    static func producesFormat(_ format: FormatID) -> Check {
        Check(name: "output is \(format.pill)") { ctx in
            guard let url = ctx.output else { throw CheckFailure("no output") }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else { throw CheckFailure("\(url.lastPathComponent) is empty") }
            guard let found = try? Services.sniffer.sniff(url).format else { throw CheckFailure("the sniffer cannot identify \(url.lastPathComponent)") }
            guard FormatCatalog.isSameFormat(found, format) else { throw CheckFailure("the output sniffs as \(found.pill)") }
            return [.info("output bytes", Double(size), unit: "B")]
        }
    }

    /// The first output, read as UTF-8 text, contains every string (case-insensitive).
    static func textContains(_ needles: [String]) -> Check {
        Check(name: "text contains \(needles.count) strings") { ctx in
            let text = try textOf(ctx.output)
            let missing = needles.filter { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) == nil }
            if !missing.isEmpty { throw CheckFailure("missing: \(missing)") }
            return [.exact("missing strings", 0, equals: 0)]
        }
    }

    /// An entry of a ZIP-based output (DOCX, EPUB, XLSX, ODT…), read through `/usr/bin/unzip`, contains every string.
    static func zipEntryContains(_ entry: String, _ needles: [String]) -> Check {
        Check(name: "\(entry) contains \(needles.count) strings") { ctx in
            guard let url = ctx.output else { throw CheckFailure("no output") }
            let text = try zipEntry(url, entry)
            let missing = needles.filter { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) == nil }
            if !missing.isEmpty { throw CheckFailure("missing in \(entry): \(missing)") }
            return [.exact("missing strings", 0, equals: 0)]
        }
    }

    /// The output is a ZIP that lists every one of these entry names.
    static func zipHasEntries(_ names: [String]) -> Check {
        Check(name: "package has \(names.joined(separator: ", "))") { ctx in
            guard let url = ctx.output else { throw CheckFailure("no output") }
            let listing = Subprocess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z1", url.path])
            guard listing.status == 0, let text = listing.standardOutput else { throw CheckFailure("not a readable ZIP") }
            let entries = Set(text.split(separator: "\n").map(String.init))
            let missing = names.filter { !entries.contains($0) }
            if !missing.isEmpty { throw CheckFailure("missing entries: \(missing)") }
            return [.info("entries", Double(entries.count))]
        }
    }

    /// A PDF output with at least `pages` pages, containing `text`, whose first page is not blank (ink coverage over `inkAtLeast`).
    static func pdf(pages: Int = 1, text: [String] = [], inkAtLeast: Double = 0.001) -> Check {
        Check(name: "PDF has \(pages)+ pages, text and ink") { ctx in
            guard let url = ctx.output, let doc = PDFDocument(url: url) else { throw CheckFailure("not a readable PDF") }
            var out: [Measurement] = [.count("pages", doc.pageCount, atLeast: pages)]
            let content = doc.string ?? ""
            let missing = text.filter { content.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) == nil }
            if !missing.isEmpty { throw CheckFailure("text not found: \(missing)") }
            guard let page = doc.page(at: 0), let raster = PDFRender.raster(page, dpi: 72) else { throw CheckFailure("page 1 does not render") }
            ctx.attach("page 1", raster: raster, name: "page1.png")
            let ink = Double(stride(from: 0, to: raster.rgb.count, by: 3).filter { raster.rgb[$0] < 200 || raster.rgb[$0 + 1] < 200 || raster.rgb[$0 + 2] < 200 }.count) / Double(raster.pixelCount)
            out.append(Measurement(name: "ink coverage", value: ink, limit: .atLeast(inkAtLeast)))
            return out
        }
    }

    /// Converts the output back to `format` and compares the words with the source's own (quality §3.7 round trips): the
    /// share of the source's words found in order in the round trip must be at least `atLeast`.
    static func roundTrip(to format: FormatID, via intermediate: FormatID? = nil, wordsAtLeast atLeast: Double = 1.0) -> Check {
        Check(name: "round trip back to \(format.pill)") { ctx in
            guard let output = ctx.output else { throw CheckFailure("no output") }
            let folder = ctx.work.appendingPathComponent("roundtrip", isDirectory: true)
            let back = await Pipeline.convert(output, to: format, into: folder)
            guard case .converted(let result) = back.outcome, let file = result.outputs.first else { throw CheckFailure("the way back failed: \(back.outcome)") }
            let original = words(try textOf(ctx.source)), trip = words(try textOf(file))
            let kept = longestCommonSubsequence(original, trip)
            return [Measurement(name: "words kept in order", value: original.isEmpty ? 1 : Double(kept) / Double(original.count), limit: .atLeast(atLeast))]
        }
    }

    /// The output picture against a reference picture: SSIM, ΔE00 (mean and p95) and PSNR, with a difference heat map in the report.
    static func imageMatches(reference: @escaping @MainActor (CaseContext) -> URL, ssimAtLeast: Double? = nil, meanDeltaEAtMost: Double? = nil,
                             p95DeltaEAtMost: Double? = nil, psnrAtLeast: Double? = nil) -> Check {
        Check(name: "picture matches the reference") { ctx in
            guard let out = ctx.output, let a = Raster(contentsOf: reference(ctx)), let b = Raster(contentsOf: out) else { throw CheckFailure("a picture could not be decoded") }
            guard a.width == b.width, a.height == b.height else { throw CheckFailure("size \(b.width)x\(b.height) differs from \(a.width)x\(a.height)") }
            var m: [Measurement] = []
            if let ssimAtLeast, let r = SSIM.ssim(a, b) { m.append(.ssim("ssim", r.mean, atLeast: ssimAtLeast)) }
            if meanDeltaEAtMost != nil || p95DeltaEAtMost != nil, let map = DeltaE.map(a, b) {
                let s = DeltaE.summarise(map)
                if let x = meanDeltaEAtMost { m.append(.deltaE("deltaE mean", s.mean, atMost: x)) }
                if let x = p95DeltaEAtMost { m.append(.deltaE("deltaE p95", s.p95, atMost: x)) }
                ctx.attach("ΔE00 histogram", file: "deltae.svg", data: Data(Heat.histogramSVG(map).utf8))
                ctx.attach("difference (ΔE00, red = 10+)", raster: Heat.map(map, width: a.width, height: a.height, full: 10), name: "difference.png")
            }
            if let psnrAtLeast, let p = PSNR.compare(a, b) { m.append(.psnr(p, atLeast: psnrAtLeast)) }
            ctx.attach("reference", raster: a, name: "reference.png")
            ctx.attach("output", raster: b, name: "output.png")
            return m
        }
    }

    // MARK: Text helpers

    @MainActor
    static func textOf(_ url: URL?) throws -> String {
        guard let url else { throw CheckFailure("no file") }
        guard let data = try? Data(contentsOf: url) else { throw CheckFailure("\(url.lastPathComponent) cannot be read") }
        if let doc = PDFDocument(data: data), url.pathExtension.lowercased() == "pdf" { return doc.string ?? "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func zipEntry(_ zip: URL, _ entry: String) throws -> String {
        let r = Subprocess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", zip.path, entry])
        guard r.status == 0, let text = r.standardOutput else { throw CheckFailure("\(entry) is not in \(zip.lastPathComponent)") }
        return text
    }

    /// Lower-cased words of a text, markup and punctuation dropped.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var row = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() { row[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], row[j]) }
            previous = row
        }
        return previous[b.count]
    }
}

enum PDFRender {
    /// A PDF page drawn at `dpi` on white.
    static func raster(_ page: PDFPage, dpi: Double) -> Raster? {
        let box = page.bounds(for: .cropBox)
        let scale = dpi / 72
        let width = max(1, Int((box.width * scale).rounded())), height = max(1, Int((box.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .cropBox, to: context)
        return context.makeImage().flatMap { Raster($0) }
    }
}

/// Difference heat maps and histograms for the report.
enum Heat {
    /// Black = identical, through blue and yellow to red at `full`.
    static func map(_ values: [Double], width: Int, height: Int, full: Double) -> Raster {
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for (i, v) in values.enumerated() {
            let t = min(1, max(0, v / full))
            let (r, g, b): (Double, Double, Double) = t < 0.5 ? (0, t * 2 * 0.8, 0.3 + t * 2 * 0.7) : (min(1, (t - 0.5) * 2 + 0.6), 0.8 * (1 - (t - 0.5) * 2), 0.0)
            rgb[i * 3] = UInt8(r * 255); rgb[i * 3 + 1] = UInt8(g * 255); rgb[i * 3 + 2] = UInt8(b * 255)
        }
        return Raster(width: width, height: height, rgb: rgb)
    }

    /// A ΔE00 histogram (bins of 0.5 up to 10, the last bin open) as a small SVG.
    static func histogramSVG(_ values: [Double]) -> String {
        let bins = 21
        var counts = [Int](repeating: 0, count: bins)
        for v in values { counts[min(bins - 1, Int(v / 0.5))] += 1 }
        let peak = max(1, counts.max() ?? 1)
        let bars = counts.enumerated().map { i, c -> String in
            let h = Double(c) / Double(peak) * 90
            return "<rect x=\"\(10 + i * 14)\" y=\"\(100 - h)\" width=\"12\" height=\"\(h)\" fill=\"#5b7bd5\"/>"
        }.joined()
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"310\" height=\"130\" font-family=\"sans-serif\" font-size=\"10\">\(bars)<text x=\"10\" y=\"120\">0</text><text x=\"150\" y=\"120\">5</text><text x=\"270\" y=\"120\">10+ ΔE00</text></svg>"
    }
}
