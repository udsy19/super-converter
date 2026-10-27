import SuperConverterCore
import SwiftUI

/// Quick Actions (ux §5.10, §5.11): which one-step Finder actions are offered, and what each one makes.
struct QuickActionsPane: View {
    let context: SettingsContext

    /// The one-step actions, in the order the spec lists them.
    struct QuickAction: Identifiable {
        let key: Defaults.Key<Bool>
        let target: FormatID
        let takes: String
        var id: FormatID { target }
        var title: String { "Convert to \(target.pill)" }
    }

    static let actions: [QuickAction] = [
        QuickAction(key: .quickActionConvertToJPG, target: "jpg", takes: "Images"),
        QuickAction(key: .quickActionConvertToPNG, target: "png", takes: "Images"),
        QuickAction(key: .quickActionConvertToPDF, target: "pdf", takes: "Documents, images, slides, sheets and e-books"),
        QuickAction(key: .quickActionConvertToMP4, target: "mp4", takes: "Videos"),
        QuickAction(key: .quickActionConvertToMP3, target: "mp3", takes: "Audio and videos"),
    ]

    static let extensionsSettings = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!

    var body: some View {
        PaneScroll {
            PaneNote("Right-click files in Finder › Quick Actions to convert them in one step with your saved settings. Each action appears only for files it can take.")
            CardList {
                ForEach(Array(Self.actions.enumerated()), id: \.element.id) { index, action in
                    if index > 0 { RowDivider() }
                    QuickActionRow(action: action)
                }
            }
            HStack {
                Button("Open Extensions Settings…") { context.open(Self.extensionsSettings) }
                Spacer()
            }
            PaneNote("macOS asks you to switch Finder extensions on in System Settings › Extensions. The same actions are in the Services menu.")
        }
    }
}

private struct QuickActionRow: View {
    let action: QuickActionsPane.QuickAction
    @State private var isOn: Bool

    init(action: QuickActionsPane.QuickAction) {
        self.action = action
        _isOn = State(initialValue: Defaults[action.key])
    }

    var body: some View {
        SettingsRow(title: action.title, detail: action.takes) {
            HStack(spacing: 12) {
                Pill(text: action.target.pill, category: action.target.category)
                Toggle(action.title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
            }
        }
        .onChange(of: isOn) { _, value in Defaults[action.key] = value }
    }
}
