import Foundation

/// Where a step's input comes from and where its output goes: a model value in memory, or a file in the work folder.
public enum StepValue: Sendable {
    case file(URL)
    case image(ImageAsset)
    case vector(VectorDocument)
    case doc(DocModel)
    case layout(LayoutDocument)
    case workbook(Workbook)
    case deck(Deck)
    case publication(Publication)
    case archive(ArchiveTree)
    case media(MediaPlan)
    case font(FontModel)
    case cad(CADDrawing)

    /// The model kind this value holds; nil for a file.
    public var model: ModelKind? {
        switch self {
        case .file: nil
        case .image: .imageAsset
        case .vector: .vectorDocument
        case .doc: .docModel
        case .layout: .layoutDocument
        case .workbook: .workbook
        case .deck: .deck
        case .publication: .publication
        case .archive: .archiveTree
        case .media: .mediaPlan
        case .font: .fontModel
        case .cad: .cadDrawing
        }
    }
}

/// What a step produced, with everything it could not carry over.
public struct StepOutput: Sendable {
    public var value: StepValue
    public var lossNotes: [LossNote]
    public var warnings: [String]

    public init(_ value: StepValue, lossNotes: [LossNote] = [], warnings: [String] = []) {
        self.value = value; self.lossNotes = lossNotes; self.warnings = warnings
    }
}

/// Progress inside one step: a fraction and the unit the card shows ("Page 3 of 12", ux §7.1).
public struct StepProgress: Hashable, Sendable {
    public var fraction: Double?
    public var unit: String?
    public init(fraction: Double?, unit: String? = nil) { self.fraction = fraction; self.unit = unit }
}

/// Everything a step needs besides its input.
public struct StepContext: Sendable {
    /// The job's work folder: the only place a step writes (partial files are moved into place only when complete).
    public let workFolder: URL
    /// The file the person dropped.
    public let source: URL
    public let sourceFormat: FormatID
    public let targetFormat: FormatID
    public let options: OptionValues
    /// The look chosen on the card for documents (Original layout / As written / LaTeX); nil when not applicable.
    public let look: DocumentLook?
    /// Set when a step is the last of its route.
    public let isFinalStep: Bool
    public let report: @Sendable (StepProgress) -> Void
    /// Cooperative cancellation: engines check it between units of work.
    public let isCancelled: @Sendable () -> Bool

    public init(workFolder: URL, source: URL, sourceFormat: FormatID, targetFormat: FormatID, options: OptionValues = OptionValues(),
                look: DocumentLook? = nil, isFinalStep: Bool = false,
                report: @escaping @Sendable (StepProgress) -> Void = { _ in },
                isCancelled: @escaping @Sendable () -> Bool = { false }) {
        self.workFolder = workFolder; self.source = source; self.sourceFormat = sourceFormat; self.targetFormat = targetFormat
        self.options = options; self.look = look; self.isFinalStep = isFinalStep; self.report = report; self.isCancelled = isCancelled
    }
}

/// "Look: Original / As written / LaTeX" (formats §5, O-DOC-PDF).
public enum DocumentLook: String, Codable, CaseIterable, Sendable { case original, asWritten, latex }

/// Whether an engine can run here and now (ARCHITECTURE §6: computed once at launch and on helper changes).
public enum EngineAvailability: Hashable, Sendable {
    case available
    /// Needs this helper (not installed, or not usable).
    case needsHelper(HelperID)
    /// Not available on this macOS or this Mac, with the reason the card can show.
    case unavailable(String)
}

/// Which steps a converter handles: any file of the given formats or any file, or a model, at each end.
public struct StepPattern: Hashable, Sendable {
    public enum End: Hashable, Sendable {
        case anyFile
        case formats(Set<FormatID>)
        case model(ModelKind)

        func matches(_ endpoint: StepEndpoint) -> Bool {
            switch (self, endpoint) {
            case (.anyFile, .format): true
            case (.formats(let set), .format(let f)): set.contains(f)
            case (.model(let m), .model(let n)): m == n
            default: false
            }
        }
    }

    public let from: End
    public let to: End

    public init(from: End, to: End) { self.from = from; self.to = to }

    public func matches(_ step: Step) -> Bool { from.matches(step.from) && to.matches(step.to) }
}

/// An engine's adapter. It is data-driven (ARCHITECTURE §4): `id` is the engine id `format-matrix.json` uses, `handles`
/// the kinds of (from, to) it converts, `availability()` whether it can run here. The planner only follows routes the
/// matrix lists; the self-test fails if the matrix names an engine no converter registers, or a converter is registered
/// that no route uses.
public protocol Converter: Sendable {
    var id: EngineID { get }
    var handles: [StepPattern] { get }
    func availability() -> EngineAvailability
    func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput
}

public extension Converter {
    func handles(_ step: Step) -> Bool { step.engine == id && handles.contains { $0.matches(step) } }
}

/// The set of every engine's converters, registered by ConvertKit from each module's `install()`.
@MainActor
public protocol ConverterRegistry: AnyObject {
    var converters: [any Converter] { get }
    func register(_ converter: any Converter)
    func converter(for engine: EngineID) -> (any Converter)?
}

/// The default registry. It lives in Core so engines can register in any order at launch; ConvertKit's `install()` then
/// verifies the matrix against it (every engine a route names has a converter, every converter is used by a route).
@MainActor
public final class ConverterList: ConverterRegistry {
    public private(set) var converters: [any Converter] = []

    public init() {}

    public func register(_ converter: any Converter) {
        converters.removeAll { $0.id == converter.id }
        converters.append(converter)
    }

    public func converter(for engine: EngineID) -> (any Converter)? { converters.first { $0.id == engine } }
}
