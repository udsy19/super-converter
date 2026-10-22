import SuperConverterCore
import SwiftUI

// The small parts every screen shares: format pills, the flow arrow (ux §3.4), a wrapping layout, round icon buttons.

/// A wrapping row layout: children keep their size and flow onto new lines (picker chips, popular pairs).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    private func lines(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var result: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width + 0.5 { result.append([]); x = 0 }
            result[result.count - 1].append((index, size))
            x += size.width + spacing
        }
        return result.map { $0.map { (index: $0.0, size: $0.1) } }
    }

    private func rowWidth(_ row: [(index: Int, size: CGSize)]) -> CGFloat {
        var total: CGFloat = 0
        for item in row { total += item.size.width }
        return total + spacing * CGFloat(max(row.count - 1, 0))
    }

    private func rowHeight(_ row: [(index: Int, size: CGSize)]) -> CGFloat {
        var tallest: CGFloat = 0
        for item in row { tallest = max(tallest, item.size.height) }
        return tallest
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lines(subviews, width: width)
        var height: CGFloat = lineSpacing * CGFloat(max(rows.count - 1, 0))
        var used: CGFloat = 0
        for row in rows { height += rowHeight(row); used = max(used, rowWidth(row)) }
        return CGSize(width: proposal.width == nil ? used : min(used, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in lines(subviews, width: bounds.width) {
            let height = rowHeight(row)
            var x = alignment == .center ? bounds.minX + (bounds.width - rowWidth(row)) / 2 : bounds.minX
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + lineSpacing
        }
    }
}

/// The source format's pill: 22 tall, category tint, ink text (ux §3.5).
struct SourcePill: View {
    let format: FormatID
    var body: some View { PaletteReader(format.category) { p in
        Text(format.pill).scFont(SCFont.pill).foregroundStyle(p.ink)
            .padding(.horizontal, 8).frame(height: SCMetrics.Card.sourcePillHeight)
            .background(Capsule().fill(p.tint))
            .overlay { if let border = p.border { Capsule().strokeBorder(border, lineWidth: SCColor.increasedContrastBorder) } }
    } }
}

/// The target pill: 26 tall, filled; with a chevron when it opens the picker (ux §3.5).
struct TargetPill: View {
    let format: FormatID?
    var category: FormatCategory
    var chevron = true

    var body: some View { PaletteReader(category) { p in
        HStack(spacing: 4) {
            Text(format?.pill ?? "Choose").scFont(SCFont.targetPill)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 9, weight: .heavy)).accessibilityHidden(true) }
        }
        .foregroundStyle(format == nil ? Color.scLabel : p.filledText)
        .padding(.leading, 11).padding(.trailing, chevron ? 9 : 11)
        .frame(height: SCMetrics.Card.targetPillHeight)
        .background(Capsule().fill(format == nil ? Color.scControl : p.filledFill))
        .overlay { if let border = p.border { Capsule().strokeBorder(border, lineWidth: SCColor.increasedContrastBorder) } }
    } }
}

/// The flow arrow (ux §3.4): a 15 × 2 line from the source colour to the target colour, ending in a target-coloured head.
struct FlowArrow: View {
    let from: FormatCategory
    let to: FormatCategory

    var body: some View {
        let target = Color(nsColor: NSColor(hex: SCColor.colors(for: to).base))
        HStack(spacing: -1) {
            Capsule().fill(flowGradient(from: from, to: to))
                .frame(width: SCMetrics.Card.flowSize.width, height: SCMetrics.Card.flowSize.height)
            ArrowHead().fill(target).frame(width: 5, height: 8)
        }
        .padding(.horizontal, SCMetrics.Card.flowGap)
        .accessibilityHidden(true)
    }
}

struct ArrowHead: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Resolves a category's palette for the current appearance and contrast.
struct PaletteReader<Content: View>: View {
    let category: FormatCategory
    let content: (Palette) -> Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ category: FormatCategory, @ViewBuilder content: @escaping (Palette) -> Content) {
        self.category = category; self.content = content
    }

    var body: some View { content(Palette(category, scheme: scheme, contrast: contrast)) }
}

/// A round icon button on a card (options, Quick Look, Share, Show in Finder): 26 pt, control fill on hover.
struct CircleIconButton: View {
    let symbol: String
    let label: String
    var filled = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { CircleIcon(symbol: symbol, filled: filled, hovering: hovering) }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(label)
            .help(label)
    }
}

struct CircleIcon: View {
    let symbol: String
    var filled = false
    var hovering = false

    var body: some View {
        Image(systemName: symbol).font(.system(size: 13, weight: .regular))
            .foregroundStyle(filled ? Color.scLabel : Color.scSecondary)
            .frame(width: SCMetrics.Card.optionsButton, height: SCMetrics.Card.optionsButton)
            .background(Circle().fill(filled || hovering ? Color.scControl : .clear))
            .contentShape(Circle())
    }
}

/// A checkbox that is blue whether or not the window is active (the sheet and popover are drawn in their own windows).
struct AccentCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(configuration.isOn ? Color.scAccent : Color.scCard)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(configuration.isOn ? Color.clear : Color.scStrongHairline, lineWidth: 1))
                    .overlay { if configuration.isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) } }
                    .frame(width: 15, height: 15)
                configuration.label
            }
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}
