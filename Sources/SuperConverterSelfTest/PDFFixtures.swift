import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SuperConverterCore

// PDF fixtures for the LayoutKit, RenderKit and PDFOps checks (WP-L): generated with Quartz and Core Text, so text, rulings,
// pictures and colours are known exactly.

let fixtureSize = CGSize(width: 612, height: 792)

/// Draws `text` with its baseline at (x, y) (PDF space, y up).
@discardableResult
func fixtureText(_ ctx: CGContext, _ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 11, bold: Bool = false, italic: Bool = false) -> CGFloat {
    var name = "Helvetica"
    if bold && italic { name = "Helvetica-BoldOblique" } else if bold { name = "Helvetica-Bold" } else if italic { name = "Helvetica-Oblique" }
    let font = CTFontCreateWithName(name as CFString, size, nil)
    let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
    ctx.textPosition = CGPoint(x: x, y: y)
    let line = CTLineCreateWithAttributedString(attributed)
    CTLineDraw(line, ctx)
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
}

/// Writes a PDF of `pages` drawing closures to a new file in `scratch`.
func fixturePDF(_ name: String = "fixture", userPassword: String? = nil, pages: [(CGContext) -> Void]) -> URL {
    let url = scratch.appendingPathComponent("\(name)-\(UUID().uuidString).pdf")
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    var box = CGRect(origin: .zero, size: fixtureSize)
    var info: [CFString: Any] = [kCGPDFContextTitle: "Fixture"]
    if let userPassword { info[kCGPDFContextUserPassword] = userPassword; info[kCGPDFContextOwnerPassword] = userPassword + "-owner" }
    let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary)!
    for draw in pages { ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage() }
    ctx.closePDF()
    return url
}

/// A page with a heading, two paragraphs (one with bold words and a hyphenated line end), a bullet list, a ruled 3 × 3 table,
/// a picture, a running header and a page number.
func fixtureDocumentPage(_ ctx: CGContext, number: Int) {
    fixtureText(ctx, "Acme Corp quarterly", x: 72, y: 760, size: 9)
    fixtureText(ctx, "\(number)", x: 300, y: 40, size: 10)
    ctx.translateBy(x: 0, y: -24)   // the body sits below the header band
    fixtureText(ctx, "Quarterly Report", x: 72, y: 700, size: 24, bold: true)
    let first = ["The company grew steadily during the quarter and the board is", "pleased with the results, which exceed the forecast in every", "region we operate in, including some new markets."]
    for (i, line) in first.enumerated() { fixtureText(ctx, line, x: 72, y: 660 - CGFloat(i) * 14) }
    let revenue = fixtureText(ctx, "Revenue", x: 72, y: 604, bold: true)
    fixtureText(ctx, "rose by twelve percent over a comparable inter-", x: 72 + revenue + 3.1, y: 604)
    fixtureText(ctx, "national period, driven by subscriptions.", x: 72, y: 590)
    for (i, item) in ["First point", "Second point", "Third point"].enumerated() {
        fixtureText(ctx, "\u{2022}", x: 80, y: 550 - CGFloat(i) * 16)
        fixtureText(ctx, item, x: 96, y: 550 - CGFloat(i) * 16)
    }
    // Table: 3 columns x 3 rows, ruled.
    let xs: [CGFloat] = [72, 192, 312, 432], ys: [CGFloat] = [480, 456, 432, 408]
    ctx.setStrokeColor(gray: 0, alpha: 1); ctx.setLineWidth(0.8)
    for y in ys { ctx.move(to: CGPoint(x: xs[0], y: y)); ctx.addLine(to: CGPoint(x: xs.last!, y: y)) }
    for x in xs { ctx.move(to: CGPoint(x: x, y: ys[0])); ctx.addLine(to: CGPoint(x: x, y: ys.last!)) }
    ctx.strokePath()
    let cells = [["Item", "Qty", "Price"], ["Widget", "4", "1,250.50"], ["Gadget", "10", "99.00"]]
    for (r, row) in cells.enumerated() {
        for (c, text) in row.enumerated() { fixtureText(ctx, text, x: xs[c] + 6, y: ys[r + 1] + 8, bold: r == 0) }
    }
    // Picture: a solid green square drawn as an image.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmap = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    bitmap.setFillColor(CGColor(red: 0, green: 0.6, blue: 0, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
    ctx.draw(bitmap.makeImage()!, in: CGRect(x: 72, y: 280, width: 160, height: 100))
    fixtureText(ctx, "Figure 1. Growth by region", x: 72, y: 264, size: 9)
}

/// A page with a red rectangle at (100, 600)–(200, 700) on white.
func fixtureRedRectPage(_ ctx: CGContext) {
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 100, y: 600, width: 100, height: 100))
}

/// The RGBA bytes of an ImageFrame (8-bit).
func fixtureBytes(_ frame: ImageFrame) -> [UInt8]? {
    if case .rgba8(let data, _) = frame.pixels { return [UInt8](data) }
    return nil
}

/// RGBA at pixel (x, y) counted from the top-left.
func fixturePixel(_ frame: ImageFrame, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int)? {
    guard let bytes = fixtureBytes(frame), case .rgba8(_, let stride) = frame.pixels else { return nil }
    let i = y * stride + x * 4
    return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
}

/// A step's engine runs once; returns the output or nil after recording a failure.
@MainActor
func fixtureRun(_ converter: any Converter, from: StepEndpoint, to: StepEndpoint, input: StepValue, options: OptionValues = OptionValues(),
                workFolder: URL? = nil, expectingFailure: Bool = false) -> StepOutput? {
    let folder = workFolder ?? scratch.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var source = scratch
    if case .file(let url) = input { source = url }
    let context = StepContext(workFolder: folder, source: source, sourceFormat: "pdf", targetFormat: "pdf", options: options)
    let step = Step(converter.id, from, to)
    switch complete(300, { try await converter.run(step, input: input, context: context) }) {
    case .success(let output)?: return output
    case .failure(let error)?:
        if !expectingFailure { check(false, "\(converter.id) \(from) → \(to) failed: \(error)") }
        return nil
    case nil: check(false, "\(converter.id) timed out"); return nil
    }
}
