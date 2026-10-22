import SuperConverterCore
import SwiftUI

/// The bottom bar, 76 tall (ux §3.5, §5.3, §5.6, §5.7): "Set all to", "Save to" and the Convert button; progress and Stop
/// while converting; the summary with Show in Finder, Share… and Convert more when done.
struct ActionBarView: View {
    @ObservedObject var vm: WindowViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            switch vm.phase {
            case .converting: converting.transition(slide)
            case .finished: finished.transition(slide)
            default: ready.transition(slide)
            }
        }
        .padding(.horizontal, SCMetrics.ActionBar.sidePadding)
        .frame(height: SCMetrics.ActionBar.height)
        .frame(maxWidth: .infinity)
        .background(ActionBarBackground())
        .overlay(alignment: .top) { Rectangle().fill(Color.scHairline).frame(height: 1) }
        .animation(reduceMotion ? .easeOut(duration: SCMotion.reducedFade) : .easeOut(duration: 0.25), value: vm.phase)
    }

    private var slide: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: SCMotion.actionBarSlide))
    }

    // MARK: Ready

    private var ready: some View {
        HStack(spacing: 0) {
            Text(Strings.ActionBar.setAllTo).scFont(SCTextStyle(.text, 13, line: 16)).foregroundStyle(Color.scSecondary)
            SetAllMenu(vm: vm).padding(.leading, 12)
            Text(Strings.ActionBar.saveTo).scFont(SCTextStyle(.text, 13, line: 16)).foregroundStyle(Color.scSecondary).padding(.leading, 24)
            SaveToMenu(vm: vm).padding(.leading, 12)
            Spacer(minLength: 16)
            ConvertButton(vm: vm)
        }
    }

    // MARK: Converting

    private var converting: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.ActionBar.converting(done: vm.finishedInBatch, of: vm.batchCards.count)).scFont(SCFont.summary).foregroundStyle(Color.scLabel)
                Text(vm.convertingDetail).scFont(SCTextStyle(.text, 13, line: 16)).foregroundStyle(Color.scSecondary).lineLimit(1)
            }
            OverallProgress(fraction: vm.overallFraction, categories: vm.batchCards.map(\.targetCategory)).frame(width: 300, height: 6).padding(.leading, 24)
                .accessibilityLabel("Overall progress").accessibilityValue("\(Int(vm.overallFraction * 100)) percent")
            Spacer(minLength: 16)
            Button { vm.stop() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill").font(.system(size: 10)).accessibilityHidden(true)
                    Text(Strings.Window.stop).scFont(SCTextStyle(.rounded, 14, line: 18, .semibold))
                }
                .foregroundStyle(Color.scLabel).padding(.horizontal, 20).frame(height: 32)
                .background(Capsule().fill(Color.scControl))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityLabel(Strings.Window.stop)
        }
    }

    // MARK: Finished

    private var finished: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                .frame(width: 36, height: 36).background(Circle().fill(Color.scSuccess)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.finishedTitle).scFont(SCFont.summary).foregroundStyle(Color.scLabel)
                Text(vm.finishedDetail).scFont(SCTextStyle(.text, 13, line: 16)).foregroundStyle(Color.scSecondary).lineLimit(1)
            }
            Spacer(minLength: 16)
            SecondaryBarButton(symbol: "folder", title: Strings.Window.showInFinder) { vm.revealResults() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            ShareLink(items: vm.doneOutputs) {
                BarButtonLabel(symbol: "square.and.arrow.up", title: Strings.Window.share)
            }
            .buttonStyle(.plain).accessibilityLabel(Strings.Window.share)
            Button { vm.convertMore() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).accessibilityHidden(true)
                    Text(Strings.Window.convertMore).scFont(SCTextStyle(.rounded, 15, line: 20, .semibold))
                }
                .foregroundStyle(Color.scWindow).padding(.horizontal, 22).frame(height: 40)
                .background(Capsule().fill(Color.scLabel).shadow(color: .black.opacity(0.16), radius: 6, y: 3))
            }
            .buttonStyle(.plain).accessibilityLabel(Strings.Window.convertMore)
        }
    }
}

/// The action bar's material: the `.headerView` blur under a tint (ux §3.3).
private struct ActionBarBackground: View {
    var body: some View {
        ZStack {
            VisualEffect(material: .headerView)
            Rectangle().fill(Color(SCColor.actionBar))
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

struct BarButtonLabel: View {
    let symbol: String
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).accessibilityHidden(true)
            Text(title).scFont(SCTextStyle(.text, 14, line: 18, .medium))
        }
        .foregroundStyle(Color.scLabel).padding(.horizontal, 16).frame(height: 32)
        .background(Capsule().fill(Color.scControl))
    }
}

