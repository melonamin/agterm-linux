import CGtk
import Foundation
import agtermCore

@MainActor
final class DashboardRuntime {
    var host: OpaquePointer?
    var header: OpaquePointer?
    var titleLabel: OpaquePointer?
    var keyController: OpaquePointer?
    var frames: [DashboardMember: OpaquePointer] = [:]
    var targets: [DashboardMember: TerminalZoomTarget] = [:]
    var statusIcons: [DashboardMember: OpaquePointer] = [:]
    var clickContexts: [DashboardClickContext] = []
    var clickIntent = DashboardClickIntent()
    var pendingClickSource: guint = 0
    var pendingClickContext: DashboardDelayedClickContext?
}

@MainActor
final class DashboardClickContext {
    weak var controller: AppController?
    let member: DashboardMember

    init(controller: AppController, member: DashboardMember) {
        self.controller = controller
        self.member = member
    }
}

@MainActor
final class DashboardDelayedClickContext {
    weak var controller: AppController?
    let member: DashboardMember
    let generation: UInt64

    init(controller: AppController, member: DashboardMember, generation: UInt64) {
        self.controller = controller
        self.member = member
        self.generation = generation
    }
}

@MainActor
extension AppController {
    func toggleDashboard() {
        if dashboard.isOpen {
            closeDashboard()
            return
        }
        guard terminalZoom.target == nil else { return }
        let members = store.dashboardMRUMembers(limit: DashboardLayout.maxCells)
        guard !members.isEmpty else { return }
        openDashboard(members: members, fontMode: .auto)
    }

    func openDashboard(members: [DashboardMember], fontMode: DashboardFontMode) {
        guard !members.isEmpty else { return }
        if terminalZoom.target != nil { setTerminalZoom(.off, target: nil) }
        if dashboard.isOpen { closeDashboard(refocus: false) }
        if quickVisible { setQuick(false) }
        if paletteWindow != nil { closePalette() }
        searchSurface?.endSearch()
        if sessionSwitcher.isActive { endSessionSwitch() }
        dashboard.open(members: members, fontMode: fontMode)
        refreshPaneOverlayCoverage()
        suppressAutoFollow()
        showDashboardSourcePages()
        showActive(focus: false)
        applyDashboardFont()
        mountDashboard()
    }

    func closeDashboard(refocus: Bool = true) {
        cancelPendingDashboardClick()
        guard dashboard.isOpen || dashboardRuntime.host != nil else { return }
        clearDashboardFontOverrides()
        if let keys = dashboardRuntime.keyController {
            gtk_widget_remove_controller(W(window), keys)
            dashboardRuntime.keyController = nil
        }
        if let host = dashboardRuntime.host, let deckOverlay {
            gtk_overlay_remove_overlay(deckOverlay, W(host))
        }
        dashboardRuntime.host = nil
        dashboardRuntime.header = nil
        dashboardRuntime.titleLabel = nil
        dashboardRuntime.frames = [:]
        dashboardRuntime.targets = [:]
        dashboardRuntime.statusIcons = [:]
        dashboardRuntime.clickContexts = []
        dashboard.close()
        refreshPaneOverlayCoverage()
        resumeAutoFollow()
        restoreSessionTopPages()
        gtk_widget_set_can_target(W(splitView), 1)
        // The overlay removal above destroyed the host `mountDashboard` grabbed, so both legs must hand
        // the keyboard back.
        if refocus {
            showActiveFocusingVisibleSurface()
        } else {
            showActive()
        }
    }

    func selectDashboardMember(_ member: DashboardMember) {
        cancelPendingDashboardClick()
        guard dashboard.members.contains(member) else { return }
        noteUserActivity()
        store.selectSession(member.session)
        if let session = store.session(withID: member.session) {
            session.splitFocused = member.surface == .split
        }
        closeDashboard(refocus: false)
        if member.surface == .split { focusPane(left: false) } else { focusPane(left: true) }
    }

    func moveDashboardHighlight(_ direction: DashboardLayout.Direction) {
        cancelPendingDashboardClick()
        dashboard.move(direction)
        updateDashboardHighlight()
    }

