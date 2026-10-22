import AppKit
import SuperConverterCore

/// Where a card is in its life (ux §5.3–§5.7).
enum CardState: Equatable {
    case ready
    /// Enqueued; the queue has not started it.
    case queued
    case waitingForHelper(HelperID)
    case converting(JobProgress)
    case done(ConversionResult)
    case failed(ConversionError)
    /// Nothing can read this kind of file yet; the card says so.
    case unreadable

    var isActive: Bool {
        switch self {
        case .queued, .waitingForHelper, .converting: true
        default: false
        }
    }

    var isFinished: Bool {
        switch self {
        case .done, .failed: true
        default: false
        }
    }
}

/// One dropped file.
@MainActor
final class FileCard: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let sizeBytes: Int64
    /// The detected format; nil when nothing in the catalog matches.
    let source: FormatID?
    /// Set when the file's content differs from its extension ("This is a PNG file").
    let mismatch: FormatID?

    @Published var target: FormatID?
    @Published var options = OptionValues()
    @Published var look: DocumentLook?
    /// Facts that matter for the kind: "4032 × 3024", "2:14" (ux §5.3).
    @Published var facts: [String] = []
    @Published var thumbnail: NSImage?
    @Published var state: CardState = .ready
    @Published var route: RouteChoice = .builtin(steps: [])
    @Published var betterWithHelper: HelperID?
    /// The profile the options sheet resolves.
    @Published var optionProfile: String?
    /// The helper's install progress while this card's helper installs (0…1; nil when idle).
    @Published var helperInstall: Double?
    /// The finished file's thumbnail (the card turns to the target colour with it).
    @Published var resultThumbnail: NSImage?
    /// The planner's other looks for this pair (documents → PDF).
    @Published var availableLooks: [DocumentLook] = []
    /// "Try with LibreOffice" / "Make it look like the original": run the helper route when it exists.
    var preferHelper: Bool?
    var jobID: JobID?
    /// The last progress step announced to VoiceOver (25 % steps).
    var announcedStep = 0

    init(url: URL, sizeBytes: Int64, source: FormatID?, mismatch: FormatID?) {
        self.url = url; self.sizeBytes = sizeBytes; self.source = source; self.mismatch = mismatch
    }

    var name: String { url.lastPathComponent }
    var displayName: String { url.deletingPathExtension().lastPathComponent }

    /// The name shown on the card: the original while it waits, the result's name once done.
    var shownName: String {
        if case .done(let result) = state, let output = result.outputs.first { return output.lastPathComponent }
        return name
    }

    var sourceCategory: FormatCategory { source?.category ?? .document }
    var targetCategory: FormatCategory { target?.category ?? sourceCategory }

    /// The helper whose absence blocks the route.
    var missingHelpers: [HelperID] {
        if case .helper(_, _, let missing) = route { return missing }
        return []
    }

    /// Why the planner says this pair cannot run here ("GIF pictures have no sound"); nil when it can.
    var unavailableMessage: String? {
        guard case .unavailable(let reason) = route else { return nil }
        switch reason {
        case .notOffered(let text), .engineUnavailable(_, let text): return text
        }
    }

    var hasChangedOptions: Bool { !options.isEmpty || look != nil }

    /// A card whose target can still be changed (ux §5.6: cards stay editable until they start).
    var isEditable: Bool {
        switch state {
        case .ready, .waitingForHelper, .failed: source != nil
        default: false
        }
    }

    var request: ConversionRequest? {
        guard let source, let target else { return nil }
        return ConversionRequest(source: url, sourceFormat: source, target: target, options: options, look: look, preferHelper: preferHelper)
    }

    /// "Beach at golden hour, HEIC photo, 4.2 megabytes. Becomes JPG." (ux §6.7)
    var accessibilitySummary: String {
        var text = displayName
        if let source { text += ", \(source.pill) \(sourceCategory.noun(count: 1))" }
        text += ", \(Self.spokenSize(sizeBytes))."
        switch state {
        case .done(let result):
            text += " Converted to \(target?.pill ?? "")."
            if let first = result.lossNotes.first { text += " " + first.headline + "." }
        case .failed(let error):
            text += " " + Strings.problem(error).message + "."
        case .unreadable:
            text += " " + Strings.Card.unreadable + "."
        case .converting(let progress):
            if let f = progress.fraction { text += " Converting, \(Int(f * 100)) percent." }
            if let target { text += " Becomes \(target.pill)." }
        case .queued, .waitingForHelper:
            text += " Waiting to convert."
            if let target { text += " Becomes \(target.pill)." }
        case .ready:
            if let target { text += " Becomes \(target.pill)." } else { text += " Choose a format." }
        }
        return text
    }

    static func spokenSize(_ bytes: Int64) -> String {
        Formatting.bytes(bytes)
            .replacingOccurrences(of: " KB", with: " kilobytes").replacingOccurrences(of: " MB", with: " megabytes")
            .replacingOccurrences(of: " GB", with: " gigabytes").replacingOccurrences(of: " bytes", with: " bytes")
    }
}
