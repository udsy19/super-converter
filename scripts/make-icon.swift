// Renders Super Converter's app icon into a folder (ux §3.7): a rounded-square plate holding three tilted cards — a pink
// photo, a blue page and a violet video frame, in their category colours (ux §3.2) — and, over them, a disc filled with
// the signature flow from what a file was to what it becomes (pink → violet → blue, ux §3.4) carrying a white circular
// double arrow. The menu-bar icon is the double arrow alone; MenuBarKit draws it from the SF Symbol
// `arrow.triangle.2.circlepath` as a template image, so only the app icon is rendered here.
//   AppIcon.iconset/   the app icon at every size iconutil needs
// Usage: swift scripts/make-icon.swift <out-folder>
// Adapted from super-pdf scripts/make-icon.swift (commit 2079863): the plate geometry, its shadow, the folded sheet and the
// iconset sizes.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func context(_ px: Int) -> CGContext {
    CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func png(_ ctx: CGContext) -> Data { NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])! }

func gradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// Category colours (ux §3.2): base, ink, tint, deep.
struct Hue { let base: UInt32, ink: UInt32, tint: UInt32, deep: UInt32 }
let images = Hue(base: 0xEE4A8C, ink: 0xAE1757, tint: 0xFDE7F0, deep: 0xD13374)
let documents = Hue(base: 0x3D6CF2, ink: 0x1E46B4, tint: 0xE6ECFD, deep: 0x2F5BD6)
let video = Hue(base: 0x7A5AF0, ink: 0x5132C2, tint: 0xEEEAFD, deep: 0x6848DB)

/// A card (ux §3.5: 208 × 250, radius 16) centred on the origin, `width` wide: white, with a soft shadow, drawn by `content`
/// inside its thumbnail well (the card's tint).
func card(_ ctx: CGContext, width: CGFloat, hue: Hue, shadow s: CGFloat, small: Bool, content: (CGContext, CGRect) -> Void) {
    let height = width * 250 / 208
    let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
    let body = rounded(rect, width * 16 / 208)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035, color: color(0x141628, 0.32))
    ctx.addPath(body); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    // The well: 192 × 132 at 8 inset; below it a name line and the category pill.
    let inset = width * 8 / 208
    let well = CGRect(x: rect.minX + inset, y: rect.maxY - inset - width * 132 / 208, width: rect.width - inset * 2, height: width * 132 / 208)
    ctx.saveGState()
    ctx.addPath(rounded(well, width * 11 / 208)); ctx.clip()
    ctx.setFillColor(color(hue.tint)); ctx.fill(well)
    content(ctx, well)
    ctx.restoreGState()
    guard !small else { return }
    let line = width * 0.07
    ctx.setFillColor(color(0x16171C, 0.78))
    ctx.addPath(rounded(CGRect(x: rect.minX + inset * 1.6, y: well.minY - line * 1.9, width: rect.width * 0.62, height: line), line / 2)); ctx.fillPath()
    ctx.setFillColor(color(hue.base))
    ctx.addPath(rounded(CGRect(x: rect.minX + inset * 1.6, y: rect.minY + inset * 1.6, width: rect.width * 0.34, height: line * 1.5), line * 0.75)); ctx.fillPath()
}

