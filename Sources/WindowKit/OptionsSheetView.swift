import SuperConverterCore
import SwiftUI

/// The per-file options sheet (ux §5.5, mockup `options-sheet.png`): the pair in the header, the profile's first controls in
/// plain words, the rest under More options, "Use these settings for every JPG", Cancel and Done.
struct OptionsSheetView: View {
    @ObservedObject var model: OptionsModel
    var cancel: () -> Void
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 16)
            Rectangle().fill(Color.scHairline).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.primary) { definition in OptionRow(model: model, definition: definition) }
                if !model.more.isEmpty { moreOptions }
            }
            .padding(.vertical, 12)
            Rectangle().fill(Color.scHairline).frame(height: 1)
            footer.padding(.top, 16)
        }
        .padding(.horizontal, 26).padding(.top, 22).padding(.bottom, 22)
        .frame(width: SCMetrics.OptionsSheet.width)
        .background(Color.scCard)
    }

    private var header: some View {
        HStack(spacing: 0) {
            SourcePill(format: model.source)
            FlowArrow(from: model.source.category, to: model.target.category).padding(.horizontal, 4)
            TargetPill(format: model.target, category: model.target.category, chevron: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).scFont(SCFont.title).foregroundStyle(Color.scLabel)
                Text(model.subtitle).scFont(SCTextStyle(.text, 13, line: 16)).foregroundStyle(Color.scSecondary).lineLimit(1).truncationMode(.middle)
            }
            .padding(.leading, 14)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var moreOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { model.moreExpanded.toggle() } } label: {
                HStack(spacing: 10) {
                    Color.clear.frame(width: SCMetrics.OptionsSheet.labelColumn - 20, height: 1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(model.moreExpanded ? 90 : 0))
                        .foregroundStyle(Color.scSecondary).frame(width: 10)
                    Text("More options").scFont(SCTextStyle(.text, 13, line: 17, .medium)).foregroundStyle(Color.scLabel)
                    if !model.moreExpanded {
                        Text(model.moreSummary).scFont(SCTextStyle(.text, 13, line: 16)).foregroundStyle(Color.scSecondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, SCMetrics.OptionsSheet.rowPadding).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More options")
            .accessibilityValue(model.moreExpanded ? "Shown" : "Hidden")
            if model.moreExpanded {
                ForEach(model.more) { definition in OptionRow(model: model, definition: definition, showsTechnicalName: true) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle(isOn: $model.useForEvery) {
                Text("Use these settings for every \(model.target.pill)").scFont(SCTextStyle(.text, 13, line: 17))
            }
            .toggleStyle(AccentCheckboxStyle())
            Spacer(minLength: 8)
            Button(action: cancel) {
                Text("Cancel").scFont(SCTextStyle(.text, 13, line: 17, .medium)).foregroundStyle(Color.scLabel)
                    .padding(.horizontal, 20).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.scCard).shadow(color: .black.opacity(0.08), radius: 1, y: 1))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.scStrongHairline, lineWidth: 1))
            }
            .buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Cancel")
            Button(action: done) {
                Text("Done").scFont(SCTextStyle(.text, 13, line: 17, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 22).frame(height: 32).background(RoundedRectangle(cornerRadius: 8).fill(Color.scAccent))
            }
            .buttonStyle(.plain).keyboardShortcut(.defaultAction).accessibilityLabel("Done")
        }
    }
}

