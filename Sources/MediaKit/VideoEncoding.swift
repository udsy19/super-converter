import Foundation
import SuperConverterCore

/// The picture side of an FFmpeg encode (quality §5.1): geometry (size, fit, square pixels, container sizes), deinterlacing,
/// HDR kept or tone-mapped, BT.601 ↔ BT.709 when scaling across SD/HD, frame rate, and the encoder's own settings.
struct VideoEncoding {
    var filters: [String] = []
    var arguments: [String] = []
    var pixelFormat: String
    var width: Int
    var height: Int
    var lossNotes: [LossNote] = []

    /// Rates MPEG-2, DV, DVD and MXF accept.
    static let standardRates: [Double] = [24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 50, 60000.0 / 1001, 60]

    static func plan(video: MediaProbe.Stream, probe: MediaProbe, codec: VideoCodec, target: MediaContainer, settings s: MediaSettings,
                     facts: SourceFacts, sourceFormat: FormatID) throws -> VideoEncoding {
        // Rotation is applied while decoding (FFmpeg's autorotate), so plan with the picture as it is shown.
        let quarterTurn = video.rotation.map { Int(abs($0).rounded()) % 180 == 90 } ?? false
        var srcW = video.width ?? 0, srcH = video.height ?? 0
        if quarterTurn { swap(&srcW, &srcH) }
        guard srcW > 0, srcH > 0 else { throw ConversionError.damaged(sourceFormat) }
        let sar = video.sampleAspect ?? 1
        let displayW = Int((Double(srcW) * sar).rounded())
        let sourceRate = video.frameRate ?? 25

        // Frame rate: the person's, then what the container insists on.
        var rate: Double? = s.fps
        let fixedRates = [.mpeg2, .dv, .dnxhr].contains(codec) || ["vob", "mxf", "dv"].contains(target.format.rawValue)
        let pal = abs((rate ?? sourceRate) - 25) < 0.5 || abs((rate ?? sourceRate) - 50) < 0.5
        if codec == .dv || target.format == "vob" { rate = pal ? 25 : 30000.0 / 1001 }
        else if fixedRates { rate = standardRates.min { abs($0 - (rate ?? sourceRate)) < abs($1 - (rate ?? sourceRate)) } }
        let outRate = rate ?? sourceRate

        // Geometry.
        var box: (w: Int?, h: Int?) = (s.width, s.height)
        var fit = s.fit
        var dar: String?
        if codec == .dv || target.format == "vob" {
            box = (720, pal ? 576 : 480); fit = .pad
            dar = Double(displayW) / Double(srcH) > 1.5 ? "16/9" : "4/3"
        }
        if let ratio = s.aspectRatio, Self.aspect(ratio) != nil { dar = ratio.replacingOccurrences(of: ":", with: "/") }
        var geometry = Geometry.fit(source: (displayW, srcH), box: box, fit: fit)
        let anamorphicOut = dar != nil && (codec == .dv || target.format == "vob")
        if anamorphicOut { geometry = Geometry.Result(scaleW: box.w!, scaleH: box.h!, cropW: nil, cropH: nil, padW: nil, padH: nil) }
        let outW = Geometry.even(geometry.finalW), outH = Geometry.even(geometry.finalH)
        let scaleW = Geometry.even(geometry.scaleW), scaleH = Geometry.even(geometry.scaleH)
        let scaling = scaleW != srcW || scaleH != srcH || sar != 1

        // Colour (quality §5.1): read the tags; untagged streams are BT.601 below 720 lines and BT.709 from there.
        var src = ColourTags(video.colour, height: srcH)
        if Self.isRGB(video.pixelFormat) { src = ColourTags(MediaProbe.Colour(), height: outH) }
        let isHDR = video.colour.isHDR
        let keepHDR = isHDR && !s.hdrToSDR && codec.carriesHDR
        let toneMap = isHDR && !keepHDR
        var out = src
        if toneMap { out = ColourTags(primaries: "bt709", transfer: "bt709", matrix: "bt709", range: "tv") }
        else if scaling, !isHDR, (srcH >= 720) != (outH >= 720) {
            // Scaling across SD/HD changes the matrix (BT.601 ↔ BT.709); primaries and transfer stay as tagged.
            out.matrix = outH >= 720 ? "bt709" : (out.primaries == "bt470bg" ? "bt470bg" : "smpte170m")
        }

        var e = VideoEncoding(pixelFormat: "yuv420p", width: outW, height: outH)
        let tenBit = video.bitDepth > 8
        e.pixelFormat = codec.pixelFormat(tenBit: keepHDR || (tenBit && codec.carriesHDR), alpha: Self.hasAlpha(video) && codec.carriesAlpha(in: target),
                                          ntscDV: codec == .dv && !pal, profile: s.profile)

        if facts.interlaced && s.deinterlace {
            // bwdif on the detected fields: one frame per frame, so the frame rate and A/V timing are untouched.
            e.filters.append("bwdif=mode=send_frame:parity=auto:deint=all")
        }
        if toneMap {
            let peak = Self.peak(video.hdr)
            e.filters.append("zscale=t=linear:npl=100:tin=\(src.transfer):min=\(src.matrix):pin=\(src.primaries):rin=\(Self.zRange(src.range))")
            e.filters.append("format=gbrpf32le")
            e.filters.append("zscale=p=bt709")
            e.filters.append("tonemap=tonemap=mobius:desat=0:peak=\(String(format: "%.2f", peak))")
            e.filters.append("zscale=w=\(scaleW):h=\(scaleH):f=lanczos:t=bt709:m=bt709:r=limited:d=error_diffusion")
            e.lossNotes.append(LossNote(.hdrToSDR, detail: s.hdrToSDR ? "" : "\(target.format.pill) with \(codec.label) can’t carry HDR"))
        } else if Self.isRGB(video.pixelFormat) {
            // Pictures (GIF, PNG frames, slides, RGB video): one conversion into the output's matrix, limited range.
            e.filters.append("scale=\(scaleW):\(scaleH):flags=lanczos+accurate_rnd+full_chroma_int:out_color_matrix=\(Self.swsMatrix(out.matrix)):out_range=tv")
        } else if scaling || out.matrix != src.matrix {
            if Self.zscaleReads(video.pixelFormat) {
                e.filters.append("zscale=w=\(scaleW):h=\(scaleH):f=lanczos:min=\(src.matrix):m=\(out.matrix):tin=\(src.transfer):t=\(out.transfer)"
                                 + ":pin=\(src.primaries):p=\(out.primaries):rin=\(Self.zRange(src.range)):r=\(Self.zRange(out.range)):d=error_diffusion")
            } else {
                e.filters.append("scale=\(scaleW):\(scaleH):flags=lanczos+accurate_rnd+full_chroma_int:in_color_matrix=\(Self.swsMatrix(src.matrix)):out_color_matrix=\(Self.swsMatrix(out.matrix))")
            }
        }
        if let cw = geometry.cropW, let ch = geometry.cropH {
            e.filters.append("crop=\(Geometry.even(cw)):\(Geometry.even(ch))")
        }
        if let pw = geometry.padW, let ph = geometry.padH {
            e.filters.append("pad=\(Geometry.even(pw)):\(Geometry.even(ph)):(ow-iw)/2:(oh-ih)/2:color=black")
        }
        if let dar { e.filters.append("setdar=\(dar)") } else if scaling { e.filters.append("setsar=1") }
        if let r = rate, abs(r - sourceRate) > 0.001 || video.isVariableFrameRate && target.constantFrameRate {
            e.filters.append("fps=\(Self.rational(r))")
        }
        e.filters.append("format=\(e.pixelFormat)")

        // Encoder.
        let gop = s.keyframeInterval ?? max(Int((outRate * 2).rounded()), 1)
        var a: [String] = ["-c:v", codec.encoder(hardware: s.hardware)]
        switch codec {
        case .h264, .hevc:
            let hevc = codec == .hevc
            #if arch(arm64)
            a += ["-q:v", String(Int((VideoToolboxCalibration.quality(crf: s.crf, hevc: hevc) * 100).rounded()))]
            #else
            // Intel Macs' VideoToolbox has no constant-quality mode: an average rate from the same crf scale.
            a += ["-b:v", "\(Self.averageKbps(width: outW, height: outH, rate: outRate, crf: s.crf, hevc: hevc))k"]
            #endif
            a += s.hardware ? ["-allow_sw", "1"] : ["-require_sw", "1"]
            if hevc {
                if keepHDR || e.pixelFormat == "p010le" { a += ["-profile:v", "main10"] } else { a += ["-profile:v", "main"] }
                if ["mp4", "mov", "m4v"].contains(target.format.rawValue) { a += ["-tag:v", "hvc1"] }
                if e.pixelFormat == "bgra" { a += ["-alpha_quality", "0.75"] }
            } else {
                let profile = s.profile.map(Self.h264Profile) ?? (["3gp", "3gpp", "3g2"].contains(target.format.rawValue) ? "baseline" : "high")
                a += ["-profile:v", profile]
                if let level = s.level { a += ["-level", level] }
            }
            if s.speed == .fast { a += ["-prio_speed", "1"] } else if s.speed == .slow { a += ["-prio_speed", "0"] }
            a += ["-g", String(gop)]
        case .prores:
            let alpha = e.pixelFormat == "bgra"
            a += ["-profile:v", s.profile.flatMap(Self.proresProfile) ?? (alpha ? "4444" : "hq")]
            a += s.hardware ? ["-allow_sw", "1"] : ["-require_sw", "1"]
        case .av1:
            a += ["-crf", String(Self.vpCRF(s)), "-preset", String([MediaSettings.Speed.fast: 8, .medium: 6, .slow: 4][s.speed]!), "-g", String(gop)]
            var params = ["tune=0"]
            if keepHDR, let md = video.hdr.masteringDisplay { params.append("mastering-display=\(Self.svtMastering(md))") }
            if keepHDR, let cll = video.hdr.maxCLL { params.append("content-light=\(cll),\(video.hdr.maxFALL ?? 0)") }
            a += ["-svtav1-params", params.joined(separator: ":")]
        case .vp9:
            a += ["-crf", String(Self.vpCRF(s)), "-b:v", "0", "-deadline", "good", "-cpu-used", String(Self.cpuUsed(s.speed)), "-row-mt", "1", "-g", String(gop)]
            if e.pixelFormat == "yuv420p10le" { a += ["-profile:v", "2"] }
            if e.pixelFormat == "yuva420p" { a += ["-auto-alt-ref", "0"] }
        case .vp8:
            // libvpx's VP8 constant quality needs a ceiling: about 0.3 bit per pixel per frame.
            let cap = max(Int(Double(outW * outH) * outRate * 0.3 / 1000), 200)
            a += ["-crf", String(max(Self.vpCRF(s), 4)), "-b:v", "\(cap)k", "-deadline", "good", "-cpu-used", String(Self.cpuUsed(s.speed)), "-g", String(gop)]
            if e.pixelFormat == "yuva420p" { a += ["-auto-alt-ref", "0"] }
        case .mpeg4:
            a += ["-q:v", String(s.qscale), "-mbd", "rd", "-g", String(gop)]
            if target.format == "avi" { a += ["-tag:v", "XVID"] }
        case .flv1, .msmpeg4v3, .wmv2, .rv20:
            a += ["-q:v", String(s.qscale), "-g", String(gop)]
        case .mpeg2:
            if target.format == "vob" {
                // DVD-Video limits (formats §5: VOB keeps DVD constraints): 9.8 Mb/s peak including audio, GOP 15 (PAL 12).
                a += ["-q:v", String(s.qscale), "-maxrate", "8000k", "-bufsize", "1835k", "-g", pal ? "12" : "15", "-bf", "2"]
            } else {
                a += ["-q:v", String(s.qscale), "-g", String(min(gop, 15)), "-bf", "2"]
                if target.format == "mxf" { a += ["-profile:v", "0"] }
            }
        case .dnxhr:
            a += ["-profile:v", e.pixelFormat == "yuv422p10le" ? "dnxhr_hqx" : "dnxhr_hq"]
        case .dv:
            break
        case .theora:
            // libtheora's quality runs 0–10: crf 20 ⇒ 7.5, every 4 crf one step.
            a += ["-q:v", String(format: "%.1f", min(max(10 - Double(s.crf - 10) / 4, 0), 10)), "-g", String(gop)]
        }
        if let r = rate { a += ["-r", Self.rational(r)] }
        a += ["-color_primaries", out.primaries, "-color_trc", out.transfer, "-colorspace", out.matrix, "-color_range", out.range]
        if let tune = s.tune, !tune.isEmpty, codec.isVideoToolbox {
            e.lossNotes.append(LossNote(.otherLoss, detail: "The Mac’s encoder has no “\(tune)” tune; it was ignored"))
        }
        e.arguments = a
        return e
    }

