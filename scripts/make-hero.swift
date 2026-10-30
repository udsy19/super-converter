// Draws docs/images/hero.png, the README's hero, laid out like Super Paste's: the icon and name, the line, and the real window
// render the self-tests write (SUPERCONVERTER_RENDER_DIR=<dir> swift run SuperConverterSelfTest gives window-cards.png).
// Usage: swift scripts/make-hero.swift <icon_512x512.png from make-icon.swift> <window-cards.png> docs/images/hero.png
import AppKit
let a = CommandLine.arguments
let icon = NSImage(contentsOfFile: a[1])!, window = NSImage(contentsOfFile: a[2])!
let W = 2400, H = 1260
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.rounded)!, size: size) ?? base
}
let ink = NSColor(srgbRed: 0x16/255, green: 0x17/255, blue: 0x1C/255, alpha: 1)
let grey = NSColor(srgbRed: 0x63/255, green: 0x67/255, blue: 0x74/255, alpha: 1)
let light = NSColor(srgbRed: 0x9A/255, green: 0x9E/255, blue: 0xAA/255, alpha: 1)
let H2 = CGFloat(H)
icon.draw(in: NSRect(x: 128, y: H2 - 128 - 92, width: 92, height: 92))
("Super Converter" as NSString).draw(at: NSPoint(x: 240, y: H2 - 128 - 66), withAttributes: [.font: rounded(44, .bold), .foregroundColor: ink])
let tag = "Free · open source · macOS 14+" as NSString
let tagAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: light]
tag.draw(at: NSPoint(x: CGFloat(W) - 144 - tag.size(withAttributes: tagAttrs).width, y: H2 - 128 - 60), withAttributes: tagAttrs)
let head = NSMutableAttributedString(string: "Drop any file. ", attributes: [.font: rounded(128, .heavy), .foregroundColor: ink, .kern: -2])
head.append(NSAttributedString(string: "Get any format.", attributes: [.font: rounded(128, .medium), .foregroundColor: grey, .kern: -2]))
head.draw(at: NSPoint(x: 140, y: H2 - 430))
let line = "212 formats, converted on your Mac: photos, video, audio, documents, e-books,\narchives, fonts and CAD. No upload, no account." as NSString
let para = NSMutableParagraphStyle(); para.lineSpacing = 10
line.draw(in: NSRect(x: 146, y: H2 - 600, width: 2200, height: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 44), .foregroundColor: grey, .paragraphStyle: para])
// The window, cropped at the bottom edge, on a soft shadow with rounded corners.
let width = CGFloat(W) - 288
let height = width * window.size.height / window.size.width
let frame = NSRect(x: 144, y: H2 - 660 - height, width: width, height: height)
let clip = NSBezierPath(roundedRect: frame, xRadius: 28, yRadius: 28)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowBlurRadius = 40; shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.shadowColor = NSColor(white: 0, alpha: 0.16); shadow.set()
NSColor.white.setFill(); clip.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState(); clip.addClip(); window.draw(in: frame); NSGraphicsContext.restoreGraphicsState()
NSColor(white: 0, alpha: 0.10).setStroke(); clip.lineWidth = 2; clip.stroke()
NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
