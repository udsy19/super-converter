import AppKit

/// Quick Look thumbnails for cards, generated off the main thread and cached by file identity + modification date
/// (ux §5.3).
@MainActor
public protocol Thumbnailing: AnyObject {
    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> NSImage?
    func removeCache()
}
