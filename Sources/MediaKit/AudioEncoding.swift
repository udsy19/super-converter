import Foundation
import SuperConverterCore

/// The sound side of an FFmpeg encode (quality §5.2): which tracks, copy or encode, the encoder at its transparent default,
/// soxr resampling, TPDF dither when the bit depth drops, BS.775 down-mix, gain with a true-peak limiter that engages only
/// when it must, two-pass EBU R128 loudness.
struct AudioEncoding {
    var maps: [String] = []
    var arguments: [String] = []
    var streams: [MediaProbe.Stream] = []
    var outputCodec: String?
    var lossNotes: [LossNote] = []
    var warnings: [String] = []

    static func plan(probe: MediaProbe, sourceFormat: FormatID, target: MediaContainer, settings s: MediaSettings,
                     facts: SourceFacts) throws -> AudioEncoding? {
        let all = probe.audio
        guard let main = all.first(where: \.isDefault) ?? all.first else { return nil }
        var e = AudioEncoding()

        // Tracks: one, unless the container holds several and the person (or the MKV ↔ MOV/MP4 default) asks for all.
        let between: Set<FormatID> = ["mkv", "mov", "mp4", "m4v"]
        let wantsAll = s.allAudioStreams ?? (between.contains(sourceFormat) && between.contains(target.format) && sourceFormat != target.format)
        let selected = target.isVideo && wantsAll ? all : [main]
        if selected.count < all.count, all.count > 1 {
            e.lossNotes.append(LossNote(.tracksDropped, detail: "\(all.count - selected.count) of \(all.count) audio tracks"))
        }
        e.streams = selected
        for stream in selected { e.maps += ["-map", "0:\(stream.index)"] }

        let choice = s.audioCodec.lowercased()
        let explicit = AudioCodec(option: choice)
        if choice == "copy" || choice == "auto" || explicit.map({ $0.probeName == main.codec }) == true,
           !s.changesAudio, selected.allSatisfy({ target.canCopyAudio($0.codec) }) {
            e.arguments = ["-c:a", "copy"]
            return e
        }
        if choice == "copy" { e.warnings.append("The sound can’t be kept as it is in \(target.format.pill), so it was converted") }

        var codec = explicit.flatMap { target.audioCodecs.contains($0) ? $0 : nil } ?? defaultCodec(for: target, source: main)
        if let explicit, !target.audioCodecs.contains(explicit) {
            e.warnings.append("\(target.format.pill) can’t hold \(explicit.rawValue) sound, so \(codec.rawValue) was used")
        }
        // PCM and lossless targets keep the source's bit depth (bit-exact chains, quality §5.2) unless the person picked one.
        let sourceBits = bits(of: main)
        if codec.isPCM || codec == .flac || codec == .alac, explicit == nil || explicit?.bitDepth == nil {
            let want = s.bitDepth ?? sourceBits ?? 16
            if codec.isPCM && codec != .pcm8 {
                codec = s.floatSamples || (s.bitDepth == nil && main.sampleFormat?.hasPrefix("flt") == true && sourceBits == 32 && target.audioCodecs.contains(.float32))
                    ? .float32 : (want >= 32 && target.audioCodecs.contains(.pcm32) ? .pcm32 : want > 16 && target.audioCodecs.contains(.pcm24) ? .pcm24 : .pcm16)
            }
        }
        e.outputCodec = codec.rawValue
        let outBits = codec.bitDepth ?? ((codec == .flac || codec == .alac) ? min(s.bitDepth ?? sourceBits ?? 16, 24) : nil)

        // Rate and channels: the person's, then what the codec and container accept.
        let sourceRate = main.sampleRate ?? 48000
        var rate = s.sampleRate ?? sourceRate
        rate = allowedRate(rate, codec: codec, target: target)
        var channels = s.channels ?? main.channels ?? 2
        if codec == .amrNB || codec == .amrWB { channels = 1 }
        if target.format == "dv" || ["mp3", "mp2", "wmav2"].contains(codec.rawValue) { channels = min(channels, 2) }
        if codec == .opus, channels > 8 { channels = 8 }

        // Filters.
        var filters: [String] = []
        if s.volume != 1 { filters.append("volume=\(String(format: "%.4f", s.volume))") }
        var resample = rate != sourceRate
        if let target = s.loudness, let m = facts.loudnorm {
            filters.append("loudnorm=I=\(target):TP=\(limiterCeiling):LRA=11:measured_I=\(m.integrated):measured_TP=\(m.truePeak):measured_LRA=\(m.range)"
                           + ":measured_thresh=\(m.threshold):offset=\(m.offset):linear=true:print_format=none")
            resample = true   // loudnorm works at 192 kHz
        }
        let dropsBits = (outBits ?? 32) < (sourceBits ?? 16) || codec == .pcm8 && (sourceBits ?? 16) > 8
        if resample || dropsBits {
            var r = "aresample=resampler=soxr:precision=28"
            if resample { r += ":osr=\(rate)" }
            if dropsBits, let f = sampleFormat(bits: outBits ?? 16, codec: codec) { r += ":osf=\(f):dither_method=triangular" }
            filters.append(r)
        }
        if s.loudness == nil, s.volume != 1 || resample, let peak = facts.truePeak, peak + 20 * log10(max(s.volume, 1e-6)) > limiterCeiling {
            filters.append("alimiter=limit=\(String(format: "%.4f", pow(10, limiterCeiling / 20))):attack=5:release=50:level=0")
            e.lossNotes.append(LossNote(.otherLoss, detail: "A limiter kept the peaks below −1 dBTP"))
        }
        var a: [String] = []
        if !filters.isEmpty { a += ["-af", filters.joined(separator: ",")] }
        a += encoderArguments(codec, target: target, settings: s, channels: channels, outBits: outBits, rate: rate)
        a += ["-ar", String(rate), "-ac", String(channels)]
        e.arguments = a
        return e
    }

