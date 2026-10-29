import Foundation
import SuperConverterCore

/// What `ffprobe` says about a file (quality §5.1: colour is read with ffprobe and written to the output, never untagged):
/// the container, every stream with its codec, size, timing, colour and HDR metadata, and the chapters.
struct MediaProbe: Sendable, Equatable {
    struct Colour: Sendable, Equatable {
        /// FFmpeg's names: "bt709", "smpte170m", "bt2020"; nil when the stream is untagged.
        var primaries: String?
        /// "bt709", "smpte2084" (PQ), "arib-std-b67" (HLG).
        var transfer: String?
        /// "bt709", "smpte170m", "bt470bg", "bt2020nc".
        var matrix: String?
        /// "tv" (limited) or "pc" (full).
        var range: String?

        var isHDR: Bool { transfer == "smpte2084" || transfer == "arib-std-b67" }
    }

    /// SMPTE ST 2086 mastering display and CTA-861.3 content light level, as ffprobe prints them.
    struct HDRMetadata: Sendable, Equatable {
        /// "G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)": the x265/SVT-AV1 parameter form.
        var masteringDisplay: String?
        var maxCLL: Int?
        var maxFALL: Int?

        var isEmpty: Bool { masteringDisplay == nil && maxCLL == nil }

        /// The mastering display's ten numbers in their order: green, blue, red and white point x/y (0.00002 units), then the
        /// maximum and minimum luminance (0.0001 cd/m²).
        var masteringValues: [Int]? {
            let numbers = masteringDisplay?.split(whereSeparator: { !"0123456789".contains($0) }).compactMap { Int($0) } ?? []
            return numbers.count == 10 ? numbers : nil
        }

        /// Fills in what is still missing from an ffprobe `side_data_list` (a stream's or a frame's).
        mutating func read(_ sideData: [[String: Any]]) {
            for side in sideData {
                switch side["side_data_type"] as? String {
                case "Mastering display metadata": masteringDisplay = masteringDisplay ?? MediaProbe.masteringDisplay(side)
                case "Content light level metadata" where maxCLL == nil:
                    maxCLL = MediaProbe.int(side["max_content"]); maxFALL = MediaProbe.int(side["max_average"])
                default: break
                }
            }
        }
    }

    struct Stream: Sendable, Equatable {
        var index: Int
        var kind: MediaPlan.Stream.Kind
        /// ffprobe's codec name: "h264", "aac", "subrip", "png" (cover art).
        var codec: String
        var profile: String?
        var width: Int?
        var height: Int?
        var pixelFormat: String?
        var bitsPerSample: Int?
        /// The average frame rate (r_frame_rate when the average is unknown).
        var frameRate: Double?
        var isVariableFrameRate: Bool
        var sampleRate: Int?
        var channels: Int?
        var channelLayout: String?
        var sampleFormat: String?
        var bitRate: Int?
        var duration: Double?
        var language: String?
        var title: String?
        /// "progressive", "tt", "bb", "tb", "bt"; nil when unknown.
        var fieldOrder: String?
        /// Degrees the display matrix rotates by (−90 for a phone held upright).
        var rotation: Double?
        /// Pixel aspect (sample_aspect_ratio); nil when square or unknown.
        var sampleAspect: Double?
        var colour: Colour
        var hdr: HDRMetadata
        /// Cover art (an attached picture).
        var isAttachedPicture: Bool
        var isDefault: Bool

        var isTextSubtitle: Bool { MediaProbe.textSubtitleCodecs.contains(codec) }
        var bitDepth: Int {
            if let bits = bitsPerSample, bits > 0 { return bits }
            guard let f = pixelFormat else { return 8 }
            if f.contains("p10") || f.hasSuffix("10le") || f.hasSuffix("10be") || f == "p010le" || f == "v210" { return 10 }
            if f.contains("p12") { return 12 }
            if f.contains("p16") || f.hasSuffix("16le") { return 16 }
            return 8
        }
    }

    struct Chapter: Sendable, Equatable { var start: Double; var end: Double; var title: String }

    /// ffprobe's demuxer names ("mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm").
    var formatName: String
    var duration: Double?
    var bitRate: Int?
    var streams: [Stream]
    var chapters: [Chapter]
    var tags: [String: String]

    static let textSubtitleCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text", "microdvd", "subviewer", "jacosub", "sami", "realtext", "stl"]

