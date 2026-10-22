import Foundation

/// The intermediate models (Models/): the hub of the hub-and-spoke design. A step reads or writes one of these, or a file.
public enum ModelKind: String, CaseIterable, Codable, Sendable {
    case imageAsset = "ImageAsset", vectorDocument = "VectorDocument", docModel = "DocModel"
    case layoutDocument = "LayoutDocument", workbook = "Workbook", deck = "Deck", publication = "Publication"
    case archiveTree = "ArchiveTree", mediaPlan = "MediaPlan", fontModel = "FontModel", cadDrawing = "CADDrawing"
}

/// One end of a step: a file in a format, or an in-memory model.
public enum StepEndpoint: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    case format(FormatID)
    case model(ModelKind)

    public init(stringLiteral value: String) { self = .format(FormatID(value)) }

    public static let imageAsset = StepEndpoint.model(.imageAsset)
    public static let vectorDocument = StepEndpoint.model(.vectorDocument)
    public static let docModel = StepEndpoint.model(.docModel)
    public static let layoutDocument = StepEndpoint.model(.layoutDocument)
    public static let workbook = StepEndpoint.model(.workbook)
    public static let deck = StepEndpoint.model(.deck)
    public static let publication = StepEndpoint.model(.publication)
    public static let archiveTree = StepEndpoint.model(.archiveTree)
    public static let mediaPlan = StepEndpoint.model(.mediaPlan)
    public static let fontModel = StepEndpoint.model(.fontModel)
    public static let cadDrawing = StepEndpoint.model(.cadDrawing)

    /// "docx" for a file, "@DocModel" for a model: the notation of `format-matrix.json`.
    public var description: String {
        switch self {
        case .format(let f): f.rawValue
        case .model(let m): "@" + m.rawValue
        }
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        if text.hasPrefix("@"), let model = ModelKind(rawValue: String(text.dropFirst())) {
            self = .model(model)
        } else {
            self = .format(FormatID(text))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public var isModel: Bool { if case .model = self { true } else { false } }
}

/// One conversion step: `engine` turns `from` into `to`. A route is a list of these; the planner never parses prose.
public struct Step: Hashable, Codable, Sendable, CustomStringConvertible {
    public let engine: EngineID
    public let from: StepEndpoint
    public let to: StepEndpoint

    public init(_ engine: EngineID, _ from: StepEndpoint, _ to: StepEndpoint) {
        self.engine = engine; self.from = from; self.to = to
    }

    public var description: String { "\(engine.rawValue): \(from) → \(to)" }
}

/// What a person can run without installing anything (formats §6.0 totals).
public enum RouteNeed: String, Codable, Sendable {
    /// Runs with nothing installed.
    case builtin
    /// Runs built in and switches to the helper when it is present (original office layout).
    case optional
    /// Needs a helper.
    case required
    /// Listed by CloudConvert but deliberately not offered (formats §7).
    case notOffered
}

/// Which path runs when both exist and the helper is installed (formats §6).
public enum RoutePreference: String, Codable, Sendable { case builtin, helper }

/// Work order (formats §7): P1 ships first. It does not limit what ships.
public enum Rank: String, Codable, Comparable, Sendable {
    case p1, p2, p3
    public static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }
}

/// Where a pair comes from (formats intro): CloudConvert parity, a pair the hub gives for free, or one CloudConvert lists
/// but does not convert.
public enum PairOrigin: String, Codable, Sendable { case cloudconvert, added, bonus }

/// A second way to run a pair that the person picks on the card (documents: Look "LaTeX").
public struct RouteAlternate: Hashable, Codable, Sendable {
    public enum Look: String, Codable, Sendable { case latex }
    public enum Via: String, Codable, Sendable { case builtin, helper }

    public let look: Look
    public let via: Via
    public let steps: [Step]

    public init(_ look: Look, via: Via, steps: [Step]) { self.look = look; self.via = via; self.steps = steps }
}

/// How one (input, output) pair runs: the built-in chain, the helper chain, or both.
public struct Route: Hashable, Codable, Sendable {
    public let from: FormatID
    public let to: FormatID
    public let origin: PairOrigin
    public let need: RouteNeed
    /// The path that needs nothing installed, if there is one.
    public let builtin: [Step]?
    /// The path through helpers, if there is one.
    public let helper: [Step]?
    /// The helpers `helper` needs (any one of the DWG pair, both of an iWork + LibreOffice chain).
    public let helpers: [HelperID]
    public let prefer: RoutePreference
    public let alternates: [RouteAlternate]
    /// The option profile (formats §5), e.g. "O-IMG+Q+DPI"; "O-…" ids resolve through `OptionProfiles`.
    public let options: String
    public let rank: Rank
    public let note: String

    public init(_ from: FormatID, _ to: FormatID, _ origin: PairOrigin, _ need: RouteNeed, builtin: [Step]? = nil,
                helper: [Step]? = nil, helpers: [HelperID] = [], prefer: RoutePreference = .builtin,
                alternates: [RouteAlternate] = [], options: String, _ rank: Rank, note: String = "") {
        self.from = from; self.to = to; self.origin = origin; self.need = need; self.builtin = builtin
        self.helper = helper; self.helpers = helpers; self.prefer = builtin == nil ? .helper : prefer
        self.alternates = alternates; self.options = options; self.rank = rank; self.note = note
    }

    public var isOffered: Bool { need != .notOffered }

    /// Every engine any of this route's chains uses.
    public var engines: Set<EngineID> {
        Set((builtin ?? []).map(\.engine) + (helper ?? []).map(\.engine) + alternates.flatMap { $0.steps.map(\.engine) })
    }
}

/// The matrix (formats §6): every offered pair with its routes. Built from the generated tables.
public enum FormatMatrix {
    public static let routes: [Route] = GeneratedMatrix.all

    private static let index: [FormatID: [FormatID: Route]] = {
        var table: [FormatID: [FormatID: Route]] = [:]
        for route in routes { table[route.from, default: [:]][route.to] = route }
        return table
    }()

    public static func route(from: FormatID, to: FormatID) -> Route? { index[from]?[to] }

    /// Every pair listed for `from`, offered or not, in the matrix's order.
    public static func routes(from: FormatID) -> [Route] { routes.filter { $0.from == from } }

    /// The targets offered for a source format.
    public static func targets(for from: FormatID) -> [FormatID] {
        (index[from] ?? [:]).values.filter(\.isOffered).map(\.to).sorted()
    }

    /// Pairs the app offers (everything except the deliberately not offered).
    public static var offered: [Route] { routes.filter(\.isOffered) }

    /// Why a pair is not offered ("GIF pictures have no sound"), for the picker's search (ux §7.2).
    public static func notOfferedReason(from: FormatID, to: FormatID) -> String? {
        guard let route = route(from: from, to: to), !route.isOffered else { return nil }
        return route.note
    }
}