    func updateDashboardButton() {
        guard let dashboardButton else { return }
        gtk_widget_set_sensitive(W(dashboardButton), store.workspaces.contains { !$0.sessions.isEmpty } ? 1 : 0)
    }

    func revealSessionDirectory(_ id: UUID) -> Bool {
        guard let path = store.session(withID: id)?.focusedCwd else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        launchDefaultHandler(forURI: URL(fileURLWithPath: path).absoluteString)
        return true
    }

    func prepareDashboardForReconcile()
        -> (members: [DashboardMember], mode: DashboardFontMode, highlighted: DashboardMember?)? {
        guard dashboard.isOpen else { return nil }
        let existing = Set(store.workspaces.flatMap(\.sessions).flatMap { session -> [DashboardMember] in
            var result = [DashboardMember(session: session.id, surface: .primary)]
            if session.hasSplit { result.append(DashboardMember(session: session.id, surface: .split)) }
            return result
        })
        let survivors = dashboard.members.filter(existing.contains)
        let state = (survivors, dashboard.fontMode,
                     dashboard.highlighted.flatMap { survivors.contains($0) ? $0 : nil })
        closeDashboard(refocus: false)
        return state
    }

    func restoreDashboardAfterReconcile(
        _ state: (members: [DashboardMember], mode: DashboardFontMode, highlighted: DashboardMember?)?) {
        guard let state, !state.members.isEmpty else { return }
        openDashboard(members: state.members, fontMode: state.mode)
        if let highlighted = state.highlighted {
            dashboard.highlight(highlighted)
            updateDashboardHighlight()
        }
    }

