import CGtk
import Foundation

// MARK: - GTK trampolines

@MainActor
final class DirectoryChooserContext {
    let controller: AppController
    let workspaceID: UUID

    init(controller: AppController, workspaceID: UUID) {
        self.controller = controller
        self.workspaceID = workspaceID
    }
}

let onWindowActive: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { window, _, _ in
    guard let window else { return }
    MainActor.assumeIsolated {
        // GTK emits is-active while unmapping a closing window. windowWillClose removes its controller
        // from gWindows before that notification, so resolve through the live registry instead of
        // dereferencing unretained signal data that may already be deallocated.
        guard let ctl = gWindows.values.first(where: { $0.windowPointer == window }) else { return }
        if gtk_window_is_active(WIN(window)) != 0 {
            ctl.becameFrontmost()
            ctl.applyInactiveWindowSidebarHidingIfEnabled()
        }
    }
}

let onWindowFullscreened: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { window, _, _ in
    guard let window else { return }
    MainActor.assumeIsolated {
        gWindows.values.first(where: { $0.windowPointer == window })?.fullscreenStateDidChange()
    }
}

let onFullscreenTransitionTimeout: @MainActor @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue().fullscreenTransitionDidTimeout()
    }
    return 0
}

let onWindowCloseRequest: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> gboolean = { _, data in
    guard let data else { return 0 }
    let ctl = Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue()
    let allow = MainActor.assumeIsolated { ctl.windowShouldClose() }
    guard allow else { return 1 }
    MainActor.assumeIsolated { ctl.windowWillClose() }
    return 0
}

let onEmptyWindowKeyPressed: @MainActor @convention(c)
    (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { controller, keyval, keycode, state, _ in
        MainActor.assumeIsolated {
            guard let owner = controllerForEventController(controller), owner.store.activeSession == nil else {
                return 0
            }
            let event = controller.flatMap { gtk_event_controller_get_current_event($0) }
            return owner.handleKey(
                keyval: keyval,
                keycode: keycode,
                state: state,
                sessionID: UUID(),
                origin: nil,
                context: shortcutKeyContext(event: event, keycode: keycode)
            ) ? 1 : 0
    }
}

@MainActor
func installEmptyWindowKeyController(on window: OpaquePointer?) {
    let keys = gtk_event_controller_key_new()
    connect(keys, "key-pressed", unsafeBitCast(onEmptyWindowKeyPressed as @convention(c)
        (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self))
    gtk_widget_add_controller(W(window), keys)
}

/// `GtkOverlay::get-child-position` on the deck overlay: hands the quick-terminal card an EXPLICIT
/// rectangle every layout pass, so it stays at `LinuxQuickCardPolicy.cardSizePercent`% of the window
/// content below the header (macOS parity) and follows a live window resize, instead of the fixed pixel
/// margins it used to carry. The math itself is host-free in `LinuxQuickCardPolicy.cardAllocation`.
///
/// Signal contract. `get-child-position` is declared `when="last"` with a BOOLEAN-HANDLED accumulator,
/// and `connect()` (`GtkInterop.swift`) uses `g_signal_connect_data` with flags 0 — NOT `G_CONNECT_AFTER`.
/// An AFTER connection would never run here: the class default returns TRUE for every child and the
/// accumulator ends the emission at that point. Returning 0 (FALSE) falls through to GTK's default,
/// alignment-based placement.
///
/// This handler answers ONLY for `quickFrame`. EVERY other `deckOverlay` child returns 0 and keeps its
/// default placement: the per-session floating overlay frames (`AppControllerSurfaces.syncOverlay`), the
/// zoom host (`AppControllerZoom`), the dashboard host (`AppControllerDashboard`), the Ctrl-Tab switcher
/// box, and the GL-error label (both in `AppController`). The zoom case is load-bearing — zooming `.quick`
/// HIDES `quickFrame` and adds a FILL/expand `zoomHost`, which must never be given the card rectangle.
///
/// Coordinates. GTK documents the returned allocation as relative to the overlay's MAIN child. Here that
/// is the same as overlay coordinates, because the main child is the sidebar `GtkPaned` sitting at 0,0 at
/// full size (the documented exception is a `GtkScrolledWindow` main child, which this is not).
///
/// The frame keeps `GTK_ALIGN_FILL` and zero margins on purpose (`AppController.setQuick`):
/// `gtk_widget_size_allocate` re-applies align + margins INSIDE the rectangle returned here, so copying
/// `syncOverlay`'s `GTK_ALIGN_CENTER` would collapse the card back to its natural size and silently defeat
/// the explicit allocation.
///
/// Teardown is covered by the usual registry recovery: `controllerForWidget` resolves through `gWindows`,
/// which `windowWillClose` has already left, so a late emission on a closing window falls through to the
/// default placement instead of touching a freed controller. A nil `quickFrame` does the same; a HIDDEN
/// one (the zoomed `.quick` case) is not laid out at all, so GTK never emits the signal for it.
let onDeckOverlayChildPosition: @MainActor @convention(c)
    (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<GdkRectangle>?, gpointer?) -> gboolean = { overlay, child, allocation, _ in
        MainActor.assumeIsolated {
            guard let overlay, let child, let allocation,
                  let controller = controllerForWidget(overlay),
                  let quick = controller.quickFrame, quick == child else { return 0 }
            // Measure the header only while it is SHOWN: a hidden-but-previously-allocated GTK4 widget
            // retains its last allocated height, so hidden-toolbar mode would otherwise inset the card by
            // a strip that is not on screen. No header at all ⇒ 0. The policy cannot see visibility.
            let headerHeight = controller.contentHeader.map { gtk_widget_get_visible(W($0)) != 0 ? gtk_widget_get_height(W($0)) : 0 } ?? 0
            let card = LinuxQuickCardPolicy.cardAllocation(overlayWidth: gtk_widget_get_width(W(overlay)),
                                                           overlayHeight: gtk_widget_get_height(W(overlay)),
                                                           headerHeight: headerHeight)
            // Assigned WHOLE: GTK passes an uninitialized stack rectangle, so a field-by-field fill that
            // ever misses one yields garbage rather than a default.
            allocation.pointee = GdkRectangle(x: card.x, y: card.y, width: card.width, height: card.height)
            return 1
        }
}

/// Install the quick-card placement handler on the deck overlay; the cast is long enough that it stays out
/// of `AppController`, mirroring `installEmptyWindowKeyController` above.
@MainActor
func installQuickCardPlacement(on overlay: OpaquePointer?) {
    connect(overlay, "get-child-position", unsafeBitCast(onDeckOverlayChildPosition as @convention(c)
        (OpaquePointer?, OpaquePointer?, UnsafeMutablePointer<GdkRectangle>?, gpointer?) -> gboolean, to: GCallback.self))
}

let onQuitResponse: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { controllerForWidget(dialog)?.confirmQuit(id) }
}

let onCloseSessionResponse: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { controllerForWidget(dialog)?.confirmSessionClose(id) }
}

