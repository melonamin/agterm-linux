import Foundation
#if canImport(Markdown)
import Markdown

/// Image discovery shares the CommonMark grammar with the renderer rather than guessing destinations
/// with a second string parser. File containment and bounded reads remain separate host-free/host checks.
enum MarkdownImageReferencesPortable {
    static func references(in source: String) -> [String] {
        func images(_ node: any Markup) -> [String] {
            if let image = node as? Image, let source = image.source { return [source] }
            return node.children.flatMap(images)
        }
        return images(Document(parsing: source))
    }
}
#endif
