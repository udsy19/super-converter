import Combine
import Foundation
import SuperConverterCore

/// What the Formats pane edits (ux §5.11): the default target of each source format (§6.1) and the options saved for each
/// target format ("Use these settings for every …", §5.5). Everything is read from and written to `Defaults`; the model only
/// adds the lookups and republishes when a target or options key changes.
@MainActor
final class FormatsModel: ObservableObject {
    /// Bumped whenever a saved target or saved options change, so views re-read.
    @Published private(set) var revision = 0
    private var subscription: AnyCancellable?

    init() {
        subscription = Defaults.changes.filter { $0.hasPrefix("target.") || $0.hasPrefix("options.") }
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.revision += 1 }
    }

    // MARK: Default targets

    /// Source formats that have a default target and at least one offered target, by category in catalog order.
    static let sourceGroups: [(category: FormatCategory, sources: [FormatID])] = {
        let sources = DefaultTargets.sources.filter { !FormatMatrix.targets(for: $0).isEmpty }
        return FormatCategory.allCases.compactMap { category in
            let members = sources.filter { FormatCatalog.format($0)?.category == category }
            return members.isEmpty ? nil : (category, members)
        }
    }()

    func targets(for source: FormatID) -> [FormatID] { FormatMatrix.targets(for: source) }

    /// The target a file of this format becomes: the saved choice, else the table's.
    func target(for source: FormatID) -> FormatID? {
        DefaultTargets.target(for: source, remembered: Defaults[.target(for: source)])
    }

    /// True when the person's own choice (not the table) decides.
    func isCustomised(source: FormatID) -> Bool { Defaults[.target(for: source)] != nil }

    func setTarget(_ target: FormatID, for source: FormatID) { Defaults[.target(for: source)] = target }
    func resetTarget(for source: FormatID) { Defaults.reset(.target(for: source)) }

    // MARK: Saved options

    /// Every format that is the target of an offered pair, by category.
    static let targetGroups: [(category: FormatCategory, targets: [FormatID])] = {
        let targets = Set(FormatMatrix.offered.map(\.to))
        return FormatCategory.allCases.compactMap { category in
            let members = FormatCatalog.formats(in: category).map(\.id).filter(targets.contains)
            return members.isEmpty ? nil : (category, members)
        }
    }()

    /// The option profile of a target: the one most of its offered pairs use (a target such as PDF has several; the saved
    /// values are per target, so the commonest decides which controls are shown).
    func profile(for target: FormatID) -> OptionProfile? {
        let ids = FormatMatrix.offered.filter { $0.to == target }.map(\.options)
        let counts = Dictionary(ids.map { ($0, 1) }, uniquingKeysWith: +)
        guard let best = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key else { return nil }
        return OptionProfiles.profile(best)
    }

    /// The controls a saved-options row edits: the per-card "look" is not saved (ux §5.5).
    func definitions(for target: FormatID) -> (primary: [OptionDefinition], more: [OptionDefinition]) {
        guard let profile = profile(for: target) else { return ([], []) }
        let usable = profile.options.filter { definition in
            if definition.key == "look" { return false }
            if case .secret = definition.kind { return false }
            return true
        }
        return (usable.filter { !$0.isMore }, usable.filter(\.isMore))
    }

    func saved(for target: FormatID) -> OptionValues { Defaults[.savedOptions(for: target)] ?? OptionValues() }

    func hasSaved(_ target: FormatID) -> Bool { !(Defaults[.savedOptions(for: target)]?.isEmpty ?? true) }

    /// Sets one option; a value equal to its default (or nil) is removed so only differences are stored, and the key goes
    /// away entirely when nothing differs.
    func set(_ definition: OptionDefinition, to value: OptionValue?, for target: FormatID) {
        var values = saved(for: target)
        values[definition.key] = (value == nil || value == definition.defaultValue) ? nil : value
        if values.isEmpty { Defaults.reset(.savedOptions(for: target)) } else { Defaults[.savedOptions(for: target)] = values }
    }

    func resetOptions(for target: FormatID) { Defaults.reset(.savedOptions(for: target)) }

    /// "Quality 80 · Progressive": what the saved options change, in the profile's own words.
    func summary(for target: FormatID) -> String {
        guard let profile = profile(for: target) else { return "" }
        let values = saved(for: target)
        return profile.options.compactMap { definition -> String? in
            guard let value = values[definition.key] else { return nil }
            return "\(definition.label): \(Self.describe(value, definition))"
        }.joined(separator: " · ")
    }

    private static func describe(_ value: OptionValue, _ definition: OptionDefinition) -> String {
        switch value {
        case .bool(let on): return on ? "on" : "off"
        case .int(let n): return "\(n)"
        case .double(let x): return String(format: "%g", x)
        case .string(let s):
            if case .choice(let choices) = definition.kind, let match = choices.first(where: { $0.id == s }) { return match.label }
            return s
        }
    }
}
