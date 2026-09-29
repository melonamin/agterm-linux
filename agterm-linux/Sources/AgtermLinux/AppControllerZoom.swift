import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    static func zoomTargetToRehostAfterPrimaryPanePromotion(
        _ target: TerminalZoomTarget, sessionID: UUID
    ) -> TerminalZoomTarget? {
        switch target {
        case .session(let id, .primary) where id == sessionID: .session(sessionID, .primary)
        case .session(let id, .split) where id == sessionID: .session(sessionID, .primary)
        case .session(let id, .overlayLeft) where id == sessionID: .session(sessionID, .overlayLeft)
        case .session(let id, .overlayRight) where id == sessionID: .session(sessionID, .overlayLeft)
        default: nil
        }
    }

    func suspendTerminalZoomForPrimaryPanePromotion(_ sessionID: UUID) -> TerminalZoomTarget? {
        guard let target = terminalZoom.target,
              let promoted = Self.zoomTargetToRehostAfterPrimaryPanePromotion(
                target, sessionID: sessionID) else { return nil }
        setTerminalZoom(.off, target: target)
        return promoted
    }

    func resumeTerminalZoomAfterPrimaryPanePromotion(_ target: TerminalZoomTarget?) {
        if let target { setTerminalZoom(.on, target: target) }
    }

    func clearInvalidTerminalZoom() {
        guard let target = terminalZoom.target,
              !linuxZoomTargetIsValid(target) else {
            return
        }
        setTerminalZoom(.off, target: target, resync: false)   // reconcile, the only caller, resyncs next
    }

    func linuxZoomTargetIsValid(_ target: TerminalZoomTarget) -> Bool {
        if target == .quick { return quickVisible && quickSurface?.isRealized == true }
        return TerminalZoomController.isTargetValid(target, in: store)
    }

    func surface(for target: TerminalZoomTarget) -> GhosttySurface? {
        switch target {
        case .quick: return quickSurface
        case .session(let id, .primary): return surfaces[id]
        case .session(let id, .split): return splitSurfaces[id]
        case .session(let id, .scratch): return scratchSurfaces[id]
        case .session(let id, .overlay): return overlaySurfaces[id]
        case .session(let id, .overlayLeft): return leftOverlaySurfaces[id]
        case .session(let id, .overlayRight): return rightOverlaySurfaces[id]
        }
    }

    /// Zoom is LAYOUT ONLY: the zoomed terminal never leaves its pane host. Unparenting a live GtkGLArea
    /// destroys its GL context for good, leaving the pane blank even after the exit ([[libghostty]]),
    /// so instead the sidebar column and the content header are hidden, `zoomHeader` takes the header's
    /// place, the target session's deck page is presented, and its sibling pane is hidden — the same
    /// visibility-only maximization a hidden split already uses. `.quick` keeps its card and is only
    /// allocated the whole content area (`onDeckOverlayChildPosition`).
    func setTerminalZoom(_ mode: ControlToggleMode, target: TerminalZoomTarget?, resync: Bool = true) {
        if mode != .off, dashboard.isOpen { closeDashboard(refocus: false) }
        let old = terminalZoom.target
        terminalZoom.set(mode, target: target)
        let new = terminalZoom.target
        guard old != new else { return }
        if let new, surface(for: new) == nil { terminalZoom.clear() }
        if case .session(let id, _)? = old {
            restoreZoomedPaneOverlays(id)
            // A target switch can leave this pane hidden until zoom finally exits. Keep its ratio restore
            // pending so the divider is reset after the un-zoomed allocation, even across other targets.
            if store.session(withID: id)?.splitRatio != nil { zoomPendingRatioRestore.insert(id) }
        }
        if terminalZoom.target == nil {
            for id in Array(zoomPendingRatioRestore) {
                guard let paned = sessionPanes[id] else {
                    zoomPendingRatioRestore.remove(id)
                    continue
                }
                let context = ZoomExitRatioContext(
                    controller: self, sessionID: id, paned: paned, zoomedWidth: gtk_widget_get_width(W(paned)))
                _ = gtk_widget_add_tick_callback(W(window), zoomExitRatioTick,
                                                 Unmanaged.passRetained(context).toOpaque(), releaseZoomExitRatioTick)
            }
        }
        applyTerminalZoomChrome()
        applyQuickFrameVisibility()
        if let deckOverlay { gtk_widget_queue_resize(W(deckOverlay)) }   // re-place the quick card
        // Leaving a zoom (or switching targets) lets the ordinary syncs put every page, pane and floating
        // frame back; `showActive` at the end of that pass re-applies whatever zoom is still current.
        if !resync {
            return
        } else if old != nil {
            reconcile(focusActive: false, syncSidebar: false)
        } else {
            showActive(focus: false)
        }
        resyncBlinkPhase()   // zooming unmaps the sidebar column
        refreshPaneOverlayCoverage()
        updateAllPaneDimming()
        if let current = terminalZoom.target { surface(for: current)?.refresh() }
        // Nothing here clears `quickVisible`, so the quick card can come back on screen over the deck.
        if let current = terminalZoom.target {
            surface(for: current)?.grabFocus(supersedingPopoverCapture: true)
        } else {
            focusActiveSurface()
        }
    }

    /// Build the zoom strip once, as a second top bar of the content toolbar. It is only ever shown or
    /// hidden, never re-parented, so the deck below it keeps its place in the tree.
    func installZoomHeader(in contentToolbar: OpaquePointer?) {
        let header = OpaquePointer(adw_header_bar_new())
        gtk_widget_add_css_class(W(header), "agterm-modal-header")
        let decorationLayout = LinuxDesktopEnvironment.hidesClientSideWindowButtons() ? ":" : "close,minimize,maximize:"
        decorationLayout.withCString { adw_header_bar_set_decoration_layout(header, $0) }
        let titleLabel = OpaquePointer(gtk_label_new(""))
        gtk_widget_add_css_class(W(titleLabel), "title")
        adw_header_bar_set_title_widget(header, W(titleLabel))
        let exit = OpaquePointer(gtk_button_new_with_label("Exit Terminal Zoom"))
        gtk_widget_set_tooltip_text(W(exit), "Exit Terminal Zoom")
        gtk_widget_set_focus_on_click(W(exit), 0)
        connect(exit, "clicked", unsafeBitCast(onTerminalZoomExit, to: GCallback.self))
        adw_header_bar_pack_end(header, W(exit))
        gtk_widget_set_visible(W(header), 0)
        adw_toolbar_view_add_top_bar(contentToolbar, W(header))
        zoomHeader = header
        zoomTitleLabel = titleLabel
    }

    /// Sidebar column, content header and zoom strip for the current zoom state. `applySidebarVisibility`
    /// and `applyToolbarMode` honor the same rule, so a settings change mid-zoom cannot undo it.
    func applyTerminalZoomChrome() {
        let zoomed = terminalZoom.target != nil
        if let paned = splitView, let sidebar = gtk_paned_get_start_child(paned) {
            gtk_widget_set_visible(sidebar, store.sidebarVisible && !zoomed ? 1 : 0)
            if !zoomed { applySidebarWidth(paned) }
        }
        let toolbarShown = linuxSettingsStore().load().effectiveToolbarMode != .hidden
        if let contentHeader { gtk_widget_set_visible(W(contentHeader), toolbarShown && !zoomed ? 1 : 0) }
        if let zoomHeader { gtk_widget_set_visible(W(zoomHeader), toolbarShown && zoomed ? 1 : 0) }
        if zoomed, let zoomTitleLabel {
            let title = LinuxModalTitle.normal(
                sessionName: zoomTitleSessionName,
                window: library.windows.first(where: { $0.id == windowID }))
            gtk_label_set_text(zoomTitleLabel, title)
        }
    }

    /// The session whose deck page a zoom presents in place of the selection's, nil when not zoomed on one.
    var zoomedSessionID: UUID? {
        if case .session(let id, _)? = terminalZoom.target { return id }
        return nil
    }

    var zoomTitleSessionName: String? {
        zoomedSessionID.flatMap { store.session(withID: $0)?.displayName } ?? store.activeSession?.displayName
    }

    /// Quick remains logically open across a session zoom, but its card must yield to the zoomed deck.
    var quickFramePresented: Bool { quickVisible && zoomedSessionID == nil }

    func applyQuickFrameVisibility() {
        if let quickFrame { gtk_widget_set_visible(W(quickFrame), quickFramePresented ? 1 : 0) }
    }

    /// Which pane hosts stay shown while `slot` is zoomed; nil leaves the split layout alone.
    static func zoomedPaneVisibility(_ slot: TerminalZoomSurface) -> (primary: Bool, split: Bool)? {
        switch slot {
        case .primary, .overlayLeft: (true, false)
        case .split, .overlayRight: (false, true)
        case .scratch, .overlay: nil
        }
    }

    /// `zoomedPaneVisibility` for one session: nil unless the current zoom targets one of its panes.
    func zoomedPaneVisibility(forSession id: UUID) -> (primary: Bool, split: Bool)? {
        guard case .session(let zoomed, let slot)? = terminalZoom.target, zoomed == id else { return nil }
        return Self.zoomedPaneVisibility(slot)
    }

    /// The session stack page a zoom on `slot` must show; nil for a floating overlay, which is not a page.
    static func zoomedStackPage(_ slot: TerminalZoomSurface, floatingOverlay: Bool) -> String? {
        switch slot {
        case .primary, .split, .overlayLeft, .overlayRight: "main"
        case .scratch: "scratch"
        case .overlay: floatingOverlay ? nil : "overlay"
        }
    }

    /// Re-assert the zoomed session's page, panes and covers over whatever the last sync laid out. Runs at
    /// the end of every `showActive`, and `layoutSplit` consults `zoomedPaneVisibility` itself.
    func applyTerminalZoomLayout() {
        guard case .session(let id, let slot)? = terminalZoom.target else { return }
        let floating = floatingOverlayFrames[id]
        if let stack = sessionStacks[id],
           let page = Self.zoomedStackPage(slot, floatingOverlay: floating != nil),
           page.withCString({ gtk_stack_get_child_by_name(stack, $0) }) != nil {
            page.withCString { gtk_stack_set_visible_child_name(stack, $0) }
        }
        if let visible = zoomedPaneVisibility(forSession: id) {
            if let primary = primaryPaneHosts[id] { gtk_widget_set_visible(W(primary), visible.primary ? 1 : 0) }
            if let split = splitPaneHosts[id] { gtk_widget_set_visible(W(split), visible.split ? 1 : 0) }
        }
        // Zooming a pane's BASE terminal lifts that pane's own overlay out of the way.
        switch slot {
        case .primary: setZoomedPaneOverlayVisible(false, sessionID: id, pane: .left)
        case .split: setZoomedPaneOverlayVisible(false, sessionID: id, pane: .right)
        default: break
        }
        if slot == .overlay, let floating {
            gtk_widget_set_size_request(W(floating), -1, -1)
            gtk_widget_set_halign(W(floating), GTK_ALIGN_FILL)
            gtk_widget_set_valign(W(floating), GTK_ALIGN_FILL)
            gtk_widget_set_margin_start(W(floating), 0)
            gtk_widget_set_margin_end(W(floating), 0)
            gtk_widget_set_margin_top(W(floating), 0)
            gtk_widget_set_margin_bottom(W(floating), 0)
        }
    }

    private func restoreZoomedPaneOverlays(_ sessionID: UUID) {
        for pane in OverlayPane.allCases { setZoomedPaneOverlayVisible(true, sessionID: sessionID, pane: pane) }
    }

    private func setZoomedPaneOverlayVisible(_ visible: Bool, sessionID: UUID, pane: OverlayPane) {
        let flag: gboolean = visible ? 1 : 0
        if let overlay = paneOverlaySurface(sessionID, pane: pane) { gtk_widget_set_visible(W(overlay.rootWidget), flag) }
        if let wash = paneOverlayWash(sessionID, pane: pane) { gtk_widget_set_visible(W(wash), flag) }
        if let html = store.session(withID: sessionID)?.paneOverlay(pane)?.html,
           let page = LinuxHtmlOverlayRegistry.shared.existing(html.id) {
            gtk_widget_set_visible(W(page.root), flag)
        }
    }

}

