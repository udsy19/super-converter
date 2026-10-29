import Foundation
import SuperConverterCore

/// The video encoders MediaKit drives (formats §5 O-VIDEO codec table; quality §5.1 encoder choice): H.264/HEVC/ProRes with
/// VideoToolbox, VP8/VP9 with libvpx, AV1 with SVT-AV1, the legacy codecs with FFmpeg's own encoders.
enum VideoCodec: String, CaseIterable, Sendable {
    case h264, hevc, prores, av1, vp8, vp9
    /// MPEG-4 Part 2 with the XVID FourCC (CloudConvert's "xvid").
    case mpeg4
    /// Sorenson Spark (CloudConvert's "sorenson").
    case flv1
    case msmpeg4v3, wmv2, mpeg2, dnxhr, dv, theora, rv20

    /// The name ffprobe gives a stream of this codec, for "can this stream be copied".
    var probeName: String {
        switch self {
        case .mpeg2: "mpeg2video"
        case .dnxhr: "dnxhd"
        case .dv: "dvvideo"
        default: rawValue
        }
    }

    /// The FFmpeg encoder.
    var encoder: String {
        switch self {
        case .h264: "h264_videotoolbox"
        case .hevc: "hevc_videotoolbox"
        case .prores: "prores_videotoolbox"
        case .av1: "libsvtav1"
        case .vp8: "libvpx"
        case .vp9: "libvpx-vp9"
        case .mpeg4: "mpeg4"
        case .flv1: "flv"
        case .msmpeg4v3: "msmpeg4"
        case .wmv2: "wmv2"
        case .mpeg2: "mpeg2video"
        case .dnxhr: "dnxhd"
        case .dv: "dvvideo"
        case .theora: "libtheora"
        case .rv20: "rv20"
        }
    }

    var isVideoToolbox: Bool { self == .h264 || self == .hevc || self == .prores }

    /// Codecs that carry 10-bit PQ/HLG with its metadata (quality §5.1: HEVC Main10, AV1, ProRes, VP9 profile 2).
    var carriesHDR: Bool { self == .hevc || self == .av1 || self == .prores || self == .vp9 }

    /// Reads the O-VIDEO `videoCodec` choice and CloudConvert's `video_codec` names.
    init?(option: String) {
        switch option.lowercased() {
        case "h264", "x264", "avc", "libx264": self = .h264
        case "hevc", "h265", "x265", "libx265": self = .hevc
        case "prores": self = .prores
        case "av1", "libaom-av1", "svtav1", "libsvtav1": self = .av1
        case "vp8", "libvpx": self = .vp8
        case "vp9", "libvpx-vp9": self = .vp9
        case "xvid", "mpeg4", "libxvid": self = .mpeg4
        case "sorenson", "flv", "flv1": self = .flv1
        case "msmpeg4", "msmpeg4v3": self = .msmpeg4v3
        case "wmv2": self = .wmv2
        case "mpeg2", "mpeg2video": self = .mpeg2
        case "dnxhd", "dnxhr": self = .dnxhr
        case "dv", "dvvideo": self = .dv
        case "theora", "libtheora": self = .theora
        case "rv20", "realvideo": self = .rv20
        default: return nil
        }
    }
}

/// The audio encoders (quality §5.2 transparent defaults; formats §5 O-AUDIO codec list).
enum AudioCodec: String, CaseIterable, Sendable {
    case aac, heAAC, heAACv2, alac, flac, mp3, opus, vorbis, ac3, wmav2, mp2
    case pcm16, pcm24, pcm32, float32, pcm8
    case mulaw, alaw, amrNB, amrWB

    /// The name ffprobe gives such a stream (for copy decisions); PCM is matched by family in `canCopy`.
    var probeName: String {
        switch self {
        case .aac, .heAAC, .heAACv2: "aac"
        case .amrNB: "amr_nb"
        case .amrWB: "amr_wb"
        case .mulaw: "pcm_mulaw"
        case .alaw: "pcm_alaw"
        case .pcm16: "pcm_s16le"
        case .pcm24: "pcm_s24le"
        case .pcm32: "pcm_s32le"
        case .float32: "pcm_f32le"
        case .pcm8: "pcm_u8"
        default: rawValue
        }
    }

