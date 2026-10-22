import Foundation
import SuperConverterCore
public enum PDFReader { public static func read(_ url: URL) throws -> VectorReadResult { throw ConversionError.failed("todo") } }
public enum AIReader { public static func read(_ url: URL) throws -> VectorReadResult { throw ConversionError.failed("todo") } }
public enum SVGReader { public static func read(_ data: Data) throws -> VectorReadResult { throw ConversionError.failed("todo") } }
public enum SVGWriter { public static func write(_ document: VectorDocument, options: VectorWriteOptions) throws -> VectorWriteResult { throw ConversionError.failed("todo") } }
