import AppKit
import Foundation
import ImageIO
import PDFKit
import SuperConverterCore
import WebKit

/// HTML as a web page → PDF (`WebKitPrint`) or PNG/JPG (`WebKitSnapshot`) with WebKit offscreen (formats §3.1): a `WKWebView`
/// in a window that is never ordered onto the screen. Printing goes through `NSPrintOperation`, so the PDF is paginated,
/// vector, with selectable text, and honours the page's own `@page` and break rules. Options are O-WEB / O-WEB-SHOT; nothing
/// leaves the Mac unless "Load web resources" is on for the file.
@MainActor
enum WebKitRender {
    struct PrintOptions {
        var paper = "auto"
        var landscape = false
        var zoom = 1.0
        var marginMM = 10.0
        var printBackground = true
        var screenMedia = false
        var headerFooter = false
        var headerTemplate = ""
        var footerTemplate = ""
        var waitUntil = "load"
        var waitForElement = ""
        var waitMS = 0
        var pages = ""
        var loadWebResources = false

        init() {}

        init(_ values: OptionValues) {
            paper = values["pageFormat"]?.string ?? "auto"
            landscape = values["orientation"]?.string == "landscape"
            zoom = values["zoom"]?.double ?? 1
            marginMM = values["margin"]?.double ?? 10
            printBackground = values["printBackground"]?.bool ?? true
            screenMedia = values["cssMedia"]?.string == "screen"
            headerFooter = values["headerFooter"]?.bool ?? false
            headerTemplate = values["headerTemplate"]?.string ?? ""
            footerTemplate = values["footerTemplate"]?.string ?? ""
            waitUntil = values["waitUntil"]?.string ?? "load"
            waitForElement = values["waitForElement"]?.string ?? ""
            waitMS = values["waitTime"]?.int ?? 0
            pages = values["pages"]?.string ?? ""
            loadWebResources = values["loadWebResources"]?.bool ?? false
        }

        /// Paper size in points (portrait).
        var paperSize: NSSize {
            switch paper {
            case "letter": return NSSize(width: 612, height: 792)
            case "legal": return NSSize(width: 612, height: 1008)
            case "tabloid", "ledger": return NSSize(width: 792, height: 1224)
            case "a3": return NSSize(width: 841.89, height: 1190.55)
            case "a5": return NSSize(width: 419.53, height: 595.28)
            case "b5": return NSSize(width: 498.9, height: 708.66)
            case "a4": return NSSize(width: 595.28, height: 841.89)
            default:
                let p = PaperSize.regional
                return NSSize(width: p.width, height: p.height)
            }
        }
    }

    struct SnapshotOptions {
        var width = 1440
        var scale = 2
        var quality = 90
        var waitUntil = "load"
        var waitForElement = ""
        var waitMS = 0
        var loadWebResources = false

        init() {}

        init(_ values: OptionValues) {
            width = values["screenWidth"]?.int ?? 1440
            scale = values["scale"]?.int ?? 2
            quality = values["quality"]?.int ?? 90
            waitUntil = values["waitUntil"]?.string ?? "load"
            waitForElement = values["waitForElement"]?.string ?? ""
            waitMS = values["waitTime"]?.int ?? 0
            loadWebResources = values["loadWebResources"]?.bool ?? false
        }
    }

    // MARK: Print

