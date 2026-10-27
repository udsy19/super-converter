import AppKit
import SuperConverterCore
import SwiftUI

/// The menu-bar panel (ux §5.9, `menubar.png`): dropped files with their targets, Convert, where results go, the recent
/// list and the footer. 360 pt wide; the controller hosts it in a rounded window under the status item.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    @State private var hovering = false
    static let sidePadding: CGFloat = 18
    /// Rows of the recent list visible before it scrolls.
    static let visibleRecents = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            switch model.phase {
            case .idle: DropArea(hovering: hovering).padding(.horizontal, Self.sidePadding).padding(.top, 14)
            default: itemList
            }
            action
            if !model.recents.isEmpty { recents }
            Divider().overlay(Color.scHairline).padding(.top, 12)
            footer
        }
        .frame(width: SCMetrics.MenuBarPanel.width)
        .background(Color.scCard)
        .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
            Self.urls(from: providers) { model.add($0) }
            return true
        }
    }

    /// Reads the file URLs of dropped items, then calls `done` on the main actor with them in drop order.
    static func urls(from providers: [NSItemProvider], done: @escaping @MainActor ([URL]) -> Void) {
        let lock = NSLock()
        var found: [Int: URL] = [:]
        let group = DispatchGroup()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.withLock { found[index] = url } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let urls = lock.withLock { found.keys.sorted().compactMap { found[$0] } }
            MainActor.assumeIsolated { done(urls) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Strings.appName).scFont(SCFont.title).foregroundStyle(Color.scLabel)
            Spacer()
            if let subtitle = model.subtitle { Text(subtitle).scFont(SCFont.body).foregroundStyle(Color.scSecondary) }
        }
        .padding(.horizontal, Self.sidePadding).padding(.top, 16)
    }

    private var itemList: some View {
        VStack(spacing: 6) {
            ForEach(model.items) { item in ItemRow(item: item, model: model) }
        }
        .padding(.horizontal, Self.sidePadding).padding(.top, 12)
    }

    @ViewBuilder private var action: some View {
        if model.phase != .idle {
            VStack(alignment: .leading, spacing: 8) {
                switch model.phase {
                case .ready: ConvertButton(model: model)
                case .converting: ConvertingBar(model: model)
                default: ShowResultsButton(model: model)
                }
                HStack(spacing: 4) {
                    Text(model.placeLine).scFont(SCFont.body).foregroundStyle(Color.scSecondary)
                    Text("·").foregroundStyle(Color.scSecondary)
                    PlaceMenu(model: model)
                }
                .padding(.leading, 6)
            }
            .padding(.horizontal, Self.sidePadding - 4).padding(.top, 14)
        }
    }

    private var recents: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recently converted").scFont(SCFont.sectionHead).textCase(.uppercase).foregroundStyle(Color.scSecondary)
                .padding(.leading, 6).padding(.top, 14)
            let rows = VStack(spacing: 0) { ForEach(model.recents) { RecentRow(recent: $0, model: model) } }
            if model.recents.count > Self.visibleRecents {
                ScrollView { rows }.frame(height: CGFloat(Self.visibleRecents) * SCMetrics.MenuBarPanel.rowHeight)
            } else {
                rows
            }
        }
        .padding(.horizontal, Self.sidePadding - 4)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { model.openApp() } label: {
                HStack {
                    Text("Open \(Strings.appName)").scFont(SCFont.body).foregroundStyle(Color.scLabel)
                    Spacer()
                    Text("⌘O").scFont(SCFont.meta).foregroundStyle(Color.scSecondary)
                        .padding(.horizontal, 6).frame(height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.scStrongHairline, lineWidth: 1))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("o", modifiers: .command)
            CircleIconButton(symbol: "gearshape", label: "Settings…") { model.openSettings() }
        }
        .padding(.horizontal, Self.sidePadding).padding(.vertical, 12)
    }
}

