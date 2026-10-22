import Combine
import Foundation
import SuperConverterCore

/// The per-file options sheet's state (ux §5.5): the profile's plain controls, the rest under "More options", the values
/// being edited, the live estimate, and what "Done" applies.
@MainActor
final class OptionsModel: ObservableObject {
    let source: FormatID
    let target: FormatID
    let profile: OptionProfile
    /// Names for the subtitle: "Beach at golden hour.heic and 1 more photo".
    let subtitle: String
    /// Pixel size of the first file, for the estimate under quality controls.
    let pixels: (width: Int, height: Int)?
    /// The looks the pair offers (documents → PDF), nil otherwise.
    let looks: [DocumentLook]
    @Published var values: OptionValues
    @Published var look: DocumentLook?
    @Published var useForEvery: Bool
    @Published var moreExpanded = false

    init(source: FormatID, target: FormatID, profile: OptionProfile, values: OptionValues, look: DocumentLook?, looks: [DocumentLook] = [],
         subtitle: String, pixels: (width: Int, height: Int)? = nil, useForEvery: Bool = false) {
        self.source = source; self.target = target; self.profile = profile; self.values = values; self.look = look
        self.looks = looks; self.subtitle = subtitle; self.pixels = pixels
        self.useForEvery = useForEvery
    }

    var title: String { "\(target.pill) options" }

    /// The controls shown plainly (ux §5.5: the first three or four of the profile).
    var primary: [OptionDefinition] { Array(profile.primary.prefix(4)) }
    /// Everything after the first four plain controls, then the profile's own "more" options.
    var more: [OptionDefinition] { Array(profile.primary.dropFirst(4)) + profile.more }

    /// "progressive, colour detail, background, resizing": what hides under More options, in the technical names.
    var moreSummary: String {
        more.prefix(5).map { ($0.technicalName ?? $0.label).lowercased() }.joined(separator: ", ")
    }

    /// "look" is the card's document look, not a stored option.
    func value(_ definition: OptionDefinition) -> OptionValue? {
        definition.key == "look" ? (look.map { .string($0.rawValue) } ?? definition.defaultValue) : values.value(for: definition)
    }

    /// Sets a value; a value equal to the default is removed so only differences are stored.
    func set(_ definition: OptionDefinition, _ value: OptionValue?) {
        if definition.key == "look" {
            look = value?.string.flatMap(DocumentLook.init(rawValue:)).flatMap { $0.rawValue == definition.defaultValue?.string ? nil : $0 }
            return
        }
        if value == nil || value == definition.defaultValue { values.values[definition.key] = nil } else { values[definition.key] = value }
    }

    /// "About 2.1 MB each — looks the same as the original" under the quality control.
    var estimate: String? {
        guard let quality = profile.definition("quality"), let q = value(quality)?.int else { return nil }
        return Estimate.text(target: target, quality: q, pixels: pixels, size: values["size"]?.string ?? "original")
    }

    func reset() {
        values = OptionValues()
        look = nil
    }
}

/// The live estimate (ux §5.5). ConvertKit does not publish a sampling contract, so this is a model of how encoders spend
/// bytes on a photo: bytes per pixel grows with the cube of quality, scaled per codec. It says "About", and the wording tier
/// follows the quality. An engine-measured estimate replaces it when ConvertKit offers one.
enum Estimate {
    static func text(target: FormatID, quality: Int, pixels: (width: Int, height: Int)?, size: String) -> String? {
        let tier: String
        switch quality {
        case 85...: tier = "looks the same as the original"
        case 65..<85: tier = "very close to the original"
        case 40..<65: tier = "softer, but fine for screens"
        default: tier = "visibly softer"
        }
        guard let bytes = bytes(target: target, quality: quality, pixels: pixels, size: size) else { return tier.prefix(1).uppercased() + tier.dropFirst() }
        return "About \(Formatting.bytes(bytes)) each — \(tier)"
    }

    static func bytes(target: FormatID, quality: Int, pixels: (width: Int, height: Int)?, size: String) -> Int64? {
        guard let pixels else { return nil }
        let codec: Double
        switch target.rawValue {
        case "jpg", "jpeg": codec = 1
        case "webp": codec = 0.75
        case "avif": codec = 0.55
        case "heic", "heif": codec = 0.5
        default: return nil
        }
        let scale = Double(size).map { ($0 / 100) * ($0 / 100) } ?? 1
        let q = Double(min(max(quality, 1), 100)) / 100
        let bitsPerPixel = 0.015 + q * q * q * 1.9
        return Int64(Double(pixels.width * pixels.height) * scale * bitsPerPixel * codec / 8)
    }
}
