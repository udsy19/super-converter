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
            // A container format the sniffer cannot tell from a plain ZIP (OEB) is accepted by its extension.
            let claimed = (try? Services.sniffer.sniff(url).claimed) ?? nil
            guard FormatCatalog.isSameFormat(found, format) || (found == "zip" && claimed.map { FormatCatalog.isSameFormat($0, format) } == true) else {
                throw CheckFailure("the output sniffs as \(found.pill)")
            }
            return [.info("output bytes", Double(size), unit: "B")]
        }
    }

    /// The first output, read as it is (markup included; a PDF through PDFKit), contains every string (case-insensitive).
    static func textContains(_ needles: [String]) -> Check {
        Check(name: "text contains \(needles.count) strings") { ctx in
            let text = try rawText(ctx.output)
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

    /// The output and the source say the same thing once both are converted to `format` (CSV for spreadsheets: "values
    /// round-trip as displayed", quality §4): the words of the two conversions agree in order.
    static func equivalentAfter(converting format: FormatID, atLeast minimum: Double = 1.0) -> Check {
        Check(name: "output and source agree as \(format.pill)") { ctx in
            guard let output = ctx.output else { throw CheckFailure("no output") }
            var texts: [[String]] = []
            for (label, file) in [("source", ctx.source), ("output", output)] {
                if label == "source", ctx.sourceFormat == format { texts.append(words(try textOf(file))); continue }
                let run = await Pipeline.convert(file, to: format, into: ctx.work.appendingPathComponent("equivalent-\(label)", isDirectory: true))
                guard case .converted(let result) = run.outcome, let converted = result.outputs.first else { throw CheckFailure("the \(label) did not convert to \(format.pill): \(run.outcome)") }
                texts.append(words(try textOf(converted)))
            }
            guard !texts[0].isEmpty else { throw CheckFailure("the source converts to nothing") }
            let kept = Double(longestCommonSubsequence(texts[0], texts[1])) / Double(max(texts[0].count, texts[1].count))
            return [Measurement(name: "agreement", value: kept, limit: .atLeast(minimum))]
        }
    }

    /// THD+N of the first output's first channel at `frequency`, in dB (quality §5.3).
    static func thdPlusN(frequency: Double, atMost limit: Double) -> Check {
        Check(name: "THD+N at \(Measurement.format(frequency)) Hz") { ctx in
            guard let url = ctx.output, let signal = AudioMetrics.read(url) else { throw CheckFailure("the audio cannot be decoded") }
            guard let value = AudioMetrics.thdPlusN(signal, frequency: frequency) else { throw CheckFailure("THD+N could not be measured") }
            return [Measurement(name: "THD+N", value: value, unit: "dB", limit: .atMost(limit), noise: 0.5)]
        }
    }

    /// EBU R128 integrated loudness within `tolerance` LU of `integrated`, and the true peak at most `truePeakAtMost` dBTP,
    /// measured by `ffmpeg ebur128`.
    static func loudness(integrated target: Double, tolerance: Double, truePeakAtMost: Double? = nil) -> Check {
        Check(name: "EBU R128 loudness") { ctx in
            guard let url = ctx.output else { throw CheckFailure("no output") }
            guard FFmpegLocator.find() != nil else { throw CheckFailure("ffmpeg was not found (scripts/tools.sh fetch, or SUPERCONVERTER_FFMPEG)") }
            guard let m = Loudness.measure(url) else { throw CheckFailure("ffmpeg could not measure \(url.lastPathComponent)") }
            var out = [Measurement(name: "integrated loudness", value: m.integrated, unit: "LUFS", limit: .within(target, tolerance: tolerance), noise: 0.1), .info("loudness range", m.range, unit: "LU")]
            if let truePeakAtMost, let peak = m.truePeak { out.append(Measurement(name: "true peak", value: peak, unit: "dBTP", limit: .atMost(truePeakAtMost), noise: 0.1)) }
            return out
        }
    }

    /// The output folder holds exactly what an independent extraction of the source (`ditto -x -k`) holds: same paths, sizes,
    /// SHA-256, links and empty folders (quality §8 "Content manifest").
    static func manifestMatchesExtraction() -> Check {
        Check(name: "manifest equals an independent extraction") { ctx in
            guard let folder = ctx.output else { throw CheckFailure("no output") }
            let reference = ctx.work.appendingPathComponent("reference", isDirectory: true)
            try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
            guard Subprocess.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", ctx.source.path, reference.path]).status == 0 else { throw CheckFailure("the reference extraction failed") }
            let expected = Manifest.entries(of: reference), actual = Manifest.entries(of: folder)
            let differences = Manifest.differences(expected, actual)
            if !differences.isEmpty { throw CheckFailure("manifest differs: \(differences.prefix(5))") }
            return [.count("entries", actual.count, atLeast: 1), .exact("manifest differences", 0, equals: 0)]
        }
    }

    /// An EPUB's first ZIP entry is `mimetype`, stored uncompressed, holding `application/epub+zip` (the EPUB container rule).
    static func epubMimetypeFirstAndStored() -> Check {
        Check(name: "EPUB mimetype first and stored") { ctx in
            guard let url = ctx.output, let head = try? FileHandle(forReadingFrom: url).read(upToCount: 64), head.count >= 58 else { throw CheckFailure("not a ZIP") }
            let bytes = [UInt8](head)
            let name = String(decoding: bytes[30..<38], as: UTF8.self), method = Int(bytes[8]) | Int(bytes[9]) << 8
            let body = String(decoding: bytes[38..<58], as: UTF8.self)
            guard bytes[0] == 0x50, bytes[1] == 0x4B else { throw CheckFailure("not a ZIP") }
            guard name == "mimetype" else { throw CheckFailure("the first entry is \(name), not mimetype") }
            guard method == 0 else { throw CheckFailure("mimetype is compressed (method \(method))") }
            guard body == "application/epub+zip" else { throw CheckFailure("mimetype holds \(body)") }
            return [.exact("mimetype ok", 1, equals: 1)]
        }
    }

    /// Every picture of a comic archive appears byte for byte (same SHA-256) in the output package.
    static func picturesPassThrough() -> Check {
        Check(name: "pictures pass through untouched") { ctx in
            func hashes(_ zip: URL) -> [String] {
                let listing = Subprocess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z1", zip.path]).standardOutput ?? ""
                return listing.split(separator: "\n").map(String.init).filter { ["png", "jpg", "jpeg", "gif"].contains(($0 as NSString).pathExtension.lowercased()) }
                    .map { Manifest.sha256(Subprocess.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", zip.path, $0]).data) }
            }
            guard let output = ctx.output else { throw CheckFailure("no output") }
            let source = hashes(ctx.source), made = Set(hashes(output))
            guard !source.isEmpty else { throw CheckFailure("the source has no pictures") }
            return [Measurement(name: "pictures kept byte-exact", value: Double(source.filter(made.contains).count) / Double(source.count), limit: .within(1, tolerance: 0))]
        }
    }

    /// Share of the source's words that survive in order in the output's text (document → document claims of quality §3.7 and
    /// §3.6: "character error rate 0" for born-digital PDFs). `ignoring` drops words the target legitimately omits (link URLs).
    static func wordRecall(atLeast minimum: Double, ignoring: Set<String> = []) -> Check {
        Check(name: "words kept from the source") { ctx in
            let original = words(try textOf(ctx.source)).filter { !ignoring.contains($0) }, kept = words(try textOf(ctx.output)).filter { !ignoring.contains($0) }
            guard !original.isEmpty else { throw CheckFailure("the source has no text") }
            return [Measurement(name: "word recall", value: Double(longestCommonSubsequence(original, kept)) / Double(original.count), limit: .atLeast(minimum))]
        }
    }

    /// The first output picture has ink: the share of non-white pixels is at least `inkAtLeast`; its bounding box has
    /// `aspect` (width / height) within `tolerance` when given — for plots zoomed to the drawing's extents.
    static func pictureHasInk(inkAtLeast: Double = 0.001, aspect: Double? = nil, tolerance: Double = 0.05) -> Check {
        Check(name: "picture has ink") { ctx in
            guard let url = ctx.output, let raster = Raster(contentsOf: url) else { throw CheckFailure("the output picture cannot be decoded") }
            ctx.attach("output", raster: raster, name: "output.png")
            var minX = raster.width, maxX = -1, minY = raster.height, maxY = -1, ink = 0
            for y in 0..<raster.height { for x in 0..<raster.width {
                let i = (y * raster.width + x) * 3
                if raster.rgb[i] < 200 || raster.rgb[i + 1] < 200 || raster.rgb[i + 2] < 200 { ink += 1; minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            } }
            var out = [Measurement(name: "ink coverage", value: Double(ink) / Double(raster.pixelCount), limit: .atLeast(inkAtLeast))]
            if let aspect, maxX >= minX, maxY >= minY {
                out.append(Measurement(name: "ink aspect", value: Double(maxX - minX + 1) / Double(maxY - minY + 1), limit: .within(aspect, tolerance: aspect * tolerance)))
            }
            return out
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

    /// The file's own text: markup and all for text formats, extracted text for a PDF.
    static func rawText(_ url: URL?) throws -> String {
        guard let url else { throw CheckFailure("no file") }
        if url.pathExtension.lowercased() == "pdf" { return try TextExtraction.text(of: url) }
        guard let data = try? Data(contentsOf: url) else { throw CheckFailure("\(url.lastPathComponent) cannot be read") }
        return String(decoding: data, as: UTF8.self)
    }

    /// What a reader would read: the file's text with markup removed.
    static func textOf(_ url: URL?) throws -> String {
        guard let url else { throw CheckFailure("no file") }
        return try TextExtraction.text(of: url)
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
