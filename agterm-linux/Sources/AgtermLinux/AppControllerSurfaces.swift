import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    // MARK: - Reconcile

    /// Rebuild the deck from the store's tree: realize a surface for every session it names, then drop the
    /// surfaces of sessions it no longer does.
    ///
    /// A soft-closed session is deliberately absent from the tree while its record waits out the undo
    /// grace, so the "no longer named" set is the tree ids UNION the ids a pending close still holds —
    /// every reconcile, not only the trailing one a soft close arms. Reaping a held session would free its
    /// ghostty surfaces (killing the shells) while `undoPendingClose` still offers to bring it back, and
    /// the undo would then silently spawn a brand-new login shell in place of the user's running one.
    func reconcile(focusActive: Bool = true, rebuildSidebar: Bool = true) {
        let dashboardRestore = prepareDashboardForReconcile()
        clearInvalidTerminalZoom()
        for ws in store.workspaces {
            for s in ws.sessions {
                ensurePrimary(s)
                syncSplit(s)
                syncPaneOverlays(s, allowFocus: focusActive)
                syncScratch(s)
                syncOverlay(s, allowFocus: focusActive)   // after scratch so an open overlay wins the visible child
            }
        }
        // Drop closed sessions, but never one a pending close still holds for its undo window.
        var live = Set(store.workspaces.flatMap { $0.sessions.map(\.id) })
        live.formUnion(store.pendingHeldSessionIDs())
        for id in Array(surfaces.keys) where !live.contains(id) { removeSession(id) }
        if rebuildSidebar { self.rebuildSidebar() }
        showActive(focus: focusActive)
        updateTitle()
        updateAttentionButton()
        updateDashboardButton()
        restoreDashboardAfterReconcile(dashboardRestore)
    }

    /// The `AGTERM_*` env injected into a session's spawned shells (main/split/scratch) so the
    /// agent-status hooks + `{AGT_X}` tokens can call back over the control socket.
    func sessionEnv(for s: Session, pane: StatusPane? = nil) -> [String: String] {
        let paneIdentity: UUID? = switch pane {
        case .left: s.paneIdentity
        case .right: s.splitPaneIdentity
        case .scratch, nil: nil
        }
        return SurfaceEnvironment.session(sessionID: s.id, windowID: windowID,
                                          workspaceID: store.workspace(forSession: s.id)?.id,
                                          socketPath: gControlServer.resolvedSocketPath,
                                          programVersion: LinuxAppMetadata.version, pane: pane,
                                          paneToken: paneIdentity?.uuidString)
    }

    /// Each session's deck page is an outer GtkStack ("main" = a GtkPaned holding the
    /// pane(s), "scratch" = the full-overlay scratch shell). The primary pane starts in the paned's start
    /// child and keeps whatever slot it is given for its lifetime (`primaryInEndSlot`).
    private func ensurePrimary(_ s: Session) {
        guard surfaces[s.id] == nil,
              let paned = OpaquePointer(gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)),
              let stack = op(gtk_stack_new()) else { return }
        sessionPanes[s.id] = paned
        connect(paned, "notify::position", unsafeBitCast(onPanedPosition as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        let dividerClick = gtk_gesture_click_new()
        gtk_gesture_single_set_button(dividerClick, 1)
        connect(dividerClick, "pressed", unsafeBitCast(onPanedDoubleClick as @convention(c)
            (OpaquePointer?, Int32, Double, Double, gpointer?) -> Void, to: GCallback.self))
        gtk_widget_add_controller(W(paned), dividerClick)
        sessionStacks[s.id] = stack
        let launch = paneLaunchProvider(for: s, pane: .left)
        let surf = GhosttySurface(sessionID: s.id, cwd: s.effectiveCwd,
                                  env: launch.environment, controller: self,
                                  fontSize: s.fontSize, backedByZmx: launch.backedByZmx)
        surf.launchSeed = launch
        gSpawnRegistry.enqueue(surf, key: s.paneIdentity, shouldPace: launch.shouldPace)
        s.surface = surf
        surfaces[s.id] = surf
        installPaneExitHandler(surf, sessionID: s.id)
        let paneHost = OpaquePointer(gtk_overlay_new())
        gtk_overlay_set_child(paneHost, W(surf.rootWidget))
        primaryPaneHosts[s.id] = paneHost
        gtk_paned_set_start_child(paned, W(paneHost))
        "main".withCString { _ = gtk_stack_add_named(stack, W(paned), $0) }
        gtk_widget_set_halign(W(stack), GTK_ALIGN_FILL)
        gtk_widget_set_valign(W(stack), GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(W(stack), 1)
        gtk_widget_set_vexpand(W(stack), 1)
        gtk_widget_set_opacity(W(stack), 0)
        gtk_widget_set_can_target(W(stack), 0)
        gtk_widget_set_child_visible(W(stack), 0)
        gtk_overlay_add_overlay(deck, W(stack))
    }

    /// Create/show/hide the scratch shell to match the session's scratch state. Kept
    /// alive (hidden) when toggled off; removed only when its shell exits.
    private func syncScratch(_ s: Session) {
        guard let stack = sessionStacks[s.id] else { return }
        if s.scratchActive {
            if scratchSurfaces[s.id] == nil {
                let command = s.scratchCommand
                s.scratchCommand = nil
                let sc = GhosttySurface(sessionID: s.id, cwd: s.effectiveCwd, command: command,
                                        env: sessionEnv(for: s, pane: .scratch), controller: self,
                                        role: .scratch,
                                        reportsPaneState: false)
                let sid = s.id
                sc.onExit = { [weak self] in self?.closeScratch(sid) }
                s.scratchSurface = sc
                scratchSurfaces[s.id] = sc
                "scratch".withCString { _ = gtk_stack_add_named(stack, W(sc.rootWidget), $0) }
            }
            "scratch".withCString { gtk_stack_set_visible_child_name(stack, $0) }
        } else {
            "main".withCString { gtk_stack_set_visible_child_name(stack, $0) }
            if let sc = scratchSurfaces[s.id], s.scratchSurface == nil {
                gtk_stack_remove(stack, W(sc.rootWidget))
                scratchSurfaces[s.id] = nil
            }
        }
    }

    /// Create/show/hide the ephemeral overlay terminal (runs `overlayCommand` over the session).
    private func syncOverlay(_ s: Session, allowFocus: Bool) {
        guard let stack = sessionStacks[s.id] else { return }
        if let cached = overlaySurfaces[s.id], s.overlaySurface !== cached {
            if let frame = floatingOverlayFrames[s.id] {
                gtk_overlay_remove_overlay(deck, W(frame))
                floatingOverlayFrames[s.id] = nil
            } else {
                gtk_stack_remove(stack, W(cached.rootWidget))
            }
            overlaySurfaces[s.id] = nil
        }
        if s.overlayActive {
            if overlaySurfaces[s.id] == nil, let cmd = s.overlayCommand {
                let codePath = NSTemporaryDirectory() + "agterm-ovl-\(UUID().uuidString).code"
                var ovlEnv = sessionEnv(for: s)
                ovlEnv[OverlayCapture.cmdEnvKey] = cmd
                ovlEnv[OverlayCapture.codeEnvKey] = codePath
                if s.hudActive, let hudFile = s.hudFile {
                    ovlEnv[HudLayout.fileEnvKey] = hudFile
                }
                let ov = GhosttySurface(sessionID: s.id, cwd: s.overlayCwd ?? s.effectiveCwd,
                                        command: "sh -c " + Self.singleQuoted(OverlayCapture.shellLine),
                                        env: ovlEnv, controller: self, waitAfterCommand: s.overlayWait,
                                        role: .overlay,
                                        reportsPaneState: false,
                                        fontSize: s.fontSize,
                                        backgroundColor: s.overlayBackgroundColor,
                                        usesSessionWatermark: false)
                let sid = s.id
                let owner = windowID
                let recordsExitCode = !s.hudActive
                ov.captureExitCode(from: codePath) { code in
                    if recordsExitCode { gWindows[owner]?.store.recordOverlayExit(sid, code: code) }
                }
                ov.onExit = {
                    runOnMain { MainActor.assumeIsolated {
                        gWindows[owner]?.closeOverlay(sid)
                    } }
                }
                s.overlaySurface = ov
                overlaySurfaces[s.id] = ov
                if let pct = s.overlaySizePercent {
                    let overlay = deck
                    guard let frame = OpaquePointer(gtk_frame_new(nil)) else { return }
                    gtk_widget_add_css_class(W(frame), "card")
                    gtk_widget_add_css_class(W(frame), "agterm-quick")
                    gtk_widget_set_overflow(W(frame), GTK_OVERFLOW_HIDDEN)   // clip GL child to the rounded card; see LinuxQuickCardPolicy
                    gtk_widget_set_halign(W(frame), GTK_ALIGN_CENTER)
                    gtk_widget_set_valign(W(frame), GTK_ALIGN_CENTER)
                    ov.sizeFallback = mountFloatingOverlayFrame(
                        s, frame: frame, overlay: overlay, child: ov.rootWidget, fallbackPercent: pct)
                    gtk_overlay_add_overlay(overlay, W(frame))
                    // Keep this AFTER `mountFloatingOverlayFrame` — hidden widgets do not measure.
                    gtk_widget_set_visible(W(frame), s.id == store.selectedSessionID ? 1 : 0)
                    floatingOverlayFrames[s.id] = frame
                } else {
                    "overlay".withCString { _ = gtk_stack_add_named(stack, W(ov.rootWidget), $0) }
                }
                ov.realizeWidgetIfNeeded()
            }
            if floatingOverlayFrames[s.id] != nil {
                if let frame = floatingOverlayFrames[s.id], let percent = s.overlaySizePercent {
                    let overlay = deck
                    updateFloatingOverlayFrame(s, frame: frame, overlay: overlay, fallbackPercent: percent)
                }
                if allowFocus, !s.hudActive, s.id == store.selectedSessionID {
                    overlaySurfaces[s.id]?.grabFocus(supersedingPopoverCapture: true)
                }
            } else {
                "overlay".withCString { gtk_stack_set_visible_child_name(stack, $0) }
                if allowFocus, !s.hudActive, s.id == store.selectedSessionID {
                    overlaySurfaces[s.id]?.grabFocus(supersedingPopoverCapture: true)
                }
            }
        } else if let ov = overlaySurfaces[s.id], s.overlaySurface == nil {
            if let frame = floatingOverlayFrames[s.id] {
                let overlay = deck
                gtk_overlay_remove_overlay(overlay, W(frame))
                floatingOverlayFrames[s.id] = nil
            } else {
                (s.scratchActive ? "scratch" : "main").withCString { gtk_stack_set_visible_child_name(stack, $0) }
                gtk_stack_remove(stack, W(ov.rootWidget))
            }
            overlaySurfaces[s.id] = nil
        }
    }

    /// Measure an empty, visible GtkFrame, apply the current overlay geometry, mount its child, and return
    /// the child's usable box. The ordering matters: a size request, hidden state, or mounted child would
    /// contaminate the frame-only chrome measurement used by the pre-layout surface estimate.
    private func mountFloatingOverlayFrame(
        _ session: Session,
        frame: OpaquePointer,
        overlay: OpaquePointer,
        child: OpaquePointer?,
        fallbackPercent: Int
    ) -> (width: Int32, height: Int32) {
        var chromeWidth: Int32 = 0, chromeHeight: Int32 = 0
        gtk_widget_measure(W(frame), GTK_ORIENTATION_HORIZONTAL, -1, &chromeWidth, nil, nil, nil)
        gtk_widget_measure(W(frame), GTK_ORIENTATION_VERTICAL, -1, &chromeHeight, nil, nil, nil)
        let request = updateFloatingOverlayFrame(
            session, frame: frame, overlay: overlay, fallbackPercent: fallbackPercent)
        gtk_frame_set_child(cast(frame), W(child))
        return GhosttySurfaceGeometry.contentSize(
            request: request, chrome: (width: chromeWidth, height: chromeHeight))
    }

    @discardableResult
    private func updateFloatingOverlayFrame(_ session: Session, frame: OpaquePointer,
                                            overlay: OpaquePointer,
                                            fallbackPercent: Int) -> (width: Int32, height: Int32) {
        let width = gtk_widget_get_width(W(overlay))
        let height = gtk_widget_get_height(W(overlay))
        let widthPercent = Int32(session.overlaySizePercent ?? fallbackPercent)
        let heightPercent = Int32(session.hudHeightPercent ?? session.overlaySizePercent ?? fallbackPercent)
        let minimumWidth: Int32 = session.hudActive ? 1 : 240
        let minimumHeight: Int32 = session.hudActive ? 1 : 160
        let request = (width: max(minimumWidth, width * widthPercent / 100),
                       height: max(minimumHeight, height * heightPercent / 100))
        gtk_widget_set_size_request(W(frame), request.width, request.height)
        let position = session.hudSpec?.position ?? .center
        let horizontal: GtkAlign
        switch position {
        case .topLeft, .centerLeft, .bottomLeft: horizontal = GTK_ALIGN_START
        case .topRight, .centerRight, .bottomRight: horizontal = GTK_ALIGN_END
        default: horizontal = GTK_ALIGN_CENTER
        }
        let vertical: GtkAlign
        switch position {
        case .topLeft, .topCenter, .topRight: vertical = GTK_ALIGN_START
        case .bottomLeft, .bottomCenter, .bottomRight: vertical = GTK_ALIGN_END
        default: vertical = GTK_ALIGN_CENTER
        }
        gtk_widget_set_halign(W(frame), horizontal)
        gtk_widget_set_valign(W(frame), vertical)
        let horizontalMargin = width * Int32(HudPosition.edgeMarginPercent) / 100
        let verticalMargin = height * Int32(HudPosition.edgeMarginPercent) / 100
        gtk_widget_set_margin_start(W(frame), horizontal == GTK_ALIGN_START ? horizontalMargin : 0)
        gtk_widget_set_margin_end(W(frame), horizontal == GTK_ALIGN_END ? horizontalMargin : 0)
        gtk_widget_set_margin_top(W(frame), vertical == GTK_ALIGN_START ? verticalMargin : 0)
        gtk_widget_set_margin_bottom(W(frame), vertical == GTK_ALIGN_END ? verticalMargin : 0)
        let targetable = Self.floatingOverlayTargetable(isHud: session.hudActive)
        gtk_widget_set_can_target(W(frame), targetable ? 1 : 0)
        gtk_widget_set_focusable(W(frame), 0)
        if let surface = overlaySurfaces[session.id] {
            gtk_widget_set_can_target(W(surface.rootWidget), targetable ? 1 : 0)
            gtk_widget_set_focusable(
                W(surface.glArea), Self.floatingOverlayFocusable(isHud: session.hudActive) ? 1 : 0)
        }
        return request
    }

    static func floatingOverlayTargetable(isHud: Bool) -> Bool { !isHud }
    static func floatingOverlayFocusable(isHud: Bool) -> Bool { !isHud }

    func installHudGeometryTracking() {
        let callback = unsafeBitCast(onDeckAllocationChanged as @convention(c)
            (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self)
        connect(deck, "notify::width", callback)
        connect(deck, "notify::height", callback)
    }

    static func hudGeometryNeedsRefresh(
        previous: (Int32, Int32)?, width: Int32, height: Int32
    ) -> Bool {
        width > 0 && height > 0 && (previous?.0 != width || previous?.1 != height)
    }

    func refreshHudGeometryForDeckAllocation() {
        let width = gtk_widget_get_width(W(deck)), height = gtk_widget_get_height(W(deck))
        guard Self.hudGeometryNeedsRefresh(
            previous: lastHudGeometryDeckSize, width: width, height: height) else { return }
        lastHudGeometryDeckSize = (width, height)
        for (id, frame) in floatingOverlayFrames {
            guard let session = store.session(withID: id), session.hudActive,
                  let percent = session.overlaySizePercent else { continue }
            updateFloatingOverlayFrame(session, frame: frame, overlay: deck, fallbackPercent: percent)
        }
    }

    /// The terminal deck's current allocation in logical GTK units, used when a child is realized before
    /// its first layout pass and therefore has no allocation of its own yet.
    func deckAllocationSize() -> (width: Int32, height: Int32) {
        (width: gtk_widget_get_width(W(deck)), height: gtk_widget_get_height(W(deck)))
    }

    static func singleQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The overlay's command exited (or a control close): tear it down + reconcile.
    func closeOverlay(_ id: UUID) {
        let hud = store.session(withID: id)?.hudActive == true
        store.closeOverlay(id)
        reconcile(focusActive: !hud)
    }

    /// Capture each pane's live foreground command into the session model so a restart can re-run it.
    func captureForegroundCommands() {
        let denylistPath = ConfigPaths.restoreDenylistPath(configDirectory: configDirectory())
        let denylist = (try? String(contentsOf: denylistPath, encoding: .utf8)).map(CommandRestore.parseDenylist)
            ?? ["tmux", "screen", "zellij"]
        for ws in store.workspaces {
            for s in ws.sessions {
                if let argv = surfaces[s.id]?.foregroundCommand(), CommandRestore.shouldRestore(argv: argv, denylist: denylist) {
                    s.foregroundCommand = argv
                } else {
                    s.foregroundCommand = nil
                }
                let splitArgv = s.isSplit ? splitSurfaces[s.id]?.foregroundCommand() : nil
                s.splitForegroundCommand = splitArgv.flatMap {
                    CommandRestore.shouldRestore(argv: $0, denylist: denylist) ? $0 : nil
                }
            }
        }
    }

    func runCustomCommand(_ cmd: CustomCommand, origin: GhosttySurface? = nil,
                          allowSessionless: Bool = false) {
        let s = store.activeSession
        guard s != nil || allowSessionless else { return }
        if s == nil, CommandContext.referencesSessionScopedContext(cmd.command) {
            showToast("\(cmd.name) needs an active session")
            return
        }
        let workspace = s.flatMap { store.workspace(forSession: $0.id) }
        let pane: CommandContext.Pane
        let selectionSurface: GhosttySurface?
        if let s, let origin, scratchSurfaces[s.id] === origin {
            pane = .scratch
            selectionSurface = origin
        } else if let s, let origin, splitSurfaces[s.id] === origin {
            pane = .right
            selectionSurface = origin
        } else if let s, let origin, surfaces[s.id] === origin {
            pane = .left
            selectionSurface = origin
        } else if let s, s.splitFocused, let split = splitSurfaces[s.id] {
            pane = .right
            selectionSurface = split
        } else {
            pane = .left
            selectionSurface = s.flatMap { surfaces[$0.id] }
        }
        let context = CommandContext(sessionID: s?.id.uuidString ?? "", sessionName: s?.displayName ?? "",
                                     sessionPWD: s?.effectiveCwd ?? "",
                                     workspaceID: workspace?.id.uuidString ?? "",
                                     workspaceName: workspace?.name ?? "",
                                     windowID: windowID.uuidString,
                                     windowName: gLibrary.windows.first(where: { $0.id == windowID })?.name ?? "",
                                     pane: pane, selection: selectionSurface?.readSelection() ?? "",
                                     socket: gControlServer.resolvedSocketPath)
        let controllerOrigin = customCommandOrigin
        let launcher = controllerOrigin.launcher
        LinuxCustomCommandProcess.launch(command: cmd, context: context, launcher: launcher) { [weak self] failure in
            runOnMain { [weak self, weak controllerOrigin] in
                MainActor.assumeIsolated {
                    guard let self, let controllerOrigin,
                          self.customCommandOrigin === controllerOrigin,
                          gWindows[self.windowID] === self else { return }
                    controllerOrigin.deliverIfActive {
                        self.showToast(failure.toast(commandName: cmd.name))
                    }
                }
            }
        }
    }

    func configDirectory() -> URL {
        ConfigPaths.configDirectory(setting: linuxSettingsStore().load().configDirectory,
                                    stateDir: ProcessInfo.processInfo.environment["AGTERM_STATE_DIR"],
                                    home: FileManager.default.homeDirectoryForCurrentUser)
    }

    func editKeymap() {
        guard let id = store.selectedSessionID else { return }
        let path = ConfigPaths.keymapPath(configDirectory: configDirectory()).path
        store.openOverlay(id, command: ConfigPaths.editorCommand(forPath: path), sizePercent: 95)
        reconcile()
    }

    func editGhosttyConfig() {
        guard let id = store.selectedSessionID else { return }
        let path = ConfigPaths.ghosttyConfigPath(configDirectory: configDirectory()).path
        store.openOverlay(id, command: ConfigPaths.editorCommand(forPath: path), sizePercent: 95)
        reconcile()
    }

    func syncSplit(_ s: Session) {
        if dashboard.isOpen,
           dashboardRuntime.targets.values.contains(where: {
               if case .session(let id, _) = $0 { return id == s.id }
               return false
           }) { return }
        // `layoutSplit` is the only site that parents a pane host and needs both; without the primary a
        // freshly created split host would stay unparented and floating forever.
        guard let paned = sessionPanes[s.id], let primaryHost = primaryPaneHosts[s.id] else { return }
        if s.isSplit, splitSurfaces[s.id] == nil {
            let launch = paneLaunchProvider(for: s, pane: .right)
            let split = GhosttySurface(sessionID: s.id, cwd: s.initialSplitCwd ?? s.effectiveCwd,
                                       env: launch.environment, controller: self,
                                       role: .split, fontSize: s.fontSize,
                                       backedByZmx: launch.backedByZmx)
            split.launchSeed = launch
            if let identity = s.splitPaneIdentity {
                gSpawnRegistry.enqueue(split, key: identity, shouldPace: launch.shouldPace)
            }
            s.splitSurface = split
            splitSurfaces[s.id] = split
            installPaneExitHandler(split, sessionID: s.id)
            let paneHost = OpaquePointer(gtk_overlay_new())
            gtk_overlay_set_child(paneHost, W(split.rootWidget))
            splitPaneHosts[s.id] = paneHost
        }
        if let split = splitSurfaces[s.id] {
            if s.splitSurface == nil {
                collapseSplit(paned, dropping: splitPaneHosts[s.id], showing: primaryHost)
                splitSurfaces[s.id] = nil
                splitPaneHosts[s.id] = nil
            } else {
                layoutSplit(s, paned: paned, split: split)
                if s.isSplit {
                    split.refresh()
                    surfaces[s.id]?.refresh()
                    restoreSplitRatio(s)
                }
            }
        }
        updatePaneDim(s)
    }

    /// Pane roles are mutable (`session.swap`), so child exit must resolve the surface's current
    /// model role rather than retain the role it had when its GTK host was created.
    func installPaneExitHandler(_ surface: GhosttySurface, sessionID: UUID) {
        surface.onExit = { [weak self, weak surface] in
            guard let self, let surface,
                  let session = self.store.session(withID: sessionID) else {
                self?.reconcile()
                return
            }
            if session.surface === surface {
                self.closePrimaryPane(sessionID)
            } else if session.splitSurface === surface {
                self.closeSplitPane(sessionID)
            } else {
                self.reconcile()
            }
        }
    }

    /// Collapse a split onto its surviving host: free the DEAD host's slot, leaving the survivor's — and so
    /// its realization — untouched ([[libghostty]]), then show it. The show is not redundant: a tmux-style
    /// maximization hid one host, and no `layoutSplit` pass runs for this session again.
    func collapseSplit(_ paned: OpaquePointer, dropping dead: OpaquePointer?,
                       showing survivor: OpaquePointer) {
        if let dead {
            let widget = W(dead)
            if gtk_paned_get_start_child(paned) == widget { gtk_paned_set_start_child(paned, nil) }
            if gtk_paned_get_end_child(paned) == widget { gtk_paned_set_end_child(paned, nil) }
        }
        gtk_widget_set_visible(W(survivor), 1)
    }

    /// True once the session's primary pane host holds the paned's END slot — the state a primary-pane
    /// promotion leaves behind ([[libghostty]]). Physical left/right and the divider fraction both invert
    /// with it.
    func primaryInEndSlot(_ id: UUID) -> Bool {
        guard let paned = sessionPanes[id], let primary = primaryPaneHosts[id] else { return false }
        return gtk_paned_get_end_child(paned) == W(primary)
    }

    /// Converts between a session's stored `splitRatio` (always the PRIMARY pane's share) and a GtkPaned
    /// position fraction (always the START child's). The two invert once the primary holds the end slot;
    /// the mapping is its own inverse, so one call serves both directions.
    func panedFraction(_ ratio: Double, session id: UUID) -> Double {
        primaryInEndSlot(id) ? 1 - ratio : ratio
    }

    private func layoutSplit(_ s: Session, paned: OpaquePointer, split: GhosttySurface) {
        guard let primary = primaryPaneHosts[s.id], let splitHost = splitPaneHosts[s.id] else { return }
        let primaryWidget = W(primary)
        let splitWidget = W(splitHost)
        let layout = SplitPaneLayout(isSplit: s.isSplit, splitFocused: s.splitFocused)
        let orientation = s.splitAxis == .topBottom ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL
        if gtk_orientable_get_orientation(paned) != orientation {
            splitAxisTransitions.insert(s.id)
            gtk_orientable_set_orientation(paned, orientation)
            splitAxisTransitions.remove(s.id)
        }
        // The only placement site: the primary keeps the slot it already holds and the split fills the
        // other. GtkPaned gives the sole visible child the full allocation, so the tmux-style hidden-split
        // maximization is visibility alone, with no rehosting. Both hosts are held because a slot setter
        // unparents whatever occupies the slot it writes, and either host can be that occupant.
        let inEnd = primaryInEndSlot(s.id)
        let startWidget = inEnd ? splitWidget : primaryWidget
        let endWidget = inEnd ? primaryWidget : splitWidget
        withWidgetRefHeld(primary) {
            withWidgetRefHeld(splitHost) {
                if gtk_paned_get_start_child(paned) != startWidget {
                    gtk_paned_set_start_child(paned, startWidget)
                }
                if gtk_paned_get_end_child(paned) != endWidget {
                    gtk_paned_set_end_child(paned, endWidget)
                }
            }
        }
        gtk_widget_set_visible(primaryWidget, layout.primaryVisible ? 1 : 0)
        gtk_widget_set_visible(splitWidget, layout.splitVisible ? 1 : 0)
    }

    func capturePanedRatio(_ paned: OpaquePointer?) {
        guard let paned, let (sid, _) = sessionPanes.first(where: { $0.value == paned }),
              !splitRatioRestore.isSuppressed(sid), !splitAxisTransitions.contains(sid) else { return }
        guard let session = store.session(withID: sid) else { return }
        let extent = session.splitAxis == .topBottom
            ? gtk_widget_get_height(W(paned)) : gtk_widget_get_width(W(paned))
        guard extent > 0 else { return }
        let ratio = panedFraction(Double(gtk_paned_get_position(paned)) / Double(extent), session: sid)
        guard ratio > AppStore.splitRatioMin, ratio < AppStore.splitRatioMax else { return }
        if let cur = session.splitRatio, abs(cur - ratio) < 0.004 { return }
        session.splitRatio = ratio
        layoutSaveDebouncer.schedule(after: 0.4) { [weak self] in self?.store.save() }
    }

    func resetSplitRatio(_ gesture: OpaquePointer?, x: Double, y: Double) {
        guard let gesture, let panedWidget = gtk_event_controller_get_widget(gesture) else { return }
        let paned = OpaquePointer(panedWidget)
        guard let (sid, _) = sessionPanes.first(where: { $0.value == paned }),
              let session = store.session(withID: sid),
              Self.splitDividerHit(
                  x: session.splitAxis == .topBottom ? y : x,
                  dividerPosition: Double(gtk_paned_get_position(paned)), splitVisible: session.isSplit)
        else { return }
        session.splitRatio = AppStore.splitRatioDefault
        applySplitRatio(to: session)
    }

    static func splitDividerHit(x: Double, dividerPosition: Double, splitVisible: Bool) -> Bool {
        splitVisible && abs(x - dividerPosition) <= 10
    }

    private func restoreSplitRatio(_ s: Session) {
        guard let paned = sessionPanes[s.id], s.splitRatio != nil else { return }
        scheduleSplitRatioRestore(sessionID: s.id, paned: paned)
    }

    func scheduleSplitRatioRestore(sessionID: UUID, paned: OpaquePointer) {
        let generation = splitRatioRestore.begin(windowID: windowID, sessionID: sessionID, paned: paned)
        guard tryRestorePanedRatio(
            windowID: windowID, sessionID: sessionID, paned: paned, generation: generation) != 0 else { return }
        let context = SplitRatioRestoreTickContext(
            controller: self, sessionID: sessionID, paned: paned, generation: generation)
        let sourceID = g_timeout_add_full(
            G_PRIORITY_DEFAULT, 50, restorePanedRatioTick,
            Unmanaged.passRetained(context).toOpaque(), releaseSplitRatioRestoreTick)
        splitRatioRestore.setSource(sourceID, sessionID: sessionID, generation: generation)
    }

    @discardableResult
    func tryRestorePanedRatio(
        windowID: UUID, sessionID: UUID, paned: OpaquePointer, generation: UInt64
    ) -> gboolean {
        guard self.windowID == windowID,
              splitRatioRestore.matches(
                windowID: windowID, sessionID: sessionID, paned: paned, generation: generation),
              sessionPanes[sessionID] == paned,
              let ratio = store.session(withID: sessionID)?.splitRatio else {
            splitRatioRestore.complete(sessionID: sessionID, generation: generation)
            return 0
        }
        guard let session = store.session(withID: sessionID) else { return 1 }
        let extent = session.splitAxis == .topBottom
            ? gtk_widget_get_height(W(paned)) : gtk_widget_get_width(W(paned))
        guard extent > 0 else { return 1 }
        gtk_paned_set_position(paned, Int32(panedFraction(ratio, session: sessionID) * Double(extent)))
        splitRatioRestore.complete(sessionID: sessionID, generation: generation)
        return 0
    }

    func applySplitRatio(to session: Session) {
        store.save()
        guard let paned = sessionPanes[session.id], session.splitRatio != nil else { return }
        scheduleSplitRatioRestore(sessionID: session.id, paned: paned)
    }

    private func removeSession(_ id: UUID) {
        abandonSearch(ownedBy: id)
        splitRatioRestore.cancel(sessionID: id)
        scratchSurfaces[id]?.teardown()
        scratchSurfaces[id] = nil
        if let frame = floatingOverlayFrames[id] {
            gtk_overlay_remove_overlay(deck, W(frame))
            floatingOverlayFrames[id] = nil
        }
        overlaySurfaces[id]?.teardown()
        overlaySurfaces[id] = nil
        leftOverlaySurfaces[id]?.teardown()
        leftOverlaySurfaces[id] = nil
        leftOverlayWashes[id] = nil
        leftOverlayWashProviders[id] = nil
        rightOverlaySurfaces[id]?.teardown()
        rightOverlaySurfaces[id] = nil
        rightOverlayWashes[id] = nil
        rightOverlayWashProviders[id] = nil
        splitSurfaces[id]?.teardown()
        splitSurfaces[id] = nil
        surfaces[id]?.teardown()
        if let stack = sessionStacks[id] { gtk_overlay_remove_overlay(deck, W(stack)) }
        surfaces[id] = nil
        sessionPanes[id] = nil
        primaryPaneHosts[id] = nil
        splitPaneHosts[id] = nil
        sessionStacks[id] = nil
    }

    /// Dashboard mirrors the primary/split panes, so expose each member's `main` page beneath its
    /// opaque host even when scratch or a full overlay was previously on top.
    func showDashboardSourcePages() {
        for id in Set(dashboard.members.map(\.session)) {
            guard let stack = sessionStacks[id] else { continue }
            "main".withCString { gtk_stack_set_visible_child_name(stack, $0) }
        }
    }

    /// Restore the page that owns each session after Dashboard stops mirroring its main panes.
    func restoreSessionTopPages() {
        for session in store.workspaces.flatMap(\.sessions) {
            guard let stack = sessionStacks[session.id] else { continue }
            let page: String
            if session.fullOverlayActive {
                page = "overlay"
            } else if session.scratchActive {
                page = "scratch"
            } else {
                page = "main"
            }
            page.withCString { gtk_stack_set_visible_child_name(stack, $0) }
        }
    }

    /// Push every deck page to the presentation the current selection implies, then focus the active pane.
    ///
    /// The no-active-session case must still run: `store.activeSession` is nil whenever the visible tree
    /// names none, which is exactly what a soft close of the LAST session produces while its record waits out
    /// the undo grace — and `reconcile` deliberately KEEPS that session's surfaces alive then
    /// (`pendingHeldSessionIDs`). Returning early would leave the just-closed stack on screen at full opacity
    /// and still accepting keystrokes until the grace finalizer tears it down, so nil active means every page
    /// goes inactive rather than keeping whatever the last selection left behind.
    func showActive(focus: Bool = true) {
        let active = store.activeSession
        for (id, stack) in sessionStacks {
            let presentation = DeckPagePresentation(pageID: id, activeID: active?.id, dashboardOpen: dashboard.isOpen)
            gtk_widget_set_opacity(W(stack), presentation.opacity)
            gtk_widget_set_can_target(W(stack), presentation.canTarget ? 1 : 0)
            gtk_widget_set_child_visible(W(stack), presentation.childVisible ? 1 : 0)
        }
        updateFloatingOverlayVisibility(activeID: active?.id)
        updateCoverDimming()
        if focus, let active {
            if active.programOverlayActive {
                overlaySurfaces[active.id]?.grabFocus()
            } else if active.scratchActive {
                scratchSurfaces[active.id]?.grabFocus()
            } else if let pane = active.focusedOverlayPane {
                paneOverlaySurface(active.id, pane: pane)?.grabFocus()
            } else if active.splitFocused, let split = splitSurfaces[active.id] {
                split.grabFocus()
            } else {
                surfaces[active.id]?.grabFocus()
            }
        }
        updateToggleIcons()
    }

    /// Put keyboard focus back on the active surface when GTK has just stranded it.
    func refocusIfStranded() {
        // A late callback can reach this after `windowWillClose` tore the widget tree down.
        guard gWindows[windowID] === self else { return }
        let focus = gtk_window_get_focus(WIN(window))
        if let focus {
            // "Unmapped" means STRANDED only while the TOPLEVEL is mapped — an unmapped window reports
            // `mapped == 0` for every descendant, a live focus owner included.
            guard gtk_widget_get_mapped(W(window)) != 0, gtk_widget_get_mapped(focus) == 0 else { return }
        }
        focusActiveSurface()
    }

    /// Hand the keyboard to whichever surface is on screen and should own it. `refocusIfStranded()` is
    /// this plus the "GTK actually stranded focus" guard; reach it directly only when the loss is one
    /// that guard cannot see.
    func focusActiveSurface() {
        // Teardown paths clear their own zoom target first, so a stale target is not a case to design for.
        if let target = terminalZoom.target {
            surface(for: target)?.grabFocus()
            return
        }
        if quickVisible {
            quickSurface?.grabFocus()
            return
        }
        guard !dashboard.isOpen, let id = store.activeSession?.id else { return }
        searchTargetSurface(for: id)?.grabFocus()
    }

    /// The shape a path that hands the keyboard back after a MODE CHANGE must use: `showActive()`'s own
    /// focus leg is deck-only, so it misses the quick terminal, the zoom host and the dashboard.
    func showActiveFocusingVisibleSurface() {
        showActive(focus: false)
        focusActiveSurface()
    }

    /// Detach a dying popover and hand the keyboard back when the popover was holding it — the dismissal
    /// seam both the context menu and the session picker owe.
    ///
    /// `popdown: true` (a programmatic dismissal) emits `"closed"` synchronously from inside the popdown,
    /// so such a caller MUST clear its own popover handle FIRST, or the popover is unparented twice.
    /// `popdown: false` is GTK's own dismissal arriving on `"closed"`.
    ///
    /// The unparent is ordered BEFORE the grab — on the `"closed"` path the popdown is still in flight and
    /// moves focus to the parent afterwards, undoing a grab taken while the popover is still parented —
    /// and stays SYNCHRONOUS, since a popover left parented at window destroy hangs the close.
    ///
    /// `refocus: false` keeps the detach and drops only the grab, but still CONSUMES the search-entry
    /// capture, so such a caller must read the flag before dismissing.
    func detachPopover(_ popover: OpaquePointer, popdown: Bool, refocus: Bool = true) {
        let host = gtk_widget_get_parent(W(popover))
        let stoleKeyboardFromSearchEntry = popoverTookKeyboardFromSearchEntry
        popoverTookKeyboardFromSearchEntry = false
        if popdown { gtk_popover_popdown(POPOVER(popover)) }
        let focus = gtk_window_get_focus(WIN(window))
        let heldTheKeyboard = focus == nil || focus == host
            || (focus.map { gtk_widget_is_ancestor($0, W(popover)) != 0 } ?? false)
        if gtk_widget_get_parent(W(popover)) != nil { gtk_widget_unparent(W(popover)) }
        guard refocus else { return }
        if stoleKeyboardFromSearchEntry, restoreSearchEntryFocus() { return }
        if heldTheKeyboard { focusActiveSurface() }
    }

    /// The ONLY legal popup seam, never a bare `gtk_popover_popup`: it records whether the keyboard sat
    /// in the in-terminal search entry, which is unknowable by dismissal time. `detachPopover` consumes
    /// the capture. `keepingCapture` carries a still-live one across a REPLACEMENT, where re-reading the
    /// entry answers `false` because the outgoing popover holds the keyboard.
    func popupPopover(_ popover: OpaquePointer, keepingCapture: Bool = false) {
        popoverTookKeyboardFromSearchEntry = keepingCapture || searchEntryHoldsKeyboard()
        gtk_popover_popup(POPOVER(popover))
    }

    /// A deliberate focus transfer wins over the owner recorded before a popover took the keyboard.
    /// Clear it at the transfer seam; dismissal-time focus is unreliable under reactivating window managers.
    func invalidatePopoverSearchEntryCapture() {
        popoverTookKeyboardFromSearchEntry = false
    }

    /// Whether a REPLACEMENT opener may carry the capture: only while `outgoing` still OWNS the keyboard.
    /// BOUNDARY, measured — do NOT apply this to the dismissal-time repairs (`rebuildSidebar()`'s tail,
    /// `activateSessionPickerRow`); both covering `chrome-focus-popovers` steps fail when it is.
    func searchEntryCaptureSurvives(_ outgoing: OpaquePointer?) -> Bool {
        guard popoverTookKeyboardFromSearchEntry, let outgoing else { return false }
        guard let focus = gtk_window_get_focus(WIN(window)) else { return true }
        return focus == W(outgoing) || gtk_widget_is_ancestor(focus, W(outgoing)) != 0
    }

    private func updateFloatingOverlayVisibility(activeID: UUID?) {
        for (id, frame) in floatingOverlayFrames {
            let visible = id == activeID && (store.session(withID: id)?.overlayActive == true)
            gtk_widget_set_visible(W(frame), visible ? 1 : 0)
        }
    }

    func surfaceDidReportProgress(_ id: UUID, percent: Int?) {
        if let percent { sessionProgress[id] = percent } else { sessionProgress.removeValue(forKey: id) }
        if id == store.selectedSessionID { updateTitle() }
    }

    func updateTitle() {
        let settings = linuxSettingsStore().load()
        let windowInfo = library.windows.first(where: { $0.id == windowID })
        let normalTitle = LinuxModalTitle.normal(sessionName: store.activeSession?.displayName, window: windowInfo)
        var title = store.activeSession?.displayName ?? "agterm"
        if let id = store.selectedSessionID, let p = sessionProgress[id] {
            title = (p < 0 ? "⋯ " : "\(p)% ") + title
        }
        title.withCString { gtk_window_set_title(WIN(window), $0) }
        if let titleWidget {
            let hidden = settings.resolvedHiddenInterfaceElements
            let composition = TitlebarComposition.compose(
                .init(
                    sessionName: hidden.contains(.sessionName)
                        ? nil : (store.activeSession?.displayName ?? "agterm"),
                    windowName: hidden.contains(.windowName) || windowInfo?.hasCustomName != true
                        ? nil : windowInfo?.name,
                    context: hidden.contains(.sessionContext) ? nil : store.activeSession?.context,
                    detail: store.activeSession?.subtitleDetail ?? ""
                ),
                mode: settings.effectiveToolbarMode
            )
            composition.title.withCString { adw_window_title_set_title(titleWidget, $0) }
            composition.subtitle.withCString { adw_window_title_set_subtitle(titleWidget, $0) }
        }
        normalTitle.withCString { value in
            if let zoomTitleLabel { gtk_label_set_text(zoomTitleLabel, value) }
        }
        LinuxModalTitle.dashboard(window: windowInfo).withCString { value in
            if let dashboardTitle = dashboardRuntime.titleLabel {
                gtk_label_set_text(dashboardTitle, value)
            }
        }
    }

    func monospaceFonts() -> [String] {
        guard let ctx = gtk_widget_get_pango_context(W(window)) else { return [] }
        var families: UnsafeMutablePointer<UnsafeMutablePointer<PangoFontFamily>?>?
        var count: Int32 = 0
        pango_context_list_families(ctx, &families, &count)
        defer { g_free(families) }
        var names: Set<String> = []
        for i in 0..<Int(count) {
            guard let fam = families?[i], pango_font_family_is_monospace(fam) != 0,
                  let c = pango_font_family_get_name(fam) else { continue }
            names.insert(String(cString: c))
        }
        return names.sorted()
    }

    func sessionDidReportTitle(_ id: UUID, _ title: String, isSplit: Bool, loginShell: String? = nil) {
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard store.recordTitle(title, forSession: id, isSplit: isSplit,
                                loginShell: loginShell, home: home) else { return }
        if id == store.selectedSessionID { updateTitle() }
        scheduleSidebarMetadataRefresh()
    }

    func sessionDidReportPwd(_ id: UUID, _ pwd: String, isSplit: Bool) {
        guard store.recordPwd(pwd, forSession: id, isSplit: isSplit) else { return }
        if id == store.selectedSessionID { updateTitle() }
        scheduleSidebarMetadataRefresh()
    }

    /// Coalesce OSC title/pwd churn from every session into one sidebar rebuild.
    ///
    /// A rebuild destroys and re-creates every row, so it must NOT land while the user is interacting with
    /// one: it would tear down an in-progress inline rename (whose entry commits its half-typed text on the
    /// focus-out that disposal triggers) and dismiss an open context menu — both from a background shell's
    /// prompt redraw. Those interactions are short, so the refresh re-arms itself at a slower cadence
    /// instead of being dropped; whichever ends the interaction rebuilds anyway, and the retry is then a
    /// cheap no-op repaint. The gate is the shared `sidebarInteractionInProgress`, so this and the trailing
    /// soft-close reconcile defer on exactly the same condition.
    ///
    /// Internal rather than file-private because the app-level desktop-metrics observer in `App.swift`
    /// routes its own notification burst through this same debouncer and interaction gate.
    func scheduleSidebarMetadataRefresh(after delay: TimeInterval = 0.01) {
        sidebarMetadataDebouncer.schedule(after: delay) { [weak self] in
            guard let self else { return }
            guard !self.sidebarInteractionInProgress else {
                self.scheduleSidebarMetadataRefresh(after: AppController.sidebarInteractionRetryInterval)
                return
            }
            self.rebuildSidebar()
        }
    }

    func sessionDidReportFontSize(_ id: UUID, _ size: Double) {
        store.setFontSize(id, size)
    }

    func surfaceDidFocus(_ id: UUID, isSplit: Bool) {
        guard store.session(withID: id)?.hasSplit == true else { return }
        store.setPaneFocus(isSplit, forSession: id)
        if let s = store.session(withID: id) {
            updatePaneDim(s)
            updateSessionName(id)
        }
        if id == store.selectedSessionID { updateTitle() }
    }

    static func paneSurfaceOpacities(
        isSplit: Bool, splitFocused: Bool, dimmed: Double, backdropActive: Bool
    ) -> (left: Double, right: Double) {
        guard !backdropActive else { return (1, 1) }
        return (isSplit && splitFocused ? dimmed : 1.0,
                isSplit && !splitFocused ? dimmed : 1.0)
    }

    static func paneOverlayWashOpacity(
        isSplit: Bool, splitFocused: Bool, pane: OverlayPane,
        scaledMuteOpacity: Double, backdropActive: Bool
    ) -> Double {
        guard isSplit, !backdropActive else { return 0 }
        let inactive = pane == .left ? splitFocused : !splitFocused
        return inactive ? scaledMuteOpacity : 0
    }

    static func scaledMuteOpacity(_ muteOpacity: Double, renderedWindowOpacity: Double) -> Double {
        min(1, max(0, muteOpacity)) * min(1, max(0, renderedWindowOpacity))
    }

    static func paneOverlayWashColor(fixedBackground: String?, themeBackground: String?) -> String {
        fixedBackground ?? themeBackground ?? "#000000"
    }

    func renderedWindowOpacity(_ override: Double? = nil) -> Double {
        let value = override ?? pendingBackgroundOpacity ?? linuxSettingsStore().load().backgroundOpacity ?? 1
        return min(1, max(0, value))
    }

    func updatePaneDim(_ s: Session, windowOpacity: Double? = nil) {
        let strength = linuxSettingsStore().load().inactivePaneMuteStrength ?? AppSettings.defaultInactivePaneMuteStrength
        let rawMuteOpacity = AppSettings.muteOpacity(strength: strength)
        let windowOpacity = renderedWindowOpacity(windowOpacity)
        let muteOpacity = Self.scaledMuteOpacity(rawMuteOpacity, renderedWindowOpacity: windowOpacity)
        let dimmed = 1.0 - muteOpacity
        let floatingProgram = s.programOverlayActive && s.overlaySizePercent != nil
        let backdropActive = s.id == store.selectedSessionID && (quickVisible || floatingProgram)
        let opacities = Self.paneSurfaceOpacities(
            isSplit: s.isSplit, splitFocused: s.splitFocused,
            dimmed: dimmed, backdropActive: backdropActive)
        if let main = surfaces[s.id] { gtk_widget_set_opacity(W(main.rootWidget), opacities.left) }
        if let split = splitSurfaces[s.id] { gtk_widget_set_opacity(W(split.rootWidget), opacities.right) }
        if let wash = leftOverlayWashes[s.id] {
            updatePaneOverlayWashColor(s, pane: .left)
            gtk_widget_set_opacity(W(wash), Self.paneOverlayWashOpacity(
                isSplit: s.isSplit, splitFocused: s.splitFocused, pane: .left,
                scaledMuteOpacity: muteOpacity, backdropActive: backdropActive))
        }
        if let wash = rightOverlayWashes[s.id] {
            updatePaneOverlayWashColor(s, pane: .right)
            gtk_widget_set_opacity(W(wash), Self.paneOverlayWashOpacity(
                isSplit: s.isSplit, splitFocused: s.splitFocused, pane: .right,
                scaledMuteOpacity: muteOpacity, backdropActive: backdropActive))
        }
    }

    private func updatePaneOverlayWashColor(_ session: Session, pane: OverlayPane) {
        guard let provider = paneOverlayWashProvider(session.id, pane: pane) else { return }
        let color = Self.paneOverlayWashColor(
            fixedBackground: session.paneOverlay(pane)?.backgroundColor,
            themeBackground: GhosttyApp.shared.currentThemeBackgroundHex)
        "* { background-color: \(color); }".withCString {
            gtk_css_provider_load_from_string(cast(provider), $0)
        }
    }

    /// Floating program cards and the quick terminal wash out the content behind them. HUDs stay passive
    /// and do not add a wash, matching the upstream overlay distinction.
    func updateCoverDimming(windowOpacity: Double? = nil) {
        let strength = linuxSettingsStore().load().inactivePaneMuteStrength
            ?? AppSettings.defaultInactivePaneMuteStrength
        let muteOpacity = Self.scaledMuteOpacity(
            AppSettings.muteOpacity(strength: strength),
            renderedWindowOpacity: renderedWindowOpacity(windowOpacity))
        let dimmed = 1.0 - muteOpacity
        gtk_widget_set_opacity(W(sidebarBox), quickVisible ? dimmed : 1.0)
        if let dashboardHost = dashboardRuntime.host {
            gtk_widget_set_opacity(W(dashboardHost), quickVisible ? dimmed : 1.0)
        }
        let floatingOpacity = Self.floatingFrameOpacity(quickVisible: quickVisible, dimmed: dimmed)
        for frame in floatingOverlayFrames.values { gtk_widget_set_opacity(W(frame), floatingOpacity) }
        guard let active = store.activeSession, let stack = sessionStacks[active.id], !dashboard.isOpen else {
            return
        }
        let floatingProgram = active.programOverlayActive && active.overlaySizePercent != nil
        gtk_widget_set_opacity(W(stack), quickVisible || floatingProgram ? dimmed : 1.0)
    }

    static func floatingFrameOpacity(quickVisible: Bool, dimmed: Double) -> Double {
        quickVisible ? dimmed : 1
    }

    func updateAllPaneDimming(windowOpacity: Double? = nil) {
        for workspace in store.workspaces {
            for session in workspace.sessions { updatePaneDim(session, windowOpacity: windowOpacity) }
        }
        updateCoverDimming(windowOpacity: windowOpacity)
    }
}
