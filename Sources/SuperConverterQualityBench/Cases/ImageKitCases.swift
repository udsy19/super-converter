import ApplicationServices
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SuperConverterCore

/// ImageKit (quality §2.8): every image test of the table, through the planner on the generated fixtures
/// (`scripts/make-fixtures.swift`, `imageKit()`), with the table's thresholds.
enum ImageKitCases {
    static var all: [BenchCase] {
        lossless + profiles + scaling + lossy + raw + hdr + gif + metadata + codecs + icons + otherWriters
    }

    // MARK: Lossless round trips (decoded samples bit-exact)

    static let lossless: [BenchCase] = {
        var cases: [BenchCase] = []
        for target in ["tiff", "psd", "bmp", "webp"] as [FormatID] {
            cases.append(exact("lossless-rgb8-\(target)", "generated/colorchecker-24.png", target))
        }
        for target in ["tiff", "psd", "webp"] as [FormatID] { cases.append(exact("lossless-rgba8-\(target)", "generated/logo-alpha-128.png", target)) }
        // AVIF-lossless: libavif + libaom, 8-bit 4:4:4 with the identity matrix (ImageKit's AVIFWriter).
        let lossless = OptionValues(["lossless": true])
        cases.append(exact("lossless-rgb8-avif", "generated/colorchecker-24.png", "avif", options: lossless))
        cases.append(exact("lossless-rgba8-avif", "generated/logo-alpha-128.png", "avif", options: lossless))
        for target in ["tiff", "psd"] as [FormatID] {
            cases.append(exact("lossless-rgb16-\(target)", "generated/ramp-p3-16.png", target))
            cases.append(exact("lossless-gray16-\(target)", "generated/ramp-gray-16.png", target))
        }
        cases.append(exact("lossless-cmyk8-psd", "generated/cmyk-chart.tiff", "psd"))
        return cases
    }()

    /// Source → `target` → the source's own format, both through the app: the samples come back bit-exact.
    private static func exact(_ name: String, _ fixture: String, _ target: FormatID, options: OptionValues = OptionValues()) -> BenchCase {
        BenchCase(id: "imagekit.\(name)", category: .image, fixture: fixture, target: target, options: options, checks: [
            .producesFormat(target),
            // Read back by the app itself (PSD's own reader takes the exact layer; ImageIO's reads the matted composite).
            Check(name: "read back, the samples are bit-exact") { ctx in
                let format = Pipeline.sourceFormat(of: ctx.source) ?? "png"
                let back = await Pipeline.convert(try unwrap(ctx.output), to: format, into: ctx.work.appendingPathComponent("back"))
                guard case .converted(let result) = back.outcome, let file = result.outputs.first else { throw CheckFailure("back to \(format.pill): \(back.outcome)") }
                return try samplesMatch(ctx.source, file)
            },
        ])
    }

    // MARK: Colour profiles

