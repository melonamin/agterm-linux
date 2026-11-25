import Foundation
import agtermCore

@MainActor
extension AppController {
    /// Single rows can change their group in the tree; flagged and block drags keep their sibling rules.
    func handleCompanionDrop(_ ids: [UUID], onto target: UUID, y: Double, targetHeight: Double) -> Bool {
        guard store.sidebarMode == .tree, ids.count == 1, let id = ids.first,
              let source = store.session(withID: id),
              let destination = store.session(withID: target) else { return false }
        let middle = y > targetHeight / 3 && y < targetHeight * 2 / 3
        if source.parentID == nil {
            guard destination.parentID == nil, middle else { return false }
            guard case .success = store.canMoveCompanion(id, under: target) else { return true }
            var args = ControlArgs()
            args.parent = target.uuidString
            args.index = 0
            if sendRemoteGUI(ControlRequest(cmd: .sessionCompanionMove, target: id.uuidString, args: args)) { return true }
            _ = moveLinuxCompanion(id.uuidString, parent: target.uuidString, index: 0)
            return true
        }
        guard let parent = source.parentID else { return false }
        if destination.parentID == nil, !middle {
            _ = promoteCompanionRespectingHost(id, placement: .beside(target.uuidString, after: y >= targetHeight / 2))
            return true
        }
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
