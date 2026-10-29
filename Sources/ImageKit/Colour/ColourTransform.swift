import ColorSync
import CoreGraphics
import Foundation

/// Every colour-space change goes through ColorSync (quality §2.1), in 32-bit float so nothing is clipped or quantised
/// on the way: relative colorimetric + black-point compensation by default, perceptual on request (quality §2.2).
enum ColourTransform {
    private struct Key: Hashable { let src: Data; let dst: Data; let intent: ImageSettings.Intent; let bpc: Bool }
    private final class Box: @unchecked Sendable { let transform: ColorSyncTransform; init(_ t: ColorSyncTransform) { transform = t } }
    nonisolated(unsafe) private static var cache: [Key: Box] = [:]
    private static let lock = NSLock()

    private static func transform(from src: ColourSpace, to dst: ColourSpace, intent: ImageSettings.Intent, bpc: Bool) -> ColorSyncTransform? {
        let key = Key(src: src.icc, dst: dst.icc, intent: intent, bpc: bpc)
        lock.lock(); defer { lock.unlock() }
        if let box = cache[key] { return box.transform }
        var error: Unmanaged<CFError>?
        guard let sp = ColorSyncProfileCreate(src.icc as CFData, &error)?.takeRetainedValue(),
              let dp = ColorSyncProfileCreate(dst.icc as CFData, &error)?.takeRetainedValue() else { return nil }
        let intentValue = intent == .perceptual ? kColorSyncRenderingIntentPerceptual.takeUnretainedValue() : kColorSyncRenderingIntentRelative.takeUnretainedValue()
        func step(_ profile: ColorSyncProfile, _ tag: CFString) -> [String: Any] {
            [kColorSyncProfile.takeUnretainedValue() as String: profile,
             kColorSyncRenderingIntent.takeUnretainedValue() as String: intentValue,
             kColorSyncTransformTag.takeUnretainedValue() as String: tag,
             kColorSyncBlackPointCompensation.takeUnretainedValue() as String: bpc ? kCFBooleanTrue! : kCFBooleanFalse!]
        }
        let sequence = [step(sp, kColorSyncTransformDeviceToPCS.takeUnretainedValue()), step(dp, kColorSyncTransformPCSToDevice.takeUnretainedValue())]
        guard let t = ColorSyncTransformCreate(sequence as CFArray, nil)?.takeRetainedValue() else { return nil }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = Box(t)
        return t
    }

    /// Converts `pixelCount` pixels of packed colour components (no alpha) from `src` to `dst`. Output is not clamped:
    /// out-of-gamut colours come back below 0 or above 1 so the caller can see (and report) them.
    static func convert(_ values: [Float], pixelCount: Int, from src: ColourSpace, to dst: ColourSpace,
                        intent: ImageSettings.Intent = .relative, blackPointCompensation: Bool = true) -> [Float]? {
        if src.icc == dst.icc { return values }
        guard let t = transform(from: src, to: dst, intent: intent, bpc: blackPointCompensation) else { return nil }
        var out = [Float](repeating: 0, count: pixelCount * dst.components)
        let layout = UInt32(kColorSyncByteOrderDefault) | kColorSyncAlphaNone.rawValue
        let chunk = 1 << 16
        let chunks = (pixelCount + chunk - 1) / chunk
        let ok = UnsafeMutableBufferPointer<Bool>.allocate(capacity: max(chunks, 1))
        ok.initialize(repeating: true)
        defer { ok.deallocate() }
        let srcComps = src.components, dstComps = dst.components
        values.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                let sBase = s.baseAddress!, dBase = d.baseAddress!
                DispatchQueue.concurrentPerform(iterations: chunks) { c in
                    let start = c * chunk, n = min(chunk, pixelCount - start)
                    ok[c] = ColorSyncTransformConvert(t, n, 1, dBase + start * dstComps, kColorSync32BitFloat, layout, n * dstComps * 4,
                                                      sBase + start * srcComps, kColorSync32BitFloat, layout, n * srcComps * 4, nil)
                }
            }
        }
        return ok.allSatisfy { $0 } ? out : nil
    }

    /// One colour (background fills).
    static func convert(colour: [Float], from src: ColourSpace, to dst: ColourSpace) -> [Float]? {
        convert(colour, pixelCount: 1, from: src, to: dst)
    }

    /// True when two RGB spaces map a 9×9×9 grid to within 1/512 of each other (the same colours; different bytes).
    static func equivalent(_ a: ColourSpace, _ b: ColourSpace) -> Bool {
        guard a.model == b.model, a.model == .rgb else { return a.icc == b.icc }
        var grid: [Float] = []
        for r in 0...8 { for g in 0...8 { for bl in 0...8 { grid += [Float(r) / 8, Float(g) / 8, Float(bl) / 8] } } }
        guard let out = convert(grid, pixelCount: grid.count / 3, from: a, to: b, blackPointCompensation: false) else { return false }
        return zip(grid, out).allSatisfy { abs($0 - $1) < 1 / 512 }
    }
}
