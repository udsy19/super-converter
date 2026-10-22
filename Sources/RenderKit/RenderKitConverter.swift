import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore
import UniformTypeIdentifiers

/// `RenderKit` steps (formats §6): a PDF's pages, or a VectorDocument's, become an `ImageAsset` with one frame per page at the
/// render density, in the chosen RGB space (ColorSync converts) and tagged with its profile (quality §2.2).
public struct RenderKitConverter: Converter {
    public let id: EngineID = .renderKit

    public var handles: [StepPattern] {
        [StepPattern(from: .formats(["pdf"]), to: .model(.imageAsset)),
         StepPattern(from: .model(.vectorDocument), to: .model(.imageAsset))]
    }

    public init() {}

    public func availability() -> EngineAvailability { .available }

    /// Above this many pixels a frame is written as a PNG in the work folder instead of being held in memory.
    static let inMemoryPixels = 40_000_000

    public func run(_ step: Step, input: StepValue, context: StepContext) async throws -> StepOutput {
        let options = RenderOptions(context.options, isPDF: step.from != .vectorDocument)
        var frames: [ImageFrame] = []
        switch input {
        case .file(let url):
            let document = try PDFPages.open(url, password: context.options["password"]?.string)
            let pages = PageSelection.indices(options.pages, pageCount: document.numberOfPages)
            guard !pages.isEmpty else { throw ConversionError.failed("None of those pages are in this file.") }
            let space = options.space(keeping: PDFPages.outputIntentSpace(document))
            for (n, index) in pages.enumerated() {
                if context.isCancelled() { throw ConversionError.cancelled }
                context.report(StepProgress(fraction: Double(n) / Double(pages.count), unit: "Page \(n + 1) of \(pages.count)"))
                let page = try PDFPages.page(document, at: index)
                let (w, h) = Rasterizer.pixelSize(of: PDFPages.displayedSize(page), dpi: options.dpi, width: options.width, height: options.height)
                let image = try Rasterizer.render(page, width: w, height: h, space: space, transparent: options.alpha)
                frames.append(try frame(image, space: space, options: options, index: n, context: context))
            }
        case .vector(let document):
            let pages = PageSelection.indices(options.pages, pageCount: document.pages.count)
            guard !pages.isEmpty else { throw ConversionError.failed("None of those pages are in this file.") }
            let space = options.space(keeping: nil)
            for (n, index) in pages.enumerated() {
                if context.isCancelled() { throw ConversionError.cancelled }
                context.report(StepProgress(fraction: Double(n) / Double(pages.count), unit: "Page \(n + 1) of \(pages.count)"))
                let page = document.pages[index]
                let size = CGSize(width: page.size.width, height: page.size.height)
                let (w, h) = Rasterizer.pixelSize(of: size, dpi: options.dpi, width: options.width, height: options.height)
                let image = try VectorRasterizer.render(page, width: w, height: h, space: space, transparent: options.alpha)
                frames.append(try frame(image, space: space, options: options, index: n, context: context))
            }
        default:
            throw ConversionError.unsupportedPair(from: context.sourceFormat, to: context.targetFormat)
        }
        context.report(StepProgress(fraction: 1))
        return StepOutput(.image(ImageAsset(frames: frames)))
    }

    private func frame(_ image: CGImage, space: CGColorSpace, options: RenderOptions, index: Int, context: StepContext) throws -> ImageFrame {
        if image.width * image.height > Self.inMemoryPixels {
            let url = context.workFolder.appendingPathComponent("page-\(index + 1).png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ConversionError.failed("A large page couldn’t be saved while converting.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.failed("A large page couldn’t be saved while converting.") }
            return ImageFrame(width: image.width, height: image.height, pixels: .file(url), hasAlpha: options.alpha,
                              iccProfile: space.copyICCData() as Data?)
        }
        guard let frame = ImageFrame(cgImage: image, space: space, hasAlpha: options.alpha) else { throw ConversionError.failed("The page couldn’t be drawn.") }
        return frame
    }
}

/// The O-RENDER / O-IMG+DPI options this engine reads.
struct RenderOptions {
    var pages: String?
    var dpi: Double
    var width: Int?
    var height: Int?
    var alpha: Bool
    /// "srgb", "displayP3", "adobeRGB", "keep"; anything else (grey, CMYK) is drawn in sRGB, which every RGB target takes.
    var profile: String

    init(_ options: OptionValues, isPDF: Bool) {
        pages = options["pages"]?.string
        dpi = min(max(options["pixelDensity"]?.double ?? (isPDF ? 300 : 96), 36), 2400)
        width = options["width"]?.int
        height = options["height"]?.int
        alpha = options["alpha"]?.bool ?? false
        profile = options["colourProfile"]?.string ?? "srgb"
    }

    func space(keeping kept: CGColorSpace?) -> CGColorSpace {
        switch profile {
        case "displayP3": CGColorSpace(name: CGColorSpace.displayP3)!
        case "adobeRGB": CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        case "keep": kept ?? CGColorSpace(name: CGColorSpace.sRGB)!
        default: CGColorSpace(name: CGColorSpace.sRGB)!
        }
    }
}
