import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func closeFocusedPaneOverlay(_ sessionID: UUID) -> Bool {
        guard let pane = store.session(withID: sessionID)?.focusedOverlayPane else { return false }
        store.closePaneOverlay(sessionID, pane: pane)
        reconcile()
        return true
    }

    func syncPaneOverlays(_ session: Session, allowFocus: Bool) {
        for pane in OverlayPane.allCases {
            syncPaneOverlay(session, pane: pane)
        }
        session.dropUnrealizedPaneOverlays()
        for pane in OverlayPane.allCases where session.paneOverlay(pane) == nil {
            removePaneOverlaySurface(session, pane: pane)
        }
        for pane in OverlayPane.allCases {
            setPaneOverlayCoverage(session, pane: pane, covered: session.paneOverlay(pane) != nil)
        }
        updatePaneDim(session)
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
            fontSize: session.fontSize,
            backgroundColor: overlay.backgroundColor,
            usesSessionWatermark: false
        )
        let owner = windowID
        let sessionID = session.id
        surface.captureExitCode(from: codePath) { [weak surface] code in
            guard let controller = gWindows[owner], let surface,
                  let liveSession = controller.store.session(withID: sessionID),
                  let livePane = liveSession.paneOverlayRole(of: surface) else { return }
            controller.store.recordPaneOverlayExit(sessionID, pane: livePane, code: code)
        }
        surface.onExit = { [weak surface] in
            runOnMain { MainActor.assumeIsolated {
                guard let controller = gWindows[owner], let surface,
                      let liveSession = controller.store.session(withID: sessionID),
                      let livePane = liveSession.paneOverlayRole(of: surface) else { return }
                controller.store.closePaneOverlay(sessionID, pane: livePane)
                controller.reconcile()
            } }
        }
        session.setPaneOverlaySurface(surface, pane: pane)
        setPaneOverlaySurface(surface, sessionID: session.id, pane: pane)
        gtk_widget_set_halign(W(surface.rootWidget), GTK_ALIGN_FILL)
        gtk_widget_set_valign(W(surface.rootWidget), GTK_ALIGN_FILL)
        gtk_overlay_add_overlay(host, W(surface.rootWidget))
        let wash = OpaquePointer(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0))
        gtk_widget_set_hexpand(W(wash), 1)
        gtk_widget_set_vexpand(W(wash), 1)
        gtk_widget_set_can_target(W(wash), 0)
        gtk_widget_set_focusable(W(wash), 0)
        let provider = OpaquePointer(gtk_css_provider_new())
        gtk_style_context_add_provider(gtk_widget_get_style_context(W(wash)), provider, 651)
        g_object_unref(RAW(provider))
        gtk_overlay_add_overlay(host, W(wash))
        setPaneOverlayWash(wash, provider: provider, sessionID: session.id, pane: pane)
        surface.realizeWidgetIfNeeded()
    }

    private func removePaneOverlaySurface(_ session: Session, pane: OverlayPane) {
        guard let surface = paneOverlaySurface(session.id, pane: pane) else { return }
        if let host = paneHost(session.id, pane: pane) {
            if let wash = paneOverlayWash(session.id, pane: pane) {
                gtk_overlay_remove_overlay(host, W(wash))
            }
            gtk_overlay_remove_overlay(host, W(surface.rootWidget))
        }
        setPaneOverlayWash(nil, provider: nil, sessionID: session.id, pane: pane)
        setPaneOverlaySurface(nil, sessionID: session.id, pane: pane)
    }

    private func setPaneOverlayCoverage(_ session: Session, pane: OverlayPane, covered: Bool) {
        let base = pane == .left ? surfaces[session.id] : splitSurfaces[session.id]
        guard let base else { return }
        let hidden = Self.paneBaseIsCovered(
            overlayOpen: covered, zoomTarget: terminalZoom.target, dashboardOpen: dashboard.isOpen,
            sessionID: session.id, pane: pane)
        gtk_widget_set_visible(W(base.rootWidget), hidden ? 0 : 1)
        gtk_widget_set_can_target(W(base.rootWidget), hidden ? 0 : 1)
    }

    static func paneBaseIsCovered(
        overlayOpen: Bool, zoomTarget: TerminalZoomTarget?, dashboardOpen: Bool,
        sessionID: UUID, pane: OverlayPane
    ) -> Bool {
        let base: TerminalZoomSurface = pane == .left ? .primary : .split
        return overlayOpen && !dashboardOpen && zoomTarget != .session(sessionID, base)
    }

    func refreshPaneOverlayCoverage() {
        for session in store.workspaces.flatMap(\.sessions) {
            for pane in OverlayPane.allCases {
                setPaneOverlayCoverage(session, pane: pane, covered: session.paneOverlay(pane) != nil)
            }
        }
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

    func paneOverlayWash(_ sessionID: UUID, pane: OverlayPane) -> OpaquePointer? {
        pane == .left ? leftOverlayWashes[sessionID] : rightOverlayWashes[sessionID]
    }

    func paneOverlayWashProvider(_ sessionID: UUID, pane: OverlayPane) -> OpaquePointer? {
        pane == .left ? leftOverlayWashProviders[sessionID] : rightOverlayWashProviders[sessionID]
    }

    func setPaneOverlayWash(
        _ wash: OpaquePointer?, provider: OpaquePointer?, sessionID: UUID, pane: OverlayPane
    ) {
        if pane == .left {
            leftOverlayWashes[sessionID] = wash
            leftOverlayWashProviders[sessionID] = provider
        } else {
            rightOverlayWashes[sessionID] = wash
            rightOverlayWashProviders[sessionID] = provider
        }
    }

    func raisePaneOverlayWash(_ sessionID: UUID, pane: OverlayPane) {
        guard let host = paneHost(sessionID, pane: pane), let wash = paneOverlayWash(sessionID, pane: pane) else {
            return
        }
        _ = g_object_ref(RAW(wash))
        gtk_overlay_remove_overlay(host, W(wash))
        gtk_overlay_add_overlay(host, W(wash))
        g_object_unref(RAW(wash))
    }

    func paneHost(_ sessionID: UUID, pane: OverlayPane) -> OpaquePointer? {
        pane == .left ? primaryPaneHosts[sessionID] : splitPaneHosts[sessionID]
    }
}
