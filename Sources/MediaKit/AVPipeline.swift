import AVFoundation
import CoreMedia
import Foundation
import SuperConverterCore
import VideoToolbox

/// The AVFoundation route (formats §3.1): AVAssetReader decodes, AVAssetWriter encodes with VideoToolbox (H.264, HEVC,
/// ProRes) and AudioToolbox (AAC, ALAC, LPCM), or passes compressed samples through untouched. Rotation is kept as the track
/// transform, timing as the source's (variable frame rate stays variable), metadata as the asset's. Sound that loses bits
/// gets TPDF dither before it is quantised; resampling uses AudioConverter's mastering algorithm. ADTS AAC and FLAC, which
/// AVAssetWriter does not write, go through AudioToolbox's file writer. `RouteChoice` decides which jobs come here.
enum AVPipeline {
    static func run(_ source: AVSource, plan: AVPlan, to output: URL, context: StepContext) async throws {
        let fm = FileManager.default
        let partial = output.deletingLastPathComponent().appendingPathComponent(".partial-\(UUID().uuidString.prefix(8)).\(output.pathExtension)")
        do {
            if let fileType = RouteChoice.writerTypes[plan.target] {
                try await Transcoder(source: source, plan: plan, output: partial, fileType: fileType, context: context).run()
            } else {
                try await AudioFileWriter(source: source, plan: plan, output: partial, context: context).run()
            }
        } catch {
            try? fm.removeItem(at: partial)
            if context.isCancelled() { throw ConversionError.cancelled }
            throw error
        }
        if fm.fileExists(atPath: output.path) { try? fm.removeItem(at: output) }
        try fm.moveItem(at: partial, to: output)
        context.report(StepProgress(fraction: 1))
    }

    static func describe(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "AVFoundation stopped without saying why" }
        return "AVFoundation stopped: " + (error.localizedFailureReason ?? error.localizedDescription)
    }

    static func timeRange(_ plan: AVPlan) -> CMTimeRange? {
        guard plan.trimStart != nil || plan.trimDuration != nil else { return nil }
        let start = CMTime(seconds: plan.trimStart ?? 0, preferredTimescale: 600_000)
        return CMTimeRange(start: start, duration: plan.trimDuration.map { CMTime(seconds: $0, preferredTimescale: 600_000) } ?? .positiveInfinity)
    }

    /// Reader settings that decode to interleaved Float32 at `rate`, channels mixed to `channels`.
    static func floatReadSettings(rate: Int, channels: Int) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
         AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
    }

    static func aacFormat(_ codec: AudioCodec) -> AudioFormatID {
        switch codec {
        case .heAAC: kAudioFormatMPEG4AAC_HE
        case .heAACv2: kAudioFormatMPEG4AAC_HE_V2
        default: kAudioFormatMPEG4AAC
        }
    }

    /// AAC bits per second: the person's or the default, within what the rate and channels can carry.
    static func aacBitrate(_ codec: AudioCodec, set: Int?, rate: Int, channels: Int) -> Int {
        let fallback = switch codec {
        case .heAAC: 64
        case .heAACv2: 32
        default: channels > 2 ? 64 * channels : 192
        }
        return min(set ?? fallback, AudioEncoding.aacCeiling(rate: rate, channels: channels)) * 1000
    }
}

// MARK: - AVAssetReader → AVAssetWriter

private final class Transcoder: @unchecked Sendable {
    let source: AVSource, plan: AVPlan, output: URL, fileType: AVFileType, context: StepContext

    init(source: AVSource, plan: AVPlan, output: URL, fileType: AVFileType, context: StepContext) {
        self.source = source; self.plan = plan; self.output = output; self.fileType = fileType; self.context = context
    }

