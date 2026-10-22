import Foundation

/// The main window (WindowKit, ux §4–§5.8).
@MainActor
public protocol WindowPresenting: AnyObject {
    /// Shows the window, creating it if needed.
    func show()
    /// Adds files (dropped, opened, from a Quick Action) with an optional preset target.
    func add(_ urls: [URL], target: FormatID?)
    var hasWork: Bool { get }
}

/// The menu-bar drop target and its panel (MenuBarKit, ux §5.9).
@MainActor
public protocol MenuBarPresenting: AnyObject {
    func install()
    func setVisible(_ visible: Bool)
    func showPanel(with urls: [URL])
}

/// The Settings window (SettingsKit, ux §5.11).
@MainActor
public protocol SettingsPresenting: AnyObject {
    func show(pane: SettingsPane?)
}

public enum SettingsPane: String, CaseIterable, Codable, Sendable {
    case general, formats, helpers, quickActions, about

    public var title: String {
        switch self {
        case .general: "General"
        case .formats: "Formats"
        case .helpers: "Helpers"
        case .quickActions: "Quick Actions"
        case .about: "About"
        }
    }
}
