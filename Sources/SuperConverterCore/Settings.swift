import Foundation

// Every user setting, one place, grouped by Settings pane (ux §5.11). Settings never leave the Mac. State private to one
// module (window frame, view state) is declared in that module with the module as prefix:
// `Key<Bool>("windowKit.sidebar", default: true)`.

/// Grid or list (ux §5.8, ⌘1 / ⌘2).
public enum ViewMode: String, Codable, CaseIterable, Sendable { case grid, list }

public extension Defaults.Keys {
    // MARK: General (ux §5.11)

    /// Save to: next to the originals, Downloads, or a folder.
    static let outputPlace = Key<OutputPlace>("general.outputPlace", default: .nextToOriginal)
    /// When a file with that name exists.
    static let collisionPolicy = Key<CollisionPolicy>("general.collisionPolicy", default: .addNumber)
    /// "Use JPG for HEIC files from now on" (ux §5.4); the per-format choices are `target(for:)`.
    static let rememberFormatChoices = Key<Bool>("general.rememberFormatChoices", default: true)
    static let showInMenuBar = Key<Bool>("general.showInMenuBar", default: true)
    /// "Convert as soon as files are dropped on the menu bar".
    static let convertOnMenuBarDrop = Key<Bool>("general.convertOnMenuBarDrop", default: false)
    static let notifyWhenDone = Key<Bool>("general.notifyWhenDone", default: true)
    static let playSound = Key<Bool>("general.playSound", default: false)
    static let checkForUpdates = Key<Bool>("general.checkForUpdates", default: true)
    static let viewMode = Key<ViewMode>("window.viewMode", default: .grid)

    // MARK: Quick Actions (ux §5.10): the first three are on at first launch

    static let quickActionConvertToJPG = Key<Bool>("quickActions.jpg", default: true)
    static let quickActionConvertToPNG = Key<Bool>("quickActions.png", default: true)
    static let quickActionConvertToPDF = Key<Bool>("quickActions.pdf", default: true)
    static let quickActionConvertToMP4 = Key<Bool>("quickActions.mp4", default: false)
    static let quickActionConvertToMP3 = Key<Bool>("quickActions.mp3", default: false)

    // MARK: Per-format keys

    /// The target the person last chose for a source format (ux §6.1: the last choice wins).
    static func target(for source: FormatID) -> Key<FormatID?> { Key<FormatID?>("target.\(source.rawValue)", default: nil) }

    /// Options saved with "Use these settings for every …" for a target format (ux §5.5).
    static func savedOptions(for target: FormatID) -> Key<OptionValues?> { Key<OptionValues?>("options.\(target.rawValue)", default: nil) }

    /// A helper's location when the person set one (Settings › Helpers; nil = look in the known places).
    static func helperPath(_ helper: HelperID) -> Key<URL?> { Key<URL?>("helpers.path.\(helper.rawValue)", default: nil) }
}
