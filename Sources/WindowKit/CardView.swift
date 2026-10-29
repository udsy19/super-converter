import SuperConverterCore
import SwiftUI

/// One file card, 208 × 250 (ux §3.5, §5.3, §5.6, §5.7).
struct CardView: View {
    @ObservedObject var card: FileCard
    @ObservedObject var vm: WindowViewModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var appeared: Bool
    @State private var lossNotesShown = false

    init(card: FileCard, vm: WindowViewModel) {
        self.card = card; self.vm = vm
        _appeared = State(initialValue: !vm.animates)
    }

    private var isSelected: Bool { vm.selection.contains(card.id) }
    private var isDone: Bool { if case .done = card.state { true } else { false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ThumbnailWell(card: card, vm: vm, hovering: hovering || isSelected)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.shownName).scFont(SCFont.name).foregroundStyle(Color.scLabel)
                    .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                CardMeta(card: card, vm: vm, lossNotesShown: $lossNotesShown)
            }
            .padding(.horizontal, SCMetrics.Card.nameInset).padding(.top, 10)
            Spacer(minLength: 0)
            CardRow(card: card, vm: vm)
                .padding(.horizontal, SCMetrics.Card.rowBottomInset).padding(.bottom, SCMetrics.Card.rowBottomInset)
        }
        .padding(SCMetrics.Card.inset)
        .frame(width: SCMetrics.Card.size.width, height: SCMetrics.Card.size.height)
        .background(RoundedRectangle(cornerRadius: SCMetrics.Card.radius).fill(Color.scCard)
            .shadow(color: .black.opacity(0.06), radius: 0.5, y: 0.5).shadow(color: .black.opacity(0.06), radius: 9, y: 6))
        .overlay(RoundedRectangle(cornerRadius: SCMetrics.Card.radius).strokeBorder(Color.scHairline, lineWidth: 1))
        .overlay { if isSelected { RoundedRectangle(cornerRadius: SCMetrics.Card.radius + 1).strokeBorder(Color.scAccent, lineWidth: SCMetrics.Card.selectionRing).padding(-1) } }
        .scaleEffect(appeared || reduceMotion ? 1 : SCMotion.cardAppearStartScale)
        .opacity(appeared ? 1 : 0)
        .onAppear(perform: appear)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { vm.open(card) }
        .onTapGesture {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            vm.click(card, extend: flags.contains(.command), range: flags.contains(.shift))
        }
        .onDrag {
            if case .done(let result) = card.state, let url = result.outputs.first { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            return NSItemProvider()
        } preview: { EmptyView() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(card.accessibilitySummary)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .modifier(CardAccessibilityActions(card: card, vm: vm))
    }

    private func appear() {
        guard !appeared else { return }
        let index = min(vm.appearIndex[card.id] ?? 0, SCMotion.cardStaggerLimit)
        let delay = Double(index) * SCMotion.cardStagger
        if reduceMotion {
            withAnimation(.easeOut(duration: SCMotion.reducedFade).delay(delay)) { appeared = true }
        } else {
            withAnimation(.spring(response: SCMotion.cardAppear.response, dampingFraction: SCMotion.cardAppear.dampingFraction).delay(delay)) { appeared = true }
        }
    }
}

/// VoiceOver actions on a card: Change format, Options, Remove, Quick Look (ux §6.7).
private struct CardAccessibilityActions: ViewModifier {
    @ObservedObject var card: FileCard
    @ObservedObject var vm: WindowViewModel

    func body(content: Content) -> some View {
        content
            .accessibilityAction(named: "Change format") { if card.isEditable { vm.pickerFor = card.id } }
            .accessibilityAction(named: "Options") { vm.openOptions(for: card) }
            .accessibilityAction(named: "Remove") { vm.remove([card]) }
            .accessibilityAction(named: "Quick Look") { vm.quickLook(card) }
    }
}

// MARK: Thumbnail well

private struct ThumbnailWell: View {
    @ObservedObject var card: FileCard
    @ObservedObject var vm: WindowViewModel
    let hovering: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tintCategory: FormatCategory {
        if case .done = card.state { return card.targetCategory }
        return card.sourceCategory
    }

