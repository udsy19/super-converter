import SuperConverterCore
import SwiftUI

/// The empty window and the drag-over state (ux §5.1, §5.2; mockups `window-empty.png`, `window-drag.png`): a fan of five
/// sample cards, the headline, the Choose Files… button and the Popular pairs.
struct DropZoneView: View {
    @ObservedObject var vm: WindowViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dragging: DragSummary? { vm.drag }

    var body: some View {
        ZStack {
            DropBorder(hovering: dragging != nil, animated: vm.animates)
            if dragging != nil {
                RadialGradient(colors: [Color.scAccent.opacity(0.07), .clear], center: .center, startRadius: 0, endRadius: 340).allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                SampleFan(spread: dragging != nil).padding(.bottom, 22)
                Text(dragging?.headline ?? Strings.Window.emptyHeadline).scFont(SCFont.display).foregroundStyle(Color.scLabel)
                    .multilineTextAlignment(.center).padding(.bottom, 8)
                Text(dragging?.line ?? Strings.Window.emptyLine).scFont(SCTextStyle(.text, 15, line: 21)).foregroundStyle(Color.scSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 500)
                if dragging == nil {
                    ChooseFilesButton { vm.chooseFiles() }.padding(.top, 28)
                    PopularPairs(vm: vm).padding(.top, 26)
                }
                Spacer(minLength: 0)
                if dragging == nil { footnote.padding(.bottom, 18) }
            }
            .padding(.horizontal, 24)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: dragging != nil)
        }
        .padding(SCMetrics.DropZone.inset)
        .accessibilityElement(children: .contain)
    }

    private var footnote: some View {
        var text = AttributedString(Strings.Window.emptyFootnote)
        for phrase in ["Super Converter in the menu bar", "Quick Actions › Convert with Super Converter"] {
            if let range = text.range(of: phrase) {
                text[range].font = Font(SCTextStyle(.text, 12, line: 16, .semibold).font)
                text[range].foregroundColor = Color.scSecondary
            }
        }
        return Text(text).scFont(SCTextStyle(.text, 12, line: 16)).foregroundStyle(Color.scTertiary).multilineTextAlignment(.center)
    }
}

/// The drop zone's border: a 2 pt dashed hairline, or the eleven-hue gradient while files hover (ux §3.4 item 5).
struct DropBorder: View {
    let hovering: Bool
    var animated = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SCMetrics.DropZone.cornerRadius, style: .continuous)
        if hovering {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !animated)) { timeline in
                let turn = reduceMotion || !animated ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: SCMotion.dropGradientPeriod) / SCMotion.dropGradientPeriod * 360
                shape.strokeBorder(AngularGradient(colors: hueLoop, center: .center, angle: .degrees(225 + turn)), lineWidth: SCMetrics.DropZone.hoverBorder)
            }
        } else {
            shape.strokeBorder(Color.scStrongHairline, style: StrokeStyle(lineWidth: SCMetrics.DropZone.dashedBorder, dash: SCMetrics.DropZone.dash))
        }
    }
}

/// Five sample cards, rotated −22° … +22°; they spread by 30 % while files hover (ux §3.6).
struct SampleFan: View {
    let spread: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let cards: [(FormatCategory, FormatID)] = [(.image, "jpg"), (.document, "pdf"), (.video, "mp4"), (.audio, "mp3"), (.ebook, "epub")]

    var body: some View {
        let factor = spread && !reduceMotion ? 1 + SCMotion.fanSpread : 1
        ZStack {
            ForEach(cards.indices, id: \.self) { i in
                let slot = Double(i - 2)
                FanCard(category: cards[i].0, format: cards[i].1)
                    .rotationEffect(.degrees(slot * 11 * factor))
                    .offset(x: slot * 97 * factor, y: abs(slot) * abs(slot) * 2.2)
            }
        }
        .frame(height: 140)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.75), value: spread)
        .accessibilityHidden(true)
    }
}

