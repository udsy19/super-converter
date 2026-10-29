import Foundation
import SuperConverterCore

/// HDR10 static metadata in HEVC (quality §5.1). FFmpeg 7.1's VideoToolbox encoder keeps PQ/HLG and 10 bits but writes no
/// SEI for the frames' SMPTE ST 2086 mastering display or CTA-861.3 content light level, and none of its bitstream filters
/// adds one. So after the encode the video is copied out into a MOV of its own, every sync sample gets one prefix SEI NAL
/// unit with both messages (ITU-T H.265 D.2.28 and D.2.35: the same 24- and 4-byte big-endian payloads as VideoToolbox's
/// kVTCompressionPropertyKey_MasteringDisplayColorVolume and _ContentLightLevelInfo), and FFmpeg copies it back in with the
/// other streams. Only the sample sizes and chunk offsets of that MOV change: every timestamp, edit and flag stays as FFmpeg
/// wrote it. Containers with fields of their own for the metadata (MP4/MOV mdcv and clli, Matroska's colour elements) keep
/// what FFmpeg wrote there too.
enum HDRSEI {
    /// The NAL unit (header, messages, trailing bits, emulation prevention); nil when the source has neither message.
    static func nal(_ hdr: MediaProbe.HDRMetadata) -> Data? {
        var rbsp: [UInt8] = []
        if let m = hdr.masteringValues {
            // payloadType 137: green, blue, red and white point x/y, then the maximum and minimum luminance.
            rbsp += [137, 24] + m[0..<8].flatMap { bigEndian(min(max($0, 0), 50000), 2) }
            rbsp += bigEndian(min(max(m[8], 0), Int(UInt32.max)), 4) + bigEndian(min(max(m[9], 0), Int(UInt32.max)), 4)
        }
        if let cll = hdr.maxCLL {
            // payloadType 144: MaxCLL and MaxFALL, cd/m².
            rbsp += [144, 4] + bigEndian(min(max(cll, 0), 65535), 2) + bigEndian(min(max(hdr.maxFALL ?? 0, 0), 65535), 2)
        }
        guard !rbsp.isEmpty else { return nil }
        rbsp.append(0x80)
        // nal_unit_type 39 (PREFIX_SEI_NUT), layer 0, temporal id 0; 0x03 after any two zeros that precede 0–3.
        var nal: [UInt8] = [39 << 1, 1]
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2 && byte <= 3 { nal.append(3); zeros = 0 }
            nal.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return Data(nal)
    }

    /// Writes `sei` into the video of `output`, FFmpeg's encode of `job`, in place.
    static func write(_ sei: Data, into output: URL, job: FFmpegJob, tools: MediaTools, context: StepContext) async throws {
        context.report(StepProgress(fraction: nil, unit: "Writing the HDR metadata"))
        let tag = UUID().uuidString.prefix(8)
        let plain = context.workFolder.appendingPathComponent(".hevc-\(tag).mov"), marked = context.workFolder.appendingPathComponent(".hdr10-\(tag).mov")
        defer { for url in [plain, marked] { try? FileManager.default.removeItem(at: url) } }
        // One track only: no metadata, so no timecode track either.
        try await tools.run(["-i", output.path, "-map", "0:v:0", "-c", "copy", "-tag:v", "hvc1", "-map_metadata", "-1", "-map_chapters", "-1",
                             "-write_tmcd", "0", "-f", "mov", "-y", plain.path], workFolder: context.workFolder)
        try mark(plain, with: [UInt8](sei), to: marked)
        guard !context.isCancelled() else { throw ConversionError.cancelled }
        // Data streams (a MOV timecode track) are written again from `job.muxing`.
        let wrap = ["-i", marked.path, "-i", output.path, "-map", "0:v:0", "-map", "1", "-map", "-1:v:0", "-map", "-1:d?", "-c", "copy",
                    "-map_metadata", "1", "-map_metadata:s:v:0", "1:s:v:0", "-map_chapters", "1"]
        try await tools.encode(wrap + job.muxing, format: job.muxer, to: output, duration: nil, context: context, unit: "Writing the HDR metadata")
    }

    // MARK: The MOV

    private struct Box {
        var type: String
        var body: [UInt8]
        var children: [Box]?
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]
    private static let unreadable = ConversionError.failed("The converted video couldn’t be read back to add its HDR metadata")