/// The pink photo: hills under a sun.
func photo(_ ctx: CGContext, _ well: CGRect) {
    ctx.drawLinearGradient(gradient([color(0xFFD3E4), color(images.tint)], [0, 1]),
                           start: CGPoint(x: well.midX, y: well.maxY), end: CGPoint(x: well.midX, y: well.minY), options: [])
    let sun = well.width * 0.12
    ctx.setFillColor(color(0xFFFFFF, 0.95))
    ctx.fillEllipse(in: CGRect(x: well.minX + well.width * 0.14, y: well.maxY - well.height * 0.4, width: sun * 2, height: sun * 2))
    let far = CGMutablePath()
    far.move(to: CGPoint(x: well.minX, y: well.minY))
    far.addLine(to: CGPoint(x: well.minX, y: well.minY + well.height * 0.45))
    far.addQuadCurve(to: CGPoint(x: well.maxX, y: well.minY + well.height * 0.3), control: CGPoint(x: well.midX + well.width * 0.1, y: well.maxY + well.height * 0.05))
    far.addLine(to: CGPoint(x: well.maxX, y: well.minY)); far.closeSubpath()
    ctx.addPath(far); ctx.setFillColor(color(images.base)); ctx.fillPath()
    let near = CGMutablePath()
    near.move(to: CGPoint(x: well.minX, y: well.minY))
    near.addLine(to: CGPoint(x: well.minX, y: well.minY + well.height * 0.18))
    near.addQuadCurve(to: CGPoint(x: well.maxX, y: well.minY + well.height * 0.42), control: CGPoint(x: well.midX + well.width * 0.25, y: well.minY - well.height * 0.05))
    near.addLine(to: CGPoint(x: well.maxX, y: well.minY)); near.closeSubpath()
    ctx.addPath(near); ctx.setFillColor(color(images.deep)); ctx.fillPath()
}

/// The violet video frame: a film strip's sprocket holes around a play mark.
func frame(_ ctx: CGContext, _ well: CGRect) {
    ctx.setFillColor(color(video.base)); ctx.fill(well)
    let hole = well.height * 0.09
    for row in [well.minY + hole * 0.6, well.maxY - hole * 1.6] {
        var x = well.minX + hole * 0.6
        while x < well.maxX {
            ctx.addPath(rounded(CGRect(x: x, y: row, width: hole * 1.3, height: hole), hole * 0.3))
            x += hole * 2.2
        }
    }
    ctx.setFillColor(color(0xFFFFFF, 0.5)); ctx.fillPath()
    let r = well.height * 0.24
    let play = CGMutablePath()
    play.move(to: CGPoint(x: well.midX - r * 0.6, y: well.midY + r))
    play.addLine(to: CGPoint(x: well.midX + r, y: well.midY))
    play.addLine(to: CGPoint(x: well.midX - r * 0.6, y: well.midY - r))
    play.closeSubpath()
    ctx.addPath(play); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
}

/// The blue page: a white sheet with a folded corner and lines of text, on the documents tint.
func page(_ small: Bool) -> (CGContext, CGRect) -> Void {
    { ctx, well in
        let w = well.height * 0.62, h = well.height * 0.8, fold = w * 0.26
        let sheet = CGRect(x: well.midX - w / 2, y: well.minY + well.height * 0.1, width: w, height: h)
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: sheet.minX, y: sheet.minY))
        outline.addLine(to: CGPoint(x: sheet.maxX, y: sheet.minY))
        outline.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
        outline.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
        outline.addLine(to: CGPoint(x: sheet.minX, y: sheet.maxY))
        outline.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -w * 0.02), blur: w * 0.08, color: color(documents.ink, 0.3))
        ctx.addPath(outline); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
        ctx.restoreGState()
        let flap = CGMutablePath()
        flap.move(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY))
        flap.addLine(to: CGPoint(x: sheet.maxX - fold, y: sheet.maxY - fold))
        flap.addLine(to: CGPoint(x: sheet.maxX, y: sheet.maxY - fold))
        flap.closeSubpath()
        ctx.addPath(flap); ctx.setFillColor(color(0xC9D6FB)); ctx.fillPath()
        let left = sheet.minX + w * 0.16, right = sheet.maxX - w * 0.16
        let line = h * (small ? 0.09 : 0.055)
        var y = sheet.maxY - h * 0.3
        ctx.setFillColor(color(documents.base))
        ctx.addPath(rounded(CGRect(x: left, y: y, width: (right - left) * 0.6, height: line * 1.3), line * 0.6)); ctx.fillPath()
        y -= line * 2.6
        ctx.setFillColor(color(0xA9BBEF))
        for width in small ? [1.0, 0.8] : [1.0, 0.92, 1.0, 0.7] {
            ctx.addPath(rounded(CGRect(x: left, y: y, width: (right - left) * width, height: line), line / 2)); ctx.fillPath()
            y -= line * 2.1
        }
    }
}

