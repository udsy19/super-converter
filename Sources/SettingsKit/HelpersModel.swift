import Foundation
import SuperConverterCore

/// What a helper unlocks, as the pills under its name (ux §5.11): the formats that only a helper can read or write, the
/// pairs it enables between formats that otherwise convert without it, and "Original layout" when it improves pairs that
/// already work. Derived from the matrix, so it never drifts from what the planner does.
enum HelperUnlocks {
    struct Item: Hashable { let text: String; let category: FormatCategory }

    private struct Index {
        /// Formats whose every offered pair from them needs a helper.
        var inputOnly: Set<FormatID> = []
        /// Formats whose every offered pair to them needs a helper.
        var outputOnly: Set<FormatID> = []
    }

    private static let index: Index = {
        var from: [FormatID: Bool] = [:], to: [FormatID: Bool] = [:]
        for route in FormatMatrix.offered {
            let required = route.need == .required
            from[route.from] = (from[route.from] ?? true) && required
            to[route.to] = (to[route.to] ?? true) && required
        }
        return Index(inputOnly: Set(from.filter(\.value).keys), outputOnly: Set(to.filter(\.value).keys))
    }()

    private static let order: [FormatID: Int] = Dictionary(uniqueKeysWithValues: FormatCatalog.all.enumerated().map { ($1.id, $0) })

    /// At most `limit` pills; the rest are counted in a final "+N".
    static func items(for helper: HelperID, limit: Int = 8) -> [Item] {
        let routes = FormatMatrix.offered.filter { $0.helpers.contains(helper) }
        var result: [Item] = []
        if routes.contains(where: { $0.need == .optional }) { result.append(Item(text: "Original layout", category: .document)) }
        let required = routes.filter { $0.need == .required }
        func sorted(_ ids: Set<FormatID>) -> [FormatID] { ids.sorted { (order[$0] ?? 0, $0) < (order[$1] ?? 0, $1) } }
        let inputs = Set(required.map(\.from).filter(index.inputOnly.contains))
        let outputs = Set(required.map(\.to).filter(index.outputOnly.contains))
        result += sorted(inputs).map { Item(text: $0.pill, category: $0.category) }
        result += sorted(outputs).map { Item(text: "\($0.pill) out", category: $0.category) }
        let pairs = required.filter { !index.inputOnly.contains($0.from) && !index.outputOnly.contains($0.to) }
            .sorted { (order[$0.from] ?? 0, order[$0.to] ?? 0) < (order[$1.from] ?? 0, order[$1.to] ?? 0) }
        result += pairs.map { Item(text: "\($0.from.pill) → \($0.to.pill)", category: $0.to.category) }
        guard result.count > limit else { return result }
        return Array(result.prefix(limit - 1)) + [Item(text: "+\(result.count - limit + 1)", category: .document)]
    }
}

/// The Helpers pane's state (ux §5.11): every helper's status from `HelperManaging`, install progress, and what each button
/// does. Opening a page and showing the Homebrew line are the only things it does besides calling the manager.
@MainActor
final class HelpersModel: ObservableObject {
    /// The helpers shown first (the mockup's list); the rest sit under "Further down".
    static let main: [HelperID] = [.libreoffice, .iwork, .calibre, .pandoc, .tectonic, .ghostscript, .oda]
    static let further: [HelperID] = HelperCatalog.all.map(\.id).filter { !main.contains($0) }

    enum Action: Equatable {
        case install, remove
        case get(label: String)
        case none
    }

    /// What an install is doing right now, for the row's right-hand side.
    enum Activity: Equatable {
        case downloading(fraction: Double)
        case verifying, unpacking
    }

    @Published private(set) var statuses: [HelperID: HelperStatus] = [:]
    @Published private(set) var activity: [HelperID: Activity] = [:]
    @Published private(set) var failures: [HelperID: String] = [:]
    @Published var notes: Set<HelperID> = []

    private let manager: HelperManaging
    private let open: (URL) -> Void
    private var watcher: Task<Void, Never>?

    init(manager: HelperManaging, open: @escaping (URL) -> Void) {
        self.manager = manager
        self.open = open
        refresh()
        watcher = Task { [weak self] in
            guard let changes = self?.manager.statusChanges else { return }
            for await helper in changes { self?.refresh(helper) }
        }
    }

    deinit { watcher?.cancel() }

    func refresh() { for info in HelperCatalog.all { statuses[info.id] = manager.status(of: info.id) } }
    private func refresh(_ helper: HelperID) { statuses[helper] = manager.status(of: helper) }

