import Foundation
import Testing
import agtermCore
@testable import AgtermLinux

@Suite("Linux zmx adapters")
struct LinuxZmxTests {
    @Test("kill output requires an exact confirmation")
    func killOutcome() {
        #expect(LinuxZmxClient.outcome(
            of: "killed session agterm-deadbeef\n", name: "agterm-deadbeef"
        ) == .killed)
        #expect(LinuxZmxClient.outcome(
            of: "cleaned up stale session agterm-deadbeef\n", name: "agterm-deadbeef"
        ) == .staleSocket)
        #expect(LinuxZmxClient.outcome(
            of: "not killed session agterm-deadbeef\n", name: "agterm-deadbeef"
        ) == .failed("not killed session agterm-deadbeef"))
    }

    @Test("a zero-exit kill reports its stderr confirmation; list keeps stderr out")
    func killReadsStderr() throws {
        let zmx = try StderrZmx()
        defer { zmx.remove() }
        let client = LinuxZmxClient(executablePath: zmx.path, socketDirectory: "/tmp/zmx-test")
        #expect(client.killConfirmed(name: "agterm-a") == .killed)
        #expect(client.killObservedOrphan(names: ["agterm-b"]) == ["agterm-b": .staleSocket])
        #expect(client.listSessions()?.map(\.name) == ["agterm-c"])
    }

    @Test("only kill invocations merge stderr")
    func mergeFlag() {
        let seen = InvocationLog()
        let client = LinuxZmxClient(executablePath: "/zmx", socketDirectory: "/tmp/zmx-test") { invocation in
            seen.append(invocation)
            return ""
        }
        _ = client.listSessions()
        _ = client.killConfirmed(name: "agterm-a")
        _ = client.killObservedOrphan(names: ["agterm-b"])
        _ = client.kill(paneIdentities: [UUID()])
        _ = client.screen(name: "agterm-a", all: false)
        #expect(seen.merges == ["list": false, "kill": true, "screen": false])
    }

    @Test("proc stat parsing tolerates parentheses in the process name")
    func procStatForegroundGroup() {
        let stat = "42 (zmx (pane)) S 1 42 42 34816 777 0 0 0"
        #expect(LinuxZmxForegroundResolver.terminalForegroundGroup(stat: stat) == 777)
        #expect(LinuxZmxForegroundResolver.terminalForegroundGroup(
            stat: "42 (zmx) S 1 42 42 34816 -1 0"
        ) == nil)
        #expect(LinuxZmxForegroundResolver.terminalForegroundGroup(stat: "malformed") == nil)
    }

    @Test("the development zmx path is absolute")
    func developmentPath() {
        #expect(LinuxZmxLaunch.executablePath(environment: [:]).hasPrefix("/"))
        #expect(LinuxZmxLaunch.executablePath(environment: ["AGTERM_ZMX_PATH": "/tmp/custom-zmx"])
            == "/tmp/custom-zmx")
    }
}

