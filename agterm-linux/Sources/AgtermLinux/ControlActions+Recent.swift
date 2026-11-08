import Foundation
import agtermCore

@MainActor
extension AppController {
    func listRecentClosed() -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(recent: library.recentClosedItems.map(ControlRecentItem.init)))
    }

    func clearRecentClosed() -> ControlResponse {
        guard library.clearRecentClosedItems() else { return err("could not clear recent items") }
        return ok()
    }

    func openRecentClosed(_ target: String?, window: String?) -> ControlResponse {
        let itemID: UUID
        switch RecentClosedTarget.resolve(target, in: library.recentClosedItems) {
        case .failure(let failure): return err(failure.message)
        case .success(let id): itemID = id
        }
        guard !library.recentClosedItemLacksParent(itemID) else {
            return err("parent session is not open or in Recent Closed")
        }
        guard let item = library.recentClosedItems.first(where: { $0.id == itemID }),
              let outcome = library.reopenRecentClosedOutcome(itemID, into: store) else {
            return err("could not reopen \(itemID.uuidString)")
        }
        gWindows[outcome.window]?.reconcile(focusActive: false)
        return ControlResponse(ok: true, result: ControlResult(recentOpen: ControlRecentOpen(
            item: ControlRecentItem(item), window: outcome.window.uuidString, complete: outcome.complete)))
    }
}
