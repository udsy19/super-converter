import AVFoundation
import Foundation

/// Audio metrics: THD+N of a test tone (quality §5.3 "Resampling": 1 kHz sine, <= -100 dB).
enum AudioMetrics {
    struct Signal {
        var sampleRate: Double
        var samples: [Double]
    }

    /// Decodes the first channel of any file AVFoundation reads to Double samples in -1…1.
    static func read(_ url: URL) -> Signal? {
        guard let file = try? AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData else { return nil }
        return Signal(sampleRate: file.processingFormat.sampleRate, samples: (0..<Int(buffer.frameLength)).map { Double(data[0][$0]) })
    }

    /// THD+N in dB: the RMS of everything that is not the fundamental (harmonics, noise, DC) relative to the RMS of the
    /// fundamental. The fundamental at `frequency` is removed by a least-squares fit of a sine and cosine plus an offset over
    /// the whole signal, so the result is exact for any frequency and length (no window, no leakage, no integer-cycle rule).
    /// Full band: nothing above 20 kHz is filtered out.
    static func thdPlusN(_ signal: Signal, frequency: Double) -> Double? {
        let n = signal.samples.count
        guard n > 16, frequency > 0, frequency < signal.sampleRate / 2 else { return nil }
        let w = 2 * Double.pi * frequency / signal.sampleRate
        var ss = 0.0, cc = 0.0, sc = 0.0, s1 = 0.0, c1 = 0.0
        var ys = 0.0, yc = 0.0, y1 = 0.0
        for i in 0..<n {
            let s = sin(w * Double(i)), c = cos(w * Double(i)), y = signal.samples[i]
            ss += s * s; cc += c * c; sc += s * c; s1 += s; c1 += c
            ys += y * s; yc += y * c; y1 += y
        }
        // Normal equations for [a, b, d] in y ~ a sin + b cos + d.
        let m: [[Double]] = [[ss, sc, s1], [sc, cc, c1], [s1, c1, Double(n)]]
        guard let x = solve3(m, [ys, yc, y1]) else { return nil }
        var residual = 0.0
        for i in 0..<n {
            let fit = x[0] * sin(w * Double(i)) + x[1] * cos(w * Double(i)) + x[2]
            let e = signal.samples[i] - fit
            residual += e * e
        }
        let noise = (residual / Double(n)).squareRoot()
        let fundamental = ((x[0] * x[0] + x[1] * x[1]) / 2).squareRoot()
        guard fundamental > 0 else { return nil }
        return 20 * log10(max(noise / fundamental, 1e-12))
    }

    private static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a, v = b
        for col in 0..<3 {
            guard let pivot = (col..<3).max(by: { abs(m[$0][col]) < abs(m[$1][col]) }), abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot); v.swapAt(col, pivot)
            for row in (col + 1)..<3 {
                let f = m[row][col] / m[col][col]
                for k in col..<3 { m[row][k] -= f * m[col][k] }
                v[row] -= f * v[col]
            }
        }
        var x = [Double](repeating: 0, count: 3)
        for row in stride(from: 2, through: 0, by: -1) {
            var s = v[row]
            for k in (row + 1)..<3 { s -= m[row][k] * x[k] }
            x[row] = s / m[row][row]
        }
        return x
    }

    /// A sine of `amplitude` (peak, 0…1) at `frequency`, quantised to `bits` the way a PCM file stores it (round to nearest
    /// level; nil bits keeps full precision).
    static func sine(frequency: Double, sampleRate: Double, seconds: Double, amplitude: Double = 1, bits: Int? = nil, harmonics: [Int: Double] = [:]) -> Signal {
        let count = Int(sampleRate * seconds)
        let scale = bits.map { Double((1 << ($0 - 1)) - 1) }
        let samples = (0..<count).map { i -> Double in
            let t = 2 * Double.pi * frequency * Double(i) / sampleRate
            var v = amplitude * sin(t)
            for (order, level) in harmonics { v += amplitude * level * sin(Double(order) * t) }
            if let scale { v = (v * scale).rounded() / scale }
            return v
        }
        return Signal(sampleRate: sampleRate, samples: samples)
    }

    /// Writes mono or stereo 16-bit PCM WAV (the same signal on every channel).
    static func writeWAV(_ signal: Signal, channels: Int = 1, to url: URL) throws {
        var data = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = signal.samples.count * channels * 2
        data.append("RIFF".data(using: .ascii)!); put32(UInt32(36 + bytes)); data.append("WAVEfmt ".data(using: .ascii)!)
        put32(16); put16(1); put16(UInt16(channels)); put32(UInt32(signal.sampleRate)); put32(UInt32(signal.sampleRate) * UInt32(channels) * 2)
        put16(UInt16(channels * 2)); put16(16)
        data.append("data".data(using: .ascii)!); put32(UInt32(bytes))
        for s in signal.samples {
            let v = Int16(max(-32768, min(32767, (s * 32767).rounded())))
            for _ in 0..<channels { put16(UInt16(bitPattern: v)) }
        }
        try data.write(to: url)
    }
}