    var video: [Stream] { streams.filter { $0.kind == .video && !$0.isAttachedPicture } }
    var audio: [Stream] { streams.filter { $0.kind == .audio } }
    var subtitles: [Stream] { streams.filter { $0.kind == .subtitle } }
    var coverArt: [Stream] { streams.filter { $0.kind == .video && $0.isAttachedPicture } }
    var mainVideo: Stream? { video.first(where: \.isDefault) ?? video.first }

    // MARK: Parsing

    init(formatName: String, duration: Double?, bitRate: Int?, streams: [Stream], chapters: [Chapter], tags: [String: String]) {
        self.formatName = formatName; self.duration = duration; self.bitRate = bitRate; self.streams = streams
        self.chapters = chapters; self.tags = tags
    }

    /// Reads `ffprobe -of json -show_format -show_streams -show_chapters`.
    init?(json data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let format = root["format"] as? [String: Any] ?? [:]
        formatName = format["format_name"] as? String ?? ""
        duration = Self.double(format["duration"])
        bitRate = Self.int(format["bit_rate"])
        tags = Self.tags(format["tags"])
        streams = (root["streams"] as? [[String: Any]] ?? []).compactMap(Self.stream)
        chapters = (root["chapters"] as? [[String: Any]] ?? []).map { c in
            Chapter(start: Self.double(c["start_time"]) ?? 0, end: Self.double(c["end_time"]) ?? 0, title: Self.tags(c["tags"])["title"] ?? "")
        }
    }

    private static func stream(_ s: [String: Any]) -> Stream? {
        guard let index = s["index"] as? Int else { return nil }
        let kind: MediaPlan.Stream.Kind
        switch s["codec_type"] as? String {
        case "video": kind = .video
        case "audio": kind = .audio
        case "subtitle": kind = .subtitle
        default: kind = .data
        }
        let tags = Self.tags(s["tags"])
        let disposition = s["disposition"] as? [String: Any] ?? [:]
        let average = rate(s["avg_frame_rate"]), real = rate(s["r_frame_rate"])
        var rotation = tags["rotate"].flatMap(Double.init).map { -$0 }
        let sideData = s["side_data_list"] as? [[String: Any]] ?? []
        for side in sideData where side["side_data_type"] as? String == "Display Matrix" { rotation = double(side["rotation"]) ?? rotation }
        var hdr = HDRMetadata()
        hdr.read(sideData)
        return Stream(index: index, kind: kind, codec: s["codec_name"] as? String ?? "none", profile: s["profile"] as? String,
                      width: int(s["width"]), height: int(s["height"]), pixelFormat: s["pix_fmt"] as? String,
                      bitsPerSample: int(s["bits_per_raw_sample"]) ?? int(s["bits_per_sample"]).flatMap { $0 > 0 ? $0 : nil },
                      frameRate: average ?? real, isVariableFrameRate: average != nil && real != nil && abs(average! - real!) > 0.01 * real!,
                      sampleRate: int(s["sample_rate"]), channels: int(s["channels"]), channelLayout: s["channel_layout"] as? String,
                      sampleFormat: s["sample_fmt"] as? String, bitRate: int(s["bit_rate"]), duration: double(s["duration"]),
                      language: tags["language"].flatMap { $0 == "und" ? nil : $0 }, title: tags["title"],
                      fieldOrder: (s["field_order"] as? String).flatMap { $0 == "unknown" ? nil : $0 }, rotation: rotation,
                      sampleAspect: ratio(s["sample_aspect_ratio"]).flatMap { abs($0 - 1) < 0.001 ? nil : $0 },
                      colour: Colour(primaries: known(s["color_primaries"]), transfer: known(s["color_transfer"]),
                                     matrix: known(s["color_space"]), range: known(s["color_range"])),
                      hdr: hdr, isAttachedPicture: (disposition["attached_pic"] as? Int) == 1,
                      isDefault: (disposition["default"] as? Int) == 1)
    }

