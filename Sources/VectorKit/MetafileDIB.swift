import Foundation
import SuperConverterCore

/// Device-independent bitmaps as metafiles carry them → 8-bit RGBA (un-premultiplied, top row first).
enum MetafileDIB {
    struct Image {
        var width: Int
        var height: Int
        var rgba: [UInt8]
        var hasAlpha: Bool
        var embedded: ImageAsset?
        /// The file stored the rows bottom-up (source rectangles count from the bottom).
        var bottomUp = false

        var asset: ImageAsset? {
            if let embedded { return embedded }
            return ImageAsset(frames: [ImageFrame(width: width, height: height, pixels: .rgba8(Data(rgba), bytesPerRow: width * 4), hasAlpha: hasAlpha)])
        }

        /// The sub-rectangle (x, y, w, h) in pixels, clamped; nil when empty.
        func cropped(x: Int, y: Int, w: Int, h: Int) -> Image? {
            guard embedded == nil else { return self }
            let x0 = max(0, x), y0 = max(0, y), x1 = min(width, x + w), y1 = min(height, y + h)
            guard x1 > x0, y1 > y0 else { return nil }
            if x0 == 0, y0 == 0, x1 == width, y1 == height { return self }
            var out = [UInt8](); out.reserveCapacity((x1 - x0) * (y1 - y0) * 4)
            for row in y0..<y1 { out.append(contentsOf: rgba[((row * width + x0) * 4)..<((row * width + x1) * 4)]) }
            return Image(width: x1 - x0, height: y1 - y0, rgba: out, hasAlpha: hasAlpha, embedded: nil, bottomUp: bottomUp)
        }

        /// The source rectangle of a blit (x, y from the top-left, or from the bottom for bottom-up files); the whole
        /// picture for an empty rectangle.
        func source(x: Int, y: Int, w: Int, h: Int) -> Image? {
            if w <= 0 || h <= 0 { return self }
            return cropped(x: x, y: bottomUp ? height - y - h : y, w: w, h: h)
        }

        var averageColour: VectorColour {
            guard embedded == nil, !rgba.isEmpty else { return .black }
            var r = 0, g = 0, b = 0
            let n = rgba.count / 4
            for i in 0..<n { r += Int(rgba[i * 4]); g += Int(rgba[i * 4 + 1]); b += Int(rgba[i * 4 + 2]) }
            return VectorColour(red: Double(r) / Double(n) / 255, green: Double(g) / Double(n) / 255, blue: Double(b) / Double(n) / 255)
        }
    }

    /// Bytes of the colour table and masks that follow a BITMAPINFOHEADER.
    static func infoLength(_ bmi: ByteReader) -> Int {
        let size = bmi.u32(0)
        if size == 12 { let bpp = bmi.u16(10); return 12 + (bpp <= 8 ? (1 << bpp) * 3 : 0) }
        let bpp = bmi.u16(14), comp = bmi.u32(16)
        var used = bmi.u32(32)
        if bpp <= 8 { if used == 0 || used > 256 { used = 1 << bpp } } else { used = 0 }
        return size + (comp == 3 && size == 40 ? 12 : 0) + used * 4
    }

