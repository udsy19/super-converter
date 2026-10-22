import AppKit
import Quartz
import SwiftUI

/// One file in the Quick Look panel and the card it belongs to (a card with several results shows several entries).
struct PreviewEntry: Equatable {
    let url: URL
    let cardID: UUID
}

/// What the Quick Look panel needs from the window: the files to show, where the card's thumbnail is, and the selection
/// the arrow keys move. The window's view model is the real one; tests use a fake.
@MainActor
protocol QuickLookSource: AnyObject {
    var previewEntries: [PreviewEntry] { get }
    /// Index of the entry the panel opens on.
    var previewStartIndex: Int { get }
    /// True while one card is selected, so the arrow keys step between cards rather than between a multi-selection's files.
    var arrowsMoveSelection: Bool { get }
    var gridColumns: Int { get }
    func moveSelection(_ step: Int)
    /// The card's thumbnail frame in the window's content (top-left origin); nil when the card is not on screen.
    func thumbnailFrame(of card: UUID) -> CGRect?
    func transitionImage(of card: UUID) -> NSImage?
}

/// The panel's data source and delegate (ux §5.7): files from the selected cards, arrow keys that move the card
/// selection, and the zoom out of the card's thumbnail. The panel is only touched through the optional `panel` it was
/// handed, so tests call every method with none.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private weak var source: QuickLookSource?
    /// Converts a rect in the window's content (top-left origin) to screen coordinates.
    var screenRect: (CGRect) -> NSRect = { $0 }
    private(set) var panel: QLPreviewPanel?
    private var entries: [PreviewEntry] = []

    init(source: QuickLookSource) { self.source = source }

    // MARK: Panel control (called from the responder chain)

    func begin(_ panel: QLPreviewPanel) {
        self.panel = panel
        panel.dataSource = self
        panel.delegate = self
        refresh()
    }

    func end(_ panel: QLPreviewPanel) {
        if self.panel === panel { self.panel = nil }
        panel.dataSource = nil
        panel.delegate = nil
    }

    /// Re-reads the entries and moves the panel to the selected card (after a selection or a result change).
    func refresh() {
        entries = source?.previewEntries ?? []
        panel?.reloadData()
        if let source, !entries.isEmpty { panel?.currentPreviewItemIndex = min(source.previewStartIndex, entries.count - 1) }
    }

    // MARK: Data source

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { MainActor.assumeIsolated { entries.count } }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { entries.indices.contains(index) ? entries[index].url as NSURL : nil }
    }

    // MARK: Delegate

    /// Arrow keys move the card selection while one card is selected; with several selected the panel pages through them.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            guard let event, event.type == .keyDown, let source, source.arrowsMoveSelection,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
            let step: Int
            switch event.keyCode {
            case 123: step = -1
            case 124: step = 1
            case 125: step = source.gridColumns
            case 126: step = -source.gridColumns
            default: return false
            }
            source.moveSelection(step)
            refresh()
            return true
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        MainActor.assumeIsolated {
            guard let entry = entry(for: item), let frame = source?.thumbnailFrame(of: entry.cardID), !frame.isEmpty else { return .zero }
            return screenRect(frame)
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: QLPreviewItem!, contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        MainActor.assumeIsolated {
            guard let entry = entry(for: item) else { return nil }
            return source?.transitionImage(of: entry.cardID)
        }
    }

    private func entry(for item: QLPreviewItem?) -> PreviewEntry? {
        guard let url = item?.previewItemURL else { return nil }
        return entries.first { $0.url == url }
    }
}

/// Records each card thumbnail's frame while it is on screen, for the panel's zoom.
private struct PreviewSourceModifier: ViewModifier {
    let card: UUID
    @ObservedObject var vm: WindowViewModel

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { vm.thumbnailFrames[card] = $0 }
            .onDisappear { vm.thumbnailFrames[card] = nil }
    }
}

extension View {
    func quickLookSource(card: UUID, vm: WindowViewModel) -> some View { modifier(PreviewSourceModifier(card: card, vm: vm)) }
}
