import CWebKit
import Foundation
import agtermCore

/// Each checked image is served once at its own address; WebKit never receives base64 image text.
@MainActor
final class LinuxImagePageSource {
    static let scheme = "agterm-image"
    private var staged: (path: String, mime: String, data: Data)?

    func stage(_ data: Data, mime: String, page: UUID) -> String {
        let path = "/" + UUID().uuidString.lowercased()
        staged = (path, mime, data)
        return "\(Self.scheme)://\(page.uuidString.lowercased())\(path)"
    }

    func clear() { staged = nil }

    func serve(_ path: String, request: OpaquePointer) {
        guard let image = staged, image.path == path else { return agterm_uri_scheme_deny(request) }
        staged = nil
        image.data.withUnsafeBytes { bytes in
            agterm_uri_scheme_finish_bytes(request, bytes.baseAddress, bytes.count, image.mime)
        }
    }
}

enum LinuxFilePageContent: Sendable {
    case html(String)
    case image(Data, String)
}

@MainActor
extension LinuxHtmlOverlayPage {
    func displayGenerated(_ content: LinuxFilePageContent) {
        let html: String
        switch content {
        case .html(let value): html = value
        case .image(let data, let mime):
            imageLoadError = nil
            html = ImagePage.html(src: imageSource.stage(data, mime: mime, page: id))
        }
        html.withCString { webkit_web_view_load_html(cast(webView), $0, nil) }
    }
}
