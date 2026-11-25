import Foundation
import agtermCore

enum LinuxFilePageFailure: Error, Sendable {
    case message(String)
    var message: String {
        switch self {
        case .message(let value): value
        }
    }
}

/// Runs on a worker. Only Swift-owned document text crosses back to the GTK main thread.
enum LinuxFilePageLoader {
    static func load(_ source: HtmlSource) -> Result<LinuxFilePageContent, LinuxFilePageFailure> {
        switch source {
        case .image(let path):
            return ImageProbe.load(path: path).map { .image($0.1, $0.0.mimeType) }
                .mapError { .message($0.description) }
        case .markdown(let path):
            let assets = MarkdownAssets.shared
            guard assets.available else { return .failure(.message("Markdown renderer resources are not bundled")) }
            return MarkdownProbe.load(path: path)
                .map { .html(MarkdownPage.html(markdown: $0.markdown, images: $0.images, style: assets.style)) }
                .mapError { .message($0.description) }
        case .text(let path, let line):
            return TextProbe.load(path: path).map {
                .html(TextPage.html(text: $0, language: TextPage.language(forFile: path), line: line, style: MarkdownAssets.shared.textStyle))
            }.mapError { .message($0.description) }
        case .document(let path):
            return DocumentProbe.load(path: path).map(LinuxFilePageContent.html).mapError { .message($0.description) }
        default: return .failure(.message("not a generated file page"))
        }
    }
}