    // MARK: Helpers

    static func aspect(_ text: String) -> Double? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "/" }).compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    static func hasAlpha(_ s: MediaProbe.Stream) -> Bool {
        guard let f = s.pixelFormat else { return false }
        return f.hasPrefix("yuva") || f.hasPrefix("rgba") || f.hasPrefix("bgra") || f.hasPrefix("argb") || f.hasPrefix("abgr")
            || f == "ya8" || f == "ya16be" || f == "ya16le" || f.hasPrefix("gbrap") || f == "pal8" && s.codec == "gif" || f.hasPrefix("ayuv")
    }

    /// Planar YUV/GBR formats zimg reads directly; paletted and packed ones go through swscale.
    static func zscaleReads(_ format: String?) -> Bool {
        guard let f = format else { return false }
        return (f.hasPrefix("yuv") || f.hasPrefix("gbr") || f.hasPrefix("gray")) && !f.contains("yuyv") && !f.contains("uyvy")
    }

    /// RGB and paletted pictures: their YUV tags are chosen for the output, not read from the source.
    static func isRGB(_ format: String?) -> Bool {
        guard let f = format else { return false }
        return f.hasPrefix("rgb") || f.hasPrefix("bgr") || f.hasPrefix("argb") || f.hasPrefix("abgr") || f.hasPrefix("gbr") || f == "pal8"
            || f.hasPrefix("0rgb") || f.hasPrefix("rgb0") || f.hasPrefix("bgr0") || f.hasPrefix("0bgr")
    }

    static func zRange(_ range: String) -> String { range == "pc" ? "full" : "limited" }

    static func swsMatrix(_ matrix: String) -> String {
        switch matrix {
        case "bt709": "bt709"
        case "bt2020nc", "bt2020c": "bt2020"
        case "smpte240m": "smpte240m"
        default: "bt601"
        }
    }

    /// The tone-mapping peak in multiples of 100 cd/m² (`zscale npl=100`): the content light level, else the mastering
    /// display's maximum, else 1000 cd/m².
    static func peak(_ hdr: MediaProbe.HDRMetadata) -> Double {
        if let cll = hdr.maxCLL, cll > 0 { return Double(cll) / 100 }
        if let md = hdr.masteringDisplay, let l = md.range(of: "L("), let comma = md[l.upperBound...].firstIndex(of: ","),
           let max = Double(md[l.upperBound..<comma]), max > 0 { return max / 10000 / 100 }
        return 10
    }

    /// SVT-AV1 wants the mastering display as normalised numbers: G(x,y)B(x,y)R(x,y)WP(x,y)L(max,min).
    static func svtMastering(_ x265: String) -> String {
        let numbers = x265.split(whereSeparator: { !"0123456789".contains($0) }).compactMap { Double($0) }
        guard numbers.count == 10 else { return x265 }
        func c(_ v: Double) -> String { String(format: "%.4f", v / 50000) }
        func l(_ v: Double) -> String { String(format: "%.4f", v / 10000) }
        return "G(\(c(numbers[0])),\(c(numbers[1])))B(\(c(numbers[2])),\(c(numbers[3])))R(\(c(numbers[4])),\(c(numbers[5])))WP(\(c(numbers[6])),\(c(numbers[7])))L(\(l(numbers[8])),\(l(numbers[9])))"
    }

    /// VP9/AV1 CRF: formats §5 uses 30 for the default (CloudConvert 31), and the x264 scale + 10 for anything else.
    static func vpCRF(_ s: MediaSettings) -> Int { min(max(s.crf + 10, 0), 63) }

    static func cpuUsed(_ speed: MediaSettings.Speed) -> Int { [MediaSettings.Speed.fast: 4, .medium: 2, .slow: 1][speed]! }

    static func h264Profile(_ p: String) -> String {
        switch p.lowercased() {
        case "baseline", "constrained_baseline": "baseline"
        case "main": "main"
        case "high444", "high10", "high422": "high"
        default: "high"
        }
    }

    static func proresProfile(_ p: String) -> String? {
        switch p.lowercased() {
        case "proxy", "0": "proxy"
        case "lt", "1": "lt"
        case "standard", "422", "2": "standard"
        case "hq", "3": "hq"
        case "4444", "4": "4444"
        case "xq", "4444xq", "5": "xq"
        default: nil
        }
    }

    /// A frame rate as FFmpeg's exact rational ("30000/1001").
    static func rational(_ r: Double) -> String {
        for base in [24.0, 30, 60, 120] where abs(r - base * 1000 / 1001) < 0.001 { return "\(Int(base * 1000))/1001" }
        if abs(r - r.rounded()) < 0.0005 { return String(Int(r.rounded())) }
        return String(format: "%.4f", r)
    }

    /// Intel fallback: x264's rule of thumb (≈ 0.1 bit per pixel at crf 20 for H.264, halving every 6 crf; HEVC 30 % less).
    static func averageKbps(width: Int, height: Int, rate: Double, crf: Int, hevc: Bool) -> Int {
        let bpp = 0.1 * pow(2, Double(20 - crf) / 6) * (hevc ? 0.7 : 1)
        return max(Int(Double(width * height) * rate * bpp / 1000), 100)
    }
}

