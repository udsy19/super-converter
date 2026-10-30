import CoreGraphics
import Foundation
import SuperConverterCore

/// Image XObjects → ImageAsset (8-bit RGBA): raw samples in any colour space and depth, DCT/JPEG 2000 through ImageIO,
/// stencil masks, colour-key masks, explicit masks and soft masks.
enum PDFImageDecoder {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    static func decode(_ stream: CGPDFStreamRef, lookup: (String) -> CGPDFObjectRef?, fill: VectorColour) -> ImageAsset? {
        guard let dict = PDFObj.streamDictionary(stream), var w = PDFObj.int(dict, "Width") ?? PDFObj.int(dict, "W"),
              var h = PDFObj.int(dict, "Height") ?? PDFObj.int(dict, "H"), ImageBridge.plausible(width: w, height: h) else { return nil }
        let isMask = PDFObj.bool(dict, "ImageMask") ?? false
        guard let (data, format) = PDFObj.data(stream) else { return nil }
        var rgba: [UInt8]
        var hasAlpha = false

        if format != .raw {
            // The encoded picture knows its own size; a dictionary that disagrees is not trusted with the allocation.
            guard let image = ImageBridge.image(decoding: data) else { return nil }
            w = image.width; h = image.height
            guard let pixels = drawn(image, width: w, height: h) else { return nil }
            rgba = pixels
        } else if isMask {
            guard holds(data, width: w, height: h, components: 1, bits: 1) else { return nil }
            let invert = (PDFObj.numbers(dict, "Decode") ?? [0, 1]).first == 1
            let samples = unpack(data, width: w, height: h, components: 1, bits: 1)
            rgba = [UInt8](repeating: 0, count: w * h * 4)
            let r = UInt8((fill.red * 255).rounded()), g = UInt8((fill.green * 255).rounded()), b = UInt8((fill.blue * 255).rounded())
            for i in 0..<(w * h) {
                let paint = (samples[i] == 0) != invert
                rgba[i * 4] = r; rgba[i * 4 + 1] = g; rgba[i * 4 + 2] = b; rgba[i * 4 + 3] = paint ? 255 : 0
            }
            hasAlpha = true
        } else {
            let bits = PDFObj.int(dict, "BitsPerComponent") ?? PDFObj.int(dict, "BPC") ?? 8
            guard let csObject = PDFObj.object(dict, "ColorSpace") ?? PDFObj.object(dict, "CS"), let space = PDFColourSpace.parse(csObject, lookup: lookup) else { return nil }
            let n = space.components
            guard n > 0, holds(data, width: w, height: h, components: n, bits: bits) else { return nil }
            var samples = unpack(data, width: w, height: h, components: n, bits: bits)
            // Colour-key mask is tested on the undecoded samples.
            var keyed: [Bool]?
            if let mask = PDFObj.array(dict, "Mask") {
                let ranges = PDFObj.numbers(mask)
                if ranges.count >= 2 * n {
                    var flags = [Bool](repeating: false, count: w * h)
                    for p in 0..<(w * h) {
                        var all = true
                        for c in 0..<n {
                            let v = Double(samples[p * n + c])
                            let lo = ranges[2 * c] / (bits > 8 ? 257 : 1), hi = ranges[2 * c + 1] / (bits > 8 ? 257 : 1)
                            if v < lo || v > hi { all = false; break }
                        }
                        flags[p] = all
                    }
                    keyed = flags
                }
            }
            if let decode = PDFObj.numbers(dict, "Decode"), decode.count >= 2 * n, !isIdentityDecode(decode, space: space, n: n) {
                let indexed = isIndexed(space)
                for p in 0..<(w * h) {
                    for c in 0..<n {
                        let s = Double(samples[p * n + c]) / (indexed ? 1 : 255)
                        let lo = decode[2 * c], hi = decode[2 * c + 1]
                        let v = indexed ? lo + s * (hi - lo) : (lo + s * (hi - lo)) * 255
                        samples[p * n + c] = UInt8(max(0, min(255, v.rounded())))
                    }
                }
            }
            guard let converted = toRGBA(samples, width: w, height: h, space: space, bits: bits) else { return nil }
            rgba = converted
            if let keyed { for p in 0..<(w * h) where keyed[p] { rgba[p * 4 + 3] = 0 }; hasAlpha = true }
        }