    var isPCM: Bool { [.pcm16, .pcm24, .pcm32, .float32, .pcm8].contains(self) }

    /// Bits per sample of a PCM or lossless codec (nil when it follows the source).
    var bitDepth: Int? {
        switch self {
        case .pcm16: 16
        case .pcm24: 24
        case .pcm32, .float32: 32
        case .pcm8: 8
        default: nil
        }
    }

    /// Reads the O-AUDIO `codec` choice and CloudConvert's `audio_codec` names.
    init?(option: String) {
        switch option.lowercased() {
        case "aac", "aac_lc", "aac_at", "libfdk_aac": self = .aac
        case "aac_he_1", "he-aac", "heaac", "aac_he": self = .heAAC
        case "aac_he_2", "he-aac-v2", "heaacv2", "aac_he_v2": self = .heAACv2
        case "alac": self = .alac
        case "flac": self = .flac
        case "mp3", "libmp3lame", "lame": self = .mp3
        case "opus", "libopus": self = .opus
        case "vorbis", "libvorbis": self = .vorbis
        case "ac3", "ac-3": self = .ac3
        case "wma", "wmav2": self = .wmav2
        case "mp2": self = .mp2
        case "pcm_s16le", "pcm_s16be", "pcm16", "pcm": self = .pcm16
        case "pcm_s24le", "pcm_s24be", "pcm24": self = .pcm24
        case "pcm_s32le", "pcm_s32be", "pcm32": self = .pcm32
        case "pcm_f32le", "pcm_f32be", "float", "float32", "32f": self = .float32
        case "pcm_u8", "pcm8": self = .pcm8
        case "mulaw", "pcm_mulaw", "ulaw", "µ-law": self = .mulaw
        case "alaw", "pcm_alaw", "a-law": self = .alaw
        case "amr_nb", "amrnb", "libopencore_amrnb", "amr": self = .amrNB
        case "amr_wb", "amrwb", "libvo_amrwbenc": self = .amrWB
        default: return nil
        }
    }
}

/// What an output container holds (formats §5 "Codecs per output container"; CloudConvert offers codecs some containers
/// cannot carry — we list only the ones that work).
struct MediaContainer: Sendable {
    enum Subtitles: Sendable, Equatable {
        /// No subtitle streams.
        case none
        /// Text subtitles in this codec (`mov_text`, `webvtt`, `srt`), bitmap ones dropped.
        case text(String)
        /// Text and bitmap subtitles as they are (Matroska); text that must change codec becomes `srt`/`ass`.
        case any
        /// DVD bitmap subtitles only (MPEG program streams).
        case dvd
    }

    let format: FormatID
    /// FFmpeg's muxer.
    let muxer: String
    let isVideo: Bool
    /// Encoders offered, the default first.
    let videoCodecs: [VideoCodec]
    let audioCodecs: [AudioCodec]
    /// ffprobe codec names a stream may already have to be copied in.
    let copyVideo: Set<String>
    let copyAudio: Set<String>
    let subtitles: Subtitles
    let chapters: Bool
    /// Cover art carried as an attached picture.
    let coverArt: Bool
    /// The container needs a constant frame rate (quality §5.1 timing).
    let constantFrameRate: Bool
    /// MP4-family: `+faststart` when "Ready for the web" is on.
    let webReady: Bool
    /// Extra muxer arguments.
    let muxerArguments: [String]

    var defaultVideo: VideoCodec? { videoCodecs.first }
    var defaultAudio: AudioCodec? { audioCodecs.first }

    func canCopyVideo(_ codec: String) -> Bool { copyVideo.contains(codec) }
    func canCopyAudio(_ codec: String) -> Bool {
        if copyAudio.contains(codec) { return true }
        // PCM of another width or byte order is not a copy: WAV ↔ AIFF re-packs samples (bit-exact, quality §5.2).
        return false
    }

