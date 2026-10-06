import Testing
import agtermCore
@testable import AgtermLinux

@Suite("zmx.attach request validation")
struct RemoteZmxAttachRequestTests {
    private struct Attach: Equatable {
        let host: String
        let session: String
        let window: String?
    }

    private final class Calls {
        var treeHosts: [String] = []
        var attaches: [Attach] = []
    }

    private static let tree = ControlRemoteTree(
        host: "buildbox", endpoint: ControlZmxEndpoint(executable: "/zmx", socketDirectory: "/tmp/zmx"), sessions: []
    )

    private func dispatch(_ request: ControlRequest, calls: Calls) -> ControlResponse {
        ControlServer.dispatchRemoteZmx(request, readTree: { host in
            calls.treeHosts.append(host)
            return ControlResponse(ok: true, result: ControlResult(remote: Self.tree))
        }, attach: { host, session, _, window in
            calls.attaches.append(Attach(host: host, session: session, window: window))
            return ControlResponse(ok: true)
        })
    }

    @Test("an invalid remote session is refused before any ssh call", arguments: [
        (nil, "zmx.attach requires a remote session"),
        ("", "zmx.attach requires a remote session"),
        ("  \n", "zmx.attach requires a remote session"),
        ("two words", "invalid remote session"),
        ("bell\u{07}", "invalid remote session"),
    ] as [(String?, String)])
    func invalidTarget(target: String?, error: String) {
        let calls = Calls()
        let response = dispatch(ControlRequest(cmd: .zmxAttach, target: target,
                                               args: ControlArgs(host: "buildbox")), calls: calls)
        #expect(response.ok == false)
        #expect(response.error == error)
        #expect(calls.treeHosts.isEmpty)
        #expect(calls.attaches.isEmpty)
    }

    @Test("a missing host is refused before any ssh call")
    func missingHost() {
        let calls = Calls()
        let response = dispatch(ControlRequest(cmd: .zmxAttach, target: "s1", args: ControlArgs(host: "  ")),
                                calls: calls)
        #expect(response.error == "zmx.attach requires a host")
        #expect(calls.treeHosts.isEmpty)
    }

    @Test("host, session and window are trimmed like the shared dispatcher", arguments: [
        (" w1 ", "w1"), ("   ", nil), (nil, nil),
    ] as [(String?, String?)])
    func trimsArguments(window: String?, expected: String?) {
        let calls = Calls()
        let response = dispatch(ControlRequest(cmd: .zmxAttach, target: " s1\n",
                                               args: ControlArgs(host: " buildbox ", window: window)), calls: calls)
        #expect(response.ok)
        #expect(calls.treeHosts == ["buildbox"])
        #expect(calls.attaches == [Attach(host: "buildbox", session: "s1", window: expected)])
    }

    @Test("a failed tree read is returned without attaching")
    func treeFailure() {
        var attached = false
        let response = ControlServer.dispatchRemoteZmx(
            ControlRequest(cmd: .zmxAttach, target: "s1", args: ControlArgs(host: "buildbox")),
            readTree: { _ in ControlResponse(ok: false, error: "ssh failed") },
            attach: { _, _, _, _ in
                attached = true
                return ControlResponse(ok: true)
            })
        #expect(response.error == "ssh failed")
        #expect(!attached)
    }

    @Test("a remote tree request reads the tree and never attaches")
    func treeOnly() {
        let calls = Calls()
        let response = dispatch(ControlRequest(cmd: .zmxTree, args: ControlArgs(host: "buildbox")), calls: calls)
        #expect(response.result?.remote == Self.tree)
        #expect(calls.treeHosts == ["buildbox"])
        #expect(calls.attaches.isEmpty)
    }
}
