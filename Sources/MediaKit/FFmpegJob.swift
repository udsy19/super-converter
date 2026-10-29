import Foundation
import SuperConverterCore

/// One FFmpeg run, planned: the arguments (inputs, maps, filters, codecs, tags), the muxer, the plan it carries out, the
/// output's length for progress, and what it could not keep (quality §1 loss notes).
struct FFmpegJob: Sendable {
    var arguments: [String] = []
    var muxer: String
    var duration: Double?
    var plan: MediaPlan
    var lossNotes: [LossNote] = []
    var warnings: [String] = []
    /// The muxer options that end `arguments` (timecode, fast start, the container's own), for a later re-wrap.
    var muxing: [String] = []
    /// HEVC HDR10: the prefix SEI to write into the encoded video (`HDRSEI`).
    var hdrSEI: Data?
}

/// What the planner found out about the source besides `ffprobe`'s word (each costs a decoding pass).
struct SourceFacts: Sendable {
    var interlaced = false
    /// Two-pass loudness: the first pass's measurement (EBU R128, `loudnorm`).
    var loudnorm: LoudnormMeasurement?
    /// True peak of the source, dBTP (decides whether the limiter is needed for a gain change).
    var truePeak: Double?
}

struct LoudnormMeasurement: Sendable, Equatable {
    var integrated: Double, truePeak: Double, range: Double, threshold: Double, offset: Double
}

/// Turns a probe, a target container and the person's options into FFmpeg arguments (formats §5; quality §5).
enum FFmpegPlanner {
    /// A peak above this after a gain change engages the limiter (quality §5.2: −1 dBTP).
    static let limiterCeiling = -1.0

