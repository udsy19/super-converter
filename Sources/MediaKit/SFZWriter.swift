import Foundation
import SuperConverterCore

/// SF2 → one audio file per sample (WAV with its loop points in a `smpl` chunk, or FLAC) plus, for SFZ and ZIP, an SFZ
/// map per preset that places those samples on the keyboard (formats §6.4, O-SF2). The result is a folder; for ZIP it is
/// also described as an `ArchiveTree` for ArchiveKit to pack. FLAC samples are encoded by the bundled FFmpeg (lossless,
/// same bit depth).
struct SFZWriter {
    let font: SoundFont
    /// "wav" or "flac".
    var sampleFormat = "wav"
    var writeMap = true
    var folderPerPreset = true

    struct Result {
        var folder: URL
        var files: [URL]
    }

    func write(into folder: URL, tools: MediaTools, workFolder: URL, isCancelled: @escaping @Sendable () -> Bool) async throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let samplesDir = writeMap ? folder.appendingPathComponent("Samples", isDirectory: true) : folder
        try fm.createDirectory(at: samplesDir, withIntermediateDirectories: true)
        if sampleFormat == "flac", case .unavailable(let why) = tools.availability { throw ConversionError.failed(why) }
        var files: [URL] = []
        var names: [Int: String] = [:]
        var used = Set<String>()
        var pendingFLAC: [(wav: URL, flac: URL)] = []
        for (i, sample) in font.samples.enumerated() where !sample.isROM && sample.frameCount > 0 {
            if isCancelled() { throw ConversionError.cancelled }
            var base = Self.safe(sample.name.isEmpty ? "Sample \(i + 1)" : sample.name)
            if used.contains(base.lowercased()) { base += " \(i + 1)" }
            used.insert(base.lowercased())
            let url = samplesDir.appendingPathComponent(base + "." + sampleFormat)
            if sampleFormat == "flac" {
                let wav = workFolder.appendingPathComponent("sf2-\(i).wav")
                try wavData(sample).write(to: wav)
                pendingFLAC.append((wav, url))
            } else {
                try wavData(sample).write(to: url)
            }
            names[i] = url.lastPathComponent
            files.append(url)
        }
        // FLAC through the bundled FFmpeg, 32 samples a run (lossless at the stored bit depth).
        for start in stride(from: 0, to: pendingFLAC.count, by: 32) {
            if isCancelled() { throw ConversionError.cancelled }
            let batch = pendingFLAC[start..<min(start + 32, pendingFLAC.count)]
            var args: [String] = []
            for item in batch { args += ["-i", item.wav.path] }
            for (n, item) in batch.enumerated() {
                args += ["-map", "\(n):a:0", "-c:a", "flac", "-compression_level", "8", "-f", "flac", "-y", item.flac.path]
            }
            try await tools.run(args, workFolder: workFolder)
            for item in batch { try? fm.removeItem(at: item.wav) }
        }
        guard writeMap else { return Result(folder: folder, files: files) }
        for (p, preset) in font.presets.enumerated() {
            let title = Self.safe(String(format: "%03d-%03d ", preset.bank, preset.program) + (preset.name.isEmpty ? "Preset \(p + 1)" : preset.name))
            let dir = folderPerPreset ? folder.appendingPathComponent(title, isDirectory: true) : folder
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let prefix = folderPerPreset ? "../Samples/" : "Samples/"
            let url = dir.appendingPathComponent(title + ".sfz")
            try sfzText(for: preset, samplePath: { names[$0].map { prefix + $0 } }).write(to: url, atomically: true, encoding: .utf8)
            files.append(url)
        }
        return Result(folder: folder, files: files)
    }

    // MARK: SFZ

    /// Regions for every preset zone × instrument zone: key and velocity ranges intersected, the sample's root key,
    /// tuning, loop, volume, pan and the volume envelope (SF2 generators → SFZ opcodes).
    func sfzText(for preset: SoundFont.Preset, samplePath: (Int) -> String?) -> String {
        var lines = ["// \(preset.name) — bank \(preset.bank), program \(preset.program), from \(font.name)", ""]
        for pz in preset.zones {
            guard let ii = pz.instrument, ii < font.instruments.count else { continue }
            let inst = font.instruments[ii]
            for iz in inst.zones {
                guard let si = iz.sampleID, si < font.samples.count, let path = samplePath(si) else { continue }
                let sample = font.samples[si]
                func value(_ op: Int) -> Int? { iz.amount(op) ?? inst.global?.amount(op) }
                func offset(_ op: Int) -> Int { pz.amount(op) ?? preset.global?.amount(op) ?? 0 }
                func intersect(_ op: Int) -> ClosedRange<Int> {
                    let a = iz.range(op) ?? inst.global?.range(op) ?? 0...127
                    let b = pz.range(op) ?? preset.global?.range(op) ?? 0...127
                    let lo = max(a.lowerBound, b.lowerBound)
                    return lo...max(min(a.upperBound, b.upperBound), lo)
                }
                let keys = intersect(43), vel = intersect(44)
                var region = ["<region>", "sample=\(path)", "lokey=\(keys.lowerBound)", "hikey=\(keys.upperBound)",
                              "lovel=\(vel.lowerBound)", "hivel=\(vel.upperBound)"]
                let root = value(58).flatMap { $0 >= 0 ? $0 : nil } ?? sample.originalPitch
                region.append("pitch_keycenter=\(root)")
                let tune = (value(52) ?? 0) + offset(52) + sample.pitchCorrection
                if tune != 0 { region.append("tune=\(tune)") }
                let transpose = (value(51) ?? 0) + offset(51)
                if transpose != 0 { region.append("transpose=\(transpose)") }
                let attenuation = Double((value(48) ?? 0) + offset(48)) / 10   // centibels → dB
                if attenuation != 0 { region.append("volume=\(String(format: "%.1f", -attenuation))") }
                let pan = Double((value(17) ?? 0) + offset(17)) / 5          // 0.1 % → −100…100
                if pan != 0 { region.append("pan=\(String(format: "%.1f", pan))") }
                let mode = value(54) ?? 0
                region.append(mode == 1 ? "loop_mode=loop_continuous" : (mode == 3 ? "loop_mode=loop_sustain" : "loop_mode=no_loop"))
                if mode & 1 == 1 {
                    let ls = sample.loopStart - sample.start + (value(2) ?? 0) + (value(45) ?? 0) * 32768
                    let le = sample.loopEnd - sample.start + (value(3) ?? 0) + (value(50) ?? 0) * 32768
                    region += ["loop_start=\(ls)", "loop_end=\(max(le - 1, ls))"]
                }
                let startOffset = (value(0) ?? 0) + (value(4) ?? 0) * 32768
                if startOffset > 0 { region.append("offset=\(startOffset)") }
                func seconds(_ op: Int) -> Double? { value(op).map { pow(2, Double($0) / 1200) } }
                if let a = seconds(34) { region.append("ampeg_attack=\(String(format: "%.4f", a))") }
                if let h = seconds(35) { region.append("ampeg_hold=\(String(format: "%.4f", h))") }
                if let d = seconds(36) { region.append("ampeg_decay=\(String(format: "%.4f", d))") }
                if let s = value(37) { region.append("ampeg_sustain=\(String(format: "%.2f", 100 * pow(10, -Double(s) / 200)))") }
                if let rel = seconds(38) { region.append("ampeg_release=\(String(format: "%.4f", rel))") }
                lines.append(region.joined(separator: " "))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Samples

    /// RIFF WAVE with `fmt `, a `smpl` chunk (unity note, pitch fraction, loop) and `data`.
    func wavData(_ sample: SoundFont.Sample) -> Data {
        let pcm = font.pcm(of: sample)
        let bits = font.bitDepth, rate = UInt32(max(sample.sampleRate, 1))
        var fmt = Data()
        fmt.le16(1); fmt.le16(1); fmt.le32(rate); fmt.le32(rate * UInt32(bits / 8)); fmt.le16(UInt16(bits / 8)); fmt.le16(UInt16(bits))
        var smpl = Data()
        smpl.le32(0); smpl.le32(0); smpl.le32(1_000_000_000 / rate)
        smpl.le32(UInt32(max(sample.originalPitch, 0)))
        smpl.le32(sample.pitchCorrection > 0 ? UInt32(Double(sample.pitchCorrection) / 100 * 4294967296.0) : 0)
        smpl.le32(0); smpl.le32(0)
        let looped = sample.loopEnd > sample.loopStart && sample.loopStart >= sample.start
        smpl.le32(looped ? 1 : 0); smpl.le32(0)
        if looped {
            smpl.le32(0); smpl.le32(0)
            smpl.le32(UInt32(sample.loopStart - sample.start)); smpl.le32(UInt32(max(sample.loopEnd - sample.start - 1, 0)))
            smpl.le32(0); smpl.le32(0)
        }
        var body = Data("WAVE".utf8)
        body.chunk("fmt ", fmt); body.chunk("smpl", smpl); body.chunk("data", pcm)
        var out = Data("RIFF".utf8); out.le32(UInt32(body.count)); out.append(body)
        return out
    }

    /// File-name-safe text (no slashes, colons or control characters).
    static func safe(_ name: String) -> String {
        String(name.map { c -> Character in "/:\\\0".contains(c) || c.isNewline ? "_" : c }).trimmingCharacters(in: .whitespaces)
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
    mutating func chunk(_ id: String, _ body: Data) {
        append(Data(id.utf8)); le32(UInt32(body.count)); append(body)
        if body.count % 2 == 1 { append(0) }
    }
}