    private var isConverting: Bool {
        if case .converting = card.state { true } else { false }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SCMetrics.Card.thumbnailRadius)
                .fill(Palette(tintCategory, scheme: scheme, contrast: contrast).tint)
                .animation(reduceMotion ? .easeInOut(duration: SCMotion.reducedFade) : .easeInOut(duration: SCMotion.tintCrossFade), value: tintCategory)
            artwork.opacity(isConverting ? 0.55 : 1)
            if case .converting(let progress) = card.state {
                VStack { Spacer(); ProgressCapsule(card: card, fraction: progress.fraction) }.padding(.horizontal, 10).padding(.bottom, 10)
            }
            if let helper = vm.blockingHelper(of: card), card.betterWithHelper != helper {
                VStack { Spacer(); HelperNotice(card: card, vm: vm, helper: helper) }.padding(8)
            }
        }
        .overlay(alignment: .topLeading) { badge.padding(.leading, 9).padding(.top, 9) }
        .overlay(alignment: .topTrailing) {
            if hovering && !isConverting { RemoveButton { vm.remove([card]) }.padding(6) }
        }
        .frame(width: SCMetrics.Card.thumbnailWell.width, height: SCMetrics.Card.thumbnailWell.height)
        .quickLookSource(card: card.id, vm: vm)
    }

    @ViewBuilder private var artwork: some View {
        if let image = card.resultThumbnail ?? card.thumbnail {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(width: SCMetrics.Card.thumbnailFit.width, height: SCMetrics.Card.thumbnailFit.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.14), radius: 2.5, y: 2)
        } else {
            ThumbnailArt(category: card.sourceCategory, duration: card.sourceCategory == .video ? card.facts.last : nil)
        }
    }

    @ViewBuilder private var badge: some View {
        switch card.state {
        case .done:
            StatusBadge(text: Strings.Card.doneBadge, symbol: "checkmark", fill: .scSuccess)
                .transition(reduceMotion ? .opacity : .scale(scale: SCMotion.badgeStartScale, anchor: .topLeading).combined(with: .opacity))
        case .failed:
            StatusBadge(text: Strings.Card.failedBadge, symbol: "exclamationmark", fill: .scFailure)
                .transition(reduceMotion ? .opacity : .scale(scale: SCMotion.badgeStartScale, anchor: .topLeading).combined(with: .opacity))
        default: EmptyView()
        }
    }
}

struct StatusBadge: View {
    let text: String
    let symbol: String
    let fill: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .heavy))
            Text(text).font(Font(SCTextStyle(.rounded, 11, line: 14, .bold).font))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9).frame(height: SCMetrics.Card.badgeHeight)
        .background(Capsule().fill(fill))
        .accessibilityHidden(true)
    }
}

private struct RemoveButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
                .frame(width: SCMetrics.Card.removeButton, height: SCMetrics.Card.removeButton)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove")
        .help("Remove from the list")
    }
}

/// The flow progress capsule (ux §3.4 item 2): 6 pt, source → target gradient; indeterminate shows a gentle shimmer.
private struct ProgressCapsule: View {
    @ObservedObject var card: FileCard
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.7))
                Capsule().fill(flowGradient(from: card.sourceCategory, to: card.targetCategory))
                    .frame(width: proxy.size.width * (fraction ?? 0.3))
                    .offset(x: fraction == nil && shimmer ? proxy.size.width * 0.7 : 0)
            }
        }
        .frame(height: SCMetrics.Card.progressCapsule)
        .clipShape(Capsule())
        .onAppear {
            guard fraction == nil, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { shimmer = true }
        }
        .accessibilityHidden(true)
    }
}

/// "Needs calibre — Free · 160 MB" with Install or Get…, and the install's progress in the same place (ux §5.6).
private struct HelperNotice: View {
    @ObservedObject var card: FileCard
    @ObservedObject var vm: WindowViewModel
    let helper: HelperID