    static let profiles: [BenchCase] = {
        var cases: [BenchCase] = ["png", "tiff", "psd", "jpg", "webp", "avif", "heic"].map { (target: FormatID) in
            let lossy = ["jpg", "webp", "avif", "heic"].contains(target)
            return BenchCase(id: "imagekit.profile-kept-\(target)", category: .image, fixture: "generated/photo-p3-320.tiff", target: target, checks: [
                Check(name: "the Display P3 profile is kept") { ctx in
                    let same = try profileKept(ctx.source, try unwrap(ctx.output))
                    return [.exact("profile identical", same ? 1 : 0, equals: 1)]
                },
            ] + (lossy ? [.imageMatches(reference: { $0.source }, meanDeltaEAtMost: 1.0, p95DeltaEAtMost: 2.5)]
                       : [.imageMatches(reference: { $0.source }, meanDeltaEAtMost: 0.0)]))
        }
        cases.append(BenchCase(id: "imagekit.profile-kept-cmyk-jpg", category: .image, fixture: "generated/cmyk-chart.tiff", target: "jpg", checks: [
            Check(name: "CMYK stays CMYK with its profile") { ctx in
                let space = try unwrap(firstImage(try unwrap(ctx.output))?.colorSpace)
                return [.exact("CMYK", space.model == .cmyk ? 1 : 0, equals: 1), .exact("profile identical", try profileKept(ctx.source, try unwrap(ctx.output)) ? 1 : 0, equals: 1)]
            },
        ]))
        // Converted: CMYK → sRGB PNG, and Display P3 → sRGB on request, against ColorSync's own transform (relative + BPC).
        cases.append(BenchCase(id: "imagekit.profile-converted-cmyk", category: .image, fixture: "generated/cmyk-chart.tiff", target: "png", checks: [
            Check(name: "patches vs the ColorSync reference") { ctx in
                // The file holds the patches as 8-bit samples: the reference starts from those, not the exact fractions.
                try patchesMatch(ctx, source: cmykPatches.map { $0.map { Float(($0 * 255).rounded()) / 255 } }, sourceSpace: CGColorSpace(name: CGColorSpace.genericCMYK)!, perRow: 8, size: 16)
            },
        ]))
        cases.append(BenchCase(id: "imagekit.profile-converted-p3", category: .image, fixture: "generated/colorchecker-p3.png", target: "png",
                               options: OptionValues(["colourProfile": "srgb"]), checks: [
            Check(name: "patches vs the ColorSync reference") { ctx in
                try patchesMatch(ctx, source: colorChecker.map { $0.map { Float($0) / 255 } }, sourceSpace: CGColorSpace(name: CGColorSpace.displayP3)!, perRow: 6, size: 40)
            },
        ]))
        // No-ICC target: what the viewer showed is what the GIF shows (in-gamut ColorChecker, ≤ 256 colours).
        cases.append(BenchCase(id: "imagekit.no-icc-gif", category: .image, fixture: "generated/colorchecker-p3.png", target: "gif", checks: [
            .producesFormat("gif"), .imageMatches(reference: { $0.source }, meanDeltaEAtMost: 1.0),
        ]))
        return cases
    }()

    // MARK: Scaling, ringing, edges

    static let scaling: [BenchCase] = {
        var cases: [BenchCase] = [256, 128, 64].map { side in
            BenchCase(id: "imagekit.gamma-scaling-\(side)", category: .image, fixture: "generated/checker-512.png", target: "png",
                      options: OptionValues(["width": .int(side)]), checks: [
                Check(name: "uniform 50 % linear grey") { ctx in
                    let r = try raster(ctx.output)
                    guard r.width == side else { throw CheckFailure("width \(r.width)") }
                    return [Measurement(name: "min sRGB", value: Double(r.rgb.min() ?? 0), limit: .atLeast(187)),
                            Measurement(name: "max sRGB", value: Double(r.rgb.max() ?? 0), limit: .atMost(188))]
                },
            ])
        }
        cases += [100, 600].map { width in
            BenchCase(id: "imagekit.ringing-\(width)", category: .image, fixture: "generated/step-edge-200.png", target: "png",
                      options: OptionValues(["width": .int(width)]), checks: [
                Check(name: "no halo beyond 3 px") { ctx in
                    let r = try raster(ctx.output)
                    let edge = r.width / 2
                    var halo = 0
                    for y in 0..<r.height { for x in 0..<r.width where abs(x - edge) > 3 {
                        let v = Int(r.rgb[(y * r.width + x) * 3]), flat = x < edge ? 0 : 255
                        halo = max(halo, abs(v - flat))
                    } }
                    return [Measurement(name: "halo beyond 3 px", value: Double(halo), unit: "levels", limit: .atMost(2))]
                },
            ])
        }
        cases.append(BenchCase(id: "imagekit.edge-chroma", category: .image, fixture: "generated/red-text-240.png", target: "jpg", checks: [
            Check(name: "glyph-edge ΔE00") { ctx in
                let a = try raster(ctx.source), b = try raster(ctx.output)
                guard let map = DeltaE.map(a, b) else { throw CheckFailure("sizes differ") }
                var edges: [Double] = []
                for y in 1..<(a.height - 1) { for x in 1..<(a.width - 1) {
                    var white = false, ink = false
                    for dy in -1...1 { for dx in -1...1 {
                        let i = ((y + dy) * a.width + x + dx) * 3
                        if a.rgb[i] > 250 && a.rgb[i + 1] > 250 && a.rgb[i + 2] > 250 { white = true } else { ink = true }
                    } }
                    if white && ink { edges.append(map[y * a.width + x]) }
                } }
                let s = DeltaE.summarise(edges)
                return [.deltaE("edge ΔE00 p95", s.p95, atMost: 6), .info("edge ΔE00 mean", s.mean)]
            },
        ]))
        cases.append(BenchCase(id: "imagekit.alpha-edges", category: .image, fixture: "generated/logo-alpha-128.png", target: "jpg", checks: [
            Check(name: "no dark fringe on white") { ctx in
                // Across the alpha edge (source alpha strictly between 0 and 1) the disc, (200, 30, 40), meets white: no
                // pixel there may be darker than the disc itself.
                let r = try raster(ctx.output), alpha = try alphaChannel(ctx.source)
                let luma = r.luma
                let edge = alpha.indices.filter { alpha[$0] > 0 && alpha[$0] < 255 }
                let foreground = 0.299 * 200 + 0.587 * 30 + 0.114 * 40
                return [Measurement(name: "min luma across the edge", value: edge.map { luma[$0] }.min() ?? 0, limit: .atLeast(min(foreground, 255) - 1)),
                        .info("edge pixels", Double(edge.count))]
            },
        ]))
        return cases
    }()

