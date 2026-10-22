import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore

/// The one or two facts that matter for a kind of file (ux §5.3): pixel size, pages, duration, sample rate. Read from the
/// file's header only; kinds whose facts need a reader (slides in a deck, chapters in a book) say nothing here, and their
/// engines do not publish a contract for it yet.
enum FileFacts {
    static func read(_ url: URL, format: FormatID?) async -> [String] {
        guard let format, let category = FormatCatalog.format(format)?.category else { return [] }
        switch category {
        case .image: return imageFacts(url)
        case .document where format.rawValue == "pdf": return pdfFacts(url)
        case .video: return await mediaFacts(url, video: true)
        case .audio: return await mediaFacts(url, video: false)
        default: return []
        }
    }

    static func imageFacts(_ url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return [] }
        return ["\(w) × \(h)"]
    }

    static func pdfFacts(_ url: URL) -> [String] {
        guard let doc = CGPDFDocument(url as CFURL), !doc.isEncrypted || doc.isUnlocked else { return [] }
        return [Formatting.count(doc.numberOfPages, "page", "pages")]
    }

    static func mediaFacts(_ url: URL, video: Bool) async -> [String] {
        let asset = AVURLAsset(url: url)
        var facts: [String] = []
        if video {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize) {
                let long = max(size.width, size.height)
                if long >= 3800 { facts.append("4K") } else if long >= 1900 { facts.append("1080p") } else if long >= 1200 { facts.append("720p") }
            }
        } else if let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let descriptions = try? await track.load(.formatDescriptions),
                  let description = descriptions.first,
                  let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            let khz = basic.pointee.mSampleRate / 1000
            facts.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
        }
        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            facts.append(clock(duration.seconds))
        }
        return facts
    }

    /// "2:14", "41:20", "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

extension FileFacts {
    /// Facts that change the default target (ux §6.1): transparency and animation, read from the header.
    static func traits(_ url: URL, format: FormatID) -> DefaultTargets.Traits {
        switch format.rawValue {
        case "gif", "webp", "avif", "png":
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return .init() }
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            return .init(hasTransparency: props?[kCGImagePropertyHasAlpha] as? Bool ?? false, isAnimated: CGImageSourceGetCount(source) > 1)
        case "ogg":
            return .init(hasVideo: false)
        default:
            return .init()
        }
    }
}
