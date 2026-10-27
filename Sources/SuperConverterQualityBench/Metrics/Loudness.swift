import Foundation

/// Where the bundled `ffmpeg` lives, for the bench (WP0c ships `ffmpeg`/`ffprobe` into `Vendor/Tools`, fetched by
/// `scripts/tools.sh`; the app carries them in its bundle). Order: `SUPERCONVERTER_FFMPEG`, the repository's Vendor/Tools,
/// the app bundle's Helpers folder, then a system install (Homebrew) so a dev machine without the bundle can still measure.
enum FFmpegLocator {
    static func find(_ tool: String = "ffmpeg", environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates: [URL] = []
        if tool == "ffmpeg", let path = environment["SUPERCONVERTER_FFMPEG"], !path.isEmpty { candidates.append(URL(fileURLWithPath: path)) }
        candidates.append(RepoRoot.url.appendingPathComponent("Vendor/Tools/\(tool)"))
        if let bundle = Bundle.main.resourceURL { candidates.append(bundle.deletingLastPathComponent().appendingPathComponent("Helpers/\(tool)")) }
        candidates += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0).appendingPathComponent(tool) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// EBU R128 / ITU-R BS.1770 loudness through `ffmpeg -af ebur128` (quality §5.3 "Loudness option": integrated, +-0.5 LU).
enum Loudness {
    struct Measurement: Equatable {
        /// Integrated loudness, LUFS.
        var integrated: Double
        /// Loudness range, LU.
        var range: Double
        /// True peak, dBTP (nil when the filter did not print it).
        var truePeak: Double?
    }

    /// Runs the filter over the file's first audio stream; nil when ffmpeg is missing or the output has no summary.
    static func measure(_ url: URL, ffmpeg: URL? = FFmpegLocator.find()) -> Measurement? {
        guard let ffmpeg, let output = Subprocess.run(ffmpeg, ["-nostdin", "-hide_banner", "-nostats", "-i", url.path, "-vn",
                                                                "-af", "ebur128=peak=true", "-f", "null", "-"]).standardError else { return nil }
        return parse(output)
    }

    /// Reads the "Summary:" block that `ebur128` prints last.
    static func parse(_ log: String) -> Measurement? {
        guard let summary = log.range(of: "Summary:", options: .backwards) else { return nil }
        let text = String(log[summary.upperBound...])
        func number(_ label: String, unit: String) -> Double? {
            guard let r = text.range(of: "\(label):") else { return nil }
            let rest = text[r.upperBound...].drop { $0 == " " }
            guard let end = rest.range(of: unit) else { return nil }
            return Double(rest[..<end.lowerBound].trimmingCharacters(in: .whitespaces))
        }
        guard let integrated = number("I", unit: "LUFS"), let range = number("LRA", unit: "LU") else { return nil }
        return Measurement(integrated: integrated, range: range, truePeak: number("Peak", unit: "dBFS"))
    }
}