    // MARK: Photo lossy defaults

    /// The 24 Kodak photographs (Tests/Corpus/corpus.lock, `scripts/fetch-corpus.sh`) at each lossy default. They are PNGs, a
    /// graphics source that WebP would write losslessly (formats §5), so `lossless` is turned off to get the photo defaults.
    static let lossy: [BenchCase] = ["jpg", "webp", "avif", "heic"].flatMap { (target: FormatID) in
        (1...24).map { n in
            let photo = String(format: "kodim%02d", n)
            return BenchCase(id: "imagekit.photo-\(target)-\(photo)", category: .image, tier: .full, fixture: "external/photos/\(photo).png",
                             target: target, options: OptionValues(["lossless": false]), checks: [
                .producesFormat(target), .imageMatches(reference: { $0.source }, ssimAtLeast: 0.985, meanDeltaEAtMost: 1.5),
            ])
        }
    }

    // MARK: RAW

    static let raw: [BenchCase] = ["png", "jpg", "tiff", "heic"].map { (target: FormatID) in
        BenchCase(id: "imagekit.raw-\(target)", category: .image, fixture: "generated/synthetic.dng", target: target, checks: [
            Check(name: "the pipeline adds nothing to CIRAWFilter") { ctx in
                let out = try unwrap(ctx.output)
                guard let filter = CIRAWFilter(imageURL: ctx.source), let developed = filter.outputImage,
                      let space = firstImage(out)?.colorSpace,
                      let reference = CIContext().createCGImage(developed, from: developed.extent, format: .RGBA16, colorSpace: space),
                      let a = Raster(reference) else { throw CheckFailure("bare CIRAWFilter could not develop the fixture") }
                let b = try raster(out)
                guard let map = DeltaE.map(a, b) else { throw CheckFailure("size \(b.width)x\(b.height) vs \(a.width)x\(a.height)") }
                return [.deltaE("ΔE00 mean vs CIRAWFilter", DeltaE.summarise(map).mean, atMost: 0.3)]
            },
        ])
    }

    // MARK: HDR

    static let hdr: [BenchCase] = ["heic", "jpg", "avif"].map { (target: FormatID) in
        BenchCase(id: "imagekit.hdr-\(target)", category: .image, fixture: "generated/hdr-gainmap.heic", target: target, checks: [
            Check(name: "gain map kept") { ctx in
                [.exact("gain map present", hasGainMap(try unwrap(ctx.output)) ? 1 : 0, equals: 1),
                 .exact("no HDR loss note", ctx.result.lossNotes.contains(LossNote(.hdrToSDR)) ? 0 : 1, equals: 1)]
            },
        ])
    } + [
        BenchCase(id: "imagekit.hdr-png", category: .image, fixture: "generated/hdr-gainmap.heic", target: "png", checks: [
            Check(name: "tone-mapped like CIToneMapHeadroom") { ctx in
                let out = try unwrap(ctx.output)
                guard let image = firstImage(out), let space = image.colorSpace, let reference = toneMapReference(ctx.source, space: space) else {
                    throw CheckFailure("no reference tone map")
                }
                let a = try unwrap(Raster(reference)), b = try raster(out)
                var worst = 0.0
                for y in 0..<b.height { for x in (b.width * 3 / 4)..<b.width { for c in 0..<3 {
                    worst = max(worst, abs(Double(a.rgb[(y * a.width + x) * 3 + c]) - Double(b.rgb[(y * b.width + x) * 3 + c])) / 255)
                } } }
                return [.exact("HDR loss note", ctx.result.lossNotes.contains(LossNote(.hdrToSDR)) ? 1 : 0, equals: 1),
                        Measurement(name: "highlights vs reference", value: worst, limit: .atMost(0.02))]
            },
        ]),
    ]

