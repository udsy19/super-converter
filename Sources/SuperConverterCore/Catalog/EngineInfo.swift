import Foundation

/// What kind of code an engine is (formats §3): decides licence handling and availability checks.
public enum EngineKind: String, Codable, Sendable {
    /// A system framework or macOS command; present on every supported Mac.
    case apple
    /// Code in this repository.
    case own
    /// Third-party code shipped inside the app (static library, or the LGPL executables and dylib).
    case bundled
    /// An optional program the person installs (formats §4), run only through HelperKit.
    case helper
}

/// The module that registers an engine's converter, and what kind of engine it is. `EngineID` itself is generated
/// (`Generated/GeneratedEngines.swift`): its raw values are the engine names formats §3 uses and `format-matrix.json` carries.
public struct EngineInfo: Hashable, Sendable {
    public let module: ModuleID
    public let kind: EngineKind
}