/// The small dashed drop area an empty panel shows (ux §5.9).
private struct DropArea: View {
    let hovering: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc").font(.system(size: 20, weight: .regular)).foregroundStyle(hovering ? Color.scAccent : Color.scTertiary)
            Text(hovering ? "Drop to add" : "Drop files here to convert").scFont(SCFont.body).foregroundStyle(Color.scSecondary)
        }
        .frame(maxWidth: .infinity).frame(height: 84)
        .background(RoundedRectangle(cornerRadius: SCMetrics.Card.radius, style: .continuous).fill(hovering ? Color.scAccent.opacity(0.08) : .clear))
        .overlay(RoundedRectangle(cornerRadius: SCMetrics.Card.radius, style: .continuous)
            .strokeBorder(hovering ? Color.scAccent : Color.scStrongHairline,
                          style: StrokeStyle(lineWidth: SCMetrics.DropZone.dashedBorder, dash: SCMetrics.DropZone.dash)))
        .accessibilityElement(children: .combine)
    }
}

/// A thumbnail well: the Quick Look image, or the category's symbol on its tint.
private struct Thumbnail: View {
    let image: NSImage?
    let category: FormatCategory
    private let side = SCMetrics.MenuBarPanel.thumbnail

    var body: some View {
        PaletteReader(category) { p in
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack { p.tint; Image(systemName: category.symbol).font(.system(size: 17)).foregroundStyle(p.ink) }
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: SCMetrics.Card.thumbnailRadius - 3, style: .continuous))
        }
        .accessibilityHidden(true)
    }
}

private struct ItemRow: View {
    let item: BatchItem
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(image: model.thumbnails[item.url], category: item.category)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).scFont(SCFont.name).foregroundStyle(Color.scLabel).lineLimit(1).truncationMode(.middle)
                status
            }
            Spacer(minLength: 0)
            if item.state == .ready {
                CircleIconButton(symbol: "xmark", label: "Remove \(item.name)") { model.remove(item) }
            }
        }
        .frame(minHeight: SCMetrics.MenuBarPanel.rowHeight - 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .ready:
            HStack(spacing: 0) {
                if let source = item.source { SourcePill(format: source) }
                FlowArrow(from: item.category, to: item.targetCategory)
                TargetMenu(item: item, model: model)
            }
        case .unreadable:
            Text(Strings.Card.unreadable).scFont(SCFont.meta).foregroundStyle(Color.scSecondary).lineLimit(2)
        case .queued, .waiting:
            Text(Strings.Card.waiting).scFont(SCFont.meta).foregroundStyle(Color.scSecondary)
        case .converting(let progress):
            HStack(spacing: 8) {
                ProgressCapsule(fraction: progress.fraction, category: item.targetCategory)
                if let f = progress.fraction { Text(Strings.Card.progress(percent: Int(f * 100), secondsLeft: nil)).scFont(SCFont.meta).foregroundStyle(Color.scSecondary) }
            }
        case .done(let result):
            HStack(spacing: 6) {
                Label(Strings.Card.doneBadge, systemImage: "checkmark.circle.fill").scFont(SCFont.meta).foregroundStyle(Color.scSuccess)
                if result.outputBytes > 0 { Text(Strings.Card.done(newSize: result.outputBytes, oldSize: result.inputBytes)).scFont(SCFont.meta).foregroundStyle(Color.scSecondary) }
            }
        case .failed(let error):
            Text(Strings.problem(error).message).scFont(SCFont.meta).foregroundStyle(Color.scFailure).lineLimit(2)
        }
    }
}

/// The target pill as a pop-up of the formats the file can become.
private struct TargetMenu: View {
    let item: BatchItem
    @ObservedObject var model: PanelModel

    var body: some View {
        Menu {
            ForEach(model.targets(for: item), id: \.self) { format in
                Button(format.pill) { model.setTarget(format, for: item) }
            }
        } label: {
            TargetPill(format: item.target, category: item.targetCategory)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Convert \(item.name) to")
        .accessibilityValue(item.target?.pill ?? "nothing chosen")
    }
}

private struct ProgressCapsule: View {
    let fraction: Double?
    let category: FormatCategory

    var body: some View {
        PaletteReader(category) { p in
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.scControl)
                    Capsule().fill(p.filledFill).frame(width: proxy.size.width * max(fraction ?? 0.08, 0.04))
                }
            }
            .frame(height: SCMetrics.Card.progressCapsule)
        }
    }
}

