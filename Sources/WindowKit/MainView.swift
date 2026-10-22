import SuperConverterCore
import SwiftUI

/// The window's content (ux §4): toolbar, then the drop zone or the cards, then the action bar.
struct MainView: View {
    @ObservedObject var vm: WindowViewModel

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(vm: vm)
            Rectangle().fill(Color.scHairline).frame(height: 1)
            ZStack {
                if vm.phase == .empty {
                    DropZoneView(vm: vm)
                } else {
                    CardsView(vm: vm)
                    if let drag = vm.drag { DragOverlay(summary: drag) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if vm.phase != .empty { ActionBarView(vm: vm) }
        }
        .background(Color.scWindow)
        .background(KeyCommands(vm: vm))
        .sheet(item: Binding(get: { vm.options }, set: { if $0 == nil { vm.options = nil } })) { session in
            OptionsSheetView(model: session.model, cancel: { vm.cancelOptions() }, done: { vm.applyOptions() })
        }
        .frame(minWidth: SCMetrics.Window.minimumSize.width, minHeight: SCMetrics.Window.minimumSize.height)
    }
}

/// The unified toolbar's content: title and subtitle on the left; Add Files, Grid/List and Clear on the right (ux §3.5).
struct ToolbarView: View {
    @ObservedObject var vm: WindowViewModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Strings.appName).font(.system(size: SCMetrics.Toolbar.titleSize, weight: .bold)).foregroundStyle(Color.scLabel)
                if let subtitle = vm.subtitle {
                    Text(subtitle).font(.system(size: SCMetrics.Toolbar.subtitleSize)).monospacedDigit().foregroundStyle(Color.scSecondary)
                }
            }
            .padding(.leading, 90)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 12)
            HStack(spacing: 14) {
                Button { vm.chooseFiles() } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .regular)).foregroundStyle(Color.scSecondary).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).accessibilityLabel("Add files").help("Add files (⌘O)")
                ViewModeControl(vm: vm)
                Button { vm.clear() } label: {
                    Image(systemName: "trash").font(.system(size: 15, weight: .regular)).foregroundStyle(Color.scSecondary).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).disabled(vm.cards.isEmpty)
                .accessibilityLabel("Clear all").help("Remove all files from the list")
            }
            .padding(.trailing, 22)
        }
        .frame(height: SCMetrics.Window.toolbarHeight)
        .background(WindowDragArea())
    }
}

/// The grid/list segmented control, 24 tall.
private struct ViewModeControl: View {
    @ObservedObject var vm: WindowViewModel

    var body: some View {
        HStack(spacing: 0) {
            segment(.grid, symbol: "square.grid.2x2", label: "Grid view", key: "1")
            segment(.list, symbol: "list.bullet", label: "List view", key: "2")
        }
        .padding(2).background(RoundedRectangle(cornerRadius: 7).fill(Color.scControl))
    }

    private func segment(_ mode: ViewMode, symbol: String, label: String, key: KeyEquivalent) -> some View {
        let selected = vm.viewMode == mode
        return Button { vm.setViewMode(mode) } label: {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(selected ? Color.scLabel : Color.scSecondary)
                .frame(width: 32, height: SCMetrics.Window.segmentedHeight - 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.scCard : .clear).shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help("\(label) (⌘\(String(key.character)))")
    }
}

/// An empty AppKit view that lets the window be dragged by the toolbar area (the SwiftUI content has no title bar).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView { override var mouseDownCanMoveWindow: Bool { true } }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
}

/// Grid or list of cards, with the keyboard model (ux §6.5).
struct CardsView: View {
    @ObservedObject var vm: WindowViewModel

    var body: some View {
        GeometryReader { proxy in
            Group {
                if vm.usesList(width: proxy.size.width) { ListView(vm: vm) } else { grid(width: proxy.size.width) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { vm.moveSelection(-1); return .handled }
        .onKeyPress(.rightArrow) { vm.moveSelection(1); return .handled }
        .onKeyPress(.upArrow) { vm.moveSelection(-vm.columns); return .handled }
        .onKeyPress(.downArrow) { vm.moveSelection(vm.columns); return .handled }
        .onKeyPress(.space) { vm.quickLookSelection(); return .handled }
        .onKeyPress(.delete) { vm.removeSelected(); return .handled }
        .onKeyPress(.deleteForward) { vm.removeSelected(); return .handled }
        .onKeyPress("t") { if let card = vm.selectedCards.first(where: \.isEditable) { vm.pickerFor = card.id; return .handled }; return .ignored }
    }

    private func grid(width: CGFloat) -> some View {
        let columnWidth = SCMetrics.Grid.columnWidth, gap = SCMetrics.Grid.gap
        let count = max(1, Int((width - 2 * SCMetrics.Grid.paddingX + gap) / (columnWidth + gap)))
        let columns = Array(repeating: GridItem(.fixed(columnWidth), spacing: gap), count: count)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: gap) {
                ForEach(vm.displayCards) { card in CardView(card: card, vm: vm) }
            }
            .padding(.horizontal, SCMetrics.Grid.paddingX).padding(.vertical, SCMetrics.Grid.paddingY)
            .frame(maxWidth: .infinity)
        }
        .onAppear { vm.columns = count }
        .onChange(of: count) { _, new in vm.columns = new }
        .contentShape(Rectangle())
        .onTapGesture { vm.selection = [] }
    }
}

/// Window-level shortcuts that have no visible control: select all, options for the selection, and the rest of ux §6.5.
private struct KeyCommands: View {
    @ObservedObject var vm: WindowViewModel
    var body: some View {
        ZStack {
            Button("Select all") { vm.selectAll() }.keyboardShortcut("a", modifiers: .command)
            Button("Options") { if let card = vm.selectedCards.first ?? vm.cards.first { vm.openOptions(for: card) } }.keyboardShortcut("o", modifiers: [.command, .option])
        }
        .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
    }
}