private struct StderrZmx {
    let directory: URL
    var path: String { directory.appendingPathComponent("zmx").path }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("zmx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        case "$1:$2" in
        kill:agterm-a) echo "killed session agterm-a" >&2 ;;
        kill:agterm-b) echo "cleaned up stale session agterm-b" >&2 ;;
        list:*) printf 'name=agterm-c\\tclients=0\\tpid=7\\n'; echo "name=agterm-noise" >&2 ;;
        esac
        """
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class InvocationLog: @unchecked Sendable {
    private let lock = NSLock()
    private var byCommand: [String: Bool] = [:]

    func append(_ invocation: LinuxZmxClient.Invocation) {
        lock.withLock { byCommand[invocation.arguments.first ?? ""] = invocation.mergesStderr }
    }

    var merges: [String: Bool] { lock.withLock { byCommand } }
}

private final class ListingRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var timeouts: [TimeInterval] = []
    private let output: String?

    init(daemons: [UUID: Int32]) {
        output = daemons.map { "name=\(ZmxSupport.daemonName(for: $0))\tclients=1\tpid=\($1)" }
            .joined(separator: "\n")
    }

    init(failing: Void) { output = nil }

    var listTimeouts: [TimeInterval] { lock.withLock { timeouts } }

    func client() -> LinuxZmxClient {
        LinuxZmxClient(executablePath: "/zmx", socketDirectory: "/tmp/zmx-test", timeout: 3) { invocation in
            guard invocation.arguments == ["list"] else { return "" }
            self.lock.withLock { self.timeouts.append(invocation.timeout) }
            guard let output = self.output else { throw LinuxZmxClient.CommandError.timedOut }
            return output
        }
    }
}

@MainActor
private final class WrappedSurface: TerminalSurface, LinuxForegroundCapturePane {
    let identity = UUID()
    let backedByZmx: Bool
    let isRealized = true
    let localForeground: Int32 = 4242
    var paneToken: String { identity.uuidString }

    init(zmx: Bool = true) { backedByZmx = zmx }

    func teardown() {}
    func promoteToPrimaryPane() {}

    func pid(_ snapshot: LinuxZmxForegroundResolver.Snapshot?) -> Int32? {
        LinuxZmxForegroundResolver.paneForegroundPID(backedByZmx: backedByZmx, paneIdentity: identity,
                                                     snapshot: snapshot, localForeground: { self.localForeground })
    }
}

@MainActor
@Suite("Linux zmx foreground snapshot")
struct LinuxZmxForegroundSnapshotTests {
    private func session(_ surface: WrappedSurface?, split: WrappedSurface? = nil, remote: String? = nil) -> Session {
        let session = Session(initialCwd: "/tmp", remoteHost: remote)
        session.surface = surface
        session.splitSurface = split
        return session
    }

    private func resolver(_ runner: ListingRunner) -> LinuxZmxForegroundResolver {
        LinuxZmxForegroundResolver(client: runner.client(), probe: { $0 + 1000 })
    }

    @Test("a wrapped pane whose daemon lookup fails reports unknown, never the attach client")
    func wrappedLookupFailureIsUnknown() {
        let wrapped = WrappedSurface()
        let present = WrappedSurface()
        let snapshot = LinuxZmxForegroundResolver.Snapshot(
            leaders: [ZmxSupport.daemonName(for: present.identity): 7], probe: { _ in nil })
        #expect(wrapped.pid(nil) == nil)
        #expect(wrapped.pid(snapshot) == nil)
        #expect(present.pid(snapshot) == nil)
        #expect(LinuxZmxForegroundResolver.paneForegroundPID(
            backedByZmx: true, paneIdentity: nil, snapshot: snapshot, localForeground: { 4242 }) == nil)
        #expect(WrappedSurface(zmx: false).pid(nil) == 4242)
    }

    @Test("one listing serves every pane of a tree pass")
    func treePassListsOnce() {
        let first = WrappedSurface(), missing = WrappedSurface(), split = WrappedSurface()
        let local = WrappedSurface(zmx: false)
        let runner = ListingRunner(daemons: [first.identity: 10, split.identity: 20])
        let sessions = [session(first, split: split), session(missing), session(local)]
        let snapshot = resolver(runner).passSnapshot(for: sessions, timeout: nil)
        #expect(first.pid(snapshot) == 1010)
        #expect(missing.pid(snapshot) == nil)
        #expect(split.pid(snapshot) == 1020)
        #expect(missing.pid(snapshot) == nil)
        #expect(local.pid(snapshot) == 4242)
        #expect(runner.listTimeouts == [3])
    }

    @Test("a failed listing leaves every wrapped pane unknown without re-listing")
    func failedListingIsUnknownForAll() {
        let first = WrappedSurface(), second = WrappedSurface()
        let runner = ListingRunner(failing: ())
        let snapshot = resolver(runner).passSnapshot(for: [session(first), session(second)], timeout: nil)
        #expect(snapshot == nil)
        #expect(first.pid(snapshot) == nil)
        #expect(second.pid(snapshot) == nil)
        #expect(runner.listTimeouts.count == 1)
    }

    @Test("no local wrapped pane takes no listing")
    func unwrappedOrRemoteSkipsListing() {
        let runner = ListingRunner(daemons: [:])
        let sessions = [session(WrappedSurface(zmx: false)), session(WrappedSurface(), remote: "host")]
        #expect(resolver(runner).passSnapshot(for: sessions, timeout: nil) == nil)
        #expect(runner.listTimeouts.isEmpty)
    }

    @Test("a capture pass takes one listing bounded by the capture timeout", arguments: [true, false])
    func capturePassListsOnceWithinBudget(listingSucceeds: Bool) {
        let first = WrappedSurface(), second = WrappedSurface(), local = WrappedSurface(zmx: false)
        let runner = listingSucceeds
            ? ListingRunner(daemons: [first.identity: 10, second.identity: 20]) : ListingRunner(failing: ())
        let resolver = resolver(runner)
        let sessions = [session(first), session(second), session(local)]
        let panes: [UUID: WrappedSurface] = Dictionary(uniqueKeysWithValues: zip(sessions.map(\.id), [first, second, local]))
        let count = LinuxForegroundCapture.capture(
            sessions: sessions, preserveUnconsumedPending: true,
            panes: { (panes[$0.id], nil) },
            snapshot: { resolver.freshSnapshot(timeout: LinuxZmxClient.captureInvocationTimeout) },
            read: { pane, snapshot in pane.pid(snapshot).map { ["pid", String($0)] } })
        #expect(runner.listTimeouts == [LinuxZmxClient.captureInvocationTimeout])
        #expect(count == (listingSucceeds ? 3 : 1))
        #expect(sessions[0].foregroundCommand == (listingSucceeds ? ["pid", "1010"] : nil))
        #expect(sessions[1].foregroundCommand == (listingSucceeds ? ["pid", "1020"] : nil))
        #expect(sessions[2].foregroundCommand == ["pid", "4242"])
    }
}
