import AVFoundation
import CoreMedia
import Foundation
import SuperConverterCore

/// What AVFoundation says about a file: whether Apple's frameworks can open and decode it, and its tracks.
struct AVSource: @unchecked Sendable {
    let url: URL
    let asset: AVURLAsset
    let readable: Bool
    let decodable: Bool
    let videoTracks: Int
    let audioTracks: Int
    let hasChapters: Bool
    let duration: Double?
    /// Size as shown (the track transform applied) and frame rate of the first video track.
    let displaySize: (width: Int, height: Int)?
    let frameRate: Double?
    let audioRate: Int?
    let audioChannels: Int?
    /// Bits of integer PCM sound, nil for compressed sound.
    let audioBits: Int?
}

enum AVProbe {
    static func load(_ url: URL, sourceFormat: FormatID) async throws -> AVSource {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        if (try? await asset.load(.hasProtectedContent)) == true { throw ConversionError.drmProtected }
        let readable = (try? await asset.load(.isReadable)) ?? false
        let tracks = readable ? ((try? await asset.load(.tracks)) ?? []) : []
        var decodable = readable && !tracks.isEmpty
        var video = 0, audio = 0
        var size: (Int, Int)?, rate: Double?, audioRate: Int?, channels: Int?, bits: Int?
        for track in tracks {
            let type = track.mediaType
            guard type == .video || type == .audio else { continue }
            if (try? await track.load(.isDecodable)) != true { decodable = false }
            if type == .video {
                if video == 0 {
                    let natural = (try? await track.load(.naturalSize)) ?? .zero
                    let transform = (try? await track.load(.preferredTransform)) ?? .identity
                    let shown = natural.applying(transform)
                    size = (Int(abs(shown.width).rounded()), Int(abs(shown.height).rounded()))
                    rate = (try? await track.load(.nominalFrameRate)).map(Double.init).flatMap { $0 > 0 ? $0 : nil }
                }
                video += 1
            } else {
                if audio == 0, let desc = try? await track.load(.formatDescriptions).first,
                   let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    audioRate = Int(asbd.mSampleRate); channels = Int(asbd.mChannelsPerFrame)
                    if asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0 { bits = Int(asbd.mBitsPerChannel) }
                }
                audio += 1
            }
        }
        let chapters = ((try? await asset.load(.availableChapterLocales)) ?? []).isEmpty == false
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds).flatMap { $0.isFinite ? $0 : nil }
        return AVSource(url: url, asset: asset, readable: readable, decodable: decodable, videoTracks: video, audioTracks: audio, hasChapters: chapters,
                        duration: duration, displaySize: size, frameRate: rate, audioRate: audioRate, audioChannels: channels, audioBits: bits)
    }
}

/// What the AVFoundation route will do (`AVPipeline` carries it out).
struct AVPlan: Sendable {
    struct Video: Sendable {
        var copy: Bool
        var codec: VideoCodec
        var proresProfile: String
        var h264Profile: String
        var crf: Int
        var keyframeInterval: Int?
        var frameRate: Double?
        var fast: Bool
        var hardware: Bool
        /// Size as shown; nil keeps the source's.
        var outputSize: (width: Int, height: Int)?
        var fit: MediaSettings.Fit
        var colour: ColourTags
        var tenBit: Bool
    }

    struct Audio: Sendable {
        var copy: Bool
        var codec: AudioCodec
        var bitrate: Int?
        var sampleRate: Int?
        var channels: Int?
        var bits: Int
        /// TPDF dither before the writer quantises to fewer bits (quality §5.2).
        var dither: Bool
    }

    var target: FormatID
    var trimStart: Double?
    var trimDuration: Double?
    var expectedDuration: Double?
    var webReady: Bool
    var video: Video?
    /// One entry per audio track kept, in track order.
    var audio: [Audio]

    var copiesEverything: Bool { (video?.copy ?? true) && audio.allSatisfy(\.copy) }
}

