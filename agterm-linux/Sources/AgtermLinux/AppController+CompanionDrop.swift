import Foundation
import agtermCore

@MainActor
extension AppController {
    /// Single companions may change groups in the ordinary tree; flagged and block drags keep their sibling rules.
    func handleCompanionDrop(_ ids: [UUID], onto target: UUID, y: Double, targetHeight: Double) -> Bool {
        guard store.sidebarMode == .tree, ids.count == 1, let id = ids.first,
              let parent = store.session(withID: id)?.parentID,
              let destination = store.session(withID: target) else { return false }
        let row: SidebarDrop.CompanionDropRow
        let index: Int
        if let targetParent = destination.parentID {
            guard let position = store.companions(of: targetParent).firstIndex(where: { $0.id == target }) else { return false }
            row = .parent(targetParent)
            index = LinuxSidebarPolicy.dropInsertionSlot(targetIndex: position, y: y, height: targetHeight)
        } else {
            row = .parent(target)
            index = SidebarDrop.onItemIndex
        }
        guard let move = SidebarDrop.companionReparent(from: parent, onto: row, childIndex: index),
              case .success = store.canMoveCompanion(id, under: move.parent) else { return false }
        var args = ControlArgs()
        args.parent = move.parent.uuidString
        args.index = move.slot
        if sendRemoteGUI(ControlRequest(cmd: .sessionCompanionMove, target: id.uuidString, args: args)) { return true }
        _ = moveLinuxCompanion(id.uuidString, parent: move.parent.uuidString, index: move.slot)
        return true
    }
}
