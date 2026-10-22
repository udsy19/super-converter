import Foundation

/// Every module of the package (ARCHITECTURE §3). Engines register converters; feature modules talk through `Services`.
public enum ModuleID: String, CaseIterable, Codable, Sendable {
    // Engines
    case imageKit = "ImageKit", vectorKit = "VectorKit", xpsKit = "XPSKit", vectorizeKit = "VectorizeKit"
    case cadKit = "CADKit", docKit = "DocKit", typesetKit = "TypesetKit", mathKit = "MathKit"
    case layoutKit = "LayoutKit", renderKit = "RenderKit", officeKit = "OfficeKit", ebookKit = "EbookKit"
    case archiveKit = "ArchiveKit", mediaKit = "MediaKit", fontKit = "FontKit", helperKit = "HelperKit"
    case updateKit = "UpdateKit"
    // Feature modules
    case convertKit = "ConvertKit", windowKit = "WindowKit", menuBarKit = "MenuBarKit", settingsKit = "SettingsKit"

    public enum Role: Sendable { case engine, feature }

    public var role: Role {
        switch self {
        case .convertKit, .windowKit, .menuBarKit, .settingsKit: .feature
        default: .engine
        }
    }

    public var name: String { rawValue }
}

/// Which module may import which (ARCHITECTURE §4). Engines depend only on Core and their vendor libraries, except for
/// the documented engine-to-engine edges; feature modules depend on Core, and only ConvertKit imports engines. The
/// self-test reads every `import` under Sources/ and checks it against this table, and checks that it has no cycles.
public enum ModuleGraph {
    /// Engine-to-engine edges, importer → imported.
    public static let engineEdges: [ModuleID: Set<ModuleID>] = [
        .typesetKit: [.mathKit, .vectorKit],
        .docKit: [.layoutKit],
        .ebookKit: [.docKit, .typesetKit],
        .cadKit: [.vectorKit],
        .xpsKit: [.vectorKit],
        .imageKit: [.renderKit],
        .officeKit: [.typesetKit, .renderKit],
    ]

    /// The modules `module` may import besides `SuperConverterCore` and system or vendor modules.
    public static func allowedImports(of module: ModuleID) -> Set<ModuleID> {
        switch module {
        case .convertKit:
            Set(ModuleID.allCases.filter { $0.role == .engine })
        case .windowKit, .menuBarKit, .settingsKit:
            []
        default:
            engineEdges[module] ?? []
        }
    }

    /// True when the engine edges contain a cycle.
    public static var hasCycle: Bool {
        var state: [ModuleID: Int] = [:]   // 1 visiting, 2 done
        func visit(_ m: ModuleID) -> Bool {
            if state[m] == 2 { return false }
            if state[m] == 1 { return true }
            state[m] = 1
            for next in engineEdges[m] ?? [] where visit(next) { return true }
            state[m] = 2
            return false
        }
        return ModuleID.allCases.contains(where: visit)
    }
}
