import AppKit

// Type (ux §3.1). SF Pro Rounded is the personality (cheerful, friendly, still Apple); everything people read at length is
// SF Pro Text.

public struct SCTextStyle: Hashable, Sendable {
    public enum Family: String, Sendable { case rounded, text }

    public var family: Family
    public var size: CGFloat
    /// Line height in points.
    public var line: CGFloat
    public var weight: NSFont.Weight
    /// Tracking in points.
    public var tracking: CGFloat
    public var uppercase: Bool
    public var tabularFigures: Bool

    public init(_ family: Family, _ size: CGFloat, line: CGFloat, _ weight: NSFont.Weight = .regular, tracking: CGFloat = 0,
                uppercase: Bool = false, tabularFigures: Bool = false) {
        self.family = family; self.size = size; self.line = line; self.weight = weight; self.tracking = tracking
        self.uppercase = uppercase; self.tabularFigures = tabularFigures
    }

    public var font: NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard family == .rounded, let descriptor = base.fontDescriptor.withDesign(.rounded),
              let rounded = NSFont(descriptor: descriptor, size: size) else { return base }
        return rounded
    }
}

public enum SCFont {
    /// Empty-state headline.
    public static let display = SCTextStyle(.rounded, 30, line: 36, .heavy, tracking: -0.3)
    /// Sheet and popover titles, Settings headings.
    public static let title = SCTextStyle(.rounded, 17, line: 22, .bold)
    /// Action-bar summary, primary button label.
    public static let summary = SCTextStyle(.rounded, 15, line: 20, .bold)
    /// Format pills, chips (target pills use `targetPill`).
    public static let pill = SCTextStyle(.rounded, 11, line: 11, .bold, tracking: 0.35, uppercase: true)
    public static let targetPill = SCTextStyle(.rounded, 12, line: 12, .bold, tracking: 0.35, uppercase: true)
    /// Section heads in the picker.
    public static let sectionHead = SCTextStyle(.rounded, 11, line: 11, .bold, tracking: 0.6, uppercase: true)
    /// File names.
    public static let name = SCTextStyle(.text, 13, line: 16, .semibold)
    public static let body = SCTextStyle(.text, 13, line: 18)
    /// Sizes, dimensions, durations, progress (secondary colour).
    public static let meta = SCTextStyle(.text, 11, line: 14, tabularFigures: true)

    public static let all: [SCTextStyle] = [display, title, summary, pill, targetPill, sectionHead, name, body, meta]
}
