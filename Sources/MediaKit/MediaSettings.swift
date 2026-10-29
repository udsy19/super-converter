import Foundation
import SuperConverterCore

/// The options of one media job, read from the card's values with the profile defaults of formats §5 (O-VIDEO, O-AUDIO,
/// O-ANIM, O-DECK-VIDEO). `OptionValues` stores only what the person changed, so "set" below means "differs from the default":
/// that is what turns on CBR for MP3 or rules out stream copy.
struct MediaSettings: Sendable, Equatable {
    enum Fit: String, Sendable { case max, crop, scale, pad }
    enum Speed: String, Sendable { case fast, medium, slow }
    enum SubtitleMode: String, Sendable { case copy, none, soft, hard }
    enum Corner: String, Sendable { case topLeft, topRight, bottomLeft, bottomRight, centre }

    // Video (O-VIDEO).
    var videoCodec: String = "auto"
    /// x264-scale CRF, 0–51 (formats §5: default 20).
    var crf: Int = 20
    var crfSet = false
    var speed: Speed = .medium
    var width: Int?
    var height: Int?
    var fit: Fit = .max
    var fps: Double?
    var keyframeInterval: Int?
    var aspectRatio: String?
    var removeSound = false
    var profile: String?
    var level: String?
    var tune: String?
    var subtitles: SubtitleMode = .copy
    var subtitleFile: URL?
    var watermark: URL?
    var watermarkCorner: Corner = .bottomRight
    var watermarkOpacity: Double = 1
    var hdrToSDR = false
    var deinterlace = true
    var webReady = true
    var hardware = true
    var qscale = 3
    var allAudioStreams: Bool?

    // Audio (O-AUDIO, and the audio part of O-VIDEO).
    var audioCodec: String = "auto"
    /// kb/s; nil when the person left it (each encoder then uses its transparent default, quality §5.2).
    var audioBitrate: Int?
    var mp3Quality = 0
    var volume: Double = 1
    var channels: Int?
    var sampleRate: Int?
    var loudness: Double?
    /// 16, 24, 32 (integer) or nil for the source's; `floatSamples` for 32-bit float.
    var bitDepth: Int?
    var floatSamples = false
    var flacLevel = 8
    var keepArtwork = true

    // Both.
    var trimStart: Double?
    var trimEnd: Double?

    // Animation (O-ANIM).
    var colours = 256
    var dither = "sierra2_4a"
    var loopForever = true
    var webpQuality = 80

    // Slides as video (O-DECK-VIDEO).
    var secondsPerSlide: Double = 5

    init() {}

