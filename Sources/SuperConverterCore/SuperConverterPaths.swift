import Foundation

/// Where Super Converter keeps its files (ARCHITECTURE §8): ~/Library/Application Support/Super Converter/ and
/// ~/Library/Caches/Super Converter/.
public enum SuperConverterPaths {
    public static let bundleID = "com.udsy.superconverter"
    public static let appName = "Super Converter"
    public static let supportFolderName = "Super Converter"
    /// The `superconverter://convert?file=…&to=jpg` URL scheme (ARCHITECTURE §3, app target).
    public static let urlScheme = "superconverter"
    public static let repository = URL(string: "https://github.com/udsy19/super-converter")!
    /// The GitHub Releases asset the updater looks for.
    public static let updateAssetBase = "SuperConverter"

    /// The folder `support` lives in (Application Support). The self-test and `SUPERCONVERTER_DATA_DIR` point it elsewhere.
    nonisolated(unsafe) public static var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    /// The folder `caches` lives in (Caches).
    nonisolated(unsafe) public static var cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

    public static var support: URL { ensure(base.appendingPathComponent(supportFolderName, isDirectory: true)) }
    /// CLI helpers unpack here, one folder per helper and version: `Helpers/<id>/<version>/`.
    public static var helpers: URL { ensure(support.appendingPathComponent("Helpers", isDirectory: true)) }
    public static func helper(_ id: HelperID, version: String) -> URL {
        ensure(helpers.appendingPathComponent(id.rawValue, isDirectory: true).appendingPathComponent(version, isDirectory: true))
    }
    /// What is installed, with versions and locations.
    public static var helpersRecord: URL { support.appendingPathComponent("helpers.json") }
    /// Work folders, one per job; removed when the job ends and swept at launch.
    public static var jobs: URL { ensure(support.appendingPathComponent("Jobs", isDirectory: true)) }
    public static func job(_ id: JobID) -> URL {
        ensure(jobs.appendingPathComponent(id.rawValue.uuidString.lowercased(), isDirectory: true))
    }
    /// The menu-bar list of recent conversions (last 10).
    public static var recent: URL { support.appendingPathComponent("recent.json") }
    /// The updater's state.
    public static var updateState: URL { support.appendingPathComponent("update.json") }
    /// LibreOffice's private profile (`-env:UserInstallation=`), so runs never touch the person's own.
    public static var libreOfficeProfile: URL { ensure(support.appendingPathComponent("lo-profile", isDirectory: true)) }
    /// Tectonic's package cache (warm-up document; runs use `--only-cached`).
    public static var tectonicCache: URL { ensure(support.appendingPathComponent("tectonic-cache", isDirectory: true)) }
    /// Quick Look thumbnails by file identity + modification date.
    public static var thumbnails: URL {
        ensure(cacheBase.appendingPathComponent(supportFolderName, isDirectory: true).appendingPathComponent("thumbnails", isDirectory: true))
    }

    /// Where a folder of the app's bundled resources may be, in order: `Contents/Resources/<name>` in the bundle, then
    /// the repository's `Resources/<name>` when running from a SwiftPM build (self-test, `sconv`, the bench).
    public static func bundledResources(_ name: String) -> [URL] {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent(name)) }
        var source = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { source.deleteLastPathComponent() }   // <root>/Sources/SuperConverterCore/SuperConverterPaths.swift → <root>
        candidates.append(source.appendingPathComponent("Resources").appendingPathComponent(name))
        return candidates
    }

    /// Free bytes for important use on the volume that holds `url`; `Int64.max` when the system can't say.
    public static func freeSpace(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    @discardableResult public static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Core bootstrap, launch sequence step 1 (ARCHITECTURE §9): `SUPERCONVERTER_DATA_DIR` and `SUPERCONVERTER_DEFAULTS_SUITE`
/// give tests throwaway places (and no updater).
public enum CoreBootstrap {
    /// Applies the environment overrides; returns true when either is set (the app then skips the updater and offers).
    @discardableResult
    public static func configure(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        var throwaway = false
        if let dir = environment["SUPERCONVERTER_DATA_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            SuperConverterPaths.base = url.appendingPathComponent("Application Support", isDirectory: true)
            SuperConverterPaths.cacheBase = url.appendingPathComponent("Caches", isDirectory: true)
            throwaway = true
        }
        if let suite = environment["SUPERCONVERTER_DEFAULTS_SUITE"], !suite.isEmpty, let store = UserDefaults(suiteName: suite) {
            Defaults.store = store
            throwaway = true
        }
        return throwaway
    }
}