let onNewSession: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.newSession() }
}

let onNewWorkspace: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.newWorkspace() }
}

let onWorkspaceAddSession: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated {
        guard let controller = controllerForWidget(button),
              let workspace = controller.workspaceForHeader(button) else { return }
        controller.newSession(in: workspace)
    }
}

let onSidebarToggle: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleSidebar() }
}

let onSplitToggle: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleSplit() }
}

let onScratchToggle: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleScratch() }
}

let onQuickToggle: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleQuick() }
}

let onDashboardToggle: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleDashboard() }
}

let onNewWindow: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.openNewWindow() }
}

let onFlaggedToggle: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleFlaggedView() }
}

let onWorkspaceFilterToggle: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleWorkspaceFilter() }
}

let onAttentionButton: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.showSessionPicker(attention: true, anchor: button) }
}

let onRecentSessionsButton: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.showSessionPicker(attention: false, anchor: button) }
}

let onRowActivated: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { list, row, _ in
    MainActor.assumeIsolated {
        guard let controller = controllerForWidget(list), let id = controller.session(forRow: row) else { return }
        controller.selectSession(id)
    }
}

let onSessionRowClick: @MainActor @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, presses, _, _, data in
    guard presses == 1, let gesture, let data else { return }
    MainActor.assumeIsolated {
        guard let controller = controllerForEventController(gesture),
              let id = controller.session(forRow: OpaquePointer(data)) else { return }
        let modifiers = gtk_event_controller_get_current_event_state(gesture).rawValue
        gtk_gesture_set_state(gesture, GTK_EVENT_SEQUENCE_CLAIMED)
        controller.handleSessionRowClick(id, modifiers: modifiers)
    }
}

let onRowRightClick: @MainActor @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { _, _, x, y, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        controllerForWidget(OpaquePointer(data))?.showRowContextMenu(listBox: OpaquePointer(data), x: x, y: y)
    }
}

