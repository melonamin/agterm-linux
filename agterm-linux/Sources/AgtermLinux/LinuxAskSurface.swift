import CGtk
import Foundation
import agtermCore

@MainActor
final class LinuxAskSurface {
    let askID: String
    let root: OpaquePointer
    var buttons: [OpaquePointer]
    var navigation: AskNavigation

    init(ask: PendingAsk, root: OpaquePointer, buttons: [OpaquePointer]) {
        askID = ask.id
        self.root = root
        self.buttons = buttons
        navigation = AskNavigation(buttons: ask.buttons, defaultID: ask.defaultID,
                                   destructiveID: ask.destructiveID)
    }

    func focusSelection() {
        guard let index = navigation.highlighted, buttons.indices.contains(index) else { return }
        _ = gtk_widget_grab_focus(W(buttons[index]))
    }
}

@MainActor
extension AppController {
    func showGUIAsk(_ ask: PendingAsk) -> Bool {
        guard guiAskWindow == nil else { return false }
        guard let win = op(gtk_window_new()) else { return false }
        guard let panel = buildAskPanel(ask) else {
            gtk_window_destroy(WIN(win))
            return false
        }
        guiAskWindow = win
        suppressAutoFollow()
        guiAskSuppressesAutoFollow = true
        attachControllerContext(to: win, windowID: windowID)
        gtk_window_set_transient_for(WIN(win), WIN(windowPointer))
        gtk_window_set_modal(WIN(win), 1)
        ask.title.withCString { gtk_window_set_title(WIN(win), $0) }
        let width = ask.width.map { max(280, gtk_widget_get_width(W(windowPointer)) * Int32($0) / 100) } ?? 480
        gtk_window_set_default_size(WIN(win), width, -1)
        gtk_window_set_child(WIN(win), W(panel.root))
        connect(win, "close-request", unsafeBitCast(onGUIAskClose as @convention(c)
            (OpaquePointer?, gpointer?) -> gboolean, to: GCallback.self))
        connect(win, "destroy", unsafeBitCast(onGUIAskDestroyed as @convention(c)
            (OpaquePointer?, gpointer?) -> Void, to: GCallback.self),
            Unmanaged.passRetained(self).toOpaque())
        installAskKeyController(on: win)
        guiAskButtons = panel.buttons
        guiAskNavigation = panel.navigation
        closePalette()
        gtk_window_present(WIN(win))
        focusGUIAskSelection()
        return true
    }

    func dismissGUIAsk() {
        guard let win = guiAskWindow else { return }
        guiAskWindow = nil
        finishGUIAskAutoFollowSuppression()
        replicaGUIAskSessionID = nil
        guiAskButtons = []
        guiAskNavigation = nil
        gtk_window_destroy(WIN(win))
    }

    func guiAskWasDestroyed() {
        guard guiAskWindow != nil else { return }
        guiAskWindow = nil
        finishGUIAskAutoFollowSuppression()
        guiAskButtons = []
        guiAskNavigation = nil
        if let id = replicaGUIAskSessionID {
            replicaGUIAskSessionID = nil
            if let ask = store.session(withID: id)?.askPending {
                store.session(withID: id)?.resolveAsk(id: ask.id, ControlAskResult(result: .escaped))
            }
        } else {
            pickController.escapeAsk()
        }
    }

    private func finishGUIAskAutoFollowSuppression() {
        guard guiAskSuppressesAutoFollow else { return }
        guiAskSuppressesAutoFollow = false
        resumeAutoFollow()
    }

    func escapeGUIAsk() {
        if let id = replicaGUIAskSessionID, let ask = store.session(withID: id)?.askPending {
            store.session(withID: id)?.resolveAsk(id: ask.id, ControlAskResult(result: .escaped))
        } else {
            guard pickController.pendingAsk != nil else { return }
            pickController.escapeAsk()
        }
        dismissGUIAsk()
    }

    private func focusGUIAskSelection() {
        guard let index = guiAskNavigation?.highlighted,
              guiAskButtons.indices.contains(index) else { return }
        _ = gtk_widget_grab_focus(W(guiAskButtons[index]))
    }

