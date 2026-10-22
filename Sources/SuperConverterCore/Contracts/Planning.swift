import Foundation

/// A request to convert one file.
public struct ConversionRequest: Hashable, Sendable {
    public var source: URL
    public var sourceFormat: FormatID
    public var target: FormatID
    public var options: OptionValues
    public var look: DocumentLook?
    /// Overrides the matrix's `prefer` ("Make it look like the original" after a built-in run).
    public var preferHelper: Bool?

    public init(source: URL, sourceFormat: FormatID, target: FormatID, options: OptionValues = OptionValues(),
                look: DocumentLook? = nil, preferHelper: Bool? = nil) {
        self.source = source; self.sourceFormat = sourceFormat; self.target = target
        self.options = options; self.look = look; self.preferHelper = preferHelper
    }
}

/// How a pair will run on this Mac (ARCHITECTURE §5).
public enum RouteChoice: Hashable, Sendable {
    case builtin(steps: [Step])
    /// Runs through helpers; `missing` are the ones not installed (the card shows Install or Get…).
    case helper(steps: [Step], helpers: [HelperID], missing: [HelperID])
    case unavailable(reason: UnavailableReason)

    public var steps: [Step] {
        switch self {
        case .builtin(let s), .helper(let s, _, _): s
        case .unavailable: []
        }
    }
}

public enum UnavailableReason: Hashable, Sendable {
    /// The pair is not in the matrix, or deliberately not offered; carries the matrix's note.
    case notOffered(String)
    /// An engine on every route cannot run here (older macOS), with the reason.
    case engineUnavailable(EngineID, String)
}

public struct ConversionPlan: Hashable, Sendable {
    public var request: ConversionRequest
    public var choice: RouteChoice
    /// The route's rank and option profile, for the options sheet.
    public var optionProfile: String
    /// A helper that would do better when the built-in route runs ("Make it look like the original — Install LibreOffice").
    public var betterWithHelper: HelperID?
    /// The other looks available for this pair.
    public var availableLooks: [DocumentLook]

    public init(request: ConversionRequest, choice: RouteChoice, optionProfile: String, betterWithHelper: HelperID? = nil,
                availableLooks: [DocumentLook] = []) {
        self.request = request; self.choice = choice; self.optionProfile = optionProfile
        self.betterWithHelper = betterWithHelper; self.availableLooks = availableLooks
    }
}

/// ConvertKit's planner: follows the matrix's routes, `prefer`, engine availability and helper status.
@MainActor
public protocol Planning: AnyObject {
    func plan(for request: ConversionRequest) -> ConversionPlan
    /// Targets offered for a source, each with how it would run (the picker shows a ⬇ for helper routes).
    func targets(for source: FormatID) -> [(format: FormatID, choice: RouteChoice)]
}
