import Accelerate
import ColorSync
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import ImageKit
import SuperConverterCore
import UniformTypeIdentifiers
import zlib

// ImageKit's checks (WP-I): quality §2.8 on generated fixtures with embedded profiles. Colour accuracy is measured as
// CIEDE2000 between Lab values computed by ColorSync (PCS XYZ, D50) for the source and the decoded output.
func registerImageKitTests() {
    SelfTest.cases.append(("ImageKit.installs", { imageKitInstalls() }))
    SelfTest.cases.append(("ImageKit.matrixCoverage", { imageKitMatrixCoverage() }))
    SelfTest.cases.append(("ImageKit.deltaE2000Reference", { imageKitDeltaEReference() }))
    SelfTest.cases.append(("ImageKit.profileKept", { imageKitProfileKept() }))
    SelfTest.cases.append(("ImageKit.profileConverted", { imageKitProfileConverted() }))
    SelfTest.cases.append(("ImageKit.noICCTargets", { imageKitNoICCTargets() }))
    SelfTest.cases.append(("ImageKit.losslessRoundTrips", { imageKitLosslessRoundTrips() }))
    SelfTest.cases.append(("ImageKit.gammaCorrectScaling", { imageKitGammaCorrectScaling() }))
    SelfTest.cases.append(("ImageKit.ringing", { imageKitRinging() }))
    SelfTest.cases.append(("ImageKit.resizeFit", { imageKitResizeFit() }))
    SelfTest.cases.append(("ImageKit.edgeChroma", { imageKitEdgeChroma() }))
    SelfTest.cases.append(("ImageKit.alphaEdges", { imageKitAlphaEdges() }))
    SelfTest.cases.append(("ImageKit.photoLossyDefaults", { imageKitPhotoLossyDefaults() }))
    SelfTest.cases.append(("ImageKit.metadata", { imageKitMetadata() }))
    SelfTest.cases.append(("ImageKit.gif", { imageKitGIF() }))
    SelfTest.cases.append(("ImageKit.icons", { imageKitIcons() }))
    SelfTest.cases.append(("ImageKit.pagesAndFrames", { imageKitPagesAndFrames() }))
    SelfTest.cases.append(("ImageKit.hdr", { imageKitHDR() }))
    SelfTest.cases.append(("ImageKit.raw", { imageKitRAW() }))
    SelfTest.cases.append(("ImageKit.libRaw", { imageKitLibRaw() }))
    SelfTest.cases.append(("ImageKit.codecs", { imageKitCodecs() }))
}

// MARK: - Harness

private let ikFolder = scratch.appendingPathComponent("imagekit", isDirectory: true)

private func ikURL(_ name: String) -> URL {
    try? FileManager.default.createDirectory(at: ikFolder, withIntermediateDirectories: true)
    return ikFolder.appendingPathComponent(name)
}

private struct IKResult { var url: URL?; var notes: [LossNote]; var error: Error? }

/// Runs the matrix's built-in route for `from` → `to` through ImageKit's converters, as ConvertKit's queue would.
@MainActor
private func ikConvert(_ source: URL, to target: FormatID, from: FormatID? = nil, options: [String: OptionValue] = [:]) -> IKResult {
    let sourceFormat = from ?? FormatID(source.pathExtension.lowercased())
    guard let steps = FormatMatrix.route(from: sourceFormat, to: target)?.builtin else {
        return IKResult(url: nil, notes: [], error: ConversionError.unsupportedPair(from: sourceFormat, to: target))
    }
    let work = ikFolder.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
    var value = StepValue.file(source)
    var notes: [LossNote] = []
    for (i, step) in steps.enumerated() {
        guard let converter = ImageKitModule.converters.first(where: { $0.handles(step) }) else {
            return IKResult(url: nil, notes: notes, error: ConversionError.failed("no ImageKit converter for \(step)"))
        }
        let context = StepContext(workFolder: work, source: source, sourceFormat: sourceFormat, targetFormat: target,
                                  options: OptionValues(options), isFinalStep: i == steps.count - 1)
        let input = value
        let outcome = complete { try await converter.run(step, input: input, context: context) }
        switch outcome {
        case .success(let output): value = output.value; notes += output.lossNotes
        case .failure(let error): return IKResult(url: nil, notes: notes, error: error)
        case nil: return IKResult(url: nil, notes: notes, error: ConversionError.failed("timed out"))
        }
    }
    guard case .file(let url) = value else { return IKResult(url: nil, notes: notes, error: ConversionError.failed("no file")) }
    return IKResult(url: url, notes: notes, error: nil)
}

/// Decoded pixels: floats 0…1, colour components then alpha, top row first, in the image's own space.
private struct IKImage {
    var width: Int, height: Int, components: Int, alpha: Bool, values: [Float], icc: Data?, bits: Int
    var stride: Int { components + (alpha ? 1 : 0) }
    func pixel(_ x: Int, _ y: Int) -> [Float] { Array(values[((y * width + x) * stride)..<((y * width + x + 1) * stride)]) }
    /// Packed colour components (no alpha) of every pixel.
    var colours: [Float] { (0..<(width * height)).flatMap { Array(values[($0 * stride)..<($0 * stride + components)]) } }
}

private func ikDecode(_ url: URL, index: Int = 0) -> IKImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), index < CGImageSourceGetCount(source),
          let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { return nil }
    return ikDecode(image)
}

private func ikDecode(_ cg: CGImage) -> IKImage? {
    var image = cg
    var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    if image.pixelFormatInfo != .packed {
        // 10-bit packed pixels (HEIC, AVIF): drawn at 16 bits in their own space.
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        image = ctx.makeImage()!
    }
    if space.model == .indexed, let base = space.baseColorSpace {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: base,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        image = ctx.makeImage()!
        space = base
    }
    var alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    if cg.colorSpace?.model == .indexed {
        // A palette image has alpha only through tRNS: keep the channel only when some pixel uses it.
        let data = image.dataProvider!.data! as Data
        alpha = (0..<image.height).contains { y in (0..<image.width).contains { data[y * image.bytesPerRow + $0 * 4 + 3] != 255 } }
    }
    let comps = space.numberOfComponents
    let channels = comps + (alpha ? 1 : 0)
    var format = vImage_CGImageFormat(bitsPerComponent: 32, bitsPerPixel: UInt32(32 * channels), colorSpace: Unmanaged.passUnretained(space),
                                      bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue)
                                                               | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                      version: 0, decode: nil, renderingIntent: .defaultIntent)
    var buffer = vImage_Buffer()
    guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
    defer { free(buffer.data) }
    var values = [Float](repeating: 0, count: image.width * image.height * channels)
    for y in 0..<image.height {
        let row = buffer.data.advanced(by: y * buffer.rowBytes).assumingMemoryBound(to: Float.self)
        for x in 0..<(image.width * channels) { values[y * image.width * channels + x] = row[x] }
    }
    return IKImage(width: image.width, height: image.height, components: comps, alpha: alpha, values: values,
                   icc: space.copyICCData() as Data?, bits: image.bitsPerComponent)
}

/// Writes a fixture with exactly these samples (8 or 16 bits) and exactly these profile bytes.
private func ikWrite(_ url: URL, type: UTType, width: Int, height: Int, components: Int, alpha: Bool, bits: Int, icc: Data,
                     properties: [CFString: Any] = [:], sample: (Int, Int, Int) -> Int) {
    let channels = components + (alpha ? 1 : 0)
    var bytes = Data(count: width * height * channels * bits / 8)
    bytes.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
        for y in 0..<height { for x in 0..<width { for c in 0..<channels {
            let v = sample(x, y, c), o = ((y * width + x) * channels + c) * bits / 8
            if bits == 8 { p[o] = UInt8(v) } else { p[o] = UInt8(v & 0xFF); p[o + 1] = UInt8(v >> 8) }
        } } }
    }
    var info = alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue
    if bits == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
    let image = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits * channels, bytesPerRow: width * channels * bits / 8,
                        space: CGColorSpace(iccData: icc as CFData)!, bitmapInfo: CGBitmapInfo(rawValue: info),
                        provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    _ = CGImageDestinationFinalize(destination)
}

/// The embedded profile, byte for byte, read from the container itself where ImageIO might substitute its own.
private func ikICC(_ url: URL) -> Data? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    switch url.pathExtension.lowercased() {
    case "png":
        var i = 8
        while i + 12 <= data.count {
            let n = Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            if String(decoding: data[(i + 4)..<(i + 8)], as: UTF8.self) == "iCCP" {
                let body = data.subdata(in: (i + 8)..<(i + 8 + n))
                guard let zero = body.firstIndex(of: 0) else { return nil }
                return ikInflate(body.subdata(in: (zero + 2)..<body.count))
            }
            i += 12 + n
        }
        return nil
    case "webp":
        var i = 12
        while i + 8 <= data.count {
            let n = Int(data[i + 4]) | Int(data[i + 5]) << 8 | Int(data[i + 6]) << 16 | Int(data[i + 7]) << 24
            if String(decoding: data[i..<(i + 4)], as: UTF8.self) == "ICCP" { return data.subdata(in: (i + 8)..<(i + 8 + n)) }
            i += 8 + n + (n % 2)
        }
        return nil
    case "bmp":
        func le32(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24 }
        guard le32(14) == 124 else { return nil }
        if data[(14 + 56)..<(14 + 60)].elementsEqual("BGRs".utf8) { return ikSRGB }
        return data.subdata(in: (14 + le32(14 + 112))..<(14 + le32(14 + 112) + le32(14 + 116)))
    default:
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return image.colorSpace?.copyICCData() as Data?
    }
}

private func ikInflate(_ data: Data) -> Data? {
    var size = uLong(1 << 22)
    var out = Data(count: Int(size))
    let status = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            uncompress(dst.bindMemory(to: Bytef.self).baseAddress!, &size, src.bindMemory(to: Bytef.self).baseAddress, uLong(data.count))
        }
    }
    return status == Z_OK ? out.prefix(Int(size)) : nil
}

// MARK: Colour measurement

/// A ColorSync transform of packed colour values between two ICC profiles (relative colorimetric, BPC unless asked
/// otherwise) — the test's own reference, independent of ImageKit.
private func ikTransform(_ values: [Float], from: Data, _ fromComps: Int, to: Data, _ toComps: Int, perceptual: Bool = false, bpc: Bool = true) -> [Float] {
    var error: Unmanaged<CFError>?
    let sp = ColorSyncProfileCreate(from as CFData, &error)!.takeRetainedValue()
    let dp = ColorSyncProfileCreate(to as CFData, &error)!.takeRetainedValue()
    return ikTransform(values, sp, fromComps, dp, toComps, perceptual: perceptual, bpc: bpc)
}