/// One option: the right-aligned label, then the control its kind calls for.
private struct OptionRow: View {
    @ObservedObject var model: OptionsModel
    let definition: OptionDefinition
    var showsTechnicalName = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(rowLabel).scFont(SCTextStyle(.text, 13, line: 17)).foregroundStyle(Color.scLabel)
                .multilineTextAlignment(.trailing).frame(width: SCMetrics.OptionsSheet.labelColumn, alignment: .trailing)
                .padding(.top, controlTopInset)
            control.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, SCMetrics.OptionsSheet.rowPadding)
        .accessibilityElement(children: .contain)
    }

    private var rowLabel: String {
        if let parts = sliderCaptions { return definition.technicalName?.capitalized ?? parts.0 }
        if showsTechnicalName, let technical = definition.technicalName, technical.lowercased() != definition.label.lowercased() {
            return "\(definition.label) (\(technical))"
        }
        return definition.label
    }

    /// "Smaller file ↔ Best quality" splits into the two captions under a slider.
    private var sliderCaptions: (String, String)? {
        let parts = definition.label.components(separatedBy: " ↔ ")
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    private var controlTopInset: CGFloat {
        switch definition.kind {
        case .integer, .number: sliderCaptions == nil ? 0 : 4
        default: 4
        }
    }

    @ViewBuilder private var control: some View {
        switch definition.kind {
        case .toggle:
            Toggle("", isOn: boolBinding).toggleStyle(AccentCheckboxStyle()).labelsHidden().accessibilityLabel(definition.label).padding(.top, 4)
        case .choice(let choices):
            HStack(spacing: 16) {
                ChoiceControl(label: definition.label, choices: visible(choices), selection: stringBinding, tint: model.target.category)
                if definition.key == "size", let pixels = model.pixels {
                    Text("\(pixels.width) × \(pixels.height)").scFont(SCTextStyle(.text, 13, line: 17)).foregroundStyle(Color.scSecondary)
                }
            }
        case .integer(let range, let unit):
            SliderControl(label: definition.label, range: Double(range.lowerBound)...Double(range.upperBound), unit: unit, captions: sliderCaptions,
                          tint: model.target.category, value: doubleBinding(default: Double(range.lowerBound)), isInteger: true,
                          note: definition.key == "quality" ? model.estimate : nil)
        case .number(let range, let unit):
            SliderControl(label: definition.label, range: range, unit: unit, captions: sliderCaptions, tint: model.target.category,
                          value: doubleBinding(default: range.lowerBound), isInteger: false, note: nil)
        case .text, .pageRange, .file:
            TextField(definition.kind == .pageRange ? "All pages" : "", text: stringBinding).textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280).accessibilityLabel(definition.label)
        case .secret:
            SecureField("", text: stringBinding).textFieldStyle(.roundedBorder).frame(maxWidth: 280).accessibilityLabel(definition.label)
        case .colour:
            ColorPicker("", selection: colourBinding, supportsOpacity: false).labelsHidden().accessibilityLabel(definition.label)
        }
    }

    /// The look control offers only the looks the pair has.
    private func visible(_ choices: [OptionChoice]) -> [OptionChoice] {
        guard definition.key == "look", !model.looks.isEmpty else { return choices }
        let allowed = Set(model.looks.map(\.rawValue))
        return choices.filter { allowed.contains($0.id) }
    }

    private var boolBinding: Binding<Bool> {
        Binding(get: { model.value(definition)?.bool ?? false }, set: { model.set(definition, .bool($0)) })
    }

    private var stringBinding: Binding<String> {
        Binding(get: { model.value(definition)?.string ?? "" }, set: { model.set(definition, .string($0)) })
    }

    private func doubleBinding(default fallback: Double) -> Binding<Double> {
        Binding(get: { model.value(definition)?.double ?? fallback }, set: { newValue in
            if case .integer = definition.kind { model.set(definition, .int(Int(newValue.rounded()))) } else { model.set(definition, .double(newValue)) }
        })
    }

    private var colourBinding: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: model.value(definition)?.string ?? "#FFFFFF")) },
                set: { model.set(definition, .string(String($0.hexString.prefix(7)))) })
    }
}

private extension Color {
    var hexString: String { NSColor(self).hexRGBA }
}

/// A slider with its value at the right and captions under the ends ("Smaller file", "Best quality").
private struct SliderControl: View {
    let label: String
    let range: ClosedRange<Double>
    let unit: String?
    let captions: (String, String)?
    let tint: FormatCategory
    @Binding var value: Double
    let isInteger: Bool
    let note: String?

