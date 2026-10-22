import CoreGraphics
import Foundation
import SuperConverterCore

// Origin: Super PDF Sources/ConvertKit/Import/PresentationImporter.swift @ 058469b (`SlideRenderer`), adapted: the PDF is
// returned as loss notes instead of an import report, cancellation is cooperative, hidden slides can be kept.

/// Draws slides into a PDF, one page per slide at the slide's own size (quality §4).
final class SlideRenderer {
    let deck: SlideDeck

    init(deck: SlideDeck) { self.deck = deck }

    /// Writes the PDF; `includeHidden` keeps slides marked hidden (`hidden_slides`), `slideNumbers` limits it to those
    /// slides (1-based). Returns the loss notes.
    func write(to output: URL, includeHidden: Bool = false, slideNumbers: Set<Int>? = nil, isCancelled: () -> Bool = { false },
               progress: (Int, Int) -> Void = { _, _ in }) throws -> [LossNote] {
        var slides: [(part: SlidePart, number: Int)] = []
        for (index, path) in deck.slidePaths.enumerated() {
            guard let part = try deck.part(path), part.root.name == "sld" else { continue }
            if let slideNumbers, !slideNumbers.contains(index + 1) { continue }
            if !includeHidden, let show = part.root.attr("show"), ["0", "false", "off"].contains(show) { continue }
            slides.append((part, index + 1))
        }
        guard !slides.isEmpty else { throw ConversionError.failed("This presentation has no slides to show.") }

        var box = CGRect(origin: .zero, size: deck.size)
        var info: [CFString: Any] = [kCGPDFContextCreator: Strings.appName]
        if let title = deck.title { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(output as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw ConversionError.failed("The PDF couldn’t be created.")
        }
        var leftOut = false
        do {
            for (page, slide) in slides.enumerated() {
                if isCancelled() { throw ConversionError.cancelled }
                progress(page + 1, slides.count)
                context.beginPDFPage(nil)
                context.saveGState()
                context.translateBy(x: 0, y: deck.size.height)
                context.scaleBy(x: 1, y: -1)
                defer {
                    context.restoreGState()
                    context.endPDFPage()
                }
                leftOut = try SlideCanvas(deck: deck, slide: slide.part, number: slide.number, context: context).draw().leftOut || leftOut
            }
        } catch {
            context.closePDF()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        context.closePDF()
        return leftOut ? [LossNote(.otherLoss, detail: "Some charts, diagrams or embedded objects couldn’t be drawn, so they were left out.")] : []
    }
}
