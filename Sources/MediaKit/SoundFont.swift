import Foundation
import SuperConverterCore

/// A SoundFont 2 bank (RIFF `sfbk`, SoundFont 2.04 specification): presets → instruments → sample headers, with the
/// generators that place each sample on the keyboard, and the sample data (16-bit, plus the `sm24` low byte for 24-bit).
struct SoundFont {
    struct Sample {
        var name: String
        var start: Int, end: Int, loopStart: Int, loopEnd: Int
        var sampleRate: Int
        var originalPitch: Int
        var pitchCorrection: Int
        var link: Int
        var type: Int
        var frameCount: Int { max(end - start, 0) }
        /// ROM samples (type & 0x8000) have no data in the file.
        var isROM: Bool { type & 0x8000 != 0 }
    }

    /// A zone's generators by SF2 generator number (§8.1.2), as raw 16-bit amounts or ranges (lo | hi << 8).
    struct Zone {
        var generators: [Int: Int] = [:]
        var instrument: Int? { generators[41] }
        var sampleID: Int? { generators[53] }
        func range(_ op: Int) -> ClosedRange<Int>? {
            guard let raw = generators[op] else { return nil }
            let lo = raw & 0xFF, hi = (raw >> 8) & 0xFF
            return lo <= hi ? lo...hi : nil
        }
        func amount(_ op: Int) -> Int? { generators[op].map { Int(Int16(truncatingIfNeeded: $0)) } }
    }

    struct Instrument { var name: String; var global: Zone?; var zones: [Zone] }
    struct Preset { var name: String; var program: Int; var bank: Int; var global: Zone?; var zones: [Zone] }

    var name: String
    var samples: [Sample]
    var instruments: [Instrument]
    var presets: [Preset]
    /// 16-bit sample data and the optional low bytes (`sm24`).
    var smpl: Data
    var sm24: Data?

    var bitDepth: Int { sm24 == nil ? 16 : 24 }

    /// The most SFZ regions (preset zone × instrument zone pairs) a bank may describe.
    static let maxRegions = 1_000_000

    // MARK: Parsing