    func syncAskSurfaces() {
        if let id = replicaGUIAskSessionID {
            let session = store.session(withID: id)
            let paneVisible = session.map { candidate in
                candidate.askPaneIdentity == nil || candidate.askTargetPane.map(candidate.rendersPane) == true
            } ?? false
            let valid = session?.askPending?.style == .gui && store.selectedSessionID == id
                && !dashboard.isOpen && terminalZoom.target == nil && !pickController.modalPending
                && paneVisible
            if !valid {
                if let ask = session?.askPending {
                    session?.resolveAsk(id: ask.id, ControlAskResult(result: .cancelled))
                }
                dismissGUIAsk()
            }
        }
        if let ask = pickController.pendingAsk, let anchor = ask.anchor {
            let valid = store.selectedSessionID == anchor.sessionID && terminalZoom.target == nil
                && !dashboard.isOpen && store.session(withID: anchor.sessionID).map { session in
                    guard let identity = anchor.paneIdentity else { return true }
                    guard let pane = session.paneRole(forIdentity: identity) else { return false }
                    return session.rendersPane(pane)
                } == true
            if !valid {
                pickController.cancelAsk()
                dismissGUIAsk()
            }
        }
        for (id, surface) in terminalAskSurfaces {
            guard store.session(withID: id)?.askPending?.id == surface.askID else {
                removeTerminalAskSurface(id)
                continue
            }
        }
        for session in store.workspaces.flatMap(\.sessions) {
            guard let ask = session.askPending, ask.style == .terminal,
                  !session.askPresentedRemotely else { continue }
            let visible = store.selectedSessionID == session.id && terminalZoom.target == nil
                && !dashboard.isOpen && (session.askPaneIdentity == nil || !session.scratchActive)
                && (session.askPaneIdentity == nil || session.askTargetPane.map(session.rendersPane) == true)
                && !pickController.modalPending && paletteWindow == nil
            let newlyCreated = terminalAskSurfaces[session.id] == nil
            let host = askHost(for: session)
            let focusWasInRegion = host.flatMap { host in
                gtk_window_get_focus(WIN(windowPointer)).map { focus in
                    gtk_widget_is_ancestor(focus, W(host)) != 0
                }
            } == true && !searchEntryHoldsKeyboard()
            if terminalAskSurfaces[session.id] == nil {
                guard let host, let panel = buildAskPanel(ask) else { continue }
                gtk_overlay_add_overlay(host, W(panel.root))
                terminalAskSurfaces[session.id] = panel
                installAskKeyController(on: panel.root)
            }
            guard let surface = terminalAskSurfaces[session.id] else { continue }
            let wasVisible = !newlyCreated && gtk_widget_get_visible(W(surface.root)) != 0
            if let host,
               let parent = gtk_widget_get_parent(W(surface.root)), OpaquePointer(parent) != host {
                g_object_ref(RAW(surface.root))
                gtk_overlay_remove_overlay(OpaquePointer(parent), W(surface.root))
                gtk_overlay_add_overlay(host, W(surface.root))
                g_object_unref(RAW(surface.root))
            }
            gtk_widget_set_visible(W(surface.root), visible ? 1 : 0)
            if visible, newlyCreated || !wasVisible, focusWasInRegion,
               gtk_window_is_active(WIN(windowPointer)) != 0 { surface.focusSelection() }
        }
    }

    private func askHost(for session: Session) -> OpaquePointer? {
        switch session.askTargetPane {
        case .left: primaryPaneHosts[session.id]
        case .right: splitPaneHosts[session.id]
        case nil: deck
        }
    }

    func removeTerminalAskSurface(_ id: UUID) {
        guard let surface = terminalAskSurfaces.removeValue(forKey: id) else { return }
        if let parent = gtk_widget_get_parent(W(surface.root)) {
            gtk_overlay_remove_overlay(OpaquePointer(parent), W(surface.root))
        }
    }