    static func printPDF(_ page: URL, options: PrintOptions, to output: URL, isCancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        var size = options.paperSize
        if options.landscape { size = NSSize(width: size.height, height: size.width) }
        let session = try await Session(page: page, width: size.width * 96 / 72, height: size.height * 96 / 72, loadWebResources: options.loadWebResources,
                                        screenMedia: options.screenMedia, wait: (options.waitUntil, options.waitForElement, options.waitMS), zoom: options.zoom, isCancelled: isCancelled)
        if options.printBackground {
            _ = try? await session.web.evaluateJavaScript("(function(){var s=document.createElement('style');s.textContent='*{-webkit-print-color-adjust:exact!important;print-color-adjust:exact!important}';document.head.appendChild(s);})()")
        }
        let title = (try? await session.web.evaluateJavaScript("document.title")) as? String ?? ""
        let margin = CGFloat(options.marginMM * 72 / 25.4)
        let info = NSPrintInfo()
        info.paperSize = size
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.jobDisposition = .save
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".print-\(UUID().uuidString).pdf")
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temporary
        let operation = session.web.printOperation(with: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.view?.frame = NSRect(x: 0, y: 0, width: size.width - 2 * margin, height: size.height - 2 * margin)
        let finish = PrintFinish()
        operation.runModal(for: session.window, delegate: finish, didRun: #selector(PrintFinish.didRun(_:success:contextInfo:)), contextInfo: nil)
        let deadline = Date().addingTimeInterval(180)
        while !finish.finished && Date() < deadline {
            if isCancelled() { try? FileManager.default.removeItem(at: temporary); throw ConversionError.cancelled }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard finish.finished, finish.success, let document = PDFDocument(url: temporary), document.pageCount > 0 else {
            throw ConversionError.failed("The page couldn’t be printed.")
        }
        if let range = PageRange.parse(options.pages, count: document.pageCount) {
            for index in (0..<document.pageCount).reversed() where !range.contains(index + 1) { document.removePage(at: index) }
            guard document.pageCount > 0 else { throw ConversionError.failed("None of the chosen pages exist.") }
        }
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: title, PDFDocumentAttribute.creatorAttribute: "Super Converter"]
        if options.headerFooter {
            try PageFurniture.write(document, header: options.headerTemplate, footer: options.footerTemplate, title: title, url: page.absoluteString, to: output, margin: margin)
        } else {
            guard document.write(to: output) else { throw ConversionError.failed("The PDF couldn’t be saved.") }
        }
    }

    private final class PrintFinish: NSObject {
        var finished = false
        var success = false
        @objc func didRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) { finished = true; self.success = success }
    }

    // MARK: Snapshot

    static func snapshot(_ page: URL, options: SnapshotOptions, format: FormatID, to output: URL, isCancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        // Device scale factor n: the page is laid out at the chosen width in CSS pixels, drawn n times larger.
        let scale = CGFloat(max(options.scale, 1))
        let width = CGFloat(max(options.width, 200))
        let session = try await Session(page: page, width: width * scale, height: 800 * scale, loadWebResources: options.loadWebResources, screenMedia: true,
                                        wait: (options.waitUntil, options.waitForElement, options.waitMS), zoom: Double(scale), isCancelled: isCancelled)
        // The whole page: size the view to the document.
        let cssHeight = (try? await session.web.evaluateJavaScript("Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)")) as? Double ?? 800
        let height = CGFloat(min(max(cssHeight, 1), 30_000 / Double(scale))) * scale
        session.window.setContentSize(NSSize(width: width * scale, height: height))
        session.web.frame = NSRect(x: 0, y: 0, width: width * scale, height: height)
        try await Task.sleep(nanoseconds: 100_000_000)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: width * scale, height: height)
        configuration.snapshotWidth = NSNumber(value: Double(width * scale))
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            session.web.takeSnapshot(with: configuration) { image, error in
                if let image { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? ConversionError.failed("The page couldn’t be captured.")) }
            }
        }
        // Whatever the display's own scale, the file is exactly width × scale pixels wide.
        let pixelWidth = Int((width * scale).rounded()), pixelHeight = max(Int(height.rounded()), 1)
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let captured = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ConversionError.failed("The page couldn’t be captured.") }
        context.interpolationQuality = .high
        if format.rawValue != "png" {   // JPEG has no transparency: composite on white
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }
        context.draw(captured, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        guard let result = context.makeImage() else { throw ConversionError.failed("The page couldn’t be captured.") }
        let data = NSMutableData()
        let type = format.rawValue == "png" ? "public.png" : "public.jpeg"
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw ConversionError.failed("The picture couldn’t be saved.") }
        let properties: [CFString: Any] = format.rawValue == "png" ? [:] : [kCGImageDestinationLossyCompressionQuality: Double(options.quality) / 100]
        CGImageDestinationAddImage(destination, result, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("The picture couldn’t be saved.") }
        try (data as Data).write(to: output, options: .atomic)
    }

    // MARK: Session

    /// A loaded page in an offscreen web view.
    private final class Session: NSObject, WKNavigationDelegate {
        let web: WKWebView
        let window: NSWindow
        private var loaded = false
        private var failure: Error?

        init(page: URL, width: CGFloat, height: CGFloat, loadWebResources: Bool, screenMedia: Bool, wait: (until: String, element: String, ms: Int),
             zoom: Double, isCancelled: @escaping @Sendable () -> Bool) async throws {
            _ = NSApplication.shared
            let configuration = WKWebViewConfiguration()
            configuration.suppressesIncrementalRendering = true
            if !loadWebResources {
                // Nothing leaves the Mac: remote requests are blocked before they start.
                let rules = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#
                if let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "block-remote", encodedContentRuleList: rules) {
                    configuration.userContentController.add(list)
                }
            }
            web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
            window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = web
            super.init()
            web.navigationDelegate = self
            if screenMedia { web.mediaType = "screen" }
            if zoom != 1 { web.pageZoom = zoom }
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
            let deadline = Date().addingTimeInterval(60)
            while !loaded && failure == nil && Date() < deadline {
                if isCancelled() { throw ConversionError.cancelled }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if failure != nil || !loaded { throw ConversionError.failed("The page couldn’t be loaded.") }
            // Fonts and pictures settle before anything is drawn.
            _ = try? await web.callAsyncJavaScript("await document.fonts.ready; await Promise.all(Array.from(document.images).map(i => i.complete ? 0 : new Promise(r => { i.onload = i.onerror = r; setTimeout(r, 5000) })));", contentWorld: .page)
            if wait.until.hasPrefix("networkidle") { try await Task.sleep(nanoseconds: 500_000_000) }
            if !wait.element.isEmpty {
                let selector = wait.element.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                let limit = Date().addingTimeInterval(30)
                while Date() < limit, ((try? await web.evaluateJavaScript("document.querySelector('\(selector)') !== null")) as? Bool) != true {
                    if isCancelled() { throw ConversionError.cancelled }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            if wait.ms > 0 { try await Task.sleep(nanoseconds: UInt64(min(wait.ms, 60_000)) * 1_000_000) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error }
    }
}

/// "1-3,5" → {1,2,3,5}; nil for "" (all pages).
enum PageRange {
    static func parse(_ text: String, count: Int) -> Set<Int>? {
        let t = text.trimmed
        guard !t.isEmpty, t.lowercased() != "all" else { return nil }
        var out = Set<Int>()
        for part in t.split(separator: ",") {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmed) }
            if ends.count == 1, let n = ends[0] { out.insert(n) }
            else if ends.count == 2 {
                let lo = ends[0] ?? 1, hi = ends[1] ?? count
                if lo <= hi { for n in lo...min(hi, max(count, lo)) { out.insert(n) } }
            }
        }
        return out.isEmpty ? nil : out
    }
}