    static func read(_ data: Data) throws -> SoundFont {
        var r = Reader(data)
        guard r.fourCC() == "RIFF" else { throw ConversionError.damaged("sf2") }
        _ = r.u32()
        guard r.fourCC() == "sfbk" else { throw ConversionError.damaged("sf2") }
        var info: [String: String] = [:]
        var smpl = Data(), sm24: Data?
        var pdta: [String: Data] = [:]
        while r.remaining >= 8 {
            let id = r.fourCC(), size = Int(r.u32())
            guard size <= r.remaining else { throw ConversionError.damaged("sf2") }
            let body = r.bytes(size)
            if size % 2 == 1 && r.remaining > 0 { _ = r.bytes(1) }
            guard id == "LIST" else { continue }
            var list = Reader(body)
            let kind = list.fourCC()
            while list.remaining >= 8 {
                let sub = list.fourCC(), n = Int(list.u32())
                guard n <= list.remaining else { throw ConversionError.damaged("sf2") }
                let chunk = list.bytes(n)
                if n % 2 == 1 && list.remaining > 0 { _ = list.bytes(1) }
                switch kind {
                case "INFO": info[sub] = String(decoding: chunk.prefix { $0 != 0 }, as: UTF8.self)
                case "sdta": if sub == "smpl" { smpl = chunk } else if sub == "sm24" { sm24 = chunk }
                case "pdta": pdta[sub] = chunk
                default: break
                }
            }
        }
        guard let phdr = pdta["phdr"], let pbag = pdta["pbag"], let pgen = pdta["pgen"], let inst = pdta["inst"],
              let ibag = pdta["ibag"], let igen = pdta["igen"], let shdr = pdta["shdr"] else { throw ConversionError.damaged("sf2") }

        func generators(_ data: Data) -> [(Int, Int)] {
            var g = Reader(data), out: [(Int, Int)] = []
            while g.remaining >= 4 { out.append((Int(g.u16()), Int(g.u16()))) }
            return out
        }
        func bags(_ data: Data) -> [Int] {
            var b = Reader(data), out: [Int] = []
            while b.remaining >= 4 { out.append(Int(b.u16())); _ = b.u16() }
            return out
        }
        let pgens = generators(pgen), igens = generators(igen)
        let pbags = bags(pbag), ibags = bags(ibag)
        func zones(bags: [Int], gens: [(Int, Int)], from: Int, to: Int, terminal: Int) -> (Zone?, [Zone]) {
            var global: Zone?, list: [Zone] = []
            guard from <= to, to < bags.count else { return (nil, []) }
            for z in from..<to {
                var zone = Zone()
                // A damaged bag list can run backwards or past the generators: such a zone has none.
                let first = bags[z], end = min(bags[z + 1], gens.count)
                if first < end { for g in first..<end { zone.generators[gens[g].0] = gens[g].1 } }
                if zone.generators[terminal] == nil {
                    if z == from { global = zone }   // a first zone without its terminal generator is the global zone
                } else { list.append(zone) }
            }
            return (global, list)
        }

        var instruments: [Instrument] = []
        var ir = Reader(inst)
        var instRecords: [(String, Int)] = []
        while ir.remaining >= 22 { instRecords.append((ir.name(), Int(ir.u16()))) }
        for i in 0..<max(instRecords.count - 1, 0) {
            let (g, z) = zones(bags: ibags, gens: igens, from: instRecords[i].1, to: instRecords[i + 1].1, terminal: 53)
            instruments.append(Instrument(name: instRecords[i].0, global: g, zones: z))
        }
        var presets: [Preset] = []
        var pr = Reader(phdr)
        var presetRecords: [(String, Int, Int, Int)] = []
        while pr.remaining >= 38 {
            let name = pr.name(), program = Int(pr.u16()), bank = Int(pr.u16()), bag = Int(pr.u16())
            _ = pr.bytes(12)
            presetRecords.append((name, program, bank, bag))
        }
        for i in 0..<max(presetRecords.count - 1, 0) {
            let rec = presetRecords[i]
            let (g, z) = zones(bags: pbags, gens: pgens, from: rec.3, to: presetRecords[i + 1].3, terminal: 41)
            presets.append(Preset(name: rec.0, program: rec.1, bank: rec.2, global: g, zones: z))
        }
        var samples: [Sample] = []
        var sr = Reader(shdr)
        while sr.remaining >= 46 {
            let name = sr.name()
            let start = Int(sr.u32()), end = Int(sr.u32()), ls = Int(sr.u32()), le = Int(sr.u32()), rate = Int(sr.u32())
            let pitch = Int(sr.u8()), corr = Int(Int8(bitPattern: sr.u8())), link = Int(sr.u16()), type = Int(sr.u16())
            samples.append(Sample(name: name, start: start, end: end, loopStart: ls, loopEnd: le, sampleRate: rate,
                                  originalPitch: pitch, pitchCorrection: corr, link: link, type: type))
        }
        if !samples.isEmpty { samples.removeLast() }   // the terminal "EOS" record
        // Each preset zone × instrument zone becomes an SFZ region. Banks have thousands; a damaged one whose zones all point
        // at the same huge instrument would ask for billions of lines of text.
        let regions = presets.reduce(0) { total, preset in
            preset.zones.reduce(total) { sum, zone in
                sum + (zone.instrument.flatMap { instruments.indices.contains($0) ? instruments[$0].zones.count : nil } ?? 0)
            }
        }
        guard regions <= maxRegions else { throw ConversionError.damaged("sf2") }
        return SoundFont(name: info["INAM"] ?? "SoundFont", samples: samples, instruments: instruments, presets: presets,
                         smpl: smpl, sm24: sm24)
    }

    /// The sample's frames as little-endian PCM of `bitDepth` bits.
    func pcm(of sample: Sample) -> Data {
        let n = sample.frameCount
        guard n > 0, (sample.start + n) * 2 <= smpl.count else { return Data() }
        if let sm24, sample.start + n <= sm24.count {
            var out = Data(capacity: n * 3)
            for i in 0..<n {
                let o = smpl.startIndex + (sample.start + i) * 2
                out.append(sm24[sm24.startIndex + sample.start + i]); out.append(smpl[o]); out.append(smpl[o + 1])
            }
            return out
        }
        let o = smpl.startIndex + sample.start * 2
        return smpl.subdata(in: o..<(o + n * 2))
    }

    /// Little-endian byte reader over RIFF data.
    struct Reader {
        let data: Data
        var offset = 0
        init(_ data: Data) { self.data = data }
        var remaining: Int { data.count - offset }
        mutating func bytes(_ n: Int) -> Data {
            let n = min(n, remaining)
            defer { offset += n }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
        }
        mutating func u8() -> UInt8 { bytes(1).first ?? 0 }
        mutating func u16() -> UInt16 { let b = bytes(2); return b.count == 2 ? UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8 : 0 }
        mutating func u32() -> UInt32 { UInt32(u16()) | UInt32(u16()) << 16 }
        mutating func fourCC() -> String { String(decoding: bytes(4), as: UTF8.self) }
        mutating func name() -> String {
            String(decoding: bytes(20).prefix { $0 != 0 }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }
}