/// Copy first, then AVFoundation, then FFmpeg (quality §5.1): the AVFoundation route takes a job when Apple's frameworks
/// read every track and the options ask only for what AVAssetWriter does — H.264/HEVC/ProRes, AAC/ALAC/PCM, size by fit,
/// trim, rate, channels, bit depth. Everything else (other codecs, filters, subtitles, chapters, HDR, interlaced
/// sources, loudness) goes to FFmpeg.
enum RouteChoice {
    enum Choice { case avFoundation(AVPlan), ffmpeg(String) }

    static let writerTypes: [FormatID: AVFileType] = ["mov": .mov, "mp4": .mp4, "m4v": .m4v, "3gp": .mobile3GPP, "3gpp": .mobile3GPP,
                                                     "m4a": .m4a, "m4b": .m4a, "wav": .wav, "aiff": .aiff, "aif": .aiff, "aifc": .aifc, "caf": .caf]

    static func choose(asset: AVSource, probe: MediaProbe?, sourceFormat: FormatID, target: MediaContainer, settings s: MediaSettings,
                       facts: SourceFacts, ffmpegAvailable: Bool) -> Choice {
        guard asset.readable, asset.decodable else { return .ffmpeg("Apple’s frameworks can’t decode every stream in this file") }
        guard writerTypes[target.format] != nil || target.format == "aac" || target.format == "flac" else {
            return .ffmpeg("AVFoundation can’t write \(target.format.pill)")
        }
        // AudioToolbox's FLAC writer has a fixed 4096-frame packet and no tags: FFmpeg's FLAC is better when it is here.
        if target.format == "flac" && ffmpegAvailable { return .ffmpeg("FLAC is written by FFmpeg") }
        if s.volume != 1 || s.loudness != nil { return .ffmpeg("Gain and loudness are FFmpeg filters") }
        // soxr (quality §5.2) when the bundled FFmpeg is here; AudioConverter's mastering quality otherwise.
        if ffmpegAvailable, let rate = s.sampleRate, rate != asset.audioRate { return .ffmpeg("Resampling uses soxr") }
        if let probe {
            if target.isVideo && !probe.subtitles.isEmpty && s.subtitles != .none { return .ffmpeg("Subtitles are carried by FFmpeg") }
            if !probe.chapters.isEmpty && target.chapters && s.keepArtwork { return .ffmpeg("Chapters are carried by FFmpeg") }
            if probe.mainVideo?.colour.isHDR == true && target.isVideo { return .ffmpeg("HDR is handled by FFmpeg") }
            if !target.isVideo && !probe.coverArt.isEmpty && s.keepArtwork && target.coverArt { return .ffmpeg("Cover art is carried by FFmpeg") }
        }
        var plan = AVPlan(target: target.format, trimStart: s.trimStart, trimDuration: s.trimEnd.map { $0 - (s.trimStart ?? 0) },
                          expectedDuration: s.outputDuration(asset.duration), webReady: s.webReady && target.webReady, video: nil, audio: [])

        // Picture.
        if target.isVideo, asset.videoTracks > 0, let shown = asset.displaySize {
            if facts.interlaced && s.deinterlace { return .ffmpeg("Interlaced video is deinterlaced by FFmpeg") }
            if s.fps != nil || s.aspectRatio != nil || s.watermark != nil || s.subtitles == .hard || s.hdrToSDR || s.fit == .pad || s.subtitleFile != nil {
                return .ffmpeg("These picture options are FFmpeg filters")
            }
            let source = probe?.mainVideo
            let explicit = VideoCodec(option: s.videoCodec)
            if s.videoCodec != "auto" && s.videoCodec != "copy" && explicit == nil { return .ffmpeg("Unknown video codec") }
            let copyable = source.map { target.canCopyVideo($0.codec) } ?? true
            let copy = (s.videoCodec == "copy" || (explicit == nil || explicit?.probeName == source?.codec)) && copyable && !s.changesVideo
            let codec = copy ? (explicit ?? .h264) : (explicit ?? target.defaultVideo ?? .h264)
            guard copy || [.h264, .hevc].contains(codec) || codec == .prores && target.format == "mov" else {
                return .ffmpeg("\(codec.label) is encoded by FFmpeg")
            }
            if ["3gp", "3gpp"].contains(target.format.rawValue), !copy, codec != .h264 { return .ffmpeg("3GP holds H.264 only") }
            // AVAssetReader hands 4:2:0 buffers over untouched only from H.264 and HEVC; other decoders (MPEG-4 Part 2, ProRes,
            // DV) give 4:2:2 or RGB that it subsamples coarsely (measured: chroma SSIM 0.977 against FFmpeg's 0.994).
            if !copy, let codec = source?.codec, !["h264", "hevc"].contains(codec) { return .ffmpeg("\(codec) is decoded by FFmpeg") }
            var size: (Int, Int)?
            if s.width != nil || s.height != nil {
                let g = Geometry.fit(source: (shown.width, shown.height), box: (s.width, s.height), fit: s.fit)
                size = (Geometry.even(g.finalW), Geometry.even(g.finalH))
            }
            let colour = source.map { ColourTags($0.colour, height: shown.height) } ?? ColourTags(MediaProbe.Colour(), height: shown.height)
            plan.video = AVPlan.Video(copy: copy, codec: codec, proresProfile: s.profile.flatMap(VideoEncoding.proresProfile) ?? "hq",
                                      h264Profile: s.profile.map(VideoEncoding.h264Profile) ?? (["3gp", "3gpp"].contains(target.format.rawValue) ? "baseline" : "high"),
                                      crf: s.crf, keyframeInterval: s.keyframeInterval ?? asset.frameRate.map { Int(($0 * 2).rounded()) },
                                      frameRate: asset.frameRate, fast: s.speed == .fast, hardware: s.hardware, outputSize: size, fit: s.fit,
                                      colour: colour, tenBit: (source?.bitDepth ?? 8) > 8 && codec != .h264)
        } else if target.isVideo {
            return .ffmpeg("There is no picture AVFoundation can read")
        }

        // Sound.
        if asset.audioTracks > 0 && !s.removeSound {
            let source = probe?.audio.first
            let explicit = AudioCodec(option: s.audioCodec)
            if s.audioCodec != "auto" && s.audioCodec != "copy" && explicit == nil { return .ffmpeg("Unknown audio codec") }
            let copyable = source.map { target.canCopyAudio($0.codec) } ?? false
            let copy = (s.audioCodec == "copy" || explicit == nil || explicit?.probeName == source?.codec) && copyable && !s.changesAudio
            var codec = explicit.flatMap { target.audioCodecs.contains($0) ? $0 : nil }
                ?? (source.map { AudioEncoding.defaultCodec(for: target, source: $0) } ?? target.defaultAudio ?? .aac)
            let sourceBits = asset.audioBits ?? source.flatMap(AudioEncoding.bits) ?? 16
            let bits = s.bitDepth ?? sourceBits
            if codec.isPCM {
                codec = s.floatSamples ? .float32 : (bits >= 32 && target.audioCodecs.contains(.pcm32) ? .pcm32 : bits > 16 && target.audioCodecs.contains(.pcm24) ? .pcm24 : .pcm16)
                if codec == .float32 && !target.audioCodecs.contains(.float32) { codec = .pcm24 }
            }
            guard copy || [.aac, .heAAC, .heAACv2, .alac, .flac, .pcm16, .pcm24, .pcm32, .float32].contains(codec) else {
                return .ffmpeg("\(codec.rawValue) is encoded by FFmpeg")
            }
            let outBits = codec.bitDepth ?? min(bits, 24)
            let rate = s.sampleRate.map { AudioEncoding.allowedRate($0, codec: codec, target: target) }
            let count = target.isVideo && (s.allAudioStreams ?? false) ? asset.audioTracks : 1
            let track = AVPlan.Audio(copy: copy, codec: codec, bitrate: s.audioBitrate, sampleRate: rate, channels: s.channels, bits: outBits,
                                     dither: !copy && codec != .float32 && outBits < sourceBits)
            plan.audio = Array(repeating: track, count: count)
        } else if !target.isVideo {
            return .ffmpeg("There is no sound AVFoundation can read")
        }
        if target.format == "aac" && plan.audio.first?.copy == true { return .ffmpeg("ADTS re-wraps are FFmpeg’s") }
        return .avFoundation(plan)
    }
}
