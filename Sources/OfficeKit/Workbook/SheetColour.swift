import Foundation

// Origin: Super PDF Sources/ConvertKit/Support/SheetTable.swift @ 058469b (`SheetRGB.tinted`) and Import/SpreadsheetImporter.swift
// (`SheetPalette`), adapted: colours are plain 0…1 components that read and write "#RRGGBB" for the Workbook model.

/// An sRGB colour, 0…1.
struct SheetRGB: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    static let black = SheetRGB(red: 0, green: 0, blue: 0)
    static let white = SheetRGB(red: 1, green: 1, blue: 1)

    init(red: Double, green: Double, blue: Double) { self.red = red; self.green = green; self.blue = blue }

    /// "FFRRGGBB" (ARGB, Excel's way), "RRGGBB" or "#RRGGBB"; nil when malformed.
    init?(hex: String) {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 8 { digits = String(digits.dropFirst(2)) }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255; green = Double((value >> 8) & 0xFF) / 255; blue = Double(value & 0xFF) / 255
    }

    /// "#RRGGBB" (the Workbook model's colour text).
    var hash: String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Excel's tint: towards white for positive values, towards black for negative ones (in HSL lightness).
    func tinted(_ tint: Double) -> SheetRGB {
        guard tint != 0 else { return self }
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        var l = (maxC + minC) / 2
        let d = maxC - minC
        var h = 0.0, s = 0.0
        if d > 0 {
            s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            if maxC == red { h = (green - blue) / d + (green < blue ? 6 : 0) } else if maxC == green { h = (blue - red) / d + 2 } else { h = (red - green) / d + 4 }
            h /= 6
        }
        l = tint < 0 ? l * (1 + tint) : l * (1 - tint) + tint
        func hue(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        guard s > 0 else { return SheetRGB(red: l, green: l, blue: l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        return SheetRGB(red: hue(p, q, h + 1.0 / 3), green: hue(p, q, h), blue: hue(p, q, h - 1.0 / 3))
    }
}

/// Excel's 64-colour legacy palette (`indexed`), plus 64/65 for the system foreground/background.
enum SheetPalette {
    private static let colors: [UInt32] = [
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x000000, 0xFFFFFF, 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00, 0xFF00FF, 0x00FFFF,
        0x800000, 0x008000, 0x000080, 0x808000, 0x800080, 0x008080, 0xC0C0C0, 0x808080,
        0x9999FF, 0x993366, 0xFFFFCC, 0xCCFFFF, 0x660066, 0xFF8080, 0x0066CC, 0xCCCCFF,
        0x000080, 0xFF00FF, 0xFFFF00, 0x00FFFF, 0x800080, 0x800000, 0x008080, 0x0000FF,
        0x00CCFF, 0xCCFFFF, 0xCCFFCC, 0xFFFF99, 0x99CCFF, 0xFF99CC, 0xCC99FF, 0xFFCC99,
        0x3366FF, 0x33CCCC, 0x99CC00, 0xFFCC00, 0xFF9900, 0xFF6600, 0x666699, 0x969696,
        0x003366, 0x339966, 0x003300, 0x333300, 0x993300, 0x993366, 0x333399, 0x333333,
    ]

    static func indexed(_ index: Int) -> SheetRGB? {
        if index == 64 { return .black }
        if index == 65 { return .white }
        guard index >= 0, index < colors.count else { return nil }
        let v = colors[index]
        return SheetRGB(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
