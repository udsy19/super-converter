import AppKit
import CryptoKit
import Foundation
import QuickLookThumbnailing
import SuperConverterCore

/// Quick Look thumbnails for cards (ux §5.3), cached on disk by the file's identity and modification date so a file shows
/// instantly the second time. Generation runs off the main thread (Quick Look's own queue).
@MainActor
public final class ThumbnailService: Thumbnailing {
    public typealias Generator = @Sendable (URL, CGSize, CGFloat) async -> NSImage?

    private let cacheFolder: () -> URL
    private let generate: Generator
    private let maxEntries: Int

    public init(cacheFolder: @escaping () -> URL = { SuperConverterPaths.thumbnails }, maxEntries: Int = 2000,
                generator: @escaping Generator = ThumbnailService.quickLook) {
        self.cacheFolder = cacheFolder; self.maxEntries = maxEntries; self.generate = generator
    }

    public func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let file = cacheFolder().appendingPathComponent(Self.key(for: url, size: size, scale: scale) + ".png")
        if let cached = NSImage(contentsOf: file) { return cached }
        guard let image = await generate(url, size, scale) else { return nil }
        if let png = Self.pngData(image) {
            try? png.write(to: file, options: .atomic)
            prune()
        }
        return image
    }

    public func removeCache() {
        let folder = cacheFolder()
        for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Cache file name: path, size and modification date of the file, and the size asked for.
    static func key(for url: URL, size: CGSize, scale: CGFloat) -> String {
        var fresh = url   // a URL caches its resource values; a card keeps one URL while the file changes
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let identity = "\(url.standardizedFileURL.path)|\(values?.fileSize ?? 0)|\(modified)|\(Int(size.width))x\(Int(size.height))@\(scale)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Keeps the newest `maxEntries` thumbnails.
    private func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheFolder(), includingPropertiesForKeys: keys),
              files.count > maxEntries else { return }
        let oldestFirst = files.sorted {
            ((try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        for file in oldestFirst.prefix(files.count - maxEntries) { try? FileManager.default.removeItem(at: file) }
    }

    /// Quick Look's generator: the best representation it can make, nil when it has none for this kind of file.
    public nonisolated static let quickLook: Generator = { url, size, scale in
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}
