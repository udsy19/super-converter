import SuperConverterCore
import SwiftUI

/// The target picker popover (ux §5.4, mockup `target-picker.png`): search, "Best for …", categories with coloured chips,
/// "Use X for Y files from now on".
struct FormatPickerView: View {
    @ObservedObject var model: FormatPickerModel
    var pick: (FormatID) -> Void
    var close: () -> Void
    @FocusState private var searchFocused: Bool
    @State private var contentHeight: CGFloat = 0
    private let maxListHeight: CGFloat = 330

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField.padding(.bottom, 14)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    content.background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
                }
                .frame(height: contentHeight > 0 ? min(contentHeight, maxListHeight) : nil)
                .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
                .onChange(of: model.focused) { _, focus in if let focus { withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(focus) } } }
            }
            footer.padding(.top, 12)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: SCMetrics.Picker.width)
        .background(Color.scCard)
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Color.scTertiary).accessibilityHidden(true)
            TextField(model.placeholder, text: $model.query)
                .textFieldStyle(.plain).scFont(SCTextStyle(.text, 13, line: 17))
                .focused($searchFocused)
                .onSubmit { if let target = model.focusedTarget { pick(target.format) } }
                .onKeyPress(.downArrow) { model.move(7); return .handled }
                .onKeyPress(.upArrow) { model.move(-7); return .handled }
                .onKeyPress(.rightArrow, phases: [.down, .repeat]) { _ in
                    model.query.isEmpty ? { model.move(1); return .handled }() : .ignored
                }
                .onKeyPress(.leftArrow, phases: [.down, .repeat]) { _ in
                    model.query.isEmpty ? { model.move(-1); return .handled }() : .ignored
                }
                .accessibilityLabel("Search formats")
        }
        .padding(.horizontal, 10).frame(height: SCMetrics.Picker.searchHeight)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.scControl))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !model.isSearching, !model.suggestions.isEmpty { bestFor }
            let rows = sectionRows
            ForEach(rows.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(rows[i]) { section in
                        SectionView(section: section, model: model, pick: pick)
                            .frame(width: rows[i].count == 2 ? 192 : nil, alignment: .leading)
                    }
                    if rows[i].count == 2 { Spacer(minLength: 0) }
                }
            }
            if model.isSearching && model.matches.isEmpty { noMatches }
            if model.isSearching, !model.notOffered.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.notOffered, id: \.format) { item in
                        Text("\(item.format.pill): \(item.reason)").scFont(SCFont.body).foregroundStyle(Color.scSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Small groups sit two to a row ("DOCUMENTS" and "VECTOR" in the mockup); big groups take a row.
    private var sectionRows: [[PickerSection]] {
        var rows: [[PickerSection]] = []
        var pending: PickerSection?
        for section in model.sections {
            if section.targets.count <= 2 {
                if let first = pending { rows.append([first, section]); pending = nil } else { pending = section }
            } else {
                if let first = pending { rows.append([first]); pending = nil }
                rows.append([section])
            }
        }
        if let first = pending { rows.append([first]) }
        return rows
    }

    private var bestFor: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHead(category: model.sourceCategory, title: "\(Strings.Picker.bestFor) \(model.sourceCategory.noun(count: 2))")
            HStack(spacing: 7) {
                ForEach(model.suggestions) { suggestion in
                    SuggestionChip(suggestion: suggestion, isCurrent: suggestion.target.format == model.current,
                                   isFocused: suggestion.target.format == model.focused) { pick(suggestion.target.format) }
                }
            }
        }
    }

    private var noMatches: some View {
        Text("No formats match “\(model.query)”").scFont(SCFont.body).foregroundStyle(Color.scSecondary)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            Rectangle().fill(Color.scHairline).frame(height: 1)
            HStack {
                if let target = model.current ?? model.focused {
                    Toggle(isOn: $model.remember) {
                        Text(Strings.Picker.useFromNowOn(target, source: model.source)).scFont(SCFont.body)
                    }
                    .toggleStyle(AccentCheckboxStyle())
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    KeyCap(text: "↩"); Text("choose").scFont(SCTextStyle(.text, 12, line: 16)).foregroundStyle(Color.scSecondary)
                    KeyCap(text: "esc"); Text("close").scFont(SCTextStyle(.text, 12, line: 16)).foregroundStyle(Color.scSecondary)
                }
                .accessibilityHidden(true)
            }
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .regular)).foregroundStyle(Color.scSecondary)
            .padding(.horizontal, 6).frame(height: 20)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.scStrongHairline, lineWidth: 1))
    }
}

