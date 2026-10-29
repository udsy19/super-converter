import AppKit
import SuperConverterCore
import VectorKit

func registerVectorKitSVGTests() {
    SelfTest.cases.append(("VectorKit.svg.shapes", {
        let svg = svtSVG("""
        <rect x="10" y="10" width="40" height="30" fill="#ff0000"/>
        <circle cx="70" cy="70" r="20" fill="rgb(0,0,255)"/>
        <ellipse cx="25" cy="75" rx="15" ry="8" style="fill:lime"/>
        <polygon points="60,5 95,5 95,30" fill="orange"/>
        <line x1="5" y1="95" x2="95" y2="95" stroke="black" stroke-width="4"/>
        <path d="M 10 50 h 20 v 10 z" fill="purple"/>
        """)
        guard let result = try? SVGReader.read(svg), let bmp = svtRender(result.document) else { check(false, "svg shapes parse"); return }
        svtSave(VectorDrawing.render(result.document.pages[0], scale: 4.0 / 3.0), "svg-shapes")
        check(result.document.pages[0].size == VectorSize(width: 75, height: 75), "svg page size in points")
        check(bmp.near(30, 25, 255, 0, 0), "red rect")
        check(bmp.near(70, 70, 0, 0, 255), "blue circle")
        check(bmp.near(25, 75, 0, 255, 0), "lime ellipse via style")
        check(bmp.near(90, 10, 255, 165, 0), "orange polygon")
        check(bmp.near(50, 95, 0, 0, 0), "stroked line")
        check(bmp.near(26, 53, 128, 0, 128), "purple path")
        check(bmp.near(5, 5, 255, 255, 255), "background white")
        check(bmp.near(70, 25, 255, 255, 255), "no fill leak")
    }))

    SelfTest.cases.append(("VectorKit.svg.cascade", {
        let svg = svtSVG("""
        <style>.a { fill: #00ff00 } rect#b { fill: #0000ff } g > .c { fill: #ff00ff }</style>
        <rect class="a" x="0" y="0" width="30" height="30"/>
        <rect id="b" class="a" x="40" y="0" width="30" height="30"/>
        <g><rect class="c" x="0" y="40" width="30" height="30"/></g>
        <rect class="a" style="fill:#ff0000" x="40" y="40" width="30" height="30" fill="#000000"/>
        <g fill="#808080" transform="translate(70 70)"><rect width="30" height="30"/></g>
        """)
        guard let result = try? SVGReader.read(svg), let bmp = svtRender(result.document) else { check(false, "svg cascade parse"); return }
        check(bmp.near(15, 15, 0, 255, 0), "class rule")
        check(bmp.near(55, 15, 0, 0, 255), "id beats class")
        check(bmp.near(15, 55, 255, 0, 255), "child combinator")
        check(bmp.near(55, 55, 255, 0, 0), "style attribute beats rules")
        check(bmp.near(85, 85, 128, 128, 128), "inherited fill and translate")
    }))

    SelfTest.cases.append(("VectorKit.svg.transformsEvenOddStroke", {
        let svg = svtSVG("""
        <path d="M50 5 L81 95 L5 38 L95 38 L19 95 Z" fill="#000000" fill-rule="evenodd"/>
        <rect x="-10" y="-5" width="20" height="10" fill="red" transform="translate(80 15) rotate(90) scale(1 2)"/>
        """)
        guard let result = try? SVGReader.read(svg), let bmp = svtRender(result.document) else { check(false, "svg star parse"); return }
        check(bmp.near(50, 50, 255, 255, 255), "even-odd hole in the star centre")
        check(bmp.near(50, 15, 0, 0, 0), "star arm filled")
        check(bmp.near(80, 15, 255, 0, 0), "rotated scaled rect")
        check(bmp.near(80, 3, 255, 255, 255), "rotated rect extent")
        let wide = svtSVG("<rect x='10' y='10' width='80' height='80' fill='none' stroke='#0000ff' stroke-width='10' stroke-dasharray='20 10' stroke-linejoin='round'/>")
        guard let r2 = try? SVGReader.read(wide), let b2 = svtRender(r2.document) else { check(false, "stroke parse"); return }
        check(b2.near(20, 10, 0, 0, 255), "dash on")
        check(b2.near(35, 10, 255, 255, 255), "dash gap")
        check(b2.near(50, 50, 255, 255, 255), "unfilled interior")
    }))

    SelfTest.cases.append(("VectorKit.svg.gradientsClipUse", {
        let svg = svtSVG("""
        <defs>
          <linearGradient id="lg" x1="0" x2="1"><stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient>
          <radialGradient id="rg"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#000000"/></radialGradient>
          <clipPath id="cp"><circle cx="75" cy="25" r="15"/></clipPath>
          <rect id="u" width="10" height="10" fill="#00aa00"/>
          <symbol id="s" viewBox="0 0 10 10"><rect width="10" height="10" fill="#ffaa00"/></symbol>
        </defs>
        <rect x="0" y="0" width="50" height="20" fill="url(#lg)"/>
        <rect x="0" y="30" width="40" height="40" fill="url(#rg)"/>
        <rect x="55" y="0" width="45" height="50" fill="#ff00ff" clip-path="url(#cp)"/>
        <use href="#u" x="60" y="60"/>
        <use xlink:href="#s" x="80" y="80" width="20" height="20"/>
        """)
        guard let result = try? SVGReader.read(svg), let bmp = svtRender(result.document) else { check(false, "svg paint parse"); return }
        svtSave(VectorDrawing.render(result.document.pages[0], scale: 4.0 / 3.0), "svg-paint")
        let left = bmp.at(2, 10), right = bmp.at(47, 10)
        check(left.r > 230 && left.b < 25 && right.b > 230 && right.r < 25, "linear gradient runs red to blue")
        check(bmp.near(20, 50, 255, 255, 255, tolerance: 20), "radial centre white")
        check(bmp.at(3, 32).r < 60, "radial edge dark")
        check(bmp.near(75, 25, 255, 0, 255), "clipped inside")
        check(bmp.near(58, 5, 255, 255, 255), "clipped outside")
        check(bmp.near(65, 65, 0, 170, 0), "use")
        check(bmp.near(90, 90, 255, 170, 0), "use of symbol with viewBox")
    }))

    SelfTest.cases.append(("VectorKit.svg.patternsSkewClipNested", {
        let svg = svtSVG("""
        <defs>
          <pattern id="p" width="10" height="10" patternUnits="userSpaceOnUse"><rect width="5" height="5" fill="#ff0000"/><rect x="5" y="5" width="5" height="5" fill="#0000ff"/></pattern>
          <clipPath id="empty"></clipPath>
          <linearGradient id="g" x1="0" x2="1"><stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient>
        </defs>
        <rect x="0" y="0" width="40" height="40" fill="url(#p)"/>
        <rect x="50" y="0" width="30" height="30" fill="#00ff00" clip-path="url(#empty)"/>
        <g transform="translate(0 50) scale(3 1)"><rect x="0" y="0" width="20" height="20" fill="url(#g)" stroke="#000" stroke-width="2"/></g>
        <svg x="70" y="60" width="20" height="20" viewBox="0 0 10 10"><rect width="10" height="10" fill="#ff8800"/><circle cx="20" cy="5" r="4" fill="#000"/></svg>
        """)
        guard let result = try? SVGReader.read(svg), let bmp = svtRender(result.document) else { check(false, "svg pattern parse"); return }
        svtSave(VectorDrawing.render(result.document.pages[0], scale: 4.0 / 3.0), "svg-pattern")
        check(bmp.near(2, 2, 255, 0, 0) && bmp.near(7, 7, 0, 0, 255) && bmp.near(7, 2, 255, 255, 255), "pattern tiles")
        check(bmp.near(35, 35, 0, 0, 255) || bmp.near(32, 32, 255, 0, 0), "pattern covers the shape")
        check(bmp.near(65, 15, 255, 255, 255) && bmp.near(60, 20, 255, 255, 255), "empty clip path hides the element")
        let l = bmp.at(5, 65), r = bmp.at(55, 65)
        check(l.r > 200 && r.b > 200, "gradient under a non-uniform scale runs across the stretched box")
        check(bmp.near(80, 70, 255, 136, 0), "nested svg viewport")
        check(bmp.near(92, 70, 255, 255, 255, tolerance: 4) || bmp.near(95, 70, 255, 255, 255, tolerance: 4), "nested svg clips its content")
    }))

    SelfTest.cases.append(("VectorKit.svg.textImageMarkerMask", {
        let png = ImageBridgeFixture.redPNGBase64
        let svg = svtSVG("""
        <defs>
          <marker id="m" markerWidth="4" markerHeight="4" refX="2" refY="2" orient="auto"><rect width="4" height="4" fill="#00ff00"/></marker>
          <linearGradient id="fade"><stop offset="0" stop-color="#000"/><stop offset="1" stop-color="#fff"/></linearGradient>
          <mask id="mk"><rect x="0" y="60" width="50" height="40" fill="url(#fade)"/></mask>
        </defs>
        <text x="5" y="30" font-family="Helvetica" font-size="24" fill="#000000">Hi</text>
        <image x="60" y="5" width="30" height="20" href="data:image/png;base64,\(png)"/>
        <path d="M10 50 L50 50" stroke="#000" stroke-width="2" marker-end="url(#m)"/>
        <rect x="0" y="60" width="50" height="40" fill="#0000ff" mask="url(#mk)"/>
        """)
        guard let result = try? SVGReader.read(svg), let bmp = svtRender(result.document) else { check(false, "svg misc parse"); return }
        svtSave(VectorDrawing.render(result.document.pages[0], scale: 4.0 / 3.0), "svg-misc")
        var textRuns = 0
        for n in result.document.pages[0].nodes { if case .text(let run) = n { textRuns += 1; check(run.text == "Hi", "text content kept") } }
        check(textRuns == 1, "text stays text")
        var dark = 0
        for y in 8..<32 { for x in 5..<30 where bmp.at(x, y).r < 100 { dark += 1 } }
        check(dark > 30, "text drawn")
        check(bmp.near(75, 15, 255, 0, 0), "embedded PNG")
        check(bmp.near(50, 50, 0, 255, 0), "marker at path end")
        check(bmp.at(5, 80).r > 200, "mask hides left side")
        check(bmp.at(48, 80).r < 60 && bmp.at(48, 80).b > 150, "mask shows right side")
    }))

    SelfTest.cases.append(("VectorKit.svg.robustness", {
        check((try? SVGReader.read(Data("not xml".utf8))) == nil, "garbage rejected")
        check((try? SVGReader.read(Data("<html/>".utf8))) == nil, "non-svg root rejected")
        let svg = svtSVG("<path d='M10 10 L 50 abc 90 90' stroke='black'/><rect width='-5' height='5'/><use href='#loop'/><g id='loop'><use href='#loop'/></g>")
        check((try? SVGReader.read(svg)) != nil, "bad path data and reference loops survive")
        var deep = "<g>"
        for _ in 0..<300 { deep += "<g>" }
        deep += String(repeating: "</g>", count: 301)
        _ = try? SVGReader.read(svtSVG(deep))
        let flagged = try? SVGReader.read(svtSVG("<foreignObject width='10' height='10'/><rect width='10' height='10' filter='url(#f)'/>"))
        check(flagged?.warnings.contains("foreignObject") == true && flagged?.warnings.contains("filter") == true, "unsupported features are reported")
    }))

    SelfTest.cases.append(("VectorKit.svg.writerRoundTrip", {
        let svg = svtSVG("""
        <defs><linearGradient id="lg" x1="0" x2="1"><stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient></defs>
        <rect x="5" y="5" width="50" height="30" fill="url(#lg)" stroke="#00aa00" stroke-width="3" stroke-linejoin="round"/>
        <g transform="translate(60 60) rotate(30)" opacity="0.5"><circle r="15" fill="#ff8800"/></g>
        <path d="M5 60 Q 30 40 50 90" fill="none" stroke="#000" stroke-width="2" stroke-dasharray="4 2"/>
        <text x="8" y="75" font-family="Helvetica" font-size="12">Round trip</text>
        """)
        guard let first = try? SVGReader.read(svg), let written = try? SVGWriter.write(first.document, options: VectorWriteOptions()),
              let again = try? SVGReader.read(written.data), let a = svtRender(first.document), let b = svtRender(again.document) else {
            check(false, "svg round trip"); return
        }
        svtSave(VectorDrawing.render(again.document.pages[0], scale: 4.0 / 3.0), "svg-roundtrip")
        check(a.meanDifference(b) < 0.8, "svg → svg render difference \(a.meanDifference(b))")
        check(a.mismatch(b) < 0.01, "svg → svg mismatching pixels \(a.mismatch(b))")
        check(again.document.pages[0].size == first.document.pages[0].size, "size survives")
        check(String(decoding: written.data, as: UTF8.self).contains(">Round trip</text>"), "text stays text in the output")
        let outlined = try? SVGWriter.write(first.document, options: VectorWriteOptions(textAsOutlines: true))
        check(outlined.map { !String(decoding: $0.data, as: UTF8.self).contains("<text") && $0.lossNotes.contains { $0.kind == .textAsOutlines } } == true, "text as outlines option")
    }))
}

enum ImageBridgeFixture {
    /// A 2×2 solid red PNG.
    static var redPNGBase64: String {
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill(); rect.fill(); return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!.base64EncodedString()
    }
}
