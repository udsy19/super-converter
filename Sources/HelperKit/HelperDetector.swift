// Adapted from Super PDF Sources/ConvertKit/Helpers/{LibreOffice,HelperService}.swift (commit 058469b): detection reads the
// file system only and never launches anything; versions come from Info.plist or the Homebrew folder name (a `--version`
// probe, which does launch the tool, is HelperService's background pass).

import Foundation
import SuperConverterCore

/// Where a helper was found.
struct HelperLocation: Hashable, Sendable {
    var helper: HelperID
    /// What runs: the executable inside an app (`…/Contents/MacOS/soffice`), a command-line tool, or the app bundle itself
    /// for the apps that are driven through Apple Events (iWork, Office).
    var executable: URL
    /// The `.app` it lives in, when it is one.
    var bundle: URL?
    /// Known without running anything; nil until probed.
    var version: String?
    /// True when it is one of ours (installed by the one-click installer, listed in `helpers.json`).
    var installedByUs: Bool
}

/// One entry of `helpers.json`: what the installer put on this Mac.
struct InstalledRecord: Codable, Hashable, Sendable {
    var version: String
    /// Absolute path of the executable (CLI helper) or of the app (`~/Applications/….app`).
    var path: String
    var installedAt: Date
}

struct HelperDetector: Sendable {
    /// The Settings › Helpers override (Defaults is app policy, so the app target passes it in).
    var override: @Sendable (HelperID) -> URL?
    /// What the one-click installer recorded (read fresh on every detection).
    var records: @Sendable () -> [HelperID: InstalledRecord]
    /// Places in addition to the catalog's, by helper (Homebrew's cask wrapper for LibreOffice, `~/Applications`).
    var extraCandidates: [HelperID: [String]] = HelperDetector.defaultExtras
    /// False looks only at the override and our own installs (the self-test, which must not find what is on this Mac).
    var searchKnownPlaces = true

    static let defaultExtras: [HelperID: [String]] = [
        .libreoffice: ["/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"],
        .oda: ["~/Applications/ODAFileConverter.app"],
        .iwork: ["~/Applications/Pages.app", "~/Applications/Numbers.app", "~/Applications/Keynote.app"],
    ]

    func locate(_ helper: HelperID) -> HelperLocation? {
        if let url = override(helper), let found = location(of: helper, at: url, installedByUs: false) { return found }
        if let record = records()[helper],
           let found = location(of: helper, at: URL(fileURLWithPath: record.path), installedByUs: true) {
            var withVersion = found
            withVersion.version = record.version
            return withVersion
        }
        for path in knownPlaces(helper) {
            if let found = location(of: helper, at: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), installedByUs: false) {
                return found
            }
        }
        return nil
    }

    /// Every app of an iWork or Office helper that is present ("Pages and Keynote found").
    func apps(of helper: HelperID) -> [URL] {
        let places = (override(helper).map { [$0.path] } ?? []) + knownPlaces(helper)
        return places.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func knownPlaces(_ helper: HelperID) -> [String] {
        searchKnownPlaces ? HelperCatalog.info(helper).detection + (extraCandidates[helper] ?? []) : []
    }

    func location(of helper: HelperID, at url: URL, installedByUs: Bool) -> HelperLocation? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        if url.pathExtension == "app" {
            let executable: URL
            switch helper {
            case .iwork, .msoffice: executable = url
            default:
                guard let inside = Self.executableName(of: helper) else { return nil }
                executable = url.appendingPathComponent("Contents/MacOS/\(inside)")
            }
            guard helper == .iwork || helper == .msoffice || fm.isExecutableFile(atPath: executable.path) else { return nil }
            return HelperLocation(helper: helper, executable: executable, bundle: url, version: Self.bundleVersion(url),
                                  installedByUs: installedByUs)
        }
        guard helper != .iwork, helper != .msoffice, fm.isExecutableFile(atPath: url.path) else { return nil }
        return HelperLocation(helper: helper, executable: url, bundle: nil, version: Self.pathVersion(url.resolvingSymlinksInPath()),
                              installedByUs: installedByUs)
    }

    /// The program inside an app bundle that does the work.
    static func executableName(of helper: HelperID) -> String? {
        switch helper {
        case .libreoffice: "soffice"
        case .calibre: "ebook-convert"
        case .oda: "ODAFileConverter"
        default: nil
        }
    }

    static func bundleVersion(_ app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")))?["CFBundleShortVersionString"] as? String
    }

    /// Homebrew keeps each version in its own folder: `…/Cellar/pandoc/3.8.1/bin/pandoc`, `…/Caskroom/libreoffice/26.2.5/…`;
    /// our own installs are `…/Helpers/<id>/<version>/<tool>`.
    static func pathVersion(_ resolved: URL) -> String? {
        let parts = resolved.pathComponents
        for marker in ["Cellar", "Caskroom", "Helpers"] {
            guard let i = parts.firstIndex(of: marker) else { continue }
            let versionIndex = i + 2
            guard versionIndex < parts.count - 1, let first = parts[versionIndex].first, first.isNumber else { continue }
            // Homebrew appends a revision ("3.8.1_1").
            return String(parts[versionIndex].split(separator: "_").first ?? "")
        }
        return nil
    }

    /// A `--version` line's number: "pandoc 3.8.1", "Tectonic 0.17.0", "GPL Ghostscript 10.04.0", "ffmpeg version 8.0.1".
    static func parseVersion(_ output: String) -> String? {
        output.range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map { String(output[$0]) }
    }
}
