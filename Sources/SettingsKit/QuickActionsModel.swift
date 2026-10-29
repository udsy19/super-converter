import Combine
import Foundation
import SuperConverterCore

/// The Quick Actions pane's state (ux §5.10–§5.11): every one-step action with its switch as macOS has it, read through
/// `Services.menuBar` (MenuBarKit owns the actions) when the pane appears and whenever the app comes back to the front,
/// since System Settings › Extensions switches the same thing.
@MainActor
final class QuickActionsModel: ObservableObject {
    @Published private(set) var switches: [QuickActionSwitch] = []
    /// One line when the last switch didn't take (ux §7.2: one line, one fix).
    @Published private(set) var problem: String?

    private let menuBar: () -> MenuBarPresenting?

    init(menuBar: @escaping () -> MenuBarPresenting?) { self.menuBar = menuBar }

    /// Reads every switch from macOS again.
    func refresh() async {
        switches = await menuBar()?.quickActionSwitches() ?? []
    }

    /// True when macOS doesn't list some of the extensions (a build that isn't in an app bundle, or one not opened yet).
    var hasUnlisted: Bool { switches.contains { $0.isOn == nil } }

    /// Switches one action, showing the change at once and then whatever macOS has afterwards.
    func set(_ target: FormatID, on: Bool) async {
        guard let index = switches.firstIndex(where: { $0.target == target }) else { return }
        let title = switches[index].title
        switches[index].isOn = on
        problem = nil
        let after = await menuBar()?.setQuickAction(target, on: on)
        guard let current = switches.firstIndex(where: { $0.target == target }) else { return }
        if let after { switches[current] = after } else { switches[current].isOn = nil }
        if switches[current].isOn != on {
            problem = "macOS didn’t switch \(Strings.quoted(title)) \(on ? "on" : "off"). Try it in System Settings › Extensions."
        }
    }
}
