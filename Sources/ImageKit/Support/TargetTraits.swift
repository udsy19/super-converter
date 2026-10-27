import Foundation
import ImageIO
import SuperConverterCore

/// The writer behind a target format. ImageKit writes the first eleven; the rest are other engines' writers fed with
/// an `ImageAsset` (formats §6.2: PSWriter, CGPDF, ODFWriter, VectorizeKit).
enum TargetKind: Sendable, Equatable {
    case jpeg, png, tiff, bmp, gif, heic, psd, ico, icns, avif, webp
    case postScript, pdf, odd, svg, other

    init(_ format: FormatID) {
        switch FormatCatalog.format(format)?.family.rawValue ?? format.rawValue {
        case "jpg", "jpeg", "jfif": self = .jpeg
        case "png": self = .png
        case "tiff", "tif": self = .tiff
        case "bmp": self = .bmp
        case "gif": self = .gif
        case "heic", "heif": self = .heic
        case "psd": self = .psd
        case "ico": self = .ico
        case "icns": self = .icns
        case "avif": self = .avif
        case "webp": self = .webp
        case "eps", "ps": self = .postScript
        case "pdf": self = .pdf
        case "odd": self = .odd
        case "svg": self = .svg
        default: self = .other
        }
    }
}

/// What a target can carry (quality §2.2–§2.3); the pipeline prepares frames to fit.
struct TargetTraits: Sendable {
    let kind: TargetKind
    /// Embeds an ICC profile (or nclx code points).
    let holdsICC: Bool
    let holdsAlpha: Bool
    /// Highest bits per component the writer keeps (32 = float).
    let maxDepth: Int
    let holdsGray: Bool
    let holdsCMYK: Bool
    /// Several frames/pages/sizes in one file.
    let holdsSeveral: Bool

    init(_ kind: TargetKind) {
        self.kind = kind
        switch kind {
        case .jpeg: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (true, false, 8, true, true, false)
        case .png: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (true, true, 16, true, false, false)
        case .tiff: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (true, true, 32, true, true, true)
        case .bmp: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (false, true, 8, false, false, false)
        case .gif: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (false, true, 8, false, false, true)
        case .heic: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (true, true, 16, true, false, false)
        case .psd: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (true, true, 16, true, true, false)
        case .ico: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (false, true, 8, false, false, true)
        case .icns: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (true, true, 8, false, false, true)
        case .avif: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (true, true, 16, true, false, false)
        case .webp: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (true, true, 8, false, false, true)
        case .postScript, .pdf: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (true, true, 16, true, true, true)
        case .odd: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (true, true, 16, true, false, false)
        case .svg, .other: (holdsICC, holdsAlpha, maxDepth, holdsGray, holdsCMYK, holdsSeveral) = (false, true, 8, false, false, false)
        }
    }

    init(_ format: FormatID) { self.init(TargetKind(format)) }

    /// HDR survives (quality §2.2): HEIC and AVIF with a gain map, JPEG with an ISO 21496-1 gain map; ImageIO's HDR
    /// encode requests need macOS 15.
    var carriesHDR: Bool {
        guard #available(macOS 15, *) else { return false }
        switch kind {
        case .heic, .jpeg: return true
        case .avif: return ImageIOSupport.writesAVIF
        default: return false
        }
    }

    /// ICO entries (16–256) and the distinct ICNS sizes (the ten `.iconset` images are 16–512 at @1x and @2x).
    var iconSizes: [Int] {
        switch kind {
        case .ico: return [16, 24, 32, 48, 64, 128, 256]
        case .icns: return [16, 32, 64, 128, 256, 512, 1024]
        default: return []
        }
    }
}

/// What this Mac's ImageIO can do, checked at run time (formats §3.1: never assumed).
enum ImageIOSupport {
    static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    static let writesAVIF = writableTypes.contains("public.avif")
}
