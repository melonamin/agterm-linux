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
    func reconcile(focusActive: Bool = true) {
        let dashboardRestore = prepareDashboardForReconcile()
        clearInvalidTerminalZoom()
        for ws in store.workspaces {
            for s in ws.sessions {
                ensurePrimary(s)
                syncSplit(s)
                syncScratch(s)
                syncOverlay(s, allowFocus: focusActive)   // after scratch so an open overlay wins the visible child
            }
        }
        // Drop closed sessions, but never one a pending close still holds for its undo window.
        var live = Set(store.workspaces.flatMap { $0.sessions.map(\.id) })
        live.formUnion(store.pendingHeldSessionIDs())
        for id in Array(surfaces.keys) where !live.contains(id) { removeSession(id) }
        rebuildSidebar()
        showActive(focus: focusActive)
        updateTitle()
        updateAttentionButton()
        updateDashboardButton()
        restoreDashboardAfterReconcile(dashboardRestore)
    }

    /// The `AGTERM_*` env injected into a session's spawned shells (main/split/scratch) so the
    /// agent-status hooks + `{AGT_X}` tokens can call back over the control socket.
    private func sessionEnv(for s: Session, pane: StatusPane? = nil) -> [String: String] {
        SurfaceEnvironment.session(sessionID: s.id, windowID: windowID,
                                   workspaceID: store.workspace(forSession: s.id)?.id,
                                   socketPath: gControlServer.boundSocketPath ?? ControlServer.defaultSocketPath(),
                                   programVersion: LinuxAppMetadata.version, pane: pane,
                                   paneToken: pane == nil ? nil : UUID().uuidString)
    }

    /// Each session's deck page is an outer GtkStack ("main" = a GtkPaned holding the
    /// pane(s), "scratch" = the full-overlay scratch shell). The primary pane is the
    /// paned's start child.
    private func ensurePrimary(_ s: Session) {
        guard surfaces[s.id] == nil,
              let paned = OpaquePointer(gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)),
              let stack = op(gtk_stack_new()) else { return }
        sessionPanes[s.id] = paned
        connect(paned, "notify::position", unsafeBitCast(onPanedPosition as @convention(c) (OpaquePointer?, OpaquePointer?, gpointer?) -> Void, to: GCallback.self))
        sessionStacks[s.id] = stack
        let hadForeground = s.foregroundCommand != nil
        let restoreInput = consumeRestoreInput(&s.foregroundCommand)
        let inputs = CommandRestore.RestoreInputs(
            wasRestored: s.wasRestored,
            restoreEnabled: restoreEnabled,
            hadForeground: hadForeground,
            foregroundInput: restoreInput,
            initialCommand: s.initialCommand,
            restoreOverride: s.takePendingRestoreOverride(pane: .left)
        )
        let plan = CommandRestore.restorePlan(inputs)
        let surf = GhosttySurface(sessionID: s.id, cwd: s.effectiveCwd, command: plan.command,
                                  env: sessionEnv(for: s, pane: .left), controller: self,
                                  waitAfterCommand: s.commandWait, fontSize: s.fontSize,
                                  initialInput: plan.initialInput)
        let sid = s.id
        surf.onExit = { [weak self] in self?.closePrimaryPane(sid) }
        s.surface = surf
        surfaces[s.id] = surf
        gtk_paned_set_start_child(paned, W(surf.glArea))
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
                "scratch".withCString { _ = gtk_stack_add_named(stack, W(sc.glArea), $0) }
            }
            "scratch".withCString { gtk_stack_set_visible_child_name(stack, $0) }
        } else {
            "main".withCString { gtk_stack_set_visible_child_name(stack, $0) }
            if let sc = scratchSurfaces[s.id], s.scratchSurface == nil {
                gtk_stack_remove(stack, W(sc.glArea))
                scratchSurfaces[s.id] = nil
            }
        }
    }

    /// Create/show/hide the ephemeral overlay terminal (runs `overlayCommand` over the session).
    private func syncOverlay(_ s: Session, allowFocus: Bool) {
        guard let stack = sessionStacks[s.id] else { return }
        if s.overlayActive {
            if overlaySurfaces[s.id] == nil, let cmd = s.overlayCommand {
                let codePath = NSTemporaryDirectory() + "agterm-ovl-\(UUID().uuidString).code"
                var ovlEnv = sessionEnv(for: s)
                ovlEnv[OverlayCapture.cmdEnvKey] = cmd
                ovlEnv[OverlayCapture.codeEnvKey] = codePath
                let ov = GhosttySurface(sessionID: s.id, cwd: s.overlayCwd ?? s.effectiveCwd,
                                        command: "sh -c " + Self.singleQuoted(OverlayCapture.shellLine),
                                        env: ovlEnv, controller: self, waitAfterCommand: s.overlayWait,
                                        role: .overlay,
                                        reportsPaneState: false)
                let sid = s.id
                let owner = windowID
                ov.onExit = {
                    runOnMain { MainActor.assumeIsolated {
                        if let txt = try? String(contentsOfFile: codePath, encoding: .utf8),
                           let code = OverlayCapture.parseExitCode(txt) {
                            gWindows[owner]?.store.recordOverlayExit(sid, code: code)
                        }
                        try? FileManager.default.removeItem(atPath: codePath)
                        gWindows[owner]?.closeOverlay(sid)
                    } }
                }
                s.overlaySurface = ov
                overlaySurfaces[s.id] = ov
                if let pct = s.overlaySizePercent, let overlay = deckOverlay {
                    let frame = OpaquePointer(gtk_frame_new(nil))
                    gtk_widget_add_css_class(W(frame), "card")
                    gtk_widget_add_css_class(W(frame), "agterm-quick")
                    gtk_widget_set_overflow(W(frame), GTK_OVERFLOW_HIDDEN)   // clip GL child to the rounded card; see LinuxQuickCardPolicy
                    gtk_widget_set_halign(W(frame), GTK_ALIGN_CENTER)
                    gtk_widget_set_valign(W(frame), GTK_ALIGN_CENTER)
                    let dw = gtk_widget_get_width(W(overlay)), dh = gtk_widget_get_height(W(overlay))
                    gtk_widget_set_size_request(W(frame), max(Int32(240), dw * Int32(pct) / 100),
                                                max(Int32(160), dh * Int32(pct) / 100))
                    gtk_frame_set_child(cast(frame), W(ov.glArea))
                    gtk_overlay_add_overlay(overlay, W(frame))
                    gtk_widget_set_visible(W(frame), s.id == store.selectedSessionID ? 1 : 0)
                    floatingOverlayFrames[s.id] = frame
                } else {
                    "overlay".withCString { _ = gtk_stack_add_named(stack, W(ov.glArea), $0) }
                }
                ov.realizeWidgetIfNeeded()
            }
            if floatingOverlayFrames[s.id] != nil {
                if allowFocus, s.id == store.selectedSessionID { overlaySurfaces[s.id]?.grabFocus() }
            } else {
                "overlay".withCString { gtk_stack_set_visible_child_name(stack, $0) }
                if allowFocus, s.id == store.selectedSessionID { overlaySurfaces[s.id]?.grabFocus() }
            }
        } else if let ov = overlaySurfaces[s.id], s.overlaySurface == nil {
            if let frame = floatingOverlayFrames[s.id], let overlay = deckOverlay {
                gtk_overlay_remove_overlay(overlay, W(frame))
                floatingOverlayFrames[s.id] = nil
            } else {
                (s.scratchActive ? "scratch" : "main").withCString { gtk_stack_set_visible_child_name(stack, $0) }
                gtk_stack_remove(stack, W(ov.glArea))
            }
            overlaySurfaces[s.id] = nil
        }
    }

    private static func singleQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The overlay's command exited (or a control close): tear it down + reconcile.
    func closeOverlay(_ id: UUID) {
        store.closeOverlay(id)
        reconcile()
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

    private var restoreEnabled: Bool { linuxSettingsStore().load().restoreRunningCommand ?? false }

    private func consumeRestoreInput(_ argv: inout [String]?) -> String? {
        guard let captured = argv else { return nil }
        argv = nil
        guard restoreEnabled else { return nil }
        return CommandRestore.shellQuotedLine(captured) + "\n"
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
                                     socket: gControlServer.boundSocketPath ?? "")
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
        guard let paned = sessionPanes[s.id] else { return }
        if s.isSplit, splitSurfaces[s.id] == nil {
            let capturedInput = consumeRestoreInput(&s.splitForegroundCommand)
            let restoreInput = CommandRestore.restoreInput(
                restoreEnabled: restoreEnabled,
                restoreOverride: s.takePendingRestoreOverride(pane: .right),
                capturedInput: capturedInput
            )
            let split = GhosttySurface(sessionID: s.id, cwd: s.initialSplitCwd ?? s.effectiveCwd,
                                       env: sessionEnv(for: s, pane: .right), controller: self,
                                       role: .split, fontSize: s.fontSize,
                                       initialInput: restoreInput)
            let sid = s.id
            split.onExit = { [weak self] in self?.closeSplitPane(sid) }
            s.splitSurface = split
            splitSurfaces[s.id] = split
            gtk_paned_set_end_child(paned, W(split.glArea))
        }
        if let split = splitSurfaces[s.id] {
            if s.splitSurface == nil {
                if let primary = surfaces[s.id]?.glArea, gtk_paned_get_start_child(paned) != W(primary) {
                    gtk_paned_set_start_child(paned, nil)
                    gtk_paned_set_start_child(paned, W(primary))
                }
                gtk_paned_set_end_child(paned, nil)
                splitSurfaces[s.id] = nil
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

    private func layoutSplit(_ s: Session, paned: OpaquePointer, split: GhosttySurface) {
        guard let primary = surfaces[s.id]?.glArea else { return }
        let primaryWidget = W(primary)
        let splitWidget = W(split.glArea)
        let layout = SplitPaneLayout(isSplit: s.isSplit, splitFocused: s.splitFocused)
        // Keep both GtkGLAreas in stable paned slots for the split's entire lifetime. Unparenting a
        // GtkGLArea unrealizes it and invalidates the GL context that libghostty's surface was created
        // against; reattaching the same widget then leaves its terminal buffer alive but the pane blank.
        // GtkPaned gives the sole visible child the full allocation, so visibility alone implements the
        // tmux-style hidden-split maximization without rehosting either renderer.
        let startWidget = layout.startSlot == .primary ? primaryWidget : splitWidget
        let endWidget = layout.endSlot == .primary ? primaryWidget : splitWidget
        if gtk_paned_get_start_child(paned) != startWidget {
            gtk_paned_set_start_child(paned, startWidget)
        }
        if gtk_paned_get_end_child(paned) != endWidget {
            gtk_paned_set_end_child(paned, endWidget)
        }
        gtk_widget_set_visible(primaryWidget, layout.primaryVisible ? 1 : 0)
        gtk_widget_set_visible(splitWidget, layout.splitVisible ? 1 : 0)
    }

    func capturePanedRatio(_ paned: OpaquePointer?) {
        guard let paned, let (sid, _) = sessionPanes.first(where: { $0.value == paned }),
              !splitRatioRestore.isSuppressed(sid) else { return }
        let width = gtk_widget_get_width(W(paned))
        guard width > 0 else { return }
        let ratio = Double(gtk_paned_get_position(paned)) / Double(width)
        guard ratio > AppStore.splitRatioMin, ratio < AppStore.splitRatioMax,
              let s = store.session(withID: sid) else { return }
        if let cur = s.splitRatio, abs(cur - ratio) < 0.004 { return }
        s.splitRatio = ratio
        layoutSaveDebouncer.schedule(after: 0.4) { [weak self] in self?.store.save() }
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
        let width = gtk_widget_get_width(W(paned))
        guard width > 0 else { return 1 }
        gtk_paned_set_position(paned, Int32(ratio * Double(width)))
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
        if let frame = floatingOverlayFrames[id], let overlay = deckOverlay {
            gtk_overlay_remove_overlay(overlay, W(frame))
            floatingOverlayFrames[id] = nil
        }
        overlaySurfaces[id]?.teardown()
        overlaySurfaces[id] = nil
        splitSurfaces[id]?.teardown()
        splitSurfaces[id] = nil
        surfaces[id]?.teardown()
        if let stack = sessionStacks[id] { gtk_overlay_remove_overlay(deck, W(stack)) }
        surfaces[id] = nil
        sessionPanes[id] = nil
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
        if focus, let active {
            if active.overlayActive {
                overlaySurfaces[active.id]?.grabFocus()
            } else if active.scratchActive {
                scratchSurfaces[active.id]?.grabFocus()
            } else if active.splitFocused, let split = splitSurfaces[active.id] {
                split.grabFocus()
            } else {
                surfaces[active.id]?.grabFocus()
            }
        }
        updateToggleIcons()
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
            let sessionPart = hidden.contains(.sessionName) ? nil : (store.activeSession?.displayName ?? "agterm")
            let windowPart = hidden.contains(.windowName) || windowInfo?.hasCustomName != true ? nil : windowInfo?.name
            let visibleTitle: String
            switch (sessionPart, windowPart) {
            case let (session?, window?): visibleTitle = "\(session) — \(window)"
            case let (session?, nil): visibleTitle = session
            case let (nil, window?): visibleTitle = window
            case (nil, nil): visibleTitle = ""
            }
            visibleTitle.withCString { adw_window_title_set_title(titleWidget, $0) }
            let subtitle = settings.effectiveToolbarMode == .normal
                ? (store.activeSession?.subtitleDetail ?? "") : ""
            subtitle.withCString { adw_window_title_set_subtitle(titleWidget, $0) }
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

    func sessionDidReportTitle(_ id: UUID, _ title: String, isSplit: Bool) {
        guard store.recordTitle(title, forSession: id, isSplit: isSplit) else { return }
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
    private func scheduleSidebarMetadataRefresh(after delay: TimeInterval = 0.01) {
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
        if let s = store.session(withID: id) { updatePaneDim(s) }
        rebuildSidebar()
        if id == store.selectedSessionID { updateTitle() }
    }

    private func updatePaneDim(_ s: Session) {
        let strength = linuxSettingsStore().load().inactivePaneMuteStrength ?? AppSettings.defaultInactivePaneMuteStrength
        let dimmed = 1.0 - AppSettings.muteOpacity(strength: strength)
        if let main = surfaces[s.id]?.glArea {
            gtk_widget_set_opacity(W(main), s.isSplit && s.splitFocused ? dimmed : 1.0)
        }
        if let split = splitSurfaces[s.id]?.glArea {
            gtk_widget_set_opacity(W(split), s.isSplit && !s.splitFocused ? dimmed : 1.0)
        }
    }

    func updateAllPaneDimming() {
        for workspace in store.workspaces {
            for session in workspace.sessions { updatePaneDim(session) }
        }
    }
}