    /// Copies a one-track HEVC MOV with `sei` before the first slice of every sync sample: a new `mdat`, then `moov` with
    /// the new sample sizes (`stsz`) and chunk offsets (`co64`).
    static func mark(_ source: URL, with sei: [UInt8], to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let end = try input.seekToEnd()
        var ftyp: [UInt8] = [], moov: [Box]?
        var offset: UInt64 = 0
        while offset + 8 <= end {
            try input.seek(toOffset: offset)
            let header = [UInt8](try input.read(upToCount: 16) ?? Data())
            guard header.count >= 8 else { throw unreadable }
            var size = UInt64(value(header, 0, 4)), headerSize: UInt64 = 8
            if size == 1, header.count == 16 { size = UInt64(value(header, 8, 8)); headerSize = 16 } else if size == 0 { size = end - offset }
            guard size >= headerSize, offset + size <= end else { throw unreadable }
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if type == "ftyp" || type == "moov" {
                try input.seek(toOffset: offset)
                let box = [UInt8](try input.read(upToCount: Int(size)) ?? Data())
                if type == "ftyp" { ftyp = box } else { moov = try parse(Array(box[Int(headerSize)...])) }
            }
            offset += size
        }
        guard var moov, moov.filter({ $0.type == "trak" }).count == 1, let t = moov.firstIndex(where: { $0.type == "trak" }),
              var stbl = find(["mdia", "minf", "stbl"], in: moov[t].children ?? []) else { throw unreadable }
        func table(_ type: String) -> [UInt8]? { stbl.children?.first { $0.type == type }?.body }

        // Sample sizes, chunk offsets, samples per chunk, sync samples, NAL length size.
        guard let stsz = table("stsz"), stsz.count >= 12, let stsc = table("stsc"), stsc.count >= 8, let stsd = table("stsd"),
              let hvcC = Self.position(of: "hvcC", in: stsd), hvcC + 8 + 22 <= stsd.count else { throw unreadable }
        let lengthSize = Int(stsd[hvcC + 8 + 21] & 3) + 1
        let count = value(stsz, 8, 4), fixed = value(stsz, 4, 4)
        guard fixed != 0 || stsz.count >= 12 + 4 * count else { throw unreadable }
        let sizes = (0..<count).map { fixed != 0 ? fixed : value(stsz, 12 + 4 * $0, 4) }
        var chunkOffsets: [UInt64]
        if let stco = table("stco"), stco.count >= 8, stco.count >= 8 + 4 * value(stco, 4, 4) {
            chunkOffsets = (0..<value(stco, 4, 4)).map { UInt64(value(stco, 8 + 4 * $0, 4)) }
        } else if let co64 = table("co64"), co64.count >= 8, co64.count >= 8 + 8 * value(co64, 4, 4) {
            chunkOffsets = (0..<value(co64, 4, 4)).map { UInt64(value(co64, 8 + 8 * $0, 8)) }
        } else { throw unreadable }
        let runs = value(stsc, 4, 4)
        guard stsc.count >= 8 + 12 * runs else { throw unreadable }
        var perChunk = [Int](repeating: 0, count: chunkOffsets.count)
        for r in 0..<runs {
            let first = value(stsc, 8 + 12 * r, 4), samples = value(stsc, 12 + 12 * r, 4)
            let next = r + 1 < runs ? value(stsc, 20 + 12 * r, 4) : chunkOffsets.count + 1
            guard first >= 1 else { throw unreadable }
            for c in first..<max(next, first) where c <= chunkOffsets.count { perChunk[c - 1] = samples }
        }
        guard perChunk.reduce(0, +) == count else { throw unreadable }
        var sync = Set(0..<count)
        if let stss = table("stss"), stss.count >= 8 {
            sync = Set((0..<value(stss, 4, 4)).compactMap { 8 + 4 * $0 + 4 <= stss.count ? value(stss, 8 + 4 * $0, 4) - 1 : nil })
        }

        // The new mdat, chunk by chunk.
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        try out.write(contentsOf: ftyp)
        let mdatStart = UInt64(ftyp.count)
        try out.write(contentsOf: [0, 0, 0, 1] + Array("mdat".utf8) + [UInt8](repeating: 0, count: 8))
        var position = mdatStart + 16
        var newSizes: [Int] = []
        var sample = 0
        for (c, chunkOffset) in chunkOffsets.enumerated() {
            chunkOffsets[c] = position
            var read = chunkOffset
            for _ in 0..<perChunk[c] {
                try input.seek(toOffset: read)
                var bytes = [UInt8](try input.read(upToCount: sizes[sample]) ?? Data())
                guard bytes.count == sizes[sample] else { throw unreadable }
                read += UInt64(sizes[sample])
                if sync.contains(sample) { insert(sei, into: &bytes, lengthSize: lengthSize) }
                try out.write(contentsOf: bytes)
                position += UInt64(bytes.count)
                newSizes.append(bytes.count)
                sample += 1
            }
        }
        try out.seek(toOffset: mdatStart + 8)
        try out.write(contentsOf: bigEndian(Int(position - mdatStart), 8))
        try out.seek(toOffset: position)

        // The new moov.
        stbl.children = stbl.children!.compactMap { box in
            switch box.type {
            case "stsz": return Box(type: "stsz", body: Array(stsz[0..<4]) + bigEndian(0, 4) + bigEndian(count, 4) + newSizes.flatMap { bigEndian($0, 4) })
            case "stco", "co64": return Box(type: "co64", body: [0, 0, 0, 0] + bigEndian(chunkOffsets.count, 4) + chunkOffsets.flatMap { bigEndian(Int($0), 8) })
            default: return box
            }
        }
        replace(["mdia", "minf", "stbl"], in: &moov[t].children!, with: stbl)
        try out.write(contentsOf: serialize([Box(type: "moov", body: [], children: moov)]))
    }

