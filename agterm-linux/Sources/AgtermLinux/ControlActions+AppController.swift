import CGtk
import Foundation
import agtermCore

// Linux adapter for agtermCore's upstream `ControlActions` seam. The dispatcher owns command parsing and
// response shape; AppController keeps GTK/libghostty/window side effects.
extension AppController: ControlActions {
    enum ResolveResponse<T> {
        case success(T)
        case failure(ControlResponse)
    }

    // Internal rather than private: the `window.*` arms live in `ControlActions+AppControllerWindows.swift`
    // (the family split that keeps this file under the line cap) and share these response shapers.
    func ok(_ id: UUID? = nil) -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(id: id?.uuidString))
    }

    func err(_ message: String) -> ControlResponse {
        ControlResponse(ok: false, error: message)
    }

    private func resolveError(_ noun: String, target: String?, candidates: [UUID]) -> ControlResponse {
        if let target, case let .ambiguous(hits) = ControlResolve.resolve(target, candidates: candidates, active: nil) {
            return err(ControlResolve.ambiguousMessage(noun: noun, target: target, hits: hits))
        }
        return err(ControlResolve.notFoundMessage(noun: noun, target: target ?? "active"))
    }

    func resolveSessionResponse(_ target: String?) -> ResolveResponse<UUID> {
        let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
        switch ControlResolve.resolve(target ?? "active", candidates: candidates, active: store.selectedSessionID) {
        case .resolved(let id): return .success(id)
        case .ambiguous, .notFound: return .failure(resolveError("session", target: target, candidates: candidates))
        }
    }

    func resolveWorkspaceResponse(_ target: String?) -> ResolveResponse<UUID> {
        let candidates = store.workspaces.map(\.id)
        switch ControlResolve.resolve(target ?? "active", candidates: candidates, active: store.currentWorkspaceID) {
        case .resolved(let id): return .success(id)
        case .ambiguous, .notFound: return .failure(resolveError("workspace", target: target, candidates: candidates))
        }
    }

    func resolveWindowResponse(_ target: String?) -> ResolveResponse<UUID> {
        let candidates = library.windows.map(\.id)
        switch ControlResolve.resolve(target ?? "active", candidates: candidates, active: library.activeWindowID) {
        case .resolved(let id): return .success(id)
        case .ambiguous, .notFound: return .failure(resolveError("window", target: target, candidates: candidates))
        }
    }

    private func resolveAnchorLocation(_ anchor: String) -> ResolveResponse<(workspace: UUID, index: Int)> {
        let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
        switch ControlResolve.resolve(anchor, candidates: candidates, active: store.selectedSessionID) {
        case .resolved(let id):
            guard let location = store.sessionLocation(ofSession: id) else { return .failure(err("no such session")) }
            return .success((workspace: location.workspace, index: location.index))
        case .ambiguous, .notFound:
            return .failure(resolveError("session", target: anchor, candidates: candidates))
        }
    }

    private func resolveSessionResponses(_ targets: [String]) -> ResolveResponse<[UUID]> {
        var resolved: [UUID] = []
        for target in targets {
            switch resolveSessionResponse(target) {
            case .failure(let response): return .failure(response)
            case .success(let id):
                if !resolved.contains(id) { resolved.append(id) }
            }
        }
        return .success(resolved)
    }

    func controlTree(window: String?) -> ControlResponse {
        let baseTree = store.controlTree(
            foreground: { [weak self] session in self?.surfaces[session.id]?.foregroundCommand() },
            splitForeground: { [weak self] session in self?.splitSurfaces[session.id]?.foregroundCommand() },
            fontSize: { [weak self] in self?.surfaces[$0.id]?.currentFontSize() },
            splitFontSize: { [weak self] in self?.splitSurfaces[$0.id]?.currentFontSize() },
            scratchFontSize: { [weak self] in self?.scratchSurfaces[$0.id]?.currentFontSize() },
            quickVisible: { [weak self] in self?.quickVisible ?? false },
            zoomedSurface: { [weak self] in self?.terminalZoom.target?.controlID },
            dashboardMembers: { [weak self] in self?.dashboard.isOpen == true
                ? self?.dashboard.members.map(\.controlRef) : nil },
            dashboardHighlighted: { [weak self] in self?.dashboard.highlighted?.controlRef },
            dashboardFontSize: { [weak self] in self?.dashboard.appliedFontSize },
            dashboardFontMode: { [weak self] in
                guard let self, self.dashboard.isOpen else { return nil }
                switch self.dashboard.fontMode {
                case .untouched: return "untouched"
                case .fixed: return "fixed"
                case .auto: return "auto"
                }
            }
        )
        let tree = projectingLinuxAutoFollow(baseTree)
        return ControlResponse(ok: true, result: ControlResult(tree: tree))
    }

    func createSession(_ options: ControlSessionCreateOptions) -> ControlResponse {
        let cwd = options.cwd ?? Self.homeCwd
        let shouldFocus = !options.noSelect && gtk_window_is_active(WIN(windowPointer)) != 0
        if let anchor = options.after ?? options.before {
            switch resolveAnchorLocation(anchor) {
            case .failure(let response): return response
            case .success(let location):
                let index = options.before != nil ? location.index : location.index + 1
                guard let session = store.addSession(toWorkspace: location.workspace, cwd: cwd,
                                                     command: options.command, name: options.name, wait: options.wait == true,
                                                     at: index,
                                                     select: !options.noSelect) else {
                    return err("no such workspace")
                }
                reconcile(focusActive: shouldFocus)
                return ok(session.id)
            }
        }
        let workspaceID: UUID
        if let name = options.workspaceName {
            guard let needle = name.linuxTrimmedOrNil else { return err("workspace name must not be blank") }
            if options.createWorkspace == true {
                workspaceID = store.ensureWorkspace(named: needle, revealNewWorkspace: !options.noSelect)?.id
                    ?? store.addWorkspace(name: needle, revealNewWorkspace: !options.noSelect).id
            } else if let workspace = store.workspace(named: needle) {
                workspaceID = workspace.id
            } else {
                return err("no workspace named \"\(needle)\" (pass --create-workspace to add it)")
            }
        } else {
            switch resolveWorkspaceResponse(options.workspace) {
            case .failure(let response): return response
            case .success(let id): workspaceID = id
            }
        }
        guard let session = store.addSession(toWorkspace: workspaceID, cwd: cwd,
                                             command: options.command, name: options.name, wait: options.wait == true,
                                             select: !options.noSelect) else {
            return err("no such workspace")
        }
        reconcile(focusActive: shouldFocus)
        return ok(session.id)
    }

    func duplicateSession(_ target: String?, window: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.duplicateSession(id) else { return err("could not duplicate session") }
            reconcile(focusActive: gtk_window_is_active(WIN(windowPointer)) != 0)
            return ok(session.id)
        }
    }
    func selectSession(_ target: String?, window: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            selectSession(id, userInitiated: false)
            return ok(id)
        }
    }

    func goSession(window: String?, direction: SessionNavigation) -> ControlResponse {
        navigate(direction, userInitiated: false)
        guard let id = store.selectedSessionID else { return err("no session to navigate") }
        return ok(id)
    }

    func closeSession(_ target: String?, window: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            closeSession(id)
            return ok(id)
        }
    }

    func closeSessions(_ targets: [String], window: String?) -> ControlResponse {
        switch resolveSessionResponses(targets) {
        case .failure(let response): return response
        case .success(let ids):
            guard let first = ids.first else { return err("session.close requires at least one --target") }
            if ids.count == 1 {
                closeSession(first)
                return ok(first)
            }
            let affected: Int
            if linuxSettingsStore().load().closeGraceUndoEnabled ?? true {
                affected = store.softCloseSessions(ids) ? ids.count : 0
                if affected > 0 { reconcileSoftClose() }
            } else {
                affected = ids.reduce(into: 0) { count, id in
                    guard store.session(withID: id) != nil else { return }
                    store.closeSession(id)
                    count += 1
                }
            }
            if affected == 0 || !(linuxSettingsStore().load().closeGraceUndoEnabled ?? true) { reconcile() }
            return ControlResponse(ok: true, result: ControlResult(affected: affected))
        }
    }

    func renameSession(_ target: String?, window: String?, name: String) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            store.renameSession(id, to: name)
            rebuildAfterRename()
            return ok(id)
        }
    }

    func revealSession(_ target: String?, window: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard revealSessionDirectory(id) else {
                return err("session cwd is not an existing directory")
            }
            return ok(id)
        }
    }

    func createWorkspace(window: String?, name: String?, collapsed: Bool) -> ControlResponse {
        let workspace = store.addWorkspace(name: name?.linuxTrimmedOrNil ?? store.defaultWorkspaceName, collapsed: collapsed)
        reconcile()
        return ok(workspace.id)
    }

    func selectWorkspace(_ target: String?, window: String?) -> ControlResponse {
        switch resolveWorkspaceResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let first = store.workspaces.first(where: { $0.id == id })?.sessions.first {
                selectSession(first.id, userInitiated: false)
            }
            return ok(id)
        }
    }

    func goWorkspace(window: String?, direction: WorkspaceNavigation) -> ControlResponse {
        guard let step = navigateWorkspace(direction, userInitiated: false) else {
            return err("no other workspace to navigate to")
        }
        return ok(step.workspaceID)
    }

    func renameWorkspace(_ target: String?, window: String?, name: String) -> ControlResponse {
        switch resolveWorkspaceResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            store.renameWorkspace(id, to: name)
            rebuildAfterRename()
            return ok(id)
        }
    }

    func deleteWorkspace(_ target: String?, window: String?) -> ControlResponse {
        switch resolveWorkspaceResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard store.canRemoveWorkspace else { return err("cannot delete last workspace") }
            store.removeWorkspace(id)
            reconcile()
            return ok(id)
        }
    }

    func moveSession(_ target: String?, window: String?, move: ControlSessionMove) -> ControlResponse {
        let id: UUID
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let resolved): id = resolved
        }
        switch move {
        case .reorder(let direction):
            store.reorderSession(id, direction)
        case .workspace(let workspace):
            switch resolveWorkspaceResponse(workspace) {
            case .failure(let response): return response
            case .success(let workspaceID): store.moveSession(id, toWorkspace: workspaceID)
            }
        case .place(let anchor, let after):
            switch resolveAnchorLocation(anchor) {
            case .failure(let response): return response
            case .success(let location):
                store.moveSession(id, toWorkspace: location.workspace, at: location.index + (after ? 1 : 0))
            }
        }
        reconcile()
        return ok(id)
    }

    func moveSessions(_ targets: [String], window: String?, move: ControlSessionMove) -> ControlResponse {
        let ids: [UUID]
        switch resolveSessionResponses(targets) {
        case .failure(let response): return response
        case .success(let resolved): ids = resolved
        }
        guard !ids.isEmpty else { return err("session.move requires at least one --target") }

        let affected: Int
        switch move {
        case .reorder:
            return err("session.move --target can be repeated only with a workspace or --after/--before")
        case .workspace(let workspace):
            switch resolveWorkspaceResponse(workspace) {
            case .failure(let response): return response
            case .success(let workspaceID): affected = store.moveSessions(ids, toWorkspace: workspaceID)
            }
        case .place(let anchor, let after):
            let anchorLocation: (workspace: UUID, index: Int)
            switch resolveAnchorLocation(anchor) {
            case .failure(let response): return response
            case .success(let location): anchorLocation = location
            }
            let sources = ids.compactMap { id -> SidebarDrop.SessionSource? in
                guard let location = store.sessionLocation(ofSession: id) else { return nil }
                return SidebarDrop.SessionSource(workspace: location.workspace, index: location.index)
            }
            let count = store.workspaces.first(where: { $0.id == anchorLocation.workspace })?.sessions.count ?? 0
            let target = SidebarDrop.SessionDropTarget.sessionRow(
                workspace: anchorLocation.workspace,
                sessionIndex: anchorLocation.index,
                sessionCount: count
            )
            let childIndex = after ? SidebarDrop.onItemIndex : anchorLocation.index
            if let resolution = SidebarDrop.resolveSessions(sources: sources, target: target, childIndex: childIndex) {
                affected = store.moveSessions(ids, toWorkspace: resolution.workspace, at: resolution.destination)
            } else {
                affected = 0
            }
        }
        reconcile()
        return ControlResponse(ok: true, result: ControlResult(affected: affected))
    }

    func moveWorkspace(_ target: String?, window: String?, direction: ReorderDirection) -> ControlResponse {
        switch resolveWorkspaceResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            store.reorderWorkspace(id, direction)
            rebuildSidebarKeepingKeyboard()
            syncSidebarSelection()
            return ok(id)
        }
    }

    func focusWorkspace(_ target: String?, window: String?, mode: ControlWorkspaceFocusMode) -> ControlResponse {
        switch resolveWorkspaceResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            store.applyFocusMode(mode, to: id)
            rebuildSidebarKeepingKeyboard()
            return ok(id)
        }
    }

    func setWorkspaceFilter(window: String?, mode: ControlToggleMode) -> ControlResponse {
        store.applyWorkspaceFilter(mode)
        rebuildSidebarKeepingKeyboard()
        return ok()
    }

    func setSessionFlag(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        if mode == "clear" {
            clearFlagged()
            return ok()
        }
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let parsed = ControlToggleMode.parse(mode) else { return err("invalid flag mode: \(mode ?? "toggle")") }
            let current = store.session(withID: id)?.flagged ?? false
            store.setFlag(parsed.desiredValue(current: current), forSession: id)
            rebuildSidebarKeepingKeyboard()
            return ok(id)
        }
    }

    func markSessionSeen(_ target: String?, window: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            store.clearUnseen(id)
            rebuildSidebarKeepingKeyboard()
            return ok(id)
        }
    }

    func setSessionStatus(_ target: String?, window: String?, update: ControlSessionStatusUpdate) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let sound = update.sound, !sound.isEmpty, let error = StatusSoundPlayer.shared.statusSoundError(for: sound) {
                return err(error)
            }
            let wasBlocked = store.session(withID: id)?.agentIndicator.status == .blocked
            let pane = update.paneID.flatMap { store.session(withID: id)?.paneRole(forToken: $0) }
                ?? update.pane
            store.setAgentIndicator(AgentIndicator(status: update.status, blink: update.blink ?? false,
                                                   autoReset: update.autoReset ?? false,
                                                   color: update.color, statusPane: pane), forSession: id)
            let blockedDefault = wasBlocked ? nil : linuxSettingsStore().load().blockedStatusSoundName
            if let sound = update.status.effectiveSound(perCall: update.sound, blockedDefault: blockedDefault) {
                StatusSoundPlayer.shared.play(sound)
            }
            rebuildSidebarKeepingKeyboard()
            updateAttentionButton()
            return ok(id)
        }
    }

    func splitSession(_ target: String?, window: String?, mode: String?) -> ControlResponse {
        splitSession(target, window: window, mode: mode, axis: nil)
    }

    func splitSession(_ target: String?, window: String?, mode: String?, axis: SplitAxis?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard store.session(withID: id) != nil else { return err("no such session") }
            guard let parsed = ControlToggleMode.parse(mode) else { return err("invalid split mode: \(mode ?? "toggle")") }
            switch parsed {
            case .on: store.setSplitVisibility(id, shown: true, axis: axis)
            case .off: store.setSplitVisibility(id, shown: false)
            case .toggle: store.toggleSplit(id, axis: axis)
            }
            reconcile(rebuildSidebar: false)
            if store.selectedSessionID == id {
                sessionFocusTarget(for: id)?.grabFocus(supersedingPopoverCapture: true)
            }
            return ok(id)
        }
    }

    func closeSessionSplit(_ target: String?, window: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            guard session.hasSplit else { return ok(id) }
            store.closeSplit(id)
            reconcile()
            if store.selectedSessionID == id {
                sessionFocusTarget(for: id, wantSplit: false)?.grabFocus(supersedingPopoverCapture: true)
            }
            return ok(id)
        }
    }

    func scratchSession(_ target: String?, window: String?, mode: String?, command: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            guard let parsed = ControlToggleMode.parse(mode) else { return err("invalid scratch mode: \(mode ?? "toggle")") }
            if parsed.desiredValue(current: session.scratchActive) != session.scratchActive {
                store.toggleScratch(id)
            }
            reconcile()
            updateToggleIcons()
            return ok(id)
        }
    }
    func focusSessionPane(_ target: String?, window: String?, pane: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id), session.hasSplit else { return err("session has no split") }
            guard let parsed = ControlPaneFocusMode.parse(pane) else {
                return err("invalid pane: \(pane ?? "other")")
            }
            let toSplit = parsed.wantsSplit(currentSplitFocused: session.splitFocused,
                                            primaryInEndSlot: primaryInEndSlot(id))
            store.setPaneFocus(toSplit, forSession: id)
            syncSplit(session)
            rebuildSidebar()
            updateTitle()
            if store.selectedSessionID == id {
                sessionFocusTarget(for: id, wantSplit: toSplit)?
                    .grabFocus(supersedingPopoverCapture: true)
            }
            return ok(id)
        }
    }
    func resizeSplit(_ target: String?, window: String?, resize: ControlSplitResize) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id), session.hasSplit else { return err("session has no split") }
            let current = session.splitRatio ?? AppStore.splitRatioDefault
            let ratio: Double
            switch resize {
            case .ratio(let value): ratio = value
            case .delta(let delta): ratio = current + delta
            case .paneDelta(let target, let delta): ratio = current + target.primaryRatioDelta(
                delta, primaryInEndSlot: primaryInEndSlot(id))
            }
            _ = store.applySplitRatio(ratio, forSession: id)
            if let paned = sessionPanes[id] {
                let extent = session.splitAxis == .topBottom
                    ? gtk_widget_get_height(W(paned)) : gtk_widget_get_width(W(paned))
                let applied = session.splitRatio ?? AppStore.splitRatioDefault
                gtk_paned_set_position(
                    paned,
                    Int32(Double(max(1, extent)) * panedFraction(applied, session: id))
                )
            }
            return ok(id)
        }
    }
    func setSurfaceZoom(_ target: String?, window: String?, mode: ControlToggleMode) -> ControlResponse {
        let raw = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "active"
        let resolved: TerminalZoomTarget?
        if raw == "active" {
            if mode == .off, terminalZoom.target == nil { return ok() }
            resolved = terminalZoom.target
                ?? (quickVisible ? .quick : TerminalZoomController.resolveTarget(store: store))
        } else if raw == "quick" {
            resolved = .quick
        } else if let surfaceID = TerminalSurfaceID(rawValue: raw) {
            resolved = .session(surfaceID.sessionID, surfaceID.surface)
        } else {
            return err("invalid surface target: \(raw)")
        }
        if mode == .off, resolved == nil { return ok() }
        guard let resolved else { return err("no active surface") }
        if mode != .off, !linuxZoomTargetIsValid(resolved) {
            return err("surface not available: \(resolved.controlID)")
        }
        setTerminalZoom(mode, target: resolved)
        return ControlResponse(ok: true, result: ControlResult(id: resolved.controlID))
    }

    func setDashboard(targets: [String], window: String?, close: Bool,
                      fontMode: DashboardFontMode, mru: Bool) -> ControlResponse {
        if close {
            closeDashboard(refocus: false)
            return ok()
        }
        let members: [DashboardMember]
        var notes: [String] = []
        if mru {
            members = store.dashboardMRUMembers(limit: DashboardLayout.maxCells)
            guard !members.isEmpty else { return err("no recent sessions") }
        } else {
            let candidates = store.workspaces.flatMap { $0.sessions.map(\.id) }
            var resolved: [ResolvedDashboardTarget] = []
            var unresolved: [String] = []
            for target in targets {
                guard let parsed = DashboardTarget(rawValue: target),
                      case .resolved(let id) = ControlResolve.resolve(parsed.head, candidates: candidates,
                                                                      active: store.selectedSessionID),
                      let session = store.session(withID: id),
                      parsed.pane != .split || session.hasSplit else {
                    unresolved.append(target)
                    continue
                }
                resolved.append(ResolvedDashboardTarget(session: id, pane: parsed.pane))
            }
            let expanded = store.dashboardMembers(for: resolved, limit: DashboardLayout.maxCells)
            guard !expanded.members.isEmpty else { return err("no dashboard sessions resolved") }
            members = expanded.members
            if !unresolved.isEmpty { notes.append("unresolved: \(unresolved.joined(separator: ", "))") }
            if expanded.dropped > 0 {
                notes.append("dropped \(expanded.dropped) pane(s) beyond the \(DashboardLayout.maxCells)-cell limit")
            }
        }
        openDashboard(members: members, fontMode: fontMode)
        return notes.isEmpty ? ok() : ControlResponse(ok: true,
            result: ControlResult(text: notes.joined(separator: "; ")))
    }

    func font(_ target: String?, window: String?, pane: String?, action: String) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            let surface: GhosttySurface?
            switch pane {
            case nil, "left": surface = surfaces[id]
            case "right":
                guard let split = splitSurfaces[id] else {
                    return err("session has no split pane")
                }
                surface = split
            case "scratch":
                guard let scratch = scratchSurfaces[id] else {
                    return err("session has no scratch terminal")
                }
                surface = scratch
            case .some(let value): return err("invalid pane: \(value)")
            }
            guard let surface else { return err("session not realized") }
            surface.performBindingAction(action)
            return ok(id)
        }
    }

    func reloadKeymap() -> ControlResponse {
        let diagnostics = reloadKeymapAllWindows(reportingIn: self)   // app-global: MUST fan out
        return ControlResponse(ok: true, result: ControlResult(count: diagnostics))
    }

    func listKeymap() -> ControlResponse {
        let path = ConfigPaths.keymapPath(configDirectory: configDirectory()).path
        let projected = projectLinuxKeymap(keymap, diagnostics: keymapDiagnostics, path: path)
        return ControlResponse(ok: true, result: ControlResult(keymap: projected))
    }

    func reloadGhosttyConfig() -> ControlResponse {
        reloadConfig()
        return ok()
    }

    func sendNotification(_ target: String?, window: String?, title: String?, body: String) -> ControlResponse {
        let id: UUID?
        if target != nil {
            switch resolveSessionResponse(target) {
            case .failure(let response): return response
            case .success(let resolved): id = resolved
            }
        } else {
            id = store.selectedSessionID
        }
        if let id {
            _ = store.recordTerminalNotification(TerminalNotificationRecord(sessionID: id, windowID: windowID, pane: .main,
                                                                            title: title ?? "", body: body,
                                                                            firingIsFocused: false,
                                                                            appActive: false))
            rebuildSidebarKeepingKeyboard()
        }
        let notificationTarget = id.map { TerminalNotification.identity(windowID: windowID, sessionID: $0, pane: .main) }
        if NotificationManager.bannersEnabled {
            NotificationManager.send(title: title ?? "", body: body, target: notificationTarget)
        }
        return ok(id)
    }

    func setTheme(args: ControlArgs?) -> ControlResponse {
        let name = ThemeCatalog.resolvedName(args?.name)
        let light = ThemeCatalog.resolvedName(args?.light)
        let dark = ThemeCatalog.resolvedName(args?.dark)
        if name != nil, light != nil {
            return err("theme.set takes either a name or --light, not both")
        }
        let lightSlot = name ?? light
        let clearDark = dark?.lowercased() == "none"
        let catalog = ThemeCatalog(names: Self.bundledThemes())
        for theme in [lightSlot, clearDark ? nil : dark].compactMap({ $0 }) where !catalog.contains(name: theme) {
            return err("unknown theme: \(theme)")
        }
        var settings = linuxSettingsStore().load()
        if clearDark {
            settings.darkTheme = nil
            settings.followSystemAppearance = nil
            if lightSlot != nil { settings.theme = lightSlot }
        } else if let dark {
            settings.theme = lightSlot ?? settings.theme ?? "Builtin Light"
            settings.darkTheme = dark
            settings.followSystemAppearance = true
        } else {
            settings.theme = lightSlot
            if lightSlot == nil {
                settings.darkTheme = nil
                settings.followSystemAppearance = nil
            }
        }
        try? linuxSettingsStore().save(settings)
        reloadConfig()
        return ControlResponse(ok: true, result: ControlResult(
            theme: currentTheme,
            sync: settings.followSystemAppearance == true,
            light: settings.theme,
            dark: settings.darkTheme
        ))
    }

    func listThemes() -> ControlResponse {
        let settings = linuxSettingsStore().load()
        return ControlResponse(ok: true, result: ControlResult(
            theme: currentTheme,
            themes: Self.bundledThemes(),
            sync: settings.followSystemAppearance == true,
            light: settings.theme,
            dark: settings.darkTheme
        ))
    }

    func setSidebarVisibility(_ mode: ControlToggleMode) -> ControlResponse {
        let want = mode.desiredValue(current: store.sidebarVisible)
        if store.sidebarVisible != want {
            store.setSidebarVisible(want)
            applySidebarVisibility()
        }
        return ok()
    }

    func setSidebarViewMode(_ mode: ControlSidebarViewMode) -> ControlResponse {
        let want: SidebarMode
        switch mode {
        case .tree: want = .tree
        case .flagged: want = .flagged
        case .toggle: want = store.sidebarMode == .tree ? .flagged : .tree
        }
        store.setSidebarMode(want)
        rebuildSidebarKeepingKeyboard()
        syncSidebarSelection()
        return ok()
    }

    func expandSidebar(window: String?) -> ControlResponse {
        expandWorkspaces()
        return ok()
    }

    func collapseSidebar(window: String?) -> ControlResponse {
        collapseOtherWorkspaces()
        return ok()
    }

    func setQuickTerminal(mode: String?) -> ControlResponse {
        guard let parsed = ControlToggleMode.parse(mode, on: "show", off: "hide") else {
            return err("invalid quick mode: \(mode ?? "toggle")")
        }
        setQuick(parsed.desiredValue(current: quickVisible))
        return ok()
    }

    func typeQuick(text: String) async -> ControlResponse {
        typeQuickSync(text: text)
    }

    func typeQuickSync(text: String) -> ControlResponse {
        guard quickSurface != nil || quickVisible else { return err("quick terminal not open") }
        for _ in 0..<12 {
            while g_main_context_iteration(nil, 0) != 0 {}
            if let quickSurface, quickSurface.inject(text: text) {
                return ok()
            }
            usleep(30_000)
        }
        return err("quick terminal not realized")
    }

    func readQuickText(all: Bool, lines: Int?) async -> ControlResponse {
        readQuickTextSync(all: all, lines: lines)
    }

    func readQuickTextSync(all: Bool, lines: Int?) -> ControlResponse {
        guard quickSurface != nil || quickVisible else { return err("quick terminal not open") }
        for _ in 0..<12 {
            while g_main_context_iteration(nil, 0) != 0 {}
            if let text = quickSurface?.readScreenText(all: all, lines: lines) {
                return ControlResponse(ok: true, result: ControlResult(text: text))
            }
            usleep(30_000)
        }
        return err("failed to read surface buffer")
    }

    func typeSession(_ target: String?, window: String?, options: ControlSessionTypeOptions) async -> ControlResponse {
        typeSessionSync(target, window: window, options: options)
    }

    func typeSessionSync(_ target: String?, window: String?, options: ControlSessionTypeOptions) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("session not found") }
            switch options.pane {
            case nil, "left": break
            case "right" where !session.hasSplit: return err("session has no split pane")
            case "scratch" where session.scratchSurface == nil: return err("session has no scratch terminal")
            case "right", "scratch": break
            case .some(let pane): return err("invalid pane: \(pane)")
            }
            if options.select {
                selectSession(id, userInitiated: false)
                reconcile()
            }
            for _ in 0..<12 {
                while g_main_context_iteration(nil, 0) != 0 {}
                let surface: GhosttySurface? = switch options.pane {
                case nil, "left": surfaces[id]
                case "right": splitSurfaces[id]
                case "scratch": scratchSurfaces[id]
                case .some: nil
                }
                if let surface, surface.inject(text: options.text) {
                    return ok(id)
                }
                usleep(30_000)
            }
            return err("session not realized")
        }
    }

    func copySessionSelection(_ target: String?, window: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let text = focusedSurface(for: id)?.readSelection(), !text.isEmpty else {
                return err("no selection")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: text))
        }
    }

    func pasteSession(_ target: String?, window: String?) -> ControlResponse {
        performSessionBinding(target, action: "paste_from_clipboard")
    }

    func selectAllSession(_ target: String?, window: String?) -> ControlResponse {
        performSessionBinding(target, action: "select_all")
    }

    private func performSessionBinding(_ target: String?, action: String) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let surface = focusedSurface(for: id), surface.isRealized else {
                return err("session not realized")
            }
            surface.performBindingAction(action)
            return ok(id)
        }
    }

    func searchSession(_ target: String?, window: String?,
                       text: String?, to: String?) async -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if to == "close" {
                if searchSessionID == id { searchSurface?.endSearch() }
                return ok(id)
            }
            selectSession(id, userInitiated: false)
            reconcile(focusActive: false)
            var owner = searchTargetSurface(for: id)
            for _ in 0..<12 where owner?.isRealized != true {
                while g_main_context_iteration(nil, 0) != 0 {}
                usleep(30_000)
                owner = searchTargetSurface(for: id)
            }
            guard let owner, owner.isRealized else { return err("session not realized") }
            searchSurface = owner
            owner.startSearch()
            let hasQuery = text.map { !$0.isEmpty } ?? false
            if let text, !text.isEmpty {
                searchTotal = nil
                searchSelected = nil
                text.withCString { gtk_editable_set_text(searchEntry, $0) }
                owner.sendSearchQuery(text)
            }
            switch to {
            case "next": owner.navigateSearch(.next)
            case "prev", "previous": owner.navigateSearch(.previous)
            default: break
            }
            if hasQuery {
                for _ in 0..<20 {
                    while g_main_context_iteration(nil, 0) != 0 {}
                    if searchTotal != nil { break }
                    usleep(3000)
                }
            }
            let display = searchDisplayText()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString,
                                                                   text: display.isEmpty ? nil : display,
                                                                   count: searchTotal))
        }
    }

    func openSessionOverlay(_ target: String?, window: String?,
                            options: ControlSessionOverlayOpenOptions) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            if let pane = options.pane {
                switch store.openPaneOverlay(id, pane: pane, command: options.command, cwd: options.cwd,
                                             wait: options.wait, backgroundColor: options.backgroundColor) {
                case nil:
                    if options.follow { selectSession(id, userInitiated: false) }
                    reconcile()
                    return ok(id)
                case .unknownSession: return err("no such session")
                case .alreadyOpen: return err(PaneOverlayError.alreadyOpen)
                case .paneNotVisible: return err(PaneOverlayError.paneNotVisible)
                }
            }
            guard store.openOverlay(id, command: options.command, cwd: options.cwd, wait: options.wait,
                                    sizePercent: options.sizePercent,
                                    backgroundColor: options.backgroundColor) else {
                return err("overlay already open")
            }
            if options.follow { selectSession(id, userInitiated: false) }
            reconcile()
            return ok(id)
        }
    }

    func closeSessionOverlay(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            let hud = pane == nil && store.session(withID: id)?.hudActive == true
            let closed = pane.map { store.closePaneOverlay(id, pane: $0) } ?? store.closeOverlay(id)
            guard closed else { return err("no overlay") }
            reconcile(focusActive: !hud)
            return ok(id)
        }
    }

    func resizeSessionOverlay(_ target: String?, window: String?, sizePercent: Int?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            let hud = session.hudActive
            if hud, sizePercent == nil { return err(OverlayHudError.fullResize) }
            let previousSize = session.overlaySizePercent
            guard store.resizeOverlay(id, sizePercent: sizePercent) else { return err("no overlay") }
            if hud, !writeHudBody(session, pane: hudPaneMetrics(for: session)) {
                store.resizeOverlay(id, sizePercent: previousSize)
                return err(OverlayHudError.writeFailed)
            }
            reconcile(focusActive: !hud)
            return ok(id)
        }
    }

    func sessionOverlayResult(_ target: String?, window: String?, pane: OverlayPane?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            if let pane {
                if session.paneOverlay(pane) != nil { return err(OverlayResultError.stillRunning) }
                guard let code = session.paneOverlayExitCode(pane) else { return err(OverlayResultError.noResult) }
                return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, exitCode: code))
            }
            if session.hudActive { return err(OverlayHudError.noResult) }
            if session.overlayActive { return err(OverlayResultError.stillRunning) }
            guard let code = session.overlayExitCode else { return err(OverlayResultError.noResult) }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, exitCode: code))
        }
    }

    func setSessionBackground(_ target: String?, window: String?,
                              options: ControlSessionBackgroundOptions) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            _ = store.setBackgroundWatermark(options.watermark, forSession: id)
            applySessionWatermark(id)
            return ok(id)
        }
    }

    func readSessionText(_ target: String?, window: String?, options: ControlSessionTextOptions) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            let surface: GhosttySurface?
            switch options.pane {
            case nil: surface = store.session(withID: id)?.onScreenSurface as? GhosttySurface
            case "left": surface = surfaces[id]
            case "right": surface = splitSurfaces[id]
            case "scratch": surface = scratchSurfaces[id]
            default: surface = nil
            }
            guard let text = surface?.readScreenText(all: options.all, lines: options.lines) else {
                return err("session not realized")
            }
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString, text: text))
        }
    }

    func clearRecentClosedItems() -> ControlResponse {
        let affected = gLibrary.recentClosedItems.count
        guard gLibrary.clearRecentClosedItems() else { return err(RecentClearError.persistenceFailed) }
        return ControlResponse(ok: true, result: ControlResult(affected: affected))
    }

    func clearRestoreCommands() -> ControlResponse {
        for ctl in gWindows.values {
            for session in ctl.store.workspaces.flatMap(\.sessions) {
                session.foregroundCommand = nil
                session.splitForegroundCommand = nil
                session.clearPendingForegroundCommands()
            }
        }
        gLibrary.saveAllOpen()
        return ok()
    }
}
