import CoreGraphics
import Foundation
import PDFKit
import SuperConverterCore
import RenderKit

// RenderKit's checks (WP-L): pages are generated with Quartz and the rendered pixels are read back; the PDF/A writer's output
// goes through the verifier.

@MainActor
private func render(_ url: URL, options: OptionValues = OptionValues()) -> ImageAsset? {
    guard case .image(let asset)? = fixtureRun(RenderKitConverter(), from: "pdf", to: .imageAsset, input: .file(url), options: options)?.value else {
        check(false, "render produced no image"); return nil
    }
    return asset
}

func registerRenderKitTests() {
    SelfTest.cases.append(("RenderKit.pageSelection", {
        check(PageSelection.indices("", pageCount: 3) == [0, 1, 2], "empty selects all")
        check(PageSelection.indices("1-2,5", pageCount: 5) == [0, 1, 4], "ranges and singles")
        check(PageSelection.indices("3-", pageCount: 5) == [2, 3, 4] && PageSelection.indices("-2", pageCount: 5) == [0, 1], "open ranges")
        check(PageSelection.indices("2,2,9", pageCount: 3) == [1], "no repeats, clamped")
        check(PageSelection.indices("x", pageCount: 3).isEmpty, "garbage selects nothing")
    }))

    SelfTest.cases.append(("RenderKit.damagedPageSizes", {
        // A damaged document's page can be NaN, infinite or astronomically large: sizing must not trap, and the raster is refused.
        for size in [CGSize(width: CGFloat.nan, height: 100), CGSize(width: CGFloat.infinity, height: 1e300), CGSize(width: 1e30, height: -1e30)] {
            let (w, h) = Rasterizer.pixelSize(of: size, dpi: 600, width: nil, height: nil)
            check((1...1_000_000).contains(w) && (1...1_000_000).contains(h), "\(size) sizes to \(w) x \(h)")
            check(w * h <= Rasterizer.maxPixels || (try? Rasterizer.bitmapContext(width: w, height: h, space: CGColorSpace(name: CGColorSpace.sRGB)!)) == nil,
                  "an oversized raster is refused")
        }
    }))

    SelfTest.cases.append(("RenderKit.rendersAtRequestedDPI", {
        let pdf = fixturePDF(pages: [fixtureRedRectPage, fixtureRedRectPage])
        guard let one = render(pdf, options: OptionValues(["pixelDensity": 72, "pages": "2"])) else { return }
        check(one.frames.count == 1, "one page selected")
        guard let frame = one.frames.first else { return }
        check(frame.width == 612 && frame.height == 792, "72 dpi is 612 x 792, got \(frame.width) x \(frame.height)")
        // Rect spans x 100–200, y 600–700 (up): top-left rows 92–192.
        let inside = fixturePixel(frame, 150, 142), outside = fixturePixel(frame, 400, 400)
        check(inside.map { $0.r > 240 && $0.g < 60 && $0.b < 20 && $0.a == 255 } == true, "red inside \(String(describing: inside))")
        check(outside.map { $0.r == 255 && $0.g == 255 && $0.b == 255 } == true, "white outside")
        check(frame.iccProfile == CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData() as Data?, "tagged sRGB")
        guard let big = render(pdf, options: OptionValues(["pixelDensity": 144, "pages": "1"])) else { return }
        check(big.frames.first?.width == 1224 && big.frames.first?.height == 1584, "144 dpi doubles the pixels")
        guard let fitted = render(pdf, options: OptionValues(["width": 306, "pages": "1"])) else { return }
        check(fitted.frames.first?.width == 306 && fitted.frames.first?.height == 396, "width keeps the aspect")
    }))

    SelfTest.cases.append(("RenderKit.transparencyAndProfiles", {
        let pdf = fixturePDF(pages: [fixtureRedRectPage])
        guard let clear = render(pdf, options: OptionValues(["pixelDensity": 72, "alpha": true])), let f = clear.frames.first else { return }
        check(f.hasAlpha && fixturePixel(f, 400, 400)?.a == 0, "background transparent")
        check(fixturePixel(f, 150, 142).map { $0.r > 240 && $0.a == 255 } == true, "rectangle opaque")
        guard let p3 = render(pdf, options: OptionValues(["pixelDensity": 72, "colourProfile": "displayP3"])), let g = p3.frames.first else { return }
        check(g.iccProfile != nil && g.iccProfile != CGColorSpace(name: CGColorSpace.sRGB)!.copyICCData() as Data?, "Display P3 profile attached")
        // Pure sRGB red is inside P3's gamut but not its red primary: the P3 pixel is a less saturated number.
        check(fixturePixel(g, 150, 142).map { $0.r > 200 && $0.g < 120 } == true, "P3 pixel values differ yet stay red-ish")
    }))

    SelfTest.cases.append(("RenderKit.lockedFile", {
        let pdf = fixturePDF(userPassword: "secret", pages: [fixtureRedRectPage])
        let context = StepContext(workFolder: scratch, source: pdf, sourceFormat: "pdf", targetFormat: "png")
        let step = Step(.renderKit, "pdf", .imageAsset)
        let locked = complete(300, { try await RenderKitConverter().run(step, input: .file(pdf), context: context) })
        if case .failure(let error)? = locked { check((error as? ConversionError) == .passwordRequired("pdf"), "asks for the password, got \(error)") }
        else { check(false, "should fail without the password") }
        check(render(pdf, options: OptionValues(["password": "secret", "pixelDensity": 36])) != nil, "opens with the password")
    }))

    SelfTest.cases.append(("RenderKit.rendersVectorDocument", {
        let blue = VectorColour(red: 0, green: 0, blue: 1)
        let rect: [PathSegment] = [.move(VectorPoint(10, 10)), .line(VectorPoint(60, 10)), .line(VectorPoint(60, 60)), .line(VectorPoint(10, 60)), .close]
        let page = VectorPage(size: VectorSize(width: 100, height: 100), nodes: [
            .path(rect, fill: .solid(blue), stroke: nil),
            .group([.path([.move(VectorPoint(70, 70)), .line(VectorPoint(95, 70)), .line(VectorPoint(95, 95)), .line(VectorPoint(70, 95)), .close],
                          fill: .solid(VectorColour(red: 1, green: 0, blue: 0)), stroke: nil)],
                   transform: .identity, clip: nil, opacity: 0.5),
        ])
        guard let out = fixtureRun(RenderKitConverter(), from: .vectorDocument, to: .imageAsset, input: .vector(VectorDocument(pages: [page])),
                                   options: OptionValues(["pixelDensity": 144])), case .image(let asset) = out.value, let f = asset.frames.first else {
            check(false, "no vector render"); return
        }
        check(f.width == 200 && f.height == 200, "100 pt at 144 dpi is 200 px")
        // Blue square: x 10–60 pt, y 10–60 pt up → pixel (70, 130) from top-left at 2 px/pt.
        check(fixturePixel(f, 70, 130).map { $0.b > 240 && $0.r < 15 } == true, "blue fill")
        // Half-transparent red over white is pink.
        check(fixturePixel(f, 165, 25).map { $0.r > 240 && $0.g > 100 && $0.g < 160 } == true, "group opacity \(String(describing: fixturePixel(f, 165, 25)))")
    }))

    SelfTest.cases.append(("RenderKit.pdfAWriterAndVerifier", {
        let pdf = fixturePDF(pages: [{ fixtureDocumentPage($0, number: 1) }])
        let plain = (try? PDFPages.open(pdf)).map(PDFAVerifier.verify) ?? []
        check(plain.contains { $0.rule == "metadata" } && plain.contains { $0.rule == "output-intent" }, "a plain PDF is flagged")
        let out = scratch.appendingPathComponent("a-\(UUID().uuidString).pdf")
        do { try PDFOutput.writePDFA(pdf, to: out) } catch { check(false, "PDF/A write: \(error)"); return }
        let problems = (try? PDFPages.open(out)).map(PDFAVerifier.verify) ?? [PDFAProblem(rule: "open", message: "", pages: [])]
        check(problems.isEmpty, "PDF/A output verifies, found \(problems.map(\.rule))")
        let text = PDFDocument(url: out)?.string ?? ""
        check(text.contains("Quarterly Report"), "text survives as text")
    }))
}
