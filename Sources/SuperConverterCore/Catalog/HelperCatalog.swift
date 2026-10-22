import Foundation

/// The optional helpers (formats §4).
public enum HelperID: String, CaseIterable, Codable, Sendable {
    case libreoffice, iwork, msoffice, calibre, pandoc, tectonic, ghostscript, djvulibre, oda, libredwg
    case ffmpegGPL = "ffmpeg-gpl"
    case rar, sfark
}

/// How a helper gets onto the Mac. There is no public helpers repository [D]: GPL and AGPL helpers without an official
/// macOS build are only detected where people already have them (Homebrew and the known install paths), and "Get…"
/// explains the install.
public enum HelperInstall: Hashable, Sendable {
    /// Upstream's own signed release, downloaded by one click (pinned version + SHA-256 in HelperKit's catalog).
    case oneClick(releasePage: URL)
    /// "Get…" opens the vendor's page.
    case vendorPage(URL)
    /// "Get…" opens the App Store page.
    case appStore(URL)
    /// Detected where Homebrew installs it; "Get…" explains `brew install <formula>`.
    case homebrew(formula: String)
    /// Detected only; nothing to install from here (Microsoft Office).
    case detectOnly
    /// Detected only; "Get…" explains building it from source.
    case buildFromSource(project: URL)
}

public enum HelperLicence: String, Codable, Sendable { case permissive, copyleft, proprietary, appleFree }

public struct HelperInfo: Hashable, Sendable, Identifiable {
    public let id: HelperID
    /// "LibreOffice", "Pages / Numbers / Keynote".
    public let name: String
    /// What it unlocks, as the Helpers pane says it.
    public let unlocks: String
    public let licenceName: String
    public let licence: HelperLicence
    public let install: HelperInstall
    /// Download size in MB for the card notice ("Free · 160 MB"); nil when there is nothing to download.
    public let downloadMB: Int?
    /// Where it is looked for (absolute paths, `~` allowed), in order; a Settings override comes first.
    public let detection: [String]
    /// Time limit per file (formats §4/ARCHITECTURE §7); nil for apps driven by Apple Events.
    public let timeLimit: TimeInterval?
    /// True for apps (copied to ~/Applications), false for command-line tools (unpacked under Application Support).
    public let isApp: Bool
}

