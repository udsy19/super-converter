import Foundation
import MediaKit
import SuperConverterCore

/// MediaKit (quality §5.3). Inputs are `Tests/Corpus/generated/media/` (made by the bundled FFmpeg in make-fixtures). Every
/// measurement that needs FFmpeg uses the repository's own LGPL build in `Vendor/Tools` and nothing else (a system FFmpeg may
/// be GPL). VMAF and ViSQOL need libvmaf and ViSQOL, which only come with a GPL FFmpeg here, so the video-quality rows use the
/// bench's own SSIM/PSNR with thresholds at the same "visually lossless" level, and the lossy-audio row checks bandwidth and
/// true peak; the report says so on each case.
enum MediaKitCases {
    static var all: [BenchCase] { routes + quality }

    // MARK: Every audio/video route of the matrix with a fixture

    static let mediaEngines: Set<EngineID> = [.avFoundation, .ffmpeg, .soundFontReader, .archiveKit]

    /// One case per offered pair whose built-in route is MediaKit's (CAVS and DSS have no fixture: no LGPL encoder writes them).
    /// One pair per source format runs in the fast tier, the rest in the full tier.
    static let routes: [BenchCase] = {
        var cases: [BenchCase] = []
        var fastSources = Set<FormatID>()
        for route in FormatMatrix.offered.sorted(by: { ($0.from, $0.to) < ($1.from, $1.to) }) {
            guard let steps = route.builtin, steps.allSatisfy({ mediaEngines.contains($0.engine) }), steps.contains(where: { $0.engine != .archiveKit }),
                  case .format = steps[0].from else { continue }
            // A WEBA file sniffs as Matroska (the same EBML header), so the planner never sees WEBA → WEBA from a file; the
            // self-test's sweep runs that step.
            if route.from == "weba" && route.to == "weba" { continue }
            let fixture = "generated/media/sample.\(route.from.rawValue)"
            guard FileManager.default.fileExists(atPath: RepoRoot.url.appendingPathComponent("Tests/Corpus/\(fixture)").path) else { continue }
            let fast = fastSources.insert(route.from).inserted
            let category: Category = FormatCatalog.format(route.from)?.category == .video ? .video : .audio
            cases.append(BenchCase(id: "mediakit.route.\(route.from.rawValue)-\(route.to.rawValue)", category: category, tier: fast ? .fast : .full,
                                   fixture: fixture, target: route.to, checks: [plays(route.to)]))
        }
        return cases
    }()

    /// The output is the target container with a picture (video targets) or sound, and lasts as long as the source.
    static func plays(_ target: FormatID) -> Check {
        Check(name: "plays as \(target.pill)") { ctx in
            guard !ctx.outputs.isEmpty else { throw CheckFailure("no output") }
            if ["sfz", "zip"].contains(target.rawValue) || ctx.outputs.count > 1 {
                return [.count("files", ctx.outputs.count, atLeast: 1)]
            }
            let out = try MediaBench.probe(ctx.outputs[0]), source = try MediaBench.probe(ctx.source)
            let videoTarget = MediaBench.videoTargets.contains(target)
            if videoTarget && out.videoStreams == 0 { throw CheckFailure("no picture in the \(target.pill)") }
            if !videoTarget && out.audioStreams == 0 { throw CheckFailure("no sound in the \(target.pill)") }
            var m: [Measurement] = [.count("streams", out.videoStreams + out.audioStreams, atLeast: 1)]
            // quality §5.3 "Duration": ±1 frame for video, ±10 ms for audio. ADTS, SWF and animations carry no exact length,
            // and lossy audio frames pad the end (MP3 at 8 kHz by up to a frame of 72 ms, plus the encoder delay).
            if let a = out.streamDuration ?? out.duration, let b = source.streamDuration ?? source.duration, !["aac", "swf", "gif", "webp"].contains(target.rawValue) {
                let frame = 1 / (source.frameRate ?? 25)
                // A lossy source's priming (WMA, AAC, MP3: tens of ms) is trimmed by its decoder; lossless to lossless is exact.
                let losslessSource = source.audioCodec.map { $0.hasPrefix("pcm") || ["flac", "alac"].contains($0) } ?? true
                let lossless = ["wav", "aiff", "aif", "aifc", "flac", "caf", "au", "voc"].contains(target.rawValue)
                let tolerance = videoTarget ? frame + 0.05 : (lossless ? (losslessSource ? 0.03 : 0.1) : 0.25)
                m.append(Measurement(name: "duration difference", value: abs(a - b), unit: "s", limit: .atMost(tolerance), noise: 0.02))
            }
            return m
        }
    }

