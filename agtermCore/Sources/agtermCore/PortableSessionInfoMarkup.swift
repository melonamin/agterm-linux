import Foundation
#if canImport(Markdown)
import Markdown

/// The span adapter for hosts without Foundation's attributed Markdown initializer.
/// Swift Markdown owns CommonMark parsing and extended attributes; the adapter owns only the product's
/// span traits and JSON5 attribute types, matching the Darwin Foundation path.
enum SessionInfoMarkupPortable {
    typealias Failure = SessionInfoMarkup.ParseError

    private struct Attributes: Decodable {
        let color: String?
        let dim: Bool?
    }

    static func parse(_ source: String) throws(Failure) -> [SessionInfoSpan] {
        // A literal prefix keeps the one-line field in an inline paragraph: leading #, >, or list
        // markers are text under Foundation's inlineOnlyPreservingWhitespace mode too.
        let prefix = "agterm-inline "
        let document = Document(parsing: prefix + source)
        var spans: [SessionInfoSpan] = []
        try walk(document, style: SessionInfoSpan(text: ""), into: &spans)
        if spans.count == 1, spans[0].text == prefix.trimmingCharacters(in: .whitespaces) { return [] }
        guard !spans.isEmpty, spans[0].text.hasPrefix(prefix) else { throw .invalidMarkdown }
        spans[0].text.removeFirst(prefix.count)
        return spans.filter { !$0.text.isEmpty }
    }

    private static func append(_ text: String, style: SessionInfoSpan, into spans: inout [SessionInfoSpan]) {
        guard !text.isEmpty else { return }
        var span = style
        span.text = text
        if let last = spans.last, last.sameStyle(as: span) {
            spans[spans.count - 1].text += text
        } else {
            spans.append(span)
        }
    }

    private static func walk(_ node: any Markup, style: SessionInfoSpan,
                             into spans: inout [SessionInfoSpan]) throws(Failure) {
        var nested = style
        switch node {
        case let text as Text:
            append(text.string, style: style, into: &spans)
            return
        case let code as InlineCode:
            nested.code = true
            append(code.code, style: nested, into: &spans)
            return
        case let html as InlineHTML:
            append(html.rawHTML, style: style, into: &spans)
            return
        case is SoftBreak, is LineBreak:
            append("\n", style: style, into: &spans)
            return
        case is Strong: nested.bold = true
        case is Emphasis: nested.italic = true
        case let attribute as InlineAttributes:
            let decoder = JSONDecoder()
            decoder.allowsJSON5 = true
            let values: Attributes
            do {
                values = try decoder.decode(Attributes.self, from: Data(("{" + attribute.attributes + "}").utf8))
            } catch { throw .invalidMarkdown }
            if let name = values.color {
                guard let color = TintColor(rawValue: name.lowercased()) else { throw .unknownColor(name) }
                nested.color = color
            }
            nested.dim = values.dim ?? nested.dim
        default: break
        }
        for (index, child) in node.children.enumerated() {
            if index > 0, node is Document { append("\n", style: style, into: &spans) }
            try walk(child, style: nested, into: &spans)
        }
    }
}
#endif