    func run() async throws {
        let asset = source.asset
        let tracks = try await asset.load(.tracks)
        let reader = try AVAssetReader(asset: asset)
        if let range = AVPipeline.timeRange(plan) { reader.timeRange = range }
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = plan.webReady
        if let metadata = try? await asset.load(.metadata) { writer.metadata = metadata.filter { $0.identifier != nil } }

        var pumps: [Pump] = []
        if let v = plan.video, let track = tracks.first(where: { $0.mediaType == .video }) {
            let (out, input) = try await videoPair(v, track: track)
            guard reader.canAdd(out), writer.canAdd(input) else { throw ConversionError.failed("AVFoundation can’t write this picture") }
            reader.add(out); writer.add(input)
            pumps.append(Pump(output: out, input: input, dither: nil, primary: true))
        }
        for (a, track) in zip(plan.audio, tracks.filter { $0.mediaType == .audio }) {
            let (out, input, dither) = try await audioPair(a, track: track)
            guard reader.canAdd(out), writer.canAdd(input) else { throw ConversionError.failed("AVFoundation can’t write this sound") }
            reader.add(out); writer.add(input)
            pumps.append(Pump(output: out, input: input, dither: dither, primary: pumps.isEmpty))
        }
        guard !pumps.isEmpty else { throw ConversionError.failed("Nothing in this file can be converted") }

        guard writer.startWriting() else { throw ConversionError.failed(AVPipeline.describe(writer.error)) }
        guard reader.startReading() else { writer.cancelWriting(); throw ConversionError.failed(AVPipeline.describe(reader.error)) }
        let start = CMTime(seconds: plan.trimStart ?? 0, preferredTimescale: 600_000)
        writer.startSession(atSourceTime: plan.trimStart != nil ? start : .zero)

        let total = plan.expectedDuration ?? 0
        let origin = plan.trimStart ?? 0
        let cancelled = Flag()
        await withTaskGroup(of: Void.self) { group in
            for pump in pumps { group.addTask { await self.drive(pump, cancelled: cancelled, origin: origin, total: total) } }
        }
        if cancelled.value || context.isCancelled() || Task.isCancelled {
            reader.cancelReading(); writer.cancelWriting()
            throw ConversionError.cancelled
        }
        if reader.status == .failed { writer.cancelWriting(); throw ConversionError.failed(AVPipeline.describe(reader.error)) }
        await writer.finishWriting()
        guard writer.status == .completed else { throw ConversionError.failed(AVPipeline.describe(writer.error)) }
    }

