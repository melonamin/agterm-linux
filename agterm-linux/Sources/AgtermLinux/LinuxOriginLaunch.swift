import Foundation
import Glibc
import agtermCore

@MainActor
extension ControlServer {
    /// A remote operation must start Live daemons even when GTK has never realized their hidden widgets.
    func prepareOriginPanes(in controller: AppController, sessions: Set<UUID>, completion: @escaping @MainActor (String?) -> Void) {
        var commands: [(UUID, [String])] = []
        for row in controller.store.workspaces.flatMap(\.sessions)
            where sessions.contains(row.id) && row.remoteHost == nil && row.content == .terminal {
            for (surface, role) in [(row.surface, StatusPane.left), (row.splitSurface, .right), (row.scratchSurface, .scratch)] {
                guard let surface = surface as? GhosttySurface, surface.backedByZmx, !surface.isRealized else { continue }
                let environment: [String: String]
                let command: String?
                if let provider = surface.launchSeed {
                    environment = provider.environment
                    command = provider.resolveDetached(role).command
                } else {
                    environment = surface.env
                    command = surface.detachedLaunchCommand
                }
                guard let command, let identity = UUID(uuidString: surface.paneToken), !originEvidence.runs(identity) else { continue }
                let line = "cd " + CommandRestore.shellQuotedLine([surface.cwd]) + " && exec " + command
                commands.append((identity, environment.map { "\($0.key)=\($0.value)" } + ["/bin/sh", "-c", line]))
            }
        }
        guard !commands.isEmpty else { return completion(nil) }
        let pending = commands
        let client = gZmxClient
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            for (identity, command) in pending {
                if let error = Self.runDetachedOrigin(command) {
                    // GTK may have realized the pane since the launch was collected.
                    if client?.listSessions()?.contains(where: { $0.name == ZmxSupport.daemonName(for: identity) && $0.clients != nil }) == true { continue }
                    failure = error
                    break
                }
            }
            let outcome = failure
            runOnMain { MainActor.assumeIsolated {
                let walk = gLibrary.paneClaims()
                if walk.complete, let client = gZmxClient {
                    let claimed = Set(walk.claims.map(\.paneIdentity))
                    let orphaned = pending.map(\.0).filter { !claimed.contains($0) }
                    if !orphaned.isEmpty { DispatchQueue.global().async { _ = client.kill(paneIdentities: orphaned) } }
                }
                completion(outcome)
            } }
        }
    }

    nonisolated private static func runDetachedOrigin(_ argv: [String]) -> String? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("origin-launch-" + UUID().uuidString)
        let descriptor = Glibc.open(output.path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o600)
        let input = Glibc.open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer {
            if descriptor >= 0 { Glibc.close(descriptor) }
            if input >= 0 { Glibc.close(input) }
            try? FileManager.default.removeItem(at: output)
        }
        guard descriptor >= 0, input >= 0 else { return "could not create origin launch descriptors" }
        do {
            let child = try LinuxChildProcess(argv: argv,
                environment: gdkEnvironment.restoringChildEnvironment(ProcessInfo.processInfo.environment),
                input: input, output: descriptor, errors: descriptor, onExit: { _ in })
            guard let status = child.wait(until: Date().addingTimeInterval(5)) else {
                child.terminate(signal: SIGKILL)
                return "origin pane launch timed out"
            }
            guard status != 0 else { return nil }
            let handle = try FileHandle(forReadingFrom: output)
            defer { try? handle.close() }
            return "could not start origin pane: " + String(decoding: try handle.read(upToCount: 65536) ?? Data(), as: UTF8.self)
        } catch { return "could not start origin pane: \(error)" }
    }
}