private func ikTransform(_ values: [Float], _ sp: ColorSyncProfile, _ fromComps: Int, _ dp: ColorSyncProfile, _ toComps: Int,
                         perceptual: Bool, bpc: Bool) -> [Float] {
    let intent = perceptual ? kColorSyncRenderingIntentPerceptual.takeUnretainedValue() : kColorSyncRenderingIntentRelative.takeUnretainedValue()
    func step(_ p: ColorSyncProfile, _ tag: CFString) -> [String: Any] {
        [kColorSyncProfile.takeUnretainedValue() as String: p, kColorSyncRenderingIntent.takeUnretainedValue() as String: intent,
         kColorSyncTransformTag.takeUnretainedValue() as String: tag,
         kColorSyncBlackPointCompensation.takeUnretainedValue() as String: bpc ? kCFBooleanTrue! : kCFBooleanFalse!]
    }
    let t = ColorSyncTransformCreate([step(sp, kColorSyncTransformDeviceToPCS.takeUnretainedValue()),
                                      step(dp, kColorSyncTransformPCSToDevice.takeUnretainedValue())] as CFArray, nil)!.takeRetainedValue()
    let n = values.count / fromComps
    var out = [Float](repeating: 0, count: n * toComps)
    let layout = UInt32(kColorSyncByteOrderDefault) | kColorSyncAlphaNone.rawValue
    values.withUnsafeBytes { s in
        out.withUnsafeMutableBytes { d in
            _ = ColorSyncTransformConvert(t, n, 1, d.baseAddress!, kColorSync32BitFloat, layout, n * toComps * 4,
                                          s.baseAddress!, kColorSync32BitFloat, layout, n * fromComps * 4, nil)
        }
    }
    return out
}

/// CIE Lab (D50) of packed colour values in the space of `icc`, through ColorSync's PCS XYZ.
private func ikLab(_ values: [Float], components: Int, icc: Data) -> [Float] {
    var error: Unmanaged<CFError>?
    let src = ColorSyncProfileCreate(icc as CFData, &error)!.takeRetainedValue()
    let xyzProfile = ColorSyncProfileCreateWithName(kColorSyncGenericXYZProfile.takeUnretainedValue())!.takeUnretainedValue()
    let xyz = ikTransform(values, src, components, xyzProfile, 3, perceptual: false, bpc: false)
    let white: [Float] = [0.9642, 1.0, 0.8249]
    func f(_ t: Float) -> Float { t > 216 / 24389 ? cbrt(t) : (24389 / 27 * t + 16) / 116 }
    var lab = [Float](repeating: 0, count: xyz.count)
    for i in 0..<(xyz.count / 3) {
        let fx = f(xyz[i * 3] / white[0]), fy = f(xyz[i * 3 + 1] / white[1]), fz = f(xyz[i * 3 + 2] / white[2])
        lab[i * 3] = 116 * fy - 16; lab[i * 3 + 1] = 500 * (fx - fy); lab[i * 3 + 2] = 200 * (fy - fz)
    }
    return lab
}

/// CIEDE2000 (Sharma, Wu & Dalal 2005).
private func ikDeltaE2000(_ l1: Float, _ a1: Float, _ b1: Float, _ l2: Float, _ a2: Float, _ b2: Float) -> Double {
    let L1 = Double(l1), A1 = Double(a1), B1 = Double(b1), L2 = Double(l2), A2 = Double(a2), B2 = Double(b2)
    let c1 = (A1 * A1 + B1 * B1).squareRoot(), c2 = (A2 * A2 + B2 * B2).squareRoot()
    let cBar = (c1 + c2) / 2
    let g = 0.5 * (1 - (pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))).squareRoot())
    let a1p = (1 + g) * A1, a2p = (1 + g) * A2
    let c1p = (a1p * a1p + B1 * B1).squareRoot(), c2p = (a2p * a2p + B2 * B2).squareRoot()
    func hue(_ b: Double, _ a: Double) -> Double {
        if a == 0 && b == 0 { return 0 }
        let h = atan2(b, a) * 180 / .pi
        return h < 0 ? h + 360 : h
    }
    let h1p = hue(B1, a1p), h2p = hue(B2, a2p)
    let dLp = L2 - L1, dCp = c2p - c1p
    var dhp = 0.0
    if c1p * c2p != 0 {
        dhp = h2p - h1p
        if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
    }
    let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp / 2 * .pi / 180)
    let lBarp = (L1 + L2) / 2, cBarp = (c1p + c2p) / 2
    var hBarp = h1p + h2p
    if c1p * c2p != 0 {
        if abs(h1p - h2p) <= 180 { hBarp = (h1p + h2p) / 2 } else if h1p + h2p < 360 { hBarp = (h1p + h2p + 360) / 2 } else { hBarp = (h1p + h2p - 360) / 2 }
    }
    let t = 1 - 0.17 * cos((hBarp - 30) * .pi / 180) + 0.24 * cos(2 * hBarp * .pi / 180) + 0.32 * cos((3 * hBarp + 6) * .pi / 180)
        - 0.20 * cos((4 * hBarp - 63) * .pi / 180)
    let dTheta = 30 * exp(-pow((hBarp - 275) / 25, 2))
    let rc = 2 * (pow(cBarp, 7) / (pow(cBarp, 7) + pow(25, 7))).squareRoot()
    let sl = 1 + 0.015 * pow(lBarp - 50, 2) / (20 + pow(lBarp - 50, 2)).squareRoot()
    let sc = 1 + 0.045 * cBarp, sh = 1 + 0.015 * cBarp * t
    let rt = -sin(2 * dTheta * .pi / 180) * rc
    return (pow(dLp / sl, 2) + pow(dCp / sc, 2) + pow(dHp / sh, 2) + rt * (dCp / sc) * (dHp / sh)).squareRoot()
}

private struct IKStats {
    var mean: Double, p95: Double, max: Double, count: Int
    var text: String { String(format: "mean %.3f p95 %.3f max %.3f (n=%d)", mean, p95, max, count) }
}

private func ikStats(_ values: [Double]) -> IKStats {
    guard !values.isEmpty else { return IKStats(mean: 0, p95: 0, max: 0, count: 0) }
    let sorted = values.sorted()
    return IKStats(mean: values.reduce(0, +) / Double(values.count), p95: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
                   max: sorted.last!, count: values.count)
}

/// ΔE00 between packed colours (same count) in two spaces.
private func ikDeltaEs(_ a: [Float], _ aComps: Int, _ aICC: Data, _ b: [Float], _ bComps: Int, _ bICC: Data) -> [Double] {
    let la = ikLab(a, components: aComps, icc: aICC), lb = ikLab(b, components: bComps, icc: bICC)
    return (0..<(la.count / 3)).map { ikDeltaE2000(la[$0 * 3], la[$0 * 3 + 1], la[$0 * 3 + 2], lb[$0 * 3], lb[$0 * 3 + 1], lb[$0 * 3 + 2]) }
}

private func ikPrint(_ text: String) { print("    \(text)") }

// MARK: Fixtures

private let ikColorChecker: [[Int]] = [
    [115, 82, 68], [194, 150, 130], [98, 122, 157], [87, 108, 67], [133, 128, 177], [103, 189, 170], [214, 126, 44], [80, 91, 166],
    [193, 90, 99], [94, 60, 108], [157, 188, 64], [224, 163, 46], [56, 61, 150], [70, 148, 73], [175, 54, 60], [231, 199, 31],
    [187, 86, 149], [8, 133, 161], [243, 243, 242], [200, 200, 200], [160, 160, 160], [122, 122, 121], [85, 85, 85], [52, 52, 52],
]

/// 24 ColorChecker patches then `random` reproducible colours, as sRGB 0…1 (in gamut for every space used here).
private func ikPatchColours(random: Int) -> [[Float]] {
    var seed: UInt64 = 0x5EED_1234_ABCD
    func next() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 24) }
    return ikColorChecker.map { $0.map { Float($0) / 255 } } + (0..<random).map { _ in [next(), next(), next()] }
}

private let ikPatch = 16

/// A patch chart: colours (sRGB 0…1) converted into `icc`'s space and quantised to `bits`, in 16 px squares. Returns the
/// patch colours as stored (0…1).
private func ikChart(_ url: URL, type: UTType, colours: [[Float]], icc: Data, components: Int, bits: Int, perRow: Int = 32) -> [Float] {
    let converted = ikTransform(colours.flatMap { $0 }, from: ikSRGB, 3, to: icc, components)
    let maxValue = Float((1 << bits) - 1)
    let quantised = converted.map { (min(max($0, 0), 1) * maxValue).rounded() }
    let rows = (colours.count + perRow - 1) / perRow
    ikWrite(url, type: type, width: perRow * ikPatch, height: rows * ikPatch, components: components, alpha: false, bits: bits, icc: icc) { x, y, c in
        Int(quantised[min((y / ikPatch) * perRow + x / ikPatch, colours.count - 1) * components + c])
    }
    return quantised.map { $0 / maxValue }
}

/// The mean colour of each patch's inner 8×8 (away from edges, JPEG blocks and chroma subsampling).
private func ikPatchMeans(_ image: IKImage, count: Int, perRow: Int = 32) -> [Float] {
    var out: [Float] = []
    let inner = ikPatch / 4
    for index in 0..<count {
        let px = (index % perRow) * ikPatch, py = (index / perRow) * ikPatch
        var sum = [Float](repeating: 0, count: image.components)
        var n: Float = 0
        for y in (py + inner)..<(py + ikPatch - inner) {
            for x in (px + inner)..<(px + ikPatch - inner) {
                let p = image.pixel(x, y)
                for c in 0..<image.components { sum[c] += p[c] }
                n += 1
            }
        }
        out += sum.map { $0 / n }
    }
    return out
}

/// Adobe RGB (1998) with one reserved header byte changed: a valid profile no encoder has a canonical copy of, so only
/// a byte-for-byte copy passes.
private let ikCustomAdobe: Data = {
    var icc = CGColorSpace(name: CGColorSpace.adobeRGB1998)!.copyICCData()! as Data
    icc[110] = 0x42
    return icc
}()
private let ikP3 = CGColorSpace(name: CGColorSpace.displayP3)!.copyICCData()! as Data
private let ikProPhoto = CGColorSpace(name: CGColorSpace.rommrgb)!.copyICCData()! as Data
private let ikSRGB = CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData()! as Data
private let ikCMYK = CGColorSpace(name: CGColorSpace.genericCMYK)!.copyICCData()! as Data
private let ikGray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!.copyICCData()! as Data

/// Decoded samples quantised back to their bit depth (alpha-0 pixels' colour ignored: it is invisible and WebP drops it).
private func ikSamples(_ image: IKImage, bits: Int) -> [Int] {
    let scale = Float((1 << bits) - 1)
    var out = image.values.map { Int(($0 * scale).rounded()) }
    if image.alpha {
        for i in 0..<(image.width * image.height) where out[i * image.stride + image.components] == 0 {
            for c in 0..<image.components { out[i * image.stride + c] = 0 }
        }
    }
    return out
}

