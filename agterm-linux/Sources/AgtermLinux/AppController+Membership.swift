import CGtk
import Foundation
import agtermCore

@MainActor
extension AppController {
    func showMembershipEditor(workspaces: Bool) {
        showPalette()
        guard let window = paletteWindow else { return }
        gtk_window_set_title(WIN(window), workspaces ? "Edit Focused Workspaces" : "Edit Flagged Sessions")
        paletteAll = LinuxPaletteList(items: membershipRows(workspaces: workspaces),
                                     keepsOpenOnRun: true,
                                     refresh: { [weak self] in self?.membershipRows(workspaces: workspaces) ?? [] },
                                     preservesNaturalOrder: true)
        filterPalette("")
    }

    private func membershipRows(workspaces: Bool) -> [LinuxPaletteItem] {
        if workspaces {
            return store.workspaces.map { workspace in
                let marked = store.focusedWorkspaceIDs.contains(workspace.id)
                return (row: LinuxPaletteRow(title: workspace.name, badge: marked ? "✓" : nil), run: { [weak self] in
                    guard let self else { return }
                    self.store.setFocusMembership(workspace.id, member: !self.store.focusedWorkspaceIDs.contains(workspace.id))
                    self.syncSidebar()
                })
            }
        }
        return store.workspaces.flatMap(\.sessions).map { session in
            (row: LinuxPaletteRow(title: store.listLabel(for: session), badge: session.flagged ? "✓" : nil,
                                  indicator: session.agentIndicator), run: { [weak self] in
                guard let self, let current = self.store.session(withID: session.id) else { return }
                self.store.setFlag(!current.flagged, forSession: current.id)
                self.syncSidebar()
            })
        }
    }

    func navigateAttention(_ direction: SessionNavigation) {
        guard store.attentionNavigationAcrossWindows else { navigate(direction); return }
        guard let target = library.attentionStep(from: windowID, forward: direction == .nextAttention, eligible: {
            gWindows[$0].map { !$0.pickController.modalPending && $0.terminalZoom.target == nil && !$0.dashboard.isOpen } ?? false
        }) else { return }
        selectAttention(windowID: target.windowID, sessionID: target.sessionID)
    }
}
