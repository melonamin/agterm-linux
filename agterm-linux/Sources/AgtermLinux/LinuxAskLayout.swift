import CGtk
import agtermCore

@MainActor
extension AppController {
    /// A pane ask stays above a session cover without moving terminals or shading half the cover.
    func layoutTerminalAsk(_ surface: LinuxAskSurface, for session: Session) {
        let root = W(surface.root)
        if session.askShadesFrame { gtk_widget_add_css_class(root, "agterm-ask-shaded") } else { gtk_widget_remove_css_class(root, "agterm-ask-shaded") }
        var left: Int32 = 0, right: Int32 = 0, top: Int32 = 0, bottom: Int32 = 0
        if let pane = session.askTargetPane, session.coverOverlayVisible, session.hasSplit {
            let width = gtk_widget_get_width(W(deck)), height = gtk_widget_get_height(W(deck))
            let share = min(1, max(0, session.splitRatio ?? 0.5))
            let primaryAtEnd = primaryInEndSlot(session.id)
            let atEnd = pane == .left ? primaryAtEnd : !primaryAtEnd
            let primarySize = Int32(Double(session.splitAxis == .leftRight ? width : height) * share)
            let span = session.splitAxis == .leftRight ? width : height
            let startSize = primaryAtEnd ? span - primarySize : primarySize
            if session.splitAxis == .leftRight {
                left = atEnd ? startSize : 0
                right = atEnd ? 0 : span - startSize
            } else {
                top = atEnd ? startSize : 0
                bottom = atEnd ? 0 : span - startSize
            }
        }
        gtk_widget_set_margin_start(root, left)
        gtk_widget_set_margin_end(root, right)
        gtk_widget_set_margin_top(root, top)
        gtk_widget_set_margin_bottom(root, bottom)
        if let width = session.askPending?.width, let host = askHost(for: session),
           let frame = gtk_widget_get_first_child(root) {
            let span = max(0, gtk_widget_get_width(W(host)) - left - right)
            gtk_widget_set_size_request(frame, max(0, span * Int32(width) / 100 - 32), -1)
        }
    }
}