    static let limiterCeiling = FFmpegPlanner.limiterCeiling

    /// The container's default, made lossless when the source is (quality §1: lossless when the target allows it): a CAF of
    /// a WAV is PCM, not AAC.
    static func defaultCodec(for target: MediaContainer, source: MediaProbe.Stream) -> AudioCodec {
        let lossless = source.codec.hasPrefix("pcm_") || ["flac", "alac", "wavpack", "tta", "truehd", "mlp"].contains(source.codec)
        if target.format == "caf", lossless { return .pcm16 }
        return target.defaultAudio ?? .aac
    }

    /// Bits per sample the source really has (24-bit FLAC decodes into 32-bit words).
    static func bits(of s: MediaProbe.Stream) -> Int? {
        if let raw = s.bitsPerSample, raw > 0, s.codec.hasPrefix("pcm_") || ["flac", "alac", "wavpack"].contains(s.codec) { return raw }
        switch s.sampleFormat {
        case "u8", "u8p": return 8
        case "s16", "s16p": return 16
        case "s32", "s32p": return s.codec.hasPrefix("pcm_s24") ? 24 : 32
        case "flt", "fltp", "dbl", "dblp": return s.codec.hasPrefix("pcm_f") ? 32 : nil
        default: return nil
        }
    }

    static func sampleFormat(bits: Int, codec: AudioCodec) -> String? {
        if codec == .float32 { return "flt" }
        switch bits {
        case 8: return "u8"
        case 16: return "s16"
        default: return "s32"
        }
    }

    /// The highest AAC bitrate AudioToolbox accepts for a rate and channel count, kb/s. Its encoder takes only its own steps,
    /// up to about 3 bits per sample and channel (24 kb/s for mono at 8 kHz, 64 for mono at 22.05 kHz, 288 for stereo at 48).
    static func aacCeiling(rate: Int, channels: Int) -> Int {
        let limit = 3 * Double(rate * max(channels, 1)) / 1000
        return aacSteps.last { Double($0) <= limit } ?? aacSteps[0]
    }

    static let aacSteps = [8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 192, 224, 256, 288, 320, 384, 448, 512, 576, 640, 768]

    static func allowedRate(_ rate: Int, codec: AudioCodec, target: MediaContainer) -> Int {
        func nearest(_ set: [Int]) -> Int { set.min { abs($0 - rate) < abs($1 - rate) }! }
        switch codec {
        case .opus: return [48000, 24000, 16000, 12000, 8000].contains(rate) ? rate : 48000
        case .ac3: return nearest([48000, 44100, 32000])
        case .mp2: return nearest([48000, 44100, 32000, 24000, 22050, 16000])
        case .amrNB: return 8000
        case .amrWB: return 16000
        case .mp3 where ["swf", "flv"].contains(target.format.rawValue): return nearest([44100, 22050, 11025])
        case .mp3: return nearest([48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000])
        case .wmav2: return min(rate, 48000)
        // AAC has a fixed set of rates (a VOC file says 22 222 Hz for 22.05 kHz).
        case .aac, .heAAC, .heAACv2: return nearest([8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000])
        default: break
        }
        if ["dv", "mxf", "vob", "dvr", "wtv", "mpeg", "mpg", "mod"].contains(target.format.rawValue) { return 48000 }
        if ["flv"].contains(target.format.rawValue) { return nearest([44100, 22050, 11025]) }
        return rate
    }

