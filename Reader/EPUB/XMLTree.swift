import Foundation

/// Minimal DOM built with XMLParser. Element names have their namespace prefix stripped
/// (e.g. "dc:title" -> "title"); attributes keep their original names.
final class XNode {
    let name: String
    let attributes: [String: String]
    var children: [XNode] = []
    var text: String = ""
    weak var parent: XNode?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    subscript(attr: String) -> String? {
        if let v = attributes[attr] { return v }
        // Match ignoring prefix, e.g. "type" matches "epub:type".
        for (k, v) in attributes where k.split(separator: ":").last.map(String.init) == attr {
            return v
        }
        return nil
    }

    func child(_ name: String) -> XNode? { children.first { $0.name == name } }
    func children(_ name: String) -> [XNode] { children.filter { $0.name == name } }

    /// Depth-first search for all descendants with this name.
    func descendants(_ name: String) -> [XNode] {
        var out: [XNode] = []
        for c in children {
            if c.name == name { out.append(c) }
            out.append(contentsOf: c.descendants(name))
        }
        return out
    }

    func firstDescendant(_ name: String) -> XNode? {
        for c in children {
            if c.name == name { return c }
            if let d = c.firstDescendant(name) { return d }
        }
        return nil
    }

    /// All text inside this element, including descendants.
    var allText: String {
        text + children.map(\.allText).joined()
    }
}

enum XMLTree {
    static func parse(_ data: Data) -> XNode? {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        // Even on a late error we may have a usable tree.
        return delegate.root
    }

    static func parse(url: URL) -> XNode? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XNode?
        var stack: [XNode] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            let el = XNode(name: local, attributes: attributeDict)
            if let top = stack.last {
                el.parent = top
                top.children.append(el)
            } else {
                root = el
            }
            stack.append(el)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let s = String(data: CDATABlock, encoding: .utf8) { stack.last?.text += s }
        }
    }
}
