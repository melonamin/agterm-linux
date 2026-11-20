import CGtk
import agtermCore

@MainActor
extension AppController {
    func refreshHudMeasurement(_ session: Session) {
        guard session.hudActive, let spec = session.hudSpec else { return }
        let metrics = hudPaneMetrics(for: session, pane: session.hudTargetPane, fontSize: session.hudFontSize)
        store.updateHud(session.id, spec: spec, size: HudLayout.panelSize(for: spec, pane: metrics), paneIdentity: session.hudPaneIdentity)
        _ = writeHudBody(session, pane: metrics)
    }

    func mountFloatingOverlayFrame(
        _ session: Session,
        frame: OpaquePointer,
        overlay: OpaquePointer,
        child: OpaquePointer?,
        fallbackPercent: Int
    ) -> (width: Int32, height: Int32) {
        var chromeWidth: Int32 = 0, chromeHeight: Int32 = 0
        gtk_widget_measure(W(frame), GTK_ORIENTATION_HORIZONTAL, -1, &chromeWidth, nil, nil, nil)
        gtk_widget_measure(W(frame), GTK_ORIENTATION_VERTICAL, -1, &chromeHeight, nil, nil, nil)
        let request = updateFloatingOverlayFrame(
            session, frame: frame, overlay: overlay, fallbackPercent: fallbackPercent)
        gtk_frame_set_child(cast(frame), W(child))
        return GhosttySurfaceGeometry.contentSize(
            request: request, chrome: (width: chromeWidth, height: chromeHeight))
    }

    @discardableResult
    func updateFloatingOverlayFrame(_ session: Session, frame: OpaquePointer,
                                    overlay: OpaquePointer,
                                    fallbackPercent: Int) -> (width: Int32, height: Int32) {
        let width = gtk_widget_get_width(W(overlay))
        let height = gtk_widget_get_height(W(overlay))
        let widthPercent = Int32(session.overlaySizePercent ?? fallbackPercent)
        let heightPercent = Int32(session.hudHeightPercent ?? session.overlaySizePercent ?? fallbackPercent)
        let request: (width: Int32, height: Int32)
        if session.hudActive {
            request = (max(1, width * widthPercent / 100), max(1, Int32(session.hudHeightPoints ?? Double(height * heightPercent / 100))))
        } else {
            let panel = OverlayPointSize.panelSize(in: (Double(width), Double(height)),
                                                  sizePercent: Int(widthPercent), points: session.overlayPoints,
                                                  chrome: session.htmlOverlay?.chrome ?? 0)
            request = (max(1, Int32(panel.width)), max(1, Int32(panel.height)))
        }
        gtk_widget_set_size_request(W(frame), request.width, request.height)
        let framed = !session.hudActive || session.hudSpec?.frame != false
        for cssClass in ["card", "agterm-quick"] {
            if framed { gtk_widget_add_css_class(W(frame), cssClass) } else { gtk_widget_remove_css_class(W(frame), cssClass) }
        }
        if framed { gtk_widget_remove_css_class(W(frame), "agterm-hud-frameless") } else { gtk_widget_add_css_class(W(frame), "agterm-hud-frameless") }

        let position = session.hudSpec?.position ?? .center
        let horizontal: GtkAlign
        switch position {
        case .topLeft, .centerLeft, .bottomLeft: horizontal = GTK_ALIGN_START
        case .topRight, .centerRight, .bottomRight: horizontal = GTK_ALIGN_END
        default: horizontal = GTK_ALIGN_CENTER
        }
        let vertical: GtkAlign
        switch position {
        case .topLeft, .topCenter, .topRight: vertical = GTK_ALIGN_START
        case .bottomLeft, .bottomCenter, .bottomRight: vertical = GTK_ALIGN_END
        default: vertical = GTK_ALIGN_CENTER
        }
        gtk_widget_set_halign(W(frame), horizontal)
        gtk_widget_set_valign(W(frame), vertical)
        let sticky = session.hudSpec?.sticky == true
        let horizontalMargin = sticky ? 0 : width * Int32(HudPosition.edgeMarginPercent) / 100
        let verticalMargin = sticky ? 0 : height * Int32(HudPosition.edgeMarginPercent) / 100
        gtk_widget_set_margin_start(W(frame), horizontal == GTK_ALIGN_START ? horizontalMargin : 0)
        gtk_widget_set_margin_end(W(frame), horizontal == GTK_ALIGN_END ? horizontalMargin : 0)
        gtk_widget_set_margin_top(W(frame), vertical == GTK_ALIGN_START ? verticalMargin : 0)
        gtk_widget_set_margin_bottom(W(frame), vertical == GTK_ALIGN_END ? verticalMargin : 0)
        let targetable = Self.floatingOverlayTargetable(isHud: session.hudActive)
        gtk_widget_set_can_target(W(frame), targetable ? 1 : 0)
        gtk_widget_set_focusable(W(frame), 0)
        if let surface = overlaySurfaces[session.id] {
            gtk_widget_set_can_target(W(surface.rootWidget), targetable ? 1 : 0)
            gtk_widget_set_focusable(
                W(surface.glArea), Self.floatingOverlayFocusable(isHud: session.hudActive) ? 1 : 0)
        }
        return request
    }

}
