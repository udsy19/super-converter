import Accelerate
import CoreGraphics
import Foundation

/// The pipeline's working image (quality §2.1): 32-bit float, un-premultiplied, colour components then alpha, in `space`.
/// Gray has one component, RGB three, CMYK four. Values of an `extended` raster may exceed 1 (HDR in an extended-linear
/// space); every other raster stays within 0…1 between steps.
struct Raster: @unchecked Sendable {
    var width: Int
    var height: Int
    var space: ColourSpace
    var hasAlpha: Bool
    var data: [Float]
    /// Bits per component of the pixels this came from: 8, 16, or 32 for float ("Bit depth: Keep").
    var sourceDepth: Int
    var extended = false

    var stride: Int { space.components + (hasAlpha ? 1 : 0) }
    var pixelCount: Int { width * height }

    init(width: Int, height: Int, space: ColourSpace, hasAlpha: Bool, data: [Float], sourceDepth: Int, extended: Bool = false) {
        self.width = width; self.height = height; self.space = space; self.hasAlpha = hasAlpha
        self.data = data; self.sourceDepth = sourceDepth; self.extended = extended
    }

    // MARK: From Core Graphics

    /// Reads a `CGImage` as floats without any colour conversion: the pixels are labelled with `space`, which must have the
    /// image's number of colour components (indexed images are expanded through their palette first).
    init?(cgImage image: CGImage, space: ColourSpace, extended: Bool = false) {
        var source = image
        if let imageSpace = image.colorSpace, imageSpace.model == .indexed, let base = imageSpace.baseColorSpace {
            guard let expanded = Raster.expandIndexed(image, base: base) else { return nil }
            source = expanded
        } else if image.pixelFormatInfo != .packed, let unpacked = Raster.unpack(image) {
            source = unpacked   // 10-bit packed pixels (HEIC, AVIF) are beyond vImage's layouts
        }
        let alpha: Bool = {
            switch source.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: false
            default: true
            }
        }()
        let comps = space.components
        guard (source.colorSpace?.numberOfComponents ?? comps) == comps else { return nil }
        // Relabel with our space (same bytes) so vImage sees one colour space on both sides and converts only the layout.
        let labelSpace = extended ? (CGColorSpaceCreateExtended(space.cg) ?? space.cg) : space.cg
        guard let provider = source.dataProvider,
              let relabelled = CGImage(width: source.width, height: source.height, bitsPerComponent: source.bitsPerComponent,
                                       bitsPerPixel: source.bitsPerPixel, bytesPerRow: source.bytesPerRow, space: labelSpace,
                                       bitmapInfo: source.bitmapInfo, provider: provider, decode: source.decode,
                                       shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let channels = comps + (alpha ? 1 : 0)
        var format = vImage_CGImageFormat(
            bitsPerComponent: 32, bitsPerPixel: UInt32(32 * channels), colorSpace: Unmanaged.passUnretained(labelSpace),
            bitmapInfo: CGBitmapInfo(rawValue: (alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue)
                                     | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            version: 0, decode: nil, renderingIntent: .defaultIntent)
        var buffer = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, relabelled, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        defer { free(buffer.data) }
        let w = Int(buffer.width), h = Int(buffer.height), rowFloats = w * channels
        var data = [Float](repeating: 0, count: w * h * channels)
        data.withUnsafeMutableBufferPointer { d in
            for y in 0..<h {
                let row = buffer.data.advanced(by: y * buffer.rowBytes).assumingMemoryBound(to: Float.self)
                (d.baseAddress! + y * rowFloats).update(from: row, count: rowFloats)
            }
        }
        let isFloat = source.bitmapInfo.contains(.floatComponents)
        self.init(width: w, height: h, space: space, hasAlpha: alpha, data: data,
                  sourceDepth: isFloat ? 32 : (source.bitsPerComponent > 8 ? 16 : 8), extended: extended || isFloat)
    }

    /// 16 bits per component drawn in the image's own colour space (no colour conversion: the spaces are equal).
    private static func unpack(_ image: CGImage) -> CGImage? {
        guard let space = image.colorSpace, space.model == .rgb || space.model == .monochrome else { return nil }
        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let info = (alpha ? CGImageAlphaInfo.premultipliedLast : space.model == .rgb ? .noneSkipLast : .none).rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 16, bytesPerRow: 0,
                                      space: space, bitmapInfo: info) else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func expandIndexed(_ image: CGImage, base: CGColorSpace) -> CGImage? {
        let channels = base.numberOfComponents + 1
        var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: UInt32(8 * channels), colorSpace: Unmanaged.passUnretained(base),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), version: 0, decode: nil,
                                          renderingIntent: .defaultIntent)
        var buffer = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return nil }
        defer { free(buffer.data) }
        var error = vImage_Error()
        return vImageCreateCGImageFromBuffer(&buffer, &format, nil, nil, vImage_Flags(kvImageNoFlags), &error)?.takeRetainedValue()
    }

    // MARK: To Core Graphics

    /// A `CGImage` at 8 or 16 bits per component (rounded; dither first with `Dither.quantise`), or 32-bit float.
    /// Alpha stays un-premultiplied (kCGImageAlphaLast), which ImageIO's encoders keep as is.
    func cgImage(depth: Int) -> CGImage? {
        let alpha = hasAlpha
        let comps = space.components
        let channels = stride
        let count = pixelCount
        var bytes = Data(count: count * channels * (depth == 8 ? 1 : depth == 16 ? 2 : 4))
        data.withUnsafeBufferPointer { src in
            bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                switch depth {
                case 8:
                    let d = raw.bindMemory(to: UInt8.self)
                    for i in 0..<(count * channels) { d[i] = UInt8(min(max(src[i], 0), 1) * 255 + 0.5) }
                case 16:
                    let d = raw.bindMemory(to: UInt16.self)
                    for i in 0..<(count * channels) { d[i] = UInt16(min(max(src[i], 0), 1) * 65535 + 0.5).littleEndian }
                default:
                    let d = raw.bindMemory(to: Float.self)
                    for i in 0..<(count * channels) { d[i] = (i % channels == comps) ? min(max(src[i], 0), 1) : src[i] }
                }
            }
        }
        let bpc = depth == 8 ? 8 : depth == 16 ? 16 : 32
        var info = alpha ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue
        if bpc == 16 { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        if bpc == 32 { info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue }
        let cgSpace = bpc == 32 && extended ? (CGColorSpaceCreateExtended(space.cg) ?? space.cg) : space.cg
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: bpc, bitsPerPixel: bpc * channels,
                       bytesPerRow: width * channels * bpc / 8, space: cgSpace, bitmapInfo: CGBitmapInfo(rawValue: info),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Pixel helpers

    /// True when some pixel is not fully opaque.
    var hasTransparency: Bool {
        guard hasAlpha else { return false }
        let s = stride
        var i = s - 1
        while i < data.count { if data[i] < 1 - 1e-6 { return true }; i += s }
        return false
    }

    /// The largest colour value (HDR headroom of an extended raster).
    var maxComponent: Float {
        var m: Float = 0
        let s = stride, comps = space.components
        for i in 0..<pixelCount { for c in 0..<comps { m = max(m, data[i * s + c]) } }
        return m
    }

    /// Drops the alpha channel (after flattening or when it is fully opaque).
    mutating func removeAlpha() {
        guard hasAlpha else { return }
        let s = stride, comps = space.components
        var out = [Float](repeating: 0, count: pixelCount * comps)
        for i in 0..<pixelCount { for c in 0..<comps { out[i * comps + c] = data[i * s + c] } }
        data = out; hasAlpha = false
    }

    /// Adds an opaque alpha channel.
    mutating func addAlpha() {
        guard !hasAlpha else { return }
        let comps = space.components, s = comps + 1
        var out = [Float](repeating: 1, count: pixelCount * s)
        for i in 0..<pixelCount { for c in 0..<comps { out[i * s + c] = data[i * comps + c] } }
        data = out; hasAlpha = true
    }

    /// The colour components only, packed (for ColorSync), and the alpha plane.
    func splitAlpha() -> (colour: [Float], alpha: [Float]?) {
        guard hasAlpha else { return (data, nil) }
        let s = stride, comps = space.components
        var colour = [Float](repeating: 0, count: pixelCount * comps)
        var alpha = [Float](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            for c in 0..<comps { colour[i * comps + c] = data[i * s + c] }
            alpha[i] = data[i * s + comps]
        }
        return (colour, alpha)
    }

    static func join(colour: [Float], components: Int, alpha: [Float]?) -> [Float] {
        guard let alpha else { return colour }
        let s = components + 1
        var out = [Float](repeating: 0, count: alpha.count * s)
        for i in 0..<alpha.count {
            for c in 0..<components { out[i * s + c] = colour[i * components + c] }
            out[i * s + components] = alpha[i]
        }
        return out
    }

    /// Clamps colour components to 0…1 (and alpha always); extended rasters keep values above 1.
    mutating func clamp() {
        let s = stride, comps = space.components, ext = extended, count = pixelCount
        data.withUnsafeMutableBufferPointer { d in
            for i in 0..<count {
                for c in 0..<comps { d[i * s + c] = ext ? max(d[i * s + c], 0) : min(max(d[i * s + c], 0), 1) }
                if s > comps { d[i * s + comps] = min(max(d[i * s + comps], 0), 1) }
            }
        }
    }
}

// MARK: Half floats (`ImageFrame.Pixels.rgbaHalf`), through vImage so x86_64 needs no Float16 type.

enum HalfFloat {
    static func toFloat(_ data: Data, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&s, &d, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }
}
