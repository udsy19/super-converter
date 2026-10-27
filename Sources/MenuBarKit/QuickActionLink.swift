import AppKit
import SuperConverterCore

/// The `superconverter://` link a Quick Action or Service hands to the app (ARCHITECTURE §3): `open` adds the files to the
/// window, `convert` runs them in the background to `to` (or each file's default target) and posts a notification.
///
///     superconverter://convert?file=/Users/me/a.heic&file=/Users/me/b.heic&to=jpg
///     superconverter://open?file=/Users/me/a.heic
public struct QuickActionLink: Equatable, Sendable {
    public enum Verb: String, Sendable { case open, convert }

    public var verb: Verb
    public var files: [URL]
    public var target: FormatID?

    public init(_ verb: Verb, files: [URL], target: FormatID? = nil) {
        self.verb = verb; self.files = files; self.target = target
    }

    /// What `action` does with `files`.
    public init(_ action: QuickAction, files: [URL]) {
        self.init(action.target == nil ? .open : .convert, files: files, target: action.target)
    }

    public init?(_ url: URL) {
        guard url.scheme == SuperConverterPaths.urlScheme, let host = url.host, let verb = Verb(rawValue: host),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let files = items.filter { $0.name == "file" }.compactMap { $0.value }.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty else { return nil }
        self.init(verb, files: files, target: items.first { $0.name == "to" }?.value.map { FormatID($0) })
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = SuperConverterPaths.urlScheme
        parts.host = verb.rawValue
        parts.queryItems = files.map { URLQueryItem(name: "file", value: $0.path) } + (target.map { [URLQueryItem(name: "to", value: $0.rawValue)] } ?? [])
        return parts.url!
    }
}

/// Opens a URL; the Quick Action extension and the Services provider use the system one, tests a fake.
public protocol URLOpening {
    func open(_ url: URL)
}

public struct SystemURLOpener: URLOpening {
    public init() {}
    public func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

public extension QuickAction {
    /// What the extension does: hands the selected files to the app as a link. False when there was nothing to hand over.
    @discardableResult
    func handOff(_ files: [URL], using opener: URLOpening) -> Bool {
        guard !files.isEmpty else { return false }
        opener.open(QuickActionLink(self, files: files).url)
        return true
    }
}