private let onTerminalZoomExit: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    MainActor.assumeIsolated {
        controllerForWidget(button)?.setTerminalZoom(.off, target: nil)
    }
}

/// A split divider waiting for its paned to leave the zoom-wide allocation. `ticks` bounds the wait for a
/// zoom that never changed the width (the sidebar was already hidden).
@MainActor
final class ZoomExitRatioContext {
    weak var controller: AppController?
    let sessionID: UUID
    let paned: OpaquePointer
    let zoomedWidth: Int32
    var ticks = 0

    init(controller: AppController, sessionID: UUID, paned: OpaquePointer, zoomedWidth: Int32) {
        self.controller = controller
        self.sessionID = sessionID
        self.paned = paned
        self.zoomedWidth = zoomedWidth
    }
}

extension AppController {
    /// One frame of the wait. The callback lives on the window so a hidden target pane still settles.
    /// Returning 0 (`G_SOURCE_REMOVE`) detaches it.
    func restoreRatioAfterZoomExit(_ context: ZoomExitRatioContext) -> gboolean {
        guard sessionPanes[context.sessionID] == context.paned else {
            zoomPendingRatioRestore.remove(context.sessionID)
            return 0
        }
        context.ticks += 1
        guard gtk_widget_get_width(W(context.paned)) == context.zoomedWidth, context.ticks < 3 else {
            if terminalZoom.target == nil {
                scheduleSplitRatioRestore(sessionID: context.sessionID, paned: context.paned)
                zoomPendingRatioRestore.remove(context.sessionID)
            } else {
                zoomPendingRatioRestore.insert(context.sessionID)
            }
            return 0
        }
        return 1
    }
}

// The same address-crossing shape as `sidebarScrollRetryTick` (`AppControllerCallbacks`).
private let zoomExitRatioTick: GtkTickCallback = { _, _, data in
    guard let data else { return 0 }
    let address = Int(bitPattern: data)
    return MainActor.assumeIsolated {
        guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return gboolean(0) }
        let context = Unmanaged<ZoomExitRatioContext>.fromOpaque(raw).takeUnretainedValue()
        return context.controller?.restoreRatioAfterZoomExit(context) ?? 0
    }
}

private let releaseZoomExitRatioTick: GDestroyNotify = { data in
    guard let data else { return }
    let address = Int(bitPattern: data)
    MainActor.assumeIsolated {
        guard let raw = UnsafeMutableRawPointer(bitPattern: address) else { return }
        Unmanaged<ZoomExitRatioContext>.fromOpaque(raw).release()
    }
}