    static func job(source: URL, sourceFormat: FormatID, probe: MediaProbe, target: MediaContainer, settings s: MediaSettings,
                    facts: SourceFacts = SourceFacts(), externalSubtitles: URL? = nil, inputFormat: [String] = []) throws -> FFmpegJob {
        var job = FFmpegJob(muxer: target.muxer, duration: s.outputDuration(probe.duration),
                            plan: MediaPlan(engine: .ffmpeg, container: target.format, duration: s.outputDuration(probe.duration),
                                            trimStart: s.trimStart, trimEnd: s.trimEnd,
                                            chapters: probe.chapters.map { MediaPlan.Chapter(title: $0.title, start: $0.start) }))
        var args: [String] = []
        if let start = s.trimStart { args += ["-ss", MediaTime.argument(start)] }
        if let end = s.trimEnd { args += ["-to", MediaTime.argument(end)] }
        args += inputFormat + ["-i", source.path]
        var nextInput = 1

        // MARK: Video
        var videoCopied = false
        var vcodec: VideoCodec?
        var filterComplex: [String] = []
        var maps: [String] = []
        var streamArgs: [String] = []
        let video = target.isVideo ? probe.mainVideo : nil
        if let video {
            let choice = s.videoCodec.lowercased()
            let sameFormat = sourceFormat == target.format
            let explicit = VideoCodec(option: choice)
            let deinterlace = facts.interlaced && s.deinterlace
            let hdrChange = video.colour.isHDR && (s.hdrToSDR || !(explicit ?? target.defaultVideo!).carriesHDR)
            // SWF's demuxer gives FLV1 packets without usable timestamps: re-encode rather than copy them.
            let copyAllowed = target.canCopyVideo(video.codec) && sourceFormat != "swf" && !s.changesVideo && !(deinterlace && !sameFormat) && !hdrChange
                && (explicit == nil || explicit!.probeName == video.codec)
            if choice == "copy" && !target.canCopyVideo(video.codec) {
                job.warnings.append("The video stream can’t be kept as it is in \(target.format.pill), so it was converted")
            }
            if (choice == "copy" && target.canCopyVideo(video.codec) && sourceFormat != "swf") || ((choice == "auto" || explicit != nil) && copyAllowed) {
                videoCopied = true
                maps += ["-map", "0:\(video.index)"]
                streamArgs += ["-c:v", "copy"]
                if video.codec == "hevc", ["mp4", "mov", "m4v"].contains(target.format.rawValue) { streamArgs += ["-tag:v", "hvc1"] }
                if video.codec == "mpeg4", target.format == "avi" { streamArgs += ["-tag:v", "XVID"] }
            } else {
                let codec = explicit.flatMap { target.videoCodecs.contains($0) ? $0 : nil } ?? target.defaultVideo!
                if let explicit, !target.videoCodecs.contains(explicit) {
                    job.warnings.append("\(target.format.pill) can’t hold \(explicit.rawValue.uppercased()) video, so \(codec.rawValue.uppercased()) was used")
                }
                vcodec = codec
                let encode = try VideoEncoding.plan(video: video, probe: probe, codec: codec, target: target, settings: s, facts: facts,
                                                    sourceFormat: sourceFormat)
                job.lossNotes += encode.lossNotes
                job.hdrSEI = encode.hdrSEI
                var chain = encode.filters
                var label = "[0:\(video.index)]"
                // Hard subtitles burn in after scaling (the text keeps its size relative to the new picture), before the final
                // pixel format.
                if s.subtitles == .hard {
                    if let file = externalSubtitles {
                        chain.insert("subtitles=filename=\(FilterText.escape(file.path))", at: chain.count - 1)
                    } else if let sub = probe.subtitles.first {
                        if sub.isTextSubtitle {
                            let ordinal = probe.subtitles.firstIndex(of: sub)!
                            chain.insert("subtitles=filename=\(FilterText.escape(source.path)):si=\(ordinal)", at: chain.count - 1)
                        } else {
                            filterComplex.append("\(label)\(chain.isEmpty ? "null" : chain.joined(separator: ","))[vpre]")
                            filterComplex.append("[vpre][0:\(sub.index)]overlay=eof_action=pass:format=auto,format=\(encode.pixelFormat)[vsub]")
                            label = "[vsub]"; chain = []
                        }
                    }
                }
                if let mark = s.watermark {
                    args += ["-i", mark.path]
                    let input = nextInput; nextInput += 1
                    filterComplex.append("\(label)\(chain.isEmpty ? "null" : chain.joined(separator: ","))[vmain]")
                    let opacity = s.watermarkOpacity < 1 ? ",colorchannelmixer=aa=\(String(format: "%.3f", s.watermarkOpacity))" : ""
                    // The mark keeps its own size up to a quarter of the frame's width; 3 % margin from the chosen corner.
                    filterComplex.append("[\(input):v]format=rgba\(opacity),scale=w='min(iw,\(max(encode.width / 4, 2)))':h=-2[mark]")
                    filterComplex.append("[vmain][mark]overlay=\(Watermark.position(s.watermarkCorner)):format=auto,format=\(encode.pixelFormat)[vout]")
                    maps += ["-map", "[vout]"]
                } else if !filterComplex.isEmpty {
                    filterComplex.append("\(label)\(chain.isEmpty ? "null" : chain.joined(separator: ","))[vout]")
                    maps += ["-map", "[vout]"]
                } else {
                    maps += ["-map", "0:\(video.index)"]
                    if !chain.isEmpty { streamArgs += ["-vf", chain.joined(separator: ",")] }
                }
                streamArgs += encode.arguments
            }
            job.plan.streams.append(MediaPlan.Stream(index: video.index, kind: .video, codec: video.codec,
                                                     outputCodec: videoCopied ? nil : vcodec?.rawValue, bitrate: video.bitRate,
                                                     width: video.width, height: video.height, frameRate: video.frameRate,
                                                     isHDR: video.colour.isHDR, language: video.language))
            if probe.video.count > 1 { job.lossNotes.append(LossNote(.tracksDropped, detail: "Only the main video track was kept")) }
        }

        // MARK: Audio
        if !s.removeSound, let plan = try AudioEncoding.plan(probe: probe, sourceFormat: sourceFormat, target: target, settings: s, facts: facts) {
            maps += plan.maps
            streamArgs += plan.arguments
            job.lossNotes += plan.lossNotes
            job.warnings += plan.warnings
            for stream in plan.streams {
                job.plan.streams.append(MediaPlan.Stream(index: stream.index, kind: .audio, codec: stream.codec, outputCodec: plan.outputCodec,
                                                         bitrate: stream.bitRate, sampleRate: stream.sampleRate, channels: stream.channels,
                                                         language: stream.language))
            }
        } else if s.removeSound {
            streamArgs += ["-an"]
        }

        // MARK: Subtitles
        let subtitlePlan = Subtitles.plan(probe: probe, target: target, settings: s, external: externalSubtitles, externalInput: nextInput)
        if externalSubtitles != nil, s.subtitles == .soft { args += ["-i", externalSubtitles!.path] }
        maps += subtitlePlan.maps
        streamArgs += subtitlePlan.arguments
        job.lossNotes += subtitlePlan.lossNotes

        // MARK: Cover art (audio targets)
        if !target.isVideo, let cover = probe.coverArt.first {
            if target.coverArt && s.keepArtwork && ["mjpeg", "png"].contains(cover.codec) {
                maps += ["-map", "0:\(cover.index)"]
                streamArgs += ["-c:v", "copy", "-disposition:v:0", "attached_pic"]
            } else if s.keepArtwork {
                job.lossNotes.append(LossNote(.imagesDropped, detail: "\(target.format.pill) can’t hold cover art"))
            }
        }

        // MARK: Metadata, chapters, timing, muxer
        if !filterComplex.isEmpty { args += ["-filter_complex", filterComplex.joined(separator: ";")] }
        args += maps + streamArgs
        args += ["-map_metadata", "0"]
        if target.chapters && s.keepArtwork { args += ["-map_chapters", "0"] }
        else {
            args += ["-map_chapters", "-1"]
            if !probe.chapters.isEmpty && s.keepArtwork { job.lossNotes.append(LossNote(.chaptersDropped, detail: "\(target.format.pill) can’t hold chapters")) }
        }
        if target.isVideo && video != nil && !videoCopied {
            if !target.constantFrameRate && s.fps == nil { args += ["-fps_mode", "vfr"] }
        }
        if let timecode = probe.tags["timecode"], ["mov", "mxf"].contains(target.format.rawValue) {
            job.muxing += ["-timecode", timecode]
        }
        if target.webReady && s.webReady { job.muxing += ["-movflags", "+faststart"] }
        job.muxing += target.muxerArguments
        if target.format == "m4b" { job.muxing += ["-brand", "M4B "] }
        job.arguments = args + job.muxing
        if !target.isVideo, probe.audio.isEmpty { throw ConversionError.impossiblePair(reason: "This file has no sound to convert.") }
        if target.isVideo, video == nil, probe.audio.isEmpty { throw ConversionError.damaged(sourceFormat) }
        return job
    }
}

/// FFmpeg filter-graph quoting: a path inside `subtitles=filename=…` passes two parsers.
enum FilterText {
    static func escape(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\\", with: "\\\\")
        for c in ["'", ":", ",", ";", "[", "]", "="] { t = t.replacingOccurrences(of: c, with: "\\" + c) }
        return "'" + t.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum Watermark {
    /// Overlay coordinates for a corner, 3 % of the frame's height from the edges (formats §5 O-VIDEO watermark).
    static func position(_ corner: MediaSettings.Corner) -> String {
        let m = "main_h*0.03"
        switch corner {
        case .topLeft: return "x=\(m):y=\(m)"
        case .topRight: return "x=main_w-overlay_w-\(m):y=\(m)"
        case .bottomLeft: return "x=\(m):y=main_h-overlay_h-\(m)"
        case .bottomRight: return "x=main_w-overlay_w-\(m):y=main_h-overlay_h-\(m)"
        case .centre: return "x=(main_w-overlay_w)/2:y=(main_h-overlay_h)/2"
        }
    }
}