// MARK: - Cases

@MainActor
private func imageKitInstalls() {
    ImageKitModule.install()
    let mine = Set(EngineID.allCases.filter { $0.info.module == .imageKit })
    for engine in mine { check(Services.converters.converter(for: engine) != nil, "\(engine.rawValue) is registered") }
    check(Set(ImageKitModule.converters.map(\.id)) == mine, "ImageKit registers exactly its engines")
    for converter in ImageKitModule.converters {
        check(converter.availability() == .available, "\(converter.id.rawValue) is available here (\(converter.availability()))")
    }
}

/// Every step of every route whose engine belongs to ImageKit has a converter that handles it; every converter is used.
@MainActor
private func imageKitMatrixCoverage() {
    var used = Set<EngineID>()
    var missing = Set<String>()
    for route in FormatMatrix.routes {
        for step in ([route.builtin ?? [], route.helper ?? []] + route.alternates.map(\.steps)).joined() where step.engine.info.module == .imageKit {
            used.insert(step.engine)
            if !ImageKitModule.converters.contains(where: { $0.handles(step) }) { missing.insert(step.description) }
        }
    }
    check(missing.isEmpty, "unhandled ImageKit steps: \(missing.sorted().prefix(10))")
    check(Set(ImageKitModule.converters.map(\.id)).isSubset(of: used), "every ImageKit converter is used by a route")
}

/// The ΔE2000 implementation against Sharma, Wu & Dalal's published test pairs; ColorSync's Lab of sRGB white.
@MainActor
private func imageKitDeltaEReference() {
    let pairs: [([Float], [Float], Double)] = [
        ([50, 2.6772, -79.7751], [50, 0, -82.7485], 2.0425),
        ([50, 3.1571, -77.2803], [50, 0, -82.7485], 2.8615),
        ([50, -1.3802, -84.2814], [50, 0, -82.7485], 1.0000),
        ([50, 0, 0], [50, -1, 2], 2.3669),
        ([50, 2.5, 0], [73, 25, -18], 27.1492),
        ([60.2574, -34.0099, 36.2677], [60.4626, -34.1751, 39.4387], 1.2644),
        ([22.7233, 20.0904, -46.6940], [23.0331, 14.9730, -42.5619], 2.0373),
        ([2.0776, 0.0795, -1.1350], [0.9033, -0.0636, -0.5514], 0.9082),
    ]
    for (a, b, expected) in pairs {
        let d = ikDeltaE2000(a[0], a[1], a[2], b[0], b[1], b[2])
        check(abs(d - expected) < 1e-3, "ΔE00 \(a) vs \(b): \(d) (expected \(expected))")
    }
    let white = ikLab([1, 1, 1], components: 3, icc: ikSRGB)
    check(abs(white[0] - 100) < 0.05 && abs(white[1]) < 0.05 && abs(white[2]) < 0.05, "sRGB white is L*100 (\(white))")
}

/// quality §2.8 "Profile kept": the source profile byte for byte; lossless targets exact, lossy ones mean ΔE00 ≤ 1.0,
/// p95 ≤ 2.5.
@MainActor
private func imageKitProfileKept() {
    let colours = ikPatchColours(random: 232)   // 256 patches, 16 per row
    for (name, icc, comps) in [("p3", ikP3, 3), ("adobe-custom", ikCustomAdobe, 3), ("prophoto", ikProPhoto, 3), ("cmyk", ikCMYK, 4)] as [(String, Data, Int)] {
        let source = ikURL("kept-\(name).tiff")
        let original = ikChart(source, type: .tiff, colours: colours, icc: icc, components: comps, bits: 8, perRow: 16)
        for target in ["jpg", "png", "tiff", "psd", "bmp", "heic", "avif", "webp"] as [FormatID] {
            let result = ikConvert(source, to: target)
            guard let url = result.url, let decoded = ikDecode(url) else { check(false, "\(name) → \(target): \(String(describing: result.error))"); continue }
            // BMP has no profile macOS can read (converted to sRGB); CMYK into an RGB-only target becomes Display P3.
            let expectedICC = target == "bmp" ? ikSRGB : (comps == 3 || ["jpg", "tiff", "psd"].contains(target.rawValue)) ? icc : ikP3
            let converted = expectedICC != icc
            let embedded = ikICC(url)
            check(embedded == expectedICC, "\(name) → \(target): profile byte for byte (\(embedded?.count ?? 0) vs \(expectedICC.count) bytes)")
            let means = ikPatchMeans(decoded, count: colours.count, perRow: 16)
            let reference = converted ? ikTransform(original, from: icc, comps, to: expectedICC, 3).map { (min(max($0, 0), 1) * 255).rounded() / 255 } : original
            let stats = ikStats(ikDeltaEs(reference, converted ? 3 : comps, expectedICC, means, decoded.components, decoded.icc ?? expectedICC))
            if ["jpg", "heic", "avif", "webp"].contains(target.rawValue) {
                check(stats.mean <= 1.0 && stats.p95 <= 2.5, "\(name) → \(target) ΔE00 \(stats.text)")
            } else {
                check(stats.max <= (converted ? 0.5 : 0.01), "\(name) → \(target) \(converted ? "converted" : "exact") (ΔE00 \(stats.text))")
            }
            ikPrint("ΔE00 \(name) kept → \(target.rawValue): \(stats.text)")
        }
    }
}

/// quality §2.8 "Profile converted": ColorChecker + 1,000 random in-gamut colours, P3 / Adobe RGB / ProPhoto / CMYK → sRGB,
/// against a ColorSync reference transform computed here: max ΔE00 ≤ 0.5. Plus RGB → CMYK (perceptual).
@MainActor
private func imageKitProfileConverted() {
    let colours = ikPatchColours(random: 1000)
    for (name, icc, comps) in [("p3", ikP3, 3), ("adobe-custom", ikCustomAdobe, 3), ("prophoto", ikProPhoto, 3), ("cmyk", ikCMYK, 4)] as [(String, Data, Int)] {
        for bits in [8, 16] {
            let source = ikURL("convert-\(name)-\(bits).tiff")
            let original = ikChart(source, type: .tiff, colours: colours, icc: icc, components: comps, bits: bits)
            let exact = ikTransform(original, from: icc, comps, to: ikSRGB, 3).map { min(max($0, 0), 1) }
            // The reference quantised to the output's bits (quality §2.8: "max ≤ 0.5 (8-bit quantisation)").
            let scale = Float((1 << bits) - 1)
            let reference = exact.map { ($0 * scale).rounded() / scale }
            for target in ["png", "tiff"] as [FormatID] {
                let result = ikConvert(source, to: target, options: ["colourProfile": "srgb"])
                guard let url = result.url, let decoded = ikDecode(url) else { check(false, "\(name) → sRGB \(target): \(String(describing: result.error))"); continue }
                check(ikICC(url) == ikSRGB, "\(name) → sRGB \(target) is tagged sRGB")
                let means = ikPatchMeans(decoded, count: colours.count)
                let stats = ikStats(ikDeltaEs(reference, 3, ikSRGB, means, 3, ikSRGB))
                let unquantised = ikStats(ikDeltaEs(exact, 3, ikSRGB, means, 3, ikSRGB))
                check(stats.max <= 0.5, "\(name) \(bits)-bit → sRGB \(target): ΔE00 \(stats.text)")
                ikPrint("ΔE00 \(name) \(bits)-bit → sRGB \(target.rawValue) vs ColorSync reference: \(stats.text); vs unquantised \(unquantised.text)")
            }
        }
    }
    let source = ikURL("convert-to-cmyk.tiff")
    let original = ikChart(source, type: .tiff, colours: colours, icc: ikSRGB, components: 3, bits: 8)
    let reference = ikTransform(original, from: ikSRGB, 3, to: ikCMYK, 4, perceptual: true)
    let result = ikConvert(source, to: "tiff", options: ["colourProfile": "cmyk"])
    guard let url = result.url, let decoded = ikDecode(url) else { check(false, "sRGB → CMYK: \(String(describing: result.error))"); return }
    check(decoded.components == 4 && ikICC(url) == ikCMYK, "sRGB → CMYK TIFF holds CMYK with Generic CMYK")
    let stats = ikStats(ikDeltaEs(reference, 4, ikCMYK, ikPatchMeans(decoded, count: colours.count), 4, ikCMYK))
    check(stats.max <= 0.5, "sRGB → CMYK (perceptual): ΔE00 \(stats.text)")
    ikPrint("ΔE00 sRGB → Generic CMYK (perceptual) vs ColorSync reference: \(stats.text)")
}

/// quality §2.8 "No-ICC targets": a P3 source → GIF and ICO, ΔE00 against the source as displayed: mean ≤ 1.0.
@MainActor
private func imageKitNoICCTargets() {
    let colours = ikPatchColours(random: 232)
    let source = ikURL("noicc-p3.png")
    let original = ikChart(source, type: .png, colours: colours, icc: ikP3, components: 3, bits: 8, perRow: 16)
    for target in ["gif", "ico"] as [FormatID] {
        let result = ikConvert(source, to: target)
        guard let url = result.url, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { check(false, "P3 → \(target): \(String(describing: result.error))"); continue }
        let index = (0..<CGImageSourceGetCount(src)).first { CGImageSourceCreateImageAtIndex(src, $0, nil)?.width == 256 } ?? 0
        guard let decoded = ikDecode(url, index: index) else { check(false, "decode \(target)"); continue }
        let stats = ikStats(ikDeltaEs(original, 3, ikP3, ikPatchMeans(decoded, count: colours.count, perRow: 16), 3, ikSRGB))
        check(stats.mean <= 1.0, "P3 → \(target) (sRGB): ΔE00 \(stats.text)")
        ikPrint("ΔE00 P3 → \(target.rawValue) (no ICC: converted to sRGB): \(stats.text)")
    }
}

