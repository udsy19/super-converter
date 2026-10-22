import Foundation

/// One signature of the sniffer's table (ux §6.2): bytes at an offset mean this format. The sniffer (ConvertKit) reads the
/// first `MagicTable.headerLength` bytes of a file, tries the rules in order, and for ZIP containers looks at the entries.
public struct MagicRule: Hashable, Sendable {
    public let format: FormatID
    public let offset: Int
    public let bytes: [UInt8]
    /// Also required: more bytes at other offsets (RIFF forms, ISO base media brands).
    public let also: [Also]
    /// The signature is shared by many formats of one container (TIFF-based RAW, OLE); the extension decides among
    /// `family` when it is one of them, else `format` is the answer.
    public let family: [FormatID]

    public struct Also: Hashable, Sendable {
        public let offset: Int
        public let bytes: [UInt8]
        public init(_ offset: Int, _ bytes: [UInt8]) { self.offset = offset; self.bytes = bytes }
    }

    public init(_ format: FormatID, at offset: Int = 0, _ bytes: [UInt8], also: [Also] = [], family: [FormatID] = []) {
        self.format = format; self.offset = offset; self.bytes = bytes; self.also = also; self.family = family
    }

    public func matches(_ header: [UInt8]) -> Bool {
        func has(_ at: Int, _ b: [UInt8]) -> Bool { header.count >= at + b.count && Array(header[at..<(at + b.count)]) == b }
        return has(offset, bytes) && also.allSatisfy { has($0.offset, $0.bytes) }
    }
}

/// How a `PK\3\4` file is told apart: the entries it holds, and optionally its `mimetype` file or the content type in
/// `[Content_Types].xml`. Rules are tried in order; the first whose entries are all present (and whose text matches) wins.
public struct ZipRule: Hashable, Sendable {
    public let format: FormatID
    public let requiredEntries: [String]
    /// The exact content of the `mimetype` entry (ODF, EPUB).
    public let mimetype: String?
    /// A substring of the main content type in `[Content_Types].xml` (macro-enabled, template, show variants).
    public let contentType: String?

    public init(_ format: FormatID, entries: [String], mimetype: String? = nil, contentType: String? = nil) {
        self.format = format; self.requiredEntries = entries; self.mimetype = mimetype; self.contentType = contentType
    }
}

public enum MagicTable {
    /// Read this many bytes: the tar signature sits at 257, MOBI at 60, and ISO 9660's "CD001" at 0x8001.
    public static let headerLength = 0x8006