private struct FanCard: View {
    let category: FormatCategory
    let format: FormatID
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Palette(category, scheme: scheme, contrast: contrast).tint)
                ThumbnailArt(category: category, duration: category == .video ? "0:42" : nil).scaleEffect(0.62)
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            SourcePill(format: format)
        }
        .padding(6).padding(.bottom, 2)
        .frame(width: 92, height: 124)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.scCard).shadow(color: .black.opacity(0.10), radius: 10, y: 6).shadow(color: .black.opacity(0.06), radius: 0.5))
    }
}

/// The only neutral-filled button: black in light mode, white in dark (ux §5.1).
struct ChooseFilesButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).accessibilityHidden(true)
                Text(Strings.Window.chooseFiles).scFont(SCTextStyle(.rounded, 15, line: 20, .semibold))
            }
            .foregroundStyle(Color.scWindow).padding(.horizontal, 24).frame(height: 40)
            .background(Capsule().fill(Color.scLabel).shadow(color: .black.opacity(0.18), radius: 8, y: 4))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("o", modifiers: .command)
        .accessibilityLabel(Strings.Window.chooseFiles)
    }
}

/// "Popular" HEIC → JPG … chips: each opens the file chooser filtered to the source and presets the target (ux §5.1).
struct PopularPairs: View {
    @ObservedObject var vm: WindowViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Popular").scFont(SCTextStyle(.text, 13, line: 17)).foregroundStyle(Color.scSecondary).padding(.top, 5)
            FlowLayout(spacing: 8, lineSpacing: 10, alignment: .center) {
                ForEach(Strings.Window.popularPairs.indices, id: \.self) { i in
                    let pair = Strings.Window.popularPairs[i]
                    Button { vm.chooseFiles(filter: pair.from, target: pair.to) } label: { PairChip(from: pair.from, to: pair.to) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(label(pair.from, pair.to)). Choose files.".replacingOccurrences(of: "→", with: "to"))
                }
            }
        }
        .frame(maxWidth: 640)
    }

    private func label(_ from: FormatID, _ to: FormatID) -> String { "\(from.pill) → \(PairChip.shown(from: from, to: to))" }
}

private struct PairChip: View {
    let from: FormatID
    let to: FormatID

    /// "PDF → WORD": the popular pair says what people call it.
    static func shown(from: FormatID, to: FormatID) -> String { from == "pdf" && to == "docx" ? "WORD" : to.pill }

    var body: some View {
        HStack(spacing: 0) {
            PaletteReader(from.category) { p in Text(from.pill).scFont(SCTextStyle(.rounded, 12, line: 14, .bold).withTracking(0.3)).foregroundStyle(p.ink) }
            FlowArrow(from: from.category, to: to.category).padding(.horizontal, 3)
            PaletteReader(to.category) { p in Text(Self.shown(from: from, to: to)).scFont(SCTextStyle(.rounded, 12, line: 14, .bold).withTracking(0.3)).foregroundStyle(p.ink) }
        }
        .padding(.horizontal, 12).frame(height: 27)
        .background(Capsule().fill(Color.scCard).shadow(color: .black.opacity(0.07), radius: 3, y: 1))
        .overlay(Capsule().strokeBorder(Color.scHairline, lineWidth: 1))
    }
}

extension SCTextStyle {
    func withTracking(_ value: CGFloat) -> SCTextStyle { var copy = self; copy.tracking = value; return copy }
}

/// The overlay shown while files hover over a window that already holds cards (ux §5.2: anywhere over the window).
struct DragOverlay: View {
    let summary: DragSummary
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: SCMetrics.DropZone.cornerRadius, style: .continuous).fill(Color.scWindow.opacity(0.55))
            DropBorder(hovering: true)
            VStack(spacing: 4) {
                Text(summary.headline).scFont(SCTextStyle(.rounded, 22, line: 28, .heavy)).foregroundStyle(Color.scLabel)
                Text(summary.line).scFont(SCTextStyle(.text, 14, line: 18)).foregroundStyle(Color.scSecondary)
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.scCard).shadow(color: .black.opacity(0.14), radius: 14, y: 6))
        }
        .padding(SCMetrics.DropZone.inset)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}
