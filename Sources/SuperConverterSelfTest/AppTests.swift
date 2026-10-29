import AppKit
import MenuBarKit
import SuperConverterCore
import UniformTypeIdentifiers

// The app target's checks (WP-R): the launch sequence's order (read from the app's source, which the self-test can't
// import), Resources/Info.plist against what Core's catalog and MenuBarKit's Quick Actions say it must hold (document
// types and type declarations for all 212 formats, the URL scheme, the Services entries, the usage strings), and the
// `superconverter://` links as people type them in scripts. Nothing launches the app or registers anything.
// SUPERCONVERTER_WRITE_PLISTS=1 rewrites Resources/Info.plist from `appInfoPlist` (keeping its version keys).
func registerAppTests() {
    SelfTest.cases.append(("App.paths", {
        check(SuperConverterPaths.bundleID == "com.udsy.superconverter" && SuperConverterPaths.urlScheme == "superconverter",
              "bundle identifier and URL scheme")
    }))
    SelfTest.cases.append(("App.launchSequence", { appLaunchSequence() }))
    SelfTest.cases.append(("App.infoPlist", { appInfoPlistMatches() }))
    SelfTest.cases.append(("App.infoPlistCoversCatalog", { appInfoPlistCoversCatalog() }))
    SelfTest.cases.append(("App.typedLinks", { appTypedLinks() }))
}

private let appRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let infoPlistURL = appRoot.appendingPathComponent("Resources/Info.plist")

// MARK: - Launch sequence (ARCHITECTURE §9)

/// Steps 1–4 in their order: bootstrap; HelperKit, every engine, ConvertKit, WindowKit, MenuBarKit, SettingsKit; the
/// updater, the menus and the Services provider; registration, the files passed in, the updater's start.
private func appLaunchSequence() {
    guard let source = try? String(contentsOf: appRoot.appendingPathComponent("Sources/SuperConverter/AppDelegate.swift"), encoding: .utf8) else {
        print("  (sources not on disk; launch sequence not read)"); return
    }
    let installs = source.split(separator: "\n").compactMap { line -> String? in
        let text = line.trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix("Module.install()") else { return nil }
        return String(text.dropLast("Module.install()".count))
    }
    let engines = ModuleID.allCases.filter { $0.role == .engine && $0 != .helperKit }.map(\.rawValue)
    check(installs.first == ModuleID.helperKit.rawValue, "HelperKit installs first (\(installs.first ?? "none"))")
    check(Set(installs.dropFirst().prefix(engines.count)) == Set(engines) && installs.count == engines.count + 5,
          "then every engine module once: \(installs)")
    check(Array(installs.suffix(4)) == ["ConvertKit", "WindowKit", "MenuBarKit", "SettingsKit"], "then the feature modules in order")
    check(Set(installs).count == installs.count, "no module installs twice")
    func position(_ text: String) -> String.Index? { source.range(of: text)?.lowerBound }
    let steps = ["CoreBootstrap.configure()", "HelperKitModule.install()", "SettingsKitModule.install()", "Services.updates = ",
                 "NSApp.mainMenu = ", "NSApp.servicesProvider = ", "NSUpdateDynamicServices()", "LSRegisterURL(",
                 "Services.menuBar.install()", "open(waiting)", "Services.updates.start()"]
    let positions = steps.map(position)
    check(!positions.contains(nil), "every launch step is there: \(zip(steps, positions).filter { $0.1 == nil }.map(\.0))")
    let found = positions.compactMap { $0 }
    check(found == found.sorted(), "and in ARCHITECTURE §9's order")
    check(source.contains("if !isThrowaway { Services.updates.start() }") && source.contains("if !isThrowaway, Bundle.main.bundleURL.pathExtension == \"app\""),
          "a throwaway data folder starts no updater and registers nothing")
}

// MARK: - Info.plist

/// A format's own type when macOS declares none: the app imports one so Open With and the Quick Actions find the file.
private func importedTypeIdentifier(_ format: Format) -> String { "\(SuperConverterPaths.bundleID).format.\(format.id.rawValue)" }

/// Inputs macOS declares no type for, whose extension is a single word: Finder sees only the last word of "tar.lzo", so
/// those are found through their last word's format (LZO).
private var formatsNeedingImport: [Format] {
    FormatCatalog.inputs.filter { $0.utTypeIdentifiers.isEmpty && !$0.id.rawValue.contains(".") }
}

