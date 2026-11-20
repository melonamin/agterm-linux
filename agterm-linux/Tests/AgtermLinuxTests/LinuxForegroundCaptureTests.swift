import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@MainActor
private final class FakePane: LinuxForegroundCapturePane {
    let backedByZmx: Bool
    let isRealized: Bool
    let argv: [String]?
    var reads = 0

    init(_ argv: [String]?, zmx: Bool = false, realized: Bool = true) {
        self.argv = argv
        backedByZmx = zmx
        isRealized = realized
    }
}

@MainActor
@Suite("Linux foreground capture")
struct LinuxForegroundCaptureTests {
    private struct Snapshot {}
    private final class Counter { var value = 0 }

    private func capture(_ sessions: [Session], preserve: Bool,
                         panes: [UUID: (primary: FakePane?, split: FakePane?)],
                         snapshot: Snapshot? = Snapshot(), snapshotCalls: Counter = Counter(),
                         timeRemaining: @escaping () -> Bool = { true }) -> Int {
        LinuxForegroundCapture.capture(
            sessions: sessions, preserveUnconsumedPending: preserve,
            panes: { panes[$0.id] ?? (nil, nil) },
            snapshot: { () -> Snapshot? in
                snapshotCalls.value += 1
                return snapshot
            },
            timeRemaining: timeRemaining,
            read: { pane, _ in
                pane.reads += 1
                return pane.argv
            })
    }

    @Test("exit capture preserves an unconsumed pending argv when the read yields nothing")
    func exitPreservesPending() {
        let session = Session(initialCwd: "/tmp")
        session.pendingForegroundCommand = ["npm", "run", "dev"]
        let count = capture([session], preserve: true, panes: [session.id: (FakePane(nil), nil)])
        #expect(count == 0)
        #expect(session.foregroundCommand == ["npm", "run", "dev"])
    }

    @Test("exit capture preserves a hidden split's pending argv when no split surface was built")
    func exitPreservesHiddenSplitPending() {
        let session = Session(initialCwd: "/tmp")
        session.hasSplit = true
        session.pendingSplitForegroundCommand = ["tail", "-f", "log"]
        _ = capture([session], preserve: true, panes: [session.id: (FakePane(nil), nil)])
        #expect(session.splitForegroundCommand == ["tail", "-f", "log"])
    }

    @Test("restore.capture leaves an unconsumed pending argv out of the snapshot and armed")
    func onDemandDropsPending() {
        let session = Session(initialCwd: "/tmp")
        session.hasSplit = true
        session.pendingForegroundCommand = ["npm", "run", "dev"]
        session.pendingSplitForegroundCommand = ["tail", "-f", "log"]
        let count = capture([session], preserve: false, panes: [session.id: (FakePane(nil), nil)])
        #expect(count == 0)
        #expect(session.foregroundCommand == nil)
        #expect(session.splitForegroundCommand == nil)
        #expect(session.takePendingForegroundCommand(pane: .left) == ["npm", "run", "dev"])
        #expect(session.takePendingForegroundCommand(pane: .right) == ["tail", "-f", "log"])
    }

    @Test("exit capture does not resurrect an argv the factory already consumed")
    func consumedPendingStaysGone() {
        let session = Session(initialCwd: "/tmp")
        session.pendingForegroundCommand = ["npm", "run", "dev"]
        _ = session.takePendingForegroundCommand(pane: .left)
        _ = capture([session], preserve: true, panes: [session.id: (FakePane(nil), nil)])
        #expect(session.foregroundCommand == nil)
    }

    @Test("a hidden realized Live split is read")
    func hiddenRealizedLiveSplitCaptured() {
        let session = Session(initialCwd: "/tmp")
        session.hasSplit = true
        session.isSplit = false
        let split = FakePane(["tail", "-f", "log"], zmx: true)
        let count = capture([session], preserve: true,
                            panes: [session.id: (FakePane(["vim"], zmx: true), split)])
        #expect(count == 2)
        #expect(session.splitForegroundCommand == ["tail", "-f", "log"])
    }