    func answerAskButton(_ button: OpaquePointer?) {
        guard let button, let name = gtk_widget_get_name(W(button)),
              let index = Int(String(cString: name).replacingOccurrences(of: "ask-button-", with: "")) else { return }
        if let win = guiAskWindow, gtk_widget_is_ancestor(W(button), W(win)) != 0,
           let ask = pickController.pendingAsk, ask.buttons.indices.contains(index) {
            let choice = ask.buttons[index]
            pickController.resolveAsk(ControlAskResult(result: .answered, id: choice.id,
                                                        label: choice.label, index: index))
            dismissGUIAsk()
            return
        }
        if let win = guiAskWindow, gtk_widget_is_ancestor(W(button), W(win)) != 0,
           let id = replicaGUIAskSessionID, let session = store.session(withID: id),
           let ask = session.askPending, ask.buttons.indices.contains(index) {
            let choice = ask.buttons[index]
            session.resolveAsk(id: ask.id, ControlAskResult(result: .answered, id: choice.id,
                                                             label: choice.label, index: index))
            dismissGUIAsk()
            return
        }
        for (id, surface) in terminalAskSurfaces where gtk_widget_is_ancestor(W(button), W(surface.root)) != 0 {
            guard let session = store.session(withID: id), let ask = session.askPending,
                  ask.id == surface.askID, ask.buttons.indices.contains(index) else { return }
            let choice = ask.buttons[index]
            session.resolveAsk(id: ask.id, ControlAskResult(result: .answered, id: choice.id,
                                                           label: choice.label, index: index))
            removeTerminalAskSurface(id)
            return
        }
    }

    func handleAskKey(_ widget: OpaquePointer?, key: UInt32, modifiers: UInt32) -> Bool {
        guard let widget else { return false }
        if let win = guiAskWindow, widget == win,
           let ask = pickController.pendingAsk ?? replicaGUIAskSessionID.flatMap({ store.session(withID: $0)?.askPending }) {
            if key == 0xFF1B { escapeGUIAsk(); return true }
            guard var navigation = guiAskNavigation else { return false }
            if key == 0xFF09 || key == 0xFE20 {
                if key == 0xFE20 || modifiers & UInt32(GDK_SHIFT_MASK.rawValue) != 0 {
                    navigation.moveBackward()
                } else { navigation.moveForward() }
                guiAskNavigation = navigation
                focusGUIAskSelection()
                return true
            }
            if key == 0xFF0D || key == 0xFF8D {
                if let index = navigation.activate(), guiAskButtons.indices.contains(index) {
                    answerAskButton(guiAskButtons[index])
                }
                return true
            }
            if let scalar = UnicodeScalar(key), let index = navigation.hotkey(String(scalar)),
               ask.buttons.indices.contains(index) { answerAskButton(guiAskButtons[index]); return true }
            return false
        }
        for (id, surface) in terminalAskSurfaces where widget == surface.root {
            if key == 0xFF1B {
                store.session(withID: id)?.resolveAsk(id: surface.askID, ControlAskResult(result: .escaped))
                removeTerminalAskSurface(id)
                return true
            }
            if key == 0xFF09 || key == 0xFE20 {
                if key == 0xFE20 || modifiers & UInt32(GDK_SHIFT_MASK.rawValue) != 0 {
                    surface.navigation.moveBackward()
                } else { surface.navigation.moveForward() }
                surface.focusSelection()
                return true
            }
            if key == 0xFF0D || key == 0xFF8D {
                if let index = surface.navigation.activate(), surface.buttons.indices.contains(index) {
                    answerAskButton(surface.buttons[index])
                }
                return true
            }
            if let scalar = UnicodeScalar(key), let index = surface.navigation.hotkey(String(scalar)),
               surface.buttons.indices.contains(index) { answerAskButton(surface.buttons[index]); return true }
            return false
        }
        return false
    }

