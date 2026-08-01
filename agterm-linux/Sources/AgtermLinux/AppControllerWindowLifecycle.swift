import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    /// This window gained focus — make it the target for global shortcuts + control commands.
    func becameFrontmost() {
        gController = self
        library.frontmostWindowID = windowID
        library.saveIndex()
        if let id = store.selectedSessionID, let session = store.session(withID: id) {
            let hadUnseen = session.unseenCount > 0
            store.clearUnseen(id)
            if hadUnseen {
                NotificationManager.withdraw(windowID: windowID, sessionID: id)
                rebuildSidebar()
            }
            // Reactivation can preempt a popover dismissal's own refocus, so it must be no coarser — and
            // must decline while a live search entry holds the keyboard.
            if searchEntryHoldsKeyboard() {
                showActive(focus: false)
            } else {
                showActiveFocusingVisibleSurface()
            }
            searchTargetSurface(for: id)?.refresh()
        }
    }

    /// Whether the window may close now, or should first confirm. Mirrors the macOS app-quit alert:
    /// closing the LAST open window quits the app + ends every running shell, so confirm that loss.
    /// A non-last window, an empty app, or an already-confirmed close proceeds immediately.
    func windowShouldClose() -> Bool {
        if confirmedClose { return true }
        let counts = library.openCounts()
        guard counts.windows <= 1, counts.sessions > 0 else { return true }
        let body = QuitPrompt.message(windows: counts.windows, sessions: counts.sessions)
        let dialog = OpaquePointer("Quit agterm?".withCString { h in body.withCString { b in adw_alert_dialog_new(h, b) } })
        attachControllerContext(to: dialog, windowID: windowID)
        "cancel".withCString { i in "Cancel".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "quit".withCString { i in "Quit".withCString { l in adw_alert_dialog_add_response(cast(dialog), i, l) } }
        "quit".withCString { adw_alert_dialog_set_response_appearance(cast(dialog), $0, ADW_RESPONSE_DESTRUCTIVE) }
        "cancel".withCString { adw_alert_dialog_set_close_response(cast(dialog), $0) }
        connect(dialog, "response", unsafeBitCast(onQuitResponse as @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, gpointer?) -> Void, to: GCallback.self))
        adw_dialog_present(cast(dialog), W(window))
        return false
    }

    /// The quit-confirm responded — re-issue the close on "quit"; stay open otherwise.
    func confirmQuit(_ response: String) {
        guard response == "quit" else { return }
        confirmedClose = true
        gtk_window_close(WIN(window))
    }

    /// The window is closing: capture its size for restore-on-reopen, then tear down its surfaces and
    /// drop it from the library + registry.
    func windowWillClose() {
        customCommandOrigin.invalidate()
        commitBackgroundOpacity()
        // `refocus: false` throughout: the widget tree is about to be destroyed, and the control pick's
        // deferred grab would fire after that against a finalized window.
        dismissSessionPicker(refocus: false)
        dismissControlPick(retainResultThroughRegistry: true, refocus: false)
        // Not optional cleanup: a popover left parented at destroy hangs the close, and GTK emits no
        // `"closed"` then, so this call is the only notice.
        dismissContextMenu(refocus: false)
        // EVERY dialog this window owns is dismissed here, or it outlives the widget tree and keeps the
        // controller alive with it — a bare toplevel (the theme picker, the palette) is not destroyed with
        // its transient parent under GTK4, and a hosted AdwDialog holds the same `passRetained` on "closed".
        // The theme picker's dismissal is a CANCELLATION (`cancelTheme` reverts the live preview and clears
        // the process-global override), never a bare close; it is inert with no picker up. Full rationale:
        // `.claude/rules/main-loop.md`.
        cancelTheme()
        closePalette()
        dismissSettings()
        dismissAuxiliaryDialogs()
        sidebarMetadataDebouncer.cancel()
        // These deferred jobs now really fire on Linux, and each outlives this window if something else
        // still holds the controller (an open Settings dialog, palette or theme picker retains it): a
        // pending layout save would `store.save()` after `removeWindow` deleted `windows/<id>.json` and
        // resurrect it as an orphan, a pending preview would set the theme override with no picker left to
        // clear it, and the trailing soft-close reconcile would rebuild an already-destroyed widget tree.
        layoutSaveDebouncer.cancel()
        themePreviewDebouncer.cancel()
        softCloseReconcile.cancel()
        // The post-rebuild selection re-publish would touch destroyed rows.
        selectionRepublish.cancel()
        // The soft-close grace finalizer is STORE-scoped, so none of the window-scoped cancels above reach
        // it. FINALIZE rather than cancel — cancelling strands the held records and leaks what only the
        // finalizer's teardown sweeps (see `.claude/rules/main-loop.md`).
        store.finalizeAllPendingCloses()
        cancelPendingWorkspaceToggle()
        cancelLeaderDeadlineForWindowClose()
        splitRatioRestore.cancelAll()
        cancelFullscreenTransitionTimeout()
        setTerminalZoom(.off, target: nil)
        TerminalZoomRegistry.shared.unregister(windowID)
        closeDashboard(refocus: false)
        DashboardControllerRegistry.shared.unregister(windowID)
        PickRegistry.shared.unregister(windowID)
        autoFollowCoordinator.stop()
        let w = gtk_widget_get_width(W(window)), h = gtk_widget_get_height(W(window))
        if w > 0, h > 0 { library.setGeometry(WindowGeometry.Size(width: Double(w), height: Double(h)), forWindow: windowID) }
        if linuxSettingsStore().load().restoreRunningCommand ?? false { captureForegroundCommands() }
        store.save()
        store.discardHudBodies()
        quickSurface?.teardown()
        quickSurface = nil
        quickFrame = nil
        for s in surfaces.values { s.teardown() }
        for s in splitSurfaces.values { s.teardown() }
        for s in scratchSurfaces.values { s.teardown() }
        for s in overlaySurfaces.values { s.teardown() }
        for s in leftOverlaySurfaces.values { s.teardown() }
        for s in rightOverlaySurfaces.values { s.teardown() }
        library.closeWindow(windowID)
        gWindows[windowID] = nil
        if gController === self { gController = gWindows.values.first }
    }
}
