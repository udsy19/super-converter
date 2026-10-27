import SuperConverterCore
import SwiftUI

/// Formats (ux §5.11): the default target for each source format, and the options saved for each target.
struct FormatsPane: View {
    enum Section: String, CaseIterable { case targets = "Default targets", options = "Saved options" }

    @StateObject private var model = FormatsModel()
    @State private var section: Section = .targets
    @State private var query = ""
    @State private var expanded: Set<FormatID> = []

    init(section: Section = .targets) { _section = State(initialValue: section) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                PaneNote(section == .targets
                    ? "What each kind of file becomes when you haven’t chosen. Your last choice for a format wins."
                    : "Settings saved with “Use these settings for every …” in a file’s options. Open a format to change them.")
                HStack(spacing: 12) {
                    Picker("Section", selection: $section) {
                        ForEach(Section.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
                    TextField("Search formats", text: $query).textFieldStyle(.roundedBorder)
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if section == .targets { targetRows } else { optionRows }
                }
                .padding(.horizontal, 20).padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func matches(_ id: FormatID) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return true }
        return id.rawValue.contains(text) || (FormatCatalog.format(id)?.name.lowercased().contains(text) ?? false)
    }

    private func heading(_ category: FormatCategory) -> some View {
        Text(category.title).scFont(SCFont.sectionHead).foregroundStyle(Color(SCColor.colors(for: category).inkToken))
    }

    // MARK: Default targets

    @ViewBuilder private var targetRows: some View {
        let _ = model.revision
        ForEach(FormatsModel.sourceGroups, id: \.category) { group in
            let sources = group.sources.filter(matches)
            if !sources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    heading(group.category)
                    CardList {
                        ForEach(Array(sources.enumerated()), id: \.element) { index, source in
                            if index > 0 { RowDivider() }
                            TargetRow(model: model, source: source)
                        }
                    }
                }
            }
        }
    }

    // MARK: Saved options

    @ViewBuilder private var optionRows: some View {
        let _ = model.revision
        ForEach(FormatsModel.targetGroups, id: \.category) { group in
            let targets = group.targets.filter(matches)
            if !targets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    heading(group.category)
                    CardList {
                        ForEach(Array(targets.enumerated()), id: \.element) { index, target in
                            if index > 0 { RowDivider() }
                            OptionsRow(model: model, target: target, isExpanded: expanded.contains(target)) {
                                if expanded.contains(target) { expanded.remove(target) } else { expanded.insert(target) }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// "HEIC → JPG" with a menu of the targets offered for the source and a reset when the person's choice differs from the table.
struct TargetRow: View {
    @ObservedObject var model: FormatsModel
    let source: FormatID

    var body: some View {
        let current = model.target(for: source)
        HStack(spacing: 12) {
            Pill(text: source.pill, category: source.category)
            Text(FormatCatalog.format(source)?.name ?? "").scFont(SCFont.meta).foregroundStyle(Color.scSecondary).lineLimit(1)
            Spacer(minLength: 12)
            if model.isCustomised(source: source) {
                Button("Reset") { model.resetTarget(for: source) }.buttonStyle(.link)
                    .accessibilityLabel("Reset the target for \(source.pill)")
            }
            Picker("Target for \(source.pill)", selection: Binding(get: { current ?? "" }, set: { model.setTarget($0, for: source) })) {
                ForEach(model.targets(for: source), id: \.self) { Text($0.pill).tag($0) }
            }.labelsHidden().frame(width: 120)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

/// One target with a summary of its saved options; opens into the profile's controls.
struct OptionsRow: View {
    @ObservedObject var model: FormatsModel
    let target: FormatID
    let isExpanded: Bool
    let toggle: () -> Void
    @State private var moreOpen = false

    var body: some View {
        let hasSaved = model.hasSaved(target)
        let definitions = model.definitions(for: target)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    HStack(spacing: 12) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.scSecondary).frame(width: 12)
                        Pill(text: target.pill, category: target.category)
                        Text(hasSaved ? model.summary(for: target) : (FormatCatalog.format(target)?.name ?? ""))
                            .scFont(SCFont.meta).foregroundStyle(Color.scSecondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(target.pill) options")
                if hasSaved {
                    Button("Reset") { model.resetOptions(for: target) }.buttonStyle(.link)
                        .accessibilityLabel("Reset the saved options for \(target.pill)")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if definitions.primary.isEmpty && definitions.more.isEmpty {
                        PaneNote("\(target.pill) has no options to save.")
                    }
                    ForEach(definitions.primary) { control($0) }
                    if !definitions.more.isEmpty {
                        DisclosureGroup("More options", isExpanded: $moreOpen) {
                            VStack(alignment: .leading, spacing: 10) { ForEach(definitions.more) { control($0) } }.padding(.top, 8)
                        }
                    }
                }
                .padding(.leading, 40).padding(.trailing, 16).padding(.bottom, 12)
            }
        }
    }

    private func control(_ definition: OptionDefinition) -> some View {
        OptionControl(definition: definition, value: model.saved(for: target)[definition.key],
                      set: { model.set(definition, to: $0, for: target) })
    }
}