    /// Decodes `bits` described by `bmi`. `honourAlpha` keeps the alpha byte of 32-bit pictures (AlphaBlend); otherwise they are opaque.
    static func decode(bmi info: [UInt8], bits: [UInt8], honourAlpha: Bool = false) -> Image? {
        let bmi = ByteReader(bytes: info)
        let size = bmi.u32(0)
        guard size >= 12, info.count >= size else { return nil }
        var width: Int, height: Int, bpp: Int, comp = 0
        if size == 12 { width = bmi.u16(4); height = bmi.u16(6); bpp = bmi.u16(10) }
        else { width = bmi.i32(4); height = bmi.i32(8); bpp = bmi.u16(14); comp = bmi.u32(16) }
        let topDown = height < 0
        height = abs(height)
        if comp == 4 || comp == 5 {
            guard let asset = ImageBridge.asset(decoding: Data(bits)), let f = asset.frames.first else { return nil }
            return Image(width: f.width, height: f.height, rgba: [], hasAlpha: asset.hasAlpha, embedded: asset)
        }
        guard width > 0, height > 0, width <= 30000, height <= 30000, width * height <= 40_000_000, [1, 4, 8, 16, 24, 32].contains(bpp) else { return nil }

        // Palette.
        var palette: [(UInt8, UInt8, UInt8)] = []
        if bpp <= 8 {
            let entry = size == 12 ? 3 : 4
            var used = size == 12 ? 1 << bpp : bmi.u32(32)
            if used == 0 || used > 256 { used = 1 << bpp }
            let start = size + (comp == 3 && size == 40 ? 12 : 0)
            for i in 0..<used where bmi.has(start + i * entry, entry) {
                palette.append((UInt8(bmi.u8(start + i * entry + 2)), UInt8(bmi.u8(start + i * entry + 1)), UInt8(bmi.u8(start + i * entry))))
            }
        }
        // Bit masks for 16 and 32 bits.
        var masks = [0x7C00, 0x03E0, 0x001F]
        if bpp == 32 { masks = [0x00FF0000, 0x0000FF00, 0x000000FF] }
        if comp == 3 { masks = [bmi.u32(size == 40 ? 40 : 40), bmi.u32(44), bmi.u32(48)] }
        if comp == 3, size >= 52 { masks = [bmi.u32(40), bmi.u32(44), bmi.u32(48)] }
        let alphaMask = comp == 3 && size >= 56 ? bmi.u32(52) : (bpp == 32 ? 0xFF000000 : 0)

        var out = [UInt8](repeating: 255, count: width * height * 4)
        var hasAlpha = false
        let reader = ByteReader(bytes: bits)

        // RLE → indices (bottom-up rows of `width`).
        var indices: [UInt8]?
        if comp == 1 || comp == 2 {
            guard bpp == (comp == 1 ? 8 : 4) else { return nil }
            indices = rle(bits, width: width, height: height, fourBit: comp == 2)
        }
        let stride = ((width * bpp + 31) / 32) * 4
        if indices == nil, reader.count < stride * height {
            // Truncated pixel data: decode what is there, the rest stays white.
            if reader.count < stride { return nil }
        }

        func shiftScale(_ mask: Int) -> (Int, Double) {
            guard mask != 0 else { return (0, 0) }
            var shift = 0, m = mask
            while m & 1 == 0 { m >>= 1; shift += 1 }
            return (shift, Double(m))
        }
        let (rs, rm) = shiftScale(masks[0]), (gs, gm) = shiftScale(masks[1]), (bs, bm) = shiftScale(masks[2]), (asx, am) = shiftScale(alphaMask)

        for row in 0..<height {
            let srcRow = topDown ? row : height - 1 - row
            for x in 0..<width {
                let o = (row * width + x) * 4
                var r: UInt8 = 255, g: UInt8 = 255, b: UInt8 = 255, a: UInt8 = 255
                if let indices {
                    let i = Int(indices[srcRow * width + x])
                    if i < palette.count { (r, g, b) = palette[i] } else { (r, g, b) = (0, 0, 0) }
                } else {
                    let base = srcRow * stride
                    guard base + stride <= reader.count || base + (x * bpp) / 8 < reader.count else { continue }
                    switch bpp {
                    case 1, 4, 8:
                        let bitIndex = x * bpp
                        let byte = reader.u8(base + bitIndex / 8)
                        let shift = 8 - bpp - (bitIndex % 8)
                        let i = (byte >> shift) & ((1 << bpp) - 1)
                        if i < palette.count { (r, g, b) = palette[i] } else { (r, g, b) = (0, 0, 0) }
                    case 16:
                        let v = reader.u16(base + x * 2)
                        r = UInt8(rm == 0 ? 0 : Double((v & masks[0]) >> rs) / rm * 255 + 0.5)
                        g = UInt8(gm == 0 ? 0 : Double((v & masks[1]) >> gs) / gm * 255 + 0.5)
                        b = UInt8(bm == 0 ? 0 : Double((v & masks[2]) >> bs) / bm * 255 + 0.5)
                    case 24:
                        b = UInt8(reader.u8(base + x * 3)); g = UInt8(reader.u8(base + x * 3 + 1)); r = UInt8(reader.u8(base + x * 3 + 2))
                    default:
                        let v = reader.u32(base + x * 4)
                        if comp == 0 {
                            b = UInt8(v & 255); g = UInt8((v >> 8) & 255); r = UInt8((v >> 16) & 255)
                            if honourAlpha { a = UInt8((v >> 24) & 255) }
                        } else {
                            r = UInt8(rm == 0 ? 0 : Double((v & masks[0]) >> rs) / rm * 255 + 0.5)
                            g = UInt8(gm == 0 ? 0 : Double((v & masks[1]) >> gs) / gm * 255 + 0.5)
                            b = UInt8(bm == 0 ? 0 : Double((v & masks[2]) >> bs) / bm * 255 + 0.5)
                            if honourAlpha, am > 0 { a = UInt8(Double((v & alphaMask) >> asx) / am * 255 + 0.5) }
                        }
                    }
                }
                if a != 255 {
                    hasAlpha = true
                    // Premultiplied sources (AC_SRC_ALPHA) → straight.
                    if a > 0 { r = UInt8(min(255, Int(r) * 255 / Int(a))); g = UInt8(min(255, Int(g) * 255 / Int(a))); b = UInt8(min(255, Int(b) * 255 / Int(a))) }
                }
                out[o] = r; out[o + 1] = g; out[o + 2] = b; out[o + 3] = a
            }
        }
        return Image(width: width, height: height, rgba: out, hasAlpha: hasAlpha, embedded: nil, bottomUp: !topDown)
    }

    /// Run-length decoding (BI_RLE8 / BI_RLE4) into palette indices, bottom row first.
    private static func rle(_ data: [UInt8], width: Int, height: Int, fourBit: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height)
        var x = 0, y = 0, i = 0
        func put(_ v: UInt8) { if x < width, y < height { out[y * width + x] = v }; x += 1 }
        while i + 1 < data.count, y < height {
            let n = Int(data[i]), v = data[i + 1]
            i += 2
            if n > 0 {
                for k in 0..<n { put(fourBit ? (k % 2 == 0 ? v >> 4 : v & 15) : v) }
            } else if v == 0 { x = 0; y += 1 }
            else if v == 1 { break }
            else if v == 2 { guard i + 1 < data.count else { break }; x += Int(data[i]); y += Int(data[i + 1]); i += 2 }
            else {
                let count = Int(v)
                let bytes = fourBit ? (count + 1) / 2 : count
                for k in 0..<count {
                    let b = i + (fourBit ? k / 2 : k)
                    guard b < data.count else { break }
                    put(fourBit ? (k % 2 == 0 ? data[b] >> 4 : data[b] & 15) : data[b])
                }
                i += bytes + (bytes % 2)
            }
        }
        return out
    }
}
