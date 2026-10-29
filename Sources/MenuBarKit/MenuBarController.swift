import AppKit
import Combine
import SuperConverterCore
import SwiftUI

/// The status item and its panel (ux §5.9): a template icon that accepts dropped files and opens the 360 pt panel.
@MainActor
final class MenuBarController: NSObject, MenuBarPresenting, NSWindowDelegate {
    let model: PanelModel
    private(set) var statusItem: NSStatusItem?
    private(set) var panel: PanelWindow?
    private var observers = Set<AnyCancellable>()
    private var outsideClick: Any?

    init(converter: BackgroundConverter) {
        model = PanelModel(converter: converter)
        super.init()
        model.openApp = { [weak self] in self?.close(); Services.window?.show() }
        model.openSettings = { [weak self] in self?.close(); Services.settings?.show(pane: nil) }
    }

    // MARK: MenuBarPresenting

    /// Puts the icon in the menu bar when "Show in menu bar" is on, and follows the setting.
    func install() {
        setVisible(Defaults[.showInMenuBar])
        Defaults.publisher(.showInMenuBar).dropFirst().sink { [weak self] in self?.setVisible($0) }.store(in: &observers)
    }

    func quickActionSwitches() async -> [QuickActionSwitch] {
        await QuickActionSwitches.current?.rows() ?? []
    }

    func setQuickAction(_ target: FormatID, on: Bool) async -> QuickActionSwitch? {
        guard let switches = QuickActionSwitches.current, let action = QuickAction.allCases.first(where: { $0.target == target }) else { return nil }
        try? await switches.elect(action, on: on)
        return await switches.row(action)
    }

    func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: Strings.appName)
            image?.isTemplate = true
            item.button?.image = image
            item.button?.toolTip = Strings.appName
            if let button = item.button {
                let drop = StatusDropView(frame: button.bounds)
                drop.autoresizingMask = [.width, .height]
                drop.onClick = { [weak self] in self?.toggle() }
                drop.onHover = { button.isHighlighted = $0 }
                drop.onDrop = { [weak self] urls in self?.showPanel(with: urls) }
                button.addSubview(drop)
            }
            statusItem = item
        } else if !visible, let item = statusItem {
            close()
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Opens the panel with the files added (dropped on the icon, or passed in).
    func showPanel(with urls: [URL]) {
        open()
        if !urls.isEmpty { model.add(urls) }
        fit()
    }

    // MARK: Panel

    private func toggle() { panel?.isVisible == true ? close() : open() }

    private func open() {
        let window = panel ?? makePanel()
        model.panelOpened()
        fit()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.close() }
        }
    }

    func close() {
        if let monitor = outsideClick { NSEvent.removeMonitor(monitor); outsideClick = nil }
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.panelClosed()
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func makePanel() -> PanelWindow {
        let host = NSHostingView(rootView: PanelView(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        host.wantsLayer = true
        host.layer?.cornerRadius = SCMetrics.MenuBarPanel.radius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        let window = PanelWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        window.contentView = host
        window.delegate = self
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.onCancel = { [weak self] in self?.close() }
        model.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.fit() } }.store(in: &observers)
        panel = window
        return window
    }

    /// Sizes the panel to its content and hangs it under the icon, its right edge near the icon's, kept on screen.
    private func fit() {
        guard let panel, let host = panel.contentView else { return }
        let size = host.fittingSize
        let anchor = statusItem?.button?.window?.frame
        let screen = (anchor.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(x: (anchor?.maxX ?? screen.maxX) + 8 - size.width, y: (anchor?.minY ?? screen.maxY) - 6 - size.height)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = max(origin.y, screen.minY + 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// A borderless panel that can take keys (⌘O, Return, Escape) without activating a Dock presence.
final class PanelWindow: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Covers the status item's button: takes drops and forwards clicks.
final class StatusDropView: NSView {
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var onDrop: ([URL]) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not decoded") }

    override func mouseDown(with event: NSEvent) { onClick() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onHover(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHover(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHover(false)
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }
}
