import Foundation
import SuperConverterCore

/// One media step from start to finish: probe, choose the route, plan, run, verify (formats §3.2 MediaKit).
struct MediaRun {
    let tools: MediaTools
    let context: StepContext

    static let reWrapped = "No re-encoding needed"

    // MARK: FFmpeg

    func ffmpeg(_ url: URL, sourceFormat: FormatID, target: FormatID) async throws -> StepOutput {
        let probe = try await tools.probe(url, workFolder: context.workFolder)
        return try await ffmpeg(url, probe: probe, sourceFormat: sourceFormat, target: target)
    }

    func ffmpeg(_ url: URL, probe: MediaProbe, sourceFormat: FormatID, target: FormatID) async throws -> StepOutput {
        let animation = MediaRoutes.animationTargets.contains(target)
        let settings = MediaSettings(context.options, animation: animation)
        let job: FFmpegJob
        if animation {
            let interlaced = settings.deinterlace ? try await tools.isInterlaced(url, probe: probe, sourceFormat: sourceFormat, workFolder: context.workFolder) : false
            job = try Animation.job(source: url, probe: probe, target: target, settings: settings, interlaced: interlaced)
        } else {
            guard let container = MediaContainer.of(target) else { throw ConversionError.unsupportedPair(from: sourceFormat, to: target) }
            let facts = try await facts(url, probe: probe, sourceFormat: sourceFormat, container: container, settings: settings)
            job = try FFmpegPlanner.job(source: url, sourceFormat: sourceFormat, probe: probe, target: container, settings: settings, facts: facts,
                                        externalSubtitles: settings.subtitleFile)
        }
        let output = try Self.outputURL(context, target)
        try await tools.encode(job.arguments, format: job.muxer, to: output, duration: job.duration, context: context)
        try await verify(output, target: target, expectVideo: MediaContainer.of(target)?.isVideo ?? true, plan: job.plan)
        var warnings = job.warnings
        if job.plan.streams.allSatisfy({ $0.outputCodec == nil }) && !animation { warnings.append(Self.reWrapped) }
        return StepOutput(.file(output), lossNotes: job.lossNotes, warnings: warnings)
    }