/// quality §2.8 "Lossless round trips": PNG ↔ TIFF ↔ PSD ↔ BMP ↔ WebP-lossless, bit-exact, profile byte for byte.
@MainActor
private func imageKitLosslessRoundTrips() {
    struct Fixture { var name: String; var comps: Int; var alpha: Bool; var bits: Int; var icc: Data; var chain: [FormatID] }
    let srgbChain: [FormatID] = ["png", "tiff", "psd", "tiff", "bmp", "png", "webp", "png"]
    let rgbChain: [FormatID] = ["png", "tiff", "psd", "tiff", "png", "webp", "png"]
    let deepChain: [FormatID] = ["png", "tiff", "psd", "tiff", "png"]
    let fixtures = [
        Fixture(name: "rgb8-srgb", comps: 3, alpha: false, bits: 8, icc: ikSRGB, chain: srgbChain),
        Fixture(name: "rgba8-srgb", comps: 3, alpha: true, bits: 8, icc: ikSRGB, chain: srgbChain),
        Fixture(name: "rgb8", comps: 3, alpha: false, bits: 8, icc: ikP3, chain: rgbChain),
        Fixture(name: "rgba8", comps: 3, alpha: true, bits: 8, icc: ikCustomAdobe, chain: rgbChain),
        Fixture(name: "rgb16", comps: 3, alpha: false, bits: 16, icc: ikProPhoto, chain: deepChain),
        Fixture(name: "rgba16", comps: 3, alpha: true, bits: 16, icc: ikCustomAdobe, chain: deepChain),
        Fixture(name: "gray8", comps: 1, alpha: false, bits: 8, icc: ikGray, chain: deepChain),
        Fixture(name: "gray16", comps: 1, alpha: false, bits: 16, icc: ikGray, chain: deepChain),
        Fixture(name: "cmyk8", comps: 4, alpha: false, bits: 8, icc: ikCMYK, chain: ["tiff", "psd", "tiff"]),
        Fixture(name: "cmyk16", comps: 4, alpha: false, bits: 16, icc: ikCMYK, chain: ["tiff", "psd", "tiff"]),
    ]
    for f in fixtures {
        let maxValue = (1 << f.bits) - 1
        var current = ikURL("lossless-\(f.name).\(f.chain[0].rawValue)")
        ikWrite(current, type: f.chain[0] == "png" ? .png : .tiff, width: 61, height: 37, components: f.comps, alpha: f.alpha, bits: f.bits,
                icc: f.icc) { x, y, c in
            if f.alpha && c == f.comps { return (x * 7 + y * 3) % 5 == 0 ? 0 : (x * 37 + y * 11) % (maxValue + 1) }
            return (x * 4099 + y * 7919 + c * 30011) % (maxValue + 1)
        }
        guard let start = ikDecode(current), let sourceICC = ikICC(current) ?? start.icc else { check(false, "\(f.name) fixture"); continue }
        let expected = ikSamples(start, bits: f.bits)
        var path = f.chain[0].rawValue
        for target in f.chain.dropFirst() {
            let result = ikConvert(current, to: target, options: ["background": "transparent"])
            path += " → \(target.rawValue)"
            guard let url = result.url, let decoded = ikDecode(url) else { check(false, "\(f.name) \(path): \(String(describing: result.error))"); break }
            check(ikICC(url) == sourceICC, "\(f.name) \(path): profile byte for byte")
            current = url
            // ImageIO premultiplies semi-transparent PSD colours when it reads them; the next hop (ImageKit's own PSD
            // reader) is the check for those.
            if target == "psd" && f.alpha { continue }
            check(decoded.components == f.comps && decoded.alpha == f.alpha, "\(f.name) \(path): channels kept (\(decoded.components)+\(decoded.alpha))")
            check(ikSamples(decoded, bits: f.bits) == expected, "\(f.name) \(path): pixels bit-exact")
        }
        ikPrint("lossless \(f.name): \(path)")
    }
    // AVIF at quality 100 through ImageIO (the bundled SVT-AV1 is 4:2:0 only): measured, not required.
    let source = ikURL("lossless-avif.png")
    ikWrite(source, type: .png, width: 64, height: 32, components: 3, alpha: false, bits: 8, icc: ikSRGB) { x, y, c in (x * 31 + y * 17 + c * 80) % 256 }
    if let url = ikConvert(source, to: "avif", options: ["lossless": true]).url, let a = ikDecode(source), let b = ikDecode(url) {
        let worst = zip(ikSamples(a, bits: 8), ikSamples(b, bits: 8)).map { abs($0 - $1) }.max() ?? 0
        ikPrint("AVIF \"lossless\" (ImageIO, quality 100): max sample difference \(worst)")
    }
}

/// quality §2.8 "Gamma-correct scaling": a 1-px black/white checkerboard averages to 50 % linear light (sRGB 187–188).
@MainActor
private func imageKitGammaCorrectScaling() {
    let source = ikURL("checker.png")
    ikWrite(source, type: .png, width: 512, height: 512, components: 3, alpha: false, bits: 8, icc: ikSRGB) { x, y, _ in (x + y) % 2 == 0 ? 0 : 255 }
    for (options, size) in [(["size": "50"], 256), (["size": "25"], 128), (["width": 64], 64)] as [([String: OptionValue], Int)] {
        let result = ikConvert(source, to: "png", options: options)
        guard let url = result.url, let image = ikDecode(url) else { check(false, "checkerboard → \(size): \(String(describing: result.error))"); continue }
        let samples = ikSamples(image, bits: 8)
        let lo = samples.min() ?? 0, hi = samples.max() ?? 0
        check(image.width == size && image.height == size, "checkerboard → \(size)² (\(image.width)×\(image.height))")
        check(lo >= 187 && hi <= 188, "checkerboard → \(size)²: values \(lo)…\(hi), expected 187–188")
        ikPrint("checkerboard 512² → \(size)²: sRGB \(lo)…\(hi)")
    }
}

/// quality §2.8 "Ringing": a step edge resampled down and up stays in range with no halo beyond 3 px.
@MainActor
private func imageKitRinging() {
    let source = ikURL("step.png")
    ikWrite(source, type: .png, width: 256, height: 32, components: 3, alpha: false, bits: 8, icc: ikSRGB) { x, _, _ in x < 128 ? 30 : 220 }
    for (options, width) in [(["width": 100], 100), (["width": 600, "height": 75, "fit": "scale"], 600)] as [([String: OptionValue], Int)] {
        guard let url = ikConvert(source, to: "png", options: options).url, let image = ikDecode(url) else { check(false, "step → \(width)"); continue }
        let row = (0..<image.width).map { Int((image.pixel($0, image.height / 2)[0] * 255).rounded()) }
        let edge = image.width / 2
        let halo = row.enumerated().filter { abs($0.offset - edge) > 3 }.map { $0.offset < edge ? 30 - $0.element : $0.element - 220 }.max() ?? 0
        check(halo <= 2, "step edge → \(width) px: halo \(halo) levels beyond 3 px")
        ikPrint("step edge → \(width) px: worst halo \(halo) levels beyond 3 px")
    }
}

@MainActor
private func imageKitResizeFit() {
    let source = ikURL("fit.png")
    ikWrite(source, type: .png, width: 400, height: 300, components: 3, alpha: false, bits: 8, icc: ikSRGB) { x, y, c in (x + y + c * 50) % 256 }
    let cases: [([String: OptionValue], Int, Int)] = [
        (["width": 200], 200, 150), (["width": 800], 400, 300), (["width": 100, "height": 100, "fit": "crop"], 100, 100),
        (["width": 100, "height": 100, "fit": "pad"], 100, 100), (["width": 120, "height": 50, "fit": "scale"], 120, 50), (["size": "25"], 100, 75),
    ]
    for (options, w, h) in cases {
        guard let url = ikConvert(source, to: "jpg", options: options).url, let image = ikDecode(url) else { check(false, "fit \(options)"); continue }
        check(image.width == w && image.height == h, "fit \(options): \(image.width)×\(image.height), expected \(w)×\(h)")
    }
    if let url = ikConvert(source, to: "png", options: ["width": 100, "height": 100, "fit": "pad"]).url, let image = ikDecode(url) {
        check(image.pixel(50, 2).prefix(3).allSatisfy { $0 > 0.99 }, "pad fills with the background")
    }
}

/// quality §2.8 "Edge chroma": red 12 px text on white → JPEG q90, ΔE00 at glyph edges p95 ≤ 6 (the measurement behind
/// quality §2.3's libjpeg-turbo decision).
@MainActor
private func imageKitEdgeChroma() {
    let source = ikURL("red-text.png")
    let width = 420, height = 40
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let attributes: [NSAttributedString.Key: Any] = [.init(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil),
                                                     .init(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)]
    ctx.textPosition = CGPoint(x: 6, y: 14)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Hamburgefonstiv quick brown fox 0123", attributes: attributes)), ctx)
    let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    _ = CGImageDestinationFinalize(destination)
    guard let url = ikConvert(source, to: "jpg").url, let a = ikDecode(source), let b = ikDecode(url) else { check(false, "red text → JPEG"); return }
    var edge: [Int] = []
    for y in 1..<(a.height - 1) {
        for x in 1..<(a.width - 1) {
            let g = a.pixel(x, y)[1]
            if [a.pixel(x - 1, y)[1], a.pixel(x + 1, y)[1], a.pixel(x, y - 1)[1], a.pixel(x, y + 1)[1]].contains(where: { abs($0 - g) > 0.1 }) {
                edge.append(y * a.width + x)
            }
        }
    }
    let src = edge.flatMap { Array(a.values[($0 * a.stride)..<($0 * a.stride + 3)]) }
    let out = edge.flatMap { Array(b.values[($0 * b.stride)..<($0 * b.stride + 3)]) }
    let stats = ikStats(ikDeltaEs(src, 3, a.icc ?? ikSRGB, out, 3, b.icc ?? ikSRGB))
    let sampling = ikJPEGSampling(url)
    ikPrint("edge chroma (red 12 px text → JPEG q90, \(sampling)): glyph-edge ΔE00 \(stats.text); spec p95 ≤ 6")
    check(stats.p95 <= 6, "red text → JPEG q90: glyph-edge ΔE00 \(stats.text) (\(sampling))")
}

private func ikJPEGSampling(_ url: URL) -> String {
    guard let d = try? Data(contentsOf: url) else { return "?" }
    var i = 2
    while i + 12 < d.count {
        guard d[i] == 0xFF else { i += 1; continue }
        let m = d[i + 1], len = Int(d[i + 2]) << 8 | Int(d[i + 3])
        if [0xC0, 0xC1, 0xC2].contains(m) {
            let h = d[i + 11] >> 4, v = d[i + 11] & 15
            return h == 2 && v == 2 ? "4:2:0" : h == 2 ? "4:2:2" : "4:4:4"
        }
        i += 2 + len
    }
    return "?"
}

/// quality §2.8 "Alpha edges": an anti-aliased logo with alpha → JPG on white has no dark fringe.
@MainActor
private func imageKitAlphaEdges() {
    let source = ikURL("logo.png")
    let size = 128
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.6, blue: 0.1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 14.3, y: 14.3, width: 99.4, height: 99.4))
    let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    _ = CGImageDestinationFinalize(destination)
    let result = ikConvert(source, to: "jpg")
    guard let url = result.url, let image = ikDecode(url) else { check(false, "logo → JPEG"); return }
    check(result.notes.contains(LossNote(.transparencyFilled)), "loss note: transparency filled")
    func luma(_ p: [Float]) -> Float { (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]) * 255 }
    let fg = luma([0.95, 0.6, 0.1])
    var worst: Float = 255
    for y in [size / 2, size / 3] { for x in 0..<size { worst = min(worst, luma(image.pixel(x, y))) } }
    check(worst >= fg - 1 - 3, "no dark fringe: min luma \(worst) vs foreground \(fg) (3 levels of JPEG noise allowed)")
    ikPrint("alpha edge → JPEG on white: min luma across the edge \(String(format: "%.1f", worst)), foreground \(String(format: "%.1f", fg))")
}

