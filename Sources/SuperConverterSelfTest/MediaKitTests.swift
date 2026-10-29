import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore
import HelperKit
@testable import MediaKit

// MediaKit's checks (WP-M). Inputs are the clips `scripts/make-fixtures.swift` makes with the bundled LGPL FFmpeg
// (Tests/Corpus/generated/media); every process runs through HelperKit's `BundledTools`, the runner the app uses — never a
// system FFmpeg. Without Vendor/Tools the FFmpeg cases say so and stop (the converter then reports itself unavailable).

private let media = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Tests/Corpus/generated/media", isDirectory: true)
private let runner = BundledTools()
private let tools = MediaTools(runner: runner)
private let mediaEngines: Set<EngineID> = [.avFoundation, .ffmpeg, .soundFontReader]

private func work(_ name: String) -> URL {
    let url = scratch.appendingPathComponent("mediakit-\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func context(_ folder: URL, source: URL, from: FormatID, to: FormatID, options: OptionValues = OptionValues(),
                     report: @escaping @Sendable (StepProgress) -> Void = { _ in },
                     cancelled: @escaping @Sendable () -> Bool = { false }) -> StepContext {
    StepContext(workFolder: folder, source: source, sourceFormat: from, targetFormat: to, options: options, isFinalStep: true,
                report: report, isCancelled: cancelled)
}

private func converter(_ id: EngineID) -> any Converter {
    MediaKitModule.converters(tools: runner).first { $0.id == id }!
}

/// Runs one step on a fixture and returns its output (or the error).
@MainActor private func convert(_ step: Step, _ source: URL, options: OptionValues = OptionValues(), folder: URL? = nil,
                                input: StepValue? = nil) -> Result<StepOutput, Error> {
    let to: FormatID = if case .format(let t) = step.to { t } else { "zip" }
    let from: FormatID = if case .format(let f) = step.from { f } else { "gif" }
    let ctx = context(folder ?? work(from.rawValue), source: source, from: from, to: to, options: options)
    let result = complete(300) { try await converter(step.engine).run(step, input: input ?? .file(source), context: ctx) }
        ?? .failure(ConversionError.failed("timed out"))
    if case .failure(let error) = result { print("  ↳ \(step): \(error)") }
    return result
}

@MainActor private func probe(_ url: URL) -> MediaProbe? {
    try? complete(60) { try await tools.probe(url, workFolder: work("probe")) }?.get()
}

private func outputFile(_ output: StepOutput) -> URL? { if case .file(let url) = output.value { url } else { nil } }

/// A synthetic animation: `count` frames of a moving square with the given delays.
private func animation(_ delays: [Double], size: Int = 64, alpha: Bool = false) -> ImageAsset {
    let frames = delays.enumerated().map { index, delay -> ImageFrame in
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let inside = abs(x - (index * 7) % size) < 8 && abs(y - size / 2) < 8
                let i = (y * size + x) * 4
                pixels[i] = inside ? 255 : 20; pixels[i + 1] = inside ? 40 : 120; pixels[i + 2] = 60
                pixels[i + 3] = alpha && !inside ? 0 : 255
            }
        }
        return ImageFrame(width: size, height: size, pixels: .rgba8(Data(pixels), bytesPerRow: size * 4), hasAlpha: alpha, delay: delay)
    }
    return ImageAsset(frames: frames, loopCount: 0)
}