    // MARK: GIF

    static let gif: [BenchCase] = [
        BenchCase(id: "imagekit.gif-graphics", category: .image, fixture: "generated/colorchecker-24.png", target: "gif", checks: [
            .imageMatches(reference: { $0.source }, meanDeltaEAtMost: 0.5),
            Check(name: "colours exact") { ctx in
                let a = try raster(ctx.source), b = try raster(ctx.output)
                return [.exact("pixels differing", Double(zip(a.rgb, b.rgb).filter { $0 != $1 }.count), equals: 0)]
            },
        ]),
        BenchCase(id: "imagekit.gif-photo", category: .image, fixture: "generated/photo-p3-320.tiff", target: "gif", checks: [
            .imageMatches(reference: { $0.source }, meanDeltaEAtMost: 3.0),
        ]),
        BenchCase(id: "imagekit.gif-banding", category: .image, fixture: "generated/gradient-256.png", target: "gif", checks: [
            .imageMatches(reference: { $0.source }, meanDeltaEAtMost: 3.0),
            Check(name: "no visible bands") { ctx in
                // Bands are steps the eye sees from a distance: the picture seen through an 8 × 8 box (light averaged
                // linearly, as dither mixes it) must match the source seen the same way.
                let a = try blurred(try raster(ctx.source)), b = try blurred(try raster(ctx.output))
                guard let map = DeltaE.map(a, b) else { throw CheckFailure("sizes differ") }
                let s = DeltaE.summarise(map)
                return [.deltaE("ΔE00 mean, 8×8 view", s.mean, atMost: 1.5), .info("ΔE00 p95, 8×8 view", s.p95)]
            },
        ]),
        BenchCase(id: "imagekit.gif-animated", category: .image, fixture: "generated/animated-3.gif", target: "gif", checks: [
            Check(name: "frames and timing kept") { ctx in
                let (count, duration) = try animation(try unwrap(ctx.output))
                return [.exact("frames", Double(count), equals: 3), Measurement(name: "duration", value: duration, unit: "s", limit: .within(0.6, tolerance: 0.001))]
            },
        ]),
        BenchCase(id: "imagekit.webp-animated", category: .image, fixture: "generated/animated-3.gif", target: "webp", checks: [
            Check(name: "frames and timing kept") { ctx in
                let (count, duration) = try animation(try unwrap(ctx.output))
                return [.exact("frames", Double(count), equals: 3), Measurement(name: "duration", value: duration, unit: "s", limit: .within(0.6, tolerance: 0.001))]
            },
        ]),
    ]

    // MARK: Metadata

    static let metadata: [BenchCase] = ["jpg", "heic", "png", "tiff"].map { (target: FormatID) in
        BenchCase(id: "imagekit.metadata-\(target)", category: .image, fixture: "generated/exif-orient6.jpg", target: target,
                  checks: [metadataCheck(gps: true)])
    } + [
        BenchCase(id: "imagekit.metadata-no-location", category: .image, fixture: "generated/exif-orient6.jpg", target: "jpg",
                  options: OptionValues(["metadata": "allButLocation"]), checks: [metadataCheck(gps: false)]),
    ]