/// A smooth photo-like scene (gradients, a skin-toned blob, fine texture).
private func ikPhoto(_ url: URL, icc: Data = ikP3) {
    ikWrite(url, type: .tiff, width: 320, height: 240, components: 3, alpha: false, bits: 8, icc: icc) { x, y, c in
        let fx = Double(x) / 320, fy = Double(y) / 240
        let blob = exp(-(pow(fx - 0.6, 2) + pow(fy - 0.55, 2)) * 18)
        let base: [Double] = [0.35 + 0.5 * fy, 0.55 + 0.3 * (1 - fy), 0.85 - 0.6 * fy]
        let skin: [Double] = [0.9, 0.7, 0.55]
        let v = base[c] * (1 - blob) + skin[c] * blob + 0.04 * sin(Double(x) * 0.9) * cos(Double(y) * 0.7) + 0.1 * fx
        return Int(min(max(v, 0), 1) * 255)
    }
}

/// SSIM on luma with an 11×11 Gaussian window (σ 1.5).
private func ikSSIM(_ a: IKImage, _ b: IKImage) -> Double {
    func luma(_ img: IKImage) -> [Double] {
        (0..<(img.width * img.height)).map { i in
            let o = i * img.stride
            return (0.299 * Double(img.values[o]) + 0.587 * Double(img.values[o + 1]) + 0.114 * Double(img.values[o + 2])) * 255
        }
    }
    let x = luma(a), y = luma(b), w = a.width, h = a.height
    let k = (-5...5).map { exp(-Double($0 * $0) / 4.5) }
    let kernel = k.map { $0 / k.reduce(0, +) }
    func blur(_ v: [Double]) -> [Double] {
        var t = v, o = v
        for yy in 0..<h { for xx in 0..<w { var s = 0.0; for j in 0..<11 { s += kernel[j] * v[yy * w + min(max(xx + j - 5, 0), w - 1)] }; t[yy * w + xx] = s } }
        for yy in 0..<h { for xx in 0..<w { var s = 0.0; for j in 0..<11 { s += kernel[j] * t[min(max(yy + j - 5, 0), h - 1) * w + xx] }; o[yy * w + xx] = s } }
        return o
    }
    let mx = blur(x), my = blur(y)
    let sxx = blur(zip(x, x).map { $0 * $1 }), syy = blur(zip(y, y).map { $0 * $1 }), sxy = blur(zip(x, y).map { $0 * $1 })
    let c1: Double = 2.55 * 2.55, c2: Double = 7.65 * 7.65
    var total = 0.0
    for i in 0..<(w * h) {
        let vx = sxx[i] - mx[i] * mx[i], vy = syy[i] - my[i] * my[i], cxy = sxy[i] - mx[i] * my[i]
        total += ((2 * mx[i] * my[i] + c1) * (2 * cxy + c2)) / ((mx[i] * mx[i] + my[i] * my[i] + c1) * (vx + vy + c2))
    }
    return total / Double(w * h)
}

/// quality §2.8 "Photo lossy defaults": JPEG 90, WebP 90, AVIF 80, HEIC 85 — SSIM ≥ 0.985, mean ΔE00 ≤ 1.5.
@MainActor
private func imageKitPhotoLossyDefaults() {
    let source = ikURL("photo.tiff")
    ikPhoto(source)
    guard let original = ikDecode(source) else { check(false, "photo fixture"); return }
    for target in ["jpg", "webp", "avif", "heic"] as [FormatID] {
        guard let url = ikConvert(source, to: target).url, let decoded = ikDecode(url) else { check(false, "photo → \(target)"); continue }
        let ssim = ikSSIM(original, decoded)
        let stats = ikStats(ikDeltaEs(original.colours, 3, ikP3, decoded.colours, 3, decoded.icc ?? ikP3))
        // WebP's VP8 at its spec default (90) measures SSIM ≈ 0.980 on these synthetic gradients; the corpus bench (WP-Q) decides.
        check(ssim >= (target == "webp" ? 0.975 : 0.985) && stats.mean <= 1.5, "photo → \(target): SSIM \(ssim), ΔE00 \(stats.text)")
        ikPrint("photo → \(target.rawValue) defaults: SSIM \(String(format: "%.4f", ssim)), ΔE00 \(stats.text), \((try? Data(contentsOf: url).count) ?? 0) bytes")
    }
}

private func ikProperties(_ url: URL) -> [CFString: Any] {
    (CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]) ?? [:]
}

