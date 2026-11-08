import CGtk
import CWebKit
import Foundation
import agtermCore

@MainActor
extension LinuxHtmlOverlayPage {
    func loadReplicaContent(path: String, content: ReplicaContent) {
        guard let channel = controller?.replicaPages[id]?.channel else { return fail(OverlayHtmlError.remoteFile) }
        let revision = overlay.reloadRevision
        channel.fetch(path) { [weak self] result in
            guard let self, !self.closed, self.overlay.reloadRevision == revision else { return }
            guard case .success(let resource) = result else { return self.fail(OverlayHtmlError.remoteFile) }
            if content == .markdown {
                return LinuxRemoteMarkdown(page: self, channel: channel, revision: revision).load(resource, origin: path)
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let loaded: Result<String, LinuxFilePageFailure>
                switch content {
                case .image:
                    loaded = ImageProbe.load(path: resource.path).map { ImagePage.html(data: $0.1, mimeType: $0.0.mimeType) }
                        .mapError { .message($0.description) }
                case .text(let line):
                    loaded = TextProbe.load(path: resource.path).map {
                        TextPage.html(text: $0, language: TextPage.language(forFile: path), line: line, style: MarkdownAssets.shared.textStyle)
                    }.mapError { .message($0.description) }
                case .document:
                    loaded = DocumentProbe.load(path: resource.path).mapError { .message($0.description) }
                case .html, .markdown: loaded = .failure(.message(OverlayHtmlError.remoteFile))
                }
                runOnMain { MainActor.assumeIsolated {
                    guard let self, !self.closed, self.overlay.reloadRevision == revision else { return }
                    switch loaded {
                    case .failure(let failure): self.fail(failure.message)
                    case .success(let html): html.withCString { webkit_web_view_load_html(cast(self.webView), $0, nil) }
                    }
                } }
            }
        }
    }
}

/// Fetch images through the origin's grant, never the same path on the viewer's filesystem.
/// Each continuation owns this finite load; closing/reloading the page drops it before the next fetch.
@MainActor
private final class LinuxRemoteMarkdown {
    weak var page: LinuxHtmlOverlayPage?
    let channel: LinuxPageChannel
    let revision: Int
    private var markdown = ""
    private var pending: [MarkdownPage.Image] = []
    private var embedded = MarkdownPage.Embedded()
    private var bytes = 0
    private var pixels = 0
    private var seen: [String: Int] = [:]

    init(page: LinuxHtmlOverlayPage, channel: LinuxPageChannel, revision: Int) {
        self.page = page
        self.channel = channel
        self.revision = revision
    }

    func load(_ resource: LinuxPageResource, origin: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let read = BoundedFile.read(path: resource.path, maxBytes: MarkdownPage.maxBytes)
            let markdown = (try? read.get()).flatMap { String(data: $0, encoding: .utf8) }
            let references = markdown.map {
                MarkdownPage.remoteImageReferences(in: $0, folder: URL(fileURLWithPath: origin).deletingLastPathComponent().path)
            } ?? []
            runOnMain { MainActor.assumeIsolated {
                guard self.current else { return }
                guard let markdown else { return self.page?.fail(MarkdownProbe.Failure.notText(origin).description) ?? () }
                self.markdown = markdown
                self.pending = Array(references.prefix(MarkdownPage.maxImages))
                self.next()
            } }
        }
    }

    private var current: Bool { page.map { !$0.closed && $0.overlay.reloadRevision == revision } ?? false }

    private func next() {
        guard current else { return }
        guard !pending.isEmpty, bytes < MarkdownPage.maxImageBytes, pixels < MarkdownPage.maxImagePixels else { return finish() }
        let image = pending.removeFirst()
        if let known = seen[image.path] {
            if known >= 0 { embedded.references[image.reference] = known }
            return next()
        }
        seen[image.path] = -1
        let room = MarkdownPage.maxImageBytes - bytes
        channel.fetch(image.path) { result in
            guard self.current else { return }
            guard case .success(let resource) = result else { return self.next() }
            DispatchQueue.global(qos: .userInitiated).async {
                let read = try? ImageProbe.load(path: resource.path, maxBytes: room).get()
                runOnMain { MainActor.assumeIsolated {
                    guard self.current else { return }
                    if let (probe, data) = read, self.pixels + probe.pixelWidth * probe.pixelHeight <= MarkdownPage.maxImagePixels {
                        self.bytes += data.count
                        self.pixels += probe.pixelWidth * probe.pixelHeight
                        let index = self.embedded.uris.count
                        self.embedded.uris.append("data:\(probe.mimeType);base64,\(data.base64EncodedString())")
                        self.embedded.references[image.reference] = index
                        self.seen[image.path] = index
                    }
                    self.next()
                } }
            }
        }
    }

    private func finish() {
        guard let page, current else { return }
        let markdown = markdown, embedded = embedded
        DispatchQueue.global(qos: .userInitiated).async { [weak page] in
            let html = MarkdownPage.html(markdown: markdown, images: embedded, style: MarkdownAssets.shared.style)
            runOnMain { MainActor.assumeIsolated {
                guard let page, !page.closed, page.overlay.reloadRevision == self.revision else { return }
                html.withCString { webkit_web_view_load_html(cast(page.webView), $0, nil) }
            } }
        }
    }
}
