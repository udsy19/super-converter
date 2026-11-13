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

    /// The direct-download edition's bundle id and preferences domain ("Import Settings from Another Copy…").
    public static let directBundleID = "com.udsy.superconverter"
    /// Why a conversion that needs another program isn't offered (Settings › Helpers, the card's notice).
    public static let helpersUnavailable = "This version of Super Converter converts with what is built in. Conversions that need another program — such as Keynote, Pages and Numbers files, older PowerPoint files, Kindle books, DWG drawings, PostScript, DjVu and TeX — aren’t available."
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

/// Store edition, "Import Settings from Another Copy…": copies the direct edition's preferences (formats chosen,
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

/// Store edition: the copies of the person's files that the bundled tools (`ffmpeg`, `ffprobe`, `7zz`) read. The App
/// Sandbox's per-file grants (a drop, an open panel, a bookmark) belong to the app, and Apple documents no promise that a
/// child process sees them, so a tool only ever gets a file inside the app's container. One copy per job and source —
/// a clone on APFS when the file is on the container's volume, a real copy otherwise (JobRunner counts that space
/// first) — kept in the job's work folder and removed with it. The direct edition hands out the original.
public enum ToolStaging {
    private static let lock = NSLock()

    /// The container (the sandbox's home) and the app bundle: files there need no copy.
    static var readableRoots: [String] {
        [URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/", Bundle.main.bundleURL.standardizedFileURL.path + "/"]
    }

    /// True when a tool needs a copy of `url` (Store edition, a file outside the container and the bundle).
    public static func needsCopy(_ url: URL) -> Bool {
        guard Distribution.isAppStore else { return false }
        let path = url.standardizedFileURL.path
        return !readableRoots.contains { path.hasPrefix($0) }
    }

    /// The job folder a step's work folder belongs to (`Jobs/<id>`), so every step of a job shares one copy.
    static func jobFolder(of workFolder: URL) -> URL {
        let jobs = SuperConverterPaths.jobs.standardizedFileURL.pathComponents
        let parts = workFolder.standardizedFileURL.pathComponents
        guard parts.count > jobs.count, Array(parts.prefix(jobs.count)) == jobs else { return workFolder }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(parts.prefix(jobs.count + 1))), isDirectory: true)
    }

    /// The file a bundled tool should read for `url`: `url` itself, or its copy in the job's work folder (made once).
    /// Throws when the copy can't be made — a tool must never be pointed at a file it can't read.
    public static func stage(_ url: URL, workFolder: URL) throws -> URL {
        guard needsCopy(url) else { return url }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return url }
        let folder = jobFolder(of: workFolder).appendingPathComponent(".staged", isDirectory: true)
        // One name per source path, so a job's steps (probe, analysis passes, encode) share the copy.
        var hasher = Hasher()
        hasher.combine(url.standardizedFileURL.path)
        let key = String(UInt64(bitPattern: Int64(hasher.finalize())), radix: 36)
        let copy = folder.appendingPathComponent(key, isDirectory: true).appendingPathComponent(url.lastPathComponent)
        return try lock.withLock {
            if fm.fileExists(atPath: copy.path) { return copy }
            do {
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: copy)   // clonefile on APFS
                Log.helpers.notice("Staged a working copy of \(url.lastPathComponent, privacy: .private) for the bundled tools")
            } catch {
                try? fm.removeItem(at: copy)
                throw ConversionError.failed("Super Converter couldn’t make a working copy of “\(url.lastPathComponent)”: \((error as NSError).localizedDescription)")
            }
            return copy
        }
    }
}