/// The four colour tags, with BT.601/709 defaults for untagged streams (quality §5.1: never untagged).
struct ColourTags: Equatable {
    var primaries: String, transfer: String, matrix: String, range: String

    init(primaries: String, transfer: String, matrix: String, range: String) {
        self.primaries = primaries; self.transfer = transfer; self.matrix = matrix; self.range = range
    }

    init(_ c: MediaProbe.Colour, height: Int) {
        let hd = height >= 720
        let pal = height == 576 || height == 288
        let sdPrimaries = pal ? "bt470bg" : "smpte170m"
        primaries = c.primaries ?? (hd ? "bt709" : sdPrimaries)
        transfer = c.transfer ?? (hd ? "bt709" : "smpte170m")
        matrix = c.matrix ?? (hd ? "bt709" : (pal ? "bt470bg" : "smpte170m"))
        range = c.range ?? "tv"
    }
}

extension VideoCodec {
    var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .prores: "ProRes"
        case .av1: "AV1"
        case .vp8: "VP8"
        case .vp9: "VP9"
        case .mpeg4: "MPEG-4"
        case .flv1: "Sorenson Spark"
        case .msmpeg4v3: "MS-MPEG4"
        case .wmv2: "WMV 8"
        case .mpeg2: "MPEG-2"
        case .dnxhr: "DNxHR"
        case .dv: "DV"
        case .theora: "Theora"
        case .rv20: "RealVideo 2"
        }
    }

    func carriesAlpha(in target: MediaContainer) -> Bool {
        switch self {
        case .hevc: target.format == "mov"
        case .prores: true
        case .vp8, .vp9: target.format == "webm" || target.format == "mkv"
        default: false
        }
    }

    func pixelFormat(tenBit: Bool, alpha: Bool, ntscDV: Bool, profile: String?) -> String {
        switch self {
        case .h264: "yuv420p"
        case .hevc: alpha ? "bgra" : (tenBit ? "p010le" : "yuv420p")
        case .prores: alpha || profile.flatMap(VideoEncoding.proresProfile).map { $0 == "4444" || $0 == "xq" } == true ? "bgra" : "p210le"
        case .av1: tenBit ? "yuv420p10le" : "yuv420p"
        case .vp9: alpha ? "yuva420p" : (tenBit ? "yuv420p10le" : "yuv420p")
        case .vp8: alpha ? "yuva420p" : "yuv420p"
        case .dnxhr: tenBit ? "yuv422p10le" : "yuv422p"
        case .dv: ntscDV ? "yuv411p" : "yuv420p"
        case .mpeg2, .mpeg4, .flv1, .msmpeg4v3, .wmv2, .theora, .rv20: "yuv420p"
        }
    }
}

