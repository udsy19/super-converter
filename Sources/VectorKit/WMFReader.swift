import Foundation
import SuperConverterCore

public enum WMFReader {
    public static func read(_ data: Data) throws -> VectorReadResult { throw ConversionError.unsupportedPair(from: "wmf", to: "svg") }
}
