import Foundation
import agtermCore

/// Where each local launch from a session starts. A remote row reports far-side paths, so every site passes
/// its own inherited path through `Session.localWorkingDirectory`; see control-api.md's Remote sessions.
extension AppController {
    static func overlayLaunchCwd(_ session: Session, pane: OverlayPane?, home: String = homeCwd) -> String {
        let explicit = if let pane { session.paneOverlay(pane)?.cwd } else { session.overlayCwd }
        return OverlayLaunchContext.cwd(explicit: explicit, session: session, homeDirectory: home)
    }

    static func splitLaunchCwd(_ session: Session, home: String = homeCwd) -> String {
        session.localWorkingDirectory(reported: session.initialSplitCwd ?? session.effectiveCwd, homeDirectory: home)
    }

    static func scratchLaunchCwd(_ session: Session, home: String = homeCwd) -> String {
        session.localWorkingDirectory(reported: session.effectiveCwd, homeDirectory: home)
    }

    static func quickTerminalCwd(activeSession: Session?, home: String = homeCwd) -> String {
        guard let session = activeSession else { return home }
        return session.localWorkingDirectory(reported: session.effectiveCwd, homeDirectory: home)
    }

    func newSessionIndex(in workspace: UUID) -> Int? {
        store.newSessionInsertionIndex(inWorkspace: workspace,
                                      placement: linuxSettingsStore().load().effectiveNewSessionPlacement)
    }

    static func newSessionCwd(settings: AppSettings, activeSession: Session?, home: String = homeCwd) -> String {
        let current = activeSession.map { $0.localWorkingDirectory(reported: $0.focusedCwd, homeDirectory: home) }
        return settings.resolveNewSessionCwd(currentSessionCwd: current, home: home)
    }
}