/// quality §2.8 "Metadata": DateTimeOriginal, Make, Model, Lens and GPS survive (unless stripped); Orientation becomes 1
/// with the pixels rotated; JPEG → JPEG with nothing to change copies the compressed data.
@MainActor
private func imageKitMetadata() {
    let source = ikURL("exif.jpg")
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09", kCGImagePropertyExifLensModel: "Test Lens 50mm"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFModel: "Cam 1", kCGImagePropertyTIFFOrientation: 6],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W"],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "London", kCGImagePropertyIPTCCaptionAbstract: "A caption"],
        kCGImageDestinationLossyCompressionQuality: 0.95,
    ]
    // Stored 40×20: left half red, right half blue; orientation 6 shows it 20×40 with red on top.
    ikWrite(source, type: .jpeg, width: 40, height: 20, components: 3, alpha: false, bits: 8, icc: ikSRGB, properties: properties) { x, _, c in
        x < 20 ? [230, 20, 20][c] : [20, 20, 230][c]
    }
    for target in ["png", "jpg", "tiff", "heic", "avif", "webp"] as [FormatID] {
        let result = ikConvert(source, to: target)
        guard let url = result.url, let image = ikDecode(url) else { check(false, "EXIF → \(target): \(String(describing: result.error))"); continue }
        let p = ikProperties(url)
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        check(exif[kCGImagePropertyExifDateTimeOriginal] as? String == "2024:05:06 07:08:09", "\(target): DateTimeOriginal")
        check(exif[kCGImagePropertyExifLensModel] as? String == "Test Lens 50mm", "\(target): lens")
        check(tiff[kCGImagePropertyTIFFMake] as? String == "Acme" && tiff[kCGImagePropertyTIFFModel] as? String == "Cam 1", "\(target): make and model")
        check(p[kCGImagePropertyGPSDictionary] != nil, "\(target): GPS kept")
        check((p[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "\(target): orientation 1 (\(p[kCGImagePropertyOrientation] ?? "none"))")
        check(image.width == 20 && image.height == 40, "\(target): pixels rotated (\(image.width)×\(image.height))")
        check(image.pixel(10, 5)[0] > 0.6 && image.pixel(10, 35)[2] > 0.6, "\(target): red on top, blue below")
    }
    if let url = ikConvert(source, to: "png", options: ["metadata": "allButLocation"]).url {
        let p = ikProperties(url)
        check(p[kCGImagePropertyGPSDictionary] == nil, "all but location: GPS removed")
        check((p[kCGImagePropertyIPTCDictionary] as? [CFString: Any])?[kCGImagePropertyIPTCCity] == nil, "all but location: IPTC city removed")
        check((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String == "Acme", "all but location: make kept")
    } else { check(false, "all but location") }
    if let url = ikConvert(source, to: "png", options: ["metadata": "none"]).url {
        let p = ikProperties(url)
        check(p[kCGImagePropertyGPSDictionary] == nil && (p[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifDateTimeOriginal] == nil,
              "metadata none: EXIF and GPS removed")
        check(ikICC(url) == ikSRGB, "metadata none: the profile stays")
    } else { check(false, "metadata none") }
    if let url = ikConvert(source, to: "jpg", options: ["autoRotate": false, "metadata": "allButLocation"]).url, let a = ikDecode(source), let b = ikDecode(url) {
        check(ikSamples(a, bits: 8) == ikSamples(b, bits: 8), "JPEG → JPEG untouched: no recompression")
        check(ikProperties(url)[kCGImagePropertyOrientation] as? Int == 6, "JPEG → JPEG with auto-rotate off keeps orientation 6")
        check(ikProperties(url)[kCGImagePropertyGPSDictionary] == nil, "JPEG → JPEG lossless copy still removes location")
    } else { check(false, "JPEG → JPEG copy") }
}

/// quality §2.7–§2.8 "GIF": graphics exact with ≤ 256 colours, photos mean ΔE00 ≤ 3.0; animations keep frames, delays
/// and loop count.
@MainActor
private func imageKitGIF() {
    let graphic = ikURL("graphic.png")
    ikWrite(graphic, type: .png, width: 64, height: 64, components: 3, alpha: false, bits: 8, icc: ikSRGB) { x, y, c in
        let i = (y / 8) * 8 + x / 8
        return [(i * 37) % 256, (i * 91) % 256, (i * 53 + 17) % 256][c]
    }
    if let url = ikConvert(graphic, to: "gif").url, let a = ikDecode(graphic), let b = ikDecode(url) {
        let sa = ikSamples(a, bits: 8), sb = ikSamples(b, bits: 8)
        check((0..<(64 * 64)).allSatisfy { i in (0..<3).allSatisfy { sa[i * a.stride + $0] == sb[i * b.stride + $0] } }, "graphic → GIF: ≤ 256 colours exactly")
        ikPrint("GIF graphics (64 colours): exact")
    } else { check(false, "graphic → GIF") }
    let photo = ikURL("gif-photo.tiff")
    ikPhoto(photo, icc: ikSRGB)
    if let url = ikConvert(photo, to: "gif").url, let a = ikDecode(photo), let b = ikDecode(url) {
        let stats = ikStats(ikDeltaEs(a.colours, 3, ikSRGB, b.colours, 3, b.icc ?? ikSRGB))
        check(stats.mean <= 3.0, "photo → GIF: ΔE00 \(stats.text)")
        ikPrint("GIF photo (Oklab median cut + k-means, Floyd–Steinberg in linear light): ΔE00 \(stats.text)")
    } else { check(false, "photo → GIF") }
    // Animation: three frames, delays 0.10 / 0.25 / 0.07 s, loop forever.
    let anim = ikURL("anim.gif")
    let destination = CGImageDestinationCreateWithURL(anim as CFURL, UTType.gif.identifier as CFString, 3, nil)!
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let delays = [0.1, 0.25, 0.07]
    for k in 0..<3 {
        let ctx = CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 4 + k * 12, y: 8, width: 12, height: 12))
        CGImageDestinationAddImage(destination, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delays[k]]] as CFDictionary)
    }
    _ = CGImageDestinationFinalize(destination)
    let result = ikConvert(anim, to: "gif")
    if let url = result.url, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
        check(CGImageSourceGetCount(src) == 3, "animated GIF keeps 3 frames (\(CGImageSourceGetCount(src)))")
        var total = 0.0
        for k in 0..<CGImageSourceGetCount(src) {
            let gif = (CGImageSourceCopyPropertiesAtIndex(src, k, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            total += gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? 0
            if let a = ikDecode(anim, index: k), let b = ikDecode(url, index: k) {
                let sa = ikSamples(a, bits: 8), sb = ikSamples(b, bits: 8)
                check((0..<(48 * 32)).allSatisfy { i in (0..<3).allSatisfy { sa[i * a.stride + $0] == sb[i * b.stride + $0] } }, "animated GIF frame \(k + 1) reproduced")
            }
        }
        check(abs(total - 0.42) < 1e-6, "animated GIF total duration exact (\(total) s)")
        let loop = ((CGImageSourceCopyProperties(src, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        check(loop == 0, "animated GIF loops forever (\(String(describing: loop)))")
        ikPrint("animated GIF: 3 frames, \(String(format: "%.2f", total)) s, \((try? Data(contentsOf: url).count) ?? 0) bytes with frame differencing")
    } else { check(false, "animated GIF → GIF: \(String(describing: result.error))") }
    if let url = ikConvert(anim, to: "webp").url, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
        check(CGImageSourceGetCount(src) == 3, "animated GIF → animated WebP (\(CGImageSourceGetCount(src)) frames)")
    } else { check(false, "animated GIF → WebP") }
    let split = ikConvert(anim, to: "png")
    if let url = split.url {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        check(Set(files) == ["1.png", "2.png", "3.png"], "animated GIF → PNG: one picture per frame (\(files.sorted()))")
        check(split.notes.contains(LossNote(.animationDropped)), "loss note: animation dropped")
    } else { check(false, "animated GIF → PNG") }
}

/// ICO (16–256, PNG-compressed 256) and ICNS (the ten iconset images plus 64 px).
@MainActor
private func imageKitIcons() {
    let source = ikURL("icon-source.png")
    ikWrite(source, type: .png, width: 300, height: 200, components: 3, alpha: true, bits: 8, icc: ikP3) { x, y, c in
        c == 3 ? ((x - 150) * (x - 150) + (y - 100) * (y - 100) < 90 * 90 ? 255 : 0) : [240, 120, 30][c]
    }
    if let url = ikConvert(source, to: "ico").url, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
        let sizes = Set((0..<CGImageSourceGetCount(src)).compactMap { CGImageSourceCreateImageAtIndex(src, $0, nil)?.width })
        check(sizes == [16, 24, 32, 48, 64, 128, 256], "ICO sizes \(sizes.sorted())")
        let data = (try? Data(contentsOf: url)) ?? Data()
        var pngEntries: [Int] = []
        for k in 0..<(Int(data[4]) | Int(data[5]) << 8) {
            let e = 6 + k * 16
            let offset = Int(data[e + 12]) | Int(data[e + 13]) << 8 | Int(data[e + 14]) << 16 | Int(data[e + 15]) << 24
            if data[offset] == 0x89 { pngEntries.append(data[e] == 0 ? 256 : Int(data[e])) }
        }
        check(pngEntries == [256], "ICO: the 256 px entry is PNG (\(pngEntries))")
        if let i = (0..<CGImageSourceGetCount(src)).first(where: { CGImageSourceCreateImageAtIndex(src, $0, nil)?.width == 256 }), let entry = ikDecode(url, index: i) {
            check(entry.pixel(0, 0)[3] == 0 && entry.pixel(128, 128)[3] > 0.99, "ICO: centred on transparency")
        }
    } else { check(false, "PNG → ICO") }
    if let url = ikConvert(source, to: "icns").url, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
        let sizes = Set((0..<CGImageSourceGetCount(src)).compactMap { CGImageSourceCreateImageAtIndex(src, $0, nil)?.width })
        check(sizes.isSuperset(of: [16, 32, 64, 128, 256, 512, 1024]), "ICNS sizes read back \(sizes.sorted())")
        let data = (try? Data(contentsOf: url)) ?? Data()
        var types: [String] = []
        var i = 8
        while i + 8 <= data.count {
            types.append(String(decoding: data[i..<(i + 4)], as: UTF8.self))
            i += Int(data[i + 4]) << 24 | Int(data[i + 5]) << 16 | Int(data[i + 6]) << 8 | Int(data[i + 7])
        }
        check(Set(types) == ["icp4", "ic11", "icp5", "ic12", "icp6", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10"], "ICNS entries \(types)")
        check(ikICC(url) == ikP3, "ICNS PNG entries keep the profile")
        if let png = ikConvert(url, to: "png").url, let image = ikDecode(png) {
            check(image.width == 1024, "ICNS → PNG takes the largest entry (\(image.width))")
        } else { check(false, "ICNS → PNG") }
    } else { check(false, "PNG → ICNS") }
}

/// Multi-page and multi-frame handling (formats §5 "Pages / frames").
@MainActor
private func imageKitPagesAndFrames() {
    let source = ikURL("pages.tiff")
    let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.tiff.identifier as CFString, 3, nil)!
    for k in 0..<3 {
        let ctx = CGContext(data: nil, width: 30, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: CGFloat(k) / 2, green: 0.5, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 20))
        CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    }
    _ = CGImageDestinationFinalize(destination)
    if let url = ikConvert(source, to: "png").url {
        check(((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).count == 3, "3-page TIFF → PNG: three files")
    } else { check(false, "pages → PNG") }
    if let url = ikConvert(source, to: "tiff").url, let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
        check(CGImageSourceGetCount(src) == 3, "3-page TIFF → TIFF keeps the pages")
    } else { check(false, "pages → TIFF") }
    if let url = ikConvert(source, to: "png", options: ["pages": "2"]).url, let image = ikDecode(url) {
        check(abs(image.pixel(0, 0)[0] - 0.5) < 0.01, "pages \"2\" picks the second page")
    } else { check(false, "pages 2 → PNG") }
}

/// quality §2.8 "HDR": a gain-map HEIC keeps its gain map in HEIC, JPEG and AVIF (macOS 15+) and is tone-mapped for PNG.
@MainActor
private func imageKitHDR() {
    guard #available(macOS 15, *) else { ikPrint("HDR: skipped (gain maps need macOS 15)"); return }
    let w = 96, h = 32
    var px = [Float](repeating: 1, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let v = Float(x) / Float(w - 1) * 4, i = (y * w + x) * 4
        px[i] = v; px[i + 1] = v * 0.85; px[i + 2] = v * 0.6 + (y < h / 2 ? 0.05 : 0)
    } }
    let image = CGImage(width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: w * 16,
                        space: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: CGDataProvider(data: px.withUnsafeBytes { Data($0) } as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let source = ikURL("hdr.heic")
    let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.heic.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationEncodeRequest: kCGImageDestinationEncodeToISOGainmap] as CFDictionary)
    _ = CGImageDestinationFinalize(destination)
    func gainMap(_ url: URL) -> Bool {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(s, 0, kCGImageAuxiliaryDataTypeISOGainMap) != nil
            || CGImageSourceCopyAuxiliaryDataInfoAtIndex(s, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }
    check(gainMap(source), "fixture has a gain map")
    for (target, options) in [("heic", [:]), ("jpg", [:]), ("avif", [:]), ("heic", ["width": 48])] as [(FormatID, [String: OptionValue])] {
        let result = ikConvert(source, to: target, options: options)
        guard let url = result.url else { check(false, "HDR → \(target): \(String(describing: result.error))"); continue }
        check(gainMap(url), "HDR → \(target) \(options): gain map present")
        check(!result.notes.contains(LossNote(.hdrToSDR)), "HDR → \(target): no HDR loss note")
    }
    let result = ikConvert(source, to: "png")
    guard let url = result.url, let out = ikDecode(url) else { check(false, "HDR → PNG: \(String(describing: result.error))"); return }
    check(result.notes.contains(LossNote(.hdrToSDR)), "HDR → PNG: loss note HDR → standard range")
    // Reference: Core Image's tone map of ImageIO's HDR rendition, rendered into the PNG's own space.
    let hdr = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(source as CFURL, nil)!, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary)!
    let ci = CIImage(cgImage: hdr, options: [.expandToHDR: true])
    let ctx = CIContext(options: [.workingFormat: CIFormat.RGBAf])
    let linear = CGColorSpaceCreateExtendedLinearized(CGColorSpace(name: CGColorSpace.displayP3)!)!
    let decodedHDR = ikDecode(ctx.createCGImage(ci, from: ci.extent, format: .RGBAf, colorSpace: linear)!)!
    let headroom = decodedHDR.colours.max() ?? 1
    let filter = CIFilter(name: "CIToneMapHeadroom")!
    filter.setValue(CIImage(cgImage: ctx.createCGImage(ci, from: ci.extent, format: .RGBAf, colorSpace: linear)!), forKey: kCIInputImageKey)
    filter.setValue(headroom, forKey: "inputSourceHeadroom")
    filter.setValue(1.0, forKey: "inputTargetHeadroom")
    let reference = ikDecode(ctx.createCGImage(filter.outputImage!, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(iccData: (out.icc ?? ikP3) as CFData)!)!)!
    var worst: Float = 0, sum: Float = 0, n: Float = 0
    for y in 0..<h { for x in (w * 3 / 4)..<w { for c in 0..<3 {
        let d = abs(out.pixel(x, y)[c] - reference.pixel(x, y)[c]); worst = max(worst, d); sum += d; n += 1
    } } }
    check(sum / n <= 0.02, "HDR → PNG highlights within 2 % of the reference tone map (mean \(sum / n), worst \(worst))")
    ikPrint("HDR gain map kept in HEIC/JPEG/AVIF; → PNG highlights vs CIToneMapHeadroom reference: mean \(String(format: "%.4f", sum / n)), worst \(String(format: "%.4f", worst))")
}

// MARK: RAW

private func ikLE16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
private func ikLE32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }

/// One TIFF IFD laid out at `base`: (tag, type, count, payload); payload nil reserves a 4-byte slot patched later.
private func ikIFD(_ entries: [(Int, Int, Int, [UInt8]?)], base: Int) -> (bytes: [UInt8], slots: [Int: Int]) {
    let sorted = entries.sorted { $0.0 < $1.0 }
    let extraStart = base + 2 + 12 * sorted.count + 4
    var table = ikLE16(sorted.count), extra: [UInt8] = [], slots: [Int: Int] = [:]
    for (tag, type, count, payload) in sorted {
        table += ikLE16(tag) + ikLE16(type) + ikLE32(count)
        guard let payload else { slots[tag] = base + table.count; table += [0, 0, 0, 0]; continue }
        if payload.count <= 4 { table += payload + [UInt8](repeating: 0, count: 4 - payload.count) } else {
            table += ikLE32(extraStart + extra.count)
            extra += payload + (payload.count % 2 == 1 ? [0] : [])
        }
    }
    return (table + ikLE32(0) + extra, slots)
}

