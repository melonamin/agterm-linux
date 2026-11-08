import Foundation
import Glibc
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux foreground job cleanup")
struct LinuxProcessSweeperTests {
    @Test("proc identities exclude zombies and survive command parentheses")
    func records() {
        let tail = (["1", "42", "42", "34816", "777"] + Array(repeating: "0", count: 13) + ["123456"]).joined(separator: " ")
        #expect(LinuxProcessSweeper.record(pid: 42, stat: "42 (shell (job)) S \(tail)")
            == ProcessRecord(pid: 42, started: 123456, group: 42, foreground: 777))
        #expect(LinuxProcessSweeper.record(pid: 42, stat: "42 (shell) Z \(tail)") == nil)
        #expect(LinuxProcessSweeper.record(pid: 42, stat: "malformed") == nil)
    }

    @Test("confirmed kill hangs up only the snapshot foreground job, including external daemons", arguments: ["agterm-00000000000000000000000000000000", "external"])
    func confirmedKill(name: String) {
        let table = [ProcessRecord(pid: 42, started: 1, group: 42, foreground: 77),
                     ProcessRecord(pid: 77, started: 2, group: 77),
                     ProcessRecord(pid: 88, started: 3, group: 88)]
        let signals = Signals()
        let sweeper = LinuxProcessSweeper(table: { table }, signal: { signals.append($0, $1) })
        let client = LinuxZmxClient(executablePath: "/zmx", socketDirectory: "/test", sweeper: sweeper) { request in
            request.arguments == ["list"] ? "name=\(name)\tpid=42\tclients=1\n" : "killed session \(name)\n"
        }
        #expect(client.killConfirmed(name: name) == .killed)
        #expect(signals.values == [[SIGHUP, 77]])
    }

    @Test("stale socket and recycled PID never receive a signal")
    func staleAndRecycled() {
        let shell = ProcessRecord(pid: 42, started: 1, group: 42, foreground: 77)
        let job = ProcessRecord(pid: 77, started: 2, group: 77)
        let signals = Signals()
        let sweeper = LinuxProcessSweeper(table: { [shell, job] }, signal: { signals.append($0, $1) })
        let client = LinuxZmxClient(executablePath: "/zmx", socketDirectory: "/test", sweeper: sweeper) { request in
            request.arguments == ["list"] ? "name=agterm-00000000000000000000000000000000\tpid=42\tclients=1\n" : "cleaned up stale session agterm-00000000000000000000000000000000\n"
        }
        #expect(client.killConfirmed(name: "agterm-00000000000000000000000000000000") == .staleSocket)
        let recycled = LinuxProcessSweeper(table: { [ProcessRecord(pid: 77, started: 999, group: 77)] },
                                          signal: { signals.append($0, $1) })
        recycled.send(SIGKILL, to: [job])
        #expect(signals.values.isEmpty)
        #expect(!recycled.isRunning([job]))
    }
}

private final class Signals: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[Int32]] = []
    var values: [[Int32]] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ signal: Int32, _ pid: Int32) { lock.lock(); defer { lock.unlock() }; storage.append([signal, pid]) }
}
