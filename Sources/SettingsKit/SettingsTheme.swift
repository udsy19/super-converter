import AppKit
import SuperConverterCore
import SwiftUI

// SwiftUI bridges for the Core design tokens (ux §3), the few the Settings panes need. SettingsKit depends on Core only, so
// WindowKit's own bridges (the same few lines) are not importable.

extension Color {
    init(_ token: SCColorToken) { self.init(nsColor: token.color) }

    static let scWindow = Color(SCColor.windowBackground)
    static let scCard = Color(SCColor.card)
    static let scHairline = Color(SCColor.hairline)
    static let scLabel = Color(SCColor.label)
    static let scSecondary = Color(SCColor.secondaryLabel)
    static let scControl = Color(SCColor.controlFill)
    static let scSuccess = Color(SCColor.success)
    static let scFailure = Color(SCColor.failure)
    static let scAccent = Color(SCColor.accent)
}

extension View {
    /// Applies a Core type style (family, size, weight, tracking, tabular figures).
    func scFont(_ style: SCTextStyle) -> some View {
        let font = style.tabularFigures ? Font(style.font).monospacedDigit() : Font(style.font)
        return self.font(font).tracking(style.tracking).textCase(style.uppercase ? .uppercase : nil)
    }
}

extension FormatID {
    /// The category colour a format wears; unknown formats read as documents.
    var category: FormatCategory { FormatCatalog.format(self)?.category ?? .document }
}

/// A pill in a category's tint and ink (ux §3.5), the size the Settings lists use.
struct Pill: View {
    let text: String
    let category: FormatCategory
    var body: some View {
        let colors = SCColor.colors(for: category)
        Text(text).scFont(SCFont.pill)
            .foregroundStyle(Color(colors.inkToken)).padding(.horizontal, 8).frame(height: SCMetrics.Card.sourcePillHeight)
            .background(Capsule().fill(Color(colors.tintToken)))
    }
}

/// A white card holding rows separated by hairlines.
struct CardList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: SCMetrics.Card.radius).fill(Color.scCard))
            .overlay(RoundedRectangle(cornerRadius: SCMetrics.Card.radius).strokeBorder(Color.scHairline, lineWidth: 1))
    }
}

/// A label on the left, its control on the right (General, Quick Actions, About).
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scFont(SCFont.body).foregroundStyle(Color.scLabel)
                if let detail { Text(detail).scFont(SCFont.meta).foregroundStyle(Color.scSecondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16).padding(.vertical, SCMetrics.OptionsSheet.rowPadding + 1)
    }
}

/// The hairline between rows.
struct RowDivider: View {
    var body: some View { Rectangle().fill(Color.scHairline).frame(height: 1).padding(.leading, 16) }
}

/// The small grey line under a pane's title or list.
struct PaneNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).scFont(SCFont.body).foregroundStyle(Color.scSecondary).fixedSize(horizontal: false, vertical: true)
    }
}