    static func encoderArguments(_ codec: AudioCodec, target: MediaContainer, settings s: MediaSettings, channels: Int, outBits: Int?,
                                 rate: Int) -> [String] {
        let bigEndian = ["aiff", "aif", "aifc", "au"].contains(target.format.rawValue)
        func kbps(_ fallback: Int) -> String { "\(s.audioBitrate ?? fallback)k" }
        // AAC carries a limited number of bits per sample: 192 kb/s does not fit mono at 22.05 kHz.
        func aac(_ fallback: Int) -> String { "\(min(s.audioBitrate ?? fallback, aacCeiling(rate: rate, channels: channels)))k" }
        switch codec {
        case .aac:
            // AudioToolbox's AAC, the best on macOS (quality §5.2); 192 kb/s for stereo, 64 kb/s a channel above that.
            return ["-c:a", "aac_at", "-aac_at_mode", "cvbr", "-b:a", aac(channels > 2 ? 64 * channels : 192)]
        case .heAAC: return ["-c:a", "aac_at", "-profile:a", "aac_he", "-b:a", aac(64)]
        case .heAACv2: return ["-c:a", "aac_at", "-profile:a", "aac_he_v2", "-b:a", aac(32)]
        case .alac: return ["-c:a", "alac", "-sample_fmt", (outBits ?? 16) > 16 ? "s32p" : "s16p"]
        case .flac: return ["-c:a", "flac", "-compression_level", String(s.flacLevel), "-sample_fmt", (outBits ?? 16) > 16 ? "s32" : "s16"]
        case .mp3:
            // LAME V0 unless a bitrate was set, then CBR (formats §5 O-AUDIO).
            return s.audioBitrate.map { ["-c:a", "libmp3lame", "-b:a", "\($0)k"] } ?? ["-c:a", "libmp3lame", "-q:a", String(s.mp3Quality)]
        case .opus: return ["-c:a", "libopus", "-b:a", kbps(160), "-vbr", "on"]
        case .vorbis: return s.audioBitrate.map { ["-c:a", "libvorbis", "-b:a", "\($0)k"] } ?? ["-c:a", "libvorbis", "-q:a", "6"]
        case .ac3: return ["-c:a", "ac3", "-b:a", kbps(channels > 2 ? 448 : 192)]
        case .wmav2: return ["-c:a", "wmav2", "-b:a", kbps(192)]
        case .mp2: return ["-c:a", "mp2", "-b:a", kbps(224)]
        case .pcm16: return ["-c:a", bigEndian ? "pcm_s16be" : "pcm_s16le"]
        case .pcm24: return ["-c:a", bigEndian ? "pcm_s24be" : "pcm_s24le"]
        case .pcm32: return ["-c:a", bigEndian ? "pcm_s32be" : "pcm_s32le"]
        case .float32: return ["-c:a", bigEndian ? "pcm_f32be" : "pcm_f32le"]
        case .pcm8: return ["-c:a", "pcm_u8"]
        case .mulaw: return ["-c:a", "pcm_mulaw"]
        case .alaw: return ["-c:a", "pcm_alaw"]
        case .amrNB: return ["-c:a", "libopencore_amrnb", "-b:a", "12.2k"]
        case .amrWB: return ["-c:a", "libvo_amrwbenc", "-b:a", "23.85k"]
        }
    }
}

/// Subtitle streams (formats §5 `subtitles_mode`): kept in the target's own text codec when it has one, dropped with a note
/// when it has none; a file given for "soft" is added as a stream, one for "hard" is burned in by the video side.
struct Subtitles {
    var maps: [String] = []
    var arguments: [String] = []
    var lossNotes: [LossNote] = []

    static func plan(probe: MediaProbe, target: MediaContainer, settings s: MediaSettings, external: URL?, externalInput: Int) -> Subtitles {
        var p = Subtitles()
        guard target.isVideo else { return p }
        let mode = s.subtitles
        if mode == .none || mode == .hard { p.arguments = ["-sn"]; return p }
        var count = 0, dropped = 0
        func add(_ spec: String, codec: String) {
            p.maps += ["-map", spec]
            p.arguments += ["-c:s:\(count)", codec]
            count += 1
        }
        for sub in probe.subtitles {
            switch target.subtitles {
            case .none: dropped += 1
            case .text(let codec): if sub.isTextSubtitle { add("0:\(sub.index)", codec: codec) } else { dropped += 1 }
            case .any: add("0:\(sub.index)", codec: sub.codec == "mov_text" || sub.codec == "text" ? "srt" : "copy")
            case .dvd: if sub.codec == "dvd_subtitle" { add("0:\(sub.index)", codec: "copy") } else { dropped += 1 }
            }
        }
        if mode == .soft, let external {
            let ass = ["ass", "ssa"].contains(external.pathExtension.lowercased())
            switch target.subtitles {
            case .text(let codec): add("\(externalInput):0", codec: codec)
            case .any: add("\(externalInput):0", codec: ass ? "ass" : "srt")
            case .none, .dvd: dropped += 1
            }
        }
        if dropped > 0 { p.lossNotes.append(LossNote(.subtitlesDropped, detail: "\(target.format.pill) can’t hold \(dropped == 1 ? "these subtitles" : "\(dropped) of the subtitle tracks")")) }
        if count == 0 { p.arguments.append("-sn") }
        return p
    }
}
