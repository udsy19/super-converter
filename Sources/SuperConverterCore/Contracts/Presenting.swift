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
    /// The one-step Finder Quick Actions (ux §5.10) as macOS has them switched now, in menu order. The switch is the
    /// person's, per user, and System Settings › Extensions can change it too, so this asks macOS every time.
    func quickActionSwitches() async -> [QuickActionSwitch]
    /// Switches the Quick Action that converts to `target` on or off, then answers what macOS has afterwards.
    func setQuickAction(_ target: FormatID, on: Bool) async -> QuickActionSwitch?
}

/// One row of Settings › Quick Actions (ux §5.11): a one-step action, the files it shows for, and its switch.
public struct QuickActionSwitch: Hashable, Sendable {
    public var target: FormatID
    /// "Convert to JPG".
    public var title: String
    /// Which files it shows for: "Images".
    public var takes: String
    /// On or off as macOS has it; nil when macOS doesn't list the extension (a build that isn't in an app bundle).
    public var isOn: Bool?

    public init(target: FormatID, title: String, takes: String, isOn: Bool?) {
        self.target = target; self.title = title; self.takes = takes; self.isOn = isOn
    }
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
