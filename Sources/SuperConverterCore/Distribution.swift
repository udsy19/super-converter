import Foundation

/// Which edition this build is (docs/app-store/architecture.md). `swift build -Xswiftc -DAPP_STORE` (scripts/build-app.sh
/// `DISTRIBUTION=appstore`) makes the Mac App Store edition: App Sandbox, no updater, no outside helpers, no Apple Events.
/// Without the flag the build is the direct-download edition, unchanged.
public enum Distribution {
    #if APP_STORE
    public static let isAppStore = true
    #else
    public static let isAppStore = false
    #endif

    /// The direct-download edition's bundle id and preferences domain ("Import Settings from the Direct Download…").
    public static let directBundleID = "com.udsy.superconverter"
    /// Where the direct-download edition is offered (the Store edition points people there for helper-run formats).
    public static let directDownloadPage = URL(string: "https://udsy19.github.io/super-converter/")!

    /// Why a helper-run conversion is missing from the Store edition (Settings › Helpers, the card's notice).
    public static let helpersUnavailable = "The Mac App Store edition converts with what is built in. Conversions that need LibreOffice, calibre, Pandoc, Tectonic, Ghostscript, DjVuLibre, ODA, LibreDWG, a GPL FFmpeg, RAR, sfArk or Pages, Numbers, Keynote and Microsoft Office are in the direct-download edition, because the App Store doesn't let an app run or install other programs or control other apps."
}

/// Store edition: the folders the person chose (output folders, folders added to the window, folders granted for a Quick
/// Action), kept as app-scoped security-scoped bookmarks so the App Sandbox lets the app back in after a relaunch. In the
/// direct edition every call does nothing: it is not sandboxed.
public enum FolderAccess {
    static let bookmarks = Defaults.Key<[Data]>("store.folderBookmarks", default: [])
    /// The most folders remembered; the oldest go first.
    static let limit = 64
    nonisolated(unsafe) private static var accessing: [String: URL] = [:]
    private static let lock = NSLock()

    /// Keeps `folder` reachable after a relaunch and starts using it now.
    public static func remember(_ folder: URL) {
        guard Distribution.isAppStore,
              let data = try? folder.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        let path = folder.standardizedFileURL.path
        var kept = Defaults[bookmarks].filter { resolve($0)?.standardizedFileURL.path != path }
        kept.append(data)
        Defaults[bookmarks] = Array(kept.suffix(limit))
        start(folder)
    }

    /// Launch: resolves every remembered folder and starts using it (stale bookmarks are renewed, dead ones dropped).
    public static func restore() {
        guard Distribution.isAppStore else { return }
        var kept: [Data] = []
        for data in Defaults[bookmarks] {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
            else { continue }
            start(url)
            kept.append(stale ? ((try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data) : data)
        }
        Defaults[bookmarks] = kept
    }

    /// True when every one of `files` can be read now (always true in the direct edition).
    public static func canRead(_ files: [URL]) -> Bool {
        files.allSatisfy { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private static func resolve(_ data: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private static func start(_ url: URL) {
        let path = url.standardizedFileURL.path
        lock.withLock {
            guard accessing[path] == nil, url.startAccessingSecurityScopedResource() else { return }
            accessing[path] = url
        }
    }
}

/// Store edition, "Import Settings from the Direct Download…": copies the direct edition's preferences (formats chosen,
/// saved options, Save To, switches) into this edition's. Nothing of the direct edition is moved or changed; keys that
/// only mean something there (helper locations, the updater, window frames, open panels) are left out.
public enum DirectEditionImport {
    /// `~/Library/Preferences/com.udsy.superconverter.plist`, where the open panel starts.
    public static var preferencesFile: URL {
        // The real home folder (in the sandbox NSHomeDirectory() is the container's).
        let home = URL(fileURLWithPath: getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory(), isDirectory: true)
        return home.appendingPathComponent("Library/Preferences/\(Distribution.directBundleID).plist")
    }

    static func isImported(_ key: String) -> Bool {
        let prefixes = ["general.", "target.", "options.", "window.viewMode", "menuBarKit.", "windowKit."]
        let excluded = ["general.checkForUpdates", "menuBarKit.quickActionsElected"]
        return prefixes.contains { key.hasPrefix($0) } && !excluded.contains(key) && !key.hasPrefix("helpers.")
    }

    /// Copies the importable keys of the property list at `file` into `defaults`; returns how many were copied.
    @discardableResult
    public static func importPreferences(from file: URL, into defaults: UserDefaults = Defaults.store) throws -> Int {
        let data = try Data(contentsOf: file)
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        var copied = 0
        for (key, value) in values where isImported(key) {
            defaults.set(value, forKey: key)
            Defaults.changes.send(key)
            copied += 1
        }
        return copied
    }
}
