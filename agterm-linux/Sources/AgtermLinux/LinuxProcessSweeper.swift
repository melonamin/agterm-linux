import Foundation
import Glibc
import agtermCore

/// Linux process identities use /proc start ticks; equality is stable across snapshots and PID reuse.
struct LinuxProcessSweeper: Sendable {
    var table: @Sendable () -> [ProcessRecord]? = LinuxProcessSweeper.read
    var signal: @Sendable (Int32, Int32) -> Void = { _ = Glibc.kill($1, $0) }

    static func read() -> [ProcessRecord]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return nil }
        return names.compactMap { name in
            guard let pid = Int32(name),
                  let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8) else { return nil }
            return record(pid: pid, stat: stat)
        }
    }

    static func record(pid: Int32, stat: String) -> ProcessRecord? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(whereSeparator: \.isWhitespace)
        // Zombies have ended; they cannot hold a port/lock or respond to a signal.
        guard fields.count > 19, fields[0] != "Z", fields[0] != "X",
              let group = Int32(fields[2]), let foreground = Int32(fields[5]),
              let started = Int64(fields[19]) else { return nil }
        return ProcessRecord(pid: pid, started: started, group: group, foreground: foreground)
    }

    func foregroundJob(of shell: Int32) -> [ProcessRecord]? {
        table().map { ProcessSweep.foregroundJob(of: shell, in: $0) }
    }

    func isRunning(_ job: [ProcessRecord]) -> Bool {
        guard let table = table() else { return !job.isEmpty }
        return !ProcessSweep.survivors(of: job, in: table).isEmpty
    }

    func send(_ signal: Int32, to job: [ProcessRecord]) {
        guard let table = table() else { return }
        for process in ProcessSweep.survivors(of: job, in: table) { self.signal(signal, process.pid) }
    }
}
