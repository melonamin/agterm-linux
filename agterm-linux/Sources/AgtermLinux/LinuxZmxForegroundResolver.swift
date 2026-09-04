import Foundation
import agtermCore
#if canImport(Glibc)
import Glibc
#endif

/// Resolves a zmx daemon leader to its pty's foreground process group through `/proc/<pid>/stat`.
@MainActor
final class LinuxZmxForegroundResolver {
    private let client: LinuxZmxClient
    private var leaders: [String: Int32] = [:]
    private var gate = ZmxRefreshGate()

    init(client: LinuxZmxClient) {
        self.client = client
    }

    func noteLifecycleChange() {
        gate.noteLifecycleChange()
    }

    func foregroundPID(sessionName: String, now: Date = Date()) -> Int32? {
        if gate.shouldRefresh(now: now), let refreshed = client.sessionLeaderPIDs() {
            leaders = refreshed
        }
        guard let leader = leaders[sessionName] else {
            gate.noteLifecycleChange()
            return nil
        }
        guard let foreground = Self.terminalForegroundGroup(leader) else {
            if Glibc.kill(leader, 0) != 0, errno == ESRCH { leaders[sessionName] = nil }
            gate.noteLifecycleChange()
            return nil
        }
        return foreground
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
