import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore
import UniformTypeIdentifiers

/// Photo details (quality §2.6). ImageKit keeps them in `ImageMetadata` as ImageIO reads them, so ImageIO writes them back
/// with nothing re-encoded by hand:
/// - `exif`: a binary property list of ImageIO's dictionaries ({Exif}, {ExifAux}, {TIFF}, {GPS}, maker notes, DPI);
/// - `iptc`: a binary property list of the {IPTC} dictionary;
/// - `xmp`: the XMP packet (`CGImageMetadataCreateXMPData`), which also carries everything outside EXIF and IPTC.
enum Metadata {
    /// Keys of a properties dictionary that describe the pixels or the container, not the photo.
    private static let structural: Set<String> = Set(([
        kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyColorModel,
        kCGImagePropertyProfileName, kCGImagePropertyHasAlpha, kCGImagePropertyIsFloat, kCGImagePropertyIsIndexed,
        kCGImagePropertyOrientation, kCGImagePropertyPNGDictionary, kCGImagePropertyJFIFDictionary, kCGImagePropertyGIFDictionary,
        kCGImagePropertyHEICSDictionary, kCGImagePropertyWebPDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyRawDictionary,
        kCGImagePropertyCIFFDictionary, kCGImagePropertyTGADictionary, kCGImagePropertyOpenEXRDictionary, kCGImagePropertyFileContentsDictionary,
        kCGImagePropertyAuxiliaryData, kCGImagePropertyImageCount, kCGImagePropertyImages, kCGImagePropertyThumbnailImages,
        kCGImagePropertyPrimaryImage,
    ] as [CFString]).map { $0 as String } + ["Headroom", "{AVIS}", "{HEIF}", "{8BIM}"])

    // MARK: Reading