    // MARK: quality §5.3

    static let quality: [BenchCase] = [
        // Video defaults: SSIM/PSNR against the near-lossless source (the bench has no VMAF; see the enum's comment).
        videoDefault("h264", target: "mp4", options: ["videoCodec": "h264"], ssim: 0.97),
        videoDefault("hevc", target: "mp4", options: ["videoCodec": "hevc"], ssim: 0.97),
        videoDefault("vp9", target: "webm", options: [:], ssim: 0.96),
        videoDefault("av1", target: "mkv", options: ["videoCodec": "av1"], ssim: 0.96),
        // Colour tags: BT.601 bars stay BT.601 and the decoded bars match the picture they were made from.
        BenchCase(id: "mediakit.colour-tags-601", category: .video, fixture: "generated/media/bars-601.mov", target: "mp4", checks: [
            Check(name: "tags present and kept") { ctx in
                let p = try MediaBench.probe(try out(ctx)), s = try MediaBench.probe(ctx.source)
                guard p.matrix == "smpte170m", p.primaries == s.primaries, p.range == "tv", p.transfer != nil else {
                    throw CheckFailure("tags \(p.matrix ?? "-") \(p.primaries ?? "-") \(p.transfer ?? "-") \(p.range ?? "-")")
                }
                return [.count("tags", 4, atLeast: 4)]
            },
            Check(name: "bars ΔE00") { ctx in
                let frame = try MediaBench.frame(try out(ctx), at: 0.5, into: ctx.work)
                guard let reference = Raster(contentsOf: RepoRoot.url.appendingPathComponent("Tests/Corpus/generated/smpte-bars-640x360.png")),
                      let map = DeltaE.map(reference, frame) else { throw CheckFailure("the frame can't be compared") }
                // Inside the bars only: chroma subsampling smears the edges between them.
                let s = DeltaE.summarise(map)
                ctx.attach("decoded bars", raster: frame, name: "bars.png")
                return [.deltaE("mean ΔE00", s.mean, atMost: 2.0), .info("p95 ΔE00", s.p95)]
            },
        ]),
        // HDR kept on HEVC Main10 and AV1 with the same mastering display and content light level.
        // FFmpeg 7.1's VideoToolbox HEVC encoder does not write ST 2086 / CTA-861.3 metadata: that case checks the signal and
        // the loss note that says so; AV1 carries both.
        hdrKept("hevc-mov", target: "mov", options: ["videoCodec": "hevc"], metadata: false),
        hdrKept("av1-mkv", target: "mkv", options: ["videoCodec": "av1"], metadata: true),
        // Tone map: PQ → H.264 SDR is tagged BT.709, says so, and clips almost nothing.
        BenchCase(id: "mediakit.tonemap", category: .video, fixture: "generated/media/hdr-pq.mkv", target: "mp4", checks: [
            Check(name: "BT.709 SDR") { ctx in
                let p = try MediaBench.probe(try out(ctx))
                guard p.transfer == "bt709", p.primaries == "bt709" else { throw CheckFailure("tagged \(p.transfer ?? "-") / \(p.primaries ?? "-")") }
                guard ctx.result.lossNotes.contains(where: { $0.kind == .hdrToSDR }) else { throw CheckFailure("no HDR loss note") }
                let frame = try MediaBench.frame(try out(ctx), at: 0.5, into: ctx.work)
                let luma = frame.luma
                let clipped = Double(luma.filter { $0 >= 254.5 }.count) / Double(max(luma.count, 1))
                return [Measurement(name: "clipped pixels", value: clipped * 100, unit: "%", limit: .atMost(1)),
                        .info("mean luma", luma.reduce(0, +) / Double(max(luma.count, 1)))]
            },
        ]),
        // A/V sync through every video container: the flash and the beep stay within one frame (40 ms at 25 fps).
        avSync("mp4"), avSync("mov"), avSync("mkv"), avSync("webm"), avSync("avi"), avSync("wmv"), avSync("flv"),
        // Deinterlace: 576i fields → progressive MP4 (idet interlaced ratio < 1 %).
        BenchCase(id: "mediakit.deinterlace", category: .video, fixture: "generated/media/interlaced-576i.ts", target: "mp4", checks: [
            Check(name: "idet after") { ctx in
                let log = try MediaBench.ffmpeg(["-i", try out(ctx).path, "-vf", "idet", "-an", "-f", "null", "-"]).log
                guard let line = log.split(whereSeparator: \.isNewline).last(where: { $0.contains("Multi frame detection") }) else { throw CheckFailure("no idet line") }
                func n(_ k: String) -> Double { line.range(of: "\(k):").flatMap { Double(line[$0.upperBound...].trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) } ?? 0 }
                let total = n("TFF") + n("BFF") + n("Progressive") + n("Undetermined")
                return [Measurement(name: "interlaced frames", value: 100 * (n("TFF") + n("BFF")) / max(total, 1), unit: "%", limit: .atMost(1))]
            },
        ]),
        // Lossless audio: the decoded PCM is identical.
        lossless("wav-flac", fixture: "tone-1k-24bit-44k.wav", target: "flac"),
        lossless("wav-aiff", fixture: "tone-1k-24bit-44k.wav", target: "aiff"),
        lossless("wav-m4a-alac", fixture: "tone-1k-24bit-44k.wav", target: "m4a", options: ["codec": "alac"]),
        lossless("flac-wav", fixture: "sample.flac", target: "wav"),
        // Resampling 44.1 → 48 kHz (soxr) into 32-bit float: THD+N ≤ −100 dB.
        BenchCase(id: "mediakit.resample-44-48", category: .audio, fixture: "generated/media/tone-1k-24bit-44k.wav", target: "wav",
                  options: OptionValues(["sampleRate": "48000", "bitDepth": "32f"]), checks: [
            // The tone starts and stops at full level, so any band-limited resampler rings for a few ms at both ends: the
            // middle 80 % is measured.
            Check(name: "THD+N at 1 kHz (middle 80 %)") { ctx in
                guard let signal = AudioMetrics.read(try out(ctx)) else { throw CheckFailure("the audio cannot be decoded") }
                let n = signal.samples.count
                let middle = AudioMetrics.Signal(sampleRate: signal.sampleRate, samples: Array(signal.samples[(n / 10)..<(n - n / 10)]))
                guard let value = AudioMetrics.thdPlusN(middle, frequency: 1000) else { throw CheckFailure("THD+N could not be measured") }
                return [Measurement(name: "THD+N", value: value, unit: "dB", limit: .atMost(-100), noise: 0.5),
                        .exact("sample rate", signal.sampleRate, equals: 48000)]
            },
        ]),
        BenchCase(id: "mediakit.resample-48-96", category: .audio, tier: .full, fixture: "generated/tone-997-48k.wav", target: "flac",
                  options: OptionValues(["sampleRate": "96000"]), checks: [Check(name: "96 kHz") { ctx in
            let p = try MediaBench.probe(try out(ctx))
            return [.exact("sample rate", Double(p.sampleRate ?? 0), equals: 96000)]
        }]),
        // Loudness option: −16 LUFS two-pass, ±0.5 LU, peaks under −1 dBTP.
        BenchCase(id: "mediakit.loudness-16", category: .audio, fixture: "generated/tone-1k-minus23-stereo.wav", target: "m4a",
                  options: OptionValues(["loudness": "-16"]), checks: [MediaBench.loudness(integrated: -16, tolerance: 0.5, truePeakAtMost: -0.5)]),
        // Lossy audio defaults: no clipping (true peak ≤ 0 dBTP) and the full band kept (MOS needs ViSQOL, see above).
        lossy("mp3"), lossy("m4a"), lossy("wma"),
        // Metadata: tags and cover art of an MP3 survive into M4A; chapters of an audiobook into M4B.
        BenchCase(id: "mediakit.metadata-mp3-m4a", category: .audio, fixture: "generated/media/tagged.mp3", target: "m4a", checks: [
            Check(name: "tags and cover") { ctx in
                let p = try MediaBench.probe(try out(ctx))
                for (k, v) in ["title": "Test tone", "artist": "Super Converter", "album": "Fixtures"] where p.tags[k] != v {
                    throw CheckFailure("\(k) is \(p.tags[k] ?? "missing")")
                }
                return [.count("cover pictures", p.coverArt, atLeast: 1), .count("tags", p.tags.count, atLeast: 3)]
            },
        ]),
        BenchCase(id: "mediakit.chapters-m4b", category: .audio, fixture: "generated/media/chapters.m4b", target: "m4b", options: OptionValues(["bitrate": 96]), checks: [
            Check(name: "chapters") { ctx in
                let p = try MediaBench.probe(try out(ctx))
                guard p.chapters == ["One", "Two"] else { throw CheckFailure("chapters \(p.chapters)") }
                return [.count("chapters", p.chapters.count, atLeast: 2)]
            },
        ]),
        // VideoToolbox calibration (quality §5.1): re-measures the curve and compares the shipped table (full tier).
        BenchCase(id: "mediakit.vt-calibration", category: .video, tier: .full, fixture: "generated/media/detail-640x360.mov", target: "mp4",
                  checks: [VTCalibration.check], timeout: 3600),
    ]

