import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    /// Return true when the session-wide slot belongs to a page instead of a terminal.
    func syncHtmlSessionOverlay(_ session: Session, allowFocus: Bool) -> Bool {
        guard let stack = sessionStacks[session.id] else { return false }
        guard session.htmlOverlayActive, let overlay = session.htmlOverlay else {
            if let frame = htmlSessionFrames.removeValue(forKey: session.id) {
                removeFloatingOverlayFrame(frame)
                floatingOverlayFrames[session.id] = nil
            }
            return false
        }
        let page = LinuxHtmlOverlayRegistry.shared.page(for: overlay, controller: self,
                                                        backgroundColor: session.overlayBackgroundColor)
        if let percent = session.overlaySizePercent {
            if let frame = htmlSessionFrames[session.id] {
                let host = placeFloatingOverlayFrame(frame, for: session)
                updateFloatingOverlayFrame(session, frame: frame, overlay: host, fallbackPercent: percent)
            } else if let frame = OpaquePointer(gtk_frame_new(nil)) {
                moveHtmlRoot(page.root, into: nil)
                gtk_widget_add_css_class(W(frame), "card")
                gtk_widget_add_css_class(W(frame), "agterm-quick")
                gtk_widget_set_overflow(W(frame), GTK_OVERFLOW_HIDDEN)
                gtk_frame_set_child(cast(frame), W(page.root))
                let host = floatingOverlayHost(for: session, pane: nil)
                updateFloatingOverlayFrame(session, frame: frame, overlay: host, fallbackPercent: percent)
                gtk_overlay_add_overlay(host, W(frame))
                htmlSessionFrames[session.id] = frame
                floatingOverlayFrames[session.id] = frame
            }
        } else {
            if let frame = htmlSessionFrames.removeValue(forKey: session.id) {
                gtk_frame_set_child(cast(frame), nil)
                removeFloatingOverlayFrame(frame)
                floatingOverlayFrames[session.id] = nil
            }
            if gtk_widget_get_parent(W(page.root)).map(OpaquePointer.init) != stack {
                moveHtmlRoot(page.root, into: stack)
            }
            "html".withCString { gtk_stack_set_visible_child_name(stack, $0) }
        }
        if allowFocus, session.id == store.selectedSessionID {
            gtk_widget_grab_focus(W(page.webView))
        }
        return true
    }

    func syncHtmlPaneOverlay(_ session: Session, pane: OverlayPane) {
        guard let overlay = session.paneOverlay(pane)?.html,
              let host = paneHost(session.id, pane: pane) else { return }
        let page = LinuxHtmlOverlayRegistry.shared.page(for: overlay, controller: self,
                                                        backgroundColor: session.paneOverlay(pane)?.backgroundColor)
        if gtk_widget_get_parent(W(page.root)).map(OpaquePointer.init) != host {
            moveHtmlRoot(page.root, into: nil)
            gtk_widget_set_halign(W(page.root), GTK_ALIGN_FILL)
            gtk_widget_set_valign(W(page.root), GTK_ALIGN_FILL)
            gtk_overlay_add_overlay(host, W(page.root))
        }
    }

    func moveHtmlRoot(_ root: OpaquePointer, into stack: OpaquePointer?) {
        if let parent = gtk_widget_get_parent(W(root)) {
            if htmlSessionFrames.values.contains(OpaquePointer(parent)) {
                gtk_frame_set_child(cast(OpaquePointer(parent)), nil)
            } else if sessionStacks.values.contains(OpaquePointer(parent)) {
                gtk_stack_remove(OpaquePointer(parent), W(root))
            } else {
                gtk_overlay_remove_overlay(OpaquePointer(parent), W(root))
            }
        }
        if let stack { "html".withCString { _ = gtk_stack_add_named(stack, W(root), $0) } }
    }
}