        // Soft mask or explicit mask: alpha from another image, resampled to this one.
        let softMask = PDFObj.stream(dict, "SMask")
        if let maskStream = softMask ?? PDFObj.stream(dict, "Mask"), let (alpha, mw, mh) = decodeAlpha(maskStream, soft: softMask != nil) {
            for y in 0..<h {
                let my = min(mh - 1, y * mh / h)
                for x in 0..<w { rgba[(y * w + x) * 4 + 3] = alpha[my * mw + min(mw - 1, x * mw / w)] }
            }
            hasAlpha = true
        }
        if !hasAlpha { hasAlpha = stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] != 255 } }
        return ImageAsset(frames: [ImageFrame(width: w, height: h, pixels: .rgba8(Data(rgba), bytesPerRow: w * 4), hasAlpha: hasAlpha)])
    }

    private static func isIndexed(_ space: PDFColourSpace) -> Bool { if case .indexed = space.kind { true } else { false } }

    private static func isIdentityDecode(_ d: [Double], space: PDFColourSpace, n: Int) -> Bool {
        if case .indexed = space.kind { return d[0] == 0 }
        if case .lab = space.kind { return true }
        for c in 0..<n where d[2 * c] != 0 || d[2 * c + 1] != 1 { return false }
        return true
    }

    /// Mask samples as alpha 0...255 (soft mask: gray level; explicit mask: 1-bit, 0 = opaque), with the mask's size.
    private static func decodeAlpha(_ stream: CGPDFStreamRef, soft: Bool) -> (alpha: [UInt8], width: Int, height: Int)? {
        guard let dict = PDFObj.streamDictionary(stream), let w = PDFObj.int(dict, "Width"), let h = PDFObj.int(dict, "Height"),
              ImageBridge.plausible(width: w, height: h), let (data, format) = PDFObj.data(stream) else { return nil }
        if format != .raw {
            guard let image = ImageBridge.image(decoding: data), let rgba = drawn(image, width: image.width, height: image.height) else { return nil }
            return ((0..<(image.width * image.height)).map { rgba[$0 * 4] }, image.width, image.height)
        }
        let bits = soft ? (PDFObj.int(dict, "BitsPerComponent") ?? 8) : 1
        guard holds(data, width: w, height: h, components: 1, bits: bits) else { return nil }
        let samples = unpack(data, width: w, height: h, components: 1, bits: bits)
        let inverted = (PDFObj.numbers(dict, "Decode") ?? [0, 1]).first == 1
        if soft {
            let m = bits < 8 ? Double((1 << bits) - 1) : 255
            return (samples.map { let v = UInt8(min(255, (Double($0) / m * 255).rounded())); return inverted ? 255 - v : v }, w, h)
        }
        return (samples.map { (($0 == 0) != inverted) ? 255 : 0 }, w, h)
    }

    /// Whether raw sample data of `components` × `bits` fits the declared size: the depth is one PDF allows, and the data
    /// holds at least half the rows (a short stream keeps its missing rows blank, but a header claiming far more pixels
    /// than the data holds is damage, and would be a runaway allocation).
    private static func holds(_ data: Data, width: Int, height: Int, components: Int, bits: Int) -> Bool {
        guard [1, 2, 4, 8, 16].contains(bits) else { return false }
        let rowBytes = (width * components * bits + 7) / 8
        return data.count / rowBytes >= (height + 1) / 2
    }

    /// Unpacks samples of any depth to bytes (raw values for depths below 8; 16-bit takes the high byte).
    static func unpack(_ data: Data, width: Int, height: Int, components: Int, bits: Int) -> [UInt8] {
        let rowBytes = (width * components * bits + 7) / 8
        var out = [UInt8](repeating: 0, count: width * height * components)
        let bytes = [UInt8](data)
        for y in 0..<height {
            let rowStart = y * rowBytes
            guard rowStart < bytes.count else { break }
            for i in 0..<(width * components) {
                var v = 0
                switch bits {
                case 8:
                    let o = rowStart + i
                    v = o < bytes.count ? Int(bytes[o]) : 0
                case 16:
                    let o = rowStart + i * 2
                    v = o < bytes.count ? Int(bytes[o]) : 0
                default:
                    let bitIndex = i * bits
                    let o = rowStart + bitIndex / 8
                    guard o < bytes.count else { continue }
                    let shift = 8 - bits - (bitIndex % 8)
                    v = (Int(bytes[o]) >> shift) & ((1 << bits) - 1)
                }
                out[y * width * components + i] = UInt8(v)
            }
        }
        return out
    }

    /// Draws a CGImage at a given pixel size into straight-alpha RGBA bytes.
    private static func drawn(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let ok = out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = Int(out[i + 3])
            if a > 0 && a < 255 { for c in 0..<3 { out[i + c] = UInt8(min(255, (Int(out[i + c]) * 255 + a / 2) / a)) } }
        }
        return out
    }

    /// Samples (already unpacked and decoded) in `space` → RGBA.
    private static func toRGBA(_ samples: [UInt8], width w: Int, height h: Int, space: PDFColourSpace, bits: Int) -> [UInt8]? {
        let count = w * h
        var out = [UInt8](repeating: 255, count: count * 4)
        let m = bits < 8 ? Double((1 << bits) - 1) : 255
        func viaColorSync(_ cg: CGColorSpace, _ n: Int) -> [UInt8]? {
            var scaled = samples
            if bits < 8 { for i in 0..<scaled.count { scaled[i] = UInt8((Double(scaled[i]) / m * 255).rounded()) } }
            guard let provider = CGDataProvider(data: Data(scaled) as CFData),
                  let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8 * n, bytesPerRow: w * n, space: cg,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                                      shouldInterpolate: false, intent: .defaultIntent) else { return nil }
            return drawn(image, width: w, height: h)
        }
        switch space.kind {
        case .gray:
            for p in 0..<count { let v = UInt8(min(255, (Double(samples[p]) / m * 255).rounded())); out[p * 4] = v; out[p * 4 + 1] = v; out[p * 4 + 2] = v }
        case .rgb:
            for p in 0..<count { for c in 0..<3 { out[p * 4 + c] = UInt8(min(255, (Double(samples[p * 3 + c]) / m * 255).rounded())) } }
        case .cmyk:
            return viaColorSync(CGColorSpace(name: CGColorSpace.genericCMYK)!, 4)
        case .icc(let cg, let n):
            return viaColorSync(cg, n)
        case .indexed(_, let hival, _):
            var palette: [[UInt8]] = []
            for i in 0...hival {
                let c = space.toRGB([Double(i)])
                palette.append([UInt8((c.red * 255).rounded()), UInt8((c.green * 255).rounded()), UInt8((c.blue * 255).rounded())])
            }
            for p in 0..<count { let e = palette[min(Int(samples[p]), hival)]; out[p * 4] = e[0]; out[p * 4 + 1] = e[1]; out[p * 4 + 2] = e[2] }
        case .lab, .tint:
            let n = space.components
            var cache: [[UInt8]: [UInt8]] = [:]
            for p in 0..<count {
                let key = Array(samples[(p * n)..<(p * n + n)])
                if let hit = cache[key] { out[p * 4] = hit[0]; out[p * 4 + 1] = hit[1]; out[p * 4 + 2] = hit[2]; continue }
                var comps = key.map { Double($0) / m }
                if case .lab(_, let range) = space.kind {
                    comps = [comps[0] * 100, range[0] + comps[1] * (range[1] - range[0]), range[2] + comps[2] * (range[3] - range[2])]
                }
                let c = space.toRGB(comps)
                let px = [UInt8((c.red * 255).rounded()), UInt8((c.green * 255).rounded()), UInt8((c.blue * 255).rounded())]
                if cache.count < 100_000 { cache[key] = px }
                out[p * 4] = px[0]; out[p * 4 + 1] = px[1]; out[p * 4 + 2] = px[2]
            }
        case .pattern: return nil
        }
        return out
    }
}