    /// ffprobe prints the ST 2086 values as rationals ("13250/50000"); x265 and SVT-AV1 take them in 0.00002 (chromaticity)
    /// and 0.0001 cd/m² (luminance) units.
    static func masteringDisplay(_ side: [String: Any]) -> String? {
        func units(_ key: String, _ scale: Double) -> Int? {
            guard let text = side[key] as? String else { return nil }
            let parts = text.split(separator: "/").compactMap { Double($0) }
            guard parts.count == 2, parts[1] != 0 else { return Double(text).map { Int(($0 * scale).rounded()) } }
            return Int((parts[0] / parts[1] * scale).rounded())
        }
        guard let gx = units("green_x", 50000), let gy = units("green_y", 50000), let bx = units("blue_x", 50000), let by = units("blue_y", 50000),
              let rx = units("red_x", 50000), let ry = units("red_y", 50000), let wx = units("white_point_x", 50000), let wy = units("white_point_y", 50000),
              let maxL = units("max_luminance", 10000), let minL = units("min_luminance", 10000) else { return nil }
        return "G(\(gx),\(gy))B(\(bx),\(by))R(\(rx),\(ry))WP(\(wx),\(wy))L(\(maxL),\(minL))"
    }

    private static func known(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text != "unknown", text != "reserved", text != "unspecified" else { return nil }
        return text
    }

    private static func tags(_ value: Any?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in value as? [String: Any] ?? [:] { out[k.lowercased()] = "\(v)" }
        return out
    }

    static func double(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let s = value as? String { return Int(s) }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    private static func ratio(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    private static func rate(_ value: Any?) -> Double? {
        guard let text = value as? String else { return nil }
        let parts = text.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0, parts[0] > 0 else { return nil }
        return parts[0] / parts[1]
    }
}

extension MediaTools {
    func probe(_ url: URL, workFolder: URL) async throws -> MediaProbe {
        let data = try await probeJSON(url, workFolder: workFolder)
        guard var probe = MediaProbe(json: data), !probe.streams.isEmpty else { throw ConversionError.damaged(FormatID(url.pathExtension.lowercased())) }
        // HDR metadata often sits on the frames rather than the stream (AV1 metadata OBUs, HEVC SEI): the first frame's.
        if let video = probe.mainVideo, video.colour.isHDR, video.hdr.isEmpty,
           let i = probe.streams.firstIndex(where: { $0.index == video.index }),
           let frames = try? await probeJSON(url, workFolder: workFolder, extra: ["-show_frames", "-read_intervals", "%+#1", "-select_streams", String(video.index)]),
           let root = try? JSONSerialization.jsonObject(with: frames) as? [String: Any] {
            for frame in root["frames"] as? [[String: Any]] ?? [] { probe.streams[i].hdr.read(frame["side_data_list"] as? [[String: Any]] ?? []) }
        }
        return probe
    }

    /// Whether the main video is interlaced (quality §5.1): the stream's field order when it says progressive, else FFmpeg's
    /// `idet` over the first 300 frames — interlaced when more frames show top- or bottom-field-first combing than look
    /// progressive (flags in a stream are often wrong in both directions, so a flagged stream is checked too).
    func isInterlaced(_ url: URL, probe: MediaProbe, sourceFormat: FormatID, workFolder: URL) async throws -> Bool {
        guard let video = probe.mainVideo else { return false }
        let flagged = video.fieldOrder.map { $0 != "progressive" }
        if flagged == false { return false }
        guard flagged == true || Self.oftenInterlaced.contains(sourceFormat) else { return false }
        let log = try await analyse(["-i", url.path, "-map", "0:v:0", "-an", "-sn", "-frames:v", "300", "-vf", "idet"], workFolder: workFolder)
        guard let counts = Self.idetCounts(log) else { return flagged ?? false }
        return counts.tff + counts.bff > counts.progressive
    }

    /// Containers whose sources are commonly 1080i/576i/480i (DV, DVD, AVCHD, broadcast recordings, camcorder MOD).
    static let oftenInterlaced: Set<FormatID> = ["dv", "vob", "mts", "m2ts", "ts", "mod", "mpg", "mpeg", "mxf", "dvr", "wtv"]

    /// The "Multi frame detection" line of `idet`.
    static func idetCounts(_ log: String) -> (tff: Int, bff: Int, progressive: Int)? {
        guard let line = log.split(whereSeparator: \.isNewline).last(where: { $0.contains("Multi frame detection") }) else { return nil }
        func count(_ label: String) -> Int? {
            guard let r = line.range(of: "\(label):") else { return nil }
            return Int(line[r.upperBound...].trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
        }
        guard let t = count("TFF"), let b = count("BFF"), let p = count("Progressive") else { return nil }
        return (t, b, p)
    }
}
