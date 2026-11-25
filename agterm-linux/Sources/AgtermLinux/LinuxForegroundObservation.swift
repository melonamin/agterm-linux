import CGtk
import Foundation
import agtermCore

@MainActor
extension GhosttySurface {
    /// One process observation supplies duplication and restart decisions before either can mutate a pane.
    func replayObservation(snapshot: LinuxZmxForegroundResolver.Snapshot?) -> RestartReplay.Observation {
        guard let surface,
              let pid = LinuxZmxForegroundResolver.paneForegroundPID(
                backedByZmx: backedByZmx, paneIdentity: UUID(uuidString: paneToken), snapshot: snapshot,
                localForeground: { Int32(exactly: ghostty_surface_foreground_pid(surface)) }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/cmdline")),
              let argv = CommandRestore.parseProcCmdline(data) else {
            return RestartReplay.Observation(foreground: nil, isDaemonLeader: false, workingDirectory: nil)
        }
        let manager = FileManager.default
        let cwd = try? manager.destinationOfSymbolicLink(atPath: "/proc/\(pid)/cwd")
        let executable = try? manager.destinationOfSymbolicLink(atPath: "/proc/\(pid)/exe")
        let environment = (try? Data(contentsOf: URL(fileURLWithPath: "/proc/\(pid)/environ")))
            .map { String(decoding: $0, as: UTF8.self).split(separator: "\0") }
        let path = environment?.first { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) }
        let daemon = UUID(uuidString: paneToken).map(ZmxSupport.daemonName(for:))
        let leader = daemon.flatMap { snapshot?.leaders[$0] }
        return RestartReplay.Observation(
            foreground: CommandRestore.paneForeground(argv: argv, extra: loginShellName),
            isDaemonLeader: backedByZmx && leader == pid, workingDirectory: cwd,
            executablePath: executable.flatMap { $0.hasSuffix(" (deleted)") ? nil : $0 }, searchPath: path)
    }
}