    private static func metadataCheck(gps: Bool) -> Check {
        Check(name: "tags copied, pixels rotated") { ctx in
            let out = try unwrap(ctx.output)
            let p = CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
            let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:], tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let present = [exif[kCGImagePropertyExifDateTimeOriginal], tiff[kCGImagePropertyTIFFMake], tiff[kCGImagePropertyTIFFModel],
                           exif[kCGImagePropertyExifLensModel]].filter { $0 != nil }.count
            let hasGPS = !((p[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]).isEmpty
            let r = try raster(out)
            // Stored 96 × 64 with a red block top-left; orientation 6 shows it 64 × 96 with the block top-right.
            let i = (8 * r.width + r.width - 8) * 3
            let red = r.rgb[i] > 180 && r.rgb[i + 1] < 80
            return [.exact("DateTimeOriginal, Make, Model, Lens", Double(present), equals: 4), .exact("GPS", hasGPS ? 1 : 0, equals: gps ? 1 : 0),
                    .exact("orientation", Double((p[kCGImagePropertyOrientation] as? Int) ?? 1), equals: 1),
                    .exact("rotated size", r.width == 64 && r.height == 96 ? 1 : 0, equals: 1), .exact("block top-right", red ? 1 : 0, equals: 1)]
        }
    }

    // MARK: Own codecs, icons, the other kits' writers

    static let codecs: [BenchCase] = [
        BenchCase(id: "imagekit.psb", category: .image, fixture: "generated/sample.psb", target: "png", checks: [
            Check(name: "composite decoded") { ctx in
                let r = try raster(ctx.output)
                let i = (10 * r.width + 10) * 3
                return [Measurement(name: "pixel (10, 10) error", value: Double(abs(Int(r.rgb[i]) - 40) + abs(Int(r.rgb[i + 1]) - 50) + abs(Int(r.rgb[i + 2]) - 128)),
                                    unit: "levels", limit: .atMost(3))]
            },
        ]),
        BenchCase(id: "imagekit.xcf", category: .image, fixture: "generated/sample.xcf", target: "png", checks: [
            Check(name: "layers composited (Multiply)") { ctx in
                let r = try raster(ctx.output)
                func at(_ x: Int, _ y: Int) -> [Int] { let i = (y * r.width + x) * 3; return [Int(r.rgb[i]), Int(r.rgb[i + 1]), Int(r.rgb[i + 2])] }
                let centre = at(32, 24), corner = at(2, 2)
                let centreError = abs(centre[0] - 200) + centre[1] + centre[2], cornerError = corner.map { abs($0 - 200) }.reduce(0, +)
                return [Measurement(name: "multiplied centre error", value: Double(centreError), unit: "levels", limit: .atMost(3)),
                        Measurement(name: "background error", value: Double(cornerError), unit: "levels", limit: .atMost(3))]
            },
        ]),
    ]

