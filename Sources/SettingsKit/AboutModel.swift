import Combine
import Foundation
import SuperConverterCore

/// One part of THIRD_PARTY_NOTICES.md, under its "## " heading.
struct NoticeSection: Identifiable, Equatable {
    let title: String
    let body: String
    var id: String { title }
}

enum Notices {
    /// Splits the notices into their "## " sections, dropping the generator's HTML comments. Text before the first heading
    /// becomes a section called "Overview" when it says anything.
    static func sections(_ text: String) -> [NoticeSection] {
        var sections: [NoticeSection] = []
        var title = "Overview"
        var lines: [String] = []
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { sections.append(NoticeSection(title: title, body: body)) }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("<!--") && line.hasSuffix("-->") { continue }
            if line.hasPrefix("## ") { flush(); title = String(line.dropFirst(3)) } else if !line.hasPrefix("# ") { lines.append(line) }
        }
        flush()
        return sections
    }

    static func load(from url: URL?) -> [NoticeSection] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return sections(text)
    }
}

/// The About pane's state: the update status from `Services.updates`, in words (ux §5.11).
@MainActor
final class AboutModel: ObservableObject {
    @Published private(set) var status: UpdateStatus
    private let updates: UpdateChecking?
    private var subscription: AnyCancellable?

    init(updates: UpdateChecking?) {
        self.updates = updates
        status = updates?.status ?? .disabled
        subscription = updates?.statusChanges.receive(on: DispatchQueue.main).sink { [weak self] in self?.status = $0 }
    }

    var canCheck: Bool {
        guard updates != nil else { return false }
        switch status {
        case .checking, .downloading: return false
        default: return true
        }
    }

    var readyVersion: String? { if case .readyToInstall(let version) = status { version } else { nil } }

    var statusText: String {
        switch status {
        case .idle: return ""
        case .checking: return "Checking…"
        case .upToDate(let date):
            let when = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
            return "\(Strings.appName) is up to date · checked \(when)"
        case .downloading(let version, let fraction): return "Downloading \(version)… \(Int((fraction * 100).rounded())) %"
        case .readyToInstall(let version): return "Version \(version) is ready. It installs when you quit, or now."
        case .failed(let message): return message
        case .disabled: return "Automatic updates are off"
        }
    }

    func checkNow() { updates?.checkNow() }
    func installNow() { updates?.installNow() }
}
