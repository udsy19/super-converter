import AppKit
import SuperConverterCore
import SwiftUI

/// One option of a profile as a control (formats §5): the Formats pane's editor for saved options.
struct OptionControl: View {
    let definition: OptionDefinition
    let value: OptionValue?
    let set: (OptionValue?) -> Void

    private var current: OptionValue? { value ?? definition.defaultValue }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(definition.label).scFont(SCFont.body).foregroundStyle(Color.scLabel)
                .frame(width: SCMetrics.OptionsSheet.labelColumn + 40, alignment: .leading)
            control
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var control: some View {
        switch definition.kind {
        case .toggle:
            Toggle(definition.label, isOn: Binding(get: { current?.bool ?? false }, set: { set(.bool($0)) }))
                .labelsHidden().toggleStyle(.switch)
        case .choice(let choices):
            Picker(definition.label, selection: Binding(get: { current?.string ?? choices.first?.id ?? "" }, set: { set(.string($0)) })) {
                ForEach(choices, id: \.id) { Text($0.label).tag($0.id) }
            }.labelsHidden().frame(maxWidth: 240)
        case .integer(let range, let unit):
            slider(Double(range.lowerBound)...Double(range.upperBound), unit: unit, integer: true)
        case .number(let range, let unit):
            slider(range, unit: unit, integer: false)
        case .text, .pageRange, .file:
            TextField(definition.kind == .pageRange ? "All pages" : "", text: Binding(get: { current?.string ?? "" }, set: { set($0.isEmpty ? nil : .string($0)) }))
                .textFieldStyle(.roundedBorder).frame(maxWidth: 240).accessibilityLabel(definition.label)
        case .secret:
            EmptyView()
        case .colour:
            ColorPicker(definition.label, selection: Binding(
                get: { Color(nsColor: NSColor(hex: current?.string ?? "#FFFFFF")) },
                set: { set(.string(String(NSColor($0).hexRGBA.prefix(7)))) }), supportsOpacity: false).labelsHidden()
        }
    }

    private func slider(_ range: ClosedRange<Double>, unit: String?, integer: Bool) -> some View {
        let binding = Binding<Double>(get: { current?.double ?? range.lowerBound }, set: { newValue in
            set(integer ? .int(Int(newValue.rounded())) : .double(newValue))
        })
        return HStack(spacing: 10) {
            Slider(value: binding, in: range).frame(width: 200).accessibilityLabel(definition.label)
            Text((integer ? "\(Int(binding.wrappedValue.rounded()))" : String(format: "%g", binding.wrappedValue)) + (unit.map { " \($0)" } ?? ""))
                .scFont(SCFont.meta).foregroundStyle(Color.scSecondary).frame(minWidth: 48, alignment: .leading)
        }
    }
}