    func status(_ helper: HelperID) -> HelperStatus { statuses[helper] ?? .notInstalled }

    func isOneClick(_ helper: HelperID) -> Bool { if case .oneClick = HelperCatalog.info(helper).install { true } else { false } }

    func action(for helper: HelperID) -> Action {
        if activity[helper] != nil { return .none }
        switch status(helper) {
        case .installing: return .none
        case .installed: return isOneClick(helper) ? .remove : .none
        case .notInstalled, .unusable:
            switch HelperCatalog.info(helper).install {
            case .oneClick: return .install
            case .detectOnly: return .none
            default: return .get(label: helper == .iwork ? "Get Numbers…" : Strings.Helper.get)
            }
        }
    }

    /// The fraction to draw and its words ("Installing… 64 %"), nil when nothing is installing.
    func progress(for helper: HelperID) -> (fraction: Double?, text: String)? {
        switch activity[helper] {
        case .downloading(let fraction): return (fraction, "Installing… \(Int((fraction * 100).rounded())) %")
        case .verifying: return (nil, "Verifying…")
        case .unpacking: return (nil, "Unpacking…")
        case nil:
            if case .installing(let fraction) = status(helper) { return (fraction, "Installing… \(Int((fraction * 100).rounded())) %") }
            return nil
        }
    }

    /// The status word beside the name.
    func badge(for helper: HelperID) -> (text: String, isGood: Bool)? {
        switch status(helper) {
        case .installed: (isOneClick(helper) ? "Installed" : "Found", true)
        case .unusable: ("Can’t be used", false)
        default: nil
        }
    }

    /// "Version 25.8 · 1.0 GB · Mozilla Public License 2.0" or "Free · 160 MB download · GNU GPL 3".
    func detail(for helper: HelperID) -> String {
        let info = HelperCatalog.info(helper)
        switch status(helper) {
        case .installed(let version, _, let size):
            var parts: [String] = []
            if let version { parts.append("Version \(version)") }
            if let size { parts.append(Formatting.bytes(size)) }
            parts.append(info.licenceName)
            return parts.joined(separator: " · ")
        case .unusable(let reason):
            return reason
        default:
            switch info.install {
            case .appStore: return "Free from Apple · opens briefly to export, with your permission"
            case .detectOnly: return "Used when it is installed · \(info.licenceName)"
            case .oneClick: return "\(Strings.Helper.cost(helper))\(info.downloadMB == nil ? "" : " download") · \(info.licenceName)"
            case .vendorPage: return "Free from the vendor · \(info.licenceName)"
            case .homebrew(let formula): return "Free · brew install \(formula) · \(info.licenceName)"
            case .buildFromSource: return "Free · built from source · \(info.licenceName)"
            }
        }
    }

    /// The Homebrew line shown after "Get…".
    func note(for helper: HelperID) -> String? {
        guard notes.contains(helper), case .homebrew(let formula) = HelperCatalog.info(helper).install else { return nil }
        return "Install it with Homebrew: brew install \(formula). Then choose Look again."
    }

    // MARK: Actions

    /// Downloads and installs; returns the task so a caller can wait for the end.
    @discardableResult
    func install(_ helper: HelperID) -> Task<Void, Never> {
        failures[helper] = nil
        activity[helper] = .downloading(fraction: 0)
        return Task { [weak self] in
            guard let self else { return }
            for await step in self.manager.install(helper) {
                switch step {
                case .downloading(let fraction): self.activity[helper] = .downloading(fraction: fraction)
                case .verifying: self.activity[helper] = .verifying
                case .unpacking: self.activity[helper] = .unpacking
                case .finished(let status): self.statuses[helper] = status
                case .failed(let message): self.failures[helper] = message
                }
            }
            self.activity[helper] = nil
            self.refresh(helper)
        }
    }

    func remove(_ helper: HelperID) {
        failures[helper] = nil
        do { try manager.remove(helper) } catch { failures[helper] = error.localizedDescription }
        refresh(helper)
    }

    /// "Get…": the vendor's or store's page, or the Homebrew line.
    func get(_ helper: HelperID) {
        switch HelperCatalog.info(helper).install {
        case .vendorPage(let url), .appStore(let url), .buildFromSource(let url): open(url)
        case .homebrew: notes.formUnion([helper])
        case .oneClick, .detectOnly: break
        }
    }

    func lookAgain() {
        manager.lookAgain()
        refresh()
    }

    /// Where the person said a helper is (Settings › Helpers), or nil.
    func setLocation(_ url: URL?, for helper: HelperID) {
        Defaults[.helperPath(helper)] = url
        lookAgain()
    }
}
