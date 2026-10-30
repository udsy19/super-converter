// Renders Super Converter's app icon into a folder, in the Super family's look: a white squircle and one ink glyph. The
// glyph is a conversion at a glance: a rounded square, an arrow, a circle ("this becomes that"). The circle is drawn a
// little larger than the square so the two read as the same size. website/icon.svg carries the same geometry.
//   AppIcon.iconset/   the app icon at every size iconutil needs
// Usage: swift scripts/make-icon.swift <out-folder>
// Adapted from super-paste scripts/make-icon.swift: the squircle, its shadow and field, the ink and the iconset sizes.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iconset = out.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let inset = s * 0.098
    let body = CGRect(x: inset, y: inset * 1.15, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.28))
    ctx.addPath(squircle); ctx.setFillColor(color(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(squircle); ctx.clip()
    let field = CGGradient(colorsSpace: srgb, colors: [color(0xFFFFFF), color(0xEFEFEF)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(field, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

    // Square, arrow, circle along the middle; the group is centred on the plate.
    let b = body.width, side = b * 0.235, disc = side * 1.06, gap = b * 0.045, shaft = b * 0.14
    let total = side + gap + shaft + gap + disc
    let x0 = body.midX - total / 2, cy = body.midY
    let ink = color(0x141414)
    ctx.setFillColor(ink)
    ctx.addPath(CGPath(roundedRect: CGRect(x: x0, y: cy - side / 2, width: side, height: side),
                       cornerWidth: side * 0.2, cornerHeight: side * 0.2, transform: nil))
    ctx.addEllipse(in: CGRect(x: x0 + total - disc, y: cy - disc / 2, width: disc, height: disc))
    ctx.fillPath()

    let tail = CGPoint(x: x0 + side + gap, y: cy), tip = CGPoint(x: tail.x + shaft, y: cy), head = b * 0.052
    ctx.setStrokeColor(ink); ctx.setLineWidth(b * 0.045); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.move(to: tail); ctx.addLine(to: tip)
    ctx.move(to: CGPoint(x: tip.x - head, y: cy + head)); ctx.addLine(to: tip); ctx.addLine(to: CGPoint(x: tip.x - head, y: cy - head))
    ctx.strokePath()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