    // MARK: The table

    static func of(_ format: FormatID) -> MediaContainer? { table[format] }

    private static let mp4Video: Set<String> = ["h264", "hevc", "av1", "mpeg4", "vp9", "mpeg2video", "mjpeg"]
    private static let mp4Audio: Set<String> = ["aac", "mp3", "ac3", "eac3", "alac", "opus", "flac"]
    private static let movVideo: Set<String> = mp4Video.union(["prores", "dnxhd", "dvvideo", "png", "qtrle", "rawvideo"])
    private static let movAudio: Set<String> = mp4Audio.union(["pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_f32le", "pcm_f32be", "pcm_alaw", "pcm_mulaw", "amr_nb"])
    private static let mkvVideo: Set<String> = ["h264", "hevc", "av1", "vp8", "vp9", "mpeg4", "mpeg2video", "mpeg1video", "msmpeg4v3", "wmv2", "wmv3", "vc1",
                                                 "theora", "prores", "dnxhd", "ffv1", "mjpeg", "dvvideo", "flv1", "cavs"]
    private static let mkvAudio: Set<String> = ["aac", "mp3", "mp2", "ac3", "eac3", "dts", "truehd", "opus", "vorbis", "flac", "alac", "wmav2", "pcm_s16le",
                                                 "pcm_s24le", "pcm_s32le", "pcm_f32le", "amr_nb", "amr_wb"]
    private static let tsVideo: Set<String> = ["h264", "hevc", "mpeg2video", "mpeg1video", "vc1"]
    private static let tsAudio: Set<String> = ["aac", "ac3", "eac3", "mp2", "mp3", "dts", "truehd", "pcm_bluray"]
    private static let psVideo: Set<String> = ["mpeg2video", "mpeg1video"]
    private static let psAudio: Set<String> = ["mp2", "ac3", "pcm_dvd", "mp3"]
    private static let asfVideo: Set<String> = ["msmpeg4v3", "wmv1", "wmv2", "wmv3", "vc1", "mpeg4", "h264", "mpeg2video"]
    private static let asfAudio: Set<String> = ["wmav1", "wmav2", "wmapro", "mp3", "ac3", "mp2", "aac"]

    private static func video(_ f: FormatID, _ muxer: String, _ v: [VideoCodec], _ a: [AudioCodec], copyV: Set<String>, copyA: Set<String>,
                              subs: Subtitles, chapters: Bool = false, cfr: Bool = false, web: Bool = false, args: [String] = []) -> MediaContainer {
        MediaContainer(format: f, muxer: muxer, isVideo: true, videoCodecs: v, audioCodecs: a, copyVideo: copyV, copyAudio: copyA, subtitles: subs,
                       chapters: chapters, coverArt: false, constantFrameRate: cfr, webReady: web, muxerArguments: args)
    }

    private static func audio(_ f: FormatID, _ muxer: String, _ a: [AudioCodec], copy: Set<String>, chapters: Bool = false, cover: Bool = false,
                              args: [String] = []) -> MediaContainer {
        MediaContainer(format: f, muxer: muxer, isVideo: false, videoCodecs: [], audioCodecs: a, copyVideo: [], copyAudio: copy, subtitles: .none,
                       chapters: chapters, coverArt: cover, constantFrameRate: false, webReady: false, muxerArguments: args)
    }

