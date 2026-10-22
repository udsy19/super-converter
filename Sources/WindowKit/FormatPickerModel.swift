import Combine
import SuperConverterCore

/// One target in the picker: the format, how it would run, and whether it can be picked.
struct PickerTarget: Hashable, Identifiable {
    let format: FormatID
    let choice: RouteChoice
    var id: FormatID { format }

    /// The helper a ⬇ marks: the route runs only through a helper that is not installed.
    var neededHelper: HelperID? {
        if case .helper(_, _, let missing) = choice { return missing.first }
        return nil
    }

    var isAvailable: Bool {
        if case .unavailable = choice { return false }
        return true
    }
}

/// A "Best for …" suggestion: a target and its two-word reason.
struct Suggestion: Hashable, Identifiable {
    let target: PickerTarget
    let reason: String
    var id: FormatID { target.format }
}

/// A category group in the list: its targets, and the hint when the result is not obvious ("one page per photo").
struct PickerSection: Hashable, Identifiable {
    let category: FormatCategory
    let targets: [PickerTarget]
    let hint: String?
    var id: FormatCategory { category }
}

/// The format picker's state and rules (ux §5.4): search over extensions, names and synonyms, "Best for …" chips, groups
/// by category, keyboard focus.
@MainActor
final class FormatPickerModel: ObservableObject {
    let source: FormatID
    let current: FormatID?
    let targets: [PickerTarget]
    @Published var query = ""
    /// Arrow-key focus, over `focusOrder`.
    @Published var focused: FormatID?
    /// "Use JPG for HEIC files from now on" (on by default, ux §5.4).
    @Published var remember: Bool

    init(source: FormatID, current: FormatID?, targets: [PickerTarget], remember: Bool = true) {
        self.source = source
        self.current = current
        self.targets = targets.filter { $0.format != source }
        self.remember = remember
        self.focused = current
    }

    var sourceCategory: FormatCategory { source.category }

    var placeholder: String { Strings.Picker.searchPlaceholder(count: targets.count, source: source) }

    var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var suggestions: [Suggestion] {
        BestFor.formats(for: sourceCategory).compactMap { format in
            targets.first { $0.format == format }.map { Suggestion(target: $0, reason: BestFor.reason(for: format)) }
        }
        .prefix(5).map { $0 }
    }

    /// Every target (or every match) grouped by category, in the catalog's order.
    var sections: [PickerSection] {
        let shown = isSearching ? matches : targets
        // The source's own kind first (images for a photo), then the catalog's order.
        let order = [sourceCategory] + FormatCategory.allCases.filter { $0 != sourceCategory }
        return order.compactMap { category in
            let inCategory = shown.filter { $0.format.category == category }
            guard !inCategory.isEmpty else { return nil }
            return PickerSection(category: category, targets: inCategory, hint: BestFor.hint(from: sourceCategory, to: inCategory.map(\.format)))
        }
    }

    /// Search results in rank order: extension, then names, then synonyms (ux §5.4).
    var matches: [PickerTarget] {
        Self.search(query, in: targets)
    }

    /// Formats the person searched for that this input cannot become, with the reason ("GIF pictures have no sound").
    var notOffered: [(format: FormatID, reason: String)] {
        guard isSearching else { return [] }
        let offered = Set(targets.map(\.format))
        return Self.rank(query, in: FormatCatalog.inputs.map(\.id)).filter { !offered.contains($0) && $0 != source }.compactMap { format in
            FormatMatrix.notOfferedReason(from: source, to: format).flatMap { $0.isEmpty ? nil : (format, $0) }
        }
    }

    /// The keyboard order: suggestions (when not searching), then the sections.
    var focusOrder: [FormatID] {
        let list = (isSearching ? [] : suggestions.map(\.target.format)) + sections.flatMap { $0.targets.map(\.format) }
        var seen = Set<FormatID>()
        return list.filter { seen.insert($0).inserted }
    }

