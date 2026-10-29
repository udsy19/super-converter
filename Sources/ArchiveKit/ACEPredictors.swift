// Adapted from acefile acefile.py, Sound and Pic (BSD-2-Clause, Copyright (C) 2017-2026 Daniel Roethlisberger; the licence
// text is in ACEKit.swift). Changes: Swift; Python's negative list indices become explicit wrap-arounds; picture size and
// Golomb-Rice parameters are capped so hostile input cannot ask for huge buffers.

/// ACE 2.0 SOUND modes: a multi-channel audio predictor over Huffman coding.
final class ACESound {
    private static let runLenCodes = 32
    private static let typeCode = 256 + runLenCodes
    private static let numCodes = 256 + runLenCodes + 1
    private static let maxCodeWidth = 10
    private static let channelCounts = [1, 2, 3, 3]
    private static let useChannels = [[0, 0, 0, 0], [0, 1, 0, 1], [0, 1, 0, 2], [1, 0, 2, 0]]

    /// Bit length of |i| for the signed sample differences (index taken modulo 256).
    private static let quantizer: [Int] = {
        var q = [Int](repeating: 0, count: 256)
        for i in 1...128 {
            let width = Int.bitWidth - i.leadingZeroBitCount
            q[i] = width
            q[256 - i] = width
        }
        return q
    }()

    private final class SymbolReader {
        var trees: [ACEHuffman.Tree?]
        var left = 0

        init(models: Int) { trees = [ACEHuffman.Tree?](repeating: nil, count: models) }

        func read(_ bs: ACEBitStream, model: Int) throws -> Int {
            if left == 0 {
                for i in trees.indices {
                    trees[i] = try ACEHuffman.readTree(bs, maxWidth: ACESound.maxCodeWidth, numCodes: ACESound.numCodes)
                }
                left = try bs.read(15)
            }
            left -= 1
            guard let tree = trees[model] else { throw ArchiveError.damaged("A SOUND block has no tree.") }
            return try tree.readSymbol(bs)
        }
    }

    private enum Sample { case value(Int), mode(ACEMode) }

    private final class Channel {
        let reader: SymbolReader
        let modelBase: Int
        var predDifCount = [0, 0]
        var lastPredDifCount = [0, 0]
        var rarDifCount = [0, 0, 0, 0]
        var rarCoeff = [0, 0, 0, 0]
        var rarDif = [Int](repeating: 0, count: 9)
        var byteCount = 0
        var lastSample = 0
        var lastDelta = 0
        var adaptCount = 0
        var adaptUse = 0
        var state = 0
        var code = 0

        init(reader: SymbolReader, index: Int) { self.reader = reader; modelBase = 3 * index }

        private func readSymbol(_ bs: ACEBitStream) throws -> Int {
            var model = state << 1
            if model == 0 { model += adaptUse }
            return try reader.read(bs, model: model + modelBase)
        }

        func get(_ bs: ACEBitStream) throws -> Sample {
            if state != 2 {
                code = try readSymbol(bs)
                if code == ACESound.typeCode { return .mode(try ACEMode.read(bs)) }
            }
            var value = 0
            if state == 0 {
                if code >= ACESound.runLenCodes {
                    value = code - ACESound.runLenCodes
                    adaptCount = ((adaptCount * 7) >> 3) + value
                    adaptUse = adaptCount > 40 ? 1 : 0
                } else {
                    state = 2
                }
            } else if state == 1 {
                value = code
                state = 0
            }
            if state == 2 {
                if code == 0 { state = 1 } else { code -= 1 }
                value = 0
            }
            return .value(value & 1 != 0 ? 255 - (value >> 1) : value >> 1)
        }

        func predict() -> Int {
            predDifCount[0] > predDifCount[1] ? lastSample : predictedSample()
        }

        private func predictedSample() -> Int {
            var sum = 8 * lastSample
            for i in 0..<4 { sum += rarCoeff[i] * rarDifCount[i] }
            return (sum >> 3) & 0xFF
        }

        private static func schar(_ v: Int) -> Int { Int(Int8(truncatingIfNeeded: v)) }

