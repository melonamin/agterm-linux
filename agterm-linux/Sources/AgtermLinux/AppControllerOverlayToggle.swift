import CGtk
import agtermCore

@MainActor
extension AppController {
    func installOverlayToggle(in header: OpaquePointer?) {
        interfaceWidgets[.overlayToggle] = linuxHeaderToggle(header, "view-restore-symbolic",
            LinuxChromeTooltip.text("Overlays", .toggleOverlay), onOverlayToggle)
        updateOverlayToggle()
    }

    func updateOverlayToggle() {
        guard let button = interfaceWidgets[.overlayToggle] else { return }
        let session = store.selectedSessionID.flatMap(store.session(withID:))
        let slots = session?.hideableOverlaySlots(nil) ?? []
        gtk_widget_set_sensitive(W(button), !slots.isEmpty && terminalZoom.target == nil && !dashboard.isOpen ? 1 : 0)
        let hidden = session.map { session in slots.contains { session.overlayHidden($0) } } ?? false
        gtk_button_set_icon_name(cast(button), hidden ? "view-reveal-symbolic" : "view-restore-symbolic")
    }
}

private let onOverlayToggle: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    guard let controller = controllerForWidget(button) else { return }
    _ = controller.setSessionOverlayVisibility(nil, window: nil, pane: nil, mode: .toggle)
}
