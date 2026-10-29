import Foundation
import SuperConverterCore
import UniformTypeIdentifiers

/// The six Finder Quick Actions and the Services that mirror them (ux §5.10). One value says everything the extension
/// bundles, the Services menu and the app need to agree on: the title, the target, which files it shows for (by UTType) and
/// the link it hands to the app. The plists under Sources/SuperConverterQuickActions/Plists are written from `infoPlist`
/// (the self-test checks they match).
public enum QuickAction: String, CaseIterable, Sendable {
    case convertWith = "convert-with"
    case toJPG = "convert-to-jpg"
    case toPNG = "convert-to-png"
    case toPDF = "convert-to-pdf"
    case toMP4 = "convert-to-mp4"
    case toMP3 = "convert-to-mp3"

    public var title: String {
        switch self {
        case .convertWith: "Convert with Super Converter…"
        case .toJPG: "Convert to JPG"
        case .toPNG: "Convert to PNG"
        case .toPDF: "Convert to PDF"
        case .toMP4: "Convert to MP4"
        case .toMP3: "Convert to MP3"
        }
    }

    /// The format a one-step action produces; nil for "Convert with Super Converter…", which opens the window.
    public var target: FormatID? {
        switch self {
        case .convertWith: nil
        case .toJPG: "jpg"
        case .toPNG: "png"
        case .toPDF: "pdf"
        case .toMP4: "mp4"
        case .toMP3: "mp3"
        }
    }

    /// Which files it shows for, as Settings › Quick Actions says it (ux §5.10).
    public var takes: String {
        switch self {
        case .convertWith: "Any file"
        case .toJPG, .toPNG: "Images"
        case .toPDF: "Documents, images, slides, sheets and e-books"
        case .toMP4: "Videos"
        case .toMP3: "Audio and videos"
        }
    }

    /// Switched on at first launch: the first three one-step actions; MP4 and MP3 wait for Settings (ux §5.10).
    /// "Convert with Super Converter…" is left as macOS has it.
    var startsOn: Bool? {
        switch self {
        case .convertWith: nil
        case .toJPG, .toPNG, .toPDF: true
        case .toMP4, .toMP3: false
        }
    }

    // MARK: Packaging

    /// "ConvertToJPG": the extension bundle's name (`<name>.appex`) and its plist's.
    public var bundleName: String {
        switch self {
        case .convertWith: "ConvertWithSuperConverter"
        default: "ConvertTo" + target!.pill
        }
    }

    /// The extension's bundle id, under the app's.
    public var bundleID: String { "\(SuperConverterPaths.bundleID).quickactions.\(bundleName)" }

    /// The Info.plist key that tells the shared executable which action it is.
    public static let infoKey = "SuperConverterQuickAction"

    /// The action an extension's Info.plist names.
    public init?(bundleInfo: [String: Any]?) {
        guard let raw = bundleInfo?[Self.infoKey] as? String, let action = QuickAction(rawValue: raw) else { return nil }
        self = action
    }

    // MARK: Which files it shows for (ux §5.10)

    /// The categories whose files the action takes.
    var categories: [FormatCategory] {
        switch self {
        case .convertWith: FormatCategory.allCases
        case .toJPG, .toPNG: [.image]
        case .toPDF: [.document, .image, .presentation, .spreadsheet, .ebook]
        case .toMP4: [.video]
        case .toMP3: [.audio, .video]
        }
    }

    /// System types that stand for a whole category: every image, every audio file, every movie.
    private static let broadTypes: [FormatCategory: [String]] = [
        .image: ["public.image"], .audio: ["public.audio"], .video: ["public.movie"],
        .document: ["public.text"], .spreadsheet: ["public.spreadsheet"], .presentation: ["public.presentation"],
    ]

    /// True when a file in this format can become the target here (a JPEG is a JPG; a PDF is not offered PDF).
    func takes(_ format: FormatID) -> Bool {
        guard let info = FormatCatalog.format(format) else { return false }
        guard let target else { return true }
        guard categories.contains(info.category), !FormatCatalog.isSameFormat(format, target) else { return false }
        let sources = FormatCatalog.all.filter { $0.family == info.family }.map(\.id)
        let targets = FormatCatalog.all.filter { $0.family == FormatCatalog.format(target)?.family }.map(\.id)
        return sources.contains { from in targets.contains { FormatMatrix.route(from: from, to: $0)?.isOffered == true } }
    }

    /// The type identifiers the action's activation rule and Services entry list, sorted: the broad system types of its
    /// categories, and the catalog's own identifiers (PostScript and ODF drawings are "images" that are not `public.image`;
    /// documents, books and video containers have no broad type).
    public var activationTypes: [String] {
        guard target != nil else { return ["public.item"] }
        var identifiers = Set(categories.flatMap { Self.broadTypes[$0] ?? [] })
        for format in FormatCatalog.inputs where categories.contains(format.category) && takes(format.id) {
            identifiers.formUnion(format.utTypeIdentifiers)
        }
        identifiers.remove("com.adobe.pdf")   // a PDF is not offered "Convert to PDF"
        return identifiers.sorted()
    }

    /// True when a file of this type shows the action: the type conforms to one of the activation types.
    public func accepts(_ type: UTType) -> Bool {
        activationTypes.contains { UTType($0).map(type.conforms(to:)) ?? false }
    }

    /// `NSExtensionActivationRule`: shown when at least one selected item conforms to an activation type.
    public var activationRule: String {
        let tests = activationTypes.map { "$attachment.registeredTypeIdentifiers UTI-CONFORMS-TO \"\($0)\"" }.joined(separator: " OR ")
        return "SUBQUERY(extensionItems, $extensionItem, SUBQUERY($extensionItem.attachments, $attachment, ANY \(tests)).@count >= 1).@count >= 1"
    }

    // MARK: Info.plist and Services entries (data for scripts/build-app.sh)

    /// The extension bundle's Info.plist; `build-app.sh` sets the version keys to the app's.
    public var infoPlist: [String: Any] {
        [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": title,
            "CFBundleName": bundleName,
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "SuperConverterQuickActions",
            "CFBundlePackageType": "XPC!",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            Self.infoKey: rawValue,
            "NSExtension": [
                "NSExtensionPointIdentifier": "com.apple.services",
                "NSExtensionPrincipalClass": "QuickActionRequestHandler",
                "NSExtensionAttributes": [
                    "NSExtensionActivationRule": activationRule,
                    "NSExtensionServiceAllowsFinderPreviewItem": true,
                    "NSExtensionServiceAllowsTouchBarItem": false,
                    "NSExtensionServiceFinderPreviewLabel": title,
                    "NSExtensionServiceFinderPreviewIconName": "NSActionTemplate",
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    /// The `NSServices` entry of the app's Info.plist for this action (ux §5.10: "the same five are available as Services",
    /// and the window one from the table in ux §1).
    public var servicesEntry: [String: Any] {
        [
            "NSMenuItem": ["default": title],
            "NSMessage": serviceMessage,
            "NSPortName": SuperConverterPaths.appName,
            "NSSendFileTypes": activationTypes,
        ]
    }

    /// The selector name (without arguments) `ServicesProvider` answers to.
    var serviceMessage: String {
        switch self {
        case .convertWith: "convertWithSuperConverter"
        default: "convertTo" + target!.pill
        }
    }

    /// Every `NSServices` entry, in menu order.
    public static var servicesEntries: [[String: Any]] { allCases.map(\.servicesEntry) }
}
