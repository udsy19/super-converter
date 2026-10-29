import Foundation
import SuperConverterCore

/// GIF (quality §2.7): own quantiser — median cut in Oklab with variance-weighted splits, three k-means passes,
/// Floyd–Steinberg serpentine diffusion in linear light, alpha thresholded at 50 % — and an own GIF89a writer, because
/// ImageIO cannot be told which palette, transparency index and disposal to use. Animations share one palette when that
/// costs under 0.5 dB, store only the pixels that change, and keep their total duration exact.
/// No GPL quantiser is used (libimagequant is GPL-3).
enum GIFEncoder {
    /// One frame of 8-bit sRGB RGBA (un-premultiplied).
    struct Frame { var width: Int; var height: Int; var rgba: [UInt8]; var delay: TimeInterval? }

    static func encode(_ frames: [Frame], colours: Int, dither: ImageSettings.Dither, loopCount: Int) -> Data {
        guard let first = frames.first else { return Data() }
        let animated = frames.count > 1
        let anyTransparency = frames.contains { f in Swift.stride(from: 3, to: f.rgba.count, by: 4).contains { f.rgba[$0] < 128 } }
        // Differencing needs a transparent index too; it is only used when the animation is opaque.
        let reserveTransparent = anyTransparency || animated
        let limit = max(2, min(colours, 256) - (reserveTransparent ? 1 : 0))

        // Palettes: one shared, or one per frame when sharing costs 0.5 dB or more.
        var palettes: [[UInt32]]
        var indexed: [[UInt8]]
        let globalPalette = Quantiser.palette(for: frames.map(\.rgba), maxColours: limit)
        let globalMapped = frames.map { Quantiser.map($0.rgba, width: $0.width, height: $0.height, palette: globalPalette, dither: dither) }
        palettes = [globalPalette]; indexed = globalMapped
        if animated {
            let localPalettes = frames.map { Quantiser.palette(for: [$0.rgba], maxColours: limit) }
            let localMapped = zip(frames, localPalettes).map { Quantiser.map($0.rgba, width: $0.width, height: $0.height, palette: $1, dither: dither) }
            let globalPSNR = psnr(frames.map(\.rgba), globalMapped, Array(repeating: globalPalette, count: frames.count))
            let localPSNR = psnr(frames.map(\.rgba), localMapped, localPalettes)
            if globalPSNR < localPSNR - 0.5 { palettes = localPalettes; indexed = localMapped }
        }
        let shared = palettes.count == 1

        var out = Data("GIF89a".utf8)
        out.append(le16(first.width)); out.append(le16(first.height))
        let tableBits = shared ? tableSizeBits(palettes[0].count + (reserveTransparent ? 1 : 0)) : 0
        out.append(shared ? 0x80 | 0x70 | UInt8(tableBits - 1) : 0x70)
        out.append(0)   // background colour index
        out.append(0)   // pixel aspect ratio
        if shared { out.append(colourTable(palettes[0], bits: tableBits)) }
        if animated, loopCount != 1 {
            out.append(contentsOf: [0x21, 0xFF, 0x0B])
            out.append(Data("NETSCAPE2.0".utf8))
            out.append(contentsOf: [0x03, 0x01])
            out.append(le16(loopCount))
            out.append(0)
        }

        // Delays in 10 ms units with the rounding error carried so the total is exact.
        var elapsed = 0.0, written = 0
        var previous: [UInt32]?   // the displayed canvas after the last frame
        for (k, frame) in frames.enumerated() {
            let palette = shared ? palettes[0] : palettes[k]
            let transparentIndex: UInt8? = reserveTransparent ? UInt8(palette.count) : nil
            var indexes = indexed[k]
            elapsed += frame.delay ?? 0
            let centiseconds = animated ? max(Int((elapsed * 100).rounded()) - written, 0) : 0
            written += centiseconds
            if let t = transparentIndex {
                for i in 0..<indexes.count where frame.rgba[i * 4 + 3] < 128 { indexes[i] = t }
            }
            let current: [UInt32] = indexes.map { i in transparentIndex == i ? 0xFF00_0000 : palette[Int(i)] }
            // Frame differencing (opaque animations): unchanged pixels become transparent; only the changed box is stored.
            var box = (x: 0, y: 0, w: frame.width, h: frame.height)
            var disposal: UInt8 = animated ? 2 : 0
            if animated, !anyTransparency, let prev = previous, let t = transparentIndex {
                var minX = frame.width, minY = frame.height, maxX = -1, maxY = -1
                for y in 0..<frame.height {
                    for x in 0..<frame.width where current[y * frame.width + x] != prev[y * frame.width + x] {
                        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
                if maxX < 0 { minX = 0; minY = 0; maxX = 0; maxY = 0 }
                box = (minX, minY, maxX - minX + 1, maxY - minY + 1)
                for i in 0..<indexes.count where current[i] == prev[i] { indexes[i] = t }
            }
            if animated, !anyTransparency { disposal = 1 }
            previous = current

            out.append(contentsOf: [0x21, 0xF9, 0x04])
            out.append(disposal << 2 | (transparentIndex != nil ? 1 : 0))
            out.append(le16(centiseconds))
            out.append(transparentIndex ?? 0)
            out.append(0)
            out.append(0x2C)
            out.append(le16(box.x)); out.append(le16(box.y)); out.append(le16(box.w)); out.append(le16(box.h))
            let localBits = shared ? tableBits : tableSizeBits(palette.count + (reserveTransparent ? 1 : 0))
            out.append(shared ? 0 : 0x80 | UInt8(localBits - 1))
            if !shared { out.append(colourTable(palette, bits: localBits)) }
            var sub = [UInt8](repeating: 0, count: box.w * box.h)
            for y in 0..<box.h { for x in 0..<box.w { sub[y * box.w + x] = indexes[(y + box.y) * frame.width + x + box.x] } }
            out.append(LZW.encode(sub, minimumCodeSize: max(2, localBits)))
        }
        out.append(0x3B)
        return out
    }

    private static func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }

    private static func tableSizeBits(_ count: Int) -> Int {
        var bits = 1
        while (1 << bits) < count { bits += 1 }
        return min(bits, 8)
    }

    private static func colourTable(_ palette: [UInt32], bits: Int) -> Data {
        var table = Data(count: 3 * (1 << bits))
        for (i, c) in palette.enumerated() where i < (1 << bits) {
            table[i * 3] = UInt8(c >> 16 & 0xFF); table[i * 3 + 1] = UInt8(c >> 8 & 0xFF); table[i * 3 + 2] = UInt8(c & 0xFF)
        }
        return table
    }

    private static func psnr(_ sources: [[UInt8]], _ mapped: [[UInt8]], _ palettes: [[UInt32]]) -> Double {
        var squared = 0.0, n = 0.0
        for (k, rgba) in sources.enumerated() {
            for i in 0..<(rgba.count / 4) where rgba[i * 4 + 3] >= 128 {
                let c = palettes[k][Int(mapped[k][i])]
                let d = [Double(rgba[i * 4]) - Double(c >> 16 & 0xFF), Double(rgba[i * 4 + 1]) - Double(c >> 8 & 0xFF), Double(rgba[i * 4 + 2]) - Double(c & 0xFF)]
                squared += d[0] * d[0] + d[1] * d[1] + d[2] * d[2]; n += 3
            }
        }
        guard n > 0, squared > 0 else { return 99 }
        return 10 * log10(255 * 255 / (squared / n))
    }
}

/// Palette building and mapping in Oklab (Björn Ottosson's perceptual space; the formulas are public domain).
enum Quantiser {
    struct Lab { var l: Float; var a: Float; var b: Float }