        func adjust(_ sample: Int) {
            byteCount += 1
            let predSample = predictedSample()
            let predDif = Channel.schar(predSample - sample) << 3
            rarDif[0] += abs(predDif - rarDifCount[0])
            rarDif[1] += abs(predDif + rarDifCount[0])
            rarDif[2] += abs(predDif - rarDifCount[1])
            rarDif[3] += abs(predDif + rarDifCount[1])
            rarDif[4] += abs(predDif - rarDifCount[2])
            rarDif[5] += abs(predDif + rarDifCount[2])
            rarDif[6] += abs(predDif - rarDifCount[3])
            rarDif[7] += abs(predDif + rarDifCount[3])
            rarDif[8] += abs(predDif)

            lastDelta = Channel.schar(sample - lastSample)
            predDifCount[0] += ACESound.quantizer[(predDif >> 3) & 255]
            predDifCount[1] += ACESound.quantizer[(lastSample - sample) & 255]
            lastSample = sample

            if byteCount & 0x1F == 0 {
                var minDif = 0xFFFF
                var minPos = 8
                for i in stride(from: 8, through: 0, by: -1) {
                    if rarDif[i] <= minDif { minDif = rarDif[i]; minPos = i }
                    rarDif[i] = 0
                }
                if minPos != 8 {
                    let i = minPos >> 1
                    if minPos & 1 == 0 {
                        if rarCoeff[i] >= -16 { rarCoeff[i] -= 1 }
                    } else if rarCoeff[i] <= 16 {
                        rarCoeff[i] += 1
                    }
                }
                if byteCount & 0xFF == 0 {
                    for i in 0..<2 {
                        predDifCount[i] -= lastPredDifCount[i]
                        lastPredDifCount[i] = predDifCount[i]
                    }
                }
            }
            rarDifCount[3] = rarDifCount[2]
            rarDifCount[2] = rarDifCount[1]
            rarDifCount[1] = lastDelta - rarDifCount[0]
            rarDifCount[0] = lastDelta
        }
    }

    private var mode = 0
    private var channels: [Channel] = []

    /// Starts afresh for a SOUND mode (`ACEMode.sound8` ... `sound32b`).
    func reinit(mode newMode: Int) {
        mode = newMode - ACEMode.sound8
        let count = ACESound.channelCounts[mode]
        let reader = SymbolReader(models: count * 3)
        channels = (0..<count).map { Channel(reader: reader, index: $0) }
    }

    /// Decodes `count` bytes (a multiple of 4) or up to a mode instruction.
    func read(_ bs: ACEBitStream, count: Int) throws -> (chunk: [UInt8], mode: ACEMode?) {
        var chunk: [UInt8] = []
        chunk.reserveCapacity(count)
        for i in 0..<count {
            let channel = channels[ACESound.useChannels[mode][i % 4]]
            switch try channel.get(bs) {
            case .mode(let next): return (chunk, next)
            case .value(let v):
                let sample = (v + channel.predict()) & 0xFF
                chunk.append(UInt8(sample))
                channel.adjust(Int(Int8(truncatingIfNeeded: sample)))
            }
        }
        return (chunk, nil)
    }
}

/// ACE 2.0 PIC mode: a two-dimensional pixel predictor over Golomb-Rice coding.
final class ACEPic {
    private static let contexts = 365
    private static let maxWidth = 1 << 24
    private static let maxPlanes = 255

    private struct ErrContext {
        var used = 0
        var predictor = 0
        var average = 4
        var errors = SIMD4<Int>(repeating: 0)
    }

    /// Bit width of the prediction error, indexed by the error modulo 256.
    private static let difBitWidth: [Int] = (0..<256).map { i in
        let magnitude = i < 128 ? 2 * i : -2 * (i - 256) - 1
        return Int.bitWidth - magnitude.leadingZeroBitCount
    }

    private static let quantizer: [Int] = {
        var q: [Int] = []
        q += repeatElement(-4, count: 235)
        q += repeatElement(-3, count: 14)
        q += repeatElement(-2, count: 4)
        q += repeatElement(-1, count: 2)
        q.append(0)
        q += repeatElement(1, count: 2)
        q += repeatElement(2, count: 4)
        q += repeatElement(3, count: 14)
        q += repeatElement(4, count: 235)
        return q
    }()

    /// The pixel decoder of one plane in one row. Kind 0 codes pixels as they are; kinds 1 and 2 code the difference to the
    /// previous plane (kind 2 with that plane scaled by 11/16).
    private struct PixelDecoder {
        let kind: Int
        var a: Int, b: Int, c: Int, x: Int
        var d = 0

        init(kind: Int) {
            self.kind = kind
            let start = kind == 0 ? 0 : 128
            a = start; b = start; c = start; x = start
        }

        mutating func shift() { c = a; a = d; b = x }

