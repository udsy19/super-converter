import Foundation
import SuperConverterCore

/// ConvertKit's planner (formats §6, ARCHITECTURE §6): follows the routes the matrix lists, never parses prose. A route is
/// a built-in chain, a helper chain or both, plus alternates (the LaTeX look). Which one runs depends on the matrix's
/// `prefer`, the look chosen on the card, which engines can run here, and which helpers are ready.
///
/// Engine availability is computed once (at install) and again on `refresh()` (helper changes), ARCHITECTURE §6.
@MainActor
public final class Planner: Planning {
    private let registry: ConverterRegistry
    private let helperReady: (HelperID) -> Bool
    private var availability: [EngineID: EngineAvailability] = [:]

    public init(registry: ConverterRegistry, helperReady: @escaping (HelperID) -> Bool) {
        self.registry = registry
        self.helperReady = helperReady
        refresh()
    }

    /// Asks every registered converter whether it can run here and now.
    public func refresh() {
        availability = Dictionary(registry.converters.map { ($0.id, $0.availability()) }, uniquingKeysWith: { _, last in last })
    }

    // MARK: Planning

    public func plan(for request: ConversionRequest) -> ConversionPlan {
        guard let route = route(from: request.sourceFormat, to: request.target) else {
            let reason = Strings.problem(.unsupportedPair(from: request.sourceFormat, to: request.target)).message
            return ConversionPlan(request: request, choice: .unavailable(reason: .notOffered(reason)), optionProfile: "")
        }
        guard route.isOffered else {
            return ConversionPlan(request: request, choice: .unavailable(reason: .notOffered(route.note)), optionProfile: route.options)
        }
        let picked = choose(route, look: request.look, preferHelper: request.preferHelper)
        return ConversionPlan(request: request, choice: picked.choice, optionProfile: route.options,
                              betterWithHelper: picked.betterWithHelper, availableLooks: Self.looks(of: route))
    }

    public func targets(for source: FormatID) -> [(format: FormatID, choice: RouteChoice)] {
        var routes = FormatMatrix.routes(from: source).filter(\.isOffered)
        if routes.isEmpty {
            // JPEG is JPG: use the first member of the family the matrix knows.
            routes = Self.family(of: source).lazy.map { FormatMatrix.routes(from: $0).filter(\.isOffered) }.first { !$0.isEmpty } ?? []
        }
        return routes.map { ($0.to, choose($0, look: nil, preferHelper: nil).choice) }.sorted { $0.format < $1.format }
    }

    // MARK: Route lookup

    private static func family(of id: FormatID) -> [FormatID] {
        guard let canonical = FormatCatalog.format(id)?.family else { return [id] }
        return FormatCatalog.all.filter { $0.family == canonical }.map(\.id)
    }

    /// The route for the pair; when the exact ids have none, a member of the same family does (JPEG for JPG).
    func route(from: FormatID, to: FormatID) -> Route? {
        if let exact = FormatMatrix.route(from: from, to: to) { return exact }
        for source in Self.family(of: from) {
            for target in Self.family(of: to) {
                if let route = FormatMatrix.route(from: source, to: target) { return route }
            }
        }
        return nil
    }

    /// The looks a card can offer for this pair: only pairs with a LaTeX alternate have a choice (formats §5, O-DOC-PDF).
    static func looks(of route: Route) -> [DocumentLook] {
        guard route.alternates.contains(where: { $0.look == .latex }) else { return [] }
        var looks: [DocumentLook] = []
        if route.helper != nil { looks.append(.original) }
        if route.builtin != nil { looks.append(.asWritten) }
        looks.append(.latex)
        return looks
    }

    // MARK: Choosing

    private enum Chain {
        case ready
        case needsHelpers([HelperID])
        case blocked(EngineID, String)
    }

    private static let missingEngine = "This conversion isn’t available in this version"

    private func evaluate(_ steps: [Step]) -> Chain {
        var missing: [HelperID] = []
        for step in steps {
            guard let converter = registry.converter(for: step.engine), converter.handles(step) else {
                return .blocked(step.engine, Self.missingEngine)
            }
            switch availability[step.engine] ?? converter.availability() {
            case .available: break
            case .needsHelper(let helper): if !helperReady(helper), !missing.contains(helper) { missing.append(helper) }
            case .unavailable(let reason): return .blocked(step.engine, reason)
            }
            let helpers = step.engine.helpers
            if let first = helpers.first, !helpers.contains(where: helperReady), !missing.contains(first) { missing.append(first) }
        }
        return missing.isEmpty ? .ready : .needsHelpers(missing)
    }

    func choose(_ route: Route, look: DocumentLook?, preferHelper: Bool?) -> (choice: RouteChoice, betterWithHelper: HelperID?) {
        var builtin = route.builtin, helper = route.helper
        if look == .latex {
            let alternates = route.alternates.filter { $0.look == .latex }
            builtin = alternates.first { $0.via == .builtin }?.steps
            helper = alternates.first { $0.via == .helper }?.steps
        }
        // The person's explicit choice wins; then the look; then the matrix's preference.
        let wantsHelper = preferHelper ?? {
            switch look {
            case .original: true
            case .asWritten, .latex: false
            case nil: route.prefer == .helper
            }
        }()

        let builtinState = builtin.map(evaluate)
        let helperState = helper.map(evaluate)
        let helperList = route.helpers.isEmpty ? (helper ?? []).flatMap { $0.engine.helpers.prefix(1) } : route.helpers

        if wantsHelper, let helper, case .ready? = helperState {
            return (.helper(steps: helper, helpers: helperList, missing: []), nil)
        }
        if let builtin, case .ready? = builtinState {
            var better: HelperID?
            if look == nil || look == .original, route.prefer == .helper, case .needsHelpers(let missing)? = helperState { better = missing.first }
            return (.builtin(steps: builtin), better)
        }
        if let helper, case .needsHelpers(let missing)? = helperState {
            return (.helper(steps: helper, helpers: helperList, missing: missing), nil)
        }
        if let helper, case .ready? = helperState {
            return (.helper(steps: helper, helpers: helperList, missing: []), nil)
        }
        for state in [builtinState, helperState] {
            if case .blocked(let engine, let reason)? = state { return (.unavailable(reason: .engineUnavailable(engine, reason)), nil) }
        }
        return (.unavailable(reason: .notOffered(route.note)), nil)
    }
}
