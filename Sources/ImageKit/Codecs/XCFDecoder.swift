import CoreGraphics
import Foundation
import SuperConverterCore

/// GIMP XCF (formats §3.2, spec: GIMP's `devel-docs/xcf.txt`): versions 0–22 (64-bit offsets from v11), every precision
/// (8/16/32-bit integer, half/float/double, linear or perceptual), RGB/gray/indexed with or without alpha, tiles stored
/// raw, RLE or zlib. Visible layers are composited bottom to top with their offsets, opacity, masks and the Normal,
/// Multiply, Screen and Overlay modes (others composite as Normal); group layers contribute through their children.
enum XCFDecoder {
    struct Decoded { var raster: Raster; var dpi: Double; var visibleLayers: Int }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0
        let wide: Bool
        mutating func u8() throws -> Int { guard i >= 0, i < bytes.count else { throw ConversionError.damaged("xcf") }; i += 1; return Int(bytes[i - 1]) }
        mutating func u32() throws -> Int {
            guard i >= 0, i <= bytes.count - 4 else { throw ConversionError.damaged("xcf") }
            defer { i += 4 }
            return Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        }
        mutating func i32() throws -> Int { Int(Int32(truncatingIfNeeded: try u32())) }
        mutating func f32() throws -> Float { Float(bitPattern: UInt32(try u32())) }
        mutating func pointer() throws -> Int { wide ? (try u32() << 32 | u32()) : try u32() }
        mutating func string() throws -> String {
            let n = try u32()
            guard n > 0 else { return "" }
            guard n <= bytes.count - i else { throw ConversionError.damaged("xcf") }
            defer { i += n }
            return String(decoding: bytes[i..<(i + n - 1)], as: UTF8.self)
        }
        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard i >= 0, n >= 0, n <= bytes.count - i else { throw ConversionError.damaged("xcf") }
            defer { i += n }
            return bytes[i..<(i + n)]
        }
    }

    private enum Precision {
        case int8, int16, int32, half, float, double
        var bytes: Int {
            switch self {
            case .int8: 1
            case .int16, .half: 2
            case .int32, .float: 4
            case .double: 8
            }
        }
        var isFloat: Bool { self == .half || self == .float || self == .double }
    }

    private struct Layer {
        var type = 0, x = 0, y = 0
        var opacity: Float = 1, visible = true, mode = 0, isGroup = false
        var hierarchy = 0, mask = 0, applyMask = false
    }

    static func decode(_ data: Data) throws -> Decoded {
        let bytes = [UInt8](data)
        guard bytes.count > 14, bytes[0..<9].elementsEqual("gimp xcf ".utf8) else { throw ConversionError.damaged("xcf") }
        let tag = String(decoding: bytes[9..<13], as: UTF8.self)
        let version = tag == "file" ? 0 : Int(tag.dropFirst()) ?? 0
        var r = Reader(bytes: bytes, i: 14, wide: version >= 11)
        let width = try r.u32(), height = try r.u32(), baseType = try r.u32()
        var precision = Precision.int8, linear = false
        if version >= 4 {
            let p = try r.u32()
            if version < 7 {
                switch p {
                case 1: precision = .int16
                case 2: precision = .int32; linear = true
                case 3: precision = .half; linear = true
                case 4: precision = .float; linear = true
                default: break
                }
            } else {
                linear = p % 100 == 0
                switch p / 100 {
                case 2: precision = .int16
                case 3: precision = .int32
                case 5: precision = .half
                case 6: precision = .float
                case 7: precision = .double
                default: precision = .int8
                }
            }
        }
        // GIMP's limit is 524,288 pixels a side. The canvas is allocated whole, so it may not claim more than a layer covering it
        // could describe — one 4-byte tile pointer per 64 × 64 tile, 1024 pixels for every byte of the file.
        guard (1...524_288).contains(width), (1...524_288).contains(height), width * height < 1 << 30, width * height <= bytes.count * 1024 else {
            throw ConversionError.damaged("xcf")
        }

        var compression = 0, dpi = 72.0, colormap: [UInt8] = [], icc: Data?
        try properties(&r) { type, payload in
            var p = Reader(bytes: Array(payload), wide: false)
            switch type {
            case 17: compression = try p.u8()
            case 19: dpi = Double(try p.f32())
            case 1: colormap = Array(try p.take(3 * (try p.u32())))
            case 21:
                while p.i < p.bytes.count {
                    let name = try p.string(); _ = try p.u32()
                    let body = try p.take(try p.u32())
                    if name == "icc-profile" { icc = Data(body) }
                }
            default: break
            }
        }
        var layerPointers: [Int] = []
        while true { let p = try r.pointer(); if p == 0 { break }; layerPointers.append(p) }

        // The image profile (or sRGB / Gray Gamma 2.2), linearised for linear precisions.
        let gray = baseType == 1
        var encoded: ColourSpace = gray ? .grayGamma22 : .sRGB
        if let icc, let s = ColourSpace(icc: icc), s.model == (gray ? .gray : .rgb) { encoded = s }
        let space = linear ? (encoded.linear ?? encoded) : encoded
        let comps = gray ? 1 : 3

        var layers: [Layer] = []
        for pointer in layerPointers {
            r.i = pointer
            var layer = Layer()
            _ = try r.u32(); _ = try r.u32()
            layer.type = try r.u32()
            _ = try r.string()
            try properties(&r) { type, payload in
                var p = Reader(bytes: Array(payload), wide: false)
                switch type {
                // Opacity is 0…1; a damaged float (infinite, NaN) would turn the whole composite into NaN.
                case 6: layer.opacity = min(Float(try p.u32()) / 255, 1)
                case 33: let o = try p.f32(); layer.opacity = o.isFinite ? min(max(o, 0), 1) : 0
                case 8: layer.visible = try p.u32() != 0
                case 15: layer.x = try p.i32(); layer.y = try p.i32()
                case 7: layer.mode = try p.u32()
                case 29: layer.isGroup = true
                case 11: layer.applyMask = try p.u32() != 0
                default: break
                }
            }
            layer.hierarchy = try r.pointer()
            layer.mask = try r.pointer()
            layers.append(layer)
        }

        // Composite (premultiplied, in the image's own encoding) bottom to top.
        var canvas = [Float](repeating: 0, count: width * height * (comps + 1))
        var visibleCount = 0
        for layer in layers.reversed() where layer.visible && !layer.isGroup && layer.opacity > 0 {
            visibleCount += 1
            // Indexed layers are always 8-bit (xcf.txt), so a pixel is a palette index.
            guard layer.type < 4 || precision == .int8 else { throw ConversionError.damaged("xcf") }
            let hasAlpha = layer.type % 2 == 1
            let channels = (layer.type <= 1 ? 3 : 1) + (hasAlpha ? 1 : 0)
            let pixels = try readHierarchy(bytes, at: layer.hierarchy, wide: r.wide, compression: compression, precision: precision,
                                           expectedChannels: channels)
            var mask: [Float]?
            if layer.applyMask, layer.mask != 0 {
                var m = Reader(bytes: bytes, i: layer.mask, wide: r.wide)
                _ = try m.u32(); _ = try m.u32(); _ = try m.string()
                try properties(&m) { _, _ in }
                mask = try readHierarchy(bytes, at: try m.pointer(), wide: r.wide, compression: compression, precision: precision,
                                         expectedChannels: 1).values
            }
            let lw = pixels.width
            for ly in 0..<pixels.height {
                let cy = ly + layer.y
                guard cy >= 0, cy < height else { continue }
                for lx in 0..<lw {
                    let cx = lx + layer.x
                    guard cx >= 0, cx < width else { continue }
                    let si = (ly * lw + lx) * channels
                    var colour = [Float](repeating: 0, count: comps)
                    if layer.type >= 4 {
                        let index = Int(pixels.values[si] * 255 + 0.5)
                        for c in 0..<3 where index * 3 + c < colormap.count { colour[c] = Float(colormap[index * 3 + c]) / 255 }
                    } else if comps == 3 && layer.type >= 2 {
                        colour = [pixels.values[si], pixels.values[si], pixels.values[si]]
                    } else {
                        for c in 0..<comps { colour[c] = pixels.values[si + c] }
                    }
                    var a = hasAlpha ? pixels.values[si + channels - 1] : 1
                    if let mask { a *= mask[ly * lw + lx] }
                    a *= layer.opacity
                    guard a > 0 else { continue }
                    let di = (cy * width + cx) * (comps + 1)
                    let ab = canvas[di + comps]
                    for c in 0..<comps {
                        let cb = ab > 0 ? canvas[di + c] / ab : 0
                        let cs = colour[c]
                        let cr = (1 - ab) * cs + ab * blend(layer.mode, cb, cs)
                        canvas[di + c] = a * cr + (1 - a) * canvas[di + c]
                    }
                    canvas[di + comps] = a + ab * (1 - a)
                }
            }
        }
        for i in 0..<(width * height) {
            let a = canvas[i * (comps + 1) + comps]
            for c in 0..<comps { canvas[i * (comps + 1) + c] = a > 0 ? min(max(canvas[i * (comps + 1) + c] / a, 0), precision.isFloat ? .infinity : 1) : 0 }
        }
        let depth = precision.isFloat ? 32 : precision == .int8 ? 8 : 16
        var raster = Raster(width: width, height: height, space: space, hasAlpha: true, data: canvas, sourceDepth: depth, extended: precision.isFloat)
        if !raster.hasTransparency { raster.removeAlpha() }
        if linear && !precision.isFloat {
            // Integer linear images are delivered in the profile's own encoding so 8/16-bit outputs do not band.
            let (colour, alpha) = raster.splitAlpha()
            if let converted = ColourTransform.convert(colour, pixelCount: raster.pixelCount, from: space, to: encoded, blackPointCompensation: false) {
                raster.data = Raster.join(colour: converted.map { min(max($0, 0), 1) }, components: comps, alpha: alpha)
                raster.space = encoded
            }
        }
        return Decoded(raster: raster, dpi: dpi, visibleLayers: visibleCount)
    }

    private static func blend(_ mode: Int, _ b: Float, _ s: Float) -> Float {
        switch mode {
        case 3, 30: return b * s                                         // Multiply (legacy, GIMP 2.10)
        case 4, 31: return 1 - (1 - b) * (1 - s)                         // Screen
        case 23: return b < 0.5 ? 2 * b * s : 1 - 2 * (1 - b) * (1 - s)  // Overlay (GIMP 2.10)
        case 5: return b * (b + 2 * s * (1 - b))                         // Overlay (legacy GIMP, a soft light)
        default: return s                                                // Normal and the rest
        }
    }

    private static func properties(_ r: inout Reader, _ handle: (Int, ArraySlice<UInt8>) throws -> Void) throws {
        while true {
            let type = try r.u32(), length = try r.u32()
            if type == 0 { break }
            try handle(type, try r.take(length))
        }
    }

    /// The first (full-resolution) level of a hierarchy as floats (channels interleaved).
    private static func readHierarchy(_ bytes: [UInt8], at offset: Int, wide: Bool, compression: Int, precision: Precision,
                                      expectedChannels: Int) throws -> (width: Int, height: Int, values: [Float]) {
        var r = Reader(bytes: bytes, i: offset, wide: wide)
        let width = try r.u32(), height = try r.u32(), bpp = try r.u32()
        r.i = try r.pointer()
        let lw = try r.u32(), lh = try r.u32()
        guard lw == width, lh == height, bpp == expectedChannels * precision.bytes, (1...524_288).contains(width), (1...524_288).contains(height),
              width * height < 1 << 30 else {
            throw ConversionError.damaged("xcf")
        }
        var tiles: [Int] = []
        while true {
            let p = try r.pointer()
            if p == 0 { break }
            guard p > 0, p < bytes.count else { throw ConversionError.damaged("xcf") }
            tiles.append(p)
        }
        let tilesAcross = (width + 63) / 64, tilesDown = (height + 63) / 64
        guard tiles.count >= tilesAcross * tilesDown else { throw ConversionError.damaged("xcf") }
        var values = [Float](repeating: 0, count: width * height * expectedChannels)
        for t in 0..<(tilesAcross * tilesDown) {
            let tx = (t % tilesAcross) * 64, ty = (t / tilesAcross) * 64
            let tw = min(64, width - tx), th = min(64, height - ty)
            let count = tw * th
            let raw: [UInt8]
            switch compression {
            case 0:
                guard count * bpp <= bytes.count - tiles[t] else { throw ConversionError.damaged("xcf") }
                raw = Array(bytes[tiles[t]..<(tiles[t] + count * bpp)])
            case 1:
                raw = try unRLE(bytes, from: tiles[t], pixels: count, bpp: bpp)
            case 2:
                guard let inflated = Zlib.decompress(Data(bytes[tiles[t]...]), expectedSize: count * bpp) else {
                    throw ConversionError.damaged("xcf")
                }
                raw = [UInt8](inflated)
            default:
                throw ConversionError.failed("This XCF compression isn’t supported.")
            }
            for p in 0..<count {
                let x = tx + p % tw, y = ty + p / tw
                for c in 0..<expectedChannels {
                    values[(y * width + x) * expectedChannels + c] = sample(raw, (p * expectedChannels + c) * precision.bytes, precision)
                }
            }
        }
        return (width, height, values)
    }

    private static func sample(_ raw: [UInt8], _ o: Int, _ precision: Precision) -> Float {
        switch precision {
        case .int8: return Float(raw[o]) / 255
        case .int16: return Float(Int(raw[o]) << 8 | Int(raw[o + 1])) / 65535
        case .int32: return Float(Double(UInt32(raw[o]) << 24 | UInt32(raw[o + 1]) << 16 | UInt32(raw[o + 2]) << 8 | UInt32(raw[o + 3])) / 4294967295)
        case .half: return HalfFloat.toFloat(Data([raw[o + 1], raw[o]]), count: 1)[0]
        case .float: return Float(bitPattern: UInt32(raw[o]) << 24 | UInt32(raw[o + 1]) << 16 | UInt32(raw[o + 2]) << 8 | UInt32(raw[o + 3]))
        case .double:
            var bits: UInt64 = 0
            for k in 0..<8 { bits = bits << 8 | UInt64(raw[o + k]) }
            return Float(Double(bitPattern: bits))
        }
    }

    /// XCF RLE: each byte plane of the tile (all pixels' byte 0, then byte 1, …) coded with short and long runs.
    private static func unRLE(_ bytes: [UInt8], from start: Int, pixels: Int, bpp: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: pixels * bpp)
        var i = start
        func next() throws -> Int { guard i < bytes.count else { throw ConversionError.damaged("xcf") }; i += 1; return Int(bytes[i - 1]) }
        for plane in 0..<bpp {
            var n = 0
            while n < pixels {
                let op = try next()
                if op <= 126 {
                    let v = UInt8(try next())
                    for _ in 0...op where n < pixels { out[n * bpp + plane] = v; n += 1 }
                } else if op == 127 {
                    let length = try next() << 8 | next()
                    let v = UInt8(try next())
                    for _ in 0..<length where n < pixels { out[n * bpp + plane] = v; n += 1 }
                } else if op == 128 {
                    let length = try next() << 8 | next()
                    for _ in 0..<length where n < pixels { out[n * bpp + plane] = UInt8(try next()); n += 1 }
                } else {
                    for _ in 0..<(256 - op) where n < pixels { out[n * bpp + plane] = UInt8(try next()); n += 1 }
                }
            }
        }
        return out
    }
}
