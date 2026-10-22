import Foundation

/// What a source file most likely becomes (ux §6.1). The person's last choice for a source format wins; before that, this
/// table decides.
public enum DefaultTargets {
    /// Facts about one file that change the default.
    public struct Traits: Hashable, Sendable {
        public var hasTransparency = false
        public var isAnimated = false
        /// An Ogg file with a video stream.
        public var hasVideo = false
        public init(hasTransparency: Bool = false, isAnimated: Bool = false, hasVideo: Bool = false) {
            self.hasTransparency = hasTransparency; self.isAnimated = isAnimated; self.hasVideo = hasVideo
        }
    }

    private static func entries(_ sources: [FormatID], _ target: FormatID) -> [(FormatID, FormatID)] {
        sources.map { ($0, target) }
    }

    private static let table: [FormatID: FormatID] = Dictionary([
        entries(["heic", "heif", "jfif", "3fr", "arw", "cr2", "cr3", "crw", "dcr", "dng", "erf", "mos", "mrw", "nef", "orf",
                 "pef", "raf", "raw", "rw2", "x3f"], "jpg"),
        entries(["jpg", "jpeg"], "pdf"),
        entries(["png", "bmp", "tga", "ppm", "ico", "icns", "psd", "psb", "xcf", "tif", "tiff", "avif", "webp", "gif"], "png"),
        entries(["eps", "ps", "cdr", "vsd", "cgm", "sk", "sk1", "xps", "odg", "odd", "pub"], "pdf"),
        entries(["ai"], "svg"),
        entries(["svg", "svgz", "emf", "wmf"], "png"),
        entries(["doc", "docx", "docm", "dot", "dotx", "odt", "rtf", "pages", "wpd", "wps", "lwp", "abw", "zabw", "hwp", "hwpx",
                 "sdw", "md", "txt", "rst", "tex", "html", "djvu", "eml"], "pdf"),
        entries(["pdf"], "docx"),
        entries(["xls", "xlsm", "ods", "numbers", "et", "sdc", "csv"], "xlsx"),
        entries(["xlsx"], "pdf"),
        entries(["ppt", "pps", "ppsx", "pot", "potx", "pptm", "odp", "key", "dps", "sda"], "pptx"),
        entries(["pptx"], "pdf"),
        entries(["epub", "cbz", "cbr", "cbc", "chm", "azw4"], "pdf"),
        entries(["mobi", "azw", "azw3", "prc", "pdb", "lit", "lrf", "fb2", "htmlz", "txtz", "pml", "rb", "snb", "tcr", "oeb", "htm"], "epub"),
        entries(["mov", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "m2ts", "mts", "ts", "vob", "3gp", "3gpp", "3g2", "mxf",
                 "dv", "ogv", "rm", "rmvb", "swf", "wtv", "dvr", "mod", "cavs"], "mp4"),
        entries(["mp4", "m4v"], "mp3"),
        entries(["wav", "aiff", "aif", "aifc", "flac", "m4a", "m4b", "oga", "opus", "weba", "wma", "amr", "ac3", "au", "caf", "voc",
                 "dss", "aac"], "mp3"),
        entries(["mp3"], "wav"),
        entries(["sf2"], "zip"),
        entries(["sfark"], "sf2"),
        entries(["rar", "7z", "tar", "tar.7z", "tar.bz", "tar.bz2", "tar.gz", "tar.lzo", "tar.xz", "tar.z", "tbz", "tbz2", "tgz",
                 "tz", "tzo", "gz", "bz", "bz2", "xz", "lz", "lzma", "z", "lzo", "rz", "cab", "arj", "lha", "ace", "alz", "arc", "cpio",
                 "deb", "rpm", "iso", "img", "dmg", "jar"], "zip"),
        entries(["zip"], "7z"),
        entries(["dwg", "dxf", "dwf"], "pdf"),
        entries(["ttf", "otf"], "woff2"),
        entries(["woff", "woff2", "eot"], "ttf"),
        entries(["ogg"], "mp3"),
    ].flatMap { $0 }, uniquingKeysWith: { first, _ in first })

    /// The default target for a source format.
    /// - Parameters:
    ///   - remembered: the target the person chose last for this source format; wins when it is still offered.
    public static func target(for source: FormatID, traits: Traits = Traits(), remembered: FormatID? = nil) -> FormatID? {
        if let remembered, FormatMatrix.route(from: source, to: remembered)?.isOffered == true { return remembered }
        guard let target = table[source] else { return nil }
        switch source.rawValue {
        case "gif": return traits.isAnimated ? "mp4" : "png"
        case "webp", "avif": return traits.hasTransparency ? "png" : "jpg"
        case "ogg": return traits.hasVideo ? "mp4" : "mp3"
        case "png": return "jpg"   // ux §6.1 lists PNG among the sources that become PNG; a PNG becomes a JPG
        default: return target
        }
    }

    /// Every source format that has a default.
    public static var sources: [FormatID] { Array(table.keys).sorted() }
}