/// The broad system type a category's files conform to, besides `public.data` and `public.content`.
private func broadType(_ category: FormatCategory) -> String? {
    switch category {
    case .image: "public.image"
    case .video: "public.movie"
    case .audio: "public.audio"
    case .archive: "public.archive"
    case .font: "public.font"
    default: nil
    }
}

/// What Resources/Info.plist holds besides its version keys (formats §1, ux §2 "Open With › Super Converter for all 212
/// formats", ux §5.10 Services, ARCHITECTURE §7 automation).
private func appInfoPlist() -> [String: Any] {
    let documentTypes: [[String: Any]] = FormatCategory.allCases.map { category in
        let formats = FormatCatalog.inputs.filter { $0.category == category }
        var types = Set(formats.flatMap(\.utTypeIdentifiers))
        types.formUnion(formatsNeedingImport.filter { $0.category == category }.map(importedTypeIdentifier))
        return ["CFBundleTypeName": category.title, "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate",
                "LSItemContentTypes": types.sorted()]
    }
    // Extensions macOS has no type for, also listed by name: when another app declares a type for one, LaunchServices
    // prefers that declaration over the app's import, and Open With still offers Super Converter.
    let otherFiles: [String: Any] = [
        "CFBundleTypeName": "Other files", "CFBundleTypeRole": "Viewer", "LSHandlerRank": "Alternate",
        "CFBundleTypeExtensions": formatsNeedingImport.map(\.id.rawValue).sorted(),
    ]
    let imported: [[String: Any]] = formatsNeedingImport.map { format in
        var tags: [String: Any] = ["public.filename-extension": [format.id.rawValue]]
        if !format.mimeTypes.isEmpty { tags["public.mime-type"] = format.mimeTypes }
        return ["UTTypeIdentifier": importedTypeIdentifier(format), "UTTypeDescription": format.name,
                "UTTypeConformsTo": ["public.data", "public.content"] + (broadType(format.category).map { [$0] } ?? []),
                "UTTypeTagSpecification": tags]
    }
    return [
        "CFBundleDevelopmentRegion": "en",
        "CFBundleDisplayName": SuperConverterPaths.appName,
        "CFBundleName": SuperConverterPaths.appName,
        "CFBundleExecutable": "SuperConverter",
        "CFBundleIdentifier": SuperConverterPaths.bundleID,
        "CFBundleIconFile": "AppIcon",
        "CFBundleIconName": "AppIcon",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundlePackageType": "APPL",
        "LSMinimumSystemVersion": "14.0",
        "LSApplicationCategoryType": "public.app-category.utilities",
        "NSPrincipalClass": "NSApplication",
        "NSHighResolutionCapable": true,
        "NSHumanReadableCopyright": "Copyright © 2026 Udaya Vijay Anand. MIT License.",
        "CFBundleURLTypes": [["CFBundleURLName": SuperConverterPaths.bundleID, "CFBundleURLSchemes": [SuperConverterPaths.urlScheme]]],
        "CFBundleDocumentTypes": documentTypes + [otherFiles],
        "UTImportedTypeDeclarations": imported,
        "NSServices": QuickAction.servicesEntries,
        // The hardened runtime asks before automation and before reading the protected folders (ARCHITECTURE §7).
        "NSAppleEventsUsageDescription": "Super Converter asks Pages, Numbers, Keynote and Microsoft Office to export the files you convert with them.",
        "NSDesktopFolderUsageDescription": "Super Converter reads the files you convert from your Desktop and saves the results next to them.",
        "NSDocumentsFolderUsageDescription": "Super Converter reads the files you convert from your Documents folder and saves the results next to them.",
        "NSDownloadsFolderUsageDescription": "Super Converter reads the files you convert from your Downloads folder and saves the results next to them.",
        "NSRemovableVolumesUsageDescription": "Super Converter reads the files you convert from removable drives and saves the results next to them.",
        "NSNetworkVolumesUsageDescription": "Super Converter reads the files you convert from network drives and saves the results next to them.",
    ]
}

private let versionKeys = ["CFBundleShortVersionString", "CFBundleVersion"]

