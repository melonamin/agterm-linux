import Foundation
import agtermCore

private enum LinuxOverlayReadSurface {
    case surface(GhosttySurface)
    case failure(ControlResponse)
}

/// Linux host actions added by upstream protocol releases.
/// Kept beside the main adapter so that already-large compatibility surface stays within the lint limit.
@MainActor
extension AppController {
    func appIdentity() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(app: LinuxAppMetadata.identity))
    }

    func captureRestoreCommands() -> ControlResponse {
        let configuredMode = linuxSettingsStore().load().effectiveRestoreMode
        guard configuredMode == .rerun else {
            return err("restore.capture requires rerun mode; configured restore mode is "
                + configuredMode.rawValue)
        }
        for controller in gWindows.values { controller.captureForegroundCommands() }
        let captured = gWindows.values.reduce(into: 0) { count, controller in
            for session in controller.store.workspaces.flatMap(\.sessions) {
                if session.foregroundCommand != nil { count += 1 }
                if session.splitForegroundCommand != nil { count += 1 }
            }
        }
        let paneSuffix = captured == 1 ? "" : "s"
        guard gLibrary.saveAllOpenChecked() else {
            return err("captured \(captured) pane\(paneSuffix) but at least one window's save "
                + "failed; failed windows keep their argv in memory until they save successfully")
        }
        var result = ControlResult(count: captured)
        result.text = "captured \(captured) pane\(paneSuffix)"
        return ControlResponse(ok: true, result: result)
    }

    func applySessionWatermark(_ id: UUID) {
        surfaces[id]?.applyWatermarkFromSession()
        splitSurfaces[id]?.applyWatermarkFromSession()
        scratchSurfaces[id]?.applyWatermarkFromSession()
    }

    func readEvents(_ options: ControlEventReadOptions) -> ControlResponse {
        library.readEvents(options)
    }

    func setSessionContext(_ target: String?, window: String?, context: String?) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard store.session(withID: id) != nil else { return err("no such session") }
            _ = store.setContext(context, forSession: id)
            updateTitle()
            refreshSidebar()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    func setSidebarWidth(_ points: Double, window: String?) -> ControlResponse {
        store.setSidebarWidth(points)
        if let splitView { applySidebarWidth(splitView) }
        return ControlResponse(ok: true, result: ControlResult(sidebarWidth: store.sidebarWidth))
    }

    func setWorkspaceExpansion(_ target: String?, window: String?, expanded: Bool) -> ControlResponse {
        switch resolveWorkspaceResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            store.setWorkspaceExpanded(id, expanded: expanded)
            rebuildSidebarKeepingKeyboard()
            syncSidebarSelection()
            return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
        }
    }

    private func overlayReadSurface(_ session: Session, pane: OverlayPane?) -> LinuxOverlayReadSurface {
        let occupied: Bool
        let surface: GhosttySurface?
        if let pane {
            occupied = session.paneOverlay(pane) != nil
            surface = pane == .left ? leftOverlaySurfaces[session.id] : rightOverlaySurfaces[session.id]
        } else {
            if session.hudActive {
                return .failure(ControlResponse(ok: false, error: OverlayHudError.noRead))
            }
            occupied = session.overlayActive
            surface = overlaySurfaces[session.id]
        }
        guard occupied else { return .failure(ControlResponse(ok: false, error: "no overlay")) }
        guard let surface, surface.isRealized else {
            return .failure(ControlResponse(ok: false, error: "overlay not realized"))
        }
        return .surface(surface)
    }

    func copySessionOverlaySelection(
        _ target: String?, window: String?, pane: OverlayPane?
    ) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            switch overlayReadSurface(session, pane: pane) {
            case .failure(let response): return response
            case .surface(let surface):
                guard let text = surface.readSelection() else { return err("no selection") }
                return ControlResponse(ok: true, result: ControlResult(text: text))
            }
        }
    }

    func readSessionOverlayText(
        _ target: String?, window: String?, options: ControlSessionOverlayTextOptions
    ) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id):
            guard let session = store.session(withID: id) else { return err("no such session") }
            switch overlayReadSurface(session, pane: options.pane) {
            case .failure(let response): return response
            case .surface(let surface):
                guard let text = surface.readScreenText(all: options.all, lines: options.lines) else {
                    return err("failed to read surface buffer")
                }
                return ControlResponse(ok: true, result: ControlResult(text: text))
            }
        }
    }

    func readSurfaceCursor(_ target: String?, window: String?) -> ControlResponse {
        let raw = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "active"
        let resolved: TerminalZoomTarget
        if raw == "active" {
            guard let active = terminalZoom.target
                    ?? (quickVisible ? .quick : TerminalZoomController.resolveTarget(store: store)) else {
                return err("no active surface")
            }
            resolved = active
        } else if raw == "quick" {
            resolved = .quick
        } else if let surfaceID = TerminalSurfaceID(rawValue: raw) {
            resolved = .session(surfaceID.sessionID, surfaceID.surface)
        } else {
            return err("invalid surface: \(raw)")
        }
        guard linuxZoomTargetIsValid(resolved), let surface = surface(for: resolved) else {
            return err("surface not available: \(resolved.controlID)")
        }
        guard surface.isRealized else { return err("surface not realized") }
        guard let column = surface.readCursorColumn() else { return err("failed to read cursor position") }
        return ControlResponse(
            ok: true,
            result: ControlResult(id: resolved.controlID, cursor: ControlCursor(column: column))
        )
    }

    func setSessionRestore(_ target: String?, window: String?,
                           update: ControlSessionRestoreUpdate) -> ControlResponse {
        switch resolveSessionResponse(target) {
        case .failure(let response): return response
        case .success(let id): return applySessionRestore(id: id, update: update)
        }
    }

    private func applySessionRestore(id: UUID, update: ControlSessionRestoreUpdate) -> ControlResponse {
        guard let session = store.session(withID: id) else {
            return ControlResponse(ok: false, error: "no such session")
        }
        let pane: StatusPane
        if let token = update.paneID, !token.isEmpty {
            guard let resolved = session.paneRole(forToken: token) ?? update.pane else {
                return ControlResponse(ok: false, error: "unknown pane id: \(token)")
            }
            pane = resolved
        } else {
            pane = update.pane ?? .left
        }
        guard pane != .scratch else {
            return ControlResponse(ok: false, error: "the scratch terminal is never restored")
        }
        guard pane != .right || session.hasSplit else {
            return ControlResponse(ok: false, error: "session has no split")
        }

        let value: String?
        switch update.pin {
        case .pin(let command): value = command
        case .pinNone: value = ""
        case .unpin: value = nil
        }
        guard store.setRestoreCommand(value, pane: pane, forSession: id) else {
            return ControlResponse(
                ok: false,
                error: "failed to save the restore override, the previous value is still in effect"
            )
        }
        var result = ControlResult(id: id.uuidString)
        if case .pin = update.pin, linuxSettingsStore().load().effectiveRestoreMode != .rerun {
            result.text = "saved, but \"Restore running commands on restart\" is off, so the override will not run"
        }
        return ControlResponse(ok: true, result: result)
    }
}
