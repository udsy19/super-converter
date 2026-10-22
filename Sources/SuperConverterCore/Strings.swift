import Foundation

// Copy shared across modules (ux §7): sentence case, curly quotes around names, a real ellipsis on anything that opens
// something, no exclamation marks, errors that don't apologise. Copy of one screen lives in its module.

public enum Strings {
    public static let appName = "Super Converter"

    /// “Report.pdf”: curly quotes around a file name.
    public static func quoted(_ name: String) -> String { "“\(name)”" }

    // MARK: States (ux §7.1)

    public enum Window {
        public static let emptyHeadline = "Drop files to convert"
        public static let emptyLine = "Photos, videos, documents, e-books, fonts and archives — 212 formats. Everything happens on this Mac."
        public static let chooseFiles = "Choose Files…"
        public static let emptyFootnote = "Also: drop files on Super Converter in the menu bar, or right-click files in Finder › Quick Actions › Convert with Super Converter"
        public static let popularPairs: [(from: FormatID, to: FormatID)] = [
            ("heic", "jpg"), ("mov", "mp4"), ("docx", "pdf"), ("pdf", "docx"), ("webp", "png"), ("wav", "mp3"), ("epub", "pdf"), ("ttf", "woff2"),
        ]
        public static func dragHeadline(_ count: Int) -> String { "Drop \(count) \(count == 1 ? "file" : "files") to add \(count == 1 ? "it" : "them")" }
        /// "2 photos and a video. You’ll pick what each becomes next."
        public static func dragLine(_ counts: [(FormatCategory, Int)]) -> String {
            let parts = counts.filter { $0.1 > 0 }.map { category, n in n == 1 ? "a \(category.noun(count: 1))" : "\(n) \(category.noun(count: n))" }
            return "\(list(parts)). You’ll pick what each becomes next."
        }
        /// "8 files · 1.7 GB".
        public static func subtitle(files: Int, bytes: Int64) -> String { "\(Formatting.count(files, "file", "files")) · \(Formatting.bytes(bytes))" }
        public static func subtitleConverting(done: Int, of total: Int) -> String { "Converting \(done) of \(total)" }
        public static func subtitleConverted(done: Int, of total: Int) -> String { "\(done) of \(total) converted" }
        public static func convertButton(files: Int) -> String { "Convert \(Formatting.count(files, "file", "files"))" }
        public static let stop = "Stop"
        public static let convertMore = "Convert more"
        public static let showInFinder = "Show in Finder"
        public static let share = "Share…"
    }

    public enum Card {
        public static func progress(percent: Int, secondsLeft: Double?) -> String {
            secondsLeft.map { "\(percent) % · \(Formatting.timeLeft($0))" } ?? "\(percent) %"
        }
        public static func page(_ i: Int, of n: Int) -> String { "Page \(i) of \(n)" }
        public static func slide(_ i: Int, of n: Int) -> String { "Slide \(i) of \(n)" }
        public static func chapter(_ i: Int, of n: Int) -> String { "Chapter \(i) of \(n)" }
        public static let waiting = "Waiting…"
        public static func waiting(for helper: HelperID) -> String { "Waiting for \(HelperCatalog.info(helper).name)" }
        /// "4.2 MB · was 6.0 MB".
        public static func done(newSize: Int64, oldSize: Int64) -> String { "\(Formatting.bytes(newSize)) · was \(Formatting.bytes(oldSize))" }
        public static let doneBadge = "Done"
        public static let failedBadge = "Didn’t convert"
        /// "This is a PNG file": the content differs from the extension (ux §6.2).
        public static func mismatch(_ format: FormatID) -> String { "This is a \(format.pill) file" }
        public static let unreadable = "Super Converter can’t read this kind of file yet"
    }

    public enum ActionBar {
        public static func converting(done: Int, of total: Int) -> String { "Converting… \(done) of \(total) done" }
        public static func done(ok: Int, of total: Int) -> String { "Done. \(ok) of \(total) \(total == 1 ? "file" : "files") converted" }
        /// "1.7 GB → 356 MB, saved next to the originals · 1 needs attention".
        public static func doneDetail(old: Int64, new: Int64, place: String, needAttention: Int) -> String {
            var text = "\(Formatting.sizeChange(from: old, to: new)), saved \(place)"
            if needAttention > 0 { text += " · \(needAttention) need\(needAttention == 1 ? "s" : "") attention" }
            return text
        }
        public static let setAllTo = "Set all to"
        public static let chooseAFormat = "Choose a format"
        public static let saveTo = "Save to"
        public static let nextToOriginals = "Next to the originals"
    }