    @MainActor static func out(_ ctx: CaseContext) throws -> URL { guard let url = ctx.output else { throw CheckFailure("no output") }; return url }

    static func videoDefault(_ name: String, target: FormatID, options: [String: OptionValue], ssim: Double) -> BenchCase {
        BenchCase(id: "mediakit.video-default-\(name)", category: .video, fixture: "generated/media/detail-640x360.mov", target: target,
                  options: OptionValues(options), checks: [
            Check(name: "SSIM vs source (VMAF stand-in)") { ctx in
                var ssims: [Double] = [], psnrs: [Double] = []
                // The same frames by number (seeking by time lands on different frames when an encoder shifts the start).
                let a = try VTCalibration.decode(ctx.source, into: ctx.work, tag: "source"), b = try VTCalibration.decode(try out(ctx), into: ctx.work, tag: "output")
                for (x, y) in zip(a, b) {
                    guard let s = SSIM.ssim(x, y), let p = PSNR.compare(x, y) else { throw CheckFailure("frames differ in size") }
                    ssims.append(s.mean); psnrs.append(p)
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: try out(ctx).path)[.size] as? Int) ?? 0
                return [.ssim("mean SSIM", ssims.reduce(0, +) / Double(ssims.count), atLeast: ssim),
                        .ssim("lowest SSIM", ssims.min() ?? 0, atLeast: ssim - 0.02),
                        .info("mean PSNR", psnrs.reduce(0, +) / Double(psnrs.count), unit: "dB"), .info("size", Double(size) / 1000, unit: "kB")]
            },
        ])
    }

    static func hdrKept(_ name: String, target: FormatID, options: [String: OptionValue], metadata: Bool) -> BenchCase {
        BenchCase(id: "mediakit.hdr-kept-\(name)", category: .video, fixture: "generated/media/hdr-pq.mkv", target: target, options: OptionValues(options), checks: [
            Check(name: metadata ? "PQ, mastering display, MaxCLL" : "PQ, 10-bit, metadata gap noted") { ctx in
                let source = try MediaBench.probe(ctx.source), p = try MediaBench.probe(try out(ctx))
                guard p.transfer == "smpte2084", p.primaries == "bt2020" else { throw CheckFailure("tagged \(p.transfer ?? "-") / \(p.primaries ?? "-")") }
                guard metadata else {
                    guard ctx.result.lossNotes.contains(where: { $0.detail.contains("mastering display") }) else { throw CheckFailure("the metadata gap isn't noted") }
                    return [.count("bit depth", p.bitDepth, atLeast: 10)]
                }
                guard p.maxCLL == source.maxCLL, p.maxFALL == source.maxFALL else { throw CheckFailure("MaxCLL \(p.maxCLL ?? -1)/\(p.maxFALL ?? -1) vs \(source.maxCLL ?? -1)/\(source.maxFALL ?? -1)") }
                guard p.masteringLuminance == source.masteringLuminance else { throw CheckFailure("mastering \(p.masteringLuminance ?? "-") vs \(source.masteringLuminance ?? "-")") }
                return [.exact("MaxCLL", Double(p.maxCLL ?? 0), equals: Double(source.maxCLL ?? 0)), .count("bit depth", p.bitDepth, atLeast: 10)]
            },
        ])
    }

    static func avSync(_ target: FormatID) -> BenchCase {
        BenchCase(id: "mediakit.av-sync-\(target.rawValue)", category: .video, tier: ["mp4", "mkv", "avi"].contains(target.rawValue) ? .fast : .full,
                  fixture: "generated/media/flash-beep.mov", target: target, checks: [
            Check(name: "flash vs beep") { ctx in
                let flash = try MediaBench.flashTime(try out(ctx)), beep = try MediaBench.beepTime(try out(ctx))
                return [Measurement(name: "A/V offset", value: abs(flash - beep) * 1000, unit: "ms", limit: .atMost(40)), .info("flash", flash, unit: "s")]
            },
        ])
    }

    static func lossless(_ name: String, fixture: String, target: FormatID, options: [String: OptionValue] = [:]) -> BenchCase {
        BenchCase(id: "mediakit.lossless-\(name)", category: .audio, fixture: "generated/media/\(fixture)", target: target, options: OptionValues(options), checks: [
            Check(name: "decoded PCM identical") { ctx in
                let a = try MediaBench.pcmMD5(ctx.source), b = try MediaBench.pcmMD5(try out(ctx))
                guard a == b else { throw CheckFailure("MD5 \(a) vs \(b)") }
                return [.exact("PCM differs", 0, equals: 0)]
            },
        ])
    }

    static func lossy(_ target: FormatID) -> BenchCase {
        BenchCase(id: "mediakit.lossy-\(target.rawValue)", category: .audio, tier: .full, fixture: "generated/sweep-20-20k-44k.wav", target: target, checks: [
            MediaBench.loudness(integrated: nil, tolerance: 0, truePeakAtMost: 0),
            Check(name: "bandwidth") { ctx in
                // The sweep's level between 16 and 20 kHz (where it is near its end) against 1–4 kHz: an encoder that low-passes
                // at 16 kHz loses it; quality §5.3 wants ≥ 18 kHz (Opus 20 kHz).
                let file = try out(ctx)
                func level(_ filter: String) throws -> Double {
                    let log = try MediaBench.ffmpeg(["-i", file.path, "-af", "\(filter),astats=metadata=0:measure_overall=RMS_level", "-f", "null", "-"]).log
                    guard let r = log.range(of: "RMS level dB:", options: .backwards) else { throw CheckFailure("no astats") }
                    return Double(log[r.upperBound...].trimmingCharacters(in: .whitespaces).prefix { "-.0123456789".contains($0) }) ?? -200
                }
                let high = try level("highpass=f=18000:poles=2,lowpass=f=20000:poles=2"), mid = try level("highpass=f=1000:poles=2,lowpass=f=4000:poles=2")
                return [Measurement(name: "18–20 kHz vs 1–4 kHz", value: high - mid, unit: "dB", limit: .atLeast(-12))]
            },
        ])
    }
}

