import Foundation
import SuperConverterCore

/// A parsed XML element: names without namespace prefixes (`svg:rect` → `rect`, `xlink:href` → `href`, `x:Key` → `Key`), so
/// the SVG reader reads files from tools that prefix the SVG namespace and XPSKit reads XPS markup and resources.
public final class XNode {
    public enum Part { case text(String), element(XNode) }

    public let name: String
    public var attributes: [String: String]
    public var children: [XNode] = []
    /// Text and child elements in document order (mixed content for `<text>`).
    public var parts: [Part] = []
    public var text = ""
    public weak var parent: XNode?

    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }

    public func attr(_ key: String) -> String? { attributes[key] }
    public func child(_ name: String) -> XNode? { children.first { $0.name == name } }
}

/// Bounded, non-validating XML parsing on Foundation's `XMLParser` (external entities are not resolved).
public enum XMLTree {
    static let maxDepth = 400
    static let maxElements = 2_000_000

    /// The document's root element; malformed or oversized markup is a damaged `format` file.
    public static func parse(_ data: Data, format: FormatID = "svg") throws -> XNode {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root, !delegate.overflow else { throw ConversionError.damaged(format) }
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