struct SecondaryBarButton: View {
    let symbol: String
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { BarButtonLabel(symbol: symbol, title: title) }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

/// The overall bar while converting: a gradient through the batch's target colours.
private struct OverallProgress: View {
    let fraction: Double
    let categories: [FormatCategory]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.scControl)
                Capsule().fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(proxy.size.width * fraction, fraction > 0 ? 6 : 0))
            }
        }
    }

    private var stops: [Color] {
        var seen: [FormatCategory] = []
        for c in categories where !seen.contains(c) { seen.append(c) }
        let colors = seen.map { Color(nsColor: NSColor(hex: SCColor.colors(for: $0).base)) }
        return colors.count >= 2 ? colors : (colors + colors + [Color.scAccent]).prefix(2).map { $0 }
    }
}

/// The big Convert button (ux §3.4 item 4): the batch's target colours; one category uses that category's filled colours.
struct ConvertButton: View {
    @ObservedObject var vm: WindowViewModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let categories = vm.buttonCategories
        let palettes = categories.map { Palette($0, scheme: scheme, contrast: contrast) }
        let single = palettes.count == 1 ? palettes[0] : nil
        let enabled = !vm.readyCards.isEmpty
        Button { vm.convert() } label: {
            HStack(spacing: 10) {
                Text(vm.convertTitle).scFont(SCFont.summary)
                Image(systemName: "arrow.right").font(.system(size: 18, weight: .semibold)).accessibilityHidden(true)
            }
            .foregroundStyle(single?.filledText ?? .white)
            .padding(.leading, 22).padding(.trailing, 20).frame(height: SCMetrics.ActionBar.buttonHeight)
            .background(Capsule().fill(fill(single, palettes)).shadow(color: shadow(palettes).opacity(0.35), radius: 10, y: 5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel(vm.convertTitle)
    }

    private func fill(_ single: Palette?, _ palettes: [Palette]) -> AnyShapeStyle {
        if let single { return AnyShapeStyle(single.filledFill) }
        let stops = palettes.isEmpty ? [Color.scAccent, Color.scAccent] : palettes.map(\.buttonStop)
        return AnyShapeStyle(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
    }

    private func shadow(_ palettes: [Palette]) -> Color { palettes.first?.deep ?? Color.scAccent }
}

/// "Set all to" pop-up: the targets every card can become, else per-category groups (ux §5.3).
private struct SetAllMenu: View {
    @ObservedObject var vm: WindowViewModel

    var body: some View {
        let common = vm.commonTargets
        Menu {
            if common.isEmpty {
                ForEach(vm.targetGroups, id: \.category) { group in
                    Section("\(group.category.title) to…") {
                        ForEach(group.targets, id: \.self) { format in Button(format.pill) { vm.setAll(format, category: group.category) } }
                    }
                }
            } else {
                ForEach(common, id: \.self) { format in Button(format.pill) { vm.setAll(format) } }
            }
        } label: {
            PopupLabel(text: vm.sharedTarget?.pill ?? Strings.ActionBar.chooseAFormat, symbol: nil)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(vm.editableCards.isEmpty)
        .accessibilityLabel(Strings.ActionBar.setAllTo)
    }
}

/// "Save to" pop-up: next to the originals, Downloads, or a folder (ux §5.11).
private struct SaveToMenu: View {
    @ObservedObject var vm: WindowViewModel

    var body: some View {
        Menu {
            Button(Strings.ActionBar.nextToOriginals) { vm.setOutputPlace(.nextToOriginal) }
            Button("Downloads") { vm.setOutputPlace(.downloads) }
            Button("Choose Folder…") { vm.chooseOutputFolder() }
        } label: {
            PopupLabel(text: current, symbol: "folder")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(Strings.ActionBar.saveTo)
    }

    private var current: String {
        switch Defaults[.outputPlace] {
        case .nextToOriginal: Strings.ActionBar.nextToOriginals
        case .downloads: "Downloads"
        case .folder(let url): url.lastPathComponent
        }
    }
}

/// A bordered pop-up button face: text, optional leading icon, and the up-down chevrons.
struct PopupLabel: View {
    let text: String
    let symbol: String?
    var body: some View {
        HStack(spacing: 8) {
            if let symbol { Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Color.scSecondary).accessibilityHidden(true) }
            Text(text).scFont(SCTextStyle(.text, 14, line: 18)).foregroundStyle(Color.scLabel)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.scSecondary).accessibilityHidden(true)
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.scCard))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.scStrongHairline, lineWidth: 1))
    }
}
