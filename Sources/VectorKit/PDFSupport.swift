import CoreGraphics
import Foundation
import SuperConverterCore

// Thin Swift access to the CGPDF object model, PDF functions and colour spaces for the PDF reader.

enum PDFObj {
    static func name(_ d: CGPDFDictionaryRef, _ key: String) -> String? {
        var p: UnsafePointer<Int8>?
        return CGPDFDictionaryGetName(d, key, &p) ? p.map { String(cString: $0) } : nil
    }
    static func number(_ d: CGPDFDictionaryRef, _ key: String) -> Double? {
        var v: CGPDFReal = 0
        return CGPDFDictionaryGetNumber(d, key, &v) ? Double(v) : nil
    }
    static func int(_ d: CGPDFDictionaryRef, _ key: String) -> Int? {
        var v: CGPDFInteger = 0
        if CGPDFDictionaryGetInteger(d, key, &v) { return Int(v) }
        return number(d, key).map { Int($0) }
    }
    static func bool(_ d: CGPDFDictionaryRef, _ key: String) -> Bool? {
        var v: CGPDFBoolean = 0
        return CGPDFDictionaryGetBoolean(d, key, &v) ? v != 0 : nil
    }
    static func dict(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var v: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(d, key, &v) ? v : nil
    }
    static func array(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var v: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(d, key, &v) ? v : nil
    }
    static func stream(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFStreamRef? {
        var v: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(d, key, &v) ? v : nil
    }
    static func object(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
        var v: CGPDFObjectRef?
        return CGPDFDictionaryGetObject(d, key, &v) ? v : nil
    }
    static func string(_ d: CGPDFDictionaryRef, _ key: String) -> Data? {
        var v: CGPDFStringRef?
        guard CGPDFDictionaryGetString(d, key, &v), let v, let ptr = CGPDFStringGetBytePtr(v) else { return nil }
        return Data(bytes: ptr, count: CGPDFStringGetLength(v))
    }

    static func numbers(_ a: CGPDFArrayRef) -> [Double] {
        (0..<CGPDFArrayGetCount(a)).compactMap { i in
            var v: CGPDFReal = 0
            return CGPDFArrayGetNumber(a, i, &v) ? Double(v) : nil
        }
    }
    static func numbers(_ d: CGPDFDictionaryRef, _ key: String) -> [Double]? { array(d, key).map(numbers) }

    static func streamDictionary(_ s: CGPDFStreamRef) -> CGPDFDictionaryRef? { CGPDFStreamGetDictionary(s) }

    /// Decoded stream bytes and whether they are still image-encoded (DCT/JPX).
    static func data(_ s: CGPDFStreamRef) -> (Data, CGPDFDataFormat)? {
        var format = CGPDFDataFormat.raw
        guard let cf = CGPDFStreamCopyData(s, &format) else { return nil }
        return (cf as Data, format)
    }

    static func nameElement(_ a: CGPDFArrayRef, _ i: Int) -> String? {
        var p: UnsafePointer<Int8>?
        return CGPDFArrayGetName(a, i, &p) ? p.map { String(cString: $0) } : nil
    }
    static func numberElement(_ a: CGPDFArrayRef, _ i: Int) -> Double? {
        var v: CGPDFReal = 0
        return CGPDFArrayGetNumber(a, i, &v) ? Double(v) : nil
    }
    static func dictElement(_ a: CGPDFArrayRef, _ i: Int) -> CGPDFDictionaryRef? {
        var v: CGPDFDictionaryRef?
        return CGPDFArrayGetDictionary(a, i, &v) ? v : nil
    }
    static func streamElement(_ a: CGPDFArrayRef, _ i: Int) -> CGPDFStreamRef? {
        var v: CGPDFStreamRef?
        return CGPDFArrayGetStream(a, i, &v) ? v : nil
    }
    static func arrayElement(_ a: CGPDFArrayRef, _ i: Int) -> CGPDFArrayRef? {
        var v: CGPDFArrayRef?
        return CGPDFArrayGetArray(a, i, &v) ? v : nil
    }
    static func objectElement(_ a: CGPDFArrayRef, _ i: Int) -> CGPDFObjectRef? {
        var v: CGPDFObjectRef?
        return CGPDFArrayGetObject(a, i, &v) ? v : nil
    }
    static func stringElement(_ a: CGPDFArrayRef, _ i: Int) -> Data? {
        var v: CGPDFStringRef?
        guard CGPDFArrayGetString(a, i, &v), let v, let ptr = CGPDFStringGetBytePtr(v) else { return nil }
        return Data(bytes: ptr, count: CGPDFStringGetLength(v))
    }

    /// The object's type and value as the narrow views the readers need.
    static func asName(_ o: CGPDFObjectRef) -> String? {
        var p: UnsafePointer<Int8>?
        return CGPDFObjectGetValue(o, .name, &p) ? p.map { String(cString: $0) } : nil
    }
    static func asArray(_ o: CGPDFObjectRef) -> CGPDFArrayRef? { var v: CGPDFArrayRef?; return CGPDFObjectGetValue(o, .array, &v) ? v : nil }
    static func asDict(_ o: CGPDFObjectRef) -> CGPDFDictionaryRef? { var v: CGPDFDictionaryRef?; return CGPDFObjectGetValue(o, .dictionary, &v) ? v : nil }
    static func asStream(_ o: CGPDFObjectRef) -> CGPDFStreamRef? { var v: CGPDFStreamRef?; return CGPDFObjectGetValue(o, .stream, &v) ? v : nil }
}

// MARK: Functions

/// PDF function types 0, 2, 3 and 4.
indirect enum PDFFunction {
    case sampled(domain: [Double], range: [Double], size: [Int], encode: [Double], decode: [Double], samples: [Double], outputs: Int)
    case exponential(domain: [Double], c0: [Double], c1: [Double], n: Double)
    case stitching(domain: [Double], functions: [PDFFunction], bounds: [Double], encode: [Double])
    case calculator(domain: [Double], range: [Double], program: [PSToken])
    case array([PDFFunction])

    static func parse(_ object: CGPDFObjectRef) -> PDFFunction? {
        if let a = PDFObj.asArray(object) {
            let fns = (0..<CGPDFArrayGetCount(a)).compactMap { i in PDFObj.objectElement(a, i).flatMap(parse) }
            return fns.isEmpty ? nil : .array(fns)
        }
        var dict: CGPDFDictionaryRef?
        var stream: CGPDFStreamRef?
        if let s = PDFObj.asStream(object) { stream = s; dict = PDFObj.streamDictionary(s) } else { dict = PDFObj.asDict(object) }
        guard let d = dict, let type = PDFObj.int(d, "FunctionType") else { return nil }
        let domain = PDFObj.numbers(d, "Domain") ?? [0, 1]
        let range = PDFObj.numbers(d, "Range") ?? []
        switch type {
        case 0:
            guard let stream, let loaded = PDFObj.data(stream), let sizeNumbers: [Double] = PDFObj.numbers(d, "Size"), let bps = PDFObj.int(d, "BitsPerSample"),
                  !range.isEmpty else { return nil }
            let bytes = loaded.0
            let sizes = sizeNumbers.map { Int($0) }
            let m = domain.count / 2, n = range.count / 2
            let defaultEncode: [Double] = sizes.flatMap { (s: Int) -> [Double] in [0, Double(s - 1)] }
            let encode: [Double] = PDFObj.numbers(d, "Encode") ?? defaultEncode
            let decode = PDFObj.numbers(d, "Decode") ?? range
            let total = sizes.reduce(1, *) * n
            guard total > 0, total < 4_000_000, m == sizes.count else { return nil }
            var samples = [Double](repeating: 0, count: total)
            let maxValue = Double((1 << bps) - 1)
            var bitPos = 0
            for i in 0..<total {
                var v: UInt64 = 0
                for _ in 0..<bps {
                    let byte = bitPos >> 3
                    guard byte < bytes.count else { break }
                    v = (v << 1) | UInt64((bytes[bytes.startIndex + byte] >> (7 - UInt8(bitPos & 7))) & 1)
                    bitPos += 1
                }
                samples[i] = Double(v) / maxValue
            }
            return .sampled(domain: domain, range: range, size: sizes, encode: encode, decode: decode, samples: samples, outputs: n)
        case 2:
            return .exponential(domain: domain, c0: PDFObj.numbers(d, "C0") ?? [0], c1: PDFObj.numbers(d, "C1") ?? [1], n: PDFObj.number(d, "N") ?? 1)
        case 3:
            guard let fa = PDFObj.array(d, "Functions") else { return nil }
            let fns = (0..<CGPDFArrayGetCount(fa)).compactMap { i in PDFObj.objectElement(fa, i).flatMap(parse) }
            guard fns.count == CGPDFArrayGetCount(fa), !fns.isEmpty else { return nil }
            let defaultEncode: [Double] = fns.flatMap { _ -> [Double] in [0.0, 1.0] }
            return .stitching(domain: domain, functions: fns, bounds: PDFObj.numbers(d, "Bounds") ?? [], encode: PDFObj.numbers(d, "Encode") ?? defaultEncode)
        case 4:
            guard let stream, let loaded = PDFObj.data(stream) else { return nil }
            guard let program = PSToken.parse(String(decoding: loaded.0, as: UTF8.self)) else { return nil }
            return .calculator(domain: domain, range: range, program: program)
        default: return nil
        }
    }

    func eval(_ input: [Double]) -> [Double] {
        switch self {
        case .exponential(let domain, let c0, let c1, let n):
            let x = clamp(input.first ?? 0, domain[0], domain[1])
            let t = n == 1 ? x : pow(x, n)
            return (0..<c0.count).map { c0[$0] + t * ((c1.indices.contains($0) ? c1[$0] : c0[$0]) - c0[$0]) }
        case .stitching(let domain, let fns, let bounds, let encode):
            let x = clamp(input.first ?? 0, domain[0], domain[1])
            var k = 0
            while k < bounds.count, x >= bounds[k] { k += 1 }
            k = min(k, fns.count - 1)
            let lo = k == 0 ? domain[0] : bounds[k - 1], hi = k < bounds.count ? bounds[k] : domain[1]
            let e0 = encode[2 * k], e1 = encode[2 * k + 1]
            let mapped = hi == lo ? e0 : e0 + (x - lo) / (hi - lo) * (e1 - e0)
            return fns[k].eval([mapped])
        case .array(let fns):
            return fns.flatMap { $0.eval(input) }
        case .sampled(let domain, let range, let size, let encode, let decode, let samples, let n):
            // Linear interpolation along the first input; nearest on the others.
            let m = size.count
            var coords: [Double] = []
            for i in 0..<m {
                let x = clamp(i < input.count ? input[i] : 0, domain[2 * i], domain[2 * i + 1])
                let span = domain[2 * i + 1] - domain[2 * i]
                let e = span == 0 ? encode[2 * i] : encode[2 * i] + (x - domain[2 * i]) / span * (encode[2 * i + 1] - encode[2 * i])
                coords.append(clamp(e, 0, Double(size[i] - 1)))
            }
            func sample(_ idx: [Int], _ out: Int) -> Double {
                var offset = 0, stride = 1
                for i in 0..<m { offset += idx[i] * stride; stride *= size[i] }
                return samples[offset * n + out]
            }
            var result: [Double] = []
            for o in 0..<n {
                var idx = coords.map { Int($0.rounded()) }
                let f0 = Int(floor(coords[0])), f1 = min(f0 + 1, size[0] - 1), frac = coords[0] - Double(f0)
                idx[0] = f0; let a = sample(idx, o)
                idx[0] = f1; let b = sample(idx, o)
                let v = a + (b - a) * frac
                let lo = decode[2 * o], hi = decode[2 * o + 1]
                result.append(clamp(lo + v * (hi - lo), range[2 * o], range[2 * o + 1]))
            }
            return result
        case .calculator(let domain, let range, let program):
            var stack = input.enumerated().map { clamp($0.element, domain[2 * $0.offset], domain[2 * $0.offset + 1]) }
            PSToken.run(program, &stack)
            let n = range.count / 2
            var out = Array(stack.suffix(n))
            while out.count < n { out.insert(0, at: 0) }
            return out.enumerated().map { clamp($0.element, range[2 * $0.offset], range[2 * $0.offset + 1]) }
        }
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}

/// PostScript calculator tokens (function type 4).
indirect enum PSToken {
    case number(Double)
    case op(String)
    case block([PSToken])

    static func parse(_ text: String) -> [PSToken]? {
        var tokens: [String] = []
        var current = ""
        for ch in text {
            if ch == "{" || ch == "}" { if !current.isEmpty { tokens.append(current); current = "" }; tokens.append(String(ch)) }
            else if ch.isWhitespace { if !current.isEmpty { tokens.append(current); current = "" } }
            else { current.append(ch) }
        }
        if !current.isEmpty { tokens.append(current) }
        var i = 0
        func block() -> [PSToken]? {
            var out: [PSToken] = []
            while i < tokens.count {
                let t = tokens[i]; i += 1
                if t == "{" { guard let inner = block() else { return nil }; out.append(.block(inner)) }
                else if t == "}" { return out }
                else if let n = Double(t) { out.append(.number(n)) } else { out.append(.op(t)) }
            }
            return out
        }
        guard i < tokens.count, tokens[i] == "{" else { return nil }
        i += 1
        return block()
    }

    static func run(_ program: [PSToken], _ stack: inout [Double]) {
        var pc = 0
        func pop() -> Double { stack.popLast() ?? 0 }
        while pc < program.count {
            let token = program[pc]; pc += 1
            switch token {
            case .number(let n): stack.append(n)
            case .block:
                // A block is consumed by the `if` / `ifelse` that follows it.
                if pc < program.count, case .op("if") = program[pc], case .block(let body) = token {
                    pc += 1
                    if pop() != 0 { run(body, &stack) }
                } else if pc + 1 < program.count, case .block(let second) = program[pc], case .op("ifelse") = program[pc + 1], case .block(let first) = token {
                    pc += 2
                    if pop() != 0 { run(first, &stack) } else { run(second, &stack) }
                }
            case .op(let name):
                switch name {
                case "abs": stack.append(abs(pop()))
                case "add": let b = pop(), a = pop(); stack.append(a + b)
                case "sub": let b = pop(), a = pop(); stack.append(a - b)
                case "mul": let b = pop(), a = pop(); stack.append(a * b)
                case "div": let b = pop(), a = pop(); stack.append(b == 0 ? 0 : a / b)
                case "idiv": let b = Int(pop()), a = Int(pop()); stack.append(b == 0 ? 0 : Double(a / b))
                case "mod": let b = Int(pop()), a = Int(pop()); stack.append(b == 0 ? 0 : Double(a % b))
                case "neg": stack.append(-pop())
                case "atan": let d = pop(), n = pop(); var a = atan2(n, d) * 180 / .pi; if a < 0 { a += 360 }; stack.append(a)
                case "ceiling": stack.append(ceil(pop()))
                case "floor": stack.append(floor(pop()))
                case "round": stack.append((pop() + 0.5).rounded(.down))
                case "truncate", "cvi": stack.append(pop().rounded(.towardZero))
                case "cvr": break
                case "cos": stack.append(cos(pop() * .pi / 180))
                case "sin": stack.append(sin(pop() * .pi / 180))
                case "exp": let e = pop(), b = pop(); stack.append(pow(b, e))
                case "ln": stack.append(log(max(pop(), 1e-300)))
                case "log": stack.append(log10(max(pop(), 1e-300)))
                case "sqrt": stack.append(max(0, pop()).squareRoot())
                case "and": let b = Int(pop()), a = Int(pop()); stack.append(Double(a & b))
                case "or": let b = Int(pop()), a = Int(pop()); stack.append(Double(a | b))
                case "xor": let b = Int(pop()), a = Int(pop()); stack.append(Double(a ^ b))
                case "not": let a = pop(); stack.append(a == 0 ? 1 : (a == 1 ? 0 : Double(~Int(a))))
                case "bitshift": let s = Int(pop()), a = Int(pop()); stack.append(Double(s >= 0 ? a << min(s, 62) : a >> min(-s, 62)))
                case "eq": let b = pop(), a = pop(); stack.append(a == b ? 1 : 0)
                case "ne": let b = pop(), a = pop(); stack.append(a != b ? 1 : 0)
                case "gt": let b = pop(), a = pop(); stack.append(a > b ? 1 : 0)
                case "ge": let b = pop(), a = pop(); stack.append(a >= b ? 1 : 0)
                case "lt": let b = pop(), a = pop(); stack.append(a < b ? 1 : 0)
                case "le": let b = pop(), a = pop(); stack.append(a <= b ? 1 : 0)
                case "true": stack.append(1)
                case "false": stack.append(0)
                case "pop": _ = pop()
                case "dup": if let t = stack.last { stack.append(t) }
                case "exch": if stack.count >= 2 { stack.swapAt(stack.count - 1, stack.count - 2) }
                case "copy": let n = Int(pop()); if n > 0, n <= stack.count { stack.append(contentsOf: stack.suffix(n)) }
                case "index": let n = Int(pop()); if n >= 0, n < stack.count { stack.append(stack[stack.count - 1 - n]) }
                case "roll":
                    let j = Int(pop()), n = Int(pop())
                    if n > 0, n <= stack.count {
                        var top = Array(stack.suffix(n))
                        let k = ((j % n) + n) % n
                        top = Array(top.suffix(k) + top.prefix(n - k))
                        stack.removeLast(n); stack.append(contentsOf: top)
                    }
                default: break
                }
            }
        }
    }
}

// MARK: Colour spaces

final class PDFColourSpace {
    enum Kind {
        case gray, rgb, cmyk, lab(white: [Double], range: [Double])
        case icc(CGColorSpace, Int)
        indirect case indexed(base: PDFColourSpace, hival: Int, lookup: [UInt8])
        indirect case tint(alternate: PDFColourSpace, function: PDFFunction, count: Int)
        indirect case pattern(base: PDFColourSpace?)

        var patternBase: PDFColourSpace? { if case .pattern(let b) = self { b } else { nil } }
    }

    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }

    static let deviceGray = PDFColourSpace(.gray), deviceRGB = PDFColourSpace(.rgb), deviceCMYK = PDFColourSpace(.cmyk)

    var components: Int {
        switch kind {
        case .gray, .indexed: 1
        case .rgb, .lab: 3
        case .cmyk: 4
        case .icc(_, let n): n
        case .tint(_, _, let n): n
        case .pattern(let base): base?.components ?? 0
        }
    }

    var isPattern: Bool { if case .pattern = kind { true } else { false } }

    var initial: [Double] {
        switch kind {
        case .cmyk: [0, 0, 0, 1]
        case .tint(_, _, let n): [Double](repeating: 1, count: n)
        case .icc(_, let n) where n == 4: [0, 0, 0, 1]
        default: [Double](repeating: 0, count: max(components, 1))
        }
    }

    static func named(_ name: String, lookup: (String) -> CGPDFObjectRef?) -> PDFColourSpace? {
        switch name {
        case "DeviceGray", "G", "CalGray": return deviceGray
        case "DeviceRGB", "RGB", "CalRGB": return deviceRGB
        case "DeviceCMYK", "CMYK": return deviceCMYK
        case "Pattern": return PDFColourSpace(.pattern(base: nil))
        default:
            guard let obj = lookup(name) else { return nil }
            return parse(obj, lookup: lookup)
        }
    }

    static func parse(_ object: CGPDFObjectRef, lookup: (String) -> CGPDFObjectRef?, depth: Int = 0) -> PDFColourSpace? {
        guard depth < 6 else { return nil }
        if let name = PDFObj.asName(object) { return named(name, lookup: depth == 0 ? lookup : { _ in nil }) }
        guard let array = PDFObj.asArray(object), CGPDFArrayGetCount(array) > 0, let family = PDFObj.nameElement(array, 0) else { return nil }
        func baseSpace(_ i: Int) -> PDFColourSpace? { PDFObj.objectElement(array, i).flatMap { parse($0, lookup: lookup, depth: depth + 1) } }
        switch family {
        case "DeviceGray", "G", "CalGray": return deviceGray
        case "DeviceRGB", "RGB", "CalRGB": return deviceRGB
        case "DeviceCMYK", "CMYK": return deviceCMYK
        case "Lab":
            let d = PDFObj.dictElement(array, 1)
            return PDFColourSpace(.lab(white: d.flatMap { PDFObj.numbers($0, "WhitePoint") } ?? [0.9642, 1, 0.8249], range: d.flatMap { PDFObj.numbers($0, "Range") } ?? [-100, 100, -100, 100]))
        case "ICCBased":
            guard let stream = PDFObj.streamElement(array, 1), let dict = PDFObj.streamDictionary(stream) else { return nil }
            let n = PDFObj.int(dict, "N") ?? 3
            if let loaded = PDFObj.data(stream), let space = CGColorSpace(iccData: loaded.0 as CFData), space.numberOfComponents == n {
                return PDFColourSpace(.icc(space, n))
            }
            return n == 1 ? deviceGray : n == 4 ? deviceCMYK : deviceRGB
        case "Indexed", "I":
            guard let base = baseSpace(1) else { return nil }
            var hival = 255
            var v: CGPDFInteger = 0
            if CGPDFArrayGetInteger(array, 2, &v) { hival = Int(v) }
            var lookupBytes: [UInt8] = []
            if let s = PDFObj.stringElement(array, 3) { lookupBytes = [UInt8](s) }
            else if let st = PDFObj.streamElement(array, 3), let loaded = PDFObj.data(st) { lookupBytes = [UInt8](loaded.0) }
            return PDFColourSpace(.indexed(base: base, hival: min(max(hival, 0), 255), lookup: lookupBytes))
        case "Separation", "DeviceN":
            guard let alt = baseSpace(2), let fnObj = PDFObj.objectElement(array, 3), let fn = PDFFunction.parse(fnObj) else { return nil }
            var n = 1
            if family == "DeviceN", let names = PDFObj.arrayElement(array, 1) { n = max(1, CGPDFArrayGetCount(names)) }
            return PDFColourSpace(.tint(alternate: alt, function: fn, count: n))
        case "Pattern":
            return PDFColourSpace(.pattern(base: baseSpace(1)))
        default: return nil
        }
    }

    nonisolated(unsafe) private static var cache: [String: VectorColour] = [:]
    private static let lock = NSLock()
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let cmykSpace = CGColorSpace(name: CGColorSpace.genericCMYK)!

    private static func converted(_ space: CGColorSpace, _ comps: [Double], key: String) -> VectorColour {
        let k = key + comps.map { String(Int(($0 * 255).rounded())) }.joined(separator: ",")
        lock.lock(); if let hit = cache[k] { lock.unlock(); return hit }; lock.unlock()
        let cg = CGColor(colorSpace: space, components: comps.map { CGFloat($0) } + [1])
        var result = VectorColour.black
        if let out = cg?.converted(to: srgb, intent: .defaultIntent, options: nil), let c = out.components, c.count >= 3 {
            result = VectorColour(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
        }
        lock.lock(); if cache.count > 20000 { cache.removeAll() }; cache[k] = result; lock.unlock()
        return result
    }

    func toRGB(_ raw: [Double]) -> VectorColour {
        func c(_ i: Int) -> Double { i < raw.count ? min(max(raw[i], 0), 1) : 0 }
        switch kind {
        case .gray: return VectorColour(red: c(0), green: c(0), blue: c(0))
        case .rgb: return VectorColour(red: c(0), green: c(1), blue: c(2))
        case .cmyk: return Self.converted(Self.cmykSpace, [c(0), c(1), c(2), c(3)], key: "k")
        case .icc(let space, let n):
            return Self.converted(space, (0..<n).map { c($0) }, key: "i\(space.hashValue)")
        case .lab(let white, let range):
            let L = raw.count > 0 ? min(max(raw[0], 0), 100) : 0
            let a = raw.count > 1 ? min(max(raw[1], range[0]), range[1]) : 0, b = raw.count > 2 ? min(max(raw[2], range[2]), range[3]) : 0
            let fy = (L + 16) / 116, fx = fy + a / 500, fz = fy - b / 200
            func inv(_ t: Double) -> Double { t > 6.0 / 29 ? t * t * t : 3 * (6.0 / 29) * (6.0 / 29) * (t - 4.0 / 29) }
            let X = white[0] * inv(fx), Y = white[1] * inv(fy), Z = white[2] * inv(fz)
            // D50 XYZ → linear sRGB (Bradford-adapted matrix).
            let r = 3.1338561 * X - 1.6168667 * Y - 0.4906146 * Z
            let g = -0.9787684 * X + 1.9161415 * Y + 0.0334540 * Z
            let bl = 0.0719453 * X - 0.2289914 * Y + 1.4052427 * Z
            func gamma(_ v: Double) -> Double { let x = min(max(v, 0), 1); return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055 }
            return VectorColour(red: gamma(r), green: gamma(g), blue: gamma(bl))
        case .indexed(let base, let hival, let lookup):
            let idx = min(max(Int(raw.first ?? 0), 0), hival)
            let n = base.components
            var comps: [Double] = []
            for k in 0..<n { let o = idx * n + k; comps.append(o < lookup.count ? Double(lookup[o]) / 255 : 0) }
            if case .lab(_, let range) = base.kind {
                comps = [comps[0] * 100, range[0] + comps[1] * (range[1] - range[0]), range[2] + comps[2] * (range[3] - range[2])]
            }
            return base.toRGB(comps)
        case .tint(let alt, let fn, _):
            return alt.toRGB(fn.eval(raw))
        case .pattern(let base): return base?.toRGB(raw) ?? .black
        }
    }
}
