import Foundation
import SuperConverterCore

/// Queue classes and how many jobs of each run at once (ux §6.4): video encodes 1 at a time (2 on Macs with two media
/// engines), audio 4, images and documents up to the number of performance cores, archives 2, one job per helper.
public struct ConcurrencyLimits: Sendable {
    public var video: Int
    public var audio: Int
    public var image: Int
    public var document: Int
    public var archive: Int
    public var perHelper: Int

    public init(video: Int = ConcurrencyLimits.mediaEngines, audio: Int = 4, image: Int = ConcurrencyLimits.performanceCores,
                document: Int = ConcurrencyLimits.performanceCores, archive: Int = 2, perHelper: Int = 1) {
        self.video = video; self.audio = audio; self.image = image; self.document = document
        self.archive = archive; self.perHelper = perHelper
    }

    public func limit(for kind: ConcurrencyClass) -> Int {
        max(1, {
            switch kind {
            case .video: video
            case .audio: audio
            case .image: image
            case .document: document
            case .archive: archive
            case .helper: perHelper
            }
        }())
    }

    /// Performance cores (Apple silicon), else all active cores.
    public static var performanceCores: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Media engines: Pro/Max/Ultra chips have two or more hardware encoders; the brand string says which.
    public static var mediaEngines: Int {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let brand = String(cString: buffer)
        return brand.contains("Pro") || brand.contains("Max") || brand.contains("Ultra") ? 2 : 1
    }

    /// The class a conversion belongs to: by the side of the pair that is video or audio, else by what is converted.
    public static func concurrencyClass(from: FormatID, to: FormatID) -> ConcurrencyClass {
        let categories = [from, to].compactMap { FormatCatalog.format($0)?.category }
        if categories.contains(.video) { return .video }
        if categories.contains(.audio) { return .audio }
        if categories.contains(.archive) { return .archive }
        return categories.first == .image && categories.allSatisfy({ $0 == .image || $0 == .vector }) ? .image : .document
    }
}