    @Test("an unrealized hidden split keeps pending at exit and nil on demand", arguments: [true, false])
    func unrealizedHiddenSplit(preserve: Bool) {
        let session = Session(initialCwd: "/tmp")
        session.hasSplit = true
        session.isSplit = false
        session.pendingSplitForegroundCommand = ["tail", "-f", "log"]
        let split = FakePane(["wrong"], zmx: true, realized: false)
        _ = capture([session], preserve: preserve, panes: [session.id: (nil, split)])
        #expect(split.reads == 0)
        #expect(session.splitForegroundCommand == (preserve ? ["tail", "-f", "log"] : nil))
    }

    @Test("a hidden non-Live split is not read and drops an earlier capture")
    func hiddenOrdinarySplitNotRead() {
        let session = Session(initialCwd: "/tmp")
        session.hasSplit = true
        session.isSplit = false
        session.splitForegroundCommand = ["stale"]
        let split = FakePane(["wrong"])
        let count = capture([session], preserve: false, panes: [session.id: (nil, split)])
        #expect(count == 0)
        #expect(split.reads == 0)
        #expect(session.splitForegroundCommand == nil)
    }

    @Test("a denylisted foreground is stored raw and preempts the durable command at replay")
    func denylistedForegroundStoredRaw() {
        let session = Session(initialCwd: "/tmp")
        let count = capture([session], preserve: true, panes: [session.id: (FakePane(["tmux", "attach"]), nil)])
        #expect(count == 1)
        #expect(session.foregroundCommand == ["tmux", "attach"])
        let configuration = ZmxSupport.Configuration(
            executablePath: "/usr/bin/zmx", environment: ["SHELL": "/bin/zsh", "ZDOTDIR": "/tmp/integration"],
            daemonName: "agterm-pane", socketDirectory: "/tmp/zmx", paneID: "pane")
        let command = AppController.wrappedAttachCommand(
            configuration, replay: session.foregroundCommand, durable: "make dev", denylist: ["tmux"])
        #expect(command == configuration.command)
        let lostDaemon = AppController.wrappedAttachCommand(
            configuration, replay: nil, durable: "make dev", denylist: ["tmux"])
        #expect(lostDaemon.contains("make dev"))
    }

    @Test("remote rows are neither read nor counted; the count is slots written")
    func remoteRowsSkipped() {
        let local = Session(initialCwd: "/tmp")
        local.isSplit = true
        local.hasSplit = true
        local.pendingForegroundCommand = ["kept"]
        let remote = Session(initialCwd: "/tmp", remoteHost: "buildbox")
        remote.foregroundCommand = ["ssh-era"]
        let remotePane = FakePane(["ssh", "buildbox"])
        let count = capture([local, remote], preserve: true, panes: [
            local.id: (FakePane(nil), FakePane(["worker"])),
            remote.id: (remotePane, nil),
        ])
        #expect(count == 1)
        #expect(local.foregroundCommand == ["kept"])
        #expect(local.splitForegroundCommand == ["worker"])
        #expect(remotePane.reads == 0)
        #expect(remote.foregroundCommand == ["ssh-era"])
    }

    @Test("wrapped panes need the snapshot; ordinary panes do not take one")
    func snapshotGatesWrappedPanes() {
        let calls = Counter()
        let ordinary = Session(initialCwd: "/tmp")
        _ = capture([ordinary], preserve: true, panes: [ordinary.id: (FakePane(["vim"]), nil)],
                    snapshotCalls: calls)
        #expect(calls.value == 0)
        #expect(ordinary.foregroundCommand == ["vim"])

        let wrapped = Session(initialCwd: "/tmp")
        wrapped.pendingForegroundCommand = ["npm", "run", "dev"]
        let pane = FakePane(["wrong"], zmx: true)
        _ = capture([wrapped], preserve: true, panes: [wrapped.id: (pane, nil)], snapshot: nil,
                    snapshotCalls: calls)
        #expect(calls.value == 1)
        #expect(pane.reads == 0)
        #expect(wrapped.foregroundCommand == ["npm", "run", "dev"])
    }

    @Test("an exhausted budget stops reading and keeps pending at exit")
    func exhaustedBudget() {
        let session = Session(initialCwd: "/tmp")
        session.pendingForegroundCommand = ["npm", "run", "dev"]
        let pane = FakePane(["vim"])
        let count = capture([session], preserve: true, panes: [session.id: (pane, nil)], timeRemaining: { false })
        #expect(count == 0)
        #expect(pane.reads == 0)
        #expect(session.foregroundCommand == ["npm", "run", "dev"])
    }
}