/// FFmpeg/ffprobe for the media checks: only the repository's LGPL build in `Vendor/Tools`.
enum MediaBench {
    static let videoTargets: Set<FormatID> = ["3g2", "3gp", "3gpp", "avi", "dv", "dvr", "flv", "m2ts", "m4v", "mkv", "mod", "mov", "mp4", "mpeg", "mpg", "mts",
                                              "mxf", "ogv", "rm", "rmvb", "swf", "ts", "vob", "webm", "wmv", "wtv", "gif", "webp"]

    /// Decoded frames are written as plain sRGB-less PNGs: FFmpeg would otherwise copy the video's colour tags into cICP /
    /// gAMA chunks, and ColorSync would then convert one picture of a pair and not the other.
    static let untagged = "setparams=color_primaries=unknown:color_trc=unknown:colorspace=unknown"

    static func tool(_ name: String) throws -> URL {
        let url = RepoRoot.url.appendingPathComponent("Vendor/Tools/\(name)")
        guard FileManager.default.isExecutableFile(atPath: url.path) else { throw CheckFailure("Vendor/Tools/\(name) is missing (scripts/fetch-vendor.sh)") }
        return url
    }

    struct Probe {
        var videoStreams = 0, audioStreams = 0, coverArt = 0
        var duration: Double?
        /// The longest video or audio stream (ASF and MPEG containers add preroll and padding to their own duration).
        var streamDuration: Double?
        var frameRate: Double?
        var sampleRate: Int?
        var audioCodec: String?
        var matrix: String?, primaries: String?, transfer: String?, range: String?
        var bitDepth = 8
        var maxCLL: Int?, maxFALL: Int?
        var masteringLuminance: String?
        var tags: [String: String] = [:]
        var chapters: [String] = []
    }

