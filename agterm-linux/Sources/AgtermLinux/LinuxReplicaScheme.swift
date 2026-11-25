import CGtk
import CWebKit
import Foundation
import agtermCore

@MainActor
extension LinuxHtmlOverlayPage {
    func fetchReplica(_ path: String, request: OpaquePointer) {
        if let grant = overlay.markdownLinks { return fetchLinkedMarkdown(path, grant: grant, request: request) }
        guard !closed, let channel = controller?.replicaPages[id]?.channel else { return agterm_uri_scheme_deny(request) }
        let reply = LinuxReplicaSchemeReply(request)
        let revision = overlay.reloadRevision
        channel.fetch(path) { [weak self] result in
            guard let self, !self.closed, self.overlay.reloadRevision == revision else { return reply.deny() }
            switch result {
            case .failure: reply.deny()
            case .success(let resource): reply.finish(resource)
            }
        }
    }

    private func fetchLinkedMarkdown(_ path: String, grant: MarkdownLinkGrant, request: OpaquePointer) {
        let reply = LinuxReplicaSchemeReply(request)
        let revision = overlay.reloadRevision
        if case .replica = overlay.source {
            guard let channel = controller?.replicaPages[id]?.channel else { return reply.deny() }
            channel.fetch(path) { [weak self] result in
                guard let self, !closed, overlay.reloadRevision == revision, case .success(let resource) = result else { return reply.deny() }
                LinuxRemoteMarkdown(page: self, channel: channel, revision: revision) { html in
                    if let html { reply.finishHTML(html) } else { reply.deny() }
                }.load(resource, origin: path)
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let html = MarkdownPage.linkedDocument(path, grant: grant).flatMap { file in
                    try? MarkdownProbe.load(path: file).map {
                        MarkdownPage.html(markdown: $0.markdown, images: $0.images, style: MarkdownAssets.shared.style, links: true)
                    }.get()
                }
                runOnMain { MainActor.assumeIsolated {
                    guard let self, !self.closed, self.overlay.reloadRevision == revision, let html else { return reply.deny() }
                    reply.finishHTML(html)
                } }
            }
        }
    }
}

@MainActor
private final class LinuxReplicaSchemeReply {
    let request: OpaquePointer
    init(_ request: OpaquePointer) {
        self.request = request
        g_object_ref(RAW(request))
    }
    func deny() {
        agterm_uri_scheme_deny(request)
        g_object_unref(RAW(request))
    }
    func finish(_ resource: LinuxPageResource) {
        agterm_uri_scheme_finish_file(request, resource.path, resource.mime)
        g_object_unref(RAW(request))
    }
    func finishHTML(_ html: String) {
        html.withCString { agterm_uri_scheme_finish_html(request, $0, html.utf8.count) }
        g_object_unref(RAW(request))
    }
}
