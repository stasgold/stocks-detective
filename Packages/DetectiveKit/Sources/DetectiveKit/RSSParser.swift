import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Minimal RSS 2.0 parser for news feeds.
public final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [NewsArticle] = []
    private var current: [String: String]?
    private var text = ""

    public static func parse(_ data: Data) -> [NewsArticle] {
        let delegate = RSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.items
    }

    // One formatter per parser: news feeds are parsed on several threads at once.
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                       qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "item" { current = [:] }
        text = ""
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item", let c = current {
            var title = c["title"] ?? ""
            var source = c["source"] ?? ""
            // Google News titles end with " - Publisher".
            if source.isEmpty, let r = title.range(of: " - ", options: .backwards) {
                source = String(title[r.upperBound...])
                title = String(title[..<r.lowerBound])
            } else if !source.isEmpty, title.hasSuffix(" - " + source) {
                title = String(title.dropLast(source.count + 3))
            }
            if !title.isEmpty {
                items.append(NewsArticle(
                    title: title,
                    summary: Self.stripHTML(c["description"] ?? ""),
                    source: source,
                    link: c["link"] ?? "",
                    published: c["pubDate"].flatMap { dateFormatter.date(from: $0) }))
            }
            current = nil
        } else if current != nil {
            current?[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = ""
    }

    static func stripHTML(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (k, v) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " "] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        out = out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(out.trimmingCharacters(in: .whitespaces).prefix(280))
    }
}
