import Foundation
import agtermCore

@MainActor
extension AppController {
    func physicalPaneInput(_ id: UUID, pane: StatusPane, keystroke: StatusKeystroke) {
        let settings = linuxSettingsStore().load()
        store.forwardSeenKeystroke(keystroke, forSession: id)
        if settings.effectiveBadgeReset.clearsBadge(on: keystroke) { store.clearUnseen(id) }
        if store.forwardStatusKeystroke(keystroke, pane: pane, forSession: id) { return }
        guard store.session(withID: id)?.remotePresentation?.allowsKeystrokeStatusClear != false else { return }
        store.clearStatus(by: keystroke, pane: pane, reset: settings.effectiveStatusReset, forSession: id)
    }

    func setBadgeResetAtIndex(_ index: Int) {
        guard StatusReset.allCases.indices.contains(index) else { return }
        let mode = StatusReset.allCases[index]
        persist(\.badgeReset, mode == .firstKey ? nil : mode.rawValue)
    }
}