    /// - Parameter animation: O-ANIM defaults apply (800 px wide at most, 15 fps at most, formats §5).
    init(_ o: OptionValues, animation: Bool = false, deckVideo: Bool = false) {
        func string(_ k: String) -> String? { o[k]?.string ?? o[k].map(Self.text) }
        func number(_ k: String) -> Double? { o[k]?.double ?? o[k]?.string.flatMap(Double.init) }
        func int(_ k: String) -> Int? { o[k]?.int ?? o[k]?.string.flatMap(Int.init) }
        func flag(_ k: String) -> Bool? { o[k]?.bool ?? o[k]?.string.map { ["1", "true", "yes", "on"].contains($0.lowercased()) } }
        func time(_ k: String) -> Double? { o[k]?.double ?? o[k]?.string.flatMap(MediaTime.seconds) }

        videoCodec = string("videoCodec") ?? string("video_codec") ?? "auto"
        if let q = int("quality") ?? int("crf") { crf = min(max(q, 0), 51); crfSet = true }
        speed = (string("speed") ?? string("preset")).map(Self.speed) ?? .medium
        if let size = string("size"), let lines = Int(size) { height = lines; width = lines * 16 / 9 }
        if let w = int("width") { width = w }
        if let h = int("height") { height = h }
        if animation, width == nil, height == nil { width = 800 }
        fit = string("fit").flatMap(Fit.init) ?? .max
        fps = number("fps").flatMap { $0 > 0 ? $0 : nil } ?? (animation ? 15 : nil)
        keyframeInterval = int("keyframeInterval") ?? int("keyframe_interval")
        aspectRatio = string("aspectRatio") ?? string("aspect_ratio")
        removeSound = string("sound") == "none"
        profile = string("profile"); level = string("level"); tune = string("tune")
        subtitles = string("subtitles").flatMap(SubtitleMode.init) ?? string("subtitles_mode").flatMap(SubtitleMode.init) ?? .copy
        subtitleFile = string("subtitleFile").map { URL(fileURLWithPath: $0) }
        watermark = (string("watermarkImage") ?? string("watermark_image")).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        watermarkCorner = string("watermarkPosition").flatMap(Corner.init) ?? .bottomRight
        watermarkOpacity = min(max(number("watermarkOpacity") ?? 1, 0), 1)
        hdrToSDR = string("hdr") == "sdr"
        deinterlace = string("deinterlace") != "off"
        webReady = flag("webReady") ?? true
        hardware = flag("hardwareEncoding") ?? true
        qscale = min(max(int("qscale") ?? 3, 1), 31)
        allAudioStreams = flag("allAudioStreams") ?? flag("all_audio_streams")

        audioCodec = string("audioCodec") ?? string("codec") ?? string("audio_codec") ?? "auto"
        audioBitrate = int("audioBitrate") ?? int("bitrate") ?? int("audio_bitrate")
        mp3Quality = min(max(int("mp3Quality") ?? int("audio_qscale") ?? 0, 0), 9)
        volume = max(number("volume") ?? 1, 0)
        channels = (string("channels")).flatMap(Int.init)
        sampleRate = (string("sampleRate") ?? string("sample_rate")).flatMap(Int.init)
        loudness = string("loudness").flatMap(Double.init)
        switch string("bitDepth") {
        case "16": bitDepth = 16
        case "24": bitDepth = 24
        case "32": bitDepth = 32
        case "32f": bitDepth = 32; floatSamples = true
        default: break
        }
        flacLevel = min(max(int("flacLevel") ?? 8, 0), 12)
        keepArtwork = flag("keepArtwork") ?? true

        trimStart = time("trimStart") ?? time("trim_start")
        trimEnd = time("trimEnd") ?? time("trim_end")

        colours = min(max(int("colours") ?? 256, 2), 256)
        dither = string("dither") ?? "sierra2_4a"
        loopForever = string("loop") != "once"
        webpQuality = min(max(int("lossy") ?? 80, 1), 100)

        secondsPerSlide = max(number("secondsPerSlide") ?? 5, 0.1)
        if deckVideo {
            fps = number("fps") ?? 30
            let lines = int("size") ?? 1080
            height = lines; width = lines * 16 / 9; fit = .pad
        }
    }

    private static func text(_ value: OptionValue) -> String {
        switch value {
        case .bool(let b): b ? "true" : "false"
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .string(let s): s
        }
    }

    private static func speed(_ text: String) -> Speed {
        switch text.lowercased() {
        case "ultrafast", "superfast", "veryfast", "faster", "fast": .fast
        case "slow", "slower", "veryslow", "placebo": .slow
        default: .medium
        }
    }

    // MARK: What the options change

    /// Options that change the picture: any of them rules out copying the video stream.
    var changesVideo: Bool {
        crfSet || width != nil || height != nil || fps != nil || keyframeInterval != nil || aspectRatio != nil || watermark != nil
            || subtitles == .hard || profile != nil || level != nil || hdrToSDR
    }

    /// Options that change the sound: any of them rules out copying the audio stream.
    var changesAudio: Bool {
        audioBitrate != nil || volume != 1 || channels != nil || sampleRate != nil || loudness != nil || bitDepth != nil
    }

    var isTrimmed: Bool { trimStart != nil || trimEnd != nil }

    /// The output's length for progress, from the source's and the trim.
    func outputDuration(_ source: Double?) -> Double? {
        guard let source else { return trimEnd.map { $0 - (trimStart ?? 0) } }
        let end = min(trimEnd ?? source, source)
        return max(end - (trimStart ?? 0), 0)
    }
}
