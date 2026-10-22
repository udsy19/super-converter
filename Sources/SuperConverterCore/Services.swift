import Foundation

/// Late-bound registry: each module's `install()` assigns its implementations at launch, in the order the app target calls
/// them (ARCHITECTURE §9 "Launch sequence"). Modules reach each other only through these. Every slot has one owner; the
/// comment names it.
@MainActor
public enum Services {
    // ConvertKit. The registry exists from the start so engines can register in any order (launch step 2).
    public static var converters: ConverterRegistry = ConverterList()
    public static var planner: Planning!
    public static var queue: JobQueueing!
    public static var sniffer: FormatSniffing!
    public static var output: OutputPolicy!
    public static var thumbnails: Thumbnailing!

    // HelperKit
    public static var helpers: HelperManaging!

    // WindowKit
    public static var window: WindowPresenting!

    // MenuBarKit
    public static var menuBar: MenuBarPresenting!

    // SettingsKit
    public static var settings: SettingsPresenting!

    // The app target (the UpdateKit engine)
    public static var updates: UpdateChecking!
}
