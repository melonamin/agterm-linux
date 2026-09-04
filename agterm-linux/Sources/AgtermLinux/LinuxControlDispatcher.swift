import Foundation
import agtermCore

/// Linux-local synchronous control dispatcher.
///
/// Upstream `agtermCore.ControlDispatcher` is async because macOS may need to realize SwiftUI/AppKit
/// surfaces before handling some commands.
/// The GTK control server already dispatches on the GTK main thread and needs a synchronous route from
/// its C socket callback, so the Linux fork keeps this adapter inside the Linux target instead of adding
/// Linux-driven API surface to `agtermCore`.
@MainActor
struct LinuxControlDispatcher {
    let actions: AppController

    func dispatch(_ request: ControlRequest) -> ControlResponse? {
        switch request.cmd {
        case .tree:
            return actions.controlTree(window: request.args?.window)
        case .eventsRead:
            return dispatchEventsRead(request)
        case .sessionNew, .sessionDuplicate, .sessionSelect, .sessionGo, .sessionClose, .sessionRename, .sessionReveal,
                .sessionMove, .sessionFlag, .sessionContext, .sessionSeen, .sessionStatus, .sessionRestore:
            return dispatchSessionCommand(request)
        case .sessionSplit, .sessionSplitClose, .sessionSwap, .sessionScratch, .sessionFocus, .sessionResize,
                .surfaceZoom, .surfaceCursor,
                .sessionCopy, .sessionPaste, .sessionSelectAll, .sessionOverlayOpen,
                .sessionOverlayClose, .sessionOverlayResize, .sessionOverlayResult,
                .sessionOverlayCopy, .sessionOverlayText, .sessionBackground, .sessionText:
            return dispatchSessionSurfaceCommand(request)
        case .sessionHudOpen, .sessionHudUpdate, .sessionHudClose:
            return dispatchHudCommand(request)
        case .sessionType, .quickType, .quickText:
            return nil
        case .workspaceNew, .workspaceSelect, .workspaceGo, .workspaceRename, .workspaceDelete,
                .workspaceMove, .workspaceFocus, .workspaceFilter, .workspaceCollapse, .workspaceExpand:
            return dispatchWorkspaceCommand(request)
        case .fontInc, .fontDec, .fontReset, .keymapReload, .keymapList, .configReload, .notify,
                .themeSet, .themeList, .sidebar, .sidebarMode, .sidebarExpand,
                .sidebarCollapse, .sidebarWidth, .restoreClear, .restoreCapture, .recentClear, .version:
            return dispatchAppCommand(request)
        case .windowRename, .windowResize, .windowMove, .windowZoom, .windowFullscreen, .windowMinimize:
            return dispatchWindowCommand(request)
        case .pickOpen, .pickResult, .pickCancel:
            return dispatchPickCommand(request)
        case .dashboard:
            return dispatchDashboard(request)
        case .restoreMode, .zmxList, .zmxPrune, .zmxKill, .zmxTree, .zmxAttach:
            return dispatchZmxCommand(request)
        default:
            return nil
        }
    }

    private func dispatchEventsRead(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let cursor: ControlEventCursor?
        switch (args?.run, args?.after) {
        case (nil, nil):
            cursor = nil
        case (.some, nil), (nil, .some):
            return ControlResponse(ok: false, error: ControlEventRequestError.cursorPair)
        case let (.some(runText), .some(afterText)):
            guard let run = UUID(uuidString: runText) else {
                return ControlResponse(ok: false, error: ControlEventRequestError.invalidRun)
            }
            guard let after = UInt64(afterText) else {
                return ControlResponse(ok: false, error: ControlEventRequestError.invalidCursor)
            }
            cursor = ControlEventCursor(run: run, after: after)
        }

        let limit = args?.limit ?? 100
        guard (1...1_000).contains(limit) else {
            return ControlResponse(ok: false, error: ControlEventRequestError.invalidLimit)
        }

        var parsedKinds = Set<ControlEventKind>()
        for field in args?.kinds ?? [] {
            for component in field.split(separator: ",", omittingEmptySubsequences: false) {
                let rawKind = component.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let kind = ControlEventKind(rawValue: rawKind) else {
                    return ControlResponse(ok: false, error: ControlEventRequestError.invalidKind(rawKind))
                }
                parsedKinds.insert(kind)
            }
        }
        let kinds: Set<ControlEventKind>? = parsedKinds.isEmpty ? nil : parsedKinds
        return actions.readEvents(ControlEventReadOptions(cursor: cursor, kinds: kinds, limit: limit))
    }

