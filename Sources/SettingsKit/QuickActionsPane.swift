import AppKit
import SuperConverterCore
import SwiftUI

/// Quick Actions (ux §5.10, §5.11): which one-step Finder actions are offered, and what each one makes. Each switch is
/// macOS's own (System Settings › Extensions shows the same one), so the pane reads them on appear and when the app comes
/// back to the front.
struct QuickActionsPane: View {
    let context: SettingsContext
    @StateObject private var model: QuickActionsModel

    init(context: SettingsContext, model: QuickActionsModel? = nil) {
        self.context = context
        _model = StateObject(wrappedValue: model ?? QuickActionsModel(menuBar: context.menuBar))
    }

    static let extensionsSettings = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!

    static let intro = "Right-click files in Finder › Quick Actions to convert them in one step with your saved settings. Each action appears only for files it can take."
    static let footnote = "Switching an action here switches it in System Settings › Extensions too. The same actions are in the Services menu."
    static let unlisted = "macOS lists these actions once Super Converter is in your Applications folder and has been opened."

    var body: some View {
        PaneScroll {
            PaneNote(Self.intro)
            CardList {
                ForEach(Array(model.switches.enumerated()), id: \.element.target) { index, row in
                    if index > 0 { RowDivider() }
                    QuickActionRow(row: row) { on in Task { await model.set(row.target, on: on) } }
                }
            }
            if let problem = model.problem { PaneNote(problem) }
            if model.hasUnlisted { PaneNote(Self.unlisted) }
            HStack {
                Button("Open Extensions Settings…") { context.open(Self.extensionsSettings) }
                Spacer()
            }
            PaneNote(Self.footnote)
        }
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }
}

private struct QuickActionRow: View {
    let row: QuickActionSwitch
    let set: (Bool) -> Void

    var body: some View {
        SettingsRow(title: row.title, detail: row.takes) {
            HStack(spacing: 12) {
                Pill(text: row.target.pill, category: row.target.category)
                Toggle(row.title, isOn: Binding(get: { row.isOn ?? false }, set: set))
                    .labelsHidden().toggleStyle(.switch).disabled(row.isOn == nil)
            }
        }
    }
}