    private func mountDashboard() {
        guard let deckOverlay else { return }
        let host = OpaquePointer(adw_toolbar_view_new())
        let header = OpaquePointer(adw_header_bar_new())
        let grid = OpaquePointer(gtk_grid_new())
        gtk_widget_add_css_class(W(host), "agterm-dashboard")
        gtk_widget_add_css_class(W(header), "agterm-modal-header")
        gtk_widget_set_hexpand(W(host), 1)
        gtk_widget_set_vexpand(W(host), 1)
        gtk_widget_set_focusable(W(host), 1)
        let decorationLayout = LinuxDesktopEnvironment.hidesClientSideWindowButtons() ? ":" : "close,minimize,maximize:"
        decorationLayout.withCString { adw_header_bar_set_decoration_layout(header, $0) }
        let title = LinuxModalTitle.dashboard(window: library.windows.first(where: { $0.id == windowID }))
        let titleLabel = OpaquePointer(gtk_label_new(title))
        gtk_widget_add_css_class(W(titleLabel), "title")
        adw_header_bar_set_title_widget(header, W(titleLabel))
        let exit = OpaquePointer(gtk_button_new_with_label("Exit Dashboard"))
        gtk_widget_set_tooltip_text(W(exit), "Exit Dashboard")
        gtk_widget_set_focus_on_click(W(exit), 0)
        connect(exit, "clicked", unsafeBitCast(onDashboardExit, to: GCallback.self))
        adw_header_bar_pack_end(header, W(exit))
        adw_toolbar_view_add_top_bar(host, W(header))
        if linuxSettingsStore().load().effectiveToolbarMode == .hidden {
            gtk_widget_set_visible(W(header), 0)
        }
        gtk_grid_set_row_homogeneous(cast(grid), 1)
        gtk_grid_set_column_homogeneous(cast(grid), 1)
        gtk_grid_set_row_spacing(cast(grid), 8)
        gtk_grid_set_column_spacing(cast(grid), 8)
        for margin in [gtk_widget_set_margin_top, gtk_widget_set_margin_bottom,
                       gtk_widget_set_margin_start, gtk_widget_set_margin_end] {
            margin(W(grid), 10)
        }
        adw_toolbar_view_set_content(host, W(grid))

        let (cols, _) = DashboardLayout.grid(count: dashboard.members.count)
        for (index, member) in dashboard.members.enumerated() {
            let target = TerminalZoomTarget.session(member.session, member.surface)
            guard let surface = surface(for: target) else { continue }
            let frame = OpaquePointer(gtk_frame_new(nil))
            gtk_widget_add_css_class(W(frame), "agterm-dashboard-cell")
            gtk_widget_set_hexpand(W(frame), 1)
            gtk_widget_set_vexpand(W(frame), 1)
            let cell = OpaquePointer(gtk_overlay_new())
            let paintable = gtk_widget_paintable_new(W(surface.rootWidget))
            let picture = OpaquePointer(gtk_picture_new_for_paintable(paintable))
            gtk_picture_set_can_shrink(picture, 1)
            gtk_picture_set_content_fit(picture, GTK_CONTENT_FIT_FILL)
            gtk_widget_set_hexpand(W(picture), 1)
            gtk_widget_set_vexpand(W(picture), 1)
            gtk_overlay_set_child(cell, W(picture))
            g_object_unref(RAW(paintable))
            let sessionName = store.session(withID: member.session)?.displayName ?? "Session"
            let paneName = member.surface == .split ? "Right" : "Left"
            gtk_widget_set_tooltip_text(W(frame), "\(sessionName) · \(paneName)")
            let caption = OpaquePointer(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6))
            gtk_widget_add_css_class(W(caption), "agterm-dashboard-caption")
            gtk_widget_set_halign(W(caption), GTK_ALIGN_START)
            gtk_widget_set_valign(W(caption), GTK_ALIGN_END)
            gtk_widget_set_margin_start(W(caption), 8)
            gtk_widget_set_margin_bottom(W(caption), 8)
            let statusIcon = OpaquePointer(gtk_label_new(nil))
            dashboardRuntime.statusIcons[member] = statusIcon
            gtk_box_append(cast(caption), W(statusIcon))
            let captionLabel = OpaquePointer(gtk_label_new("\(sessionName) · \(paneName)"))
            gtk_box_append(cast(caption), W(captionLabel))
            gtk_overlay_add_overlay(cell, W(caption))
            gtk_frame_set_child(cast(frame), W(cell))
            let click = gtk_gesture_click_new()
            let context = DashboardClickContext(controller: self, member: member)
            dashboardRuntime.clickContexts.append(context)
            connect(click, "pressed", unsafeBitCast(onDashboardCellPressed as @convention(c)
                (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self),
                Unmanaged.passUnretained(context).toOpaque())
            gtk_widget_add_controller(W(frame), click)
            gtk_grid_attach(cast(grid), W(frame), Int32(index % cols), Int32(index / cols), 1, 1)
            dashboardRuntime.frames[member] = frame
            dashboardRuntime.targets[member] = target
        }

        let keys = gtk_event_controller_key_new()
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE)
        connect(keys, "key-pressed", unsafeBitCast(onDashboardKey as @convention(c)
            (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean, to: GCallback.self),
            Unmanaged.passUnretained(self).toOpaque())
        // Capture on the window so native header focus, accessibility activation, and the view-only
        // terminal cells all share the same keyboard navigation path.
        gtk_widget_add_controller(W(window), keys)
        gtk_overlay_add_overlay(deckOverlay, W(host))
        dashboardRuntime.host = host
        dashboardRuntime.header = header
        dashboardRuntime.titleLabel = titleLabel
        dashboardRuntime.keyController = keys
        gtk_widget_set_can_target(W(splitView), 0)
        updateDashboardStatusIndicators()
        updateDashboardHighlight()
        _ = gtk_widget_grab_focus(W(host))
    }

    fileprivate func scheduleDashboardSelection(_ member: DashboardMember) {
        cancelPendingDashboardClick()
        dashboard.highlight(member)
        updateDashboardHighlight()
        let generation = dashboardRuntime.clickIntent.begin(member: member)
        let context = DashboardDelayedClickContext(controller: self, member: member, generation: generation)
        dashboardRuntime.pendingClickContext = context
        let source = g_timeout_add_full(
            G_PRIORITY_DEFAULT, DashboardClickIntent.delayMilliseconds, onDashboardClickDelay,
            Unmanaged.passRetained(context).toOpaque(), releaseDashboardDelayedClickContext)
        dashboardRuntime.pendingClickSource = source
        if source == 0 {
            dashboardRuntime.pendingClickContext = nil
            dashboardRuntime.clickIntent.cancel()
        }
    }