    private func buildAskPanel(_ ask: PendingAsk) -> LinuxAskSurface? {
        guard let root = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)),
              let frame = op(gtk_frame_new(nil)),
              let content = op(gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)) else { return nil }
        gtk_widget_add_css_class(W(frame), "agterm-interface-panel")
        gtk_widget_add_css_class(W(frame), "card")
        gtk_widget_set_halign(W(frame), GTK_ALIGN_CENTER)
        gtk_widget_set_valign(W(frame), GTK_ALIGN_CENTER)
        gtk_widget_set_margin_top(W(frame), 16)
        gtk_widget_set_margin_bottom(W(frame), 16)
        gtk_widget_set_margin_start(W(frame), 16)
        gtk_widget_set_margin_end(W(frame), 16)
        if let width = ask.width, ask.style == .terminal {
            let anchorWidth = max(320, gtk_widget_get_width(W(deck)))
            gtk_widget_set_size_request(W(frame), anchorWidth * Int32(width) / 100, -1)
        }
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(W(content), 16)
        }
        if let title = op(gtk_label_new(ask.title)) {
            gtk_label_set_xalign(title, 0)
            gtk_label_set_wrap(title, 1)
            gtk_widget_add_css_class(W(title), "heading")
            if ask.style == .terminal { gtk_widget_add_css_class(W(title), "monospace") }
            gtk_box_append(cast(content), W(title))
        }
        if let message = ask.message, !message.isEmpty, let label = op(gtk_label_new(message)) {
            gtk_label_set_xalign(label, 0)
            gtk_label_set_wrap(label, 1)
            if ask.style == .terminal { gtk_widget_add_css_class(W(label), "monospace") }
            gtk_box_append(cast(content), W(label))
        }
        let row = op(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8))
        let align: GtkAlign = switch ask.align {
        case .left: GTK_ALIGN_START
        case .center: GTK_ALIGN_CENTER
        case .right: GTK_ALIGN_END
        }
        gtk_widget_set_halign(W(row), align)
        var buttons: [OpaquePointer] = []
        for (index, choice) in ask.buttons.enumerated() {
            guard let button = op(gtk_button_new_with_label(choice.label)) else { continue }
            "ask-button-\(index)".withCString { gtk_widget_set_name(W(button), $0) }
            if choice.id == ask.destructiveID { gtk_widget_add_css_class(W(button), "destructive-action") }
            if ask.style == .terminal { gtk_widget_add_css_class(W(button), "monospace") }
            connect(button, "clicked", unsafeBitCast(onAskButton as @convention(c)
                (OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
            gtk_box_append(cast(row), W(button))
            buttons.append(button)
        }
        gtk_box_append(cast(content), W(row))
        gtk_frame_set_child(cast(frame), W(content))
        gtk_box_append(cast(root), W(frame))
        gtk_widget_set_halign(W(root), GTK_ALIGN_FILL)
        gtk_widget_set_valign(W(root), GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(W(root), 1)
        gtk_widget_set_vexpand(W(root), 1)
        gtk_widget_set_focusable(W(root), 1)
        attachControllerContext(to: root, windowID: windowID)
        return LinuxAskSurface(ask: ask, root: root, buttons: buttons)
    }

    private func installAskKeyController(on widget: OpaquePointer) {
        let keys = gtk_event_controller_key_new()
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        connect(keys, "key-pressed", unsafeBitCast(onAskKey as @convention(c)
            (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self))
        gtk_widget_add_controller(W(widget), keys)
    }
}

private let onAskButton: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.answerAskButton(button) }
}

private let onAskKey: @MainActor @convention(c)
    (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { keys, key, _, modifiers, _ in
        MainActor.assumeIsolated {
            guard let widget = gtk_event_controller_get_widget(keys),
                  let controller = controllerForWidget(OpaquePointer(widget)) else { return 0 }
            return controller.handleAskKey(OpaquePointer(widget), key: key, modifiers: modifiers) ? 1 : 0
        }
    }

private let onGUIAskClose: @MainActor @convention(c)
    (OpaquePointer?, gpointer?) -> gboolean = { window, _ in
        MainActor.assumeIsolated { controllerForWidget(window)?.escapeGUIAsk() }
        return 1
    }

private let onGUIAskDestroyed: @MainActor @convention(c)
    (OpaquePointer?, gpointer?) -> Void = { _, data in
        guard let data else { return }
        MainActor.assumeIsolated {
            Unmanaged<AppController>.fromOpaque(data).takeRetainedValue().guiAskWasDestroyed()
        }
    }
