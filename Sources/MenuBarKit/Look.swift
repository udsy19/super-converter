import AppKit
import SuperConverterCore
import SwiftUI

// The panel's look: the Core design tokens (ux §3) in SwiftUI, the same ones WindowKit's Theme and Primitives resolve. Those
// are internal to WindowKit, and feature modules depend on Core only (ARCHITECTURE §3), so the few bridges the panel needs
// are repeated here; every colour, size and type style still comes from SCColor, SCMetrics and SCFont.

extension Color {
    init(_ token: SCColorToken) { self.init(nsColor: token.color) }
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }

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
        let font = style.tabularFigures ? Font(style.font).monospacedDigit() : Font(style.font)
        return self.font(font).tracking(style.tracking)
    }
}

/// One category's colours for the current appearance and contrast (ux §3.2).
struct CategoryPalette {
    let ink: Color, tint: Color, deep: Color, filledFill: Color, filledText: Color
    /// The pill border with Increase Contrast on; nil otherwise.
    let border: Color?
    /// The colour a gradient stop uses on the Convert button: deep, or the ink for the light hues (ux §3.4).
    let buttonStop: Color

    init(_ category: FormatCategory, scheme: ColorScheme, contrast: ColorSchemeContrast) {
        let c = SCColor.colors(for: category)
        let dark = scheme == .dark
        var tint = NSColor(hex: dark ? c.darkTint : c.tint)
        let increased = contrast == .increased
        if increased { tint = tint.blended(withFraction: SCColor.increasedContrastTintDarkening, of: .black) ?? tint }
        ink = Color(hex: dark ? c.darkInk : c.ink)
        self.tint = Color(nsColor: tint)
        deep = Color(hex: c.deep)
        filledFill = Color(hex: c.filledFillHex)
        filledText = Color(hex: c.filledTextHex)
        border = increased ? Color(hex: dark ? c.darkInk : c.ink) : nil
        buttonStop = c.filledText == .whiteOnDeep ? Color(hex: c.deep) : Color(hex: dark ? c.darkInk : c.ink)
    }
}

/// Resolves a category's palette for the current appearance and contrast.
struct PaletteReader<Content: View>: View {
    let category: FormatCategory
    let content: (CategoryPalette) -> Content
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ category: FormatCategory, @ViewBuilder content: @escaping (CategoryPalette) -> Content) {
        self.category = category; self.content = content
    }

    var body: some View { content(CategoryPalette(category, scheme: scheme, contrast: contrast)) }
}

/// The source format's pill: category tint, ink text (ux §3.5).
struct SourcePill: View {
    let format: FormatID
    var body: some View {
        PaletteReader(FormatCatalog.format(format)?.category ?? .document) { p in
            Text(format.pill).scFont(SCFont.pill).foregroundStyle(p.ink)
                .padding(.horizontal, 8).frame(height: SCMetrics.Card.sourcePillHeight)
                .background(Capsule().fill(p.tint))
                .overlay { if let border = p.border { Capsule().strokeBorder(border, lineWidth: SCColor.increasedContrastBorder) } }
        }
    }
}

/// The target pill: filled, with a chevron because it opens the choice of targets (ux §3.5).
struct TargetPill: View {
    let format: FormatID?
    let category: FormatCategory

    var body: some View {
        PaletteReader(category) { p in
            HStack(spacing: 4) {
                Text(format?.pill ?? "Choose").scFont(SCFont.targetPill)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .heavy)).accessibilityHidden(true)
            }
            .foregroundStyle(format == nil ? Color.scLabel : p.filledText)
            .padding(.leading, 11).padding(.trailing, 9)
            .frame(height: SCMetrics.Card.targetPillHeight)
            .background(Capsule().fill(format == nil ? Color.scControl : p.filledFill))
            .overlay { if let border = p.border { Capsule().strokeBorder(border, lineWidth: SCColor.increasedContrastBorder) } }
        }
    }
}

/// The flow arrow (ux §3.4): a line from the source colour to the target colour, ending in a target-coloured head.
struct FlowArrow: View {
    let from: FormatCategory
    let to: FormatCategory

    var body: some View {
        let target = Color(hex: SCColor.colors(for: to).base)
        HStack(spacing: -1) {
            Capsule().fill(LinearGradient(colors: [Color(hex: SCColor.colors(for: from).base), target], startPoint: .leading, endPoint: .trailing))
                .frame(width: SCMetrics.Card.flowSize.width, height: SCMetrics.Card.flowSize.height)
            Triangle().fill(target).frame(width: 5, height: 8)
        }
        .padding(.horizontal, SCMetrics.Card.flowGap)
        .accessibilityHidden(true)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

extension FormatCategory {
    /// The symbol on a thumbnail stand-in before (or without) a Quick Look thumbnail.
    var symbol: String {
        switch self {
        case .document: "doc.text.fill"
        case .image: "photo.fill"
        case .video: "play.rectangle.fill"
        case .audio: "waveform"
        case .spreadsheet: "tablecells.fill"
        case .presentation: "rectangle.on.rectangle.angled"
        case .ebook: "book.closed.fill"
        case .archive: "archivebox.fill"
        case .vector: "scribble.variable"
        case .cad: "ruler.fill"
        case .font: "textformat"
        }
    }
}