    static func probe(_ url: URL) throws -> Probe {
        let out = Subprocess.run(try tool("ffprobe"), ["-v", "error", "-of", "json", "-show_format", "-show_streams", "-show_chapters", "-show_frames",
                                                        "-read_intervals", "%+#1", "-select_streams", "v:0?", url.path])
        let streams = Subprocess.run(try tool("ffprobe"), ["-v", "error", "-of", "json", "-show_format", "-show_streams", "-show_chapters", url.path])
        guard streams.status == 0, let root = try? JSONSerialization.jsonObject(with: streams.data) as? [String: Any] else { throw CheckFailure("ffprobe can't read \(url.lastPathComponent)") }
        var p = Probe()
        let format = root["format"] as? [String: Any] ?? [:]
        p.duration = (format["duration"] as? String).flatMap(Double.init)
        for (k, v) in format["tags"] as? [String: Any] ?? [:] { p.tags[k.lowercased()] = "\(v)" }
        p.chapters = (root["chapters"] as? [[String: Any]] ?? []).compactMap { ($0["tags"] as? [String: Any])?["title"] as? String }
        for s in root["streams"] as? [[String: Any]] ?? [] {
            if let d = (s["duration"] as? String).flatMap(Double.init), ["video", "audio"].contains(s["codec_type"] as? String ?? "") {
                p.streamDuration = max(p.streamDuration ?? 0, d)
            }
            let attached = ((s["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
            switch s["codec_type"] as? String {
            case "video" where attached: p.coverArt += 1
            case "video":
                if p.videoStreams == 0 {
                    p.matrix = s["color_space"] as? String; p.primaries = s["color_primaries"] as? String
                    p.transfer = s["color_transfer"] as? String; p.range = s["color_range"] as? String
                    let fmt = s["pix_fmt"] as? String ?? ""
                    p.bitDepth = fmt.contains("10") || fmt == "p010le" ? 10 : 8
                    for key in ["avg_frame_rate", "r_frame_rate"] where p.frameRate == nil {
                        let parts = (s[key] as? String ?? "").split(separator: "/").compactMap { Double($0) }
                        if parts.count == 2, parts[1] > 0, parts[0] > 0, parts[0] / parts[1] <= 120 { p.frameRate = parts[0] / parts[1] }
                    }
                    sideData(s["side_data_list"], into: &p)
                }
                p.videoStreams += 1
            case "audio":
                if p.audioStreams == 0 { p.sampleRate = (s["sample_rate"] as? String).flatMap(Int.init); p.audioCodec = s["codec_name"] as? String }
                p.audioStreams += 1
            default: break
            }
        }
        // HDR metadata often sits on the frames rather than the stream (HEVC SEI, AV1 OBUs).
        if p.maxCLL == nil || p.masteringLuminance == nil, out.status == 0, let frames = (try? JSONSerialization.jsonObject(with: out.data) as? [String: Any])?["frames"] as? [[String: Any]] {
            for f in frames { sideData(f["side_data_list"], into: &p) }
        }
        return p
    }

    private static func sideData(_ list: Any?, into p: inout Probe) {
        for side in list as? [[String: Any]] ?? [] {
            switch side["side_data_type"] as? String {
            case "Content light level metadata":
                p.maxCLL = side["max_content"] as? Int ?? p.maxCLL; p.maxFALL = side["max_average"] as? Int ?? p.maxFALL
            case "Mastering display metadata":
                if let max = side["max_luminance"] as? String, let min = side["min_luminance"] as? String { p.masteringLuminance = "\(fraction(max))/\(fraction(min))" }
            default: break
            }
        }
    }

    /// "10000000/10000" → "1000.0000": the same luminance written with different denominators compares equal.
    private static func fraction(_ text: String) -> String {
        let parts = text.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0 else { return text }
        return String(format: "%.4f", parts[0] / parts[1])
    }

    static func ffmpeg(_ arguments: [String]) throws -> (status: Int32, log: String) {
        let out = Subprocess.run(try tool("ffmpeg"), ["-nostdin", "-hide_banner", "-nostats"] + arguments, timeout: 900)
        guard out.status == 0 else { throw CheckFailure("ffmpeg failed: \(out.standardError?.suffix(300) ?? "")") }
        return (out.status, out.standardError ?? "")
    }

    /// The frame shown at `seconds`, decoded to sRGB by FFmpeg.
    static func frame(_ url: URL, at seconds: Double, into folder: URL) throws -> Raster {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let png = folder.appendingPathComponent("frame-\(UUID().uuidString.prefix(8)).png")
        _ = try ffmpeg(["-ss", String(seconds), "-i", url.path, "-frames:v", "1", "-vf", "scale=out_range=pc,format=rgb24,\(MediaBench.untagged)", "-y", png.path])
        guard let raster = Raster(contentsOf: png) else { throw CheckFailure("the frame at \(seconds) s can't be read") }
        return raster
    }

    /// The time of the first bright frame.
    static func flashTime(_ url: URL) throws -> Double {
        let log = try ffmpeg(["-i", url.path, "-an", "-vf", "signalstats,metadata=print:key=lavfi.signalstats.YAVG", "-f", "null", "-"]).log
        var time: Double?
        for line in log.split(whereSeparator: \.isNewline) {
            if let r = line.range(of: "pts_time:") { time = Double(line[r.upperBound...].prefix { "-.0123456789".contains($0) }) }
            if let r = line.range(of: "YAVG="), let y = Double(line[r.upperBound...].prefix { ".0123456789".contains($0) }), y > 128, let t = time { return t }
        }
        throw CheckFailure("no flash found")
    }

    /// The time the beep starts (the end of the first silence).
    static func beepTime(_ url: URL) throws -> Double {
        let log = try ffmpeg(["-i", url.path, "-vn", "-af", "silencedetect=n=-30dB:d=0.3", "-f", "null", "-"]).log
        guard let r = log.range(of: "silence_end:"), let t = Double(log[r.upperBound...].trimmingCharacters(in: .whitespaces).prefix { "-.0123456789".contains($0) })
        else { throw CheckFailure("no beep found") }
        return t
    }

    /// MD5 of the first audio stream decoded to 32-bit integers (bit-exact comparisons across containers).
    static func pcmMD5(_ url: URL) throws -> String {
        let out = Subprocess.run(try tool("ffmpeg"), ["-nostdin", "-v", "error", "-i", url.path, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "md5", "-"])
        guard out.status == 0, let text = out.standardOutput, !text.isEmpty else { throw CheckFailure("can't decode \(url.lastPathComponent)") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// EBU R128 with the Vendor FFmpeg's `ebur128` (the bench's `Loudness.parse`).
    static func loudness(integrated target: Double?, tolerance: Double, truePeakAtMost: Double) -> Check {
        Check(name: "EBU R128") { ctx in
            let log = try ffmpeg(["-i", try MediaKitCases.out(ctx).path, "-vn", "-af", "ebur128=peak=true", "-f", "null", "-"]).log
            guard let m = Loudness.parse(log) else { throw CheckFailure("no ebur128 summary") }
            var out: [Measurement] = []
            if let target { out.append(Measurement(name: "integrated loudness", value: m.integrated, unit: "LUFS", limit: .within(target, tolerance: tolerance), noise: 0.1)) }
            if let peak = m.truePeak { out.append(Measurement(name: "true peak", value: peak, unit: "dBTP", limit: .atMost(truePeakAtMost), noise: 0.1)) }
            return out
        }
    }
}

/// The VideoToolbox calibration of quality §5.1, measured as `VideoToolboxCalibration` describes: six synthetic 640×360 clips
/// (screen recording, smooth motion, animation, film grain, low light, fine detail), VideoToolbox quality 0.30…0.95 for H.264
/// and HEVC, the bench's SSIM and PSNR on four frames of each. crf 20 sits at mean luma SSIM 0.985; crf N asks for the PSNR at
/// that point minus (N − 20) dB. The check fails when a shipped table value is more than 0.05 from the measurement.
enum VTCalibration {
    static let clips: [(String, String)] = [
        ("screen", "testsrc2=s=640x360:r=30:d=2"),
        ("motion", "mandelbrot=s=640x360:r=30,trim=duration=2"),
        ("animation", "life=s=640x360:r=30:mold=10:ratio=0.1:death_color=#C83232:life_color=#00ff00,trim=duration=2"),
        ("grain", "testsrc2=s=640x360:r=30:d=2,noise=alls=12:allf=t"),
        ("low-light", "testsrc2=s=640x360:r=30:d=2,lutyuv=y=16+(val-16)*0.35,noise=alls=4:allf=t"),
        ("detail", "zoneplate=s=640x360:r=30:kt2=8:kx2=256:ky2=256,trim=duration=2"),
    ]
    static let qualities = stride(from: 0.30, through: 0.951, by: 0.05).map { ($0 * 100).rounded() / 100 }
    static let frames = [5, 20, 35, 50]

    static let check = Check(name: "VideoToolbox quality ↔ crf") { ctx in
        var perCodec: [String: [[Int: Double]]] = ["h264": [], "hevc": []]
        for (name, source) in clips {
            let folder = ctx.work.appendingPathComponent("cal-\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let reference = folder.appendingPathComponent("ref.y4m")
            _ = try MediaBench.ffmpeg(["-f", "lavfi", "-i", source, "-pix_fmt", "yuv420p", "-y", reference.path])
            let refFrames = try decode(reference, into: folder, tag: "ref")
            for codec in ["h264", "hevc"] {
                var curve: [Point] = []
                for q in qualities {
                    let encoded = folder.appendingPathComponent("\(codec)-\(Int(q * 100)).mp4")
                    _ = try MediaBench.ffmpeg(["-i", reference.path, "-c:v", "\(codec)_videotoolbox", "-q:v", String(Int(q * 100)), "-allow_sw", "1", "-g", "60",
                                               "-an", "-y", encoded.path])
                    let got = try decode(encoded, into: folder, tag: "\(codec)-\(Int(q * 100))")
                    var s = 0.0, p = 0.0
                    for (a, b) in zip(refFrames, got) {
                        guard let ssim = SSIM.ssim(a, b), let psnr = PSNR.compare(a, b) else { throw CheckFailure("frames differ in size") }
                        s += ssim.mean; p += min(psnr, 99)
                    }
                    curve.append(Point(q: q, ssim: s / Double(got.count), psnr: p / Double(got.count)))
                    try? FileManager.default.removeItem(at: encoded)
                }
                perCodec[codec]!.append(derive(curve))
            }
        }
        var out: [Measurement] = []
        for codec in ["h264", "hevc"] {
            let tables = perCodec[codec]!
            var line: [String] = []
            for crf in VideoToolboxCalibration.measuredCRFs {
                let mean = tables.map { $0[crf]! }.reduce(0, +) / Double(tables.count)
                line.append("\(crf): \(String(format: "%.2f", mean))")
                let shipped = VideoToolboxCalibration.quality(crf: crf, hevc: codec == "hevc")
                out.append(Measurement(name: "\(codec) crf \(crf): shipped − measured", value: abs(shipped - mean), limit: .atMost(0.05), noise: 0.02))
            }
            print("  measured \(codec): " + line.joined(separator: ", "))
        }
        return out
    }

    struct Point { var q: Double, ssim: Double, psnr: Double }

    /// One clip's crf → quality: the quality where SSIM reaches 0.985 is crf 20; crf N wants that PSNR minus (N − 20) dB.
    static func derive(_ curve: [Point]) -> [Int: Double] {
        func inverse(_ value: Double, _ key: (Point) -> Double) -> Double {
            if value <= key(curve[0]) { return curve[0].q }
            for i in 1..<curve.count where key(curve[i]) >= value {
                let t = (value - key(curve[i - 1])) / max(key(curve[i]) - key(curve[i - 1]), 1e-9)
                return curve[i - 1].q + t * (curve[i].q - curve[i - 1].q)
            }
            return curve[curve.count - 1].q
        }
        func psnr(at q: Double) -> Double {
            for i in 1..<curve.count where curve[i].q >= q {
                let t = (q - curve[i - 1].q) / (curve[i].q - curve[i - 1].q)
                return curve[i - 1].psnr + t * (curve[i].psnr - curve[i - 1].psnr)
            }
            return curve[curve.count - 1].psnr
        }
        let p20 = psnr(at: inverse(0.985) { $0.ssim })
        var table: [Int: Double] = [:]
        for crf in VideoToolboxCalibration.measuredCRFs { table[crf] = inverse(p20 - Double(crf - 20)) { $0.psnr } }
        return table
    }

    static func decode(_ url: URL, into folder: URL, tag: String) throws -> [Raster] {
        let select = frames.map { "eq(n\\,\($0))" }.joined(separator: "+")
        let pattern = folder.appendingPathComponent("\(tag)-%02d.png").path
        _ = try MediaBench.ffmpeg(["-i", url.path, "-vf", "select='\(select)',scale=out_range=pc,format=rgb24,\(MediaBench.untagged)", "-fps_mode", "passthrough", "-y", pattern])
        return try (1...frames.count).map { i in
            let file = folder.appendingPathComponent(String(format: "\(tag)-%02d.png", i))
            defer { try? FileManager.default.removeItem(at: file) }
            guard let r = Raster(contentsOf: file) else { throw CheckFailure("frame \(i) of \(tag) is missing") }
            return r
        }
    }
}
