import Foundation

/// A step either produces complete output or throws one of these; each maps to a line in ux §7.2 (what the card says and
/// the one fix it offers).
public enum ConversionError: Error, Equatable, Sendable {
    case passwordRequired(FormatID)
    case damaged(FormatID)
    case drmProtected
    case helperMissing(HelperID)
    case helperTimedOut(HelperID, seconds: Int)
    case notEnoughSpace(volume: String, needed: Int64)
    case folderNotWritable(name: String)
    case notReadableYet
    case classicDWF
    case impossiblePair(reason: String)
    case unsupportedPair(from: FormatID, to: FormatID)
    /// The step stopped before doing something the person should agree to first (quality §8 "Safety": a decompression bomb
    /// asks first). `question` is the card's line and `proceed` its button; the job runs again with the boolean option
    /// `option` set to true to go ahead. Surfaces without a card pass the question on (a notification, `sconv`'s message).
    case needsConfirmation(question: String, proceed: Fix, option: String)
    case cancelled
    /// Anything else, with the engine's own words (kept short, in the voice of ux §1.1).
    case failed(String)

    /// The fix a card offers (ux §7.2): the button label, or nil when there is none.
    public enum Fix: String, Sendable {
        case enterPassword = "Enter Password…"
        case tryWithLibreOffice = "Try with LibreOffice"
        case install = "Install"
        case get = "Get…"
        case tryAgain = "Try Again"
        case showInFinder = "Show in Finder"
        case chooseAnotherFolder = "Choose Another Folder…"
        case extractAnyway = "Extract Anyway"
    }
}
