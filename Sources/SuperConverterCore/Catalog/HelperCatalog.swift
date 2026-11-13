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
        entry(id: .libreoffice, name: "LibreOffice",
                   unlocks: "LWP, SDW, WPD, WPS, ET, SDC, DPS, SDA, PPT/PPS/POT, ODP, ODG, PUB, CDR, VSD and CGM input; DOC, XLS, PPT and ODP output; original office layout",
                   licenceName: "MPL-2.0", licence: .permissive,
                   
                   downloadMB: 360, timeLimit: 120, isApp: true),
        entry(id: .iwork, name: "Pages / Numbers / Keynote", unlocks: "PAGES, NUMBERS and KEY input and output; the best PPT, PPTX and XLS to PDF when present",
                   licenceName: "Apple (free)", licence: .appleFree,
                    downloadMB: nil,
                   timeLimit: nil, isApp: true),
        entry(id: .msoffice, name: "Microsoft Office", unlocks: "The best DOC, DOCX, XLS, XLSX, PPT and PPTX to PDF when Office is installed",
                   licenceName: "Proprietary", licence: .proprietary,  downloadMB: nil,
                   timeLimit: nil, isApp: true),
        entry(id: .calibre, name: "calibre", unlocks: "AZW, AZW3, AZW4, LIT, LRF, MOBI, PDB, PML, PRC, RB, SNB and TCR input; AZW3, MOBI, LRF and PDB output",
                   licenceName: "GPL-3.0", licence: .copyleft,
                    downloadMB: 160,
                   timeLimit: 300, isApp: true),
        entry(id: .pandoc, name: "Pandoc", unlocks: "RST input; TEX to anything but PDF",
                   licenceName: "GPL-2.0+", licence: .copyleft,
                    downloadMB: 35,
                   timeLimit: 120, isApp: false),
        entry(id: .tectonic, name: "Tectonic", unlocks: "TEX to PDF with a real LaTeX run",
                   licenceName: "MIT", licence: .permissive,
                    downloadMB: 145,
                   timeLimit: 300, isApp: false),
        entry(id: .ghostscript, name: "Ghostscript", unlocks: "EPS and PS input; PostScript-based AI",
                   licenceName: "AGPL-3.0", licence: .copyleft,  downloadMB: nil,
                   timeLimit: 120, isApp: false),
        entry(id: .djvulibre, name: "DjVuLibre", unlocks: "DJVU input",
                   licenceName: "GPL-2.0+", licence: .copyleft,  downloadMB: nil,
                   timeLimit: 120, isApp: false),
        entry(id: .oda, name: "ODA File Converter", unlocks: "DWG input and output (all AutoCAD versions)",
                   licenceName: "Proprietary freeware", licence: .proprietary,
                    downloadMB: nil,
                   timeLimit: 120, isApp: true),
        entry(id: .libredwg, name: "LibreDWG", unlocks: "DWG input and output when ODA is absent",
                   licenceName: "GPL-3.0", licence: .copyleft,  downloadMB: nil,
                   timeLimit: 120, isApp: false),
        entry(id: .ffmpegGPL, name: "FFmpeg GPL encoders", unlocks: "CAVS output; optional x264 and x265 software encoders",
                   licenceName: "GPL-2.0+", licence: .copyleft,  downloadMB: nil,
                   timeLimit: nil, isApp: false),
        entry(id: .rar, name: "RAR (RARLAB)", unlocks: "RAR output",
                   licenceName: "Proprietary (shareware)", licence: .proprietary,
                    downloadMB: nil,
                   timeLimit: 120, isApp: false),
        entry(id: .sfark, name: "sfArk tool", unlocks: "SFARK input",
                   licenceName: "GPL-3.0 (sfArkLib)", licence: .copyleft,
                    downloadMB: nil,
                   timeLimit: 120, isApp: false),
    ]

    /// A helper's card, from its name to its time limit; where it is found and how it is installed come from `sources`.
    private static func entry(id: HelperID, name: String, unlocks: String, licenceName: String, licence: HelperLicence,
                              downloadMB: Int?, timeLimit: TimeInterval?, isApp: Bool) -> HelperInfo {
        let source = sources[id] ?? (.detectOnly, [])
        return HelperInfo(id: id, name: name, unlocks: unlocks, licenceName: licenceName, licence: licence, install: source.install,
                          downloadMB: downloadMB, detection: source.detection, timeLimit: timeLimit, isApp: isApp)
    }

    #if APP_STORE
    /// The Store edition runs no outside programs: no install places, download pages or Homebrew paths in its binary.
    private static let sources: [HelperID: (install: HelperInstall, detection: [String])] = [:]
    #else
    private static let sources: [HelperID: (install: HelperInstall, detection: [String])] = [
        .libreoffice: (.oneClick(releasePage: URL(string: "https://download.documentfoundation.org/libreoffice/stable/")!),
                 ["/Applications/LibreOffice.app", "~/Applications/LibreOffice.app"]),
        .iwork: (.appStore(URL(string: "https://apps.apple.com/app/pages/id409201541")!),
                 ["/Applications/Pages.app", "/Applications/Numbers.app", "/Applications/Keynote.app"]),
        .msoffice: (.detectOnly,
                 ["/Applications/Microsoft Word.app", "/Applications/Microsoft Excel.app", "/Applications/Microsoft PowerPoint.app"]),
        .calibre: (.oneClick(releasePage: URL(string: "https://download.calibre-ebook.com/")!),
                 ["/Applications/calibre.app", "~/Applications/calibre.app"]),
        .pandoc: (.oneClick(releasePage: URL(string: "https://github.com/jgm/pandoc/releases")!),
                 ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc"]),
        .tectonic: (.oneClick(releasePage: URL(string: "https://github.com/tectonic-typesetting/tectonic/releases")!),
                 ["/Library/TeX/texbin/latexmk", "/opt/homebrew/bin/tectonic", "/usr/local/bin/tectonic"]),
        .ghostscript: (.homebrew(formula: "ghostscript"),
                 ["/opt/homebrew/bin/gs", "/usr/local/bin/gs"]),
        .djvulibre: (.homebrew(formula: "djvulibre"),
                 ["/opt/homebrew/bin/ddjvu", "/usr/local/bin/ddjvu"]),
        .oda: (.vendorPage(URL(string: "https://www.opendesign.com/guestfiles/oda_file_converter")!),
                 ["/Applications/ODAFileConverter.app"]),
        .libredwg: (.homebrew(formula: "libredwg"),
                 ["/opt/homebrew/bin/dwg2dxf", "/usr/local/bin/dwg2dxf"]),
        .ffmpegGPL: (.homebrew(formula: "ffmpeg"),
                 ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]),
        .rar: (.vendorPage(URL(string: "https://www.rarlab.com/download.htm")!),
                 ["/opt/homebrew/bin/rar", "/usr/local/bin/rar"]),
        .sfark: (.buildFromSource(project: URL(string: "https://github.com/raboof/sfarkxtc")!),
                 ["/opt/homebrew/bin/sfarkxtc", "/usr/local/bin/sfarkxtc"]),
    ]
    #endif

    private static let byID: [HelperID: HelperInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}