    private func dispatchPickCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .pickOpen:
            guard let items = request.args?.items, !items.isEmpty else {
                return ControlResponse(ok: false, error: "pick.open requires at least one item")
            }
            guard items.count <= ControlPickItem.maxItems else {
                return ControlResponse(ok: false, error: "too many items (max \(ControlPickItem.maxItems))")
            }
            guard items.allSatisfy({ !$0.label.isEmpty }) else {
                return ControlResponse(ok: false, error: "pick item label must not be empty")
            }
            var ids = Set<String>()
            guard items.allSatisfy({ ids.insert($0.id).inserted }) else {
                return ControlResponse(ok: false, error: "pick item ids must be unique")
            }
            guard items.allSatisfy({
                !containsControlCharacters($0.label)
                    && $0.subtitle.map { !containsControlCharacters($0) } != false
            }) else {
                return ControlResponse(ok: false, error: "item text must not contain control characters")
            }
            return actions.openPick(
                PendingPick(
                    id: UUID().uuidString,
                    items: items,
                    prompt: request.args?.prompt,
                    allowCustom: request.args?.allowCustom == true
                ),
                window: request.args?.window,
                follow: request.args?.follow == true
            )
        case .pickResult:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "pick.result requires a pick id")
            }
            return actions.pickResult(target, window: request.args?.window)
        case .pickCancel:
            guard let target = request.target else {
                return ControlResponse(ok: false, error: "pick.cancel requires a pick id")
            }
            return actions.cancelPick(target, window: request.args?.window)
        default:
            preconditionFailure("unexpected pick command: \(request.cmd.rawValue)")
        }
    }

    private func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    private func dispatchSessionCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionNew:
            let args = request.args
            if args?.after != nil, args?.before != nil {
                return ControlResponse(ok: false, error: "use either --after or --before, not both")
            }
            if args?.after != nil || args?.before != nil, args?.workspace != nil || args?.workspaceName != nil {
                return ControlResponse(ok: false, error: "session.new takes --after/--before or a workspace, not both")
            }
            if args?.workspace != nil, args?.workspaceName != nil {
                return ControlResponse(ok: false, error: "use either --workspace or --workspace-name, not both")
            }
            if args?.createWorkspace == true, args?.workspaceName == nil {
                return ControlResponse(ok: false, error: "--create-workspace requires --workspace-name")
            }
            if args?.wait == true, args?.command == nil {
                return ControlResponse(ok: false, error: "--wait requires --command")
            }
            return actions.createSession(ControlSessionCreateOptions(
                window: args?.window,
                cwd: args?.cwd,
                workspace: args?.workspace,
                workspaceName: args?.workspaceName,
                createWorkspace: args?.createWorkspace,
                command: args?.command,
                wait: args?.wait,
                name: args?.name,
                after: args?.after,
                before: args?.before,
                noSelect: args?.noSelect == true
            ))
        case .sessionDuplicate:
            return actions.duplicateSession(request.target, window: request.args?.window)
        case .sessionSelect:
            return actions.selectSession(request.target, window: request.args?.window)
        case .sessionGo:
            guard let dir = (request.args?.to).flatMap(SessionNavigation.init(wire:)) else {
                return ControlResponse(ok: false, error: "session.go requires --to next|prev|first|last|next-attention|prev-attention")
            }
            return actions.goSession(window: request.args?.window, direction: dir)
        case .sessionClose:
            if let targets = request.args?.targets {
                return actions.closeSessions(targets, window: request.args?.window)
            }
            return actions.closeSession(request.target, window: request.args?.window)
        case .sessionRename:
            guard let name = request.args?.name else {
                return ControlResponse(ok: false, error: "session.rename requires a name")
            }
            return actions.renameSession(request.target, window: request.args?.window, name: name)
        case .sessionReveal:
            return actions.revealSession(request.target, window: request.args?.window)
        case .sessionMove:
            let args = request.args
            if args?.after != nil, args?.before != nil {
                return ControlResponse(ok: false, error: "use either --after or --before, not both")
            }
            if let anchor = args?.after ?? args?.before {
                if args?.to != nil {
                    return ControlResponse(ok: false, error: "session.move takes --after/--before or --to, not both")
                }
                if args?.workspace != nil {
                    return ControlResponse(ok: false, error: "session.move takes --after/--before or a workspace, not both")
                }
                let move = ControlSessionMove.place(anchor: anchor, after: args?.after != nil)
                if let targets = args?.targets {
                    return actions.moveSessions(targets, window: args?.window, move: move)
                }
                return actions.moveSession(request.target, window: args?.window, move: move)
            }
            if args?.to != nil && args?.workspace != nil {
                return ControlResponse(ok: false, error: "session.move takes either --to or a workspace, not both")
            }
            if let to = args?.to {
                if args?.targets != nil {
                    return ControlResponse(
                        ok: false,
                        error: "session.move --target can be repeated only with a workspace or --after/--before"
                    )
                }
                guard let direction = ReorderDirection(rawValue: to) else {
                    return ControlResponse(ok: false, error: "session.move --to must be up|down|top|bottom")
                }
                return actions.moveSession(request.target, window: args?.window, move: .reorder(direction))
            }
            guard let workspace = args?.workspace else {
                return ControlResponse(ok: false, error: "session.move requires --to or a workspace")
            }
            let move = ControlSessionMove.workspace(workspace)
            if let targets = args?.targets {
                return actions.moveSessions(targets, window: args?.window, move: move)
            }
            return actions.moveSession(request.target, window: args?.window, move: move)
        case .sessionFlag:
            return actions.setSessionFlag(request.target, window: request.args?.window, mode: request.args?.mode)
        case .sessionContext:
            return dispatchSessionContext(request)
        case .sessionSeen:
            return actions.markSessionSeen(request.target, window: request.args?.window)
        case .sessionStatus:
            guard let status = AgentStatus(rawValue: request.args?.status ?? "") else {
                return ControlResponse(ok: false, error: "invalid status")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color (expected #rrggbb)")
            }
            var pane: StatusPane?
            if let rawPane = request.args?.pane {
                guard let parsed = StatusPane(rawValue: rawPane) else {
                    return ControlResponse(ok: false, error: "--pane must be left, right, or scratch")
                }
                pane = parsed
            }
            let update = ControlSessionStatusUpdate(status: status, blink: request.args?.blink,
                                                    autoReset: request.args?.autoReset,
                                                    sound: request.args?.sound, color: request.args?.color,
                                                    pane: pane, paneID: request.args?.paneID)
            return actions.setSessionStatus(request.target, window: request.args?.window, update: update)
        case .sessionRestore:
            return dispatchSessionRestore(request)
        default:
            preconditionFailure("unexpected session command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchSessionRestore(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let pin: ControlRestoreOverride
        switch args?.mode ?? "" {
        case "set":
            guard let command = args?.command else {
                return ControlResponse(ok: false, error: "session.restore set requires a command")
            }
            guard !command.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                return ControlResponse(ok: false, error: "command must not contain control characters")
            }
            guard command.utf8.count <= ControlRestoreOverride.maxCommandBytes else {
                return ControlResponse(ok: false,
                                       error: "command too long (max \(ControlRestoreOverride.maxCommandBytes) bytes)")
            }
            pin = .pin(command)
        case "none":
            pin = .pinNone
        case "clear":
            pin = .unpin
        default:
            return ControlResponse(ok: false,
                                   error: "invalid restore mode: \(args?.mode ?? "") (set|none|clear)")
        }
        let pane: StatusPane?
        if let rawPane = args?.pane {
            guard let parsed = StatusPane(rawValue: rawPane) else {
                return ControlResponse(ok: false, error: "--pane must be left, right, or scratch")
            }
            pane = parsed
        } else {
            pane = nil
        }
        return actions.setSessionRestore(request.target, window: args?.window,
                                         update: ControlSessionRestoreUpdate(
                                            pin: pin, pane: pane, paneID: args?.paneID))
    }

    private func dispatchWorkspaceCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .workspaceNew:
            return actions.createWorkspace(window: request.args?.window, name: request.args?.name,
                                           collapsed: request.args?.collapsed ?? false)
        case .workspaceSelect:
            return actions.selectWorkspace(request.target, window: request.args?.window)
        case .workspaceGo:
            guard let direction = request.args?.to.flatMap(WorkspaceNavigation.init(wire:)) else {
                return ControlResponse(ok: false, error: "workspace.go requires --to next|prev")
            }
            return actions.goWorkspace(window: request.args?.window, direction: direction)
        case .workspaceRename:
            guard let name = request.args?.name?.linuxTrimmedOrNil else {
                return ControlResponse(ok: false, error: "workspace.rename requires a name")
            }
            return actions.renameWorkspace(request.target, window: request.args?.window, name: name)
        case .workspaceDelete:
            return actions.deleteWorkspace(request.target, window: request.args?.window)
        case .workspaceMove:
            guard let to = request.args?.to else {
                return ControlResponse(ok: false, error: "workspace.move requires --to")
            }
            guard let direction = ReorderDirection(rawValue: to) else {
                return ControlResponse(ok: false, error: "workspace.move --to must be up|down|top|bottom")
            }
            return actions.moveWorkspace(request.target, window: request.args?.window, direction: direction)
        case .workspaceFocus:
            let rawMode = request.args?.mode ?? ControlWorkspaceFocusMode.toggle.rawValue
            guard let mode = ControlWorkspaceFocusMode(rawValue: rawMode) else {
                return ControlResponse(ok: false,
                    error: "invalid workspace.focus mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.focusWorkspace(request.target, window: request.args?.window, mode: mode)
        case .workspaceFilter:
            guard let mode = ControlToggleMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false,
                    error: "invalid workspace filter mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setWorkspaceFilter(window: request.args?.window, mode: mode)
        case .workspaceCollapse:
            return actions.setWorkspaceExpansion(request.target, window: request.args?.window, expanded: false)
        case .workspaceExpand:
            return actions.setWorkspaceExpansion(request.target, window: request.args?.window, expanded: true)
        default:
            preconditionFailure("unexpected workspace command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchSessionSurfaceCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .sessionSplit:
            let axis: SplitAxis?
            if let raw = request.args?.axis {
                guard let parsed = SplitAxis(rawValue: raw) else {
                    return ControlResponse(ok: false, error: "invalid split axis: \(raw) (vertical|horizontal)")
                }
                axis = parsed
            } else {
                axis = nil
            }
            return actions.splitSession(
                request.target,
                window: request.args?.window,
                mode: request.args?.mode,
                axis: axis
            )
        case .sessionSplitClose:
            return actions.closeSessionSplit(request.target, window: request.args?.window)
        case .sessionSwap:
            return actions.swapSessionPanes(request.target, window: request.args?.window)
        case .sessionScratch:
            return actions.scratchSession(request.target, window: request.args?.window, mode: request.args?.mode,
                                          command: request.args?.command)
        case .sessionFocus:
            return actions.focusSessionPane(request.target, window: request.args?.window, pane: request.args?.pane)
        case .sessionResize:
            switch (request.args?.ratio, request.args?.ratioDelta, request.args?.pane) {
            case (nil, nil, _):
                return ControlResponse(ok: false, error: "session.resize requires --split-ratio, --grow-left, or --grow-right")
            case (.some, .some, _):
                return ControlResponse(ok: false, error: "session.resize: --split-ratio is mutually exclusive with --grow-left/--grow-right")
            case (.some, nil, .some):
                return ControlResponse(ok: false, error: "session.resize: --split-ratio does not accept a pane selector")
            case (.some(let ratio), nil, nil):
                return actions.resizeSplit(request.target, window: request.args?.window, resize: .ratio(ratio))
            case (nil, .some(let delta), nil):
                return actions.resizeSplit(request.target, window: request.args?.window, resize: .delta(delta))
            case (nil, .some(let delta), .some(let pane)):
                guard let target = ControlSplitResizeTarget.parse(pane) else {
                    return ControlResponse(
                        ok: false,
                        error: "invalid resize pane: \(pane) (primary|split|left|right|top|bottom)"
                    )
                }
                return actions.resizeSplit(
                    request.target,
                    window: request.args?.window,
                    resize: .paneDelta(target, delta)
                )
            }
        case .sessionCopy:
            return actions.copySessionSelection(request.target, window: request.args?.window)
        case .sessionPaste:
            return actions.pasteSession(request.target, window: request.args?.window)
        case .sessionSelectAll:
            return actions.selectAllSession(request.target, window: request.args?.window)
        case .surfaceZoom:
            guard let mode = ControlToggleMode.parse(request.args?.mode, on: "show", off: "hide") else {
                return ControlResponse(ok: false,
                                       error: "invalid surface.zoom mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSurfaceZoom(request.target, window: request.args?.window, mode: mode)
        case .surfaceCursor:
            return actions.readSurfaceCursor(request.target, window: request.args?.window)
        case .sessionOverlayOpen:
            guard let command = request.args?.command, !command.isEmpty else {
                return ControlResponse(ok: false, error: "session.overlay.open requires a command")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            let pane: OverlayPane?
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let parsed): pane = parsed
            }
            if pane != nil, request.args?.sizePercent != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.sizePercentConflict)
            }
            return actions.openSessionOverlay(request.target, window: request.args?.window,
                                              options: ControlSessionOverlayOpenOptions(
                                                command: command,
                                                cwd: request.args?.cwd,
                                                wait: request.args?.wait ?? false,
                                                sizePercent: request.args?.sizePercent,
                                                backgroundColor: request.args?.color,
                                                follow: request.args?.follow ?? false,
                                                pane: pane
                                              ))
        case .sessionOverlayClose:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.closeSessionOverlay(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayResize:
            if request.args?.pane != nil {
                return ControlResponse(ok: false, error: PaneOverlayError.resizeUnsupported)
            }
            let wantsFull = request.args?.full == true
            let percent = request.args?.sizePercent
            if wantsFull, percent != nil {
                return ControlResponse(ok: false,
                                       error: "session.overlay.resize: --full is mutually exclusive with --size-percent")
            }
            if !wantsFull, percent == nil {
                return ControlResponse(ok: false,
                                       error: "session.overlay.resize requires --size-percent or --full")
            }
            if let percent, !(1...100).contains(percent) {
                return ControlResponse(ok: false,
                                       error: "session.overlay.resize: --size-percent must be 1...100")
            }
            return actions.resizeSessionOverlay(request.target, window: request.args?.window,
                                                sizePercent: wantsFull ? nil : percent)
        case .sessionOverlayResult:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.sessionOverlayResult(request.target, window: request.args?.window, pane: pane)
            }
        case .sessionOverlayCopy:
            switch parseOverlayPane(request.args?.pane) {
            case .rejected(let response): return response
            case .pane(let pane):
                return actions.copySessionOverlaySelection(
                    request.target,
                    window: request.args?.window,
                    pane: pane
                )
            }
        case .sessionOverlayText:
            return dispatchSessionOverlayText(request)
        case .sessionBackground:
            return dispatchSessionBackground(request)
        case .sessionText:
            return dispatchSessionText(request)
        default:
            preconditionFailure("unexpected session surface command: \(request.cmd.rawValue)")
        }
    }

    private enum OverlayPaneParse {
        case pane(OverlayPane?)
        case rejected(ControlResponse)
    }

    private func parseOverlayPane(_ raw: String?) -> OverlayPaneParse {
        guard let raw else { return .pane(nil) }
        guard let pane = OverlayPane(controlName: raw) else {
            return .rejected(ControlResponse(ok: false, error: PaneOverlayError.invalidPane))
        }
        return .pane(pane)
    }

    private func dispatchHudCommand(_ request: ControlRequest) -> ControlResponse {
        if request.cmd == .sessionHudClose {
            return actions.closeHud(request.target, window: request.args?.window)
        }
        let spec: HudSpec
        switch parseHudSpec(request) {
        case .rejected(let response): return response
        case .spec(let parsed): spec = parsed
        }
        if request.cmd == .sessionHudOpen {
            return actions.openHud(request.target, window: request.args?.window, spec: spec)
        }
        return actions.updateHud(request.target, window: request.args?.window, spec: spec)
    }

    private enum HudSpecParse {
        case spec(HudSpec)
        case rejected(ControlResponse)
    }

    private func parseHudSpec(_ request: ControlRequest) -> HudSpecParse {
        let args = request.args
        guard let message = args?.message, !message.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .rejected(ControlResponse(ok: false, error: "\(request.cmd.rawValue) requires a message"))
        }
        guard !containsControlCharacters(message), !containsControlCharacters(args?.detail ?? "") else {
            return .rejected(ControlResponse(ok: false, error: "hud text must not contain control characters"))
        }
        guard hudTextLength(message) <= HudSpec.maxTextLength else {
            return .rejected(ControlResponse(
                ok: false, error: "hud message too long (max \(HudSpec.maxTextLength) characters)"))
        }
        guard hudTextLength(args?.detail ?? "") <= HudSpec.maxTextLength else {
            return .rejected(ControlResponse(
                ok: false, error: "hud detail too long (max \(HudSpec.maxTextLength) characters)"))
        }
        if let color = args?.color, !WatermarkConfig.isValidColorHex(color) {
            return .rejected(ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)"))
        }
        if let textColor = args?.textColor, !WatermarkConfig.isValidColorHex(textColor) {
            return .rejected(ControlResponse(ok: false, error: "invalid text color: \(textColor) (#rrggbb)"))
        }
        if let percent = args?.sizePercent, !(1...100).contains(percent) {
            return .rejected(ControlResponse(
                ok: false, error: "\(request.cmd.rawValue): --size-percent must be 1...100"))
        }
        let position: HudPosition
        if let raw = args?.position {
            guard let parsed = HudPosition.parse(raw) else {
                return .rejected(ControlResponse(
                    ok: false, error: "invalid position: \(raw) (\(HudPosition.acceptedNamesList))"))
            }
            position = parsed
        } else {
            position = .defaultPosition
        }
        var spinner: HudSpinner?
        if let raw = args?.spinner, raw != HudSpinner.noneName {
            guard let parsed = HudSpinner(rawValue: raw) else {
                return .rejected(ControlResponse(
                    ok: false, error: "invalid spinner: \(raw) (\(HudSpinner.acceptedNamesList))"))
            }
            spinner = parsed
        }
        return .spec(HudSpec(message: message, detail: args?.detail, spinner: spinner,
                             backgroundColor: args?.color, textColor: args?.textColor,
                             sizePercent: args?.sizePercent, position: position))
    }

    private func hudTextLength(_ text: String) -> Int {
        text.precomposedStringWithCanonicalMapping.unicodeScalars.count
    }

    private func dispatchAppCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .fontInc:
            return actions.font(request.target, window: request.args?.window, pane: request.args?.pane,
                                action: FontBindingAction.increase)
        case .fontDec:
            return actions.font(request.target, window: request.args?.window, pane: request.args?.pane,
                                action: FontBindingAction.decrease)
        case .fontReset:
            return actions.font(request.target, window: request.args?.window, pane: request.args?.pane,
                                action: FontBindingAction.reset)
        case .keymapReload:
            return actions.reloadKeymap()
        case .keymapList:
            return actions.listKeymap()
        case .version:
            return actions.appIdentity()
        case .configReload:
            return actions.reloadGhosttyConfig()
        case .notify:
            guard let body = request.args?.body, !body.isEmpty else {
                return ControlResponse(ok: false, error: "notify requires a body")
            }
            return actions.sendNotification(request.target, window: request.args?.window,
                                            title: request.args?.title, body: body)
        case .themeSet:
            return actions.setTheme(args: request.args)
        case .themeList:
            return actions.listThemes()
        case .sidebar:
            guard let mode = ControlToggleMode.parse(request.args?.mode, on: "show", off: "hide") else {
                return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSidebarVisibility(mode)
        case .sidebarMode:
            guard let mode = ControlSidebarViewMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false, error: "invalid sidebar mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.setSidebarViewMode(mode)
        case .sidebarExpand:
            return actions.expandSidebar(window: request.args?.window)
        case .sidebarCollapse:
            return actions.collapseSidebar(window: request.args?.window)
        case .sidebarWidth:
            guard let points = request.args?.sidebarWidth, points.isFinite else {
                return ControlResponse(ok: false, error: "sidebar.width requires a width in points")
            }
            return actions.setSidebarWidth(points, window: request.args?.window)
        case .restoreClear:
            return actions.clearRestoreCommands()
        case .restoreCapture:
            return actions.captureRestoreCommands()
        case .recentClear:
            return actions.clearRecentClosedItems()
        default:
            preconditionFailure("unexpected app command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchSessionBackground(_ request: ControlRequest) -> ControlResponse {
        if let fit = request.args?.fit, !WatermarkConfig.isValidFit(fit) {
            return ControlResponse(ok: false, error: "invalid fit: \(fit) (contain|cover|stretch|none)")
        }
        if let position = request.args?.position, !WatermarkConfig.isValidPosition(position) {
            return ControlResponse(ok: false, error: "invalid position: \(position)")
        }
        if let opacity = request.args?.opacity, !WatermarkConfig.isValidOpacity(opacity) {
            return ControlResponse(ok: false, error: "invalid opacity: \(opacity) (0.0-1.0)")
        }
        let watermark: BackgroundWatermark?
        switch request.args?.mode {
        case "image":
            guard let path = request.args?.path, !path.isEmpty else {
                return ControlResponse(ok: false, error: "session.background image requires a path")
            }
            guard WatermarkConfig.isValidImagePath(path) else {
                return ControlResponse(ok: false, error: "image path must not contain control characters")
            }
            watermark = BackgroundWatermark(kind: .image, imagePath: path, opacity: request.args?.opacity,
                                            fit: request.args?.fit.flatMap(BackgroundWatermark.Fit.init(rawValue:)),
                                            position: request.args?.position.flatMap(BackgroundWatermark.Position.init(rawValue:)),
                                            repeats: request.args?.repeats)
        case "text":
            guard let text = request.args?.text, !text.isEmpty else {
                return ControlResponse(ok: false, error: "session.background text requires text")
            }
            guard text.count <= WatermarkConfig.maxTextLength else {
                return ControlResponse(ok: false,
                                       error: "session.background text too long (max \(WatermarkConfig.maxTextLength) characters)")
            }
            if let color = request.args?.color, !WatermarkConfig.isValidColorHex(color) {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            watermark = BackgroundWatermark(kind: .text, text: text, colorHex: request.args?.color,
                                            opacity: request.args?.opacity,
                                            fit: request.args?.fit.flatMap(BackgroundWatermark.Fit.init(rawValue:)),
                                            position: request.args?.position.flatMap(BackgroundWatermark.Position.init(rawValue:)))
        case "color":
            guard let color = request.args?.color, !color.isEmpty else {
                return ControlResponse(ok: false, error: "session.background color requires a color")
            }
            guard WatermarkConfig.isValidColorHex(color) else {
                return ControlResponse(ok: false, error: "invalid color: \(color) (#rrggbb)")
            }
            watermark = BackgroundWatermark(kind: .color, colorHex: color)
        case "clear", .none:
            watermark = nil
        default:
            return ControlResponse(ok: false,
                                   error: "invalid background mode: \(request.args?.mode ?? "") (image|text|color|clear)")
        }
        return actions.setSessionBackground(request.target, window: request.args?.window,
                                            options: ControlSessionBackgroundOptions(watermark: watermark))
    }

    private func dispatchSessionText(_ request: ControlRequest) -> ControlResponse {
        let all = request.args?.all ?? false
        let lines = request.args?.lines
        if all, lines != nil {
            return ControlResponse(ok: false, error: "use either --all or --lines, not both")
        }
        if let lines, lines <= 0 {
            return ControlResponse(ok: false, error: "--lines must be greater than 0")
        }
        return actions.readSessionText(request.target, window: request.args?.window,
                                       options: ControlSessionTextOptions(pane: request.args?.pane,
                                                                          all: all,
                                                                          lines: lines))
    }

    private func dispatchSessionOverlayText(_ request: ControlRequest) -> ControlResponse {
        let all = request.args?.all ?? false
        let lines = request.args?.lines
        if all, lines != nil {
            return ControlResponse(ok: false, error: "use either --all or --lines, not both")
        }
        if let lines, lines <= 0 {
            return ControlResponse(ok: false, error: "--lines must be greater than 0")
        }
        switch parseOverlayPane(request.args?.pane) {
        case .rejected(let response): return response
        case .pane(let pane):
            return actions.readSessionOverlayText(
                request.target,
                window: request.args?.window,
                options: ControlSessionOverlayTextOptions(pane: pane, all: all, lines: lines)
            )
        }
    }

    private func dispatchWindowCommand(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .windowRename:
            guard let name = request.args?.name?.linuxTrimmedOrNil else {
                return ControlResponse(ok: false, error: "window.rename requires a name")
            }
            return actions.windowRename(request.target, name: name)
        case .windowResize:
            guard let width = request.args?.width, let height = request.args?.height,
                  width > 0, height > 0 else {
                return ControlResponse(ok: false, error: "window.resize requires positive width and height")
            }
            return actions.windowResize(request.target, width: width, height: height)
        case .windowMove:
            guard let x = request.args?.x, let y = request.args?.y else {
                return ControlResponse(ok: false, error: "window.move requires x and y")
            }
            return actions.windowMove(request.target, x: x, y: y, display: request.args?.display)
        case .windowZoom:
            return actions.windowZoom(request.target)
        case .windowFullscreen:
            return actions.windowFullscreen(request.target)
        case .windowMinimize:
            guard let mode = ControlToggleMode.parse(request.args?.mode) else {
                return ControlResponse(ok: false,
                                       error: "invalid minimize mode: \(request.args?.mode ?? "toggle")")
            }
            return actions.windowMinimizeSync(request.target, mode: mode)
        default:
            preconditionFailure("unexpected window command: \(request.cmd.rawValue)")
        }
    }

    private func dispatchDashboard(_ request: ControlRequest) -> ControlResponse {
        let args = request.args
        let targets = args?.targets ?? []
        let fontSize = args?.fontSize
        let autoSize = args?.autoSize ?? false
        let mru = args?.mru ?? false
        if args?.close == true {
            guard targets.isEmpty, !mru, fontSize == nil, !autoSize else {
                return ControlResponse(ok: false,
                                       error: "dashboard --close takes no ids, --mru, or font options")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: true,
                                        fontMode: .untouched, mru: false)
        }
        if fontSize != nil, autoSize {
            return ControlResponse(ok: false,
                                   error: "dashboard: --font-size is mutually exclusive with --auto-size")
        }
        if let fontSize, !fontSize.isFinite || fontSize <= 0 {
            return ControlResponse(ok: false, error: "dashboard --font-size must be a positive number")
        }
        let mode: DashboardFontMode = autoSize ? .auto : (fontSize.map(DashboardFontMode.fixed) ?? .untouched)
        if mru {
            guard targets.isEmpty else {
                return ControlResponse(ok: false,
                                       error: "dashboard --mru cannot be combined with explicit session ids")
            }
            return actions.setDashboard(targets: [], window: args?.window, close: false,
                                        fontMode: mode, mru: true)
        }
        guard !targets.isEmpty else {
            return ControlResponse(ok: false, error: "dashboard requires at least one session id")
        }
        if let malformed = targets.first(where: { DashboardTarget(rawValue: $0) == nil }) {
            return ControlResponse(
                ok: false,
                error: "dashboard: invalid session id '\(malformed)' — use <id>, <id>:left, or <id>:right")
        }
        return actions.setDashboard(targets: targets, window: args?.window, close: false,
                                    fontMode: mode, mru: false)
    }
}
