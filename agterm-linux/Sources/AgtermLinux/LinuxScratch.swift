import Foundation
import agtermCore

@MainActor
extension AppController {
    func makeScratchSurface(_ session: Session) -> GhosttySurface {
        let command = session.scratchCommand
        session.scratchCommand = nil
        let cwd = Self.scratchLaunchCwd(session)
        var environment = sessionEnv(for: session, pane: .scratch)
        var spawn = command
        var backed = false
        var detached: String?
        if session.originScratch == nil {
            session.scratchCwd = cwd
            if gRestoreLaunchDecision.active == .live, session.remoteHost == nil {
                let identity = session.localScratchIdentity ?? UUID()
                environment["AGTERM_PANE_ID"] = identity.uuidString
                let lead = ZmxLeadAttachment(claim: false)
                if case .success(let configuration) = LinuxZmxLaunch.configuration(
                    paneIdentity: identity, baseEnvironment: environment, lead: lead) {
                    store.recordLiveScratch(session.id, identity: identity)
                    environment = configuration.environment
                    spawn = ZmxSupport.attachCommand(configuration, replaying: nil, paneCommand: command, denylist: [])
                    detached = ZmxSupport.attachCommand(configuration, replaying: nil, paneCommand: command, denylist: [], detached: true)
                    backed = true
                    ZmxLeadBook.shared.begin(lead, pane: identity)
                }
            } else if gRestoreLaunchDecision.requested != .live {
                store.forgetSavedScratch(session.id)
            }
        }
        if environment["AGTERM_PANE_ID"] == nil {
            environment["AGTERM_PANE_ID"] = (session.scratchClientIdentity ?? UUID()).uuidString
        }
        let surface = GhosttySurface(sessionID: session.id, cwd: cwd, command: spawn,
                                     env: environment, controller: self, role: .scratch, reportsPaneState: false,
                                     fontSize: session.fontSize, backedByZmx: backed)
        surface.onExit = { [weak self] in self?.closeScratch(session.id) }
        surface.detachedLaunchCommand = detached
        return surface
    }

    func scratchReportedPwd(_ id: UUID, _ pwd: String) {
        guard let session = store.session(withID: id), session.scratchSurface != nil else { return }
        session.scratchCwd = pwd
    }
}