    private struct Pump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        /// TPDF dither step (one LSB of the target depth) for float sound quantised by the writer.
        let dither: Float?
        let primary: Bool
    }

    private func drive(_ pump: Pump, cancelled: Flag, origin: Double, total: Double) async {
        let queue = DispatchQueue(label: "MediaKit.AVPipeline.pump")
        let context = context
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            var lastReport = 0.0
            func finish() { finished = true; pump.input.markAsFinished(); done.resume() }
            pump.input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while pump.input.isReadyForMoreMediaData {
                    if cancelled.value || context.isCancelled() { cancelled.set(); finish(); return }
                    guard let sample = pump.output.copyNextSampleBuffer() else { finish(); return }
                    let buffer = pump.dither.flatMap { Dither.apply(to: sample, step: $0) } ?? sample
                    if !pump.input.append(buffer) { finish(); return }
                    if pump.primary, total > 0 {
                        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - origin
                        let fraction = min(max(t / total, 0), 0.999)
                        if fraction - lastReport >= 0.005 {
                            lastReport = fraction
                            context.report(StepProgress(fraction: fraction, unit: "\(MediaTime.clock(max(t, 0))) of \(MediaTime.clock(total))"))
                        }
                    }
                }
            }
        }
    }

    // MARK: Video

    private func videoPair(_ v: AVPlan.Video, track: AVAssetTrack) async throws -> (AVAssetReaderOutput, AVAssetWriterInput) {
        let descriptions = try await track.load(.formatDescriptions)
        let transform = try await track.load(.preferredTransform)
        if v.copy {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: descriptions.first)
            input.transform = transform
            input.expectsMediaDataInRealTime = false
            return (out, input)
        }
        let pixelFormat = v.codec == .prores ? kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            : (v.tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        out.alwaysCopiesSampleData = false

        let natural = try await track.load(.naturalSize)
        let rotated = abs(Int((atan2(Double(transform.b), Double(transform.a)) * 180 / .pi).rounded())) % 180 == 90
        var width = Int(natural.width.rounded()), height = Int(natural.height.rounded())
        var settings: [String: Any] = [AVVideoCodecKey: Self.codecType(v)]
        if let size = v.outputSize {
            (width, height) = rotated ? (size.height, size.width) : (size.width, size.height)
            settings[AVVideoScalingModeKey] = v.fit == .crop ? AVVideoScalingModeResizeAspectFill : AVVideoScalingModeResize
        } else if let desc = descriptions.first,
                  let par = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Int],
                  let h = par[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String],
                  let vs = par[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String], h != vs {
            settings[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: h, AVVideoPixelAspectRatioVerticalSpacingKey: vs]
        }
        settings[AVVideoWidthKey] = Geometry.even(width)
        settings[AVVideoHeightKey] = Geometry.even(height)
        settings[AVVideoColorPropertiesKey] = Self.colourProperties(v.colour)
        if !v.hardware {
            settings[AVVideoEncoderSpecificationKey] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
        }
        if v.codec != .prores {
            var compression: [String: Any] = [:]
            #if arch(arm64)
            compression[kVTCompressionPropertyKey_Quality as String] = VideoToolboxCalibration.quality(crf: v.crf, hevc: v.codec == .hevc)
            #else
            compression[AVVideoAverageBitRateKey] = VideoEncoding.averageKbps(width: width, height: height, rate: v.frameRate ?? 30, crf: v.crf,
                                                                              hevc: v.codec == .hevc) * 1000
            #endif
            if let g = v.keyframeInterval { compression[AVVideoMaxKeyFrameIntervalKey] = g }
            if let fps = v.frameRate { compression[AVVideoExpectedSourceFrameRateKey] = fps }
            if v.fast { compression[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true }
            if v.codec == .hevc {
                compression[AVVideoProfileLevelKey] = v.tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
            } else {
                compression[AVVideoProfileLevelKey] = switch v.h264Profile {
                case "baseline": AVVideoProfileLevelH264BaselineAutoLevel
                case "main": AVVideoProfileLevelH264MainAutoLevel
                default: AVVideoProfileLevelH264HighAutoLevel
                }
            }
            settings[AVVideoCompressionPropertiesKey] = compression
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        return (out, input)
    }

    static func codecType(_ v: AVPlan.Video) -> AVVideoCodecType {
        switch v.codec {
        case .hevc: return .hevc
        case .prores:
            switch v.proresProfile {
            case "proxy": return .proRes422Proxy
            case "lt": return .proRes422LT
            case "standard": return .proRes422
            case "4444": return .proRes4444
            case "xq": return AVVideoCodecType(rawValue: "ap4x")
            default: return .proRes422HQ
            }
        default: return .h264
        }
    }

    /// The source's tags (quality §5.1: never untagged), in AVFoundation's names.
    static func colourProperties(_ c: ColourTags) -> [String: String] {
        let primaries = switch c.primaries {
        case "bt2020": AVVideoColorPrimaries_ITU_R_2020
        case "smpte170m": AVVideoColorPrimaries_SMPTE_C
        case "bt470bg": AVVideoColorPrimaries_EBU_3213
        case "smpte432": AVVideoColorPrimaries_P3_D65
        default: AVVideoColorPrimaries_ITU_R_709_2
        }
        let transfer = c.transfer == "linear" ? AVVideoTransferFunction_Linear : AVVideoTransferFunction_ITU_R_709_2
        let matrix = switch c.matrix {
        case "bt2020nc", "bt2020c": AVVideoYCbCrMatrix_ITU_R_2020
        case "smpte170m", "bt470bg": AVVideoYCbCrMatrix_ITU_R_601_4
        default: AVVideoYCbCrMatrix_ITU_R_709_2
        }
        return [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix]
    }

    // MARK: Sound

    private func audioPair(_ a: AVPlan.Audio, track: AVAssetTrack) async throws -> (AVAssetReaderOutput, AVAssetWriterInput, Float?) {
        let descriptions = try await track.load(.formatDescriptions)
        if a.copy {
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: descriptions.first)
            input.expectsMediaDataInRealTime = false
            return (out, input, nil)
        }
        let source = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sourceRate = Int(source?.mSampleRate ?? 48000)
        let rate = a.sampleRate ?? sourceRate
        let channels = a.channels ?? Int(source?.mChannelsPerFrame ?? 2)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: AVPipeline.floatReadSettings(rate: sourceRate, channels: channels))
        out.alwaysCopiesSampleData = true
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: channels]
        if rate != sourceRate {
            settings[AVSampleRateConverterAlgorithmKey] = AVSampleRateConverterAlgorithm_Mastering
        }
        var dither: Float?
        switch a.codec {
        case .aac, .heAAC, .heAACv2:
            settings[AVFormatIDKey] = AVPipeline.aacFormat(a.codec)
            settings[AVEncoderBitRateKey] = AVPipeline.aacBitrate(a.codec, set: a.bitrate, rate: rate, channels: channels)
            if a.codec == .aac { settings[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_VariableConstrained }
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = a.bits
            if a.dither { dither = Dither.step(bits: a.bits) }
        default:
            let bigEndian = ["aiff", "aif", "aifc"].contains(plan.target.rawValue)
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = a.codec.bitDepth ?? 16
            settings[AVLinearPCMIsFloatKey] = a.codec == .float32
            settings[AVLinearPCMIsBigEndianKey] = bigEndian
            settings[AVLinearPCMIsNonInterleaved] = false
            if a.dither && a.codec != .float32 { dither = Dither.step(bits: a.codec.bitDepth ?? 16) }
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        return (out, input, dither)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool { lock.withLock { v } }
    func set() { lock.withLock { v = true } }
}

// MARK: - ADTS AAC and FLAC through AudioToolbox

/// The two AVFoundation-route audio containers AVAssetWriter does not write, through AudioToolbox's file writer (AVAudioFile
/// over ExtAudioFile). Decoding still goes through AVAssetReader; samples arrive as interleaved Float32 and are dithered
/// (TPDF) when they lose bits.
private struct AudioFileWriter {
    let source: AVSource, plan: AVPlan, output: URL, context: StepContext

    func run() async throws {
        guard let a = plan.audio.first else { throw ConversionError.impossiblePair(reason: "This file has no sound.") }
        let tracks = try await source.asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw ConversionError.failed("AVFoundation can’t find this sound") }
        let desc = try await track.load(.formatDescriptions).first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sourceRate = Int(desc?.mSampleRate ?? 48000)
        let rate = a.sampleRate ?? sourceRate
        let channels = a.channels ?? Int(desc?.mChannelsPerFrame ?? 2)

        let reader = try AVAssetReader(asset: source.asset)
        if let range = AVPipeline.timeRange(plan) { reader.timeRange = range }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: AVPipeline.floatReadSettings(rate: rate, channels: channels))
        guard reader.canAdd(out) else { throw ConversionError.failed("AVFoundation can’t read this sound") }
        reader.add(out)

        var settings: [String: Any] = [AVSampleRateKey: Double(rate), AVNumberOfChannelsKey: channels]
        var dither: Float?
        if plan.target == "flac" {
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = a.bits
            if a.dither { dither = Dither.step(bits: a.bits) }
        } else {
            settings[AVFormatIDKey] = AVPipeline.aacFormat(a.codec)
            settings[AVEncoderBitRateKey] = AVPipeline.aacBitrate(a.codec, set: a.bitrate, rate: rate, channels: channels)
        }
        guard reader.startReading() else { throw ConversionError.failed(AVPipeline.describe(reader.error)) }
        let total = plan.expectedDuration ?? 0
        var failure: Error?
        // The file is finished when the AVAudioFile goes away: the pool makes sure that happens before this returns.
        autoreleasepool {
            do {
                let file = try AVAudioFile(forWriting: output, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
                var written = 0.0, lastReport = 0.0
                while let sample = out.copyNextSampleBuffer() {
                    if context.isCancelled() { throw ConversionError.cancelled }
                    let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
                    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
                          let block = CMSampleBufferGetDataBuffer(sample), let dest = buffer.floatChannelData?[0] else { continue }
                    let count = Int(frames) * channels
                    guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: dest) == noErr
                    else { continue }
                    if let step = dither { Dither.add(to: dest, count: count, step: step) }
                    buffer.frameLength = frames
                    try file.write(from: buffer)
                    written += Double(frames) / Double(rate)
                    if total > 0, written / total - lastReport >= 0.005 {
                        lastReport = min(written / total, 0.999)
                        context.report(StepProgress(fraction: lastReport))
                    }
                }
                if #available(macOS 15.0, *) { file.close() }
            } catch { failure = error }
        }
        if let failure {
            reader.cancelReading()
            if let failure = failure as? ConversionError { throw failure }
            throw ConversionError.failed("AudioToolbox stopped: \(failure.localizedDescription)")
        }
        if reader.status == .failed { throw ConversionError.failed(AVPipeline.describe(reader.error)) }
    }
}