    static let table: [FormatID: MediaContainer] = {
        var t: [FormatID: MediaContainer] = [:]
        func add(_ c: MediaContainer) { t[c.format] = c }
        let threeGP: [VideoCodec] = [.h264]
        // Video (formats §5 O-VIDEO).
        add(video("mp4", "mp4", [.h264, .hevc, .av1], [.aac, .heAAC, .heAACv2, .mp3, .ac3, .alac, .opus], copyV: mp4Video, copyA: mp4Audio,
                  subs: .text("mov_text"), chapters: true, web: true))
        add(video("m4v", "ipod", [.h264, .hevc, .av1], [.aac, .heAAC, .heAACv2, .ac3, .alac], copyV: ["h264", "hevc", "av1", "mpeg4"],
                  copyA: ["aac", "ac3", "alac"], subs: .text("mov_text"), chapters: true, web: true))
        add(video("mov", "mov", [.h264, .hevc, .prores, .av1], [.aac, .heAAC, .heAACv2, .alac, .pcm16, .pcm24, .mp3, .ac3], copyV: movVideo, copyA: movAudio,
                  subs: .text("mov_text"), chapters: true, web: true))
        add(video("mkv", "matroska", [.h264, .hevc, .vp8, .vp9, .av1, .prores], [.aac, .opus, .vorbis, .flac, .mp3, .ac3, .alac], copyV: mkvVideo, copyA: mkvAudio,
                  subs: .any, chapters: true))
        add(video("webm", "webm", [.vp9, .vp8, .av1], [.opus, .vorbis], copyV: ["vp8", "vp9", "av1"], copyA: ["opus", "vorbis"], subs: .text("webvtt"), chapters: true))
        add(video("avi", "avi", [.h264, .hevc, .mpeg4], [.mp3, .aac, .ac3, .pcm16], copyV: ["h264", "hevc", "mpeg4", "msmpeg4v3", "mjpeg", "mpeg2video", "dvvideo", "wmv2"],
                  copyA: ["mp3", "aac", "ac3", "mp2", "pcm_s16le", "pcm_u8"], subs: .none, cfr: true))
        add(video("flv", "flv", [.h264, .flv1], [.aac, .mp3], copyV: ["h264", "flv1"], copyA: ["aac", "mp3"], subs: .none))
        add(video("wmv", "asf", [.msmpeg4v3, .wmv2], [.wmav2], copyV: asfVideo, copyA: asfAudio, subs: .none, cfr: true))
        for f: FormatID in ["3gp", "3gpp"] {
            add(video(f, "3gp", threeGP, [.aac, .amrNB], copyV: ["h264", "h263", "mpeg4"], copyA: ["aac", "amr_nb", "amr_wb"], subs: .text("mov_text"), web: true))
        }
        add(video("3g2", "3g2", threeGP, [.aac], copyV: ["h264", "h263", "mpeg4"], copyA: ["aac", "amr_nb"], subs: .text("mov_text"), web: true))
        add(video("mpeg", "mpeg", [.mpeg2], [.mp2, .ac3], copyV: psVideo, copyA: psAudio, subs: .dvd, cfr: true))
        add(video("mpg", "mpeg", [.mpeg2], [.mp2, .ac3], copyV: psVideo, copyA: psAudio, subs: .dvd, cfr: true))
        add(video("mod", "mpeg", [.mpeg2], [.ac3, .mp2], copyV: psVideo, copyA: psAudio, subs: .none, cfr: true))
        // DVD: the `vob` muxer writes DVD-conformant packs; `-target`-style rate limits are applied with the codec settings.
        add(video("vob", "vob", [.mpeg2], [.ac3, .mp2], copyV: psVideo, copyA: ["ac3", "mp2", "pcm_dvd"], subs: .dvd, cfr: true))
        // DVR-MS is ASF with MPEG-2 video; WTV is Windows Media Center's own container.
        add(video("dvr", "asf", [.mpeg2], [.ac3, .mp2], copyV: ["mpeg2video", "h264", "vc1"], copyA: ["ac3", "mp2", "wmav2"], subs: .none, cfr: true))
        add(video("wtv", "wtv", [.mpeg2], [.ac3, .mp2], copyV: ["mpeg2video", "h264"], copyA: ["ac3", "mp2", "aac"], subs: .none, cfr: true))
        add(video("ts", "mpegts", [.h264], [.aac, .ac3, .mp2], copyV: tsVideo, copyA: tsAudio, subs: .none, cfr: true))
        add(video("m2ts", "mpegts", [.h264], [.aac, .ac3], copyV: tsVideo, copyA: tsAudio, subs: .none, cfr: true, args: ["-mpegts_m2ts_mode", "1"]))
        add(video("mts", "mpegts", [.h264], [.ac3, .aac], copyV: tsVideo, copyA: tsAudio, subs: .none, cfr: true, args: ["-mpegts_m2ts_mode", "1"]))
        add(video("mxf", "mxf", [.dnxhr, .mpeg2], [.pcm24, .pcm16], copyV: ["dnxhd", "mpeg2video", "dvvideo", "h264", "prores"],
                  copyA: ["pcm_s16le", "pcm_s24le"], subs: .none, cfr: true))
        add(video("dv", "dv", [.dv], [.pcm16], copyV: ["dvvideo"], copyA: ["pcm_s16le"], subs: .none, cfr: true))
        add(video("ogv", "ogg", [.theora], [.vorbis, .opus], copyV: ["theora", "vp8"], copyA: ["vorbis", "opus", "flac"], subs: .none, chapters: true))
        add(video("rm", "rm", [.rv20], [.ac3], copyV: ["rv10", "rv20"], copyA: ["ac3", "cook"], subs: .none, cfr: true))
        add(video("rmvb", "rm", [.rv20], [.ac3], copyV: ["rv10", "rv20", "rv30", "rv40"], copyA: ["ac3", "cook"], subs: .none, cfr: true))
        add(video("swf", "swf", [.flv1], [.mp3], copyV: ["flv1"], copyA: ["mp3"], subs: .none, cfr: true))
        // Audio (formats §5 O-AUDIO "Codecs per container").
        add(audio("aac", "adts", [.aac, .heAAC, .heAACv2], copy: ["aac"]))
        add(audio("m4a", "ipod", [.aac, .heAAC, .heAACv2, .alac], copy: ["aac", "alac"], chapters: true, cover: true))
        add(audio("m4b", "ipod", [.aac, .heAAC, .heAACv2], copy: ["aac"], chapters: true, cover: true))
        add(audio("wav", "wav", [.pcm16, .pcm24, .pcm32, .float32, .pcm8], copy: ["pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_u8"], args: ["-rf64", "auto"]))
        for f: FormatID in ["aiff", "aif"] {
            add(audio(f, "aiff", [.pcm16, .pcm24, .pcm32], copy: ["pcm_s16be", "pcm_s24be", "pcm_s32be"], args: ["-write_id3v2", "1"]))
        }
        add(audio("aifc", "aiff", [.pcm16, .pcm24, .pcm32, .float32], copy: ["pcm_s16be", "pcm_s24be", "pcm_s32be", "pcm_f32be"]))
        add(audio("caf", "caf", [.aac, .alac, .pcm16, .pcm24, .float32, .opus], copy: ["aac", "alac", "pcm_s16le", "pcm_s24le", "pcm_f32le", "pcm_s16be", "pcm_s24be", "opus"]))
        add(audio("flac", "flac", [.flac], copy: ["flac"], cover: true))
        add(audio("mp3", "mp3", [.mp3], copy: ["mp3"], cover: true, args: ["-id3v2_version", "4"]))
        for f: FormatID in ["ogg", "oga"] { add(audio(f, "ogg", [.vorbis, .opus, .flac], copy: ["vorbis", "opus", "flac"], chapters: true)) }
        add(audio("opus", "opus", [.opus], copy: ["opus"]))
        add(audio("weba", "webm", [.opus, .vorbis], copy: ["opus", "vorbis"]))
        add(audio("wma", "asf", [.wmav2], copy: ["wmav2", "wmav1"]))
        add(audio("ac3", "ac3", [.ac3], copy: ["ac3"]))
        add(audio("amr", "amr", [.amrNB], copy: ["amr_nb"]))
        add(audio("au", "au", [.pcm16, .mulaw, .alaw], copy: ["pcm_s16be", "pcm_mulaw", "pcm_alaw"]))
        add(audio("voc", "voc", [.pcm16, .pcm8], copy: ["pcm_s16le", "pcm_u8"]))
        return t
    }()
}