    var body: some View {
        HStack(spacing: 8) {
            if let progress = card.helperInstall {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Strings.Helper.installing(helper, percent: Int(progress * 100))).scFont(SCFont.meta).foregroundStyle(Color.black.opacity(0.8)).lineLimit(1)
                    ProgressView(value: progress).progressViewStyle(.linear).controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Strings.Helper.needs(helper)).font(Font(SCTextStyle(.text, 12, line: 15, .semibold).font)).foregroundStyle(Color.black.opacity(0.85)).lineLimit(1)
                    Text(Strings.Helper.cost(helper)).scFont(SCFont.meta).foregroundStyle(Color.black.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { vm.installHelper(for: card) } label: {
                    Text(isOneClick ? Strings.Helper.install : Strings.Helper.get).font(Font(SCTextStyle(.text, 11, line: 14, .semibold).font))
                        .foregroundStyle(.white).padding(.horizontal, 9).frame(height: SCMetrics.Card.noticeButtonHeight)
                        .background(Capsule().fill(Color.black))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(isOneClick ? Strings.Helper.install : Strings.Helper.get) \(HelperCatalog.info(helper).name)")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: SCMetrics.Card.noticeRadius).fill(Color.white.opacity(0.94)))
    }

    private var isOneClick: Bool { if case .oneClick = HelperCatalog.info(helper).install { true } else { false } }
}

// MARK: Meta

private struct CardMeta: View {
    @ObservedObject var card: FileCard
    @ObservedObject var vm: WindowViewModel
    @Binding var lossNotesShown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).scFont(SCFont.meta).foregroundStyle(Color.scSecondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if case .done(let result) = card.state {
                if let first = result.lossNotes.first {
                    Button { lossNotesShown = true } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "info.circle").font(.system(size: 10))
                            Text(first.headline + (result.lossNotes.count > 1 ? " +\(result.lossNotes.count - 1)" : "")).lineLimit(1)
                        }
                        .scFont(SCFont.meta).foregroundStyle(Color.scSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("What changed: " + result.lossNotes.map(\.headline).joined(separator: ". "))
                    .popover(isPresented: $lossNotesShown, arrowEdge: .bottom) { LossNotesView(notes: result.lossNotes) }
                }
                if let helper = card.betterWithHelper {
                    Button { vm.installBetterLook(card) } label: {
                        Text(Strings.Helper.betterWithHelper(helper)).scFont(SCFont.meta).foregroundStyle(Color.scAccent).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var text: String {
        switch card.state {
        case .ready:
            if let message = card.unavailableMessage { return message }
            var parts = [Formatting.bytes(card.sizeBytes)]
            if let mismatch = card.mismatch { parts.append(Strings.Card.mismatch(mismatch)) } else { parts += card.facts }
            return parts.joined(separator: " · ")
        case .queued: return Strings.Card.waiting
        case .waitingForHelper(let helper): return Strings.Card.waiting(for: helper)
        case .converting(let progress):
            let left = progress.secondsLeft.map { " · " + Formatting.timeLeft($0) } ?? ""
            if let unit = progress.unit { return unit + left }
            if let f = progress.fraction { return Strings.Card.progress(percent: Int(f * 100), secondsLeft: progress.secondsLeft) }
            return "Preparing…"
        case .done(let result):
            let new = result.outputBytes > 0 ? result.outputBytes : result.outputs.reduce(0) { $0 + WindowViewModel.size(of: $1) }
            return Strings.Card.done(newSize: new, oldSize: result.inputBytes > 0 ? result.inputBytes : card.sizeBytes)
        case .failed(let error): return Strings.problem(error, libreOfficeInstalled: vm.libreOfficeReady).message
        case .unreadable: return Strings.Card.unreadable
        }
    }
}

private struct LossNotesView: View {
    let notes: [LossNote]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What changed").scFont(SCFont.title)
            ForEach(notes, id: \.self) { note in
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.headline).scFont(SCFont.body)
                    if !note.detail.isEmpty { Text(note.detail).scFont(SCFont.meta).foregroundStyle(Color.scSecondary) }
                }
            }
        }
        .padding(14).frame(width: 280, alignment: .leading)
    }
}

// MARK: Row

private struct CardRow: View {
    @ObservedObject var card: FileCard
    @ObservedObject var vm: WindowViewModel