    /// Pictures (animation frames or slides) → video.
    func frames(_ asset: ImageAsset, target: FormatID) async throws -> StepOutput {
        guard let container = MediaContainer.of(target), container.isVideo else { throw ConversionError.unsupportedPair(from: "gif", to: target) }
        let deck = !asset.isAnimated
        var settings = MediaSettings(context.options, deckVideo: deck)
        let folder = context.workFolder.appendingPathComponent("frames-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        context.report(StepProgress(fraction: 0, unit: "Preparing \(asset.frames.count) pictures"))
        let written = try Animation.writeFrames(asset, into: folder, delay: settings.secondsPerSlide, background: Animation.background(context.options),
                                                isCancelled: context.isCancelled)
        let first = asset.frames[0]
        let delays = asset.frames.map { $0.delay ?? settings.secondsPerSlide }
        let shortest = max(delays.min() ?? 0.1, 1.0 / 60)
        // A constant rate fine enough for the shortest frame (capped at 60 fps) where the container needs one; otherwise the
        // delays themselves become the timestamps.
        if container.constantFrameRate || deck { settings.fps = settings.fps ?? min(1 / shortest, 60) }
        let probe = MediaProbe(formatName: "concat", duration: written.duration, bitRate: nil,
                               streams: [MediaProbe.Stream(index: 0, kind: .video, codec: "png", width: Geometry.even(first.width),
                                                           height: Geometry.even(first.height), pixelFormat: "rgb24", frameRate: 1 / shortest,
                                                           isVariableFrameRate: Set(delays).count > 1, colour: MediaProbe.Colour(), hdr: MediaProbe.HDRMetadata(),
                                                           isAttachedPicture: false, isDefault: true)],
                               chapters: [], tags: [:])
        var job = try FFmpegPlanner.job(source: written.list, sourceFormat: "gif", probe: probe, target: container, settings: settings,
                                        inputFormat: ["-f", "concat", "-safe", "0"])
        if written.hadAlpha { job.lossNotes.append(LossNote(.transparencyFilled)) }
        // The concat list repeats its last picture so its delay counts; at a constant rate the output then ends where the
        // delays end (with variable timestamps the repeat is the end marker itself).
        if settings.fps != nil { job.arguments += ["-t", MediaTime.argument(written.duration)] }
        let output = try Self.outputURL(context, target)
        try await tools.encode(job.arguments, format: job.muxer, to: output, duration: written.duration, context: context,
                               unit: deck ? "\(asset.frames.count) slides" : "\(asset.frames.count) frames")
        try await verify(output, target: target, expectVideo: true, plan: job.plan)
        return StepOutput(.file(output), lossNotes: job.lossNotes, warnings: job.warnings)
    }

    // MARK: AVFoundation, with the route chosen from the file

    func avFoundation(_ url: URL, sourceFormat: FormatID, target: FormatID) async throws -> StepOutput {
        guard let container = MediaContainer.of(target) else { throw ConversionError.unsupportedPair(from: sourceFormat, to: target) }
        let settings = MediaSettings(context.options)
        let asset = try await AVProbe.load(url, sourceFormat: sourceFormat)
        let probe: MediaProbe? = tools.availability == .available ? try await tools.probe(url, workFolder: context.workFolder) : nil
        var facts = SourceFacts()
        if let probe { facts = try await self.facts(url, probe: probe, sourceFormat: sourceFormat, container: container, settings: settings) }
        switch RouteChoice.choose(asset: asset, probe: probe, sourceFormat: sourceFormat, target: container, settings: settings, facts: facts,
                                  ffmpegAvailable: probe != nil) {
        case .avFoundation(let plan):
            let output = try Self.outputURL(context, target)
            try await AVPipeline.run(asset, plan: plan, to: output, context: context)
            return StepOutput(.file(output), warnings: plan.copiesEverything ? [Self.reWrapped] : [])
        case .ffmpeg(let why):
            guard let probe else { throw ConversionError.failed(why + ", and this copy of Super Converter is missing FFmpeg") }
            return try await ffmpeg(url, probe: probe, sourceFormat: sourceFormat, target: target)
        }
    }

    // MARK: Analysis passes

    /// Interlacing (video targets), the true peak (gain or resampling), the loudness measurement (two-pass EBU R128).
    func facts(_ url: URL, probe: MediaProbe, sourceFormat: FormatID, container: MediaContainer, settings s: MediaSettings) async throws -> SourceFacts {
        var facts = SourceFacts()
        let trim = (s.trimStart.map { ["-ss", MediaTime.argument($0)] } ?? []) + (s.trimEnd.map { ["-to", MediaTime.argument($0)] } ?? [])
        if container.isVideo, s.deinterlace, probe.mainVideo != nil, s.videoCodec != "copy" {
            facts.interlaced = try await tools.isInterlaced(url, probe: probe, sourceFormat: sourceFormat, workFolder: context.workFolder)
        }
        guard let audio = probe.audio.first, !s.removeSound else { return facts }
        if let target = s.loudness {
            context.report(StepProgress(fraction: nil, unit: "Measuring loudness"))
            let log = try await tools.analyse(trim + ["-i", url.path, "-map", "0:\(audio.index)", "-vn", "-sn",
                                                     "-af", "loudnorm=I=\(target):TP=\(FFmpegPlanner.limiterCeiling):LRA=11:print_format=json"],
                                              workFolder: context.workFolder)
            facts.loudnorm = Self.loudnorm(log)
        } else if s.volume != 1 || (s.sampleRate.map { $0 != audio.sampleRate } ?? false) {
            context.report(StepProgress(fraction: nil, unit: "Measuring peaks"))
            let log = try await tools.analyse(trim + ["-i", url.path, "-map", "0:\(audio.index)", "-vn", "-sn", "-af", "ebur128=peak=true"],
                                              workFolder: context.workFolder)
            facts.truePeak = Self.truePeak(log)
        }
        return facts
    }

    /// `loudnorm`'s first-pass JSON (the last `{…}` in its log).
    static func loudnorm(_ log: String) -> LoudnormMeasurement? {
        guard let open = log.range(of: "{", options: .backwards), let close = log.range(of: "}", options: .backwards), open.lowerBound < close.upperBound,
              let object = try? JSONSerialization.jsonObject(with: Data(log[open.lowerBound..<close.upperBound].utf8)) as? [String: Any] else { return nil }
        func n(_ k: String) -> Double? { MediaProbe.double(object[k]).flatMap { $0.isFinite ? $0 : nil } }
        guard let i = n("input_i"), let tp = n("input_tp"), let lra = n("input_lra"), let th = n("input_thresh") else { return nil }
        return LoudnormMeasurement(integrated: i, truePeak: tp, range: lra, threshold: th, offset: n("target_offset") ?? 0)
    }

    /// `ebur128=peak=true`'s summary: "True peak: … Peak: -0.4 dBFS".
    static func truePeak(_ log: String) -> Double? {
        guard let summary = log.range(of: "True peak:", options: .backwards), let peak = log[summary.upperBound...].range(of: "Peak:") else { return nil }
        let rest = log[peak.upperBound...].trimmingCharacters(in: .whitespaces)
        return Double(rest.prefix { "-+.0123456789".contains($0) }) ?? (rest.hasPrefix("-inf") ? -.infinity : nil)
    }

    // MARK: Output

    /// The output must hold what was planned: a picture for video targets, sound when the source had sound.
    func verify(_ output: URL, target: FormatID, expectVideo: Bool, plan: MediaPlan) async throws {
        guard tools.availability == .available else { return }
        let probe: MediaProbe
        do { probe = try await tools.probe(output, workFolder: context.workFolder) } catch {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.failed("The converted \(target.pill) couldn’t be read back")
        }
        let wantsVideo = expectVideo && plan.streams.contains { $0.kind == .video }
        let wantsAudio = plan.streams.contains { $0.kind == .audio }
        if wantsVideo && probe.video.isEmpty || wantsAudio && probe.audio.isEmpty {
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.failed("The converted \(target.pill) is missing its \(wantsVideo && probe.video.isEmpty ? "picture" : "sound")")
        }
    }

    /// A new file in the work folder named after the source; an existing name gets a number.
    static func outputURL(_ context: StepContext, _ format: FormatID) throws -> URL {
        let stem = context.source.deletingPathExtension().lastPathComponent
        var url = context.workFolder.appendingPathComponent(stem).appendingPathExtension(format.rawValue)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = context.workFolder.appendingPathComponent("\(stem) \(n)").appendingPathExtension(format.rawValue)
            n += 1
        }
        return url
    }
}
