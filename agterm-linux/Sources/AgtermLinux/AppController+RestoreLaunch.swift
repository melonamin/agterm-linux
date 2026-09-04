import agtermCore
import Foundation

struct LinuxLaunchSeed {
    let command: String?
    let initialInput: String?
    let waitAfterCommand: Bool
}

struct LinuxPaneLaunchProvider {
    let environment: [String: String]
    let backedByZmx: Bool
    let shouldPace: Bool
    let resolve: @MainActor (StatusPane) -> LinuxLaunchSeed
}

private struct LinuxLaunchSeedPolicy {
    let restoreEnabled: Bool
    let denylist: Set<String>
    let runningNames: Set<String>?
}

@MainActor
extension AppController {
    /// Defers consuming captured argv and restore overrides until libghostty actually creates the pane.
    /// A paced pane may be swapped while waiting, so the provider resolves against its live role.
    func paneLaunchProvider(for session: Session, pane: StatusPane) -> LinuxPaneLaunchProvider {
        let baseEnvironment = sessionEnv(for: session, pane: pane)
        let identity = pane == .right ? session.splitPaneIdentity : session.paneIdentity
        let decision = gRestoreLaunchDecision
        let disposition: ZmxSupport.LaunchDisposition
        if decision.requested == .live, session.remoteHost == nil, let identity {
            let configuration = try? LinuxZmxLaunch.configuration(
                paneIdentity: identity, baseEnvironment: baseEnvironment
            ).get()
            disposition = ZmxSupport.launchDisposition(
                requested: decision.requested, active: decision.active, configuration: configuration
            )
        } else {
            disposition = .ordinary
        }
        let policy = LinuxLaunchSeedPolicy(
            restoreEnabled: linuxSettingsStore().load().effectiveRestoreMode == .rerun,
            denylist: restoreDenylist(),
            runningNames: gZmxRunningNames
        )
        let shouldPace = shouldPace(
            session: session, pane: pane, disposition: disposition, policy: policy
        )
        let environment: [String: String]
        if case .wrapped(let configuration) = disposition {
            environment = configuration.environment
        } else {
            environment = baseEnvironment
        }
        return LinuxPaneLaunchProvider(
            environment: environment,
            backedByZmx: disposition.backedByZmx,
            shouldPace: shouldPace
        ) { [weak self, weak session] livePane in
            guard let self, let session else {
                return Self.unownedSeed(disposition: disposition)
            }
            return self.launchSeed(
                session: session, pane: livePane, disposition: disposition, policy: policy
            )
        }
    }

    private func launchSeed(session: Session, pane: StatusPane,
                            disposition: ZmxSupport.LaunchDisposition,
                            policy: LinuxLaunchSeedPolicy) -> LinuxLaunchSeed {
        switch disposition {
        case .wrapped(let configuration):
            let replay = session.takePendingForegroundCommand(pane: pane)
            let creationCommand = replay == nil ? durableCommand(session: session, pane: pane) : nil
            return LinuxLaunchSeed(
                command: ZmxSupport.attachCommand(
                    configuration, replaying: replay, creationCommand: creationCommand,
                    denylist: policy.denylist
                ),
                initialInput: nil,
                waitAfterCommand: false
            )
        case .ordinary:
            let capture = session.takePendingForegroundCommand(pane: pane)
            let plan = CommandRestore.restorePlan(.init(
                wasRestored: session.wasRestored,
                restoreEnabled: policy.restoreEnabled,
                hadForeground: capture != nil,
                foregroundInput: restoreInput(capture, policy: policy),
                initialCommand: durableCommand(session: session, pane: pane),
                restoreOverride: session.takePendingRestoreOverride(pane: pane),
                requestedWait: requestedWait(session: session, pane: pane)
            ))
            return LinuxLaunchSeed(command: plan.command, initialInput: plan.initialInput,
                                   waitAfterCommand: plan.waitAfterCommand)
        case .fallback:
            let plan = CommandRestore.restorePlan(.init(
                wasRestored: session.wasRestored,
                restoreEnabled: false,
                hadForeground: false,
                foregroundInput: nil,
                initialCommand: durableCommand(session: session, pane: pane),
                restoreOverride: nil,
                requestedWait: requestedWait(session: session, pane: pane)
            ))
            return LinuxLaunchSeed(command: plan.command, initialInput: plan.initialInput,
                                   waitAfterCommand: plan.waitAfterCommand)
        }
    }

    private func shouldPace(session: Session, pane: StatusPane,
                            disposition: ZmxSupport.LaunchDisposition,
                            policy: LinuxLaunchSeedPolicy) -> Bool {
        guard session.wasRestored else { return false }
        switch disposition {
        case .wrapped(let configuration):
            if policy.runningNames?.contains(configuration.daemonName) == true { return false }
            if let capture = peekCapture(session: session, pane: pane) {
                return CommandRestore.shouldRestore(argv: capture, denylist: policy.denylist)
            }
            return durableCommand(session: session, pane: pane) != nil
        case .ordinary:
            let capture = peekCapture(session: session, pane: pane)
            let plan = CommandRestore.restorePlan(.init(
                wasRestored: true,
                restoreEnabled: policy.restoreEnabled,
                hadForeground: capture != nil,
                foregroundInput: restoreInput(capture, policy: policy),
                initialCommand: durableCommand(session: session, pane: pane),
                restoreOverride: peekRestoreOverride(session: session, pane: pane),
                requestedWait: false
            ))
            return plan.command != nil || plan.initialInput != nil
        case .fallback:
            return false
        }
    }

    private func restoreInput(_ argv: [String]?, policy: LinuxLaunchSeedPolicy) -> String? {
        guard policy.restoreEnabled, let argv,
              CommandRestore.shouldRestore(argv: argv, denylist: policy.denylist) else { return nil }
        return CommandRestore.shellQuotedLine(argv) + "\n"
    }

    private func peekCapture(session: Session, pane: StatusPane) -> [String]? {
        switch pane {
        case .left: session.pendingForegroundCommand
        case .right: session.pendingSplitForegroundCommand
        case .scratch: nil
        }
    }

    private func peekRestoreOverride(session: Session, pane: StatusPane) -> String? {
        switch pane {
        case .left: session.pendingRestoreCommand
        case .right: session.pendingSplitRestoreCommand
        case .scratch: nil
        }
    }

    private func durableCommand(session: Session, pane: StatusPane) -> String? {
        switch pane {
        case .left: session.initialCommand
        case .right: session.splitInitialCommand
        case .scratch: nil
        }
    }

    private func requestedWait(session: Session, pane: StatusPane) -> Bool {
        switch pane {
        case .left: session.commandWait
        case .right: session.splitCommandWait
        case .scratch: false
        }
    }

    private static func unownedSeed(disposition: ZmxSupport.LaunchDisposition) -> LinuxLaunchSeed {
        guard case .wrapped(let configuration) = disposition else {
            return LinuxLaunchSeed(command: nil, initialInput: nil, waitAfterCommand: false)
        }
        return LinuxLaunchSeed(command: configuration.command, initialInput: nil,
                               waitAfterCommand: false)
    }

    private func restoreDenylist() -> Set<String> {
        let path = ConfigPaths.restoreDenylistPath(configDirectory: configDirectory())
        return (try? String(contentsOf: path, encoding: .utf8)).map(CommandRestore.parseDenylist)
            ?? ["tmux", "screen", "zellij"]
    }
}