/// Running header and footer for printed pages (O-WEB `header_template` / `footer_template`): the classes `date`, `title`,
/// `url`, `pageNumber`, `totalPages` fill in; other markup is dropped. Pages are re-drawn with Core Graphics, so text stays text.
enum PageFurniture {
    @MainActor
    static func write(_ document: PDFDocument, header: String, footer: String, title: String, url: String, to output: URL, margin: CGFloat) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw ConversionError.failed("The PDF couldn’t be saved.") }
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.pageRef else { continue }
            var box = page.getBoxRect(.mediaBox)
            context.beginPage(mediaBox: &box)
            context.drawPDFPage(page)
            func draw(_ template: String, at y: CGFloat) {
                let text = fill(template, date: date, title: title, url: url, page: index + 1, total: document.pageCount)
                guard !text.isEmpty else { return }
                let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.darkGray])
                let line = CTLineCreateWithAttributedString(attributed)
                let width = CTLineGetBoundsWithOptions(line, []).width
                context.textPosition = CGPoint(x: box.midX - width / 2, y: y)
                CTLineDraw(line, context)
            }
            draw(header, at: box.maxY - max(margin * 0.6, 14))
            draw(footer, at: max(margin * 0.4, 10))
            context.endPage()
        }
        context.closePDF()
        try (data as Data).write(to: output, options: .atomic)
    }

    static func fill(_ template: String, date: String, title: String, url: String, page: Int, total: Int) -> String {
        var t = template
        for (cls, value) in [("date", date), ("title", title), ("url", url), ("pageNumber", "\(page)"), ("totalPages", "\(total)")] {
            t = t.replacingOccurrences(of: "<span class=\"\(cls)\"></span>", with: value).replacingOccurrences(of: "<span class='\(cls)'></span>", with: value)
        }
        return t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmed
    }
}
