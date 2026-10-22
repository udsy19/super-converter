import Foundation
import SuperConverterCore

/// AutoCAD colour index → RGB (the standard 256-entry table, generated: 1–9 fixed, 10–249 are 24 hues × 10 shades, 250–255 greys).
enum ACI {
    static let table: [(r: Int, g: Int, b: Int)] = {
        var t = [(r: Int, g: Int, b: Int)](repeating: (0, 0, 0), count: 256)
        let fixed: [(Int, Int, Int)] = [(255, 0, 0), (255, 255, 0), (0, 255, 0), (0, 255, 255), (0, 0, 255), (255, 0, 255), (255, 255, 255),
                                        (128, 128, 128), (192, 192, 192)]
        for (i, c) in fixed.enumerated() { t[i + 1] = c }
        let values = [1.0, 0.8, 0.6, 0.5, 0.3]
        for index in 10...249 {
            let n = index - 10
            let hue = Double(n / 10) * 15
            let value = values[(n % 10) / 2]
            let saturation = n % 2 == 0 ? 1.0 : 0.5
            let h = hue / 60, sector = Int(h) % 6, f = h - Double(Int(h))
            let p = value * (1 - saturation), q = value * (1 - saturation * f), tt = value * (1 - saturation * (1 - f))
            let (r, g, b): (Double, Double, Double)
            switch sector {
            case 0: (r, g, b) = (value, tt, p)
            case 1: (r, g, b) = (q, value, p)
            case 2: (r, g, b) = (p, value, tt)
            case 3: (r, g, b) = (p, q, value)
            case 4: (r, g, b) = (tt, p, value)
            default: (r, g, b) = (value, p, q)
            }
            t[index] = (Int(r * 255), Int(g * 255), Int(b * 255))
        }
        let greys = [51, 91, 132, 173, 214, 255]
        for (i, g) in greys.enumerated() { t[250 + i] = (g, g, g) }
        return t
    }()

    static func rgb(_ index: Int) -> (r: Int, g: Int, b: Int) { table[min(max(index, 0), 255)] }

    /// The colour index nearest to an RGB value (for writing DXF from vector artwork).
    static func nearest(r: Int, g: Int, b: Int) -> Int {
        var best = 7, bestDistance = Int.max
        for i in 1...255 {
            let c = table[i]
            let d = (c.r - r) * (c.r - r) + (c.g - g) * (c.g - g) + (c.b - b) * (c.b - b)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }
}
