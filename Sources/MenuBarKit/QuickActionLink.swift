import AppKit
import Security
import SuperConverterCore

/// The `superconverter://` link a Quick Action or Service hands to the app (ARCHITECTURE §3): `open` adds the files to the
/// window, `convert` runs them in the background to `to` (or each file's default target) and posts a notification. Only
/// links from the app's own extensions convert in the background (`LinkOrigin`).
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

/// Who opened a link. Any web page, mail or app can open a `superconverter://` link, so only the app's own Quick Action
/// extensions and its Services entries (both started by the person in Finder) convert without asking (ux §5.10). A link
/// from anywhere else only fills the window with its files and target and waits for the person to convert them (ux §6.6:
/// nothing is read, converted or written that the person didn't choose).
public enum LinkOrigin: Equatable, Sendable {
    /// One of this app's Quick Action extensions, or a Services entry.
    case thisApp
    case elsewhere

    /// The origin of the Apple Event that carried a link: `.thisApp` when its sender is running, intact, code from
    /// `plugIns` (the app's `Contents/PlugIns`, where scripts/build-app.sh puts the extensions).
    public static func of(_ event: NSAppleEventDescriptor?, plugIns: URL) -> LinkOrigin {
        guard let event else { return .elsewhere }
        if let token = event.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr))?.data, !token.isEmpty {
            return of(sender: [kSecGuestAttributeAudit: token], plugIns: plugIns)
        }
        if let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value, pid > 0 {
            return of(sender: [kSecGuestAttributePid: pid], plugIns: plugIns)
        }
        return .elsewhere
    }

    /// The origin of the running code that `sender` (Security's guest attributes: an audit token or a process id) names.
    static func of(sender: [CFString: Any], plugIns: URL) -> LinkOrigin {
        var code: SecCode?, staticCode: SecStaticCode?, path: CFURL?
        guard SecCodeCopyGuestWithAttributes(nil, sender as CFDictionary, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyPath(staticCode, [], &path) == errSecSuccess, let path = path as URL? else { return .elsewhere }
        let folder = Self.realPath(plugIns) + "/"
        return Self.realPath(path).hasPrefix(folder) ? .thisApp : .elsewhere
    }

    private static func realPath(_ url: URL) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(url.path, &buffer).map { String(cString: $0) } ?? url.standardizedFileURL.path
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
