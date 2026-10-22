import AppKit

// Colour tokens (ux §3.2–3.3). Eleven category hues, each with four tokens: base (the vivid hue: progress fills, flows,
// dots), ink (text on tint), tint (pill and thumbnail backgrounds) and deep (fills under white text); dark mode keeps base
// and deep and swaps ink and tint. Neutrals follow ux §3.3. The hex values are the reference appearance used by the
// self-test and the mockups.

/// A light/dark pair of "#RRGGBB" / "#RRGGBBAA" reference values and the colour that renders it.
public struct SCColorToken: Hashable, @unchecked Sendable {
    public var name: String
    public var light: String
    public var dark: String
    /// A system colour to draw with instead of the pair (focus and selection use the accent colour).
    public var system: NSColor?

    public init(_ name: String, light: String, dark: String, system: NSColor? = nil) {
        self.name = name; self.light = light; self.dark = dark; self.system = system
    }

    public init(_ name: String, _ both: String) { self.init(name, light: both, dark: both) }

    /// A dynamic colour resolved by the drawing appearance.
    public var color: NSColor {
        if let system { return system }
        let light = NSColor(hex: light), dark = NSColor(hex: dark)
        return NSColor(name: NSColor.Name("superconverter." + name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    public func hex(dark isDark: Bool) -> String { isDark ? dark : light }
}

/// One category's hue (ux §3.2).
public struct SCCategoryColors: Hashable, Sendable {
    public let category: FormatCategory
    public let base: String
    public let ink: String
    public let tint: String
    public let deep: String
    public let darkInk: String
    public let darkTint: String
    /// Filled pills: white on deep, or near-black on base (chosen per hue by contrast).
    public let filledText: FilledText
    /// Ink on tint contrast, light and dark, as ux §3.2 prints them (the self-test checks the real ratios against these).
    public let inkContrast: (light: Double, dark: Double)
    /// Filled-pill text contrast as ux §3.2 prints it.
    public let filledContrast: Double

    public enum FilledText: String, Sendable {
        /// White on `deep`.
        case whiteOnDeep
        /// `#16171C` on `base`.
        case darkOnBase
    }

    public static func == (a: SCCategoryColors, b: SCCategoryColors) -> Bool { a.category == b.category }
    public func hash(into hasher: inout Hasher) { hasher.combine(category) }

    public var baseToken: SCColorToken { SCColorToken("\(category.rawValue).base", base) }
    public var inkToken: SCColorToken { SCColorToken("\(category.rawValue).ink", light: ink, dark: darkInk) }
    public var tintToken: SCColorToken { SCColorToken("\(category.rawValue).tint", light: tint, dark: darkTint) }
    public var deepToken: SCColorToken { SCColorToken("\(category.rawValue).deep", deep) }
    /// Fill and text of a filled pill.
    public var filledFillHex: String { filledText == .whiteOnDeep ? deep : base }
    public var filledTextHex: String { filledText == .whiteOnDeep ? "#FFFFFF" : SCColor.nearBlack }
}

public enum SCColor {
    /// `#16171C`: text on the light category fills and the light-mode label colour.
    public static let nearBlack = "#16171C"

    // MARK: Category colours (ux §3.2)

    public static let categories: [SCCategoryColors] = [
        cat(.document, "#3D6CF2", "#1E46B4", "#E6ECFD", "#2F5BD6", "#94AEF8", "#2B3659", .whiteOnDeep, (6.9, 5.4), 5.9),
        cat(.image, "#EE4A8C", "#AE1757", "#FDE7F0", "#D13374", "#F69BC0", "#522F43", .whiteOnDeep, (5.8, 5.6), 4.7),
        cat(.video, "#7A5AF0", "#5132C2", "#EEEAFD", "#6848DB", "#B6A4F7", "#383259", .whiteOnDeep, (6.9, 5.4), 5.9),
        cat(.audio, "#FF8A1F", "#A9500A", "#FFF0E2", "#D87016", "#FFBF84", "#563D2B", .darkOnBase, (4.9, 6.2), 7.6),
        cat(.spreadsheet, "#1FB36B", "#0C7642", "#E2F5EC", "#169859", "#84D5AE", "#24463B", .darkOnBase, (5.0, 6.0), 6.6),
        cat(.presentation, "#F2554B", "#B02A21", "#FDE9E8", "#D44238", "#F8A29C", "#533134", .whiteOnDeep, (5.6, 5.7), 4.5),
        cat(.ebook, "#12ADA6", "#06716C", "#E0F4F3", "#0D928C", "#7DD2CE", "#224448", .darkOnBase, (5.1, 6.0), 6.4),
        cat(.archive, "#F2B705", "#7F5C00", "#FDF6DE", "#BE8E03", "#F8D776", "#534725", .darkOnBase, (5.7, 6.5), 9.8),
        cat(.vector, "#B04FE0", "#7B20AB", "#F5E8FB", "#983AC8", "#D49EEE", "#443055", .whiteOnDeep, (6.8, 5.5), 5.6),
        cat(.cad, "#1C9FE3", "#0A6A9E", "#E1F3FB", "#1487C4", "#82CAF0", "#244156", .darkOnBase, (5.2, 5.9), 6.1),
        cat(.font, "#7DBE22", "#4A740C", "#EEF7E2", "#669D18", "#B8DB85", "#39482B", .darkOnBase, (5.0, 6.3), 7.9),
    ]

    public static func colors(for category: FormatCategory) -> SCCategoryColors {
        categories.first { $0.category == category }!
    }

    private static func cat(_ c: FormatCategory, _ base: String, _ ink: String, _ tint: String, _ deep: String, _ darkInk: String,
                            _ darkTint: String, _ filled: SCCategoryColors.FilledText, _ ratios: (Double, Double),
                            _ filledRatio: Double) -> SCCategoryColors {
        SCCategoryColors(category: c, base: base, ink: ink, tint: tint, deep: deep, darkInk: darkInk, darkTint: darkTint,
                         filledText: filled, inkContrast: ratios, filledContrast: filledRatio)
    }

    // MARK: Neutrals (ux §3.3)

    public static let windowBackground = SCColorToken("windowBackground", light: "#F4F5F9", dark: "#1B1C21")
    public static let card = SCColorToken("card", light: "#FFFFFF", dark: "#26272E")
    public static let hairline = SCColorToken("hairline", light: "#14162817", dark: "#FFFFFF14")
    public static let strongHairline = SCColorToken("strongHairline", light: "#14162829", dark: "#FFFFFF29")
    public static let label = SCColorToken("label", light: "#16171C", dark: "#F2F3F7")
    public static let secondaryLabel = SCColorToken("secondaryLabel", light: "#636774", dark: "#A3A7B4")
    public static let tertiaryLabel = SCColorToken("tertiaryLabel", light: "#9A9EAA", dark: "#6E7280")
    public static let controlFill = SCColorToken("controlFill", light: "#1416280F", dark: "#FFFFFF14")
    public static let controlHover = SCColorToken("controlHover", light: "#14162817", dark: "#FFFFFF1F")
    /// The action bar's material tint over its `.headerView` blur.
    public static let actionBar = SCColorToken("actionBar", light: "#FFFFFFD1", dark: "#26272ED6")
    public static let success = SCColorToken("success", "#1FA855")
    public static let warning = SCColorToken("warning", "#F2A100")
    public static let failure = SCColorToken("failure", "#E5484D")
    /// Focus and selection follow the system accent colour.
    public static let accent = SCColorToken("accent", light: "#007AFF", dark: "#0A84FF", system: .controlAccentColor)

    public static let neutrals: [SCColorToken] = [
        windowBackground, card, hairline, strongHairline, label, secondaryLabel, tertiaryLabel, controlFill, controlHover,
        actionBar, success, warning, failure, accent,
    ]

    /// With Increase Contrast on, tints darken by this fraction and pills gain a 1 pt ink border (ux §3.2).
    public static let increasedContrastTintDarkening = 0.06
    public static let increasedContrastBorder: CGFloat = 1

    // MARK: Contrast (WCAG 2.x)

    /// Relative luminance of "#RRGGBB" (alpha ignored).
    public static func luminance(hex: String) -> Double {
        let c = NSColor(hex: hex).usingColorSpace(.sRGB) ?? NSColor.black
        func lin(_ v: CGFloat) -> Double {
            let s = Double(v)
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    /// The contrast ratio of two colours, 1…21.
    public static func contrast(_ a: String, _ b: String) -> Double {
        let la = luminance(hex: a), lb = luminance(hex: b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Mixes `fraction` of `other` into `base` (both "#RRGGBB"), as the tints and deeps are derived (ux §3.2).
    public static func mix(_ base: String, with other: String, fraction: Double) -> String {
        let a = NSColor(hex: base).usingColorSpace(.sRGB)!, b = NSColor(hex: other).usingColorSpace(.sRGB)!
        func ch(_ x: CGFloat, _ y: CGFloat) -> Int { Int(((Double(x) * (1 - fraction) + Double(y) * fraction) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", ch(a.redComponent, b.redComponent), ch(a.greenComponent, b.greenComponent),
                      ch(a.blueComponent, b.blueComponent))
    }
}
