import Foundation
import agtermCore

/// Resolves a zmx daemon leader to its pty's foreground process group through `/proc/<pid>/stat`.
/// A capture or `tree` pass takes one bounded listing that serves every pane of that pass.
@MainActor
final class LinuxZmxForegroundResolver {
    typealias Probe = @Sendable (Int32) -> Int32?

    struct Snapshot: Sendable {
        let leaders: [String: Int32]
        let probe: Probe

        func foregroundPID(sessionName: String) -> Int32? {
            leaders[sessionName].flatMap(probe)
        }
    }

    private let client: LinuxZmxClient
    private let probe: Probe

    init(client: LinuxZmxClient, probe: @escaping Probe = LinuxZmxForegroundResolver.terminalForegroundGroup(_:)) {
        self.client = client
        self.probe = probe
    }

    /// Nil when the listing failed or timed out, which leaves every wrapped pane of the pass unknown.
    func freshSnapshot(timeout: TimeInterval?) -> Snapshot? {
        client.sessionLeaderPIDs(timeout: timeout).map { Snapshot(leaders: $0, probe: probe) }
    }

    func passSnapshot(for sessions: [Session], timeout: TimeInterval?) -> Snapshot? {
        ZmxForegroundRefreshPolicy.hasWrappedPane(in: sessions.filter(\.isPersistable))
            ? freshSnapshot(timeout: timeout) : nil
    }

    /// A wrapped pane's local pty foreground is its zmx attach client, so a failed daemon lookup reports
    /// unknown rather than falling back to it.
    nonisolated static func paneForegroundPID(backedByZmx: Bool, paneIdentity: UUID?, snapshot: Snapshot?,
                                              localForeground: () -> Int32?) -> Int32? {
        guard backedByZmx else { return localForeground().flatMap { $0 > 0 ? $0 : nil } }
        guard let paneIdentity else { return nil }
        return snapshot?.foregroundPID(sessionName: ZmxSupport.daemonName(for: paneIdentity))
    }

    /// Linux proc stat fields after the parenthesized command begin with state, ppid, pgrp, session,
    /// tty_nr, tpgid. Split after the LAST `)` because a process name may itself contain parentheses.
    nonisolated static func terminalForegroundGroup(_ pid: Int32) -> Int32? {
        guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else { return nil }
        return terminalForegroundGroup(stat: text)
    }

    nonisolated static func terminalForegroundGroup(stat text: String) -> Int32? {
        guard let close = text.lastIndex(of: ")") else { return nil }
        let fields = text[text.index(after: close)...].split(whereSeparator: \.isWhitespace)
        guard fields.count > 5, let tpgid = Int32(fields[5]), tpgid > 0 else { return nil }
        return tpgid
    }
}

@MainActor var gZmxForegroundResolver: LinuxZmxForegroundResolver?
