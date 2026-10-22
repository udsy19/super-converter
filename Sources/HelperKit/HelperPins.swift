import Foundation
import SuperConverterCore

/// One pinned upstream release of a one-click helper (formats §4, §2.9a): the exact file, its SHA-256 and what is inside.
/// Upstream's own signed builds only — there is no public helpers repository [D].
struct HelperPin: Hashable, Sendable {
    enum Arch: String, Sendable { case arm64, x86_64
        static var current: Arch {
            #if arch(arm64)
            .arm64
            #else
            .x86_64
            #endif
        }
    }

    enum Payload: Hashable, Sendable {
        /// A disk image holding `app`, which must carry a Developer ID signature of `teamID` and be notarised.
        case appInDiskImage(app: String, teamID: String)
        /// A zip with the tool at `binary` inside.
        case zipBinary(binary: String)
        /// A gzipped tar with the tool at `binary` inside.
        case tarGzBinary(binary: String)
    }

    let helper: HelperID
    let version: String
    let arch: Arch
    let url: URL
    /// Lower-case hex.
    let sha256: String
    let payload: Payload

}

enum HelperPins {
    static func pin(for helper: HelperID, arch: HelperPin.Arch = .current) -> HelperPin? {
        all.first { $0.helper == helper && $0.arch == arch }
    }

    private static func url(_ text: String) -> URL { URL(string: text)! }

    /// Versions and digests were taken from upstream's release pages (the digests are upstream's published ones; the arm64 files and calibre's image were hashed again after download).
    static let all: [HelperPin] = [
        HelperPin(helper: .libreoffice, version: "26.8.1", arch: .arm64,
                  url: url("https://download.documentfoundation.org/libreoffice/stable/26.8.1/mac/aarch64/LibreOffice_26.8.1_MacOS_aarch64.dmg"),
                  sha256: "ca074e0b13571efb30a31fc531c5f95e997030637325e5d5de92d67aefdf0dfc",
                  payload: .appInDiskImage(app: "LibreOffice.app", teamID: "7P5S3ZLCN7")),
        HelperPin(helper: .libreoffice, version: "26.8.1", arch: .x86_64,
                  url: url("https://download.documentfoundation.org/libreoffice/stable/26.8.1/mac/x86_64/LibreOffice_26.8.1_MacOS_x86-64.dmg"),
                  sha256: "4c7464313a529e9074400cbcdc894fc40ac4ef9421ded03b16b5a78d12cb155e",
                  payload: .appInDiskImage(app: "LibreOffice.app", teamID: "7P5S3ZLCN7")),
        // calibre ships one universal image; the official GitHub release carries the same file as download.calibre-ebook.com.
        HelperPin(helper: .calibre, version: "9.16.0", arch: .arm64,
                  url: url("https://github.com/kovidgoyal/calibre/releases/download/v9.16.0/calibre-9.16.0.dmg"),
                  sha256: "9e1102559e4118f37ca4f3d65b67a053a8e8d5a8232d469e205bd4145057aba5",
                  payload: .appInDiskImage(app: "calibre.app", teamID: "NTY7FVCEKP")),
        HelperPin(helper: .calibre, version: "9.16.0", arch: .x86_64,
                  url: url("https://github.com/kovidgoyal/calibre/releases/download/v9.16.0/calibre-9.16.0.dmg"),
                  sha256: "9e1102559e4118f37ca4f3d65b67a053a8e8d5a8232d469e205bd4145057aba5",
                  payload: .appInDiskImage(app: "calibre.app", teamID: "NTY7FVCEKP")),
        HelperPin(helper: .pandoc, version: "3.12.1", arch: .arm64,
                  url: url("https://github.com/jgm/pandoc/releases/download/3.12.1/pandoc-3.12.1-arm64-macOS.zip"),
                  sha256: "c2146cf33a583f3ac93eccddf1bb662371d5cfcce1aad1c87ad860cca1435d46",
                  payload: .zipBinary(binary: "pandoc-3.12.1-arm64/bin/pandoc")),
        HelperPin(helper: .pandoc, version: "3.12.1", arch: .x86_64,
                  url: url("https://github.com/jgm/pandoc/releases/download/3.12.1/pandoc-3.12.1-x86_64-macOS.zip"),
                  sha256: "81ed3e2cfecf096df15d407152f89a684fd65221082b919963f738e977fad3bc",
                  payload: .zipBinary(binary: "pandoc-3.12.1-x86_64/bin/pandoc")),
        HelperPin(helper: .tectonic, version: "0.17.0", arch: .arm64,
                  url: url("https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%400.17.0/tectonic-0.17.0-aarch64-apple-darwin.tar.gz"),
                  sha256: "a3f1cac7c5678f01661a92212f58480ae3b0634115d880dbc59e2953ded45667",
                  payload: .tarGzBinary(binary: "tectonic")),
        HelperPin(helper: .tectonic, version: "0.17.0", arch: .x86_64,
                  url: url("https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%400.17.0/tectonic-0.17.0-x86_64-apple-darwin.tar.gz"),
                  sha256: "7c90ef5b6ddb1eb1937e4337add5237b79338e4b9676459fa91187d24d6cdf80",
                  payload: .tarGzBinary(binary: "tectonic")),
    ]
}