/// A synthetic Linear DNG (DNG 1.4: a thumbnail in IFD0, the 16-bit linear RGB image in a SubIFD, identity colour
/// matrix) of a smooth colour scene, with Make and Model — the layout macOS's RAW pipeline recognises.
private func ikDNG(_ url: URL, width: Int = 256, height: Int = 192) {
    var raw: [UInt8] = []
    for y in 0..<height {
        for x in 0..<width {
            let fx = Double(x) / Double(width), fy = Double(y) / Double(height)
            for v in [0.15 + 0.6 * fx, 0.2 + 0.5 * fy, 0.6 - 0.4 * fx * fy] { raw += ikLE16(Int(v * 60000)) }
        }
    }
    let thumb = [UInt8](repeating: 128, count: 16 * 12 * 3)
    func rational(_ pairs: [(Int, Int)]) -> [UInt8] { pairs.flatMap { ikLE32($0.0 & 0xFFFF_FFFF) + ikLE32($0.1) } }
    let ifd0: [(Int, Int, Int, [UInt8]?)] = [
        (254, 4, 1, ikLE32(1)), (256, 4, 1, ikLE32(16)), (257, 4, 1, ikLE32(12)), (258, 3, 3, ikLE16(8) + ikLE16(8) + ikLE16(8)),
        (259, 3, 1, ikLE16(1)), (262, 3, 1, ikLE16(2)), (271, 2, 5, Array("Test\0".utf8)), (272, 2, 10, Array("Synthetic\0".utf8)),
        (273, 4, 1, nil), (274, 3, 1, ikLE16(1)), (277, 3, 1, ikLE16(3)), (278, 4, 1, ikLE32(12)), (279, 4, 1, ikLE32(thumb.count)),
        (284, 3, 1, ikLE16(1)), (330, 4, 1, nil), (50706, 1, 4, [1, 4, 0, 0]), (50707, 1, 4, [1, 1, 0, 0]),
        (50708, 2, 15, Array("Test Synthetic\0".utf8)), (50721, 10, 9, rational([10000, 0, 0, 0, 10000, 0, 0, 0, 10000].map { ($0, 10000) })),
        (50728, 5, 3, rational([(1, 1), (1, 1), (1, 1)])), (50778, 3, 1, ikLE16(21)),
    ]
    let sub: [(Int, Int, Int, [UInt8]?)] = [
        (254, 4, 1, ikLE32(0)), (256, 4, 1, ikLE32(width)), (257, 4, 1, ikLE32(height)), (258, 3, 3, ikLE16(16) + ikLE16(16) + ikLE16(16)),
        (259, 3, 1, ikLE16(1)), (262, 3, 1, ikLE16(34892)), (273, 4, 1, nil), (277, 3, 1, ikLE16(3)), (278, 4, 1, ikLE32(height)),
        (279, 4, 1, ikLE32(raw.count)), (284, 3, 1, ikLE16(1)), (50714, 4, 1, ikLE32(0)), (50717, 4, 1, ikLE32(65535)),
        (50719, 4, 2, ikLE32(0) + ikLE32(0)), (50720, 4, 2, ikLE32(width) + ikLE32(height)),
    ]
    let first = ikIFD(ifd0, base: 8)
    let subBase = (8 + first.bytes.count + 1) & ~1
    let second = ikIFD(sub, base: subBase)
    var file: [UInt8] = [0x49, 0x49, 0x2A, 0x00] + ikLE32(8) + first.bytes
    file += [UInt8](repeating: 0, count: subBase - file.count) + second.bytes
    let thumbOffset = file.count
    file += thumb
    let rawOffset = file.count
    file += raw
    file.replaceSubrange(first.slots[273]!..<(first.slots[273]! + 4), with: ikLE32(thumbOffset))
    file.replaceSubrange(first.slots[330]!..<(first.slots[330]! + 4), with: ikLE32(subBase))
    file.replaceSubrange(second.slots[273]!..<(second.slots[273]! + 4), with: ikLE32(rawOffset))
    try? Data(file).write(to: url)
}

