import Foundation
import agtermCore

@MainActor
extension AppController {
    func setFlagsFromGUI(_ ids: [UUID], on: Bool) {
        if sendRemoteGUI(ControlRequest(cmd: .sessionFlag, args: ControlArgs(targets: ids.map(\.uuidString), mode: on ? "on" : "off"))) { return }
        store.setFlag(on, forSessions: ids)
    }

    func setTintFromGUI(_ tint: SidebarTint?, id: UUID, workspace: Bool = false) {
        let request = ControlRequest(cmd: workspace ? .workspaceTint : .sessionTint, target: id.uuidString,
            args: ControlArgs(mode: tint == nil ? "clear" : "set", tint: tint?.color.rawValue, tintOn: tint?.parts.map(\.rawValue)))
        if sendRemoteGUI(request) { return }
        if workspace { store.setTint(tint, forWorkspace: id) } else { store.setTint(tint, forSession: id) }
    }

    func createSessionFromGUI(in workspace: UUID) {
        if sendRemoteGUI(ControlRequest(cmd: .sessionNew, args: ControlArgs(workspace: workspace.uuidString))) { return }
        _ = store.addSession(toWorkspace: workspace, cwd: newSessionCwd(in: workspace), at: newSessionIndex(in: workspace))
    }

    func createWorkspaceFromGUI() {
        if sendRemoteGUI(ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: store.defaultWorkspaceName))) { return }
        _ = store.addSession(toWorkspace: store.addWorkspace(name: store.defaultWorkspaceName).id, cwd: Self.homeCwd)
    }

    func renameRowFromGUI(_ id: UUID, isWorkspace: Bool, to name: String) {
        if sendRemoteGUI(ControlRequest(cmd: isWorkspace ? .workspaceRename : .sessionRename,
                                       target: id.uuidString, args: ControlArgs(name: name))) { return }
        if isWorkspace { store.renameWorkspace(id, to: name) } else { store.renameSession(id, to: name) }
    }

    func toggleSplitRespectingHost(_ id: UUID, axis: SplitAxis?) {
        if sendRemoteGUI(ControlRequest(cmd: .sessionSplit, target: id.uuidString,
                                       args: ControlArgs(mode: "toggle", axis: axis?.rawValue))) { return }
        store.toggleSplit(id, axis: axis)
    }

    func toggleScratchRespectingHost(_ id: UUID) {
        if sendRemoteGUI(ControlRequest(cmd: .sessionScratch, target: id.uuidString, args: ControlArgs(mode: "toggle"))) { return }
        store.toggleScratch(id)
    }

    func removeWorkspaceRespectingHost(_ id: UUID) {
        if sendRemoteGUI(ControlRequest(cmd: .workspaceDelete, target: id.uuidString)) { return }
        store.removeWorkspace(id)
    }

    func moveSessionRespectingHost(_ id: UUID, toWorkspace workspace: UUID) {
        if sendRemoteGUI(ControlRequest(cmd: .sessionMove, target: id.uuidString, args: ControlArgs(workspace: workspace.uuidString))) { return }
        store.moveSession(id, toWorkspace: workspace)
    }

    @discardableResult
    func moveSessionsRespectingHost(_ ids: [UUID], toWorkspace workspace: UUID, at index: Int? = nil) -> Int {
        let target = store.workspaces.first(where: { $0.id == workspace })?.sessions[safe: index ?? -1]?.id
        let args = target.map { ControlArgs(targets: ids.map(\.uuidString), before: $0.uuidString) }
            ?? ControlArgs(targets: ids.map(\.uuidString), workspace: workspace.uuidString)
        if sendRemoteGUI(ControlRequest(cmd: .sessionMove, target: ids.first?.uuidString, args: args)) { return 0 }
        return store.moveSessions(ids, toWorkspace: workspace, at: index)
    }

    func reorderSessionRespectingHost(_ id: UUID, _ direction: ReorderDirection) {
        if sendRemoteGUI(ControlRequest(cmd: .sessionMove, target: id.uuidString, args: ControlArgs(to: direction.rawValue))) { return }
        store.reorderSession(id, direction)
    }

    func reorderWorkspaceRespectingHost(_ id: UUID, _ direction: ReorderDirection) {
        if sendRemoteGUI(ControlRequest(cmd: .workspaceMove, target: id.uuidString, args: ControlArgs(to: direction.rawValue))) { return }
        store.reorderWorkspace(id, direction)
    }

    func newSessionCwd(in workspace: UUID) -> String {
        Self.newSessionCwd(settings: linuxSettingsStore().load(), activeSession: store.newSessionDirectorySource(inWorkspace: workspace))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