    public enum Helper {
        public static func needs(_ helper: HelperID) -> String { "Needs \(HelperCatalog.info(helper).name)" }
        /// "Free · 160 MB".
        public static func cost(_ helper: HelperID) -> String {
            let info = HelperCatalog.info(helper)
            let price = info.licence == .proprietary ? "Proprietary" : "Free"
            return info.downloadMB.map { "\(price) · \($0) MB" } ?? price
        }
        public static func installing(_ helper: HelperID, percent: Int) -> String { "Installing \(HelperCatalog.info(helper).name)… \(percent) %" }
        /// The optional helper that would do better, on a done card.
        public static func betterWithHelper(_ helper: HelperID) -> String { "Make it look like the original — Install \(HelperCatalog.info(helper).name)" }
        public static let install = "Install"
        public static let get = "Get…"
        public static let remove = "Remove"
        public static let lookAgain = "Look again"
    }

    // MARK: Picker (ux §5.4)

    public enum Picker {
        public static func searchPlaceholder(count: Int, source: FormatID) -> String { "Search \(count) formats for \(source.pill)" }
        public static func useFromNowOn(_ target: FormatID, source: FormatID) -> String { "Use \(target.pill) for \(source.pill) files from now on" }
        /// "Needs calibre — free, 160 MB": the hover text of a ⬇ target.
        public static func needsHelperHint(_ helper: HelperID) -> String {
            let info = HelperCatalog.info(helper)
            let price = info.licence == .proprietary ? "proprietary" : "free"
            return "Needs \(info.name) — " + (info.downloadMB.map { "\(price), \($0) MB" } ?? price)
        }
        public static let bestFor = "Best for"
    }

    // MARK: Problems (ux §7.2): one line, one fix

    /// What a card says for an error, and the button it offers. "Try with LibreOffice" only when LibreOffice is installed.
    public static func problem(_ error: ConversionError, libreOfficeInstalled: Bool = false) -> (message: String, fix: ConversionError.Fix?) {
        switch error {
        case .passwordRequired(let f):
            return ("This \(f.pill) needs its password", .enterPassword)
        case .damaged(let f):
            return ("This file looks damaged — it couldn’t be read as \(f.pill)", libreOfficeInstalled ? .tryWithLibreOffice : nil)
        case .drmProtected:
            return ("This book is locked by the store it came from (DRM) and can’t be converted", nil)
        case .helperMissing(let h):
            let info = HelperCatalog.info(h)
            let oneClick: Bool = { if case .oneClick = info.install { true } else { false } }()
            return ("Needs \(info.name)", oneClick ? .install : .get)
        case .helperTimedOut(let h, let seconds):
            let when = seconds % 60 == 0 && seconds >= 120 ? "\(seconds / 60) minutes" : "\(seconds) seconds"
            return ("\(HelperCatalog.info(h).name) took longer than \(when) and was stopped", .tryAgain)
        case .notEnoughSpace(let volume, let needed):
            return ("There isn’t enough space on \(quoted(volume)) — \(Formatting.bytes(needed)) more is needed", .showInFinder)
        case .folderNotWritable(let name):
            return ("Super Converter can’t save into \(quoted(name))", .chooseAnotherFolder)
        case .notReadableYet:
            return (Card.unreadable, .showInFinder)
        case .classicDWF:
            return ("This is a classic DWF drawing, which Super Converter can’t read yet", nil)
        case .impossiblePair(let reason):
            return (reason, nil)
        case .unsupportedPair(let from, let to):
            return ("\(from.pill) can’t become \(to.pill)", nil)
        case .cancelled:
            return ("Stopped", nil)
        case .failed(let message):
            return (message, nil)
        }
    }

    /// "a, b and c" with the first letter capitalised, the way the drag-over line reads.
    static func list(_ parts: [String]) -> String {
        let text: String
        switch parts.count {
        case 0: return ""
        case 1: text = parts[0]
        default: text = parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