    static let icons: [BenchCase] = [("ico", [128, 64, 48, 32, 24, 16]), ("icns", [128, 64, 32, 16])].map { (target: FormatID, sizes: [Int]) in
        BenchCase(id: "imagekit.icons-\(target)", category: .image, fixture: "generated/logo-alpha-128.png", target: target, checks: [
            Check(name: "every size up to the source") { ctx in
                let source = try unwrap(CGImageSourceCreateWithURL(try unwrap(ctx.output) as CFURL, nil))
                let found = Set((0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil)?.width })
                return [.exact("sizes missing", Double(Set(sizes).subtracting(found).count), equals: 0)]
            },
        ])
    }

    /// Routes that end in another kit's writer (VectorKit's CGPDF and PSWriter, OfficeKit's ODFWriter, VectorizeKit):
    /// the ImageAsset ImageKit hands over must come out as a valid file. Skipped while the writer is not built.
    static let otherWriters: [BenchCase] = [
        BenchCase(id: "imagekit.writer-pdf", category: .image, fixture: "generated/photo-p3-320.tiff", target: "pdf", checks: [.producesFormat("pdf"), .pdf(pages: 1)]),
        BenchCase(id: "imagekit.writer-eps", category: .image, fixture: "generated/photo-p3-320.tiff", target: "eps", checks: [.producesFormat("eps")]),
        BenchCase(id: "imagekit.writer-odd", category: .image, fixture: "generated/photo-p3-320.tiff", target: "odd", checks: [
            .zipEntryContains("mimetype", ["application/vnd.oasis.opendocument.graphics"]), .zipEntryContains("content.xml", ["draw:image"]),
        ]),
        BenchCase(id: "imagekit.trace-svg", category: .image, fixture: "generated/logo-alpha-128.png", target: "svg", checks: [
            Check(name: "the traced SVG renders like the logo") { ctx in
                let back = await Pipeline.convert(try unwrap(ctx.output), to: "png", options: OptionValues(["width": 128]), into: ctx.work.appendingPathComponent("render"))
                guard case .converted(let result) = back.outcome, let png = result.outputs.first else { throw CheckFailure("SVG → PNG: \(back.outcome)") }
                let a = try raster(ctx.source), b = try raster(png)
                guard a.width == b.width, a.height == b.height, let s = SSIM.ssim(a, b) else { throw CheckFailure("render is \(b.width)x\(b.height)") }
                return [.ssim("ssim vs logo", s.mean, atLeast: 0.95)]
            },
        ]),
    ]

    // MARK: Helpers

    /// The CMYK patches of `cmyk-chart.tiff` (the same formula as `scripts/make-fixtures.swift`).
    static let cmykPatches: [[Double]] = (0..<32).map { (i: Int) -> [Double] in
        let c = Double(i % 4) / 3, m = Double(i / 4 % 4) / 3, y = Double((i * 5) % 7) / 6
        let k: Double = i < 16 ? 0 : Double(i % 3) / 4
        return [c, m, y, k]
    }

    static let colorChecker: [[Int]] = [
        [115, 82, 68], [194, 150, 130], [98, 122, 157], [87, 108, 67], [133, 128, 177], [103, 189, 170],
        [214, 126, 44], [80, 91, 166], [193, 90, 99], [94, 60, 108], [157, 188, 64], [224, 163, 46],
        [56, 61, 150], [70, 148, 73], [175, 54, 60], [231, 199, 31], [187, 86, 149], [8, 133, 161],
        [243, 243, 242], [200, 200, 200], [160, 160, 160], [122, 122, 121], [85, 85, 85], [52, 52, 52]]

    private static func unwrap<T>(_ value: T?) throws -> T { guard let value else { throw CheckFailure("no output") }; return value }

    private static func raster(_ url: URL?) throws -> Raster {
        guard let url, let r = Raster(contentsOf: url) else { throw CheckFailure("\(url?.lastPathComponent ?? "output") cannot be decoded") }
        return r
    }

    /// `r` reduced by 8 × 8 boxes, averaged in linear light.
    private static func blurred(_ r: Raster) throws -> Raster {
        func linear(_ v: UInt8) -> Double { let c = Double(v) / 255; return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func encoded(_ l: Double) -> UInt8 { UInt8((255 * (l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055)).rounded()) }
        let w = r.width / 8, h = r.height / 8
        guard w > 0, h > 0 else { throw CheckFailure("picture too small") }
        var out = [UInt8](repeating: 0, count: w * h * 3)
        for by in 0..<h { for bx in 0..<w { for c in 0..<3 {
            var sum = 0.0
            for y in 0..<8 { for x in 0..<8 { sum += linear(r.rgb[((by * 8 + y) * r.width + bx * 8 + x) * 3 + c]) } }
            out[(by * w + bx) * 3 + c] = encoded(sum / 64)
        } } }
        return Raster(width: w, height: h, rgb: out)
    }

    /// The alpha of `url`'s first image, one byte per pixel, top row first.
    private static func alphaChannel(_ url: URL) throws -> [UInt8] {
        guard let image = firstImage(url) else { throw CheckFailure("\(url.lastPathComponent) cannot be decoded") }
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw CheckFailure("no bitmap context") }
        return (0..<(image.width * image.height)).map { rgba[$0 * 4 + 3] }
    }

    private static func firstImage(_ url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    /// The samples of `url`'s first image in its own colour space and depth (8 or 16 bits), alpha premultiplied.
    private static func samples(_ url: URL) throws -> (model: CGColorSpaceModel, bits: Int, width: Int, values: [UInt16]) {
        guard let image = firstImage(url), let decoded = image.colorSpace else { throw CheckFailure("\(url.lastPathComponent) cannot be decoded") }
        let space = decoded.model == .indexed ? decoded.baseColorSpace ?? decoded : decoded   // palette PNGs compare as their base space
        let bits = image.bitsPerComponent > 8 ? 16 : 8
        let colour = space.numberOfComponents
        let alpha = space.model == .rgb
        let channels = colour + (alpha ? 1 : 0)
        let info = (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.none).rawValue | (bits == 16 ? CGImageByteOrderInfo.order16Little.rawValue : 0)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * channels * bits / 8)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: bits,
                                          bytesPerRow: image.width * channels * bits / 8, space: space, bitmapInfo: info) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw CheckFailure("\(url.lastPathComponent): no bitmap context for its colour space") }
        let values = bits == 16 ? stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 } : bytes.map(UInt16.init)
        return (space.model, bits, image.width, values)
    }

    private static func samplesMatch(_ a: URL, _ b: URL) throws -> [Measurement] {
        let x = try samples(a), y = try samples(b)
        guard x.model == y.model, x.bits == y.bits, x.values.count == y.values.count else {
            throw CheckFailure("layout differs: \(x.model.rawValue)/\(x.bits)-bit vs \(y.model.rawValue)/\(y.bits)-bit")
        }
        return [.exact("samples differing", Double(zip(x.values, y.values).filter { $0 != $1 }.count), equals: 0), .info("bits", Double(x.bits))]
    }

    /// Identical embedded profile bytes, or the same named space (AVIF/HEIC write exact Display P3 as `nclx`, quality §2.2).
    private static func profileKept(_ a: URL, _ b: URL) throws -> Bool {
        guard let sa = firstImage(a)?.colorSpace, let sb = firstImage(b)?.colorSpace else { throw CheckFailure("a picture cannot be decoded") }
        if let da = sa.copyICCData() as Data?, let db = sb.copyICCData() as Data?, da == db { return true }
        return sa.name != nil && sa.name == sb.name
    }

    /// Each patch's centre in the output against ColorSync's relative-colorimetric + BPC transform of the source values.
    @MainActor private static func patchesMatch(_ ctx: CaseContext, source: [[Float]], sourceSpace: CGColorSpace, perRow: Int, size: Int) throws -> [Measurement] {
        let out = try unwrap(ctx.output)
        // The output's own RGB space (CMYK → PNG goes to a wide space so nothing is clipped; the P3 case asks for sRGB).
        guard let decoded = firstImage(out)?.colorSpace, let outSpace = decoded.model == .indexed ? decoded.baseColorSpace : decoded, outSpace.model == .rgb else {
            throw CheckFailure("the output is not RGB")
        }
        // The profile the fixture embeds (the system's copy of a named profile can differ by version).
        let embedded = firstImage(ctx.source)?.colorSpace.flatMap { $0.model == sourceSpace.model ? $0 : nil } ?? sourceSpace
        guard let reference = transform(source, from: embedded, to: outSpace) else { throw CheckFailure("no ColorSync transform") }
        // The output's 8-bit samples against the unrounded reference, both in CIE Lab: what is left is 8-bit quantisation.
        let r = try samples(out)
        guard r.bits == 8 else { throw CheckFailure("expected 8-bit output") }
        var centres: [[Float]] = []
        for n in 0..<source.count {
            let x = (n % perRow) * size + size / 2, y = (n / perRow) * size + size / 2
            let i = (y * r.width + x) * 4
            centres.append((0..<3).map { Float(r.values[i + $0]) / 255 })
        }
        let labSpace = CGColorSpace(name: CGColorSpace.genericLab)!
        guard let la = transform(reference.map { $0.map { min(max($0, 0), 1) } }, from: outSpace, to: labSpace),
              let lb = transform(centres, from: outSpace, to: labSpace) else { throw CheckFailure("no Lab transform") }
        // ColorSync's float Lab: L in 0…1 for 0…100, a and b as value·255 − 127.5 (see DeltaE.lab).
        func lab(_ v: [Float]) -> Lab { Lab(l: Double(v[0]) * 100, a: Double(v[1]) * 255 - 127.5, b: Double(v[2]) * 255 - 127.5) }
        let s = DeltaE.summarise(zip(la, lb).map { DeltaE.ciede2000(lab($0), lab($1)) })
        return [.deltaE("ΔE00 max vs ColorSync", s.max, atMost: 0.5), .info("ΔE00 mean", s.mean)]
    }

    private static func transform(_ colours: [[Float]], from source: CGColorSpace, to target: CGColorSpace) -> [[Float]]? {
        guard let sd = source.copyICCData(), let td = target.copyICCData(), let sp = ColorSyncProfileCreate(sd, nil)?.takeRetainedValue(),
              let tp = ColorSyncProfileCreate(td, nil)?.takeRetainedValue() else { return nil }
        func entry(_ p: ColorSyncProfile, _ tag: CFString) -> [String: Any] {
            [kColorSyncProfile.takeUnretainedValue() as String: p,
             kColorSyncRenderingIntent.takeUnretainedValue() as String: kColorSyncRenderingIntentRelative.takeUnretainedValue(),
             kColorSyncTransformTag.takeUnretainedValue() as String: tag, kColorSyncBlackPointCompensation.takeUnretainedValue() as String: kCFBooleanTrue!]
        }
        guard let t = ColorSyncTransformCreate([entry(sp, kColorSyncTransformDeviceToPCS.takeUnretainedValue()),
                                                entry(tp, kColorSyncTransformPCSToDevice.takeUnretainedValue())] as CFArray, nil)?.takeRetainedValue() else { return nil }
        let inN = colours[0].count, outN = target.numberOfComponents
        let input = colours.flatMap { $0 }
        var output = [Float](repeating: 0, count: colours.count * outN)
        let layout = ColorSyncDataLayout(UInt32(kColorSyncByteOrderDefault) | kColorSyncAlphaNone.rawValue)
        input.withUnsafeBytes { i in output.withUnsafeMutableBytes { o in
            _ = ColorSyncTransformConvert(t, colours.count, 1, o.baseAddress!, kColorSync32BitFloat, layout, colours.count * outN * 4,
                                          i.baseAddress!, kColorSync32BitFloat, layout, colours.count * inN * 4, nil)
        } }
        return (0..<colours.count).map { Array(output[($0 * outN)..<(($0 + 1) * outN)]) }
    }

    private static func hasGainMap(_ url: URL) -> Bool {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        if #available(macOS 15, *), CGImageSourceCopyAuxiliaryDataInfoAtIndex(s, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil { return true }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(s, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }

    /// CIToneMapHeadroom (target headroom 1.0) of ImageIO's HDR rendition, rendered into `space` — quality §2.2's reference.
    private static func toneMapReference(_ url: URL, space: CGColorSpace) -> CGImage? {
        guard #available(macOS 15, *), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let hdr = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary),
              let linear = CGColorSpaceCreateExtendedLinearized(CGColorSpace(name: CGColorSpace.displayP3)!) else { return nil }
        let ci = CIImage(cgImage: hdr, options: [.expandToHDR: true])
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf])
        guard let extended = context.createCGImage(ci, from: ci.extent, format: .RGBAf, colorSpace: linear), let filter = CIFilter(name: "CIToneMapHeadroom") else { return nil }
        var headroom: Float = 1
        if let data = extended.dataProvider?.data, let bytes = CFDataGetBytePtr(data) {
            let floats = UnsafeRawPointer(bytes).assumingMemoryBound(to: Float.self)
            for i in 0..<(extended.width * extended.height * 4) where i % 4 != 3 { headroom = max(headroom, floats[i]) }
        }
        filter.setValue(CIImage(cgImage: extended), forKey: kCIInputImageKey)
        filter.setValue(headroom, forKey: "inputSourceHeadroom")
        filter.setValue(1.0, forKey: "inputTargetHeadroom")
        guard let mapped = filter.outputImage else { return nil }
        return context.createCGImage(mapped, from: ci.extent, format: .RGBA8, colorSpace: space)
    }

    /// Frame count and total duration of an animated file (GIF or WebP).
    private static func animation(_ url: URL) throws -> (Int, Double) {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CheckFailure("cannot read \(url.lastPathComponent)") }
        var total = 0.0
        for i in 0..<CGImageSourceGetCount(s) {
            let p = CGImageSourceCopyPropertiesAtIndex(s, i, nil) as? [CFString: Any] ?? [:]
            let gif = p[kCGImagePropertyGIFDictionary] as? [CFString: Any], webp = p[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            total += (gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]
                      ?? webp?[kCGImagePropertyWebPUnclampedDelayTime] ?? webp?[kCGImagePropertyWebPDelayTime]) as? Double ?? 0
        }
        return (CGImageSourceGetCount(s), total)
    }
}