/// TPDF dither (quality §5.2) applied to float samples before a writer quantises them to fewer bits.
enum Dither {
    /// One LSB of a signed integer format of `bits`, in float full scale.
    static func step(bits: Int) -> Float { 1 / Float(1 << (bits - 1)) }

    /// Triangular noise of ±1 LSB added in place.
    static func add(to samples: UnsafeMutablePointer<Float>, count: Int, step: Float) {
        var rng = SystemRandomNumberGenerator()
        for i in 0..<count {
            samples[i] += (Float.random(in: -0.5...0.5, using: &rng) + Float.random(in: -0.5...0.5, using: &rng)) * step
        }
    }

    /// A copy of an interleaved Float32 sample buffer with TPDF dither added.
    static func apply(to sample: CMSampleBuffer, step: Float) -> CMSampleBuffer? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data) == noErr else { return nil }
        data.withUnsafeMutableBufferPointer { add(to: $0.baseAddress!, count: $0.count, step: step) }
        var newBlock: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0,
                                                 blockBufferOut: &newBlock) == noErr, let newBlock,
              data.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: newBlock, offsetIntoDestination: 0,
                                                                   dataLength: length) }) == noErr else { return nil }
        var copy: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: newBlock, formatDescription: format,
                                                                   sampleCount: CMSampleBufferGetNumSamples(sample),
                                                                   presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
                                                                   packetDescriptions: nil, sampleBufferOut: &copy) == noErr else { return nil }
        return copy
    }
}