        mutating func updateD(this: Int, reference: Int) {
            switch kind {
            case 0: d = this
            case 1: d = (128 + this - reference) & 0xFF
            default: d = (128 + this - ((reference * 11) >> 4)) & 0xFF
            }
        }

        func context() -> Int {
            abs(81 * ACEPic.quantizer[255 + d - a] + 9 * ACEPic.quantizer[255 + a - c] + ACEPic.quantizer[255 + c - b])
        }

        func predict(_ predictor: Int) -> Int {
            switch predictor {
            case 0: return a
            case 1: return b
            case 2: return (a + b) >> 1
            default: return (a + b - c) & 0xFF
            }
        }

        mutating func update(_ bs: ACEBitStream, _ context: inout ErrContext) throws {
            context.used += 1
            let r = context.average / context.used
            let epsilon = try bs.readGolombRice(Int.bitWidth - r.leadingZeroBitCount, signed: true)
            x = (predict(context.predictor) + epsilon) & 0xFF

            context.average += abs(epsilon)
            if context.used == 128 {
                context.used >>= 1
                context.average >>= 1
            }
            var best = 0
            for i in 0..<4 {
                context.errors[i] += ACEPic.difBitWidth[(x - predict(i)) & 255]
                if i == 0 || context.errors[i] < context.errors[best] { best = i }
            }
            context.predictor = best
            if context.errors.max() > 0x7F { context.errors &>>= 1 }
        }

        func produce(reference: Int) -> Int {
            switch kind {
            case 0: return x
            case 1: return (x + reference - 128) & 0xFF
            default: return (x + ((reference * 11) >> 4) - 128) & 0xFF
            }
        }
    }

    private var width = 0
    private var planes = 0
    private var model0 = [ErrContext](repeating: ErrContext(), count: ACEPic.contexts)
    private var modelN = [ErrContext](repeating: ErrContext(), count: ACEPic.contexts)
    private var previous: [UInt8] = []
    private var leftover: [UInt8] = []

    /// Reads width and plane count and starts afresh.
    func reinit(_ bs: ACEBitStream) throws {
        width = try bs.readGolombRice(12)
        planes = try bs.readGolombRice(2)
        guard width <= ACEPic.maxWidth, planes <= ACEPic.maxPlanes else { throw ArchiveError.damaged("A PIC block is larger than any picture.") }
        model0 = [ErrContext](repeating: ErrContext(), count: ACEPic.contexts)
        modelN = model0
        previous = []
        leftover = []
    }

    private static func at(_ array: [UInt8], _ i: Int) -> Int { Int(i >= 0 ? array[i] : array[array.count + i]) }

    private func row(_ bs: ACEBitStream) throws -> [UInt8] {
        if previous.isEmpty { previous = [UInt8](repeating: 0, count: width + planes) }
        var row = [UInt8](repeating: 0, count: width + planes)
        for plane in 0..<planes {
            var decoder: PixelDecoder
            if plane == 0 {
                decoder = PixelDecoder(kind: 0)
            } else {
                let kind = try bs.read(2)
                guard kind <= 2 else { throw ArchiveError.damaged("A PIC block names an unknown pixel decoder.") }
                decoder = PixelDecoder(kind: kind)
            }
            decoder.updateD(this: Int(previous[plane]), reference: ACEPic.at(previous, plane - 1))
            for col in stride(from: plane, to: width, by: planes) {
                decoder.shift()
                decoder.updateD(this: Int(previous[col + planes]), reference: Int(previous[col + planes - 1]))
                let index = decoder.context()
                if plane == 0 {
                    try decoder.update(bs, &model0[index])
                } else {
                    try decoder.update(bs, &modelN[index])
                }
                row[col] = UInt8(decoder.produce(reference: ACEPic.at(row, col - 1)))
            }
        }
        previous = row
        return row
    }

    /// Decodes whole rows until `count` bytes are available or a mode instruction is read; a row cut short keeps its rest.
    func read(_ bs: ACEBitStream, count: Int) throws -> (chunk: [UInt8], mode: ACEMode?) {
        var chunk = leftover
        leftover = []
        while chunk.count < count {
            if try bs.read(1) == 0 { return (chunk, try ACEMode.read(bs)) }
            let data = try row(bs).prefix(width)
            let n = min(count - chunk.count, data.count)
            chunk.append(contentsOf: data.prefix(n))
            leftover = Array(data.dropFirst(n))
        }
        return (chunk, nil)
    }
}