    private static func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// Rules in priority order: the more specific before the more general.
    public static let rules: [MagicRule] = [
        // Documents
        MagicRule("pdf", ascii("%PDF-")),
        MagicRule("rtf", ascii("{\\rtf")),
        MagicRule("djvu", ascii("AT&TFORM")),
        MagicRule("ps", ascii("%!PS-Adobe"), family: ["eps", "ai"]),
        MagicRule("eps", [0xC5, 0xD0, 0xD3, 0xC6]),
        MagicRule("doc", [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1],
                  family: ["doc", "dot", "xls", "ppt", "pps", "pot", "pub", "vsd", "hwp", "wps", "sdw", "sdc", "sda"]),
        MagicRule("hwp", ascii("HWP Document File")),
        MagicRule("abw", ascii("<abiword")),
        MagicRule("html", ascii("<!DOCTYPE html"), family: ["htm"]),
        MagicRule("html", ascii("<html"), family: ["htm"]),
        MagicRule("fb2", ascii("<FictionBook")),
        MagicRule("eml", ascii("Received: ")),
        // Images
        MagicRule("png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        MagicRule("jpg", [0xFF, 0xD8, 0xFF], family: ["jpeg", "jfif"]),
        MagicRule("gif", ascii("GIF87a")),
        MagicRule("gif", ascii("GIF89a")),
        MagicRule("webp", ascii("RIFF"), also: [.init(8, ascii("WEBP"))]),
        MagicRule("heic", at: 4, ascii("ftyp"), also: [.init(8, ascii("heic"))], family: ["heif"]),
        MagicRule("heic", at: 4, ascii("ftyp"), also: [.init(8, ascii("heix"))], family: ["heif"]),
        MagicRule("heif", at: 4, ascii("ftyp"), also: [.init(8, ascii("mif1"))], family: ["heic"]),
        MagicRule("heif", at: 4, ascii("ftyp"), also: [.init(8, ascii("msf1"))], family: ["heic"]),
        MagicRule("avif", at: 4, ascii("ftyp"), also: [.init(8, ascii("avif"))]),
        MagicRule("avif", at: 4, ascii("ftyp"), also: [.init(8, ascii("avis"))]),
        MagicRule("tiff", [0x49, 0x49, 0x2A, 0x00], family: ["tif", "3fr", "arw", "cr2", "dcr", "dng", "erf", "mos", "nef", "orf", "pef", "raw", "rw2"]),
        MagicRule("tiff", [0x4D, 0x4D, 0x00, 0x2A], family: ["tif", "3fr", "arw", "dcr", "dng", "erf", "mos", "nef", "orf", "pef", "raw"]),
        MagicRule("cr3", at: 4, ascii("ftyp"), also: [.init(8, ascii("crx "))]),
        MagicRule("crw", [0x49, 0x49, 0x1A, 0x00, 0x00, 0x00], also: [.init(6, ascii("HEAPCCDR"))]),
        MagicRule("raf", ascii("FUJIFILMCCD-RAW")),
        MagicRule("rw2", [0x49, 0x49, 0x55, 0x00]),
        MagicRule("orf", [0x49, 0x49, 0x52, 0x4F]),
        MagicRule("mrw", [0x00, 0x4D, 0x52, 0x4D]),
        MagicRule("x3f", ascii("FOVb")),
        MagicRule("psd", ascii("8BPS"), also: [.init(4, [0x00, 0x01])]),
        MagicRule("psb", ascii("8BPS"), also: [.init(4, [0x00, 0x02])]),
        MagicRule("xcf", ascii("gimp xcf ")),
        MagicRule("ico", [0x00, 0x00, 0x01, 0x00]),
        MagicRule("icns", ascii("icns")),
        MagicRule("bmp", ascii("BM")),
        MagicRule("ppm", ascii("P6"), family: ["ppm"]),
        // Vector, CAD
        MagicRule("svg", ascii("<svg")),
        MagicRule("svg", ascii("<?xml"), family: ["svg", "xps", "fb2", "html"]),
        MagicRule("emf", at: 40, ascii(" EMF")),
        MagicRule("wmf", [0xD7, 0xCD, 0xC6, 0x9A]),
        MagicRule("wmf", [0x01, 0x00, 0x09, 0x00]),
        MagicRule("cgm", [0x00, 0x20, 0x00]),
        MagicRule("dwg", ascii("AC10")),
        MagicRule("dxf", ascii("  0\nSECTION")),
        MagicRule("dxf", ascii("0\nSECTION")),
        MagicRule("dxf", ascii("AutoCAD Binary DXF")),
        MagicRule("dwf", ascii("(DWF V")),
        // Video
        MagicRule("mkv", [0x1A, 0x45, 0xDF, 0xA3], family: ["webm"]),
        MagicRule("avi", ascii("RIFF"), also: [.init(8, ascii("AVI "))]),
        MagicRule("flv", ascii("FLV"), also: [.init(3, [0x01])]),
        MagicRule("swf", ascii("FWS")),
        MagicRule("swf", ascii("CWS")),
        MagicRule("swf", ascii("ZWS")),
        MagicRule("mov", at: 4, ascii("ftyp"), also: [.init(8, ascii("qt  "))]),
        MagicRule("m4a", at: 4, ascii("ftyp"), also: [.init(8, ascii("M4A "))], family: ["m4b"]),
        MagicRule("m4b", at: 4, ascii("ftyp"), also: [.init(8, ascii("M4B "))]),
        MagicRule("m4v", at: 4, ascii("ftyp"), also: [.init(8, ascii("M4V "))]),
        MagicRule("3gp", at: 4, ascii("ftyp"), also: [.init(8, ascii("3gp"))], family: ["3gpp"]),
        MagicRule("3g2", at: 4, ascii("ftyp"), also: [.init(8, ascii("3g2"))]),
        MagicRule("mp4", at: 4, ascii("ftyp"), family: ["m4v", "mov", "3gp", "3g2"]),
        MagicRule("mpg", [0x00, 0x00, 0x01, 0xBA], family: ["mpeg", "vob", "mod", "dvr"]),
        MagicRule("mpg", [0x00, 0x00, 0x01, 0xB3], family: ["mpeg"]),
        MagicRule("ts", [0x47], also: [.init(188, [0x47])], family: ["m2ts", "mts"]),
        MagicRule("wmv", [0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11], family: ["wma", "dvr", "wtv"]),
        MagicRule("rm", ascii(".RMF"), family: ["rmvb"]),
        MagicRule("mxf", [0x06, 0x0E, 0x2B, 0x34]),
        MagicRule("dv", [0x1F, 0x07, 0x00]),
        MagicRule("ogg", ascii("OggS"), family: ["ogv", "oga", "opus"]),
        // Audio
        MagicRule("mp3", ascii("ID3")),
        MagicRule("mp3", [0xFF, 0xFB]),
        MagicRule("mp3", [0xFF, 0xF3]),
        MagicRule("flac", ascii("fLaC")),
        MagicRule("wav", ascii("RIFF"), also: [.init(8, ascii("WAVE"))]),
        MagicRule("sf2", ascii("RIFF"), also: [.init(8, ascii("sfbk"))]),
        MagicRule("aiff", ascii("FORM"), also: [.init(8, ascii("AIFF"))], family: ["aif"]),
        MagicRule("aifc", ascii("FORM"), also: [.init(8, ascii("AIFC"))]),
        MagicRule("au", ascii(".snd")),
        MagicRule("caf", ascii("caff")),
        MagicRule("voc", ascii("Creative Voice File")),
        MagicRule("amr", ascii("#!AMR")),
        MagicRule("ac3", [0x0B, 0x77]),
        MagicRule("aac", [0xFF, 0xF1]),
        MagicRule("aac", [0xFF, 0xF9]),
        MagicRule("sfark", ascii("sfArk")),
        // Books
        MagicRule("mobi", at: 60, ascii("BOOKMOBI"), family: ["azw", "azw3", "prc"]),
        MagicRule("lit", ascii("ITOLITLS")),
        MagicRule("chm", ascii("ITSF")),
        // Archives
        MagicRule("rar", ascii("Rar!"), also: [.init(4, [0x1A, 0x07])]),
        MagicRule("7z", [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]),
        MagicRule("gz", [0x1F, 0x8B], family: ["tar.gz", "tgz", "svgz"]),
        MagicRule("bz2", ascii("BZh"), family: ["bz", "tar.bz2", "tbz2", "tbz", "tar.bz"]),
        MagicRule("xz", [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], family: ["tar.xz"]),
        MagicRule("lz", ascii("LZIP")),
        MagicRule("z", [0x1F, 0x9D], family: ["tar.z", "tz"]),
        MagicRule("lzo", [0x89, 0x4C, 0x5A, 0x4F, 0x00, 0x0D, 0x0A, 0x1A, 0x0A], family: ["tar.lzo", "tzo"]),
        MagicRule("lzma", [0x5D, 0x00, 0x00]),
        MagicRule("cab", ascii("MSCF")),
        MagicRule("deb", ascii("!<arch>\n")),
        MagicRule("rpm", [0xED, 0xAB, 0xEE, 0xDB]),
        MagicRule("cpio", ascii("070707")),
        MagicRule("cpio", ascii("070701")),
        MagicRule("tar", at: 257, ascii("ustar"), family: ["tar.gz", "tar.bz2"]),
        MagicRule("arj", [0x60, 0xEA]),
        MagicRule("ace", at: 7, ascii("**ACE**")),
        MagicRule("alz", ascii("ALZ"), also: [.init(3, [0x01])]),
        MagicRule("lha", at: 2, ascii("-lh")),
        MagicRule("arc", [0x1A]),
        MagicRule("rz", ascii("RZIP")),
        MagicRule("dmg", at: 0, [0x78, 0x01, 0x73, 0x0D, 0x62, 0x62, 0x60]),
        MagicRule("iso", at: 0x8001, ascii("CD001")),
        MagicRule("zip", [0x50, 0x4B, 0x03, 0x04]),
        MagicRule("zip", [0x50, 0x4B, 0x05, 0x06]),
        // Fonts
        MagicRule("woff", ascii("wOFF")),
        MagicRule("woff2", ascii("wOF2")),
        MagicRule("otf", ascii("OTTO")),
        MagicRule("ttf", [0x00, 0x01, 0x00, 0x00]),
        MagicRule("ttf", ascii("true")),
        MagicRule("eot", at: 34, ascii("LP")),
    ]

    /// `PK\3\4` containers (ux §6.2), first match wins. Everything else with the signature is a plain ZIP.
    public static let zipRules: [ZipRule] = [
        ZipRule("pages", entries: ["Index/Document.iwa"]),
        ZipRule("pages", entries: ["index.xml", "QuickLook/Preview.pdf"]),
        ZipRule("key", entries: ["Index/Slide.iwa"]),
        ZipRule("numbers", entries: ["Index/CalculationEngine.iwa"]),
        ZipRule("epub", entries: ["META-INF/container.xml"], mimetype: "application/epub+zip"),
        ZipRule("odt", entries: ["content.xml"], mimetype: "application/vnd.oasis.opendocument.text"),
        ZipRule("ods", entries: ["content.xml"], mimetype: "application/vnd.oasis.opendocument.spreadsheet"),
        ZipRule("odp", entries: ["content.xml"], mimetype: "application/vnd.oasis.opendocument.presentation"),
        ZipRule("odg", entries: ["content.xml"], mimetype: "application/vnd.oasis.opendocument.graphics"),
        ZipRule("hwpx", entries: ["Contents/content.hpf"]),
        ZipRule("docm", entries: ["word/document.xml"], contentType: "macroEnabled"),
        ZipRule("dotx", entries: ["word/document.xml"], contentType: "template"),
        ZipRule("docx", entries: ["word/document.xml"]),
        ZipRule("xlsm", entries: ["xl/workbook.xml"], contentType: "macroEnabled"),
        ZipRule("xlsx", entries: ["xl/workbook.xml"]),
        ZipRule("pptm", entries: ["ppt/presentation.xml"], contentType: "macroEnabled"),
        ZipRule("potx", entries: ["ppt/presentation.xml"], contentType: "template"),
        ZipRule("ppsx", entries: ["ppt/presentation.xml"], contentType: "slideshow"),
        ZipRule("pptx", entries: ["ppt/presentation.xml"]),
        ZipRule("xps", entries: ["FixedDocumentSequence.fdseq"]),
        ZipRule("htmlz", entries: ["index.html"]),
        ZipRule("txtz", entries: ["index.txt"]),
        ZipRule("jar", entries: ["META-INF/MANIFEST.MF"]),
    ]
}
