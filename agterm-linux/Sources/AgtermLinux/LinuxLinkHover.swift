import CGtk
import Foundation
import agtermCore

@MainActor
extension GhosttySurface {
    func showLinkHover(_ raw: String?) {
        let key = "agterm-link-hover"
        var label = g_object_get_data(cast(rootWidget), key).map { OpaquePointer($0) }
        if label == nil, raw != nil {
            label = op(gtk_label_new(nil))
            gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_MIDDLE)
            gtk_label_set_max_width_chars(label, 100)
            gtk_widget_set_halign(W(label), GTK_ALIGN_START)
            gtk_widget_set_valign(W(label), GTK_ALIGN_END)
            gtk_widget_set_margin_start(W(label), 6)
            gtk_widget_set_margin_bottom(W(label), 6)
            gtk_widget_set_can_target(W(label), 0)
            gtk_widget_add_css_class(W(label), "card")
            gtk_widget_add_css_class(W(label), "caption")
            gtk_overlay_add_overlay(rootWidget, W(label))
            g_object_set_data(cast(rootWidget), key, RAW(label))
        }
        guard let label else { return }
        if let raw {
            let text = LinkHover.label(for: raw) { [weak self] id in
                guard let self, let controller,
                      let target = controller.library.sessionLinkTarget(id, from: linkClickOrigin,
                          pane: UUID(uuidString: paneToken)) else { return nil }
                return controller.library.store(for: target.windowID)?.session(withID: target.sessionID)?.displayName
            }
            gtk_label_set_text(label, text)
        }
        gtk_widget_set_visible(W(label), raw == nil ? 0 : 1)
    }
}