    func move(_ step: Int) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        guard let focused, let index = order.firstIndex(of: focused) else { self.focused = order.first; return }
        self.focused = order[min(max(index + step, 0), order.count - 1)]
    }

    /// The target ↩ picks.
    var focusedTarget: PickerTarget? {
        let id = focused ?? focusOrder.first
        return targets.first { $0.format == id && $0.isAvailable }
    }

    // MARK: Search

    static func search(_ query: String, in targets: [PickerTarget]) -> [PickerTarget] {
        let order = rank(query, in: targets.map(\.format))
        return order.compactMap { format in targets.first { $0.format == format } }
    }

    /// Formats matching `query`, best match first: extension equal, extension prefix, name word prefix, synonym.
    static func rank(_ query: String, in formats: [FormatID]) -> [FormatID] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ".", with: "")
        guard !q.isEmpty else { return formats }
        var scored: [(FormatID, Int)] = []
        for id in formats {
            guard let format = FormatCatalog.format(id) else { continue }
            let ext = id.rawValue
            var score: Int?
            if ext == q { score = 0 }
            else if ext.hasPrefix(q) { score = 1 }
            else if words(format.name).contains(where: { $0.hasPrefix(q) }) || format.name.lowercased().contains(q) { score = 2 }
            else if format.synonyms.contains(where: { $0.lowercased().hasPrefix(q) || ($0.contains(" ") && $0.lowercased().contains(q)) }) { score = 3 }
            else if ext.contains(q) { score = 4 }
            if let score { scored.append((id, score)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.0)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
}

/// The picker's "Best for …" data: which targets suit each kind of source, why in two words, and the hints under groups
/// whose result is not obvious. This is copy (ux §5.4), so it lives here beside the view.
enum BestFor {
    static func formats(for category: FormatCategory) -> [FormatID] {
        switch category {
        case .image: ["jpg", "heic", "png", "webp", "pdf"]
        case .video: ["mp4", "mov", "gif", "webm", "mp3"]
        case .audio: ["mp3", "m4a", "wav", "flac", "aac"]
        case .document: ["pdf", "docx", "txt", "html", "epub"]
        case .spreadsheet: ["xlsx", "pdf", "csv", "ods"]
        case .presentation: ["pdf", "pptx", "jpg", "png"]
        case .ebook: ["pdf", "epub", "azw3", "mobi", "txt"]
        case .archive: ["zip", "7z", "tar.gz"]
        case .vector: ["png", "pdf", "svg", "eps"]
        case .cad: ["pdf", "dxf", "svg", "png"]
        case .font: ["woff2", "ttf", "otf", "woff"]
        }
    }

    static func reason(for format: FormatID) -> String {
        switch format.rawValue {
        case "jpg": "Any app"
        case "heic": "Smallest"
        case "png": "No loss"
        case "webp": "For the web"
        case "avif": "Smallest"
        case "pdf": "Document"
        case "mp4": "Any device"
        case "mov": "Apple apps"
        case "gif": "Animation"
        case "webm": "For the web"
        case "mp3": "Any player"
        case "m4a": "Apple apps"
        case "wav": "No loss"
        case "flac": "No loss"
        case "aac": "Small files"
        case "docx": "Word"
        case "txt": "Plain text"
        case "html": "Web page"
        case "epub": "E-readers"
        case "azw3", "mobi": "Kindle"
        case "xlsx": "Excel"
        case "csv": "Plain table"
        case "ods": "LibreOffice"
        case "pptx": "PowerPoint"
        case "zip": "Any Mac"
        case "7z": "Smallest"
        case "tar.gz": "Developers"
        case "svg": "Scales"
        case "eps": "Print"
        case "dxf": "CAD apps"
        case "woff2": "For the web"
        case "woff": "For the web"
        case "ttf": "Desktop"
        case "otf": "Desktop"
        default: format.pill
        }
    }

    /// The line after a group's chip when its result is not obvious ("one page per photo").
    static func hint(from source: FormatCategory, to formats: [FormatID]) -> String? {
        guard formats.count == 1, let format = formats.first else { return nil }
        switch (source, format.rawValue) {
        case (.image, "pdf"): return "one page per photo"
        case (.image, "svg"): return "traced into shapes"
        case (.document, "png"), (.document, "jpg"), (.ebook, "png"), (.ebook, "jpg"): return "one picture per page"
        case (.presentation, "png"), (.presentation, "jpg"): return "one picture per slide"
        case (.video, "mp3"), (.video, "m4a"), (.video, "wav"): return "sound only"
        case (.video, "gif"), (.video, "webp"): return "no sound"
        case (.vector, "dxf"): return "for CAD apps"
        default: return nil
        }
    }
}
