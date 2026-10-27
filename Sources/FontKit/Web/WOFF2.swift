import Foundation
import WOFF2

/// WOFF 2.0 through google/woff2 + Brotli (MIT), linked as the `WOFF2` vendor library.
enum WOFF2Format {
    static func toSFNT(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count > 48, try bytes.tag(0) == "wOF2" else { throw FontError.damaged("not a WOFF2 file") }
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = bytes.withUnsafeBufferPointer { sc_woff2_decode($0.baseAddress, $0.count, &out, &length) }
        guard status == 0, let out else { throw FontError.damaged("the WOFF2 data could not be decoded") }
        defer { sc_woff2_free(out) }
        return Array(UnsafeBufferPointer(start: out, count: length))
    }

    /// `quality` is Brotli's 0...11.
    static func fromSFNT(_ sfnt: [UInt8], quality: Int = 11) throws -> [UInt8] {
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        let status = sfnt.withUnsafeBufferPointer { sc_woff2_encode($0.baseAddress, $0.count, Int32(quality), 1, &out, &length) }
        guard status == 0, let out else { throw FontError.unsupported("This font can’t be packed as WOFF 2.") }
        defer { sc_woff2_free(out) }
        return Array(UnsafeBufferPointer(start: out, count: length))
    }
}
