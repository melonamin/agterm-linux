import CGtk
import CWebKit
import Foundation

@MainActor
extension LinuxHtmlOverlayPage {
    func fetchReplica(_ path: String, request: OpaquePointer) {
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
}