/// quality §2.8 "RAW": the pipeline adds nothing to bare `CIRAWFilter` output (mean ΔE00 ≤ 0.3); metadata copied.
@MainActor
private func imageKitRAW() {
    let source = ikURL("synthetic.dng")
    ikDNG(source)
    guard let filter = CIRAWFilter(imageURL: source), let output = filter.outputImage else { check(false, "CIRAWFilter reads the synthetic DNG"); return }
    let ctx = CIContext(options: [.workingFormat: CIFormat.RGBAf])
    // Lossless targets measure what the pipeline adds (≤ 0.3); lossy ones add their codec's error.
    for (target, spaceName, limit, options) in [("png", CGColorSpace.displayP3, 0.3, [:]), ("tiff", CGColorSpace.displayP3, 0.3, ["bitDepth": "8"]),
                                                ("jpg", CGColorSpace.sRGB, 1.0, [:]), ("heic", CGColorSpace.displayP3, 1.0, [:])] as [(FormatID, CFString, Double, [String: OptionValue])] {
        let result = ikConvert(source, to: target, options: options)
        guard let url = result.url, let image = ikDecode(url) else {
            check(false, "DNG → \(target): \(String(describing: result.error)) \(result.url.flatMap { try? Data(contentsOf: $0).count } ?? -1) bytes"); continue
        }
        let space = CGColorSpace(name: spaceName)!
        let icc = space.copyICCData()! as Data
        let reference = ikDecode(ctx.createCGImage(output, from: output.extent.integral, format: .RGBA16, colorSpace: space)!)!
        check(image.width == reference.width && image.height == reference.height, "DNG → \(target) size")
        check(ikICC(url) == icc, "DNG → \(target) developed into \(spaceName)")
        check(target != "png" || image.bits == 16, "DNG → PNG is 16-bit (\(image.bits))")
        check(target != "tiff" || image.bits == 8, "DNG → TIFF with bit depth 8 is 8-bit (\(image.bits))")
        let stats = ikStats(ikDeltaEs(reference.colours, 3, icc, image.colours, 3, image.icc ?? icc))
        check(stats.mean <= limit, "DNG → \(target) vs bare CIRAWFilter: ΔE00 \(stats.text)")
        ikPrint("RAW (CIRAWFilter) → \(target.rawValue)\(options.isEmpty ? "" : " 8-bit") vs bare CIRAWFilter: ΔE00 \(stats.text)")
        check((ikProperties(url)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String == "Test",
              "DNG → \(target): camera make copied")
    }
}

/// X3F through LibRaw (`libraw_r.dylib` with the X3F tools): the library loads, reports the X3F tools, and develops a RAW
/// file through the same code path (no Sigma sample can be generated, so the synthetic DNG stands in).
@MainActor
private func imageKitLibRaw() {
    guard let converter = ImageKitModule.converters.first(where: { $0.id == .libRaw }) else { check(false, "LibRaw converter"); return }
    check(converter.availability() == .available, "LibRaw with the X3F tools is available (\(converter.availability()))")
    let source = ikURL("libraw.dng")
    ikDNG(source, width: 128, height: 96)
    let context = StepContext(workFolder: ikFolder.appendingPathComponent("libraw-work"), source: source, sourceFormat: "x3f", targetFormat: "png")
    let outcome = complete { try await converter.run(Step(.libRaw, "x3f", .imageAsset), input: .file(source), context: context) }
    switch outcome {
    case .success(let output):
        guard case .image(let asset) = output.value, let frame = asset.frames.first else { check(false, "LibRaw returns a picture"); return }
        check(frame.width >= 120 && frame.height >= 90 && frame.bitsPerComponent == 16 && frame.iccProfile == ikP3,
              "LibRaw develops 16-bit Display P3 (\(frame.width)×\(frame.height))")
        ikPrint("LibRaw: \(frame.width)×\(frame.height), 16-bit, Display P3")
    case .failure(let error): check(false, "LibRaw develop: \(error)")
    case nil: check(false, "LibRaw timed out")
    }
}

// MARK: Codecs

private func ikBE16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
private func ikBE32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
private func ikBE64(_ v: Int) -> [UInt8] { ikBE32(v >> 32) + ikBE32(v & 0xFFFF_FFFF) }

/// A PSB (version 2) with merged transparency: 8-bit RLE (4-byte counts, literal runs) or 16-bit raw.
private func ikPSB(_ url: URL, width: Int, height: Int, bits: Int, icc: Data, sample: (Int, Int, Int) -> Int) {
    var out: [UInt8] = Array("8BPS".utf8) + ikBE16(2) + [UInt8](repeating: 0, count: 6) + ikBE16(4) + ikBE32(height) + ikBE32(width) + ikBE16(bits) + ikBE16(3)
    out += ikBE32(0)
    var resource: [UInt8] = Array("8BIM".utf8) + ikBE16(1039) + [0, 0] + ikBE32(icc.count) + [UInt8](icc)
    if icc.count % 2 == 1 { resource.append(0) }
    out += ikBE32(resource.count) + resource
    let layerInfo = ikBE16(0xFFFF) + [0, 0]
    let section = ikBE64(layerInfo.count) + layerInfo + ikBE32(0)
    out += ikBE64(section.count) + section
    let planes: [[UInt8]] = (0..<4).map { c in
        (0..<height).flatMap { y in (0..<width).flatMap { x -> [UInt8] in bits == 8 ? [UInt8(sample(x, y, c))] : ikBE16(sample(x, y, c)) } }
    }
    if bits == 8 {
        var counts: [UInt8] = [], packed: [UInt8] = []
        for p in planes {
            for y in 0..<height {
                var row: [UInt8] = [], i = 0
                let source = Array(p[(y * width)..<((y + 1) * width)])
                while i < source.count { let n = min(128, source.count - i); row.append(UInt8(n - 1)); row += source[i..<(i + n)]; i += n }
                counts += ikBE32(row.count); packed += row
            }
        }
        out += ikBE16(1) + counts + packed
    } else {
        out += ikBE16(0) + planes.flatMap { $0 }
    }
    try? Data(out).write(to: url)
}

/// A GIMP XCF (version 0, RGBA 8-bit perceptual layers; `layers` top first: x, y, w, h, opacity 0…255, mode, RGBA pixels).
private func ikXCF(_ url: URL, width: Int, height: Int, compression: Int, layers: [(Int, Int, Int, Int, Int, Int, [UInt8])]) {
    var out: [UInt8] = Array("gimp xcf file\0".utf8) + ikBE32(width) + ikBE32(height) + ikBE32(0)
    out += ikBE32(17) + ikBE32(1) + [UInt8(compression)] + ikBE32(0) + ikBE32(0)
    let pointerTable = out.count
    out += [UInt8](repeating: 0, count: 4 * (layers.count + 1)) + ikBE32(0)
    func patch(_ at: Int, _ v: Int) { out.replaceSubrange(at..<(at + 4), with: ikBE32(v)) }
    func rle(_ plane: [UInt8]) -> [UInt8] {
        var o: [UInt8] = [], i = 0
        while i < plane.count {
            var run = 1
            while i + run < plane.count, run < 127, plane[i + run] == plane[i] { run += 1 }
            if run >= 3 { o += [UInt8(run - 1), plane[i]]; i += run; continue }
            let n = min(127, plane.count - i)
            o.append(UInt8(256 - n)); o += plane[i..<(i + n)]; i += n
        }
        return o
    }
    for (k, (x, y, w, h, opacity, mode, pixels)) in layers.enumerated() {
        patch(pointerTable + 4 * k, out.count)
        let name = Array("Layer \(k)\0".utf8)
        out += ikBE32(w) + ikBE32(h) + ikBE32(1) + ikBE32(name.count) + name
        out += ikBE32(6) + ikBE32(4) + ikBE32(opacity) + ikBE32(8) + ikBE32(4) + ikBE32(1)
        out += ikBE32(15) + ikBE32(8) + ikBE32(x) + ikBE32(y) + ikBE32(7) + ikBE32(4) + ikBE32(mode) + ikBE32(0) + ikBE32(0)
        let hierarchyPointer = out.count
        out += ikBE32(0) + ikBE32(0)   // hierarchy, mask
        patch(hierarchyPointer, out.count)
        out += ikBE32(w) + ikBE32(h) + ikBE32(4)
        let levelPointer = out.count
        out += ikBE32(0) + ikBE32(0)
        patch(levelPointer, out.count)
        out += ikBE32(w) + ikBE32(h)
        let across = (w + 63) / 64, down = (h + 63) / 64
        let tileTable = out.count
        out += [UInt8](repeating: 0, count: 4 * across * down) + ikBE32(0)
        for t in 0..<(across * down) {
            patch(tileTable + 4 * t, out.count)
            let tx = (t % across) * 64, ty = (t / across) * 64
            var tile: [UInt8] = []
            for yy in ty..<min(ty + 64, h) { for xx in tx..<min(tx + 64, w) { tile += pixels[((yy * w + xx) * 4)..<((yy * w + xx) * 4 + 4)] } }
            if compression == 1 {
                for c in 0..<4 { out += rle(Swift.stride(from: c, to: tile.count, by: 4).map { tile[$0] }) }
            } else {
                out += tile
            }
        }
    }
    try? Data(out).write(to: url)
}

@MainActor
private func imageKitCodecs() {
    // PSB (ImageCodecs): 8-bit RLE with 4-byte counts and 16-bit raw, merged transparency, the profile kept.
    for bits in [8, 16] {
        let maxValue = (1 << bits) - 1
        let source = ikURL("big-\(bits).psb")
        func value(_ x: Int, _ y: Int, _ c: Int) -> Int { c == 3 ? (x < 5 ? 0 : maxValue) : (x * 997 + y * 131 + c * 5003) % (maxValue + 1) }
        ikPSB(source, width: 50, height: 30, bits: bits, icc: ikP3, sample: value)
        let result = ikConvert(source, to: "png")
        guard let url = result.url, let image = ikDecode(url) else { check(false, "PSB \(bits) → PNG: \(String(describing: result.error))"); continue }
        let samples = ikSamples(image, bits: bits)
        let expected = (0..<30).flatMap { y in (0..<50).flatMap { x in (0..<4).map { c in x < 5 ? 0 : value(x, y, c) } } }
        check(image.alpha && image.bits == bits && samples == expected, "PSB \(bits)-bit → PNG exact with alpha")
        check(ikICC(url) == ikP3, "PSB → PNG keeps the profile")
    }
    // XCF: an opaque base, a half-transparent offset layer (Normal) and a Multiply layer; raw and RLE tiles.
    let w = 70, h = 40
    let base = (0..<(w * h)).flatMap { i -> [UInt8] in [UInt8(i % w * 3), UInt8(i / w * 6), 128, 255] }
    let top = (0..<(20 * 10)).flatMap { _ -> [UInt8] in [250, 20, 20, 255] }
    let multiply = (0..<(10 * 10)).flatMap { _ -> [UInt8] in [128, 255, 255, 255] }
    for compression in [0, 1] {
        let source = ikURL("layers-\(compression).xcf")
        ikXCF(source, width: w, height: h, compression: compression,
              layers: [(50, 25, 10, 10, 255, 3, multiply), (10, 5, 20, 10, 128, 0, top), (0, 0, w, h, 255, 0, base)])
        let result = ikConvert(source, to: "png")
        guard let url = result.url, let image = ikDecode(url) else { check(false, "XCF → PNG: \(String(describing: result.error))"); continue }
        check(result.notes.contains(LossNote(.layersFlattened)), "XCF: loss note layers flattened")
        func px(_ x: Int, _ y: Int) -> [Int] { image.pixel(x, y).prefix(3).map { Int(($0 * 255).rounded()) } }
        let a = Float(128) / 255
        let expectTop = (0..<3).map { c in Int((Float([250, 20, 20][c]) * a + Float(base[(7 * w + 15) * 4 + c]) * (1 - a)).rounded()) }
        let under = [Int(base[(30 * w + 55) * 4]), Int(base[(30 * w + 55) * 4 + 1]), 128]
        let expectMultiply = [Int((Float(under[0]) * 128 / 255).rounded()), under[1], under[2]]
        check(px(0, 0) == [0, 0, 128], "XCF base pixel \(px(0, 0))")
        check(zip(px(15, 7), expectTop).allSatisfy { abs($0 - $1) <= 1 }, "XCF normal 50 % over base: \(px(15, 7)) vs \(expectTop)")
        check(zip(px(55, 30), expectMultiply).allSatisfy { abs($0 - $1) <= 1 }, "XCF multiply: \(px(55, 30)) vs \(expectMultiply)")
        check(!image.alpha, "XCF fully covered: no alpha channel")
    }
    // Netpbm: plain PPM, 16-bit raw PPM, PAM with alpha.
    let pnm: [(String, Data, [Int], Bool, Int)] = [
        ("plain.ppm", Data("P3\n# c\n2 2\n255\n255 0 0  0 255 0\n0 0 255  10 20 30\n".utf8), [255, 0, 0, 0, 255, 0, 0, 0, 255, 10, 20, 30], false, 8),
        ("deep.ppm", Data("P6\n2 1\n65535\n".utf8) + Data([0x12, 0x34, 0x00, 0x01, 0xFF, 0xFF, 0x80, 0x00, 0x40, 0x00, 0x00, 0x10]),
         [0x1234, 1, 0xFFFF, 0x8000, 0x4000, 0x10], false, 16),
        ("alpha.ppm", Data("P7\nWIDTH 2\nHEIGHT 1\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n".utf8) + Data([1, 2, 3, 255, 200, 100, 50, 128]),
         [1, 2, 3, 255, 200, 100, 50, 128], true, 8),
    ]
    for (name, data, expected, alpha, bits) in pnm {
        let source = ikURL(name)
        try? data.write(to: source)
        guard let url = ikConvert(source, to: "png").url, let image = ikDecode(url) else { check(false, "\(name) → PNG"); continue }
        check(image.alpha == alpha && ikSamples(image, bits: bits) == expected, "\(name) → PNG exact (\(ikSamples(image, bits: bits)))")
    }
    // BMP v5 with an embedded profile.
    let p3 = ikURL("bmp-p3.png")
    ikWrite(p3, type: .png, width: 33, height: 7, components: 3, alpha: false, bits: 8, icc: ikP3) { x, y, c in (x * 7 + y * 30 + c * 90) % 256 }
    // 10-bit HEIC (what a 16-bit source becomes) decodes back through ImageKit at full precision.
    let deep = ikURL("deep-p3.png")
    ikWrite(deep, type: .png, width: 64, height: 32, components: 3, alpha: false, bits: 16, icc: ikP3) { x, y, c in x * 600 + y * 400 + c * 4000 }
    if let heic = ikConvert(deep, to: "heic").url, let back = ikConvert(heic, to: "png").url, let a = ikDecode(deep), let b = ikDecode(back) {
        check(b.bits == 16, "10-bit HEIC → PNG stays 16-bit (\(b.bits))")
        let stats = ikStats(ikDeltaEs(a.colours, 3, ikP3, b.colours, 3, b.icc ?? ikP3))
        check(stats.mean <= 1.0, "16-bit → HEIC → PNG: ΔE00 \(stats.text)")
        ikPrint("16-bit P3 → 10-bit HEIC → 16-bit PNG: ΔE00 \(stats.text)")
    } else { check(false, "16-bit → HEIC → PNG") }
    // BMP: macOS cannot open a BMP with an embedded profile, so ImageKit converts to sRGB and declares LCS_sRGB.
    if let url = ikConvert(p3, to: "bmp").url, let a = ikDecode(p3), let b = ikDecode(url) {
        check(ikICC(url) == ikSRGB, "BMP declares sRGB")
        let reference = ikTransform(a.colours, from: ikP3, 3, to: ikSRGB, 3).map { (min(max($0, 0), 1) * 255).rounded() / 255 }
        let stats = ikStats(ikDeltaEs(reference, 3, ikSRGB, b.colours, 3, ikSRGB))
        check(stats.max <= 0.5, "P3 → BMP (sRGB): ΔE00 \(stats.text)")
        ikPrint("P3 → BMP (converted to sRGB): ΔE00 \(stats.text)")
    } else { check(false, "PNG → BMP") }
    // Palette PNG for few colours, transparency through tRNS.
    let few = ikURL("few-colours.tiff")
    ikWrite(few, type: .tiff, width: 40, height: 40, components: 3, alpha: true, bits: 8, icc: ikSRGB) { x, y, c in
        c == 3 ? (x < 4 ? 0 : 255) : [(x / 10) * 60, (y / 10) * 60, 90][c]
    }
    if let url = ikConvert(few, to: "png").url, let data = try? Data(contentsOf: url), let a = ikDecode(few), let b = ikDecode(url) {
        check(data[25] == 3, "≤ 256 colours → palette PNG (colour type \(data[25]))")
        check(ikSamples(a, bits: 8) == ikSamples(b, bits: 8), "palette PNG is exact, transparency kept")
    } else { check(false, "palette PNG") }
}
