import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func setSessionOverlayVisibility(_ target: String?, window: String?, pane: OverlayPane?,
                                     mode: OverlayVisibilityMode) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let failure = store.applyOverlayVisibility(id, pane: pane, mode: mode) { return err(failure.message) }
            reconcile(focusActive: store.selectedSessionID == id)
            return ok(id)
        }
    }

    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?, points: OverlayPointSize) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let remote = store.resizeRemoteOverlay(id, sizePercent: sizePercent, points: points) {
                return ControlResponse(ok: remote == .sent, result: remote == .sent ? ControlResult(id: id.uuidString) : nil,
                                       error: remote.error)
            }
            if let failure = store.resizeOverlayInPoints(id, sizePercent: sizePercent, points: points) { return err(failure.message) }
            reconcile(focusActive: false)
            return ok(id)
        }
    }

    /// Layout and input use the visible layer; occupancy continues to own lifetime, reads, and exit codes.
    func applyOverlayVisibility(_ session: Session) {
        if let stack = sessionStacks[session.id] {
            let page = session.fullOverlayVisible ? (session.htmlOverlayActive ? "html" : "overlay")
                : session.scratchActive ? "scratch" : "main"
            gtk_stack_set_visible_child_name(stack, page)
        }
        let sessionShown = session.hudActive || session.coverOverlayVisible
        if let frame = floatingOverlayFrames[session.id] {
            gtk_widget_set_opacity(W(frame), sessionShown ? 1 : 0)
            gtk_widget_set_can_target(W(frame), sessionShown && !session.hudActive ? 1 : 0)
        }
        for pane in OverlayPane.allCases {
            let shown = session.paneOverlayVisible(pane)
            if let overlay = session.paneOverlay(pane) {
                let widget = overlay.html.flatMap { LinuxHtmlOverlayRegistry.shared.existing($0.id)?.root }
                    ?? paneOverlaySurface(session.id, pane: pane)?.rootWidget
                gtk_widget_set_opacity(W(widget), shown ? 1 : 0)
                gtk_widget_set_can_target(W(widget), shown ? 1 : 0)
            }
        }
    }

    func cacheOverlayBounds(_ session: Session) {
        let width = Double(gtk_widget_get_width(W(deck))), height = Double(gtk_widget_get_height(W(deck)))
        guard width > 0, height > 0 else { return }
        session.hudPaneFrames.detail = HudPaneFrame(x: 0, y: 0, width: width, height: height)
        func frame(_ host: OpaquePointer?) -> HudPaneFrame? {
            guard let host, gtk_widget_get_mapped(W(host)) != 0 else { return nil }
            var origin = graphene_point_t(), local = graphene_point_t()
            guard gtk_widget_compute_point(W(host), W(deck), &origin, &local) != 0 else { return nil }
            return HudPaneFrame(x: Double(local.x), y: Double(local.y),
                                width: Double(gtk_widget_get_width(W(host))), height: Double(gtk_widget_get_height(W(host))))
        }
        session.hudPaneFrames.left = frame(primaryPaneHosts[session.id])
        session.hudPaneFrames.right = frame(splitPaneHosts[session.id])
    }
}
