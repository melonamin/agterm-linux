import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        openHud(target, window: window, spec: spec, placement: ControlHudPlacement())
    }

    func openHud(_ target: String?, window: String?, spec: HudSpec,
                 placement: ControlHudPlacement) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            guard let command = Self.hudHelperCommand() else {
                return err("hud helper is not bundled in this build")
            }
            let paneIdentity: UUID?
            let pane: OverlayPane?
            switch resolveControlPanePlacement(placement.pane, paneID: placement.paneID, in: session,
                                               requireVisible: true, invalidPaneError: "hud pane must be left or right") {
            case .resolved(let identity, let resolvedPane):
                paneIdentity = identity
                pane = resolvedPane
            case .rejected(let response): return response
            }
            let fontSize = spec.fontSize ?? Self.hudFontSize(
                sessionFontSize: session.fontSize, settingsFontSize: linuxSettingsStore().load().fontSize)
            let metrics = hudPaneMetrics(for: session, pane: pane, fontSize: fontSize)
            guard let file = LinuxHudBodyStorage.path(for: id) else {
                return err(OverlayHudError.writeFailed)
            }
            guard store.openHud(id, command: command, spec: spec, file: file,
                                size: HudLayout.panelSize(for: spec, pane: metrics),
                                paneIdentity: paneIdentity, fontSize: fontSize) else {
                return err("overlay already open")
            }
            guard writeHudBody(session, pane: metrics) else {
                store.closeHud(id)
                reconcile(focusActive: false)
                return err(OverlayHudError.writeFailed)
            }
            armHudAutoHide(session, spec: spec)
            reconcile(focusActive: false)
            return ok(id)
        }
    }

    func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        updateHud(target, window: window, spec: spec, placement: ControlHudPlacement())
    }

    func updateHud(_ target: String?, window: String?, spec: HudSpec,
                   placement: ControlHudPlacement) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id), session.hudActive,
                  let previous = session.hudSpec, let previousWidth = session.overlaySizePercent,
                  let previousHeight = session.hudHeightPercent else { return err(OverlayHudError.noHud) }
            let paneIdentity: UUID?
            let pane: OverlayPane?
            switch resolveControlPanePlacement(placement.pane, paneID: placement.paneID, in: session,
                                               requireVisible: false, invalidPaneError: "hud pane must be left or right") {
            case .resolved(let identity, let resolvedPane):
                paneIdentity = identity
                pane = resolvedPane
            case .rejected(let response): return response
            }
            let previousPaneIdentity = session.hudPaneIdentity
            let metrics = hudPaneMetrics(for: session, pane: pane, fontSize: session.hudFontSize)
            store.updateHud(id, spec: spec, size: HudLayout.panelSize(for: spec, pane: metrics),
                            paneIdentity: paneIdentity)
            guard writeHudBody(session, pane: metrics) else {
                store.updateHud(id, spec: previous,
                                size: HudPanelSize(widthPercent: previousWidth, heightPercent: previousHeight),
                                paneIdentity: previousPaneIdentity)
                return err(OverlayHudError.writeFailed)
            }
            armHudAutoHide(session, spec: spec)
            reconcile(focusActive: false)
            return ok(id)
        }
    }

    func closeHud(_ target: String?, window: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard store.closeHud(id) else { return err(OverlayHudError.noHud) }
            reconcile(focusActive: false)
            return ok(id)
        }
    }

    func hudPaneMetrics(for session: Session, pane: OverlayPane? = nil,
                        fontSize override: Double? = nil) -> PaneMetrics {
        let fontSize = override ?? Self.hudFontSize(
            sessionFontSize: session.fontSize, settingsFontSize: linuxSettingsStore().load().fontSize)
        let context = gtk_widget_get_pango_context(W(deck))
        let description = pango_font_description_new()
        if let family = linuxSettingsStore().load().fontFamily {
            family.withCString { pango_font_description_set_family(description, $0) }
        } else {
            "monospace".withCString { pango_font_description_set_family(description, $0) }
        }
        pango_font_description_set_absolute_size(description, fontSize * 96.0 / 72.0 * 1_024.0)
        let metrics = pango_context_get_metrics(context, description, nil)
        let cellWidth = Double(pango_font_metrics_get_approximate_char_width(metrics)) / 1_024.0
        let cellHeight = Double(pango_font_metrics_get_ascent(metrics)
            + pango_font_metrics_get_descent(metrics)) / 1_024.0
        pango_font_metrics_unref(metrics)
        pango_font_description_free(description)
        let host = floatingOverlayHost(for: session, pane: pane)
        return PaneMetrics(cellWidth: max(cellWidth, 1), cellHeight: max(cellHeight, 1),
                           paneWidth: Double(gtk_widget_get_width(W(host))),
                           paneHeight: Double(gtk_widget_get_height(W(host))))
    }

    static func hudFontSize(sessionFontSize: Double?, settingsFontSize: Double?) -> Double {
        sessionFontSize ?? settingsFontSize ?? DashboardLayout.ghosttyDefaultFontSize
    }

    private func armHudAutoHide(_ session: Session, spec: HudSpec) {
        session.onHudDiscarded?()
        session.onHudDiscarded = nil
        let seconds = min(spec.effectiveHideAfter, HudSpec.maxHideAfter)
        let expiresAt = seconds > 0 ? Date().addingTimeInterval(seconds) : nil
        defer { store.publishHud(forSession: session.id, expiresAt: expiresAt) }
        guard seconds > 0 else { return }
        let id = session.id
        let cancel = MainTimer.schedule(after: seconds) { [weak self, weak session] in
            guard let self, session?.hudActive == true else { return }
            _ = self.store.closeHud(id)
            self.reconcile(focusActive: false)
        }
        session.onHudDiscarded = cancel
    }

    private static func hudHelperCommand() -> String? {
        guard let helper = Bundle.module.resourceURL?.appendingPathComponent("hud/hud.sh") else { return nil }
        guard FileManager.default.isReadableFile(atPath: helper.path) else { return nil }
        return "/bin/sh \(ShellEscape.path(helper.path))"
    }

    func writeHudBody(_ session: Session, pane: PaneMetrics) -> Bool {
        guard let path = session.hudFile, let spec = session.hudSpec,
              let width = session.overlaySizePercent, let height = session.hudHeightPercent else { return false }
        let size = HudPanelSize(widthPercent: width, heightPercent: height)
        let body = HudLayout.renderedBody(for: spec, grid: HudLayout.paintGrid(for: spec, size: size, pane: pane),
                                          ownerPid: ProcessInfo.processInfo.processIdentifier)
        return LinuxHudBodyStorage.write(Data(body.utf8), to: path)
    }
}