/// Two arrows chasing each other round a circle of radius `r` centred on `c`, as a stroked path with arrowheads.
func doubleArrow(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, lineWidth: CGFloat) {
    ctx.setStrokeColor(color(0xFFFFFF)); ctx.setFillColor(color(0xFFFFFF))
    ctx.setLineWidth(lineWidth); ctx.setLineCap(.round)
    let head = lineWidth * 1.35
    for start in [CGFloat.pi * 0.12, CGFloat.pi * 1.12] {
        let end = start + .pi * 0.68
        ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: false)
        ctx.strokePath()
        // The head points along the circle (counter-clockwise) at `end`.
        let tip = CGPoint(x: c.x + cos(end + 0.2) * r, y: c.y + sin(end + 0.2) * r)
        let back = CGPoint(x: c.x + cos(end - 0.06) * r, y: c.y + sin(end - 0.06) * r)
        let radial = CGPoint(x: cos(end - 0.06), y: sin(end - 0.06))
        let arrow = CGMutablePath()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: back.x + radial.x * head, y: back.y + radial.y * head))
        arrow.addLine(to: CGPoint(x: back.x - radial.x * head, y: back.y - radial.y * head))
        arrow.closeSubpath()
        ctx.addPath(arrow); ctx.fillPath()
    }
}

func renderIcon(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = context(px)
    let small = px <= 32

    // The plate: Apple's icon grid (824 of 1024, centred, a little high), its soft shadow, the window's quiet neutral
    // lit from above (ux §3.3) so the category colours carry the icon.
    let inset = s * 0.098
    let plate = CGRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let squircle = rounded(plate, plate.width * 0.225)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.3))
    ctx.addPath(squircle); ctx.setFillColor(color(0xF4F5F9)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    ctx.drawLinearGradient(gradient([color(0xFFFFFF), color(0xF4F5F9), color(0xDDE1EC)], [0, 0.5, 1]),
                           start: CGPoint(x: plate.midX, y: plate.maxY), end: CGPoint(x: plate.midX, y: plate.minY), options: [])

    // The cards: photo behind on the left, video frame behind on the right, the page in front, fanned like the empty
    // window's sample cards (ux §5.1).
    let cardWidth = plate.width * (small ? 0.46 : 0.4)
    let fan: [(dx: CGFloat, dy: CGFloat, angle: CGFloat, hue: Hue, content: (CGContext, CGRect) -> Void)] = [
        (-0.2, 0.05, 15, images, photo),
        (0.2, 0.05, -15, video, frame),
        (0, 0.09, -2, documents, page(small)),
    ]
    for placed in fan {
        ctx.saveGState()
        ctx.translateBy(x: plate.midX + plate.width * placed.dx, y: plate.midY + plate.height * placed.dy)
        ctx.rotate(by: placed.angle * .pi / 180)
        card(ctx, width: cardWidth, hue: placed.hue, shadow: s, small: small, content: placed.content)
        ctx.restoreGState()
    }

    // The flow disc: pink → violet → blue (ux §3.4) with the white double arrow.
    let discRadius = plate.width * (small ? 0.24 : 0.2)
    let disc = CGPoint(x: plate.midX, y: plate.minY + plate.height * 0.24)
    let circle = CGRect(x: disc.x - discRadius, y: disc.y - discRadius, width: discRadius * 2, height: discRadius * 2)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.025, color: color(0x141628, 0.4))
    ctx.addEllipse(in: circle); ctx.setFillColor(color(video.base)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: circle); ctx.clip()
    ctx.drawLinearGradient(gradient([color(images.base), color(video.base), color(documents.base)], [0, 0.5, 1]),
                           start: CGPoint(x: circle.minX, y: circle.maxY), end: CGPoint(x: circle.maxX, y: circle.minY), options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(color(0xFFFFFF, 0.9)); ctx.setLineWidth(max(s * 0.007, 0.7))
    ctx.strokeEllipse(in: circle.insetBy(dx: s * 0.0035, dy: s * 0.0035))
    doubleArrow(ctx, disc, discRadius * 0.52, lineWidth: discRadius * (small ? 0.2 : 0.15))
    ctx.restoreGState()
    return png(ctx)
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! renderIcon(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
print("Rendered the icon into \(out.path)")
