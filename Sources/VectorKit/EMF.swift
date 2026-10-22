import Foundation
import SuperConverterCore

public enum EMFReader {
    public static func read(_ data: Data) throws -> VectorReadResult { throw ConversionError.unsupportedPair(from: "emf", to: "svg") }
}
public enum EMFWriter {
    public static func write(_ document: VectorDocument, options: VectorWriteOptions) throws -> VectorWriteResult { throw ConversionError.unsupportedPair(from: "svg", to: "emf") }
}
public enum WMFReader {
    public static func read(_ data: Data) throws -> VectorReadResult { throw ConversionError.unsupportedPair(from: "wmf", to: "svg") }
}
public enum WMFWriter {
    public static func write(_ document: VectorDocument, options: VectorWriteOptions) throws -> VectorWriteResult { throw ConversionError.unsupportedPair(from: "svg", to: "wmf") }
}