    /// The SEI as one more length-prefixed NAL unit before the first VCL one (types 0–31); a sample without one is left as it is.
    private static func insert(_ sei: [UInt8], into sample: inout [UInt8], lengthSize n: Int) {
        var offset = 0
        while offset + n < sample.count, sample[offset + n] >> 1 & 0x3F >= 32 { offset += n + value(sample, offset, n) }
        guard offset + n < sample.count else { return }
        sample.insert(contentsOf: bigEndian(sei.count, n) + sei, at: offset)
    }

    private static func parse(_ bytes: [UInt8]) throws -> [Box] {
        var boxes: [Box] = []
        var i = 0
        while i + 8 <= bytes.count {
            var size = value(bytes, i, 4), header = 8
            if size == 1, i + 16 <= bytes.count { size = value(bytes, i + 8, 8); header = 16 } else if size == 0 { size = bytes.count - i }
            guard size >= header, i + size <= bytes.count else { throw unreadable }
            let type = String(decoding: bytes[i + 4..<i + 8], as: UTF8.self), body = Array(bytes[i + header..<i + size])
            boxes.append(Box(type: type, body: body, children: containers.contains(type) ? try parse(body) : nil))
            i += size
        }
        return boxes
    }

    private static func serialize(_ boxes: [Box]) -> [UInt8] {
        boxes.flatMap { box -> [UInt8] in
            let body = box.children.map(serialize) ?? box.body
            return bigEndian(body.count + 8, 4) + Array(box.type.utf8) + body
        }
    }

    private static func find(_ path: [String], in boxes: [Box]) -> Box? {
        guard let first = path.first, let box = boxes.first(where: { $0.type == first }) else { return nil }
        return path.count == 1 ? box : find(Array(path.dropFirst()), in: box.children ?? [])
    }

    private static func replace(_ path: [String], in boxes: inout [Box], with new: Box) {
        guard let first = path.first, let i = boxes.firstIndex(where: { $0.type == first }) else { return }
        if path.count == 1 { boxes[i] = new } else { replace(Array(path.dropFirst()), in: &boxes[i].children!, with: new) }
    }

    /// Where a box's type code sits inside an unparsed body (the hvcC inside the sample description), minus the size field.
    private static func position(of type: String, in bytes: [UInt8]) -> Int? {
        let code = Array(type.utf8)
        guard bytes.count >= 8 else { return nil }
        return (4...(bytes.count - 4)).first { bytes[$0..<$0 + 4].elementsEqual(code) }.map { $0 - 4 }
    }

    private static func value(_ bytes: [UInt8], _ at: Int, _ count: Int) -> Int {
        bytes[at..<at + count].reduce(0) { $0 << 8 | Int($1) }
    }

    private static func bigEndian(_ value: Int, _ bytes: Int) -> [UInt8] {
        (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}