public enum HelperCatalog {
    public static func info(_ id: HelperID) -> HelperInfo { byID[id]! }
    public static let all: [HelperInfo] = [
        HelperInfo(id: .libreoffice, name: "LibreOffice",
                   unlocks: "LWP, SDW, WPD, WPS, ET, SDC, DPS, SDA, PPT/PPS/POT, ODP, ODG, PUB, CDR, VSD and CGM input; DOC, XLS, PPT and ODP output; original office layout",
                   licenceName: "MPL-2.0", licence: .permissive,
                   install: .oneClick(releasePage: URL(string: "https://download.documentfoundation.org/libreoffice/stable/")!),
                   downloadMB: 360, detection: ["/Applications/LibreOffice.app", "~/Applications/LibreOffice.app"],
                   timeLimit: 120, isApp: true),
        HelperInfo(id: .iwork, name: "Pages / Numbers / Keynote", unlocks: "PAGES, NUMBERS and KEY input and output; the best PPT, PPTX and XLS to PDF when present",
                   licenceName: "Apple (free)", licence: .appleFree,
                   install: .appStore(URL(string: "https://apps.apple.com/app/pages/id409201541")!), downloadMB: nil,
                   detection: ["/Applications/Pages.app", "/Applications/Numbers.app", "/Applications/Keynote.app"],
                   timeLimit: nil, isApp: true),
        HelperInfo(id: .msoffice, name: "Microsoft Office", unlocks: "The best DOC, DOCX, XLS, XLSX, PPT and PPTX to PDF when Office is installed",
                   licenceName: "Proprietary", licence: .proprietary, install: .detectOnly, downloadMB: nil,
                   detection: ["/Applications/Microsoft Word.app", "/Applications/Microsoft Excel.app", "/Applications/Microsoft PowerPoint.app"],
                   timeLimit: nil, isApp: true),
        HelperInfo(id: .calibre, name: "calibre", unlocks: "AZW, AZW3, AZW4, LIT, LRF, MOBI, PDB, PML, PRC, RB, SNB and TCR input; AZW3, MOBI, LRF and PDB output",
                   licenceName: "GPL-3.0", licence: .copyleft,
                   install: .oneClick(releasePage: URL(string: "https://download.calibre-ebook.com/")!), downloadMB: 160,
                   detection: ["/Applications/calibre.app", "~/Applications/calibre.app"], timeLimit: 300, isApp: true),
        HelperInfo(id: .pandoc, name: "Pandoc", unlocks: "RST input; TEX to anything but PDF",
                   licenceName: "GPL-2.0+", licence: .copyleft,
                   install: .oneClick(releasePage: URL(string: "https://github.com/jgm/pandoc/releases")!), downloadMB: 35,
                   detection: ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"], timeLimit: 120, isApp: false),
        HelperInfo(id: .tectonic, name: "Tectonic", unlocks: "TEX to PDF with a real LaTeX run",
                   licenceName: "MIT", licence: .permissive,
                   install: .oneClick(releasePage: URL(string: "https://github.com/tectonic-typesetting/tectonic/releases")!), downloadMB: 145,
                   detection: ["/Library/TeX/texbin/latexmk", "/opt/homebrew/bin/tectonic", "/usr/local/bin/tectonic"],
                   timeLimit: 300, isApp: false),
        HelperInfo(id: .ghostscript, name: "Ghostscript", unlocks: "EPS and PS input; PostScript-based AI",
                   licenceName: "AGPL-3.0", licence: .copyleft, install: .homebrew(formula: "ghostscript"), downloadMB: nil,
                   detection: ["/opt/homebrew/bin/gs", "/usr/local/bin/gs"], timeLimit: 120, isApp: false),
        HelperInfo(id: .djvulibre, name: "DjVuLibre", unlocks: "DJVU input",
                   licenceName: "GPL-2.0+", licence: .copyleft, install: .homebrew(formula: "djvulibre"), downloadMB: nil,
                   detection: ["/opt/homebrew/bin/ddjvu", "/usr/local/bin/ddjvu"], timeLimit: 120, isApp: false),
        HelperInfo(id: .oda, name: "ODA File Converter", unlocks: "DWG input and output (all AutoCAD versions)",
                   licenceName: "Proprietary freeware", licence: .proprietary,
                   install: .vendorPage(URL(string: "https://www.opendesign.com/guestfiles/oda_file_converter")!), downloadMB: nil,
                   detection: ["/Applications/ODAFileConverter.app"], timeLimit: 120, isApp: true),
        HelperInfo(id: .libredwg, name: "LibreDWG", unlocks: "DWG input and output when ODA is absent",
                   licenceName: "GPL-3.0", licence: .copyleft, install: .homebrew(formula: "libredwg"), downloadMB: nil,
                   detection: ["/opt/homebrew/bin/dwg2dxf", "/usr/local/bin/dwg2dxf"], timeLimit: 120, isApp: false),
        HelperInfo(id: .ffmpegGPL, name: "FFmpeg GPL encoders", unlocks: "CAVS output; optional x264 and x265 software encoders",
                   licenceName: "GPL-2.0+", licence: .copyleft, install: .homebrew(formula: "ffmpeg"), downloadMB: nil,
                   detection: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"], timeLimit: nil, isApp: false),
        HelperInfo(id: .rar, name: "RAR (RARLAB)", unlocks: "RAR output",
                   licenceName: "Proprietary (shareware)", licence: .proprietary,
                   install: .vendorPage(URL(string: "https://www.rarlab.com/download.htm")!), downloadMB: nil,
                   detection: ["/opt/homebrew/bin/rar", "/usr/local/bin/rar"], timeLimit: 120, isApp: false),
        HelperInfo(id: .sfark, name: "sfArk tool", unlocks: "SFARK input",
                   licenceName: "GPL-3.0 (sfArkLib)", licence: .copyleft,
                   install: .buildFromSource(project: URL(string: "https://github.com/raboof/sfarkxtc")!), downloadMB: nil,
                   detection: ["/opt/homebrew/bin/sfarkxtc", "/usr/local/bin/sfarkxtc"], timeLimit: 120, isApp: false),
    ]

    private static let byID: [HelperID: HelperInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
