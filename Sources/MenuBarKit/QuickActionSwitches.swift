import Foundation
import SuperConverterCore

/// The Finder Quick Actions' on/off switches (ux §5.10–§5.11). macOS keeps them per user, as an "election" on each extension:
/// `pluginkit -e use|ignore -i <id>` sets it and `pluginkit -m -i <id>` lists the extension with the election as the first
/// character of its line (`+` use, `-` ignore, a space when nobody has chosen). System Settings › Extensions sets the same
/// election, so nothing here is remembered: every answer is read from pluginkit, which runs through `Services.tools` like
/// every other process (ARCHITECTURE §4).
struct QuickActionSwitches: Sendable {
    let tools: ToolRunning

    /// Through HelperKit's runner; nil before HelperKit is installed.
    @MainActor static var current: QuickActionSwitches? { Services.tools.map(QuickActionSwitches.init) }

    enum Election: Equatable, Sendable { case use, ignore, undecided }

    /// pluginkit writes nothing of its own; it still gets a work folder like every run.
    private static let workFolder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperConverter-pluginkit", isDirectory: true)

    private func pluginkit(_ arguments: [String]) async throws -> HelperRunResult {
        try await tools.run(ToolInvocation(tool: .pluginkit, arguments: arguments, workFolder: Self.workFolder, timeLimit: 15))
    }

    /// The action's election as macOS has it now; nil when macOS doesn't list the extension (or pluginkit failed).
    func election(of action: QuickAction) async -> Election? {
        guard let result = try? await pluginkit(["-m", "-i", action.bundleID]), result.exitCode == 0 else { return nil }
        return Self.election(of: action.bundleID, in: result.standardOutput)
    }

    /// Reads `id`'s line from `pluginkit -m` output: "+    com.udsy.superconverter.quickactions.ConvertToJPG(1.0.0)".
    static func election(of id: String, in listing: String) -> Election? {
        for line in listing.split(separator: "\n") {
            let entry = line.dropFirst().drop { $0 == " " || $0 == "\t" }
            guard entry.hasPrefix(id + "(") || entry == id else { continue }
            switch line.first {
            case "+": return .use
            case "-": return .ignore
            default: return .undecided
            }
        }
        return nil
    }

    /// Switches the action on (`use`) or off (`ignore`) for this user.
    func elect(_ action: QuickAction, on: Bool) async throws {
        let result = try await pluginkit(["-e", on ? "use" : "ignore", "-i", action.bundleID])
        guard result.exitCode == 0 else { throw ConversionError.failed("macOS didn’t switch “\(action.title)” \(on ? "on" : "off").") }
    }

    /// The Settings row for a one-step action, with its switch as macOS has it.
    func row(_ action: QuickAction) async -> QuickActionSwitch? {
        guard let target = action.target else { return nil }
        let election = await election(of: action)
        return QuickActionSwitch(target: target, title: action.title, takes: action.takes, isOn: election.map { $0 == .use })
    }

    /// Every one-step action's row, in menu order.
    func rows() async -> [QuickActionSwitch] {
        var rows: [QuickActionSwitch] = []
        for action in QuickAction.allCases { if let row = await row(action) { rows.append(row) } }
        return rows
    }

    /// First launch (ux §5.10): JPG, PNG and PDF on, MP4 and MP3 off, leaving alone any the person already chose in
    /// System Settings. Done once, when macOS lists every extension (otherwise tried again next launch). True when done.
    @discardableResult
    func electAtFirstLaunch() async -> Bool {
        guard !Defaults[.quickActionsElected] else { return true }
        var elections: [(QuickAction, Election)] = []
        for action in QuickAction.allCases where action.startsOn != nil {
            guard let election = await election(of: action) else { return false }
            elections.append((action, election))
        }
        for (action, election) in elections where election == .undecided {
            try? await elect(action, on: action.startsOn!)
        }
        Defaults[.quickActionsElected] = true
        return true
    }
}

extension Defaults.Keys {
    /// Set once the first-launch elections are made.
    static let quickActionsElected = Key<Bool>("menuBarKit.quickActionsElected", default: false)
}