/// "● IMAGES": the category dot and the section head (ux §3.5).
private struct SectionHead: View {
    let category: FormatCategory
    let title: String
    var body: some View {
        PaletteReader(category) { p in
            HStack(spacing: 7) {
                Circle().fill(p.base).frame(width: SCMetrics.Picker.categoryDot, height: SCMetrics.Picker.categoryDot)
                Text(title.uppercased()).scFont(SCFont.sectionHead).foregroundStyle(Color.scSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct SectionView: View {
    let section: PickerSection
    @ObservedObject var model: FormatPickerModel
    var pick: (FormatID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHead(category: section.category, title: section.category.title)
            if let hint = section.hint, let target = section.targets.first {
                HStack(spacing: 8) {
                    FormatChip(target: target, isCurrent: target.format == model.current, isFocused: target.format == model.focused) { pick(target.format) }
                    Text(hint).scFont(SCTextStyle(.text, 12.5, line: 16)).foregroundStyle(Color.scSecondary).lineLimit(1)
                }
            } else {
                FlowLayout(spacing: SCMetrics.Picker.formatChipGap, lineSpacing: SCMetrics.Picker.formatChipGap) {
                    ForEach(section.targets) { target in
                        FormatChip(target: target, isCurrent: target.format == model.current, isFocused: target.format == model.focused) { pick(target.format) }
                            .id(target.format)
                    }
                }
            }
        }
    }
}

/// A format chip: 28 tall, at least 52 wide, radius 8, category tint; the current target is filled and ringed (ux §3.5).
struct FormatChip: View {
    let target: PickerTarget
    var isCurrent = false
    var isFocused = false
    var action: () -> Void

    var body: some View {
        PaletteReader(target.format.category) { p in
            Button(action: action) {
                HStack(spacing: 4) {
                    Text(target.format.pill).scFont(SCFont.pill)
                    if target.neededHelper != nil { Image(systemName: "arrow.down.circle").font(.system(size: 10, weight: .bold)).accessibilityHidden(true) }
                }
                .foregroundStyle(isCurrent ? p.filledText : p.ink)
                .padding(.horizontal, 10).frame(minWidth: SCMetrics.Picker.formatChipMinWidth, minHeight: SCMetrics.Picker.formatChipHeight)
                .background(RoundedRectangle(cornerRadius: SCMetrics.Picker.formatChipRadius).fill(isCurrent ? p.filledFill : p.tint))
                .overlay {
                    if isCurrent { RoundedRectangle(cornerRadius: SCMetrics.Picker.formatChipRadius + 2).strokeBorder(p.filledFill, lineWidth: 2).padding(-3.5) }
                    else if let border = p.border { RoundedRectangle(cornerRadius: SCMetrics.Picker.formatChipRadius).strokeBorder(border, lineWidth: 1) }
                }
                .overlay { if isFocused && !isCurrent { RoundedRectangle(cornerRadius: SCMetrics.Picker.formatChipRadius).strokeBorder(Color.scAccent, lineWidth: 2) } }
                .opacity(target.isAvailable ? 1 : 0.4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!target.isAvailable)
            .help(target.neededHelper.map(Strings.Picker.needsHelperHint) ?? "")
            .accessibilityLabel(label)
        }
    }

    private var label: String {
        var text = "\(target.format.pill), \(FormatCatalog.format(target.format)?.name ?? "")"
        if let helper = target.neededHelper { text += ". " + Strings.Picker.needsHelperHint(helper) }
        if isCurrent { text += ", current" }
        return text
    }
}

/// A "Best for …" chip: 78 × 58, the format over its two-word reason.
private struct SuggestionChip: View {
    let suggestion: Suggestion
    let isCurrent: Bool
    let isFocused: Bool
    var action: () -> Void

    var body: some View {
        PaletteReader(suggestion.target.format.category) { p in
            Button(action: action) {
                VStack(spacing: 3) {
                    HStack(spacing: 3) {
                        Text(suggestion.target.format.pill).font(Font(SCTextStyle(.rounded, 17, line: 20, .bold).font)).tracking(0.2)
                        if suggestion.target.neededHelper != nil { Image(systemName: "arrow.down.circle").font(.system(size: 10, weight: .bold)).accessibilityHidden(true) }
                    }
                    Text(suggestion.reason).font(Font(SCTextStyle(.text, 11.5, line: 14).font)).opacity(isCurrent ? 0.9 : 0.85)
                }
                .foregroundStyle(isCurrent ? p.filledText : p.ink)
                .frame(width: SCMetrics.Picker.chipSize.width, height: SCMetrics.Picker.chipSize.height)
                .background(RoundedRectangle(cornerRadius: SCMetrics.Picker.chipRadius).fill(isCurrent ? p.filledFill : p.tint))
                .overlay {
                    if let border = p.border, !isCurrent { RoundedRectangle(cornerRadius: SCMetrics.Picker.chipRadius).strokeBorder(border, lineWidth: 1) }
                    if isFocused && !isCurrent { RoundedRectangle(cornerRadius: SCMetrics.Picker.chipRadius).strokeBorder(Color.scAccent, lineWidth: 2) }
                }
                .opacity(suggestion.target.isAvailable ? 1 : 0.4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!suggestion.target.isAvailable)
            .help(suggestion.target.neededHelper.map(Strings.Picker.needsHelperHint) ?? "")
            .accessibilityLabel("\(suggestion.target.format.pill), \(suggestion.reason)" + (isCurrent ? ", current" : ""))
            .id(suggestion.target.format)
        }
    }
}
