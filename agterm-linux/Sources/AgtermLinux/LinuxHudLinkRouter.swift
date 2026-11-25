import CGtk
import Foundation
import agtermCore

/// Feed only Ctrl gestures to a passive HUD; other gestures continue to the pane beneath it.
/// A window capture controller reaches the panel without making its terminal focusable or targetable.
@MainActor
final class LinuxHudLinkRouter {
    private weak var controller: AppController?
    private weak var pressed: GhosttySurface?
    private static weak var hovered: GhosttySurface?
    private var point = graphene_point_t()

    private init(controller: AppController) { self.controller = controller }

    static func install(on window: OpaquePointer, controller: AppController) {
        let events = gtk_event_controller_legacy_new()
        gtk_event_controller_set_propagation_phase(events, GTK_PHASE_CAPTURE)
        let router = LinuxHudLinkRouter(controller: controller)
        let data = Unmanaged.passRetained(router).toOpaque()
        g_object_set_data_full(cast(events), "agterm-hud-links", data, releaseHudLinkRouter)
        connect(events, "event", unsafeBitCast(onHudLinkEvent as @convention(c)
            (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean, to: GCallback.self), data)
        gtk_widget_add_controller(W(window), events)
    }

    static func cursorOverride(for surface: GhosttySurface) -> String? {
        guard let hovered, hovered.surface != nil, hovered.mouseOverLink,
              hovered.controller === surface.controller else { return nil }
        return "pointer"
    }

    func event(_ event: OpaquePointer) -> Bool {
        let type = gdk_event_get_event_type(event)
        var x = Double(point.x), y = Double(point.y)
        if gdk_event_get_position(event, &x, &y) != 0 { point = graphene_point_t(x: Float(x), y: Float(y)) }
        var modifiers = gdk_event_get_modifier_state(event).rawValue
        if type == GDK_KEY_PRESS || type == GDK_KEY_RELEASE {
            let key = gdk_key_event_get_keyval(event)
            if key == UInt32(GDK_KEY_Control_L) || key == UInt32(GDK_KEY_Control_R) {
                if type == GDK_KEY_PRESS { modifiers |= GDK_CONTROL_MASK.rawValue } else { modifiers &= ~GDK_CONTROL_MASK.rawValue }
            }
        }
        let mask = GDK_CONTROL_MASK.rawValue | GDK_SHIFT_MASK.rawValue | GDK_ALT_MASK.rawValue | GDK_SUPER_MASK.rawValue
        let held = modifiers & mask == GDK_CONTROL_MASK.rawValue
        let panel = held ? panel(at: point) : nil
        let previous = Self.hovered
        if previous !== panel?.0 { previous?.mouseLeft() }
        Self.hovered = panel?.0
        if let (surface, local) = panel, let terminal = surface.surface {
            ghostty_surface_mouse_pos(terminal, Double(local.x), Double(local.y), ghosttyMods(modifiers))
        }
        if previous !== Self.hovered { controller?.activeSurface()?.applyMouseCursor() }
        if type == GDK_BUTTON_RELEASE, gdk_button_event_get_button(event) == 1, let pressed {
            self.pressed = nil
            click(pressed, event: event, modifiers: modifiers, state: GHOSTTY_MOUSE_RELEASE)
            return true
        }
        guard type == GDK_BUTTON_PRESS, gdk_button_event_get_button(event) == 1, let (surface, _) = panel else { return false }
        pressed = surface
        click(surface, event: event, modifiers: modifiers, state: GHOSTTY_MOUSE_PRESS)
        return true
    }

    private func panel(at point: graphene_point_t) -> (GhosttySurface, graphene_point_t)? {
        guard let controller, gWindows[controller.windowID] === controller, !controller.dashboard.isOpen,
              controller.terminalZoom.target == nil, !controller.pickController.modalPending,
              let id = controller.store.selectedSessionID, controller.store.session(withID: id)?.hudActive == true,
              let hud = controller.overlaySurfaces[id], gtk_widget_get_mapped(W(hud.glArea)) != 0,
              let hit = gtk_widget_pick(W(controller.windowPointer), Double(point.x), Double(point.y), GTK_PICK_DEFAULT) else { return nil }
        let panes = [controller.surfaces[id], controller.splitSurfaces[id], controller.scratchSurfaces[id]].compactMap { $0 }
        // The passive card also paints across the split handle; Ctrl links own that strip too.
        let overDivider = controller.sessionPanes[id].map { paned in
            hit == W(paned) || (gtk_widget_get_parent(hit) == W(paned)
                && hit != gtk_paned_get_start_child(paned) && hit != gtk_paned_get_end_child(paned))
        } ?? false
        guard overDivider || panes.contains(where: { hit == W($0.glArea) || gtk_widget_is_ancestor(hit, W($0.glArea)) != 0 }) else { return nil }
        var source = point, local = graphene_point_t()
        guard gtk_widget_compute_point(W(controller.windowPointer), W(hud.glArea), &source, &local) != 0,
              local.x >= 0, local.y >= 0, local.x < Float(gtk_widget_get_width(W(hud.glArea))),
              local.y < Float(gtk_widget_get_height(W(hud.glArea))) else { return nil }
        return (hud, local)
    }

    private func click(_ surface: GhosttySurface, event: OpaquePointer, modifiers: UInt32, state: ghostty_input_mouse_state_e) {
        guard let terminal = surface.surface else { return }
        surface.linkBrowserOverride = false
        _ = ghostty_surface_mouse_button(terminal, state, GHOSTTY_MOUSE_LEFT, ghosttyMods(modifiers))
    }
}

private let releaseHudLinkRouter: @convention(c) (gpointer?) -> Void = { data in
    if let data { Unmanaged<LinuxHudLinkRouter>.fromOpaque(data).release() }
}

private let onHudLinkEvent: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> gboolean = { _, event, data in
    guard let event, let data else { return 0 }
    return Unmanaged<LinuxHudLinkRouter>.fromOpaque(data).takeUnretainedValue().event(event) ? 1 : 0
}

@MainActor
extension GhosttySurface {
    func refreshLinkCursor() {
        applyMouseCursor()
        if role == .overlay, controller?.store.session(withID: sessionID)?.hudActive == true {
            controller?.activeSurface()?.applyMouseCursor()
        }
    }
}
