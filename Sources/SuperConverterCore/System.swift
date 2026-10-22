import AppKit

// Small system helpers several modules share: colours from hex, byte and count formatting.
// The colour helpers are adapted from super-pdf Sources/SuperPDFCore/System.swift (commit 058469b).

public extension NSColor {
    /// "#RRGGBB" or "#RRGGBBAA" (the "#" is optional); malformed input gives magenta so it shows.
    convenience init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else {
            self.init(srgbRed: 1, green: 0, blue: 1, alpha: 1); return
        }
        let rgba = digits.count == 6 ? value << 8 | 0xFF : value
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }

    /// "#RRGGBBAA" in sRGB, upper-case.
    var hexRGBA: String {
        let c = usingColorSpace(.sRGB) ?? self
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent), byte(c.alphaComponent))
    }
}

/// The numbers cards and the action bar show (ux §7.1).
public enum Formatting {
    /// File sizes as Finder shows them (decimal units): "4.2 MB".
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "1.7 GB → 356 MB".
    public static func sizeChange(from old: Int64, to new: Int64) -> String { "\(bytes(old)) → \(bytes(new))" }

    /// "1 file", "12 files": the noun is passed in its singular and plural forms.
    public static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }

    /// "about 40 s left", "about 3 min left".
    public static func timeLeft(_ seconds: Double) -> String {
        if seconds < 90 { return "about \(max(Int(seconds.rounded()), 1)) s left" }
        return "about \(Int((seconds / 60).rounded())) min left"
    }
}