    static func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    static func encoded(_ v: Float) -> Float { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    static func oklab(linear r: Float, _ g: Float, _ b: Float) -> Lab {
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return Lab(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                   a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                   b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func linearRGB(_ lab: Lab) -> (Float, Float, Float) {
        let l = lab.l + 0.3963377774 * lab.a + 0.2158037573 * lab.b
        let m = lab.l - 0.1055613458 * lab.a - 0.0638541728 * lab.b
        let s = lab.l - 0.0894841775 * lab.a - 1.2914855480 * lab.b
        let l3 = l * l * l, m3 = m * m * m, s3 = s * s * s
        return (4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
                -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
                -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3)
    }

    private static let toLinear: [Float] = (0..<256).map { linear(Float($0) / 255) }

    static func oklab(rgb: UInt32) -> Lab {
        oklab(linear: toLinear[Int(rgb >> 16 & 0xFF)], toLinear[Int(rgb >> 8 & 0xFF)], toLinear[Int(rgb & 0xFF)])
    }

    private struct Item { var rgb: UInt32; var lab: Lab; var weight: Float }

    /// Up to `maxColours` sRGB colours for the opaque pixels of these frames: the exact colours when there are few
    /// enough, else median cut + k-means in Oklab.
    static func palette(for frames: [[UInt8]], maxColours: Int) -> [UInt32] {
        var histogram: [UInt32: Int] = [:]
        for rgba in frames {
            for i in 0..<(rgba.count / 4) where rgba[i * 4 + 3] >= 128 {
                histogram[UInt32(rgba[i * 4]) << 16 | UInt32(rgba[i * 4 + 1]) << 8 | UInt32(rgba[i * 4 + 2]), default: 0] += 1
            }
        }
        if histogram.isEmpty { return [0] }
        if histogram.count <= maxColours { return histogram.keys.sorted() }
        var items = histogram.map { Item(rgb: $0.key, lab: oklab(rgb: $0.key), weight: Float($0.value)) }

        // Median cut with variance-weighted splits.
        func stats(_ r: Range<Int>) -> (score: Float, axis: Int) {
            var w: Float = 0, mean: (Float, Float, Float) = (0, 0, 0)
            for i in r { let it = items[i]; w += it.weight; mean.0 += it.lab.l * it.weight; mean.1 += it.lab.a * it.weight; mean.2 += it.lab.b * it.weight }
            guard w > 0 else { return (0, 0) }
            mean = (mean.0 / w, mean.1 / w, mean.2 / w)
            var v: (Float, Float, Float) = (0, 0, 0)
            for i in r {
                let it = items[i]
                v.0 += it.weight * (it.lab.l - mean.0) * (it.lab.l - mean.0)
                v.1 += it.weight * (it.lab.a - mean.1) * (it.lab.a - mean.1)
                v.2 += it.weight * (it.lab.b - mean.2) * (it.lab.b - mean.2)
            }
            let axis = v.0 >= v.1 && v.0 >= v.2 ? 0 : (v.1 >= v.2 ? 1 : 2)
            return (v.0 + v.1 + v.2, axis)
        }
        var boxes: [Range<Int>] = [0..<items.count]
        var scores = [stats(boxes[0])]
        while boxes.count < maxColours {
            guard let pick = scores.indices.filter({ boxes[$0].count > 1 }).max(by: { scores[$0].score < scores[$1].score }),
                  scores[pick].score > 0 else { break }
            let r = boxes[pick], axis = scores[pick].axis
            items[r].sort { axis == 0 ? $0.lab.l < $1.lab.l : axis == 1 ? $0.lab.a < $1.lab.a : $0.lab.b < $1.lab.b }
            let total = items[r].reduce(0) { $0 + $1.weight }
            var acc: Float = 0, cut = r.lowerBound + 1
            for i in r { acc += items[i].weight; if acc >= total / 2 { cut = min(max(i + 1, r.lowerBound + 1), r.upperBound - 1); break } }
            let a = r.lowerBound..<cut, b = cut..<r.upperBound
            boxes[pick] = a; scores[pick] = stats(a)
            boxes.append(b); scores.append(stats(b))
        }
        var centres: [Lab] = boxes.map { r in
            var w: Float = 0, l: Float = 0, a: Float = 0, bb: Float = 0
            for i in r { let it = items[i]; w += it.weight; l += it.lab.l * it.weight; a += it.lab.a * it.weight; bb += it.lab.b * it.weight }
            return Lab(l: l / w, a: a / w, b: bb / w)
        }
        // k-means refinement, three passes.
        for _ in 0..<3 {
            var sums = [(Float, Float, Float, Float)](repeating: (0, 0, 0, 0), count: centres.count)
            for it in items {
                let k = nearest(it.lab, centres)
                sums[k].0 += it.lab.l * it.weight; sums[k].1 += it.lab.a * it.weight; sums[k].2 += it.lab.b * it.weight; sums[k].3 += it.weight
            }
            for k in centres.indices where sums[k].3 > 0 {
                centres[k] = Lab(l: sums[k].0 / sums[k].3, a: sums[k].1 / sums[k].3, b: sums[k].2 / sums[k].3)
            }
        }
        var seen = Set<UInt32>()
        return centres.compactMap { c in
            let (r, g, b) = linearRGB(c)
            func q(_ v: Float) -> UInt32 { UInt32(min(max(encoded(min(max(v, 0), 1)), 0), 1) * 255 + 0.5) }
            let rgb = q(r) << 16 | q(g) << 8 | q(b)
            return seen.insert(rgb).inserted ? rgb : nil
        }
    }

    private static func nearest(_ lab: Lab, _ centres: [Lab]) -> Int {
        var best = 0, bestD = Float.infinity
        for (k, c) in centres.enumerated() {
            let dl = lab.l - c.l, da = lab.a - c.a, db = lab.b - c.b
            let d = dl * dl + da * da + db * db
            if d < bestD { bestD = d; best = k }
        }
        return best
    }

    /// Palette indexes for each pixel (transparent pixels get index 0 here; the writer replaces them).
    static func map(_ rgba: [UInt8], width: Int, height: Int, palette: [UInt32], dither: ImageSettings.Dither) -> [UInt8] {
        let labs = palette.map { oklab(rgb: $0) }
        let lin = palette.map { (toLinear[Int($0 >> 16 & 0xFF)], toLinear[Int($0 >> 8 & 0xFF)], toLinear[Int($0 & 0xFF)]) }
        var exact: [UInt32: UInt8] = [:]
        for (i, c) in palette.enumerated() { exact[c] = UInt8(i) }
        var cache: [UInt32: UInt8] = [:]
        func nearestIndex(_ r: Float, _ g: Float, _ b: Float) -> UInt8 {
            let key = UInt32(min(max(r, 0), 1) * 1023) << 20 | UInt32(min(max(g, 0), 1) * 1023) << 10 | UInt32(min(max(b, 0), 1) * 1023)
            if let hit = cache[key] { return hit }
            let k = UInt8(nearest(oklab(linear: max(r, 0), max(g, 0), max(b, 0)), labs))
            if cache.count < 1 << 20 { cache[key] = k }
            return k
        }
        var out = [UInt8](repeating: 0, count: width * height)
        let bayer: [Float] = [0, 32, 8, 40, 2, 34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4, 36, 14, 46, 6, 38, 60, 28, 52, 20, 62, 30, 54, 22,
                              3, 35, 11, 43, 1, 33, 9, 41, 51, 19, 59, 27, 49, 17, 57, 25, 15, 47, 7, 39, 13, 45, 5, 37, 63, 31, 55, 23, 61, 29, 53, 21]
        let spread: Float = 1 / Float(max(2, Int(cbrt(Double(palette.count)).rounded())))
        var errCur = [Float](repeating: 0, count: (width + 2) * 3), errNext = errCur
        for y in 0..<height {
            let ltr = y % 2 == 0
            let fwd = ltr ? 1 : -1
            for step in 0..<width {
                let x = ltr ? step : width - 1 - step
                let i = y * width + x
                guard rgba[i * 4 + 3] >= 128 else { continue }
                let rgb = UInt32(rgba[i * 4]) << 16 | UInt32(rgba[i * 4 + 1]) << 8 | UInt32(rgba[i * 4 + 2])
                var r = toLinear[Int(rgba[i * 4])], g = toLinear[Int(rgba[i * 4 + 1])], b = toLinear[Int(rgba[i * 4 + 2])]
                switch dither {
                case .none:
                    out[i] = exact[rgb] ?? nearestIndex(r, g, b)
                case .ordered:
                    if let e = exact[rgb] { out[i] = e; continue }
                    let t = (bayer[(y % 8) * 8 + x % 8] / 64 - 0.5) * spread
                    out[i] = nearestIndex(linear(min(max(encoded(r) + t, 0), 1)), linear(min(max(encoded(g) + t, 0), 1)), linear(min(max(encoded(b) + t, 0), 1)))
                case .floydSteinberg:
                    r += errCur[(x + 1) * 3]; g += errCur[(x + 1) * 3 + 1]; b += errCur[(x + 1) * 3 + 2]
                    let k = Int(nearestIndex(r, g, b))
                    out[i] = UInt8(k)
                    let e = [max(min(r - lin[k].0, 0.25), -0.25), max(min(g - lin[k].1, 0.25), -0.25), max(min(b - lin[k].2, 0.25), -0.25)]
                    for c in 0..<3 {
                        errCur[(x + 1 + fwd) * 3 + c] += e[c] * 7 / 16
                        errNext[(x + 1 - fwd) * 3 + c] += e[c] * 3 / 16
                        errNext[(x + 1) * 3 + c] += e[c] * 5 / 16
                        errNext[(x + 1 + fwd) * 3 + c] += e[c] / 16
                    }
                }
            }
            swap(&errCur, &errNext)
            for k in errNext.indices { errNext[k] = 0 }
        }
        return out
    }
}

/// GIF's variable-length LZW (codes up to 12 bits, least significant bit first, in 255-byte sub-blocks).
enum LZW {
    static func encode(_ indexes: [UInt8], minimumCodeSize: Int) -> Data {
        let clear = 1 << minimumCodeSize, end = clear + 1
        var codeSize = minimumCodeSize + 1
        var next = end + 1
        var table: [Int: Int] = [:]
        var bytes: [UInt8] = []
        var bitBuffer = 0, bitCount = 0
        func emit(_ code: Int) {
            bitBuffer |= code << bitCount
            bitCount += codeSize
            while bitCount >= 8 { bytes.append(UInt8(bitBuffer & 0xFF)); bitBuffer >>= 8; bitCount -= 8 }
        }
        emit(clear)
        var prefix = -1
        for value in indexes {
            let v = Int(value)
            if prefix < 0 { prefix = v; continue }
            let key = prefix << 8 | v
            if let code = table[key] { prefix = code; continue }
            emit(prefix)
            table[key] = next
            if next >= (1 << codeSize) && codeSize < 12 { codeSize += 1 }
            next += 1
            if next == 4096 {
                emit(clear)
                table.removeAll(keepingCapacity: true)
                codeSize = minimumCodeSize + 1
                next = end + 1
            }
            prefix = v
        }
        if prefix >= 0 { emit(prefix) }
        emit(end)
        if bitCount > 0 { bytes.append(UInt8(bitBuffer & 0xFF)) }
        var out = Data([UInt8(minimumCodeSize)])
        var i = 0
        while i < bytes.count {
            let n = min(255, bytes.count - i)
            out.append(UInt8(n))
            out.append(contentsOf: bytes[i..<(i + n)])
            i += n
        }
        out.append(0)
        return out
    }
}
