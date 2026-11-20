import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func appendCompanionPlacementMenu(to box: OpaquePointer?, session id: UUID) {
        guard let row = store.session(withID: id) else { return }
        if row.parentID == nil {
            appendSidebarAction(to: box, title: "Convert to Companion") { [weak self] in
                guard let self else { return }
                dismissContextMenu()
                let request = ControlRequest(cmd: .sessionCompanionConvert, target: id.uuidString)
                if sendRemoteGUI(request) { return }
                let response = convertToCompanion(id.uuidString, window: nil)
                if !response.ok { NotificationManager.send(title: "Convert to Companion", body: response.error ?? "could not convert session") }
            }
        } else {
            let destinations = store.workspaces.flatMap(\.sessions).filter { parent in
                guard parent.parentID == nil, parent.id != row.parentID else { return false }
                if case .success = store.canMoveCompanion(id, under: parent.id) { return true }
                return false
            }
            guard !destinations.isEmpty else { return }
            appendSidebarAction(to: box, title: "Move to…") { [weak self] in
                guard let self else { return }
                dismissContextMenu()
                let pick = PendingPick(id: UUID().uuidString,
                    items: destinations.map { ControlPickItem(id: $0.id.uuidString, label: $0.displayName,
                        subtitle: self.store.workspace(forSession: $0.id)?.name) }, prompt: "Move companion to which session?")
                guard openPick(pick, window: nil, follow: true).ok else { return }
                controlPickCompletion = { [weak self] answer in
                    guard let self, answer.result == .picked, let parent = answer.id else { return }
                    var args = ControlArgs()
                    args.parent = parent
                    let request = ControlRequest(cmd: .sessionCompanionMove, target: id.uuidString, args: args)
                    if sendRemoteGUI(request) { return }
                    let response = moveLinuxCompanion(id.uuidString, parent: parent, index: nil)
                    if !response.ok { NotificationManager.send(title: "Move Companion", body: response.error ?? "could not move companion") }
                }
            }
        }
    }
}