let onWorkspaceDisclosure: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, data in
    MainActor.assumeIsolated { controllerForWidget(button)?.toggleWorkspaceCollapse(data) }
}

let onWorkspaceRowClick: @MainActor @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, nPress, x, y, data in
    MainActor.assumeIsolated {
        let controller = controllerForEventController(gesture)
        guard nPress == 1 else {
            controller?.cancelPendingWorkspaceToggle()
            return
        }
        if let gesture, let row = gtk_event_controller_get_widget(gesture),
           let picked = gtk_widget_pick(row, x, y, GTK_PICK_DEFAULT),
           gtk_widget_get_ancestor(picked, gtk_button_get_type()) != nil {
            return
        }
        controller?.scheduleWorkspaceToggle(data)
    }
}

let onWorkspaceToggleTimeout: @MainActor @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    return MainActor.assumeIsolated {
        Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue().firePendingWorkspaceToggle()
    }
}

let onRowDragPrepare: @MainActor @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer? = { source, _, _, _ in
    let uuid: String? = MainActor.assumeIsolated {
        guard let w = gtk_event_controller_get_widget(source) else { return nil }
        return controllerForEventController(source)?.session(forRow: OpaquePointer(w))?.uuidString
    }
    guard let uuid else { return nil }
    var v = GValue()
    _ = g_value_init(&v, GType(64))
    uuid.withCString { g_value_set_string(&v, $0) }
    let provider = gdk_content_provider_new_for_value(&v)
    g_value_unset(&v)
    return provider.map { OpaquePointer($0) }
}

let onRowDrop: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { target, value, _, _, _ in
    MainActor.assumeIsolated {
        guard let value, let cstr = g_value_get_string(value),
              let w = gtk_event_controller_get_widget(target),
              let controller = controllerForEventController(target),
              let targetSid = controller.session(forRow: OpaquePointer(w)),
              let sourceSid = UUID(uuidString: String(cString: cstr)) else { return 0 }
        controller.handleSessionDrop(source: sourceSid, onto: targetSid)
        return 1
    }
}

let onHeaderDragPrepare: @MainActor @convention(c) (OpaquePointer?, Double, Double, gpointer?) -> OpaquePointer? = { source, _, _, _ in
    MainActor.assumeIsolated { controllerForEventController(source)?.cancelPendingWorkspaceToggle() }
    let payload: String? = MainActor.assumeIsolated {
        guard let w = gtk_event_controller_get_widget(source) else { return nil }
        return controllerForEventController(source)?.workspaceForHeader(OpaquePointer(w)).map { "w:\($0.uuidString)" }
    }
    guard let payload else { return nil }
    var v = GValue()
    _ = g_value_init(&v, GType(64))
    payload.withCString { g_value_set_string(&v, $0) }
    let provider = gdk_content_provider_new_for_value(&v)
    g_value_unset(&v)
    return provider.map { OpaquePointer($0) }
}

let onHeaderDrop: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { target, value, _, _, _ in
    MainActor.assumeIsolated {
        guard let value, let cstr = g_value_get_string(value),
              let w = gtk_event_controller_get_widget(target),
              let controller = controllerForEventController(target),
              let targetWS = controller.workspaceForHeader(OpaquePointer(w)) else { return 0 }
        let s = String(cString: cstr)
        if s.hasPrefix("w:"), let src = UUID(uuidString: String(s.dropFirst(2))) {
            controller.handleWorkspaceDrop(source: src, onto: targetWS)
        } else if let src = UUID(uuidString: s) {
            controller.handleSessionToWorkspace(session: src, workspace: targetWS)
        }
        return 1
    }
}

let onSidebarDirectoryDrop: @MainActor @convention(c)
    (OpaquePointer?, UnsafePointer<GValue>?, Double, Double, gpointer?) -> gboolean = { target, value, _, _, _ in
    MainActor.assumeIsolated {
        guard let target, let value, let boxed = g_value_get_boxed(value),
              let widget = gtk_event_controller_get_widget(target) else { return 0 }
        let files = gdk_file_list_get_files(OpaquePointer(boxed))
        defer { if let files { g_slist_free(files) } }
        var paths: [String] = []
        var node = files
        while let current = node {
            if let data = current.pointee.data,
               let cpath = g_file_get_path(OpaquePointer(data)) {
                paths.append(String(cString: cpath))
                g_free(cpath)
            }
            node = current.pointee.next
        }
        return controllerForEventController(target)?.handleDirectoryDrop(
            paths, onto: OpaquePointer(widget)) == true ? 1 : 0
    }
}