    var body: some View {
        PaletteReader(tint) { p in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) {
                    CapsuleSlider(value: $value, range: range, step: isInteger ? 1 : 0.1, tint: p.filledFill).accessibilityLabel(label).accessibilityValue(valueText)
                    Text(valueText).font(Font(SCTextStyle(.text, 15, line: 18, .semibold).font).monospacedDigit()).foregroundStyle(Color.scLabel)
                        .frame(minWidth: 40, alignment: .trailing)
                }
                if let captions {
                    HStack {
                        Text(captions.0); Spacer(); Text(captions.1)
                    }
                    .scFont(SCTextStyle(.text, 13, line: 16)).foregroundStyle(Color.scSecondary).padding(.trailing, 52)
                }
                if let note { EstimateLine(text: note).padding(.top, 4) }
            }
        }
    }

    private var valueText: String {
        let number = isInteger ? "\(Int(value.rounded()))" : String(format: "%g", (value * 10).rounded() / 10)
        return unit.map { "\(number) \($0)" } ?? number
    }
}

/// "About 2.1 MB each — looks the same as the original": the bold half is the number.
private struct EstimateLine: View {
    let text: String
    var body: some View {
        let parts = text.components(separatedBy: " — ")
        HStack(spacing: 0) {
            Text(parts[0]).font(Font(SCTextStyle(.text, 13, line: 17, .semibold).font)).foregroundStyle(Color.scLabel)
            if parts.count > 1 { Text(" — " + parts[1]).scFont(SCTextStyle(.text, 13, line: 17)).foregroundStyle(Color.scSecondary) }
        }
    }
}

/// A choice: a segmented control when it is short, a pop-up menu otherwise (the mockup's Size and Colours rows).
private struct ChoiceControl: View {
    let label: String
    let choices: [OptionChoice]
    @Binding var selection: String
    let tint: FormatCategory

    private var isSegmented: Bool { choices.count <= 4 && choices.reduce(0) { $0 + $1.label.count } <= 40 }

    var body: some View {
        if isSegmented {
            HStack(spacing: 0) {
                ForEach(choices, id: \.id) { choice in
                    let selected = choice.id == selection
                    Button { selection = choice.id } label: {
                        Text(choice.label).font(Font(SCTextStyle(.text, 13, line: 17, selected ? .semibold : .regular).font))
                            .foregroundStyle(Color.scLabel).padding(.horizontal, 14).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.scCard : .clear)
                                .shadow(color: .black.opacity(selected ? 0.14 : 0), radius: 1.5, y: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(choice.label)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(2).background(RoundedRectangle(cornerRadius: 9).fill(Color.scControl))
            .accessibilityElement(children: .contain).accessibilityLabel(label)
        } else {
            Menu {
                ForEach(choices, id: \.id) { choice in Button(choice.label) { selection = choice.id } }
            } label: {
                HStack(spacing: 8) {
                    Text(choices.first { $0.id == selection }?.label ?? "").scFont(SCTextStyle(.text, 13, line: 17)).foregroundStyle(Color.scLabel)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.scSecondary)
                }
                .padding(.horizontal, 12).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.scCard))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.scStrongHairline, lineWidth: 1))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(label)
        }
    }
}

/// A slider drawn by hand so it wears the target's colour whether or not the window is active: a 4 pt capsule track, the
/// filled part in the category colour, a white thumb.
struct CapsuleSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (value - range.lowerBound) / span : 0
            let travel = max(proxy.size.width - 22, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.scControlHover).frame(height: 4)
                Capsule().fill(tint).frame(width: 11 + travel * fraction, height: 4)
                Circle().fill(Color.white).frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.22), radius: 2, y: 1).overlay(Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                    .offset(x: travel * fraction)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = min(max((drag.location.x - 11) / travel, 0), 1)
                let raw = range.lowerBound + f * span
                value = (raw / step).rounded() * step
            })
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(value + step * (range.upperBound - range.lowerBound > 20 ? 5 : 1), range.upperBound)
            case .decrement: value = max(value - step * (range.upperBound - range.lowerBound > 20 ? 5 : 1), range.lowerBound)
            @unknown default: break
            }
        }
    }
}
