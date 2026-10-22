import AppKit
import SuperConverterCore
import SwiftUI

// SwiftUI bridges for the Core design tokens (ux §3): category palettes resolved for the current appearance and contrast,
// neutral colours, type styles and the flow gradient (§3.4). Views never hold hex strings; they ask here.

/// One category's colours for the current appearance (ux §3.2): base, ink, tint, deep, and the filled-pill pair.
struct Palette {
    let category: FormatCategory
    let base: Color
    let ink: Color
    let tint: Color
    let deep: Color
    let filledFill: Color
    let filledText: Color
    /// The ink of the pill border with Increase Contrast on; nil otherwise.
    let border: Color?

    init(_ category: FormatCategory, scheme: ColorScheme, contrast: ColorSchemeContrast = .standard) {
        let c = SCColor.colors(for: category)
        let dark = scheme == .dark
        let inkHex = dark ? c.darkInk : c.ink
        var tintNS = NSColor(hex: dark ? c.darkTint : c.tint)
        let increased = contrast == .increased
        if increased { tintNS = tintNS.blended(withFraction: SCColor.increasedContrastTintDarkening, of: .black) ?? tintNS }
        self.category = category
        base = Color(nsColor: NSColor(hex: c.base))
        ink = Color(nsColor: NSColor(hex: inkHex))
        tint = Color(nsColor: tintNS)
        deep = Color(nsColor: NSColor(hex: c.deep))
        filledFill = Color(nsColor: NSColor(hex: c.filledFillHex))
        filledText = Color(nsColor: NSColor(hex: c.filledTextHex))
        border = increased ? Color(nsColor: NSColor(hex: inkHex)) : nil
    }

    /// The colour a gradient stop uses on the Convert button: deep, or the ink for the light hues (ux §3.4).
    var buttonStop: Color { SCColor.colors(for: category).filledText == .whiteOnDeep ? deep : ink }
}

extension Color {
    init(_ token: SCColorToken) { self.init(nsColor: token.color) }

    static let scWindow = Color(SCColor.windowBackground)
    static let scCard = Color(SCColor.card)
    static let scHairline = Color(SCColor.hairline)
    static let scStrongHairline = Color(SCColor.strongHairline)
    static let scLabel = Color(SCColor.label)
    static let scSecondary = Color(SCColor.secondaryLabel)
    static let scTertiary = Color(SCColor.tertiaryLabel)
    static let scControl = Color(SCColor.controlFill)
    static let scControlHover = Color(SCColor.controlHover)
    static let scSuccess = Color(SCColor.success)
    static let scFailure = Color(SCColor.failure)
    static let scAccent = Color(SCColor.accent)
}

extension View {
    /// Applies a Core type style (family, size, weight, tracking, tabular figures).
    func scFont(_ style: SCTextStyle) -> some View {
        modifier(SCFontModifier(style: style))
    }
}

private struct SCFontModifier: ViewModifier {
    let style: SCTextStyle
    func body(content: Content) -> some View {
        let font = style.tabularFigures ? Font(style.font).monospacedDigit() : Font(style.font)
        content.font(font).tracking(style.tracking)
    }
}

extension FormatID {
    /// The category colour a format wears; unknown formats read as documents.
    var category: FormatCategory { FormatCatalog.format(self)?.category ?? .document }
}

/// The source → target colour flow (ux §3.4): a left-to-right gradient between the two category bases.
func flowGradient(from source: FormatCategory, to target: FormatCategory) -> LinearGradient {
    LinearGradient(colors: [Color(nsColor: NSColor(hex: SCColor.colors(for: source).base)),
                            Color(nsColor: NSColor(hex: SCColor.colors(for: target).base))],
                   startPoint: .leading, endPoint: .trailing)
}

/// The eleven hues in a loop for the hovering drop-zone border (ux §3.4 item 5).
let hueLoop: [Color] = {
    let order: [FormatCategory] = [.image, .document, .video, .audio, .archive, .font, .spreadsheet, .ebook, .cad, .vector, .presentation]
    let colors = order.map { Color(nsColor: NSColor(hex: SCColor.colors(for: $0).base)) }
    return colors + [colors[0]]
}()