/// Resources/Info.plist is `appInfoPlist` plus the version keys scripts/release.sh sets.
private func appInfoPlistMatches() {
    let onDisk = NSDictionary(contentsOf: infoPlistURL) as? [String: Any]
    var expected = appInfoPlist()
    for key in versionKeys { expected[key] = onDisk?[key] ?? (key == "CFBundleVersion" ? "1" : "0.1.0") }
    if ProcessInfo.processInfo.environment["SUPERCONVERTER_WRITE_PLISTS"] == "1" {
        let data = try? PropertyListSerialization.data(fromPropertyList: expected, format: .xml, options: 0)
        check((try? data?.write(to: infoPlistURL)) != nil, "Resources/Info.plist written")
    }
    guard let info = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] else { check(false, "Resources/Info.plist reads"); return }
    check((info as NSDictionary).isEqual(to: expected),
          "Resources/Info.plist is what the catalog writes (SUPERCONVERTER_WRITE_PLISTS=1 rewrites it); differing keys: \(expected.keys.filter { !((info[$0] as AnyObject?)?.isEqual(expected[$0]) ?? false) }.sorted())")
    for key in versionKeys { check((info[key] as? String).map { !$0.isEmpty } == true, "\(key) is set") }
}

/// Every one of the 212 formats opens with Super Converter, by type or by extension, and every type it names is declared.
private func appInfoPlistCoversCatalog() {
    guard let info = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] else { check(false, "Resources/Info.plist reads"); return }
    let documentTypes = info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
    let listedTypes = Set(documentTypes.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
    let listedExtensions = Set(documentTypes.flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] })
    let imported = Set((info["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []).compactMap { $0["UTTypeIdentifier"] as? String })
    check(FormatCatalog.inputs.count == 212, "212 input formats")
    func opens(_ format: Format) -> Bool {
        format.utTypeIdentifiers.contains(where: listedTypes.contains) || listedTypes.contains(importedTypeIdentifier(format))
            || listedExtensions.contains(format.id.rawValue)
    }
    for format in FormatCatalog.inputs {
        // "tar.lzo" is a .lzo file to Finder.
        let finderSees = format.id.rawValue.split(separator: ".").last.flatMap { FormatCatalog.format(FormatID(String($0))) }
        check(opens(format) || (format.id.rawValue.contains(".") && finderSees.map(opens) == true), "\(format.pill) opens with Super Converter")
    }
    for type in listedTypes {
        check(imported.contains(type) || UTType(type) != nil, "\(type) is a type macOS declares, or the app imports it")
    }
    check(!listedTypes.contains("public.item") && !listedTypes.contains("public.data"), "no catch-all type: only the formats it converts")
    check(documentTypes.allSatisfy { $0["CFBundleTypeRole"] as? String == "Viewer" && $0["LSHandlerRank"] as? String == "Alternate" },
          "every document type is Viewer / Alternate: Super Converter never takes over a file's default app")
    let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    check(schemes == [SuperConverterPaths.urlScheme], "the superconverter:// scheme")
    let services = info["NSServices"] as? [[String: Any]] ?? []
    check(services.compactMap { $0["NSMessage"] as? String } == ["convertWithSuperConverter", "convertToJPG", "convertToPNG", "convertToPDF", "convertToMP4", "convertToMP3"],
          "the six Services entries, in menu order")
}

// MARK: - Links (ARCHITECTURE §3: `superconverter://convert?file=…&to=jpg`)

/// Links as a script or Terminal writes them (percent-encoded by hand, `open 'superconverter://…'`), on top of the round
/// trips MenuBarKit's tests check.
private func appTypedLinks() {
    let typed = URL(string: "superconverter://convert?file=/Users/me/Beach%20at%20golden%20hour.heic&file=%2FUsers%2Fme%2Fb.png&to=jpg")!
    check(QuickActionLink(typed) == QuickActionLink(.convert, files: [URL(fileURLWithPath: "/Users/me/Beach at golden hour.heic"),
                                                                    URL(fileURLWithPath: "/Users/me/b.png")], target: "jpg"),
          "a typed convert link: both files, in order, decoded, to JPG")
    let noTarget = URL(string: "superconverter://convert?file=/Users/me/a.mov")!
    check(QuickActionLink(noTarget)?.target == nil && QuickActionLink(noTarget)?.verb == .convert, "without `to`, each file becomes its default target")
    check(QuickActionLink(URL(string: "superconverter://convert?file=/a.heic&file=docs/b.png&to=png")!)?.files == [URL(fileURLWithPath: "/a.heic")],
          "a relative path is dropped, the absolute one kept")
}