func registerMediaKitTests() {
    SelfTest.cases.append(("MediaKit.installs", {
        let before = Services.converters
        Services.converters = ConverterList()
        defer { Services.converters = before }
        MediaKitModule.install()
        let registered = Set(Services.converters.converters.map(\.id))
        let expected = Set(EngineID.allCases.filter { $0.info.module == .mediaKit })
        check(registered == expected, "a converter for every engine MediaKit owns (\(registered.symmetricDifference(expected).map(\.rawValue)))")
        var steps = Set<Step>()
        for route in FormatMatrix.offered {
            for chain in [route.builtin, route.helper].compactMap({ $0 }) + route.alternates.map(\.steps) { steps.formUnion(chain) }
        }
        let mine = steps.filter { mediaEngines.contains($0.engine) }
        check(mine.count > 500, "the matrix has MediaKit's ~600 steps (\(mine.count))")
        for step in mine { check(Services.converters.converter(for: step.engine)?.handles(step) == true, "\(step) is handled") }
        check(tools.availability == .available, "the bundled ffmpeg and ffprobe are found in Vendor/Tools (scripts/fetch-vendor.sh)")
        check(MediaTools(runner: nil).availability != .available, "without the runner FFmpeg is unavailable, with a reason")
    }))

    SelfTest.cases.append(("MediaKit.units", {
        // Progress (`-progress` blocks), times, idet.
        let log = "frame=10\nout_time_us=1500000\nspeed=2.0x\nprogress=continue\nframe=20\nout_time_us=3000000\nprogress=end\n"
        check(FFmpegProgress.last(log) == FFmpegProgress.Block(outTime: 3, frame: 20, speed: nil, finished: true), "the last progress block is read")
        let p = FFmpegProgress.stepProgress(FFmpegProgress.Block(outTime: 30, frame: nil, speed: nil, finished: false), duration: 120)
        check(p.fraction == 0.25 && p.unit == "0:30 of 2:00", "progress is a fraction with a clock (\(p))")
        check(MediaTime.seconds("01:02:03.5") == 3723.5 && MediaTime.seconds("93.25") == 93.25 && MediaTime.seconds("x") == nil, "trim times parse")
        let idet = "[Parsed_idet_0] Multi frame detection: TFF:   120 BFF:     0 Progressive:    10 Undetermined:     2"
        check(MediaTools.idetCounts(idet)! == (120, 0, 10), "idet's multi-frame counts are read")
        // Geometry.
        check(Geometry.fit(source: (1920, 1080), box: (nil, 720), fit: .max) == Geometry.Result(scaleW: 1280, scaleH: 720), "fit inside keeps the aspect")
        check(Geometry.fit(source: (640, 360), box: (1280, 720), fit: .max).scaleW == 640, "fit inside never enlarges")
        let crop = Geometry.fit(source: (1920, 1080), box: (1000, 1000), fit: .crop)
        check(crop.finalW == 1000 && crop.finalH == 1000 && crop.scaleH == 1000, "crop fills the box")
        let pad = Geometry.fit(source: (1920, 1080), box: (1000, 1000), fit: .pad)
        check(pad.scaleW == 1000 && pad.padH == 1000, "pad fits and adds bars")
        // Calibration (quality §5.1).
        for table in [VideoToolboxCalibration.h264, VideoToolboxCalibration.hevc] {
            check(table.count == 52 && zip(table, table.dropFirst()).allSatisfy { $0 >= $1 }, "the calibration covers crf 0–51 and falls monotonically")
        }
        // Options.
        let s = MediaSettings(OptionValues())
        check(s.crf == 20 && !s.crfSet && s.fit == .max && s.deinterlace && s.webReady && s.audioBitrate == nil, "O-VIDEO defaults")
        let anim = MediaSettings(OptionValues(), animation: true)
        check(anim.width == 800 && anim.fps == 15, "O-ANIM keeps animations to 800 px and 15 fps")
        let set = MediaSettings(OptionValues(["quality": 18, "size": "720", "trimStart": "00:00:01.5", "audioCodec": "copy", "loudness": "-16"]))
        check(set.crfSet && set.height == 720 && set.width == 1280 && set.trimStart == 1.5 && set.loudness == -16, "options are read (\(set))")
        // Every container the matrix writes is in the table, and each lists a default.
        for route in FormatMatrix.offered {
            for step in route.builtin ?? [] where step.engine == .ffmpeg || step.engine == .avFoundation {
                guard case .format(let to) = step.to, !MediaRoutes.animationTargets.contains(to) else { continue }
                check(MediaContainer.of(to).map { $0.isVideo ? $0.defaultVideo != nil : $0.defaultAudio != nil } == true, "\(to.pill) has a container entry")
            }
        }
        // Analysis logs.
        let loud = MediaRun.loudnorm("[Parsed_loudnorm_0]\n{\n\t\"input_i\" : \"-27.61\",\n\t\"input_tp\" : \"-4.47\",\n\t\"input_lra\" : \"18.06\",\n\t\"input_thresh\" : \"-39.20\",\n\t\"target_offset\" : \"0.58\"\n}\n")
        check(loud == LoudnormMeasurement(integrated: -27.61, truePeak: -4.47, range: 18.06, threshold: -39.2, offset: 0.58), "loudnorm's first pass is read")
        check(MediaRun.truePeak("  True peak:\n    Peak:       -0.4 dBFS\n") == -0.4, "the true peak is read")
        check(FilterText.escape("/a b/it's:x.srt") == "'/a b/it\\'\\''s\\:x.srt'" || FilterText.escape("/a:b").contains("\\:"), "filter paths are quoted")
    }))

    SelfTest.cases.append(("MediaKit.probe", {
        guard let mkv = probe(media.appendingPathComponent("hdr-pq.mkv")), let v = mkv.mainVideo else { check(false, "the HDR clip probes"); return }
        check(v.colour.isHDR && v.colour.transfer == "smpte2084" && v.colour.primaries == "bt2020", "PQ tags are read (\(v.colour))")
        check(v.bitDepth == 10, "10-bit is seen")
        guard let ts = probe(media.appendingPathComponent("interlaced-576i.ts")) else { check(false, "the interlaced clip probes"); return }
        let interlaced = try? complete(120) { try await tools.isInterlaced(media.appendingPathComponent("interlaced-576i.ts"), probe: ts, sourceFormat: "ts", workFolder: work("idet")) }?.get()
        check(interlaced == true, "idet finds the interlaced fields")
        let progressive = probe(media.appendingPathComponent("sample.mp4"))!
        let flat = try? complete(120) { try await tools.isInterlaced(media.appendingPathComponent("sample.mp4"), probe: progressive, sourceFormat: "mp4", workFolder: work("idet")) }?.get()
        check(flat == false, "a progressive MP4 is not deinterlaced")
    }))

    // Every MediaKit step of the matrix, once, on its fixture: the output must be the target container with the planned streams.
    SelfTest.cases.append(("MediaKit.everyStep", {
        guard tools.availability == .available else { check(false, "Vendor/Tools is missing: run scripts/fetch-vendor.sh"); return }
        var steps = Set<Step>()
        for route in FormatMatrix.offered {
            for chain in [route.builtin, route.helper].compactMap({ $0 }) { steps.formUnion(chain.filter { mediaEngines.contains($0.engine) }) }
        }
        let ordered = steps.sorted { $0.description < $1.description }
        let results = complete(3000) { () async -> [(Step, String?)] in
            await withTaskGroup(of: (Step, String?).self) { group in
                var out: [(Step, String?)] = []
                var iterator = ordered.makeIterator()
                func add(_ step: Step) {
                    group.addTask { (step, await everyStep(step)) }
                }
                for _ in 0..<6 { if let s = iterator.next() { add(s) } }
                while let next = await group.next() {
                    out.append(next)
                    if let s = iterator.next() { add(s) }
                }
                return out
            }
        }
        guard case .success(let all)? = results else { check(false, "the sweep finished"); return }
        var skipped: [String] = []
        for (step, problem) in all {
            if let problem, problem.hasPrefix("skip:") { skipped.append("\(step.from)→\(step.to)"); continue }
            check(problem == nil, "\(step): \(problem ?? "")")
        }
        print("  MediaKit: \(all.count) steps run, \(skipped.count) without a fixture (\(skipped.joined(separator: ", ")))")
    }))

    SelfTest.cases.append(("MediaKit.avFoundation", {
        // MP4 → MOV re-wraps (copy first): no re-encoding, the same codecs.
        let mp4 = media.appendingPathComponent("sample.mp4")
        guard case .success(let rewrap)? = Optional(convert(Step(.avFoundation, "mp4", "mov"), mp4)), let mov = outputFile(rewrap) else {
            check(false, "MP4 → MOV converts"); return
        }
        check(rewrap.warnings.contains(MediaRun.reWrapped), "MP4 → MOV is a re-wrap (\(rewrap.warnings))")
        check(probe(mov)?.mainVideo?.codec == "mpeg4", "the stream is copied")
        // A quality change encodes with VideoToolbox through AVFoundation, colour tags written.
        if case .success(let encoded) = convert(Step(.avFoundation, "mov", "mp4"), mov, options: OptionValues(["quality": 23])), let out = outputFile(encoded),
           let v = probe(out)?.mainVideo {
            check(v.codec == "h264" && v.colour.matrix != nil && v.colour.primaries != nil, "a quality change encodes H.264 with colour tags (\(v.codec), \(v.colour))")
        } else { check(false, "MOV → MP4 at quality 23 converts") }
        // Lossless chains are bit-exact (quality §5.2): WAV → AIFF → WAV.
        let wav = media.appendingPathComponent("sample.wav")
        if case .success(let a) = convert(Step(.avFoundation, "wav", "aiff"), wav), let aiff = outputFile(a),
           case .success(let b) = convert(Step(.avFoundation, "aiff", "wav"), aiff), let back = outputFile(b) {
            check(pcmMD5(wav) == pcmMD5(back) && pcmMD5(wav) != nil, "WAV → AIFF → WAV is bit-exact")
            check(probe(aiff)?.audio.first?.codec == "pcm_s16be", "AIFF holds big-endian 16-bit PCM")
        } else { check(false, "WAV ↔ AIFF converts") }
        // A 24-bit tone to 16-bit is dithered by AVFoundation's route, ADTS AAC written by AudioToolbox.
        let tone = media.appendingPathComponent("tone-1k-24bit-44k.wav")
        if case .success(let o) = convert(Step(.avFoundation, "wav", "aac"), tone), let aac = outputFile(o) {
            check(probe(aac)?.formatName == "aac" && probe(aac)?.audio.first?.codec == "aac", "WAV → AAC writes ADTS")
        } else { check(false, "WAV → AAC converts") }
        // FFmpeg takes what AVFoundation cannot read (Vorbis in MKV) even on an AVFoundation step.
        if case .success(let o) = convert(Step(.avFoundation, "m4a", "wav"), media.appendingPathComponent("sample.m4a"), options: OptionValues(["volume": 2.0])),
           let out = outputFile(o) {
            check(probe(out)?.audio.first?.codec == "pcm_s16le", "a gain change falls back to FFmpeg and still writes WAV")
        } else { check(false, "M4A → WAV with volume converts") }
    }))

    SelfTest.cases.append(("MediaKit.video", {
        // HDR kept on HEVC Main10 in MOV with its metadata (quality §5.1).
        let hdr = media.appendingPathComponent("hdr-pq.mkv")
        if case .success(let o) = convert(Step(.ffmpeg, "mkv", "mov"), hdr, options: OptionValues(["videoCodec": "hevc"])), let out = outputFile(o),
           let v = probe(out)?.mainVideo {
            check(v.codec == "hevc" && v.colour.transfer == "smpte2084" && v.bitDepth == 10, "PQ stays PQ on HEVC Main10 (\(v.codec) \(v.colour) \(v.bitDepth))")
            check(o.lossNotes.allSatisfy { $0.kind != .hdrToSDR }, "no HDR note when HDR is kept")
        } else { check(false, "HDR MKV → MOV HEVC converts") }
        // … and tone-mapped to BT.709 on H.264, with the loss note.
        if case .success(let o) = convert(Step(.ffmpeg, "mkv", "mp4"), hdr), let out = outputFile(o), let v = probe(out)?.mainVideo {
            check(v.codec == "h264" && v.colour.transfer == "bt709" && v.colour.primaries == "bt709", "PQ → H.264 is tone-mapped to BT.709 (\(v.colour))")
            check(o.lossNotes.contains { $0.kind == .hdrToSDR }, "the tone map is a loss note")
        } else { check(false, "HDR MKV → MP4 converts") }
        // Deinterlaced with bwdif when idet finds fields.
        let interlaced = media.appendingPathComponent("interlaced-576i.ts")
        if case .success(let o) = convert(Step(.ffmpeg, "ts", "mp4"), interlaced), let out = outputFile(o), let p = probe(out) {
            let after = try? complete(120) { try await tools.isInterlaced(out, probe: p, sourceFormat: "ts", workFolder: work("idet")) }?.get()
            check(after == false, "the MP4 is progressive after deinterlacing")
            check(p.mainVideo?.colour.matrix == "bt470bg" || p.mainVideo?.colour.matrix == "smpte170m", "576i is tagged BT.601 (\(String(describing: p.mainVideo?.colour)))")
        } else { check(false, "interlaced TS → MP4 converts") }
        // SD → HD changes the matrix to BT.709.
        let bars = media.appendingPathComponent("bars-601.mov")
        if case .success(let o) = convert(Step(.ffmpeg, "mov", "mkv"), bars, options: OptionValues(["size": "720", "fit": "scale"])), let out = outputFile(o),
           let v = probe(out)?.mainVideo {
            check(v.height == 720 && v.colour.matrix == "bt709", "scaling SD → HD converts to BT.709 (\(v.height ?? 0), \(v.colour))")
        } else { check(false, "bars → 720p converts") }
        // Watermark, trim and a codec choice in one run.
        let mark = scratch.appendingPathComponent("mark.png")
        try? MediaKitFixtures.png(width: 40, height: 20).write(to: mark)
        if case .success(let o) = convert(Step(.ffmpeg, "mp4", "webm"), media.appendingPathComponent("sample.mp4"),
                                          options: OptionValues(["watermarkImage": .string(mark.path), "trimStart": "0.2", "trimEnd": "0.8"])),
           let out = outputFile(o), let p = probe(out) {
            check(p.mainVideo?.codec == "vp9" && p.audio.first?.codec == "opus", "WebM defaults to VP9 + Opus")
            check(abs((p.duration ?? 0) - 0.6) < 0.1, "trim keeps 0.6 s (\(p.duration ?? 0))")
        } else { check(false, "MP4 → WebM with a watermark converts") }
    }))

    SelfTest.cases.append(("MediaKit.subtitles", {
        let folder = work("subs")
        let srt = folder.appendingPathComponent("subs.srt")
        try? "1\n00:00:00,000 --> 00:00:00,900\nHello\n".write(to: srt, atomically: true, encoding: .utf8)
        let mkv = folder.appendingPathComponent("with-subs.mkv")
        let made: Void? = try? complete(60) {
            try await tools.run(["-i", media.appendingPathComponent("sample.mkv").path, "-i", srt.path, "-map", "0", "-map", "1", "-c", "copy",
                                 "-c:s", "srt", "-f", "matroska", "-y", mkv.path], workFolder: folder)
        }?.get()
        guard made != nil else { check(false, "the subtitled MKV is made"); return }
        if case .success(let o) = convert(Step(.ffmpeg, "mkv", "mp4"), mkv), let out = outputFile(o) {
            check(probe(out)?.subtitles.first?.codec == "mov_text", "SRT becomes mov_text in MP4")
        } else { check(false, "MKV with subtitles → MP4 converts") }
        if case .success(let o) = convert(Step(.ffmpeg, "mkv", "avi"), mkv), let out = outputFile(o) {
            check(probe(out)?.subtitles.isEmpty == true && o.lossNotes.contains { $0.kind == .subtitlesDropped }, "AVI can't hold subtitles: a loss note")
        } else { check(false, "MKV with subtitles → AVI converts") }
        if case .success(let o) = convert(Step(.ffmpeg, "mkv", "mp4"), mkv, options: OptionValues(["subtitles": "hard"])), let out = outputFile(o) {
            check(probe(out)?.subtitles.isEmpty == true, "burned-in subtitles leave no subtitle stream")
        } else { check(false, "burning in subtitles converts") }
    }))

    SelfTest.cases.append(("MediaKit.audio", {
        // Two-pass loudness to −16 LUFS (quality §5.3: ±0.5 LU), measured back with ebur128.
        let tone = media.appendingPathComponent("tone-1k-24bit-44k.wav")
        if case .success(let o) = convert(Step(.ffmpeg, "wav", "mp3"), tone, options: OptionValues(["loudness": "-16"])), let out = outputFile(o) {
            let log = (try? complete(60) { try await tools.analyse(["-i", out.path, "-af", "ebur128"], workFolder: work("r128")) }?.get()) ?? ""
            let integrated = log.range(of: "I:", options: .backwards).flatMap { Double(log[$0.upperBound...].trimmingCharacters(in: .whitespaces).prefix { "-.0123456789".contains($0) }) }
            check(integrated.map { abs($0 + 16) <= 0.5 } == true, "−16 LUFS within 0.5 LU (\(integrated ?? .nan))")
        } else { check(false, "WAV → MP3 with loudness converts") }
        // FLAC keeps 24 bits; WAV → FLAC → WAV is bit-exact.
        if case .success(let o) = convert(Step(.avFoundation, "wav", "flac"), tone), let flac = outputFile(o),
           case .success(let b) = convert(Step(.avFoundation, "flac", "wav"), flac), let back = outputFile(b) {
            check(probe(back)?.audio.first?.codec == "pcm_s24le", "24-bit survives FLAC")
            check(pcmMD5(tone) == pcmMD5(back), "WAV → FLAC → WAV is bit-exact")
        } else { check(false, "WAV ↔ FLAC converts") }
        // Resampling 44.1 → 48 kHz with soxr into 32-bit float.
        if case .success(let o) = convert(Step(.avFoundation, "wav", "wav"), tone, options: OptionValues(["sampleRate": "48000", "bitDepth": "32f"])),
           let out = outputFile(o), let a = probe(out)?.audio.first {
            check(a.sampleRate == 48000 && a.codec == "pcm_f32le", "resampled to 48 kHz float (\(a.codec) \(a.sampleRate ?? 0))")
        } else { check(false, "resampling converts") }
        // Without the bundled tools AVFoundation resamples on its own (AudioConverter, mastering quality).
        let alone = AVFoundationConverter(tools: MediaTools(runner: nil))
        let folder = work("alone")
        let ctx = context(folder, source: tone, from: "wav", to: "wav", options: OptionValues(["sampleRate": "48000", "bitDepth": "24"]))
        if case .success(let o)? = complete(120, { try await alone.run(Step(.avFoundation, "wav", "wav"), input: .file(tone), context: ctx) }),
           let out = outputFile(o), let a = probe(out)?.audio.first {
            check(a.sampleRate == 48000 && a.codec == "pcm_s24le", "AVFoundation alone resamples to 48 kHz (\(a.codec) \(a.sampleRate ?? 0))")
        } else { check(false, "AVFoundation resamples without FFmpeg") }
        // MP3 VBR by default, CBR when a bitrate is set.
        if case .success(let o) = convert(Step(.ffmpeg, "wav", "mp3"), media.appendingPathComponent("sample.wav"), options: OptionValues(["bitrate": 128])),
           let out = outputFile(o) {
            check(abs(Double(probe(out)?.audio.first?.bitRate ?? 0) - 128_000) < 2000, "a set bitrate is CBR")
        } else { check(false, "WAV → MP3 at 128 kb/s converts") }
    }))

    SelfTest.cases.append(("MediaKit.animation", {
        // Video → GIF: palette, at most 15 fps.
        if case .success(let o) = convert(Step(.ffmpeg, "mp4", "gif"), media.appendingPathComponent("sample.mp4")), let out = outputFile(o),
           let v = probe(out)?.mainVideo {
            check(v.codec == "gif" && (v.frameRate ?? 99) <= 15.01, "MP4 → GIF at ≤ 15 fps (\(v.frameRate ?? 0))")
        } else { check(false, "MP4 → GIF converts") }
        if case .success(let o) = convert(Step(.ffmpeg, "mkv", "webp"), media.appendingPathComponent("sample.mkv")), let out = outputFile(o) {
            let bytes = (try? Data(contentsOf: out)) ?? Data()
            check(bytes.count > 100 && String(decoding: bytes.prefix(4), as: UTF8.self) == "RIFF" && bytes.range(of: Data("ANIM".utf8)) != nil, "MKV → animated WebP")
        } else { check(false, "MKV → WebP converts") }
        // Frames → video keep their delays exactly: 0.1 + 0.3 + 0.6 s = 1 s.
        let anim = animation([0.1, 0.3, 0.6], alpha: true)
        let source = scratch.appendingPathComponent("anim.gif")
        if case .success(let o) = convert(Step(.ffmpeg, .imageAsset, "mp4"), source, input: .image(anim)), let out = outputFile(o), let p = probe(out) {
            check(abs((p.duration ?? 0) - 1.0) < 0.05, "the delays add up to the video's length (\(p.duration ?? 0))")
            check(o.lossNotes.contains { $0.kind == .transparencyFilled }, "transparency composited is noted")
        } else { check(false, "frames → MP4 converts") }
        if case .success(let o) = convert(Step(.ffmpeg, .imageAsset, "avi"), source, input: .image(anim)), let out = outputFile(o), let p = probe(out) {
            check(abs((p.duration ?? 0) - 1.0) < 0.12, "constant-rate AVI keeps the timing by duplicating frames (\(p.duration ?? 0))")
        } else { check(false, "frames → AVI converts") }
        // Slides (no delays) → SWF, five seconds each by default.
        let slides = ImageAsset(frames: animation([0, 0]).frames.map { var f = $0; f.delay = nil; return f })
        if case .success(let o) = convert(Step(.ffmpeg, .imageAsset, "swf"), source, options: OptionValues(["secondsPerSlide": 1.0]), input: .image(slides)),
           let out = outputFile(o), let p = probe(out) {
            // SWF stores no duration: count the frames (30 fps by default).
            let json = try? complete(60) { try await tools.probeJSON(out, workFolder: work("count"), extra: ["-count_frames", "-select_streams", "v:0"]) }?.get()
            let frames = json.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { ($0["streams"] as? [[String: Any]])?.first?["nb_read_frames"] as? String }.flatMap(Int.init)
            check(frames.map { abs($0 - 60) <= 2 } == true && p.mainVideo?.codec == "flv1", "two slides at 1 s each make 60 SWF frames (\(frames ?? 0))")
        } else { check(false, "slides → SWF converts") }
    }))

    SelfTest.cases.append(("MediaKit.soundFont", {
        let sf2 = media.appendingPathComponent("sample.sf2")
        guard let data = try? Data(contentsOf: sf2), let font = try? SoundFont.read(data) else { check(false, "the SoundFont reads"); return }
        check(font.samples.count == 2 && font.presets.count == 1 && font.instruments.count == 1, "2 samples, 1 preset, 1 instrument")
        check(font.samples[0].frameCount == 2205 && font.samples[0].sampleRate == 22050, "sample headers are read")
        if case .success(let o) = convert(Step(.soundFontReader, "sf2", "sfz"), sf2), let folder = outputFile(o) {
            let files = FileManager.default.subpaths(atPath: folder.path) ?? []
            check(files.filter { $0.hasSuffix(".wav") }.count == 2 && files.contains { $0.hasSuffix(".sfz") }, "SFZ + two WAVs (\(files))")
            if let map = files.first(where: { $0.hasSuffix(".sfz") }), let text = try? String(contentsOf: folder.appendingPathComponent(map), encoding: .utf8) {
                check(text.contains("hikey=59") && text.contains("lokey=60") && text.contains("loop_mode=loop_continuous"), "regions split the keyboard, the loop is kept")
            }
        } else { check(false, "SF2 → SFZ converts") }
        if case .success(let o) = convert(Step(.soundFontReader, "sf2", "flac"), sf2), let folder = outputFile(o) {
            let files = (FileManager.default.subpaths(atPath: folder.path) ?? []).filter { $0.hasSuffix(".flac") }
            check(files.count == 2 && probe(folder.appendingPathComponent(files[0]))?.audio.first?.codec == "flac", "one FLAC per sample")
        } else { check(false, "SF2 → FLAC converts") }
        if case .success(let o) = convert(Step(.soundFontReader, "sf2", .archiveTree), sf2), case .archive(let tree) = o.value {
            check(tree.entries.contains { $0.path.hasSuffix(".sfz") } && tree.entries.filter { $0.kind == .file }.count == 3, "the archive tree lists the map and samples")
        } else { check(false, "SF2 → archive tree converts") }
    }))

    SelfTest.cases.append(("MediaKit.progressAndCancel", {
        // Progress arrives while FFmpeg works ("0:01 of 0:04"); a cancel stops it and leaves no partial file.
        let cancelFolder = work("cancel")
        let long = cancelFolder.appendingPathComponent("long.mkv")
        let made: Void? = try? complete(120) {
            try await tools.run(["-f", "lavfi", "-i", "testsrc2=s=1280x720:r=30:d=20", "-c:v", "mpeg4", "-q:v", "5", "-f", "matroska", "-y", long.path],
                                workFolder: cancelFolder)
        }?.get()
        check(made != nil, "the long clip is made")
        let seen = Box()
        let ctx = context(work("progress"), source: long, from: "mkv", to: "webm", options: OptionValues(["trimEnd": "4"]),
                          report: { p in if let f = p.fraction, f > 0, f < 1, p.unit?.hasSuffix("of 0:04") == true { seen.add() } })
        let ok = complete(300) { try await converter(.ffmpeg).run(Step(.ffmpeg, "mkv", "webm"), input: .file(long), context: ctx) }
        if case .success = ok { check(seen.count > 0, "progress was reported while encoding (\(seen.count))") }
        else { check(false, "the encode finished: \(String(describing: ok))") }
        let start = Date()
        let flag = Box()
        let cctx = context(cancelFolder, source: long, from: "mkv", to: "mkv", options: OptionValues(["videoCodec": "av1", "speed": "slow", "quality": 5]),
                           cancelled: { flag.count > 0 || Date().timeIntervalSince(start) > 1.5 })
        let cancelled = complete(120) { try await converter(.ffmpeg).run(Step(.ffmpeg, "mkv", "mkv"), input: .file(long), context: cctx) }
        if case .failure(let error)? = cancelled { check((error as? ConversionError) == .cancelled, "cancelling throws .cancelled (\(error))") }
        else { check(false, "the slow encode was cancelled") }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: cancelFolder.path)) ?? []
        check(left == ["long.mkv"], "no partial output is left (\(left))")
    }))

    // The in-process readers only: the SoundFont reader with the SFZ and WAV it writes, and the ffprobe JSON parse (damaged
    // JSON stands for what ffprobe prints about a hostile file; FFmpeg itself is never run on damaged media here).
    SelfTest.cases.append(("MediaKit.damagedInputNeverCrashes", {
        guard let sf2 = try? Data(contentsOf: media.appendingPathComponent("sample.sf2")) else { check(false, "the SoundFont fixture is there"); return }
        let bank = [UInt8](sf2)
        // The hydra (`pdta`: presets, bags, generators, sample headers) damaged in place, so the RIFF sizes still hold and
        // the damage reaches the indices and offsets rather than the chunk walk.
        let hydra = (0..<(bank.count - 4)).first { bank[$0..<$0 + 4].elementsEqual("pdta".utf8) } ?? 0
        let damageHydra: (inout FuzzRandom) -> [UInt8] = { rng in
            let tail = Array(bank[hydra...])
            var damaged = Fuzz.mutate(tail, using: &rng)
            while damaged.count != tail.count { damaged = Fuzz.mutate(tail, using: &rng) }
            return Array(bank[..<hydra]) + damaged
        }
        let constructed = """
            {"streams": [{"index": 0, "codec_name": "hevc", "profile": "Main 10", "codec_type": "video", "width": 1920, "height": 1080,
              "pix_fmt": "yuv420p10le", "color_range": "tv", "color_space": "bt2020nc", "color_transfer": "smpte2084", "color_primaries": "bt2020",
              "field_order": "progressive", "sample_aspect_ratio": "1:1", "r_frame_rate": "24000/1001", "avg_frame_rate": "24000/1001",
              "bits_per_raw_sample": "10", "duration": "4.004000", "bit_rate": "1200000", "disposition": {"default": 1, "attached_pic": 0},
              "tags": {"language": "eng", "rotate": "90"},
              "side_data_list": [{"side_data_type": "Display Matrix", "rotation": -90},
                {"side_data_type": "Mastering display metadata", "red_x": "34000/50000", "red_y": "16000/50000", "green_x": "13250/50000",
                 "green_y": "34500/50000", "blue_x": "7500/50000", "blue_y": "3000/50000", "white_point_x": "15635/50000",
                 "white_point_y": "16450/50000", "min_luminance": "50/10000", "max_luminance": "10000000/10000"},
                {"side_data_type": "Content light level metadata", "max_content": 1000, "max_average": 400}]},
              {"index": 1, "codec_name": "aac", "codec_type": "audio", "sample_fmt": "fltp", "sample_rate": "48000", "channels": 2,
               "channel_layout": "stereo", "bits_per_sample": 0, "duration": 4.0, "tags": {"title": "Main"}},
              {"index": 2, "codec_name": "subrip", "codec_type": "subtitle", "tags": {"language": "und"}}],
             "chapters": [{"id": 0, "start_time": "0.000000", "end_time": "2.000000", "tags": {"title": "One"}}],
             "format": {"format_name": "matroska,webm", "duration": "4.004000", "bit_rate": "1300000", "tags": {"ENCODER": "Lavf"}}}
            """
        let nesting = ["{\"a\":[", "[", "{\"streams\":[{\"side_data_list\":["]
        var seeds = [FuzzSeed(name: "sf2", ext: "sf2", bytes: bank),
                     FuzzSeed(name: "sf2-hydra", ext: "sf2", bytes: bank, mutate: damageHydra),
                     FuzzSeed(name: "probe", ext: "json", bytes: Array(constructed.utf8), nesting: nesting)]
        // What the bundled ffprobe really prints for the HDR clip, when Vendor/Tools is there.
        if tools.availability == .available,
           let captured = try? complete(60, { try await tools.probeJSON(media.appendingPathComponent("hdr-pq.mkv"), workFolder: work("probe-json")) })?.get() {
            seeds.append(FuzzSeed(name: "ffprobe", ext: "json", bytes: [UInt8](captured), nesting: nesting))
        }
        check(MediaProbe(json: Data(constructed.utf8))?.mainVideo?.colour.isHDR == true, "the constructed probe JSON reads")
        let ran = fuzzNeverCrashes("MediaKit.damagedInputNeverCrashes", seeds: seeds, count: 60) { url, seed in
            let data = try Data(contentsOf: url)
            if seed.ext == "sf2" {
                let font = try SoundFont.read(data)
                let writer = SFZWriter(font: font)
                for sample in font.samples { _ = writer.wavData(sample) }
                for preset in font.presets { _ = writer.sfzText(for: preset) { "Samples/\($0).wav" } }
            } else if let probe = MediaProbe(json: data) {
                _ = (probe.mainVideo?.bitDepth, probe.audio.count, probe.coverArt.count, probe.subtitles.map(\.isTextSubtitle))
                _ = probe.duration.map(MediaTime.clock)
            }
        }
        check(ran == 60 * seeds.count, "every damaged input was handled without a crash (\(ran))")
    }))
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}