/// "Convert 2 files →" in the gradient of the batch's target colours (ux §3.4 item 4).
private struct ConvertButton: View {
    @ObservedObject var model: PanelModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palettes = model.buttonCategories.map { CategoryPalette($0, scheme: scheme, contrast: contrast) }
        let enabled = !model.readyItems.isEmpty
        Button { model.convert() } label: {
            HStack(spacing: 10) {
                Text(model.convertTitle).scFont(SCFont.summary)
                Image(systemName: "arrow.right").font(.system(size: 18, weight: .semibold)).accessibilityHidden(true)
            }
            .foregroundStyle(palettes.count == 1 ? palettes[0].filledText : .white)
            .frame(maxWidth: .infinity).frame(height: SCMetrics.ActionBar.buttonHeight)
            .background(Capsule().fill(fill(palettes)).shadow(color: (palettes.first?.deep ?? .scAccent).opacity(0.3), radius: 8, y: 4))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain).disabled(!enabled)
        .keyboardShortcut(.return, modifiers: .command)
    }

    private func fill(_ palettes: [CategoryPalette]) -> AnyShapeStyle {
        if palettes.count == 1 { return AnyShapeStyle(palettes[0].filledFill) }
        let stops = palettes.isEmpty ? [Color.scAccent, Color.scAccent] : palettes.map(\.buttonStop)
        return AnyShapeStyle(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
    }
}

private struct ConvertingBar: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(Strings.ActionBar.converting(done: model.items.filter { $0.state.isFinished }.count, of: model.items.count))
                .scFont(SCFont.summary).foregroundStyle(Color.scLabel)
        }
        .frame(maxWidth: .infinity).frame(height: SCMetrics.ActionBar.buttonHeight)
        .background(Capsule().fill(Color.scControl))
    }
}

private struct ShowResultsButton: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        let outputs = model.items.compactMap { item -> URL? in if case .done(let r) = item.state { r.outputs.first } else { nil } }
        Button { model.reveal(outputs) } label: {
            Text(Strings.Window.showInFinder).scFont(SCFont.summary).foregroundStyle(Color.scLabel)
                .frame(maxWidth: .infinity).frame(height: SCMetrics.ActionBar.buttonHeight)
                .background(Capsule().fill(Color.scControl))
        }
        .buttonStyle(.plain).disabled(outputs.isEmpty).opacity(outputs.isEmpty ? 0.4 : 1)
    }
}

/// "Change…": next to the originals, Downloads, or a folder (ux §5.11).
private struct PlaceMenu: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        Menu {
            Button { model.setPlace(.nextToOriginal) } label: { Label(Strings.ActionBar.nextToOriginals, systemImage: model.place == .nextToOriginal ? "checkmark" : "") }
            Button { model.setPlace(.downloads) } label: { Label("Downloads", systemImage: model.place == .downloads ? "checkmark" : "") }
            Divider()
            Button("Choose Folder…") { model.chooseOutputFolder() }
        } label: {
            Text("Change…").scFont(SCFont.body).foregroundStyle(Color.scAccent)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

private struct RecentRow: View {
    let recent: RecentConversion
    @ObservedObject var model: PanelModel

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(image: model.thumbnails[recent.output], category: FormatCatalog.format(forFileName: recent.name)?.category ?? .document)
            VStack(alignment: .leading, spacing: 2) {
                Text(recent.name).scFont(SCFont.name).foregroundStyle(Color.scLabel).lineLimit(1).truncationMode(.middle)
                Text("from \(recent.sourceFormat.pill) · \(RecentList.ago(recent.date))").scFont(SCFont.meta).foregroundStyle(Color.scSecondary)
            }
            Spacer(minLength: 0)
            CircleIconButton(symbol: "folder", label: "Show \(recent.name) in Finder") { model.reveal([recent.output]) }
        }
        .frame(height: SCMetrics.MenuBarPanel.rowHeight)
        .accessibilityElement(children: .contain)
    }
}

/// A round icon button (26 pt, control fill on hover), as on a card.
private struct CircleIconButton: View {
    let symbol: String
    let label: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Color.scSecondary)
                .frame(width: SCMetrics.Card.optionsButton, height: SCMetrics.Card.optionsButton)
                .background(Circle().fill(hovering ? Color.scControl : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}