    private func cancelPendingDashboardClick() {
        let source = dashboardRuntime.pendingClickSource
        dashboardRuntime.pendingClickSource = 0
        if source != 0 { _ = g_source_remove(source) }
        dashboardRuntime.pendingClickContext = nil
        dashboardRuntime.clickIntent.cancel()
    }

    fileprivate func completeDashboardSelection(_ context: DashboardDelayedClickContext) {
        guard dashboardRuntime.pendingClickContext === context else { return }
        dashboardRuntime.pendingClickSource = 0
        dashboardRuntime.pendingClickContext = nil
        guard dashboardRuntime.clickIntent.accepts(generation: context.generation, member: context.member),
              dashboard.isOpen, dashboard.highlighted == context.member else { return }
        selectDashboardMember(context.member)
    }

    func updateDashboardStatusIndicators() {
        let settings = linuxSettingsStore().load()
        for (member, icon) in dashboardRuntime.statusIcons {
            let indicator = store.session(withID: member.session)?.agentIndicator ?? AgentIndicator()
            Self.applyStatusGlyph(indicator, settings: settings, to: icon)
        }
    }

    private func applyDashboardFont() {
        clearDashboardFontOverrides()
        let base = linuxSettingsStore().load().fontSize ?? DashboardLayout.ghosttyDefaultFontSize
        let size = dashboard.fontMode.appliedFontSize(memberCount: dashboard.members.count, base: base)
        dashboard.setAppliedFontSize(size)
        guard let size else { return }
        for member in dashboard.members {
            let target = TerminalZoomTarget.session(member.session, member.surface)
            surface(for: target)?.dashboardFontOverride = size
        }
    }

    private func clearDashboardFontOverrides() {
        for surface in Array(surfaces.values) + Array(splitSurfaces.values) where surface.dashboardFontOverride != nil {
            surface.dashboardFontOverride = nil
        }
    }

    private func updateDashboardHighlight() {
        for (member, frame) in dashboardRuntime.frames {
            if member == dashboard.highlighted {
                gtk_widget_add_css_class(W(frame), "selected")
            } else {
                gtk_widget_remove_css_class(W(frame), "selected")
            }
        }
    }
}

private let onDashboardExit: @MainActor @convention(c) (OpaquePointer?, gpointer?) -> Void = { button, _ in
    controllerForWidget(button)?.closeDashboard()
}

private let onDashboardCellPressed: @MainActor @convention(c)
    (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void = { _, presses, _, _, data in
    guard presses >= 1, let data else { return }
    MainActor.assumeIsolated {
        let context = Unmanaged<DashboardClickContext>.fromOpaque(data).takeUnretainedValue()
        context.controller?.scheduleDashboardSelection(context.member)
    }
}

private let onDashboardClickDelay: @MainActor @convention(c) (gpointer?) -> gboolean = { data in
    guard let data else { return 0 }
    return MainActor.assumeIsolated {
        let context = Unmanaged<DashboardDelayedClickContext>.fromOpaque(data).takeUnretainedValue()
        context.controller?.completeDashboardSelection(context)
        return 0
    }
}

private let releaseDashboardDelayedClickContext: @MainActor @convention(c) (gpointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<DashboardDelayedClickContext>.fromOpaque(data).release()
}

private let onDashboardKey: @MainActor @convention(c)
    (OpaquePointer?, UInt32, UInt32, UInt32, gpointer?) -> gboolean = { _, key, _, _, data in
    guard let data else { return 0 }
    return MainActor.assumeIsolated {
        let controller = Unmanaged<AppController>.fromOpaque(data).takeUnretainedValue()
        switch key {
        case 0xFF1B: controller.closeDashboard(); return 1
        case 0xFF51: controller.moveDashboardHighlight(.left); return 1
        case 0xFF52: controller.moveDashboardHighlight(.up); return 1
        case 0xFF53: controller.moveDashboardHighlight(.right); return 1
        case 0xFF54: controller.moveDashboardHighlight(.down); return 1
        case 0xFF0D, 0xFF8D:
            if let member = controller.dashboard.highlighted { controller.selectDashboardMember(member) }
            return 1
        default: return 1
        }
    }
}
