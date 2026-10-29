import Foundation
import SuperConverterCore

/// A parsed XML element with namespace prefixes dropped (`x:Key` → `Key`, `xml:lang` → `lang`).
final class XNode {
    let name: String
    var attributes: [String: String]
    var children: [XNode] = []
    weak var parent: XNode?
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
    func attr(_ key: String) -> String? { attributes[key] }
    func child(_ name: String) -> XNode? { children.first { $0.name == name } }
}

/// Bounded XML parsing on Foundation's `XMLParser`; external entities are not resolved.
enum XMLTree {
    static let maxDepth = 200
    static let maxElements = 1_500_000

    static func parse(_ data: Data) throws -> XNode {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root, !delegate.overflow else { throw ConversionError.damaged("xps") }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []
        var count = 0
        var overflow = false

        static func local(_ name: String) -> String { name.split(separator: ":").last.map(String.init) ?? name }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            count += 1
            if count > XMLTree.maxElements || stack.count >= XMLTree.maxDepth { overflow = true; parser.abortParsing(); return }
            var attrs: [String: String] = [:]
            for (key, value) in attributeDict where !key.hasPrefix("xmlns") { attrs[Builder.local(key)] = value }
            let node = XNode(name: Builder.local(elementName), attributes: attrs)
            if let parent = stack.last { node.parent = parent; parent.children.append(node) } else if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = stack.popLast() }
    }
}