    static func capture(_ source: CGImageSource, index: Int) -> ImageMetadata {
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]) ?? [:]
        var photo: [String: Any] = [:]
        for (key, value) in properties where !structural.contains(key) { photo[key] = value }
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        let xmp = CGImageSourceCopyMetadataAtIndex(source, index, nil).flatMap { CGImageMetadataCreateXMPData($0, nil) as Data? }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        return ImageMetadata(exif: photo.isEmpty ? nil : plist(photo), iptc: iptc.flatMap { $0.isEmpty ? nil : plist($0) },
                             xmp: xmp, hasGPS: properties[kCGImagePropertyGPSDictionary as String] != nil, creationDate: date(exif))
    }

    static func plist(_ value: Any) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    private static func dictionary(_ data: Data?) -> [String: Any] {
        guard let data else { return [:] }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
    }

    private static func date(_ exif: [String: Any]?) -> Date? {
        guard let text = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String {
            f.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
            if let d = f.date(from: text + offset) { return d }
        }
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.timeZone = .current
        return f.date(from: text)
    }

    /// The DPI recorded with the photo details (nil when none was).
    static func dpi(_ metadata: ImageMetadata) -> Double? {
        dictionary(metadata.exif)[kCGImagePropertyDPIWidth as String] as? Double
    }

    // MARK: Policy

    /// "All", "All but location" (GPS and the location parts of IPTC/XMP removed) or "None" (formats §5). DPI is not a
    /// photo detail and stays.
    static func filtered(_ metadata: ImageMetadata, policy: ImageSettings.MetadataPolicy) -> ImageMetadata {
        switch policy {
        case .all: return metadata
        case .none:
            let dpi = dpi(metadata).map { [kCGImagePropertyDPIWidth as String: $0, kCGImagePropertyDPIHeight as String: $0] }
            return ImageMetadata(exif: dpi.flatMap(plist), creationDate: metadata.creationDate)
        case .allButLocation:
            var photo = dictionary(metadata.exif)
            photo.removeValue(forKey: kCGImagePropertyGPSDictionary as String)
            var iptc = dictionary(metadata.iptc)
            for key in [kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState, kCGImagePropertyIPTCCountryPrimaryLocationName,
                        kCGImagePropertyIPTCCountryPrimaryLocationCode, kCGImagePropertyIPTCSubLocation,
                        kCGImagePropertyIPTCExtLocationCreated, kCGImagePropertyIPTCExtLocationShown] { iptc.removeValue(forKey: key as String) }
            var xmp = metadata.xmp
            if let data = xmp, let parsed = CGImageMetadataCreateFromXMPData(data as CFData), let copy = CGImageMetadataCreateMutableCopy(parsed) {
                removeLocation(from: copy)
                xmp = CGImageMetadataCreateXMPData(copy, nil) as Data?
            }
            return ImageMetadata(exif: photo.isEmpty ? nil : plist(photo), iptc: iptc.isEmpty ? nil : plist(iptc), xmp: xmp,
                                 hasGPS: false, creationDate: metadata.creationDate)
        }
    }

    private static func isLocation(prefix: String, name: String) -> Bool {
        switch prefix {
        case "exif", "exifEX": return name.hasPrefix("GPS")
        case "photoshop": return ["City", "State", "Country"].contains(name)
        case "Iptc4xmpCore": return ["Location", "CountryCode"].contains(name)
        case "Iptc4xmpExt": return name.hasPrefix("Location")
        default: return false
        }
    }

    private static func removeLocation(from metadata: CGMutableImageMetadata) {
        var paths: [String] = []
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, tag in
            if let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, let name = CGImageMetadataTagCopyName(tag) as String?,
               isLocation(prefix: prefix, name: name) {
                paths.append(path as String)
            }
            return true
        }
        for path in paths { CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString) }
    }

    // MARK: Writing

    /// What to pass ImageIO for a frame: the properties dictionary (EXIF, TIFF, GPS, IPTC, orientation, DPI and the new
    /// pixel size) and the XMP as `CGImageMetadata`, both saying orientation `orientation`.
    static func forWriting(_ metadata: ImageMetadata, width: Int, height: Int, orientation: Int) -> (properties: [CFString: Any], xmp: CGImageMetadata?) {
        var properties: [CFString: Any] = [:]
        for (key, value) in dictionary(metadata.exif) { properties[key as CFString] = value }
        let iptc = dictionary(metadata.iptc)
        if !iptc.isEmpty { properties[kCGImagePropertyIPTCDictionary] = iptc }
        properties[kCGImagePropertyOrientation] = orientation
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        if !tiff.isEmpty || orientation != 1 {
            tiff[kCGImagePropertyTIFFOrientation] = orientation
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        let resolution = (properties[kCGImagePropertyDPIWidth] as? Double) ?? 72
        properties[kCGImagePropertyDPIWidth] = resolution
        properties[kCGImagePropertyDPIHeight] = (properties[kCGImagePropertyDPIHeight] as? Double) ?? resolution
        var xmp: CGImageMetadata?
        if let data = metadata.xmp, let parsed = CGImageMetadataCreateFromXMPData(data as CFData), let copy = CGImageMetadataCreateMutableCopy(parsed) {
            CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
            for path in ["tiff:ImageWidth", "tiff:ImageLength"] { CGImageMetadataRemoveTagWithPath(copy, nil, path as CFString) }
            if CGImageMetadataCopyTagWithPath(copy, nil, "exif:PixelXDimension" as CFString) != nil {
                CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelXDimension, width as CFNumber)
                CGImageMetadataSetValueMatchingImageProperty(copy, kCGImagePropertyExifDictionary, kCGImagePropertyExifPixelYDimension, height as CFNumber)
            }
            xmp = copy
        }
        return (properties, xmp)
    }

    /// The EXIF block (TIFF structure, as WebP's EXIF chunk, AVIF's Exif item and PSD resource 1058 hold it) for these
    /// properties, made by letting ImageIO write a 1×1 JPEG and taking its APP1 payload.
    static func exifBlock(_ properties: [CFString: Any]) -> Data? {
        guard properties[kCGImagePropertyExifDictionary] != nil || properties[kCGImagePropertyTIFFDictionary] != nil
                || properties[kCGImagePropertyGPSDictionary] != nil else { return nil }
        guard let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: ColourSpace.sRGB.cg,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let pixel = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, pixel, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let jpeg = out as Data
        var i = 2
        while i + 4 <= jpeg.count, jpeg[i] == 0xFF {
            let marker = jpeg[i + 1]
            let length = Int(jpeg[i + 2]) << 8 | Int(jpeg[i + 3])
            if marker == 0xE1, i + 10 <= jpeg.count, jpeg[(i + 4)..<(i + 10)] == Data("Exif\0\0".utf8) {
                return jpeg.subdata(in: (i + 10)..<(i + 2 + length))
            }
            if marker == 0xDA { break }
            i += 2 + length
        }
        return nil
    }
}
