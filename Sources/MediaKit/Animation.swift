import CoreGraphics
import Foundation
import ImageIO
import SuperConverterCore
import UniformTypeIdentifiers

/// Video ↔ GIF/WebP animations (formats §5 O-ANIM).
///
/// Video → animation: FFmpeg's two-pass palette (`palettegen` + `paletteuse`, sierra2_4a by default) for GIF, libwebp's
/// animated encoder for WebP; at most 800 px wide and 15 fps unless the person asks for more (a full-HD GIF is hundreds of MB).
/// Animation → video: ImageKit (ImageIO) decodes the GIF/WebP into Core's `ImageAsset`; its frames are written as PNGs with
/// their own delays into an FFmpeg concat list, so the delays are kept exactly (variable frame rate in MP4/MOV/MKV, exact
/// duplication in containers that need a constant rate) and transparency is composited on the background. Slides (an
/// `ImageAsset` of pages from RenderKit) become a video the same way, each page shown for `secondsPerSlide`.
enum Animation {
    static func job(source: URL, probe: MediaProbe, target: FormatID, settings s: MediaSettings, interlaced: Bool) throws -> FFmpegJob {
        guard let video = probe.mainVideo else { throw ConversionError.impossiblePair(reason: "This file has no picture to animate.") }
        var job = FFmpegJob(muxer: target == "gif" ? "gif" : "webp", duration: s.outputDuration(probe.duration),
                            plan: MediaPlan(engine: .ffmpeg, container: target, duration: s.outputDuration(probe.duration),
                                            streams: [MediaPlan.Stream(index: video.index, kind: .video, codec: video.codec, outputCodec: target.rawValue,
                                                                       width: video.width, height: video.height, frameRate: video.frameRate)],
                                            trimStart: s.trimStart, trimEnd: s.trimEnd))
        var args: [String] = []
        if let start = s.trimStart { args += ["-ss", MediaTime.argument(start)] }
        if let end = s.trimEnd { args += ["-to", MediaTime.argument(end)] }
        args += ["-i", source.path]

        var srcW = video.width ?? 0, srcH = video.height ?? 0
        if let r = video.rotation, Int(abs(r).rounded()) % 180 == 90 { swap(&srcW, &srcH) }
        guard srcW > 0, srcH > 0 else { throw ConversionError.damaged(FormatID(source.pathExtension.lowercased())) }
        let displayW = Int((Double(srcW) * (video.sampleAspect ?? 1)).rounded())
        let g = Geometry.fit(source: (displayW, srcH), box: (s.width, s.height), fit: s.fit)
        var chain: [String] = []
        if interlaced && s.deinterlace { chain.append("bwdif=mode=send_frame:parity=auto:deint=all") }
        var rate = min(s.fps ?? 15, video.frameRate ?? 15)
        // GIF delays are whole hundredths of a second: 15 fps is 7/100 s a frame, never a rounded-down 6.
        if target == "gif" { rate = 100 / (100 / rate).rounded(.up) }
        chain.append("fps=\(VideoEncoding.rational(rate))")
        chain.append("scale=\(Geometry.even(g.scaleW)):\(Geometry.even(g.scaleH)):flags=lanczos")
        if let cw = g.cropW, let ch = g.cropH { chain.append("crop=\(Geometry.even(cw)):\(Geometry.even(ch))") }
        if let pw = g.padW, let ph = g.padH { chain.append("pad=\(Geometry.even(pw)):\(Geometry.even(ph)):(ow-iw)/2:(oh-ih)/2:color=black") }
        if video.colour.isHDR {
            job.lossNotes.append(LossNote(.hdrToSDR, detail: "Animations are standard range"))
        }
        let alpha = VideoEncoding.hasAlpha(video)
        if target == "gif" {
            let dither: String
            switch s.dither {
            case "bayer": dither = "bayer:bayer_scale=3"
            case "none": dither = "none"
            default: dither = "sierra2_4a"
            }
            // One palette for the whole clip from the changing pixels; each frame then only redraws the rectangle that moved.
            let graph = "[0:\(video.index)]\(chain.joined(separator: ",")),split[a][b];"
                + "[a]palettegen=max_colors=\(s.colours):stats_mode=diff:reserve_transparent=\(alpha ? 1 : 0)[p];"
                + "[b][p]paletteuse=dither=\(dither):diff_mode=rectangle[out]"
            args += ["-filter_complex", graph, "-map", "[out]", "-loop", s.loopForever ? "0" : "-1"]
        } else {
            chain.append("format=\(alpha ? "yuva420p" : "yuv420p")")
            args += ["-map", "0:\(video.index)", "-vf", chain.joined(separator: ","), "-c:v", "libwebp_anim", "-lossless", "0",
                     "-q:v", String(s.webpQuality), "-compression_level", "4", "-loop", s.loopForever ? "0" : "1"]
        }
        args += ["-an", "-sn", "-map_metadata", "-1"]
        job.arguments = args
        if !probe.audio.isEmpty { job.warnings.append("Animations have no sound") }
        return job
    }

    // MARK: Frames → video

    /// Writes `asset`'s frames as PNG files plus an FFmpeg concat list with each frame's duration. `delay` is the time a
    /// frame without its own delay is shown (a slide). Transparent pixels are composited on `background`.
    static func writeFrames(_ asset: ImageAsset, into folder: URL, delay: Double, background: CGColor,
                            isCancelled: () -> Bool) throws -> (list: URL, duration: Double, hadAlpha: Bool) {
        guard !asset.frames.isEmpty else { throw ConversionError.impossiblePair(reason: "There are no pictures to make a video from.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = asset.frames[0]
        let width = Geometry.even(first.width), height = Geometry.even(first.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var lines = ["ffconcat version 1.0"]
        var total = 0.0
        var hadAlpha = false
        for (index, frame) in asset.frames.enumerated() {
            if isCancelled() { throw ConversionError.cancelled }
            guard let image = frame.cgImage(),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ConversionError.damaged("gif") }
            hadAlpha = hadAlpha || frame.hasAlpha
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Every frame is drawn at the first frame's size (pages of other sizes are fitted, centred).
            let f = min(Double(width) / Double(frame.width), Double(height) / Double(frame.height))
            let w = Double(frame.width) * f, h = Double(frame.height) * f
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
            guard let flat = context.makeImage() else { throw ConversionError.damaged("gif") }
            let name = String(format: "frame-%06d.png", index)
            let url = folder.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw ConversionError.folderNotWritable(name: folder.lastPathComponent)
            }
            CGImageDestinationAddImage(destination, flat, nil)
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.folderNotWritable(name: folder.lastPathComponent) }
            // GIF delays under 20 ms play as 100 ms in browsers; keep what the file says, but never zero.
            let seconds = max(frame.delay ?? delay, 0.01)
            total += seconds
            lines += ["file '\(name)'", "duration \(String(format: "%.6f", seconds))"]
        }
        // The concat demuxer drops the last duration unless the last file is listed again.
        lines.append("file '\(String(format: "frame-%06d.png", asset.frames.count - 1))'")
        let list = folder.appendingPathComponent("frames.ffconcat")
        try lines.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        return (list, total, hadAlpha)
    }

    /// The colour transparent frames are composited on: O-ANIM's `background` (#RRGGBB), white by default.
    static func background(_ options: OptionValues) -> CGColor {
        let hex = (options["background"]?.string ?? "#FFFFFF").trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard hex.count == 6, let v = Int(hex, radix: 16) else { return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1) }
        return CGColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}
