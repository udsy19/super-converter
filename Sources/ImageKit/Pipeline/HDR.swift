import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// HDR sources (quality §2.2): gain-map HEIC/JPEG/AVIF and PQ/HLG images. Detected through ImageIO's auxiliary data and
/// colour spaces at run time, never assumed.
enum HDR {
    /// The working space for HDR maths: Display P3 primaries, linear, extended (1.0 = SDR white).
    static let workingSpace = ColourSpace(icc: CGColorSpaceCreateLinearized(CGColorSpace(name: CGColorSpace.displayP3)!)!.copyICCData()! as Data)!

    static func hasGainMap(_ source: CGImageSource, index: Int = 0) -> Bool {
        if #available(macOS 15, *), CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeISOGainMap) != nil {
            return true
        }
        return CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, kCGImageAuxiliaryDataTypeHDRGainMap) != nil
    }

    /// True when the file's first image holds more than standard range.
    static func isHDR(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        if hasGainMap(source) { return true }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let space = image.colorSpace else { return false }
        return CGColorSpaceUsesITUR_2100TF(space)
    }

    /// The HDR rendition of a file's first image as an extended-linear raster (macOS 15: ImageIO applies the gain map).
    static func decodeHDR(_ url: URL) -> Raster? {
        guard #available(macOS 15, *), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR] as CFDictionary)
        else { return nil }
        return render(CIImage(cgImage: image, options: [.expandToHDR: true]), alpha: ImageIODecoder.hasAlpha(image))
    }

    /// Tone-maps an extended raster to standard range with `CIToneMapHeadroom` (target headroom 1.0); before macOS 15 the
    /// highlights are compressed with extended Reinhard on luminance so nothing hard-clips.
    static func toneMapped(_ raster: Raster) -> Raster {
        let headroom = max(raster.maxComponent, 1)
        if #available(macOS 15, *), let image = raster.cgImage(depth: 32), let filter = CIFilter(name: "CIToneMapHeadroom") {
            filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
            filter.setValue(headroom, forKey: "inputSourceHeadroom")
            filter.setValue(1.0, forKey: "inputTargetHeadroom")
            if let output = filter.outputImage, var mapped = render(output, alpha: raster.hasAlpha, space: raster.space) {
                mapped.extended = false
                mapped.clamp()
                return mapped
            }
        }
        var out = raster
        let s = out.stride
        for i in 0..<out.pixelCount {
            let r = out.data[i * s], g = out.data[i * s + 1], b = out.data[i * s + 2]
            let l = 0.2627 * r + 0.6780 * g + 0.0593 * b
            guard l > 0 else { continue }
            let k = (1 + l / (headroom * headroom)) / (1 + l)
            for c in 0..<3 { out.data[i * s + c] *= k }
        }
        out.extended = false
        out.clamp()
        return out
    }

    /// Renders a Core Image image into an extended-linear float raster in `space` (default: the HDR working space).
    static func render(_ image: CIImage, alpha: Bool, space: ColourSpace = HDR.workingSpace) -> Raster? {
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0, extent.width.isFinite else { return nil }
        let cgSpace = CGColorSpaceCreateExtended(space.cg) ?? space.cg
        let context = CIContext(options: [.workingColorSpace: cgSpace, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        guard let cg = context.createCGImage(image, from: extent, format: .RGBAf, colorSpace: cgSpace),
              var raster = Raster(cgImage: cg, space: space, extended: true) else { return nil }
        if !alpha { raster.removeAlpha() }
        raster.sourceDepth = 16
        return raster
    }
}