let onDeleteWorkspaceResponse: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { controllerForWidget(dialog)?.confirmWorkspaceDelete(id) }
}

let onDeleteWindowResponse: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { controllerForWidget(dialog)?.confirmWindowDelete(id) }
}

let onRenameWindowResponse: @MainActor @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void = { dialog, response, _ in
    let id = response.map { String(cString: $0) } ?? "cancel"
    MainActor.assumeIsolated { controllerForWidget(dialog)?.confirmWindowRename(id) }
}

let onDirectoryChosen: @MainActor @convention(c) (UnsafeMutablePointer<GObject>?, OpaquePointer?, gpointer?) -> Void = { source, result, data in
    guard let data else { return }
    MainActor.assumeIsolated {
        let context = Unmanaged<DirectoryChooserContext>.fromOpaque(data).takeRetainedValue()
        defer { context.controller.resumeAutoFollow() }
        guard gWindows[context.controller.windowID] === context.controller else { return }
        guard let file = gtk_file_dialog_select_folder_finish(
            source.map { OpaquePointer($0) }, result, nil) else { return }
        defer { g_object_unref(RAW(file)) }
        guard let cpath = g_file_get_path(file) else { return }
        let path = String(cString: cpath)
        g_free(cpath)
        context.controller.createSessionInDirectory(path, workspaceID: context.workspaceID)
    }
}

let onCtxFlag: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextFlag() }
}

let onCtxFocus: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextFocusWorkspace() }
}

let onCtxMove: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, data in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextMoveToWorkspace(data) }
}

let onCtxRename: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextRename() }
}

let onCtxCopyName: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextCopyName() }
}

let onCtxDuplicate: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextDuplicate() }
}

let onCtxRevealDirectory: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextRevealDirectory() }
}

let onCtxClearStatus: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextClearStatus() }
}

let onCtxClose: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextCloseSession() }
}

let onMenuButton: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.showPalette() }
}

let onNameDoubleClick: @MainActor @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, nPress, _, _, data in
    guard nPress == 2 else { return }
    MainActor.assumeIsolated { controllerForEventController(gesture)?.beginRenameFromLabel(data) }
}

let onRenameCommit: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { _, data in
    MainActor.assumeIsolated {
        controllerForWidget(data.map { OpaquePointer($0) })?.commitInlineRename(data)
    }
}

let onRenameKey: @MainActor @convention(c) (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { keys, keyval, _, _, _ in
    guard keyval == 0xFF1B else { return 0 }
    MainActor.assumeIsolated { controllerForEventController(keys)?.cancelInlineRename() }
    return 1
}

let onWorkspaceRightClick: @MainActor @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, _, x, y, data in
    MainActor.assumeIsolated {
        controllerForEventController(gesture)?.showWorkspaceContextMenu(data, x: x, y: y)
    }
}

let onCtxWorkspaceRename: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextWorkspaceRename() }
}

let onCtxWorkspaceCopyName: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextWorkspaceCopyName() }
}

let onCtxWorkspaceFocus: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextWorkspaceFocus() }
}

let onCtxWorkspaceFocusMembership: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextWorkspaceFocusMembership() }
}

let onCtxWorkspaceDelete: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated { controllerForWidget(button)?.contextWorkspaceDelete() }
}

let onPanedPosition: @MainActor @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void = { paned, _, _ in
    MainActor.assumeIsolated { controllerForWidget(paned)?.capturePanedRatio(paned) }
}

let onPanedDoubleClick: @MainActor @convention(c) (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { gesture, presses, x, _, _ in
    guard presses == 2 else { return }
    MainActor.assumeIsolated { controllerForEventController(gesture)?.resetSplitRatio(gesture, x: x) }
}

let restorePanedRatioTick: @MainActor @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    return MainActor.assumeIsolated {
        let context = Unmanaged<SplitRatioRestoreTickContext>.fromOpaque(data).takeUnretainedValue()
        return context.controller?.tryRestorePanedRatio(
            windowID: context.windowID, sessionID: context.sessionID,
            paned: context.paned, generation: context.generation) ?? 0
    }
}

let releaseSplitRatioRestoreTick: GDestroyNotify = { data in
    guard let data else { return }
    Unmanaged<SplitRatioRestoreTickContext>.fromOpaque(data).release()
}