/// Size and fit (formats §5 O-VIDEO `width`, `height`, `fit` = max · crop · scale · pad).
enum Geometry {
    struct Result: Equatable {
        var scaleW: Int, scaleH: Int
        var cropW: Int?, cropH: Int?
        var padW: Int?, padH: Int?
        var finalW: Int { cropW ?? padW ?? scaleW }
        var finalH: Int { cropH ?? padH ?? scaleH }
    }

    /// `max` fits inside the box and never enlarges; `scale` stretches to the box; `crop` fills it and cuts the overflow;
    /// `pad` fits inside and adds black bars. A box with one side keeps the aspect ratio.
    static func fit(source: (Int, Int), box: (w: Int?, h: Int?), fit: MediaSettings.Fit) -> Result {
        let (sw, sh) = (Double(source.0), Double(source.1))
        guard box.w != nil || box.h != nil else { return Result(scaleW: source.0, scaleH: source.1) }
        let bw = Double(box.w ?? Int((Double(box.h!) * sw / sh).rounded()))
        let bh = Double(box.h ?? Int((Double(box.w!) * sh / sw).rounded()))
        let inside = min(bw / sw, bh / sh)
        switch fit {
        case .max:
            let f = min(inside, 1)
            return Result(scaleW: Int((sw * f).rounded()), scaleH: Int((sh * f).rounded()))
        case .scale:
            return Result(scaleW: Int(bw), scaleH: Int(bh))
        case .crop:
            let f = max(bw / sw, bh / sh)
            return Result(scaleW: Int((sw * f).rounded()), scaleH: Int((sh * f).rounded()), cropW: Int(bw), cropH: Int(bh))
        case .pad:
            return Result(scaleW: Int((sw * inside).rounded()), scaleH: Int((sh * inside).rounded()), padW: Int(bw), padH: Int(bh))
        }
    }

    /// Every encoder here subsamples chroma 2:1 at least horizontally: sizes are even.
    static func even(_ v: Int) -> Int { max(v - v % 2, 2) }
}
