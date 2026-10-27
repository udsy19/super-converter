import SuperConverterCore
import SwiftUI

/// The tab row and the pane under it (ux §5.11, `settings-helpers.png`).
struct SettingsView: View {
    @ObservedObject var selection: SettingsSelection
    let context: SettingsContext

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(SettingsPane.allCases, id: \.self) { pane in
                    SettingsTab(pane: pane, isSelected: pane == selection.pane) { selection.pane = pane }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            Rectangle().fill(Color.scHairline).frame(height: 1)
            pane.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: SCMetrics.Settings.size.width, height: SCMetrics.Settings.size.height)
        .background(Color.scWindow)
    }

    @ViewBuilder private var pane: some View {
        switch selection.pane {
        case .general: GeneralPane(context: context)
        case .formats: FormatsPane()
        case .helpers: HelpersPane(context: context)
        case .quickActions: QuickActionsPane(context: context)
        case .about: AboutPane(context: context)
        }
    }
}

private struct SettingsTab: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void

    private var symbol: String {
        switch pane {
        case .general: "gearshape"
        case .formats: "square.grid.2x2"
        case .helpers: "arrow.down.to.line"
        case .quickActions: "arrow.triangle.2.circlepath"
        case .about: "eye"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18, weight: .regular)).frame(height: 22)
                Text(pane.title).scFont(SCTextStyle(.text, 12, line: 14))
            }
            .foregroundStyle(isSelected ? Color.scAccent : Color.scSecondary)
            .frame(width: 128, height: 54)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.scControl : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A pane's scrolling body.
struct PaneScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.horizontal, 20).padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