    var body: some View {
        HStack(spacing: 0) {
            switch card.state {
            case .done:
                if let target = card.target { SourcePill(format: target) }
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    CircleIconButton(symbol: "eye", label: "Quick Look") { vm.quickLook(card) }
                    ShareButton(urls: outputs, label: "Share")
                    CircleIconButton(symbol: "folder", label: "Show in Finder") { vm.actions.reveal(outputs) }
                }
            case .failed(let error):
                failureRow(error)
            case .unreadable:
                FixButton(title: ConversionError.Fix.showInFinder.rawValue, symbol: "folder") { vm.actions.reveal([card.url]) }
                Spacer(minLength: 4)
            case .queued, .converting:
                conversionPills(chevron: false)
                Spacer(minLength: 4)
                if case .converting = card.state { CircleIconButton(symbol: "xmark", label: "Cancel") { vm.cancel(card) } }
            case .ready, .waitingForHelper:
                conversionPills(chevron: card.isEditable)
                Spacer(minLength: 4)
                if card.isEditable { CircleIconButton(symbol: "slider.horizontal.3", label: "Options", filled: card.hasChangedOptions) { vm.openOptions(for: card) } }
            }
        }
        .frame(height: SCMetrics.Card.targetPillHeight)
    }

    private var outputs: [URL] { if case .done(let r) = card.state { r.outputs } else { [] } }

    @ViewBuilder private func conversionPills(chevron: Bool) -> some View {
        if let source = card.source { SourcePill(format: source) }
        FlowArrow(from: card.sourceCategory, to: card.targetCategory)
        if chevron {
            Button { vm.pickerFor = card.id } label: { TargetPill(format: card.target, category: card.targetCategory) }
                .buttonStyle(.plain)
                .accessibilityLabel("Change format, currently \(card.target?.pill ?? "none")")
                .popover(isPresented: pickerBinding, arrowEdge: .bottom) { PickerHost(card: card, vm: vm) }
        } else {
            TargetPill(format: card.target, category: card.targetCategory, chevron: false)
        }
    }

    private var pickerBinding: Binding<Bool> {
        Binding(get: { vm.pickerFor == card.id }, set: { if !$0 && vm.pickerFor == card.id { vm.pickerFor = nil } })
    }

    @ViewBuilder private func failureRow(_ error: ConversionError) -> some View {
        let problem = Strings.problem(error, libreOfficeInstalled: vm.libreOfficeReady)
        if let fix = problem.fix {
            FixButton(title: fix.rawValue, symbol: fix == .enterPassword ? "lock" : (fix == .showInFinder ? "folder" : nil)) { vm.perform(fix, for: card) }
            Spacer(minLength: 4)
            if case .needsConfirmation = error {
                // A question: going ahead is the fix, declining removes the card (nothing was written).
                CircleIconButton(symbol: "xmark", label: "Cancel") { vm.remove([card]) }
            } else {
                CircleIconButton(symbol: "slider.horizontal.3", label: "Options", filled: card.hasChangedOptions) { vm.openOptions(for: card) }
            }
        } else {
            conversionPills(chevron: card.isEditable)
            Spacer(minLength: 4)
        }
    }
}

/// A card's one-fix button: a control-fill capsule with the verb (ux §7.2).
struct FixButton: View {
    let title: String
    var symbol: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12)).accessibilityHidden(true) }
                Text(title).font(Font(SCTextStyle(.text, 13, line: 16, .medium).font)).lineLimit(1)
            }
            .foregroundStyle(Color.scLabel).padding(.horizontal, 12).frame(height: SCMetrics.Card.targetPillHeight)
            .background(Capsule().fill(Color.scControl))
        }
        .buttonStyle(.plain)
    }
}

/// A Share button that opens the system share menu for the given files.
struct ShareButton: View {
    let urls: [URL]
    let label: String
    var body: some View {
        ShareLink(items: urls) { CircleIcon(symbol: "square.and.arrow.up") }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .help(label)
    }
}

/// Holds the picker's model for as long as the popover is open.
struct PickerHost: View {
    @ObservedObject var card: FileCard
    @ObservedObject var vm: WindowViewModel
    @StateObject private var model: FormatPickerModel

    init(card: FileCard, vm: WindowViewModel) {
        self.card = card; self.vm = vm
        _model = StateObject(wrappedValue: vm.pickerModel(for: card) ?? FormatPickerModel(source: card.source ?? "pdf", current: nil, targets: []))
    }

    var body: some View {
        FormatPickerView(model: model) { target in vm.pick(target, remember: model.remember, for: card) } close: { vm.pickerFor = nil }
    }
}