/// MD5 of the decoded PCM (FFmpeg's `md5` muxer at the source's sample format): equal means bit-exact.
@MainActor private func pcmMD5(_ url: URL) -> String? {
    let folder = work("md5")
    let out = folder.appendingPathComponent("pcm.md5")
    guard (try? complete(60) { try await tools.run(["-i", url.path, "-map", "0:a:0", "-c:a", "pcm_s32le", "-f", "md5", "-y", out.path], workFolder: folder) }?.get()) != nil
    else { return nil }
    return try? String(contentsOf: out, encoding: .utf8)
}

/// One step of the sweep: nil when it converted to the right container with the planned streams, else what went wrong
/// ("skip: …" when no fixture can exist: CAVS and DSS have no LGPL encoder).
private func everyStep(_ step: Step) async -> String? {
    let folder = scratch.appendingPathComponent("mediakit-step-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let input: StepValue
    let source: URL
    let from: FormatID
    switch step.from {
    case .format(let f):
        from = f
        source = media.appendingPathComponent("sample.\(f.rawValue)")
        guard FileManager.default.fileExists(atPath: source.path) else { return "skip: no fixture for \(f.pill)" }
        input = .file(source)
    case .model:
        from = "gif"; source = folder.appendingPathComponent("frames.gif"); input = .image(animation([0.1, 0.2]))
    }
    let target: FormatID = if case .format(let t) = step.to { t } else { "zip" }
    let ctx = StepContext(workFolder: folder, source: source, sourceFormat: from, targetFormat: target, isFinalStep: true)
    let conv = MediaKitModule.converters(tools: runner).first { $0.id == step.engine }!
    let output: StepOutput
    do { output = try await conv.run(step, input: input, context: ctx) } catch { return "failed: \(error)" }
    switch output.value {
    case .archive(let tree): return tree.entries.isEmpty ? "empty archive tree" : nil
    case .file(let url):
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return "no output" }
        if isFolder.boolValue { return (FileManager.default.subpaths(atPath: url.path) ?? []).isEmpty ? "empty folder" : nil }
        guard url.pathExtension == target.rawValue else { return "named .\(url.pathExtension)" }
        guard let p = try? await tools.probe(url, workFolder: folder) else { return "output doesn't probe" }
        if let container = MediaContainer.of(target), container.isVideo || MediaRoutes.animationTargets.contains(target) {
            if p.video.isEmpty { return "no picture" }
        }
        if MediaContainer.of(target)?.isVideo == false, p.audio.isEmpty { return "no sound" }
        // ADTS has no duration (ffprobe guesses from the bitrate); MP3 at 8 kHz carries a whole frame of padding.
        if case .format = step.from, let duration = p.duration, let fixture = try? await tools.probe(source, workFolder: folder), let d = fixture.duration,
           !MediaRoutes.animationTargets.contains(target), target != "aac", abs(duration - d) > (target == "mp3" ? 0.25 : 0.15) {
            return "duration \(duration) vs \(d)"
        }
        return nil
    default: return "unexpected output"
    }
}

/// Small pictures for the checks.
enum MediaKitFixtures {
    static func png(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.8))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
