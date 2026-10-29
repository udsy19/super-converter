import Compression
import Foundation
import SuperConverterCore

/// A parsed XML element: names without namespace prefixes (`svg:rect` → `rect`, `xlink:href` → `href`), so the SVG reader
/// reads files produced by tools that prefix the SVG namespace.
final class XNode {
    enum Part { case text(String), element(XNode) }

    let name: String
    var attributes: [String: String]
    var children: [XNode] = []
    /// Text and child elements in document order (mixed content for `<text>`).
    var parts: [Part] = []
    var text = ""
    weak var parent: XNode?

    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }

    func attr(_ key: String) -> String? { attributes[key] }
}

/// Bounded, non-validating XML parsing on Foundation's `XMLParser` (external entities are not resolved).
enum XMLTree {
    static let maxDepth = 400
    static let maxElements = 2_000_000

    static func parse(_ data: Data) throws -> XNode {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root, !delegate.overflow else { throw ConversionError.damaged("svg") }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []
        var count = 0
        var overflow = false

        static func local(_ name: String) -> String {
            guard let colon = name.lastIndex(of: ":") else { return name }
            return String(name[name.index(after: colon)...])
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String]) {
            count += 1
            if count > XMLTree.maxElements || stack.count >= XMLTree.maxDepth { overflow = true; parser.abortParsing(); return }
            var attrs: [String: String] = [:]
            for (key, value) in attributeDict {
                if key.hasPrefix("xmlns") { continue }
                let local = Builder.local(key)
                // `xlink:href` and `href` are the same attribute; a plain `href` wins when both are present.
                if key == "href" || attrs[local] == nil { attrs[local] = value }
            }
            let node = XNode(name: Builder.local(elementName), attributes: attrs)
            if let parent = stack.last { node.parent = parent; parent.children.append(node); parent.parts.append(.element(node)) } else if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func add(_ string: String) {
            guard let node = stack.last else { return }
            node.text += string
            if case .text(let previous)? = node.parts.last { node.parts[node.parts.count - 1] = .text(previous + string) } else { node.parts.append(.text(string)) }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { add(string) }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { add(String(decoding: CDATABlock, as: UTF8.self)) }
    }
}

/// gzip (RFC 1952) decoding for SVGZ, bounded against decompression bombs.
enum Gzip {
    static func isGzip(_ data: Data) -> Bool { data.count > 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b }

    static func decompress(_ data: Data, limit: Int = 256 << 20) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw ConversionError.damaged("svgz") }
        let flags = bytes[3]
        var pos = 10
        if flags & 4 != 0 { guard pos + 2 <= bytes.count else { throw ConversionError.damaged("svgz") }; pos += 2 + Int(bytes[pos]) + (Int(bytes[pos + 1]) << 8) }
        if flags & 8 != 0 { while pos < bytes.count, bytes[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 16 != 0 { while pos < bytes.count, bytes[pos] != 0 { pos += 1 }; pos += 1 }
        if flags & 2 != 0 { pos += 2 }
        guard pos < bytes.count - 8 else { throw ConversionError.damaged("svgz") }
        return try Inflate.raw(Array(bytes[pos..<(bytes.count - 8)]), limit: limit)
    }
}

/// Raw DEFLATE decoding on the Compression framework with an output cap.
enum Inflate {
    static func raw(_ input: [UInt8], limit: Int) throws -> Data {
        var out = Data()
        let bufferSize = 1 << 16
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { dst.deallocate() }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw ConversionError.damaged("svgz")
        }
        defer { compression_stream_destroy(streamPointer) }
        return try input.withUnsafeBufferPointer { src -> Data in
            streamPointer.pointee.src_ptr = src.baseAddress!
            streamPointer.pointee.src_size = src.count
            streamPointer.pointee.dst_ptr = dst
            streamPointer.pointee.dst_size = bufferSize
            while true {
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - streamPointer.pointee.dst_size
                out.append(dst, count: produced)
                if out.count > limit { throw ConversionError.damaged("svgz") }
                streamPointer.pointee.dst_ptr = dst
                streamPointer.pointee.dst_size = bufferSize
                switch status {
                case COMPRESSION_STATUS_END: return out
                case COMPRESSION_STATUS_OK: continue
                default: throw ConversionError.damaged("svgz")
                }
            }
        }
    }
}
