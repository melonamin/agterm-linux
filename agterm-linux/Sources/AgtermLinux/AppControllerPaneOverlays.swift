import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func syncPaneOverlays(_ session: Session, allowFocus: Bool) {
        for pane in OverlayPane.allCases {
            syncPaneOverlay(session, pane: pane)
        }
        session.dropUnrealizedPaneOverlays()
        for pane in OverlayPane.allCases where session.paneOverlay(pane) == nil {
            removePaneOverlaySurface(session, pane: pane)
        }
        if allowFocus, session.id == store.selectedSessionID,
           let pane = session.focusedOverlayPane {
            paneOverlaySurface(session.id, pane: pane)?.grabFocus()
        }
    }

    private func syncPaneOverlay(_ session: Session, pane: OverlayPane) {
        guard let overlay = session.paneOverlay(pane), paneOverlaySurface(session.id, pane: pane) == nil,
              let host = paneHost(session.id, pane: pane) else { return }
        let codePath = NSTemporaryDirectory() + "agterm-pane-ovl-\(UUID().uuidString).code"
        var environment = sessionEnv(for: session)
        environment[OverlayCapture.cmdEnvKey] = overlay.command
        environment[OverlayCapture.codeEnvKey] = codePath
        let surface = GhosttySurface(
            sessionID: session.id,
            cwd: overlay.cwd ?? session.effectiveCwd,
            command: "sh -c " + Self.singleQuoted(OverlayCapture.shellLine),
            env: environment,
            controller: self,
            waitAfterCommand: overlay.wait,
            role: .overlay,
            reportsPaneState: false,
            backgroundColor: overlay.backgroundColor
        )
        let owner = windowID
        let sessionID = session.id
        surface.onExit = { [weak surface] in
            runOnMain { MainActor.assumeIsolated {
                guard let controller = gWindows[owner], let surface,
                      let liveSession = controller.store.session(withID: sessionID),
                      let livePane = liveSession.paneOverlayRole(of: surface) else { return }
                if let text = try? String(contentsOfFile: codePath, encoding: .utf8),
                   let code = OverlayCapture.parseExitCode(text) {
                    controller.store.recordPaneOverlayExit(sessionID, pane: livePane, code: code)
                }
                try? FileManager.default.removeItem(atPath: codePath)
                controller.store.closePaneOverlay(sessionID, pane: livePane)
                controller.reconcile()
            } }
        }
        session.setPaneOverlaySurface(surface, pane: pane)
        setPaneOverlaySurface(surface, sessionID: session.id, pane: pane)
        gtk_widget_set_halign(W(surface.glArea), GTK_ALIGN_FILL)
        gtk_widget_set_valign(W(surface.glArea), GTK_ALIGN_FILL)
        gtk_overlay_add_overlay(host, W(surface.glArea))
        surface.realizeWidgetIfNeeded()
    }

    private func removePaneOverlaySurface(_ session: Session, pane: OverlayPane) {
        guard let surface = paneOverlaySurface(session.id, pane: pane) else { return }
        if let host = paneHost(session.id, pane: pane) {
            gtk_overlay_remove_overlay(host, W(surface.glArea))
        }
        setPaneOverlaySurface(nil, sessionID: session.id, pane: pane)
    }

    func paneOverlaySurface(_ sessionID: UUID, pane: OverlayPane) -> GhosttySurface? {
        pane == .left ? leftOverlaySurfaces[sessionID] : rightOverlaySurfaces[sessionID]
    }

    func setPaneOverlaySurface(_ surface: GhosttySurface?, sessionID: UUID, pane: OverlayPane) {
        if pane == .left {
            leftOverlaySurfaces[sessionID] = surface
        } else {
            rightOverlaySurfaces[sessionID] = surface
        }
    }

    func paneHost(_ sessionID: UUID, pane: OverlayPane) -> OpaquePointer? {
        pane == .left ? primaryPaneHosts[sessionID] : splitPaneHosts[sessionID]
    }
}
