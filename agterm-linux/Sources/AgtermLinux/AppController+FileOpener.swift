import Foundation
import agtermCore

@MainActor
extension AppController {
    /// Resolve the clicked slot by current ownership: a retired split can retain its session id.
    @discardableResult
    func runFileOpener(_ opener: FileOpener, path: String, surface: GhosttySurface, host: String? = nil) -> Bool {
        guard gWindows[windowID] === self, let session = store.session(withID: surface.sessionID) else { return false }
        let pane: CommandContext.Pane
        if surfaces[session.id] === surface {
            pane = .left
        } else if splitSurfaces[session.id] === surface {
            pane = .right
        } else if scratchSurfaces[session.id] === surface {
            pane = .scratch
        } else { return false }
        let workspace = store.workspace(forSession: session.id)
        let context = CommandContext(sessionID: session.id.uuidString, sessionName: session.displayName,
            sessionPWD: session.cwd(for: pane), sessionHost: TerminalText.sanitized(session.remoteHost ?? ""),
            workspaceID: workspace?.id.uuidString ?? "", workspaceName: workspace?.name ?? "",
            windowID: windowID.uuidString, windowName: gLibrary.windows.first(where: { $0.id == windowID })?.name ?? "",
            pane: pane, paneID: session.paneToken(for: pane), selection: "", socket: gControlServer.resolvedSocketPath)
        let origin = customCommandOrigin
        let launched = LinuxCustomCommandProcess.launch(command: opener.command, context: context,
            localWorkingDirectory: FileManager.default.homeDirectoryForCurrentUser.path, openerPath: path,
            launcher: origin.launcher) { [weak self, weak origin] failure in
                runOnMain { MainActor.assumeIsolated {
                    guard let self, let origin, self.customCommandOrigin === origin, gWindows[self.windowID] === self else { return }
                    origin.deliverIfActive {
                        self.reportCustomCommandFailure(failure, command: opener.command, sessionID: context.sessionID)
                    }
                } }
            }
        if launched { store.emitOpenerRun(session: session, pane: pane.rawValue, path: path, selector: opener.command.name, host: host) }
        return launched
    }
}
