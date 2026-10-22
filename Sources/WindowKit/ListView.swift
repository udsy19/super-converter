import SuperConverterCore
import SwiftUI

/// The list view: rows 56 pt, sortable by name, kind, size and status (ux §5.8).
struct ListView: View {
    @ObservedObject var vm: WindowViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.scHairline).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(vm.displayCards) { card in
                        ListRow(card: card, vm: vm)
                        Rectangle().fill(Color.scHairline).frame(height: 1).padding(.leading, 76)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            heading("Name", .name).padding(.leading, 76).frame(maxWidth: .infinity, alignment: .leading)
            heading("Kind", .kind).frame(width: 190, alignment: .leading)
            heading("Size", .size).frame(width: 80, alignment: .leading)
            heading("Status", .status).frame(width: 210, alignment: .leading)
            Color.clear.frame(width: 120)
        }
        .frame(height: 30).padding(.horizontal, 20)
    }

    private func heading(_ title: String, _ key: SortKey) -> some View {
        Button { vm.sort(by: key) } label: {
            HStack(spacing: 3) {
                Text(title).scFont(SCTextStyle(.text, 12, line: 14, .semibold))
                if vm.sortKey == key { Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .foregroundStyle(vm.sortKey == key ? Color.scLabel : Color.scSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort by \(title.lowercased())")
    }
}

private struct ListRow: View {
    @ObservedObject var card: FileCard
    @ObservedObject var vm: WindowViewModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var isSelected: Bool { vm.selection.contains(card.id) }

    var body: some View {
        HStack(spacing: 0) {
            thumbnail.padding(.trailing, 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(card.shownName).scFont(SCFont.name).foregroundStyle(Color.scLabel).lineLimit(1).truncationMode(.middle)
                Text(Formatting.bytes(card.sizeBytes)).scFont(SCFont.meta).foregroundStyle(Color.scSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            pills.frame(width: 190, alignment: .leading)
            Text(Formatting.bytes(card.sizeBytes)).scFont(SCFont.meta).foregroundStyle(Color.scSecondary).frame(width: 80, alignment: .leading)
            status.frame(width: 210, alignment: .leading)
            actions.frame(width: 120, alignment: .trailing)
        }
        .padding(.horizontal, 20).frame(height: 56)
        .background(isSelected ? Color.scAccent.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { vm.open(card) }
        .onTapGesture {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            vm.click(card, extend: flags.contains(.command), range: flags.contains(.shift))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilitySummary)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(named: "Change format") { if card.isEditable { vm.pickerFor = card.id } }
        .accessibilityAction(named: "Options") { vm.openOptions(for: card) }
        .accessibilityAction(named: "Remove") { vm.remove([card]) }
        .accessibilityAction(named: "Quick Look") { vm.quickLook(card) }
    }

    private var thumbnail: some View {
        let category: FormatCategory = { if case .done = card.state { card.targetCategory } else { card.sourceCategory } }()
        return ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Palette(category, scheme: scheme, contrast: contrast).tint)
            if let image = card.resultThumbnail ?? card.thumbnail {
                Image(nsImage: image).resizable().scaledToFit().padding(4)
            } else {
                ThumbnailArt(category: card.sourceCategory, duration: nil).scaleEffect(0.3).frame(width: 40, height: 40)
            }
        }
        .frame(width: 40, height: 40)
        .quickLookSource(card: card.id, vm: vm)
    }

    @ViewBuilder private var pills: some View {
        if let source = card.source {
            HStack(spacing: 0) {
                SourcePill(format: source)
                FlowArrow(from: card.sourceCategory, to: card.targetCategory)
                if card.isEditable {
                    Button { vm.pickerFor = card.id } label: { TargetPill(format: card.target, category: card.targetCategory) }
                        .buttonStyle(.plain).accessibilityLabel("Change format, currently \(card.target?.pill ?? "none")")
                        .popover(isPresented: pickerBinding, arrowEdge: .bottom) { PickerHost(card: card, vm: vm) }
                } else {
                    TargetPill(format: card.target, category: card.targetCategory, chevron: false)
                }
            }
        }
    }

    private var pickerBinding: Binding<Bool> {
        Binding(get: { vm.pickerFor == card.id }, set: { if !$0 && vm.pickerFor == card.id { vm.pickerFor = nil } })
    }

    @ViewBuilder private var status: some View {
        switch card.state {
        case .converting(let progress):
            HStack(spacing: 8) {
                ProgressView(value: progress.fraction).progressViewStyle(.linear).frame(width: 90)
                Text(progress.fraction.map { "\(Int($0 * 100)) %" } ?? "…").scFont(SCFont.meta).foregroundStyle(Color.scSecondary)
            }
        case .done: StatusBadge(text: Strings.Card.doneBadge, symbol: "checkmark", fill: .scSuccess)
        case .failed(let error):
            Text(Strings.problem(error, libreOfficeInstalled: vm.libreOfficeReady).message).scFont(SCFont.meta).foregroundStyle(Color.scFailure).lineLimit(2)
        case .queued: Text(Strings.Card.waiting).scFont(SCFont.meta).foregroundStyle(Color.scSecondary)
        case .waitingForHelper(let h): Text(Strings.Card.waiting(for: h)).scFont(SCFont.meta).foregroundStyle(Color.scSecondary)
        case .unreadable: Text(Strings.Card.unreadable).scFont(SCFont.meta).foregroundStyle(Color.scSecondary).lineLimit(2)
        case .ready:
            Text(card.unavailableMessage ?? card.facts.joined(separator: " · ")).scFont(SCFont.meta).foregroundStyle(Color.scSecondary).lineLimit(1)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 2) {
            switch card.state {
            case .done(let result):
                CircleIconButton(symbol: "eye", label: "Quick Look") { vm.quickLook(card) }
                ShareButton(urls: result.outputs, label: "Share")
                CircleIconButton(symbol: "folder", label: "Show in Finder") { vm.actions.reveal(result.outputs) }
            case .converting:
                CircleIconButton(symbol: "xmark", label: "Cancel") { vm.cancel(card) }
            case .failed(let error):
                if let fix = Strings.problem(error, libreOfficeInstalled: vm.libreOfficeReady).fix {
                    FixButton(title: fix.rawValue) { vm.perform(fix, for: card) }
                }
            default:
                if card.isEditable { CircleIconButton(symbol: "slider.horizontal.3", label: "Options", filled: card.hasChangedOptions) { vm.openOptions(for: card) } }
                CircleIconButton(symbol: "xmark", label: "Remove") { vm.remove([card]) }
            }
        }
    }
}
