import Foundation

/// Something a conversion could not carry over (quality §1, ux §5.7). Every engine reports these; nothing degrades silently.
public struct LossNote: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case layersFlattened, transparencyFilled, fontsReplaced, hdrToSDR, gamutClipped, colourProfileDropped
        case animationDropped, metadataDropped, macrosDropped, formattingSimplified, tableSimplified, mathAsPicture
        case shadingRasterised, textAsOutlines, hyperlinksDropped, imagesDropped, tracksDropped, subtitlesDropped
        case chaptersDropped, encryptionRemoved, permissionsDropped, otherLoss
    }

    public let kind: Kind
    /// A short detail for the popover ("3 fonts: Helvetica Neue → Latin Modern"); empty when the headline says it all.
    public let detail: String

    public init(_ kind: Kind, detail: String = "") { self.kind = kind; self.detail = detail }

    /// The one-line phrase for the card ("Layers were flattened"), in the voice of ux §1.1.
    public var headline: String {
        switch kind {
        case .layersFlattened: "Layers were flattened"
        case .transparencyFilled: "Transparency was filled with white"
        case .fontsReplaced: "Some fonts were replaced"
        case .hdrToSDR: "HDR was converted to standard range"
        case .gamutClipped: "Some colours were outside the new colour space"
        case .colourProfileDropped: "The colour profile couldn’t be kept"
        case .animationDropped: "The animation was dropped"
        case .metadataDropped: "Some photo details were dropped"
        case .macrosDropped: "Macros were removed"
        case .formattingSimplified: "Some formatting was simplified"
        case .tableSimplified: "Some tables were simplified"
        case .mathAsPicture: "Some formulas became pictures"
        case .shadingRasterised: "Some gradients became pictures"
        case .textAsOutlines: "Text was turned into shapes"
        case .hyperlinksDropped: "Links were dropped"
        case .imagesDropped: "Some pictures were dropped"
        case .tracksDropped: "Some audio tracks were dropped"
        case .subtitlesDropped: "Subtitles were dropped"
        case .chaptersDropped: "Chapters were dropped"
        case .encryptionRemoved: "The password was removed"
        case .permissionsDropped: "Permissions weren’t kept"
        case .otherLoss: "Something couldn’t be carried over"
        }
    }
}
