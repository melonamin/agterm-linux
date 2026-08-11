import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func openHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            guard let command = Self.hudHelperCommand() else {
                return err("hud helper is not bundled in this build")
            }
            let metrics = hudPaneMetrics(for: session)
            let file = Self.hudBodyFile(for: id)
            guard store.openHud(id, command: command, spec: spec, file: file,
                                size: HudLayout.panelSize(for: spec, pane: metrics)) else {
                return err("overlay already open")
            }
            guard writeHudBody(session, pane: metrics) else {
                store.closeHud(id)
                return err(OverlayHudError.writeFailed)
            }
            reconcile(focusActive: false)
            return ok(id)
        }
    }

    func updateHud(_ target: String?, window: String?, spec: HudSpec) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id), session.hudActive,
                  let previous = session.hudSpec, let previousWidth = session.overlaySizePercent,
                  let previousHeight = session.hudHeightPercent else { return err(OverlayHudError.noHud) }
            let metrics = hudPaneMetrics(for: session)
            store.updateHud(id, spec: spec, size: HudLayout.panelSize(for: spec, pane: metrics))
            guard writeHudBody(session, pane: metrics) else {
                store.updateHud(id, spec: previous,
                                size: HudPanelSize(widthPercent: previousWidth, heightPercent: previousHeight))
                return err(OverlayHudError.writeFailed)
            }
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

    private func hudPaneMetrics(for session: Session) -> PaneMetrics {
        let fontSize = surfaces[session.id]?.currentFontSize()
            ?? session.fontSize ?? linuxSettingsStore().load().fontSize ?? DashboardLayout.ghosttyDefaultFontSize
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
        return PaneMetrics(cellWidth: max(cellWidth, 1), cellHeight: max(cellHeight, 1),
                           paneWidth: Double(gtk_widget_get_width(W(deck))),
                           paneHeight: Double(gtk_widget_get_height(W(deck))))
    }

    private static func hudHelperCommand() -> String? {
        guard let helper = Bundle.module.resourceURL?.appendingPathComponent("hud/hud.sh") else { return nil }
        guard FileManager.default.isReadableFile(atPath: helper.path) else { return nil }
        return "/bin/sh \(ShellEscape.path(helper.path))"
    }

    private static func hudBodyFile(for sessionID: UUID) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("agterm-hud-\(sessionID.uuidString).txt")
    }

    private func writeHudBody(_ session: Session, pane: PaneMetrics) -> Bool {
        guard let path = session.hudFile, let spec = session.hudSpec,
              let width = session.overlaySizePercent, let height = session.hudHeightPercent else { return false }
        let size = HudPanelSize(widthPercent: width, heightPercent: height)
        let body = HudLayout.renderedBody(for: spec, grid: HudLayout.paintGrid(for: spec, size: size, pane: pane),
                                          ownerPid: ProcessInfo.processInfo.processIdentifier)
        return (try? Data(body.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
}
